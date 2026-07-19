import BAMCharacterStudio
import BAMResourcesUI
import SwiftUI

/// List of saved characters + Create wizard (clear single entry point).
struct CharactersView: View {
    @Binding var selection: SidebarDestination?
    @State private var drafts: [CharacterDraft] = []
    @State private var showCreate = false
    @State private var loadError: String?

    private let store = CharacterLibraryStore()

    init(selection: Binding<SidebarDestination?> = .constant(nil)) {
        self._selection = selection
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
                        Takes a few minutes; no Advanced screens required.
                        """
                    )
                } actions: {
                    Button("Create a character") {
                        showCreate = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                List {
                    Section {
                        Button {
                            showCreate = true
                        } label: {
                            Label("Create another character", systemImage: "plus.circle.fill")
                        }
                    }
                    Section("Your characters") {
                        ForEach(drafts) { draft in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(draft.displayTitle)
                                    .font(.headline)
                                Text(draft.resolvedSpecies)
                                    .font(.subheadline)
                                    .foregroundStyle(BAMColors.secondaryLabel)
                                HStack(spacing: 10) {
                                    statusPill(draft.datasetId != nil, "Mind")
                                    statusPill(draft.previewAudioPath != nil, "Voice")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: delete)
                    }
                    Section {
                        Text("Next: open Playground to chat, or Advanced → Train to fine-tune a mind on a model.")
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
                    showCreate = true
                } label: {
                    Label("Create", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate, onDismiss: reload) {
            NavigationStack {
                CreateCharacterWizardView(
                    isPresented: $showCreate,
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

    private func statusPill(_ ok: Bool, _ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(ok ? Color.green.opacity(0.2) : Color.secondary.opacity(0.12))
            .foregroundStyle(ok ? .green : BAMColors.secondaryLabel)
            .clipShape(Capsule())
    }

    private func reload() {
        do {
            drafts = try store.list()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            try? store.delete(id: drafts[i].id)
        }
        reload()
    }
}
