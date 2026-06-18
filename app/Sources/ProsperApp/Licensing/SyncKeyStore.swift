import CryptoKit
import Foundation
import Security

/// 256-bit settings-sync key kept in the **iCloud Keychain**
/// (`kSecAttrSynchronizable`), so the *same* key lands on every device the user
/// signs into iCloud — letting a settings blob encrypted on one Mac decrypt on
/// another without the server ever seeing the key (end-to-end).
///
/// This is the intended production design. It requires a Developer ID build with
/// the keychain-access entitlement; until that's in place `SecItem` returns
/// `errSecMissingEntitlement` and the calls below yield `nil`, at which point
/// `SyncCrypto` falls back to the per-machine device key for local testing.
enum SyncKeyStore {
    private static let service = "com.prosper.sync"
    private static let account = "settings-sync-key.v1"
    private static let keyByteCount = 32

    enum Status: Equatable { case available, unavailable(String) }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // The bit that makes the item ride iCloud Keychain to every device.
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
    }

    /// The existing synced key, or `nil` if none exists yet / keychain unavailable.
    static func fetch() -> SymmetricKey? {
        var q = baseQuery()
        q[kSecReturnData as String] = kCFBooleanTrue as Any
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == keyByteCount else { return nil }
        return SymmetricKey(data: data)
    }

    /// The synced key, creating + storing a fresh one on the first device. Returns
    /// `nil` only when the keychain itself is unavailable (e.g. missing entitlement).
    static func fetchOrCreate() -> SymmetricKey? {
        if let existing = fetch() { return existing }
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, keyByteCount, &bytes) == errSecSuccess else { return nil }
        let data = Data(bytes)
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess: return SymmetricKey(data: data)
        case errSecDuplicateItem: return fetch() // another device synced one in first
        default: return nil
        }
    }

    /// Whether the keychain (and thus iCloud sync of the key) is reachable.
    static var status: Status {
        var q = baseQuery()
        q[kSecReturnData as String] = kCFBooleanTrue as Any
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess, errSecItemNotFound:
            return .available
        case errSecMissingEntitlement:
            return .unavailable("iCloud Keychain access needs the app entitlement (added with Developer ID).")
        case let other:
            return .unavailable("Keychain unavailable (status \(other)).")
        }
    }
}
