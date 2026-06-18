import CryptoKit
import Foundation

/// At-rest encryption for account credentials and the settings-sync blob.
///
/// **Preferred key:** the iCloud-Keychain-synced account key (`SyncKeyStore`), so
/// the same key is present on every device and a settings blob encrypted on one
/// Mac decrypts on another (end-to-end; the server only ever stores ciphertext).
///
/// **Fallback:** the per-machine device key (`DatabaseKey`, same secret behind
/// clipboard history) — used for local, single-device round-trips until the
/// Keychain entitlement lands. A blob encrypted under the device key cannot be
/// decrypted on another machine, which is correct: cross-device sync only works
/// once the iCloud key is available.
///
/// **Envelope:** `[version:1][keySource:1][AES-GCM combined]`. The key-source byte
/// lets a device *decline* (return `nil`) a blob it can't key — e.g. a device that
/// hasn't received the iCloud key yet — instead of mis-decrypting, so the UI can
/// say "waiting for iCloud Keychain" rather than clobber data.
enum SyncCrypto {
    private static let version: UInt8 = 1
    private enum Source: UInt8 { case icloud = 0, device = 1 }

    enum KeyMode: Equatable { case icloud, deviceFallback }

    /// Which key the next `encrypt` will use, given current availability.
    static var mode: KeyMode {
        SyncKeyStore.fetchOrCreate() != nil ? .icloud : .deviceFallback
    }

    private static func deviceKey() -> SymmetricKey {
        let secret = (try? DatabaseKey.fetchOrCreate()) ?? ""
        return SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
    }

    static func encrypt(_ plaintext: Data) -> Data? {
        let source: Source
        let key: SymmetricKey
        if let icloud = SyncKeyStore.fetchOrCreate() {
            source = .icloud; key = icloud
        } else {
            source = .device; key = deviceKey()
        }
        guard let sealed = try? AES.GCM.seal(plaintext, using: key),
              let combined = sealed.combined else { return nil }
        var out = Data([version, source.rawValue])
        out.append(combined)
        return out
    }

    static func decrypt(_ blob: Data) -> Data? {
        guard blob.count > 2,
              blob[blob.startIndex] == version,
              let source = Source(rawValue: blob[blob.startIndex + 1]) else { return nil }
        let body = blob.subdata(in: (blob.startIndex + 2)..<blob.endIndex)

        let key: SymmetricKey?
        switch source {
        case .icloud: key = SyncKeyStore.fetch()                       // nil ⇒ not synced here yet
        case .device: key = hasDeviceKey ? deviceKey() : nil
        }
        guard let key, let box = try? AES.GCM.SealedBox(combined: body) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// True if a device key file already exists (so we won't create one just to fail).
    private static var hasDeviceKey: Bool {
        ((try? DatabaseKey.fetch()) ?? nil) != nil
    }
}
