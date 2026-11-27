import Foundation
import Security

/// #871: where ccpool account tokens live. The live store is the Keychain; tests use
/// `CCPoolMemorySecrets`. No implementation logs, prints or describes a token.
protocol CCPoolSecrets: Sendable {
    func store(token: String, id: String, label: String) throws
    func token(id: String) throws -> String?
    func remove(id: String) throws
    /// #1326 (a): rename the item `id` to `label` (shown as `CCPoolKeychainSecrets.itemLabel`); the token is untouched.
    func relabel(id: String, label: String) throws
    /// #2007 r2 (QA R2007 F2): write `token` and `label` over the existing item `id`; throws when there is none and never
    /// creates one, so a write that lands after the account was removed leaves no item behind.
    func replace(token: String, id: String, label: String) throws
}

extension CCPoolSecrets {
    // shortcut: check-then-store is not atomic, fine for the test doubles; the Keychain type overrides it with SecItemUpdate
    func replace(token: String, id: String, label: String) throws {
        guard try self.token(id: id) != nil else { throw CCPoolSecretsError.failed(errSecItemNotFound) }
        try store(token: token, id: id, label: label)
    }
}

enum CCPoolSecretsError: Error, Equatable, CustomStringConvertible {
    /// No keychain-access-groups entitlement (swift build, self-signed build).
    case unavailable
    case failed(OSStatus)

    var description: String {
        switch self {
        case .unavailable: return "Keychain unavailable: this build has no keychain entitlement"
        case .failed(let s): return "Keychain error \(s)"
        }
    }
}

/// In-memory store for tests and previews.
final class CCPoolMemorySecrets: CCPoolSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var labels: [String: String] = [:]
    private var _refuseStore = false, _refuseRemove = false, _refuseRelabel = false

    /// Test switches: the next stores / removes throw like a Keychain error, and change nothing.
    var refuseStore: Bool {
        get { lock.withLock { _refuseStore } }
        set { lock.withLock { _refuseStore = newValue } }
    }
    var refuseRemove: Bool {
        get { lock.withLock { _refuseRemove } }
        set { lock.withLock { _refuseRemove = newValue } }
    }
    var refuseRelabel: Bool {
        get { lock.withLock { _refuseRelabel } }
        set { lock.withLock { _refuseRelabel = newValue } }
    }
    /// The label item `id` was last stored or relabelled with.
    func label(id: String) -> String? { lock.withLock { labels[id] } }

    func store(token: String, id: String, label: String) throws {
        try lock.withLock {
            if _refuseStore { throw CCPoolSecretsError.failed(errSecIO) }
            items[id] = token
            labels[id] = label
        }
    }
    func token(id: String) throws -> String? { lock.withLock { items[id] } }
    func remove(id: String) throws {
        try lock.withLock {
            if _refuseRemove { throw CCPoolSecretsError.failed(errSecIO) }
            items.removeValue(forKey: id)
            labels.removeValue(forKey: id)
        }
    }
    func relabel(id: String, label: String) throws {
        try lock.withLock {
            if _refuseRelabel || items[id] == nil { throw CCPoolSecretsError.failed(errSecItemNotFound) }
            labels[id] = label
        }
    }
    var count: Int { lock.withLock { items.count } }
}

/// One generic-password item per account in the data-protection keychain, the same keychain kind and
/// default access group as `SyncKeyStore` (the keychain-access-groups entitlement Prosper already
/// carries), but per Mac: not synchronizable, this-device-only. See work/871/report.txt section 1.
struct CCPoolKeychainSecrets: CCPoolSecrets {
    static let service = "eu.illegible.prosper.ccpool"

    static func baseQuery(id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func addQuery(id: String, label: String, token: Data) -> [String: Any] {
        var q = baseQuery(id: id)
        q[kSecAttrLabel as String] = itemLabel(label)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecValueData as String] = token
        return q
    }

    /// The name Keychain Access shows for an account's item.
    static func itemLabel(_ label: String) -> String { "Prosper ccpool: \(label)" }

    static func readQuery(id: String) -> [String: Any] {
        var q = baseQuery(id: id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return q
    }

    static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess, errSecItemNotFound: return
        case errSecMissingEntitlement: throw CCPoolSecretsError.unavailable
        default: throw CCPoolSecretsError.failed(status)
        }
    }

    func store(token: String, id: String, label: String) throws {
        let add = Self.addQuery(id: id, label: label, token: Data(token.utf8))
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                         kSecAttrLabel as String: Self.itemLabel(label)]
            status = SecItemUpdate(Self.baseQuery(id: id) as CFDictionary, update as CFDictionary)
        }
        if status == errSecItemNotFound { throw CCPoolSecretsError.failed(status) }
        try Self.check(status)
    }

    func token(id: String) throws -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery(id: id) as CFDictionary, &out)
        try Self.check(status)
        return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    func remove(id: String) throws {
        try Self.check(SecItemDelete(Self.baseQuery(id: id) as CFDictionary))
    }

    func replace(token: String, id: String, label: String) throws {
        let update: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrLabel as String: Self.itemLabel(label)]
        let status = SecItemUpdate(Self.baseQuery(id: id) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { throw CCPoolSecretsError.failed(status) }
        try Self.check(status)
    }

    func relabel(id: String, label: String) throws {
        let update: [String: Any] = [kSecAttrLabel as String: Self.itemLabel(label)]
        let status = SecItemUpdate(Self.baseQuery(id: id) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { throw CCPoolSecretsError.failed(status) }
        try Self.check(status)
    }
}
