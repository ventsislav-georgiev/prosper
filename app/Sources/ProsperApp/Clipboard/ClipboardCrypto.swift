import CryptoKit
import Foundation

/// At-rest encryption for clipboard history blobs and the index.
///
/// Clipboard contents (full text, image PNG bytes) and the index that previews
/// them are sensitive — they routinely hold passwords, tokens, and private
/// messages. They are encrypted on disk with AES-GCM (authenticated) under a
/// 256-bit key derived from the same Keychain-stored device secret that backs
/// the typing-history database (`DatabaseKey`), so no new secret is introduced
/// and the key never lands on disk in plaintext. CryptoKit ships with the OS —
/// no added dependency.
///
/// Sealed boxes are stored in CryptoKit's `combined` form (nonce ‖ ciphertext ‖
/// tag), so each blob is self-describing. `decryptOrPlaintext` migrates clips
/// written by older, unencrypted builds: if a payload doesn't authenticate as a
/// sealed box it's treated as legacy plaintext and re-encrypted on next write.
enum ClipboardCrypto {

    /// 256-bit key derived once from the Keychain device secret via SHA-256.
    /// Computed lazily so the Keychain isn't touched until the first clip.
    private static let key: SymmetricKey = {
        let secret = (try? DatabaseKey.fetchOrCreate()) ?? ""
        let digest = SHA256.hash(data: Data(secret.utf8))
        return SymmetricKey(data: digest)
    }()

    /// Encrypts `plaintext` into a self-contained sealed box (nonce ‖ ct ‖ tag).
    static func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return combined
    }

    /// Decrypts a sealed box produced by `encrypt`. Throws if tampered/wrong key.
    static func decrypt(_ ciphertext: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    /// Returns decrypted bytes, or — for blobs written by a pre-encryption build
    /// that fail to authenticate as a sealed box — the bytes unchanged. Lets old
    /// histories keep working; the next write re-persists them encrypted.
    static func decryptOrPlaintext(_ data: Data) -> Data {
        (try? decrypt(data)) ?? data
    }
}
