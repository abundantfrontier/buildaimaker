import BAMCharacterStudio
import BAMResourcesUI
import SwiftUI

/// List of saved characters + Create / Continue wizard.
struct CharactersView: View {
    @Binding var selection: SidebarDestination?
    @State private var drafts: [CharacterDraft] = []
    @State private var showWizard = false
    @State private var resumeDraft: CharacterDraft?
    @State private var loadError: String?

    private let store = CharacterLibraryStore()

    init(selection: Binding<SidebarDestination?> = .constant(nil)) {
        self._selection = selection
    }

    private var inProgress: [CharacterDraft] {
        drafts.filter { !$0.isComplete }
    }

    private var completed: [CharacterDraft] {
        drafts.filter(\.isComplete)
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Couldn’t load characters",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if drafts.isEmpty {
                ContentUnavailableView {
                    Label("No characters yet", systemImage: "theatermasks")
                } description: {
                    Text(
                        """
                        One path: Create → name → story → voice → save.
                        If you leave mid-way, progress is saved — use Continue.
                        """
                    )
                } actions: {
                    Button("Create a character") {
                        openNew()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                List {
                    if !inProgress.isEmpty {
                        Section {
                            Text("You left these unfinished. Tap Continue to pick up where you stopped.")
                                .font(.caption)
                                .foregroundStyle(BAMColors.secondaryLabel)
                            ForEach(inProgress) { draft in
                                characterRow(draft, showContinue: true)
                            }
                            .onDelete { delete(from: inProgress, at: $0) }
                        } header: {
                            Text("Continue creating")
                        }
                    }

                    Section {
                        Button {
                            openNew()
                        } label: {
                            Label("Create a new character", systemImage: "plus.circle.fill")
                        }
                    }

                    if !completed.isEmpty {
                        Section("Finished characters") {
                            ForEach(completed) { draft in
                                characterRow(draft, showContinue: false)
                            }
                            .onDelete { delete(from: completed, at: $0) }
                        }
                    }

                    Section {
                        Text("Next: Playground to chat, or Advanced → Train to fine-tune on a model.")
                            .font(.caption)
                            .foregroundStyle(BAMColors.secondaryLabel)
                        Button {
                            selection = .playground
                        } label: {
                            Label("Go to Playground", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }
            }
        }
        .navigationTitle("Characters")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openNew()
                } label: {
                    Label("Create", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showWizard, onDismiss: {
            resumeDraft = nil
            reload()
        }) {
            NavigationStack {
                CreateCharacterWizardView(
                    isPresented: $showWizard,
                    resumeDraft: resumeDraft,
                    onGoPlayground: {
                        selection = .playground
                    }
                )
            }
            .frame(minWidth: 720, minHeight: 600)
            .background(SheetKeyWindowActivator())
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder
    private func characterRow(_ draft: CharacterDraft, showContinue: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(draft.displayTitle)
                    .font(.headline)
                Text(draft.resolvedSpecies)
                    .font(.subheadline)
                    .foregroundStyle(BAMColors.secondaryLabel)
                Text(draft.progressLabel)
                    .font(.caption)
                    .foregroundStyle(showContinue ? Color.orange : BAMColors.secondaryLabel)
                HStack(spacing: 10) {
                    statusPill(!draft.examples.isEmpty || draft.datasetId != nil, "Mind")
                    statusPill(draft.previewAudioPath != nil, "Voice")
                    if draft.isComplete {
                        statusPill(true, "Saved")
                    }
                }
            }
            Spacer()
            if showContinue || !draft.isComplete {
                Button("Continue") {
                    openResume(draft)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Edit") {
                    openResume(draft)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            openResume(draft)
        }
    }

    private func statusPill(_ ok: Bool, _ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ok ? Color.green.opacity(0.2) : Color.secondary.opacity(0.12))
            .foregroundStyle(ok ? .green : BAMColors.secondaryLabel)
            .clipShape(Capsule())
    }

    private func openNew() {
        resumeDraft = nil
        showWizard = true
    }

    private func openResume(_ draft: CharacterDraft) {
        resumeDraft = draft
        showWizard = true
    }

    private func reload() {
        do {
            drafts = try store.list()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(from source: [CharacterDraft], at offsets: IndexSet) {
        for i in offsets {
            try? store.delete(id: source[i].id)
        }
        reload()
    }
}
