import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}

/// Generic-password storage for the Navidrome password, keyed by username.
public enum Keychain {
    // Not the bare bundle ID: an early CLI build created an item under that name, which the
    // app can't take ownership of.
    static let service = "cc.jofam.daptastic.navidrome"

    public static func password(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.status(status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Checks for the item without reading its data, so it never triggers an access prompt.
    public static func hasPassword(account: String) -> Bool {
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Replaces rather than updates the item where it can, so the caller becomes its creator —
    /// the one app macOS lets read it without an access prompt. Only the creator may delete an
    /// item, so if another app made it, update it in place instead (which may prompt once).
    public static func setPassword(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let deleted = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if deleted == errSecInvalidOwnerEdit {
            let status = SecItemUpdate(
                baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
            return
        }
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError.status(deleted) }
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func deletePassword(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
