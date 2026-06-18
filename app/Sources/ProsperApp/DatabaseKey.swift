import CryptoKit
import Foundation
import Security

/// File-backed device secret. Backs at-rest database encryption (WS7b,
/// SQLCipher) and the clipboard-history AES-GCM key (`ClipboardCrypto`).
///
/// ## Why a file and not the Keychain
///
/// The Keychain is the obvious home, but every route is broken for a
/// self-signed, Sparkle-updated app:
///   • Data protection keychain (`kSecUseDataProtectionKeychain` +
///     `keychain-access-groups`): restricted entitlement — without a
///     provisioning profile AMFI refuses to launch the binary.
///   • Legacy keychain, default ACL: trust is pinned to the exact binary for
///     non-notarized apps → every update re-prompts.
///   • Legacy keychain, allow-any-app ACL (`security add-generic-password -A`
///     equivalent): macOS Sierra+ adds a *partition list* entry pinning the
///     creator's per-build cdhashes; the partition check runs above the ACL and
///     editing it requires the login keychain password → the recurring
///     "enter the login keychain password" dialog on every update.
///
/// So the key lives in `~/.config/prosper/device.key` (0600, directory 0700).
/// Trade-off vs the Keychain: any process running as this user can read the
/// file; protection against other users / stolen disk / at-rest (FileVault) is
/// unchanged. In exchange the keychain dialog is gone permanently.
///
/// ## Obfuscation
///
/// The file does NOT hold the key directly. It holds the key XOR-masked with
/// `SHA-256(pepper ‖ host UUID)`:
///   • `pepper` — a static string in this source file, so a copied file is
///     useless without reading the app's source.
///   • host UUID (`gethostuuid(2)`) — stable per machine, so the file is also
///     useless when exfiltrated to another machine.
/// This is obfuscation + device binding, not real secrecy against an attacker
/// who has both the file and this source on the same machine — the Keychain
/// couldn't beat that attacker either (see partition-list notes above).
///
/// NOTE: database encryption only takes effect once the GRDB build links the
/// SQLCipher C library (see `TypingHistoryStore.setupIfNeeded`); until then the
/// key is generated/stored but unused by the DB. The clipboard path uses it now.
enum DatabaseKey {
    /// 256-bit key, hex-encoded → 64 ASCII chars, the form SQLCipher expects for
    /// a raw key (`PRAGMA key`). Random bytes, never derived from user input.
    private static let keyByteCount = 32
    /// Static mask ingredient. Combined with the host UUID it makes the on-disk
    /// blob unreadable without this source AND this machine.
    private static let pepper = "prosper.device.key.v1//keep-out-of-backups"
    /// On-disk format tag — bump if the masking scheme ever changes.
    private static let fileMagic = "pdk1:"

    enum KeyError: Error { case randomFailed, persistFailed }

    /// `~/.config/prosper/device.key`
    private static var keyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/prosper/device.key")
    }

    /// Returns the existing key, or creates+stores one on first call. Hex string.
    static func fetchOrCreate() throws -> String {
        if let existing = try fetch() { return existing }
        let key = try makeRandomHexKey()
        try persist(key)
        return key
    }

    /// Reads the stored key, or nil if none exists yet (or the file was written
    /// on another machine / with another scheme — treated as absent; a fresh key
    /// is generated and old encrypted data is simply unreadable).
    static func fetch() throws -> String? {
        readKeyFile()
    }

    /// Removes the stored key (used by privacy "Delete All" if a re-key is wanted).
    static func delete() {
        try? FileManager.default.removeItem(at: keyFileURL)
    }

    // MARK: - Private

    private static func readKeyFile() -> String? {
        guard let raw = try? String(contentsOf: keyFileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(fileMagic),
              let masked = Data(base64Encoded: String(trimmed.dropFirst(fileMagic.count))),
              masked.count == keyByteCount else { return nil }
        let keyBytes = xor(Array(masked), mask())
        return keyBytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func persist(_ hexKey: String) throws {
        guard let keyBytes = bytes(fromHex: hexKey), keyBytes.count == keyByteCount else {
            throw KeyError.persistFailed
        }
        let masked = Data(xor(keyBytes, mask()))
        let payload = fileMagic + masked.base64EncodedString() + "\n"

        let dir = keyFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try payload.data(using: .utf8)?.write(to: keyFileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
    }

    /// 32-byte XOR mask: SHA-256(pepper ‖ host UUID). The host UUID
    /// (`gethostuuid(2)`) is stable for this machine and needs no permissions.
    private static func mask() -> [UInt8] {
        var uuid = [UInt8](repeating: 0, count: 16)
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        _ = gethostuuid(&uuid, &timeout)  // failure → all-zero UUID, pepper still applies
        var material = Data(pepper.utf8)
        material.append(contentsOf: uuid)
        return Array(SHA256.hash(data: material))
    }

    private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        zip(a, b).map(^)
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    private static func makeRandomHexKey() throws -> String {
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeyError.randomFailed }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
