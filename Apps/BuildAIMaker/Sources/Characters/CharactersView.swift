import BAMCharacterStudio
import BAMResourcesUI
import SwiftUI

/// Identifiable sheet session so Continue always opens the correct draft (not a blank new one).
private struct CharacterWizardSession: Identifiable, Equatable {
    /// Stable sheet identity: draft UUID, or a fresh token for Create.
    var id: String
    /// Nil = brand new character; non-nil = resume this draft.
    var draft: CharacterDraft?

    static func createNew() -> CharacterWizardSession {
        CharacterWizardSession(id: "new-\(UUID().uuidString)", draft: nil)
    }

    static func resume(_ draft: CharacterDraft) -> CharacterWizardSession {
        CharacterWizardSession(id: draft.id, draft: draft)
    }
}

/// List of saved characters + Create / Continue wizard.
struct CharactersView: View {
    @Binding var selection: SidebarDestination?
    @EnvironmentObject private var characterLaunch: CharacterStudioLaunchContext
    @State private var drafts: [CharacterDraft] = []
    @State private var wizardSession: CharacterWizardSession?
    @State private var loadError: String?
    @State private var deleteError: String?
    /// Pending delete confirmation target.
    @State private var pendingDelete: CharacterDraft?
    @State private var showDeleteConfirm = false

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
                        One path: Create → name → model → story → voice → save.
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
                            Text("You left these unfinished. Continue to finish, or Remove to discard.")
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
                        Section {
                            ForEach(completed) { draft in
                                characterRow(draft, showContinue: false)
                            }
                            .onDelete { delete(from: completed, at: $0) }
                        } header: {
                            Text("Finished characters")
                        } footer: {
                            Text("Right-click or use Remove to delete a character permanently.")
                                .font(.caption2)
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
        .sheet(item: $wizardSession, onDismiss: {
            reload()
        }) { session in
            NavigationStack {
                CreateCharacterWizardView(
                    isPresented: Binding(
                        get: { wizardSession != nil },
                        set: { if !$0 { wizardSession = nil } }
                    ),
                    resumeDraft: session.draft,
                    onGoPlayground: { draft in
                        characterLaunch.bindPlayground(from: draft)
                        selection = .playground
                    },
                    onGoTrain: { draft in
                        characterLaunch.bindTrain(from: draft)
                        selection = .train
                    }
                )
                // Force a fresh view identity per draft so StateObject cannot reuse a blank wizard.
                .id(session.id)
            }
            .frame(minWidth: 720, minHeight: 600)
            .background(SheetKeyWindowActivator())
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { draft in
            Button(deleteButtonLabel(for: draft), role: .destructive) {
                performDelete(draft)
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { draft in
            Text(deleteDialogMessage(for: draft))
        }
        .alert("Couldn’t delete character", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .onAppear(perform: reload)
    }

    private var deleteDialogTitle: String {
        guard let draft = pendingDelete else { return "Remove character?" }
        if draft.isComplete {
            return "Remove “\(draft.displayTitle)”?"
        }
        return "Discard unfinished character?"
    }

    private func deleteButtonLabel(for draft: CharacterDraft) -> String {
        draft.isComplete ? "Remove character" : "Discard progress"
    }

    private func deleteDialogMessage(for draft: CharacterDraft) -> String {
        if draft.isComplete {
            return "This permanently deletes the character card, voice preview, and saved progress. This cannot be undone."
        }
        return "“\(draft.displayTitle)” is still in progress. Discarding removes the draft and any partial work. This cannot be undone."
    }

    @ViewBuilder
    private func characterRow(_ draft: CharacterDraft, showContinue: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // Tappable info area (buttons stay outside so they receive clicks).
            Button {
                openResume(draft)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(draft.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(draft.resolvedSpecies)
                        .font(.subheadline)
                        .foregroundStyle(BAMColors.secondaryLabel)
                    Text(draft.progressLabel)
                        .font(.caption)
                        .foregroundStyle(showContinue ? Color.orange : BAMColors.secondaryLabel)
                    HStack(spacing: 10) {
                        statusPill(draft.hasSelectedBaseModel, "Model")
                        statusPill(!draft.examples.isEmpty || draft.datasetId != nil, "Mind")
                        statusPill(draft.previewAudioPath != nil, "Voice")
                        if draft.isComplete {
                            statusPill(true, "Saved")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showContinue || !draft.isComplete {
                Button("Continue") {
                    openResume(draft)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                Button("Edit") {
                    openResume(draft)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if draft.hasSelectedBaseModel || draft.datasetId != nil {
                Menu {
                    Button {
                        openPlayground(draft)
                    } label: {
                        Label("Open in Playground", systemImage: "bubble.left.and.bubble.right")
                    }
                    .disabled(!draft.hasSelectedBaseModel && draft.bible == nil)

                    Button {
                        openTrain(draft)
                    } label: {
                        Label(
                            draft.usesAppleFoundationModel
                                ? "Specialize Apple model (adapter)"
                                : "Train this character (LoRA)",
                            systemImage: "hammer"
                        )
                    }
                    .disabled(draft.datasetId == nil && !draft.hasSelectedBaseModel && !draft.usesAppleFoundationModel)
                } label: {
                    Label("Use", systemImage: "arrow.right.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open Playground or Train with this character’s model + mind")
            }

            Button(role: .destructive) {
                requestDelete(draft)
            } label: {
                Label(
                    draft.isComplete ? "Remove" : "Discard",
                    systemImage: "trash"
                )
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.regular)
            .help(draft.isComplete ? "Remove this character permanently" : "Discard unfinished character")
            .accessibilityLabel(draft.isComplete ? "Remove character" : "Discard unfinished character")
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button {
                openResume(draft)
            } label: {
                Label(
                    draft.isComplete ? "Edit" : "Continue",
                    systemImage: draft.isComplete ? "pencil" : "arrow.forward.circle"
                )
            }
            Button {
                openPlayground(draft)
            } label: {
                Label("Open in Playground", systemImage: "bubble.left.and.bubble.right")
            }
            Button {
                openTrain(draft)
            } label: {
                Label(
                    draft.usesAppleFoundationModel
                        ? "Specialize Apple model (adapter)"
                        : "Train this character (LoRA)",
                    systemImage: "hammer"
                )
            }
            Divider()
            Button(role: .destructive) {
                requestDelete(draft)
            } label: {
                Label(
                    draft.isComplete ? "Remove character" : "Discard unfinished character",
                    systemImage: "trash"
                )
            }
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
        wizardSession = .createNew()
    }

    private func openResume(_ draft: CharacterDraft) {
        // Prefer reloading from disk so we always have the latest saved fields.
        if let fresh = try? store.load(id: draft.id) {
            wizardSession = .resume(fresh)
        } else {
            wizardSession = .resume(draft)
        }
    }

    private func openPlayground(_ draft: CharacterDraft) {
        characterLaunch.bindPlayground(from: draft)
        selection = .playground
    }

    private func openTrain(_ draft: CharacterDraft) {
        characterLaunch.bindTrain(from: draft)
        selection = .train
    }

    private func reload() {
        do {
            drafts = try store.list()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func requestDelete(_ draft: CharacterDraft) {
        pendingDelete = draft
        showDeleteConfirm = true
    }

    private func delete(from source: [CharacterDraft], at offsets: IndexSet) {
        // Swipe / Edit-mode delete: confirm when a single item; batch without extra dialog.
        if offsets.count == 1, let i = offsets.first {
            requestDelete(source[i])
            return
        }
        for i in offsets {
            performDelete(source[i], confirmAlreadyShown: true)
        }
    }

    private func performDelete(_ draft: CharacterDraft, confirmAlreadyShown: Bool = true) {
        do {
            try store.delete(id: draft.id)
            pendingDelete = nil
            showDeleteConfirm = false
            deleteError = nil
            // If wizard was open on this draft, close it.
            if wizardSession?.draft?.id == draft.id || wizardSession?.id == draft.id {
                wizardSession = nil
            }
            reload()
        } catch {
            deleteError = error.localizedDescription
            pendingDelete = nil
            showDeleteConfirm = false
        }
    }
}
