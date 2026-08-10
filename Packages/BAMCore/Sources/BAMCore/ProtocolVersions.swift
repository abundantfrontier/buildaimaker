import Foundation

/// Schema and protocol version constants pinned for BuildAIMaker v1.
public enum ProtocolVersions: Sendable {
    /// Runner protocol (JSON-NL) version negotiated in worker `hello`.
    public static let runnerProtocolVersion: Int = 1

    /// Persona pack zip + JSON format version.
    public static let personaPackFormat: Int = 1

    /// SQLite library schema version (GRDB migrations).
    public static let librarySchemaVersion: Int = 1
}
