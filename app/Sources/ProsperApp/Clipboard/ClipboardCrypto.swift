import CryptoKit
import Foundation

/// At-rest encryption for clipboard history blobs and the index.
///
/// Clipboard contents (full text, image PNG bytes) and the index that previews
/// them are sensitive — they routinely hold passwords, tokens, and private
/// messages. They are encrypted on disk with AES-GCM (authenticated) under a
/// 256-bit key derived from the same device secret that backs
/// the typing-history database (`DatabaseKey`), so no new secret is introduced
/// and the key never lands on disk in plaintext. CryptoKit ships with the OS —
/// no added dependency.
///
/// Sealed boxes are stored in CryptoKit's `combined` form (nonce ‖ ciphertext ‖
/// tag), so each blob is self-describing. `decryptOrPlaintext` migrates clips
/// written by older, unencrypted builds: if a payload doesn't authenticate as a
/// sealed box it's treated as legacy plaintext and re-encrypted on next write.
enum ClipboardCrypto {

    /// #1285: where a store gets its key; throws while the device secret is unavailable.
    /// ClipboardStore asks again on its next write until one call succeeds (never pinned).
    typealias KeySource = @Sendable () throws -> SymmetricKey

    /// The default source: the device secret (DatabaseKey's file) via SHA-256.
    /// #617: under XCTest a random per-process key, so no test reads or creates the
    /// operator's device key (DatabaseKey writes it when missing).
    static let deviceKey: KeySource = {
        if NSClassFromString("XCTestCase") != nil { return ClipboardCrypto.testKey }
        return try ClipboardCrypto.fileKey(DatabaseKey.keyFileURL)
    }
    private static let testKey = SymmetricKey(size: .bits256)

    /// The key from the device secret file at `url`. #1285: a failed fetch throws; there is no
    /// fallback secret, so nothing is ever sealed under a key anyone could compute.
    static func fileKey(_ url: URL) throws -> SymmetricKey {
        let secret = try DatabaseKey.fetchOrCreate(at: url)
        return SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
    }

    /// Encrypts `plaintext` into a self-contained sealed box (nonce ‖ ct ‖ tag).
    static func encrypt(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    /// Decrypts a sealed box produced by `encrypt`. Throws if tampered/wrong key.
    static func decrypt(_ ciphertext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    /// Returns decrypted bytes, or — for blobs written by a pre-encryption build
    /// that fail to authenticate as a sealed box — the bytes unchanged. Lets old
    /// histories keep working; the next write re-persists them encrypted.
    static func decryptOrPlaintext(_ data: Data, key: SymmetricKey) -> Data {
        (try? decrypt(data, key: key)) ?? data
    }
}
