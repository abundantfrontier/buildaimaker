import BAMCore
import Foundation
import Security

/// Storage for an optional Hugging Face Hub access token.
///
/// Production path uses Keychain; tests inject `InMemoryHFTokenStore`.
public protocol HFTokenStore: Sendable {
    /// Returns the stored token, or `nil` if none is set.
    func loadToken() throws -> String?
    /// Persists `token`, or removes the entry when `token` is `nil` / empty.
    func saveToken(_ token: String?) throws
}

/// In-memory token store for unit tests (no Keychain, no network).
public final class InMemoryHFTokenStore: HFTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init(token: String? = nil) {
        self.value = token
    }

    public func loadToken() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func saveToken(_ token: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        value = (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

/// Keychain-backed HF token store (macOS Security framework stub for dogfood).
///
/// Does not perform network I/O. Service/account names are stable so Settings
/// UI (later) can share the same item.
public struct KeychainHFTokenStore: HFTokenStore, Sendable {
    public static let service = "com.buildaimaker.huggingface"
    public static let account = "hf_token"

    public let service: String
    public let account: String

    public init(
        service: String = KeychainHFTokenStore.service,
        account: String = KeychainHFTokenStore.account
    ) {
        self.service = service
        self.account = account
    }

    public func loadToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw BAMError(
                code: .downloadFailed,
                message: "Keychain read failed (status \(status))"
            )
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else {
            return nil
        }
        return token
    }

    public func saveToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Always delete existing item first for upsert simplicity.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let trimmed, !trimmed.isEmpty else {
            return
        }

        let data = Data(trimmed.utf8)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BAMError(
                code: .downloadFailed,
                message: "Keychain write failed (status \(status))"
            )
        }
    }
}
