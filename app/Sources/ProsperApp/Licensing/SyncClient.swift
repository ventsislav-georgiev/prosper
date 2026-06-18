import Foundation

/// Transport for cross-device settings sync against `GET/PUT /sync`.
///
/// This layer is deliberately payload-agnostic: it moves an opaque, **encrypted**
/// blob with optimistic concurrency. *What* goes in the blob (which preferences,
/// quicklinks, etc.) is the app's concern — collect it into `Data`, hand it here,
/// and on pull decrypt + apply. The blob is AES-GCM-encrypted client-side via
/// `SyncCrypto` before it ever leaves the machine, keeping sync consistent with
/// Prosper's "nothing readable leaves your Mac" posture (the server stores only
/// ciphertext + a version number).
///
/// Concurrency is optimistic: the caller tracks the last-seen `version` and sends
/// it as `base_version`. On a version mismatch the server returns `.conflict`
/// with its current state so the caller can merge and retry.
@MainActor
final class SyncClient {
    static let shared = SyncClient()
    private init() {}

    struct Snapshot: Sendable {
        let version: Int
        let plaintext: Data?   // decrypted blob, or nil if none/unreadable
    }

    enum PushResult: Sendable {
        case ok(version: Int)
        case conflict(Snapshot)
        case unauthorized
        case failed
    }

    /// Fetch and decrypt the current server blob.
    func pull() async -> Snapshot? {
        guard let creds = SupporterStore.load() else { return nil }
        guard let (data, code) = try? await req("GET", session: creds.session, body: nil),
              code < 300,
              let resp = try? JSONDecoder().decode(SyncResponse.self, from: data) else { return nil }
        return Snapshot(version: resp.version, plaintext: decode(resp.blob))
    }

    /// Encrypt and upload `plaintext`, expecting the server to still be at
    /// `baseVersion`. Returns the new version, a conflict snapshot, or a failure.
    func push(_ plaintext: Data, baseVersion: Int) async -> PushResult {
        guard let creds = SupporterStore.load() else { return .unauthorized }
        guard let sealed = SyncCrypto.encrypt(plaintext) else { return .failed }
        let body = try? JSONSerialization.data(withJSONObject: [
            "base_version": baseVersion,
            "blob": sealed.base64EncodedString(),
        ])
        guard let (data, code) = try? await req("PUT", session: creds.session, body: body) else {
            return .failed
        }
        switch code {
        case 200..<300:
            let v = (try? JSONDecoder().decode(PutResponse.self, from: data))?.version ?? baseVersion + 1
            return .ok(version: v)
        case 409:
            guard let resp = try? JSONDecoder().decode(SyncResponse.self, from: data) else { return .failed }
            return .conflict(Snapshot(version: resp.version, plaintext: decode(resp.blob)))
        case 401:
            return .unauthorized
        default:
            return .failed
        }
    }

    // MARK: - Helpers

    private func decode(_ blob: String?) -> Data? {
        guard let blob, let sealed = Data(base64Encoded: blob) else { return nil }
        return SyncCrypto.decrypt(sealed)
    }

    private func req(_ method: String, session: String, body: Data?) async throws -> (Data, Int) {
        var r = URLRequest(url: ProsperServer.baseURL.appending(path: "/sync"))
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

private struct SyncResponse: Codable {
    let version: Int
    let blob: String?
    let updated_at: Int
}
private struct PutResponse: Codable {
    let version: Int
    let updated_at: Int
}
