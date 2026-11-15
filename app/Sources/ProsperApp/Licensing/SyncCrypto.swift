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

    /// `.unavailable`: neither key can be read, so nothing is sealed (#1287).
    enum KeyMode: Equatable { case icloud, deviceFallback, unavailable }

    /// #1287 seams (tests only): where the two keys come from. `create` is false when a
    /// blob is being opened, so a lookup never makes a key just to fail.
    typealias KeyLookup = @Sendable (_ create: Bool) -> SymmetricKey?
    private static let testKey = SymmetricKey(size: .bits256)
    private static var underTest: Bool { NSClassFromString("XCTestCase") != nil }

    /// The synced iCloud key. Under XCTest none (never the real Keychain).
    nonisolated(unsafe) static var icloudKey: KeyLookup = { create in
        if underTest { return nil }
        return create ? SyncKeyStore.fetchOrCreate() : SyncKeyStore.fetch()
    }

    /// The device key, or nil when the device secret cannot be read: there is no fallback
    /// secret, so nothing is ever sealed under a key anyone could compute. Under XCTest a
    /// random per-process key (never the operator's key file).
    nonisolated(unsafe) static var deviceKey: KeyLookup = { create in
        if underTest { return testKey }
        return deviceKey(at: DatabaseKey.keyFileURL, create: create)
    }

    /// #1293: the production body of `deviceKey`. A missing file stays missing on the open path
    /// (create false); a malformed one reads as no key and is never rewritten.
    static func deviceKey(at url: URL, create: Bool) -> SymmetricKey? {
        if !create, ((try? DatabaseKey.fetch(at: url)) ?? nil) == nil { return nil }
        return try? ClipboardCrypto.fileKey(url)
    }

    /// True only when the key file does not exist (a read that throws is not "absent"), so the
    /// first seal will create it. Under XCTest false (never the operator's file).
    nonisolated(unsafe) static var deviceKeyAbsent: @Sendable () -> Bool = {
        if underTest { return false }
        return deviceKeyAbsent(at: DatabaseKey.keyFileURL)
    }

    static func deviceKeyAbsent(at url: URL) -> Bool {
        do { return try DatabaseKey.fetch(at: url) == nil } catch { return false }
    }

    /// Which key the next `encrypt` will use, given current availability. #1293: looks, never
    /// creates (startup reads it before sync is on): an absent device file is .deviceFallback
    /// (encrypt creates it at the first seal); a malformed or unreadable one is .unavailable.
    static var mode: KeyMode {
        if icloudKey(true) != nil { return .icloud }
        return deviceKey(false) != nil || deviceKeyAbsent() ? .deviceFallback : .unavailable
    }

    /// nil when no key is available: nothing is sealed.
    static func encrypt(_ plaintext: Data) -> Data? {
        let source: Source
        let key: SymmetricKey
        if let icloud = icloudKey(true) {
            source = .icloud; key = icloud
        } else if let device = deviceKey(true) {
            source = .device; key = device
        } else { return nil }
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
        case .icloud: key = icloudKey(false)                    // nil ⇒ not synced here yet
        case .device: key = deviceKey(false)
        }
        guard let key, let box = try? AES.GCM.SealedBox(combined: body) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
