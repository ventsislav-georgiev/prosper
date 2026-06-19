import CryptoKit
import Foundation

/// Offline verification of supporter tokens minted by the server.
///
/// Tokens are compact EdDSA (Ed25519) JWTs signed with the server's private key
/// (`server/src/jwt.ts`). The app embeds only the matching **public** key and
/// verifies entirely offline — so a previously-fetched token keeps working with
/// no network. The token's `exp` is the offline grace boundary: past it the app
/// falls back to the free tier (fail-open) until it can refresh online.
struct SupporterClaims: Codable, Sendable {
    let sub: String          // email
    let status: String       // free | supporter
    let iat: Int
    let exp: Int
    let jti: String
    let iss: String

    var expiry: Date { Date(timeIntervalSince1970: TimeInterval(exp)) }
}

enum SupporterToken {
    /// 32-byte raw Ed25519 public key, standard-base64 — printed by
    /// `server/scripts/gen-keys.mjs` as "base64 (32-byte raw, for CryptoKit)".
    private static let publicKeyBase64 = "pgh0kUr45kDiG4+30B6UULGhk6CF2uO+33uvUOWEILY="

    /// Verify signature, issuer, and expiry. Returns claims only for a valid,
    /// unexpired token; `nil` otherwise (caller treats `nil` as free tier).
    static func verify(_ jwt: String, now: Date = Date()) -> SupporterClaims? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        let signingInput = "\(parts[0]).\(parts[1])"
        guard
            let signature = b64urlDecode(String(parts[2])),
            let payload = b64urlDecode(String(parts[1])),
            let keyData = Data(base64Encoded: publicKeyBase64),
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
            publicKey.isValidSignature(signature, for: Data(signingInput.utf8)),
            let claims = try? JSONDecoder().decode(SupporterClaims.self, from: payload)
        else { return nil }

        guard claims.iss == "prosper-supporter" else { return nil }
        guard claims.expiry > now else { return nil } // expired → fall back to free
        return claims
    }

    /// Verify a detached Ed25519 signature (base64url) over `message` using the
    /// embedded public key. The marketplace signs artifact claims with the same
    /// server key that mints supporter tokens, so the same key verifies both —
    /// see `RemoteInstaller.fetchFromMarket`.
    static func verifyDetached(signatureB64URL: String, message: String) -> Bool {
        guard
            let sig = b64urlDecode(signatureB64URL),
            let keyData = Data(base64Encoded: publicKeyBase64),
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { return false }
        return publicKey.isValidSignature(sig, for: Data(message.utf8))
    }

    static func b64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }
}
