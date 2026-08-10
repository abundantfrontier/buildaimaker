import Foundation

/// Helpers for the cooperative `cancel.flag` file under a job directory.
public enum CancelFlag: Sendable {
    public static let fileName = "cancel.flag"

    /// Writes `cancel.flag` atomically (content `"1"`).
    public static func write(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("1".utf8).write(to: url, options: .atomic)
    }

    /// Returns true when the cancel flag file exists.
    public static func exists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Best-effort remove of the cancel flag (e.g. on requeue).
    public static func clear(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
