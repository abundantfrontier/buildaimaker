import BAMCharacterStudio
import BAMResourcesUI
import SwiftUI

/// List of saved characters + entry to Create wizard (CS-1).
struct CharactersView: View {
    @State private var drafts: [CharacterDraft] = []
    @State private var showCreate = false
    @State private var loadError: String?
    @State private var path = NavigationPath()

    private let store = CharacterLibraryStore()

    var body: some View {
        NavigationStack(path: $path) {
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
                        Text("Create a creature: story, how they talk, and a fun voice.")
                    } actions: {
                        Button("Create a character") {
                            showCreate = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(drafts) { draft in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.displayTitle)
                                    .font(.headline)
                                Text(draft.resolvedSpecies)
                                    .font(.subheadline)
                                    .foregroundStyle(BAMColors.secondaryLabel)
                                HStack(spacing: 8) {
                                    if draft.datasetId != nil {
                                        Label("Mind", systemImage: "brain")
                                            .font(.caption2)
                                    }
                                    if draft.previewAudioPath != nil {
                                        Label("Voice", systemImage: "waveform")
                                            .font(.caption2)
                                    }
                                    Text(draft.updatedAt.prefix(10))
                                        .font(.caption2)
                                        .foregroundStyle(BAMColors.secondaryLabel)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete(perform: delete)
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
                ToolbarItem(placement: .automatic) {
                    Button {
                        reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showCreate, onDismiss: reload) {
                NavigationStack {
                    CreateCharacterWizardView(isPresented: $showCreate)
                        .frame(minWidth: 640, minHeight: 520)
                }
            }
            .onAppear(perform: reload)
        }
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
            let id = drafts[i].id
            try? store.delete(id: id)
        }
        reload()
    }
}
