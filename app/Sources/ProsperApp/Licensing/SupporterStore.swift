import CryptoKit
import Foundation

/// Encrypted-at-rest persistence for account credentials, plus a stable device
/// identity for activation.
///
/// Credentials (the opaque session bearer + the last supporter token + email) are
/// stored in `~/.config/prosper/supporter.dat`, AES-GCM-encrypted under the shared
/// device key (`SyncCrypto`) — the same on-disk posture as clipboard history.
///
/// TODO(keychain): move credentials to the Keychain once a Developer ID +
/// keychain-access entitlement is in place. Today the Keychain route re-prompts
/// on every Sparkle update for a self-signed app (see `DatabaseKey` for the full
/// rationale), so a 0600 file under `~/.config/prosper` is the pragmatic home.
struct StoredCredentials: Codable, Sendable {
    var email: String
    var session: String
    var token: String
}

enum SupporterStore {
    private static var underTest: Bool { NSClassFromString("XCTestCase") != nil }

    /// #1297: where the credentials live. Under XCTest a per-process temporary path (never the
    /// real home; nothing is created until a row saves); a row points this at its own tempDir().
    nonisolated(unsafe) static var fileURL: URL = defaultFileURL

    /// The default location, kept apart from the seam so a row can compare it without any file access.
    static let defaultFileURL: URL = {
        if underTest {
            return FileManager.default.temporaryDirectory
                .appending(path: "prosper-supporter-\(UUID().uuidString)/supporter.dat")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/prosper/supporter.dat")
    }()

    static func load() -> StoredCredentials? {
        guard
            let blob = try? Data(contentsOf: fileURL),
            let plain = SyncCrypto.decrypt(blob),
            let creds = try? JSONDecoder().decode(StoredCredentials.self, from: plain)
        else { return nil }
        return creds
    }

    /// False when nothing was written: no key to seal under, or the write failed.
    @discardableResult
    static func save(_ creds: StoredCredentials) -> Bool {
        guard
            let plain = try? JSONEncoder().encode(creds),
            let blob = SyncCrypto.encrypt(plain)
        else { return false }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard (try? blob.write(to: fileURL, options: [.atomic])) != nil else { return false }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return true
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Stable per-machine device id (hex of SHA-256 over the host UUID). No file,
    /// survives reinstall, and is not personally identifying on its own.
    static func deviceID() -> String {
        var uuid = [UInt8](repeating: 0, count: 16)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        _ = gethostuuid(&uuid, &timeout)
        return SHA256.hash(data: Data(uuid)).map { String(format: "%02x", $0) }.joined()
    }

    static func deviceName() -> String {
        Host.current().localizedName ?? "Mac"
    }
}
