import BAMCore
import Foundation

/// JSON file store for character drafts under Application Support.
public struct CharacterLibraryStore: @unchecked Sendable {
    public var root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(libraryRoot: URL? = nil, fileManager: FileManager = .default) {
        self.root = (libraryRoot ?? LibraryPaths.libraryRoot)
            .appendingPathComponent("characters", isDirectory: true)
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func ensureRoot() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func list() throws -> [CharacterDraft] {
        try ensureRoot()
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }

        var drafts: [CharacterDraft] = []
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let draft = try? decoder.decode(CharacterDraft.self, from: data)
            {
                drafts.append(draft)
            }
        }
        return drafts.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(_ draft: CharacterDraft) throws {
        try ensureRoot()
        var copy = draft
        copy.updatedAt = ISO8601DateFormatter().string(from: Date())
        let url = root.appendingPathComponent("\(copy.id).json")
        let data = try encoder.encode(copy)
        try data.write(to: url, options: .atomic)
    }

    public func load(id: String) throws -> CharacterDraft {
        let url = root.appendingPathComponent("\(id).json")
        let data = try Data(contentsOf: url)
        return try decoder.decode(CharacterDraft.self, from: data)
    }

    public func delete(id: String) throws {
        let url = root.appendingPathComponent("\(id).json")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func characterDirectory(id: String) throws -> URL {
        try ensureRoot()
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
