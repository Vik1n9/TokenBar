import Foundation
import Security

/// Stores one secret per provider in the login keychain.
///
/// Every write is read back before it is reported as successful: a keychain
/// write can succeed at the API level and still leave nothing retrievable (wrong
/// access group, locked keychain), and a silently missing key looks identical to
/// a network failure later on.
struct KeychainStore {
    static let service = "com.vik1n9.tokenbar"

    enum StoreError: LocalizedError {
        case writeFailed(OSStatus)
        case readBackFailed

        var errorDescription: String? {
            switch self {
            case .writeFailed(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Could not save to the keychain: \(detail)"
            case .readBackFailed:
                return "Saved to the keychain but could not read it back."
            }
        }
    }

    /// Keychain account name; one per provider.
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
    }

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    func save(_ secret: String) throws {
        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.writeFailed(status) }
        guard load() == secret else { throw StoreError.readBackFailed }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
