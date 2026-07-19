import Foundation

/// Result of an L2 pin / interpreter re-check (Settings + diagnostics).
public struct RuntimeIntegrityRecheckResult: Sendable, Equatable {
    public var isOK: Bool
    public var detail: String?
    public var code: BAMErrorCode?

    public init(isOK: Bool, detail: String? = nil, code: BAMErrorCode? = nil) {
        self.isOK = isOK
        self.detail = detail
        self.code = code
    }

    public static let ok = RuntimeIntegrityRecheckResult(isOK: true)
}
