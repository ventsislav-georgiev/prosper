import Foundation

/// Transport for the extension marketplace (`/market/*` on the Prosper backend).
///
/// Browse + download are public; publish + yank require the stored session
/// bearer (the same credential `SyncClient` uses). Downloaded artifacts carry an
/// Ed25519 signature over a canonical claim; integrity + signature verification
/// happen in `RemoteInstaller.fetchFromMarket` before anything is extracted.
enum MarketClient {

    // MARK: - DTOs

    /// One row in a browse/search listing.
    struct Package: Codable, Sendable, Identifiable, Equatable {
        let id: String
        let title: String
        let description: String
        let author: String
        let icon: String?
        let license: String?
        let latest_version: String
        let downloads: Int
        let updated_at: Int
        let kind: String?
        let preview: ThemePreview?

        var latestVersion: String { latest_version }
        var isTheme: Bool { kind == "theme" }
    }

    /// Look-and-feel preview for theme packages: each contributed theme's flat
    /// color-token map, computed at publish and rendered as a swatch strip.
    struct ThemePreview: Codable, Sendable, Equatable {
        struct Swatch: Codable, Sendable, Equatable {
            let title: String
            let appearance: String?
            let colors: [String: String]   // token name → hex
        }
        let themes: [Swatch]
    }

    struct BrowseResult: Sendable {
        let packages: [Package]
        let cursor: Int?
    }

    /// A downloaded artifact plus its signed claim (verified by the installer).
    struct Download: Codable, Sendable {
        let id: String
        let version: String
        let sha256: String
        let signature: String
        let publisher_email: String
        let published_at: Int
        let blob: String   // base64 gzipped tarball
    }

    enum MarketError: Error, LocalizedError {
        case notSignedIn
        case http(Int, String?)
        case decode

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in to publish extensions."
            case .http(let code, let msg):
                if let msg, let friendly = MarketError.friendly[msg] { return friendly }
                return msg.map { "Marketplace error (\(code)): \($0)" } ?? "Marketplace error (\(code))."
            case .decode: return "The marketplace returned an unexpected response."
            }
        }

        /// Server `{error:"..."}` codes (market.ts) → human text.
        private static let friendly: [String: String] = [
            "rate_limited": "You're publishing too often. Try again in up to an hour.",
            "not_owner": "Another account already owns this extension id.",
            "version_exists": "That version is already published — bump the version and try again.",
            "too_large": "The extension is too large to publish (256 KB max).",
            "preview_too_large": "The theme preview is too large to publish.",
            "invalid_id": "The extension id isn't a valid reverse-DNS identifier.",
            "invalid_version": "The version isn't valid semver (e.g. 1.2.3).",
            "missing_fields": "The manifest is missing a required field (name, title, or author).",
            "system_not_allowed": "A published extension can't be marked as a system extension.",
            "not_gzip": "The uploaded artifact wasn't a valid .tar.gz.",
            "yanked": "This extension version has been withdrawn.",
        ]
    }

    // MARK: - Public reads

    static func browse(query: String = "", sort: String = "updated_at", kind: String? = nil, cursor: Int = 0) async -> BrowseResult {
        var comps = URLComponents(url: base("/market/packages"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "sort", value: sort)]
        if !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let kind { items.append(URLQueryItem(name: "kind", value: kind)) }
        if cursor > 0 { items.append(URLQueryItem(name: "cursor", value: String(cursor))) }
        comps.queryItems = items
        guard let url = comps.url,
              let (data, code) = try? await get(url), code < 300,
              let resp = try? JSONDecoder().decode(BrowseResponse.self, from: data)
        else { return BrowseResult(packages: [], cursor: nil) }
        return BrowseResult(packages: resp.packages, cursor: resp.cursor)
    }

    /// id -> latest_version for every active package (drives auto-update).
    static func index() async -> [String: String] {
        guard let (data, code) = try? await get(base("/market/index")), code < 300,
              let resp = try? JSONDecoder().decode(IndexResponse.self, from: data) else { return [:] }
        return Dictionary(resp.packages.map { ($0.id, $0.latest_version) }, uniquingKeysWith: { a, _ in a })
    }

    /// The latest published version of `id`, or nil if it was never published
    /// (404) or has been yanked. Drives the Publish/Published row UX.
    static func publishedVersion(id: String) async -> String? {
        guard let (data, code) = try? await get(base("/market/packages/\(id)")), code < 300
        else { return nil }
        struct Resp: Codable { struct Pkg: Codable { let latest_version: String; let status: String }; let package: Pkg }
        guard let p = (try? JSONDecoder().decode(Resp.self, from: data))?.package, p.status == "active"
        else { return nil }
        return p.latest_version
    }

    static func download(id: String, version: String) async throws -> Download {
        let url = base("/market/download/\(id)/\(version)")
        let (data, code) = try await get(url)
        guard code < 300 else { throw MarketError.http(code, errorText(data)) }
        guard let dl = try? JSONDecoder().decode(Download.self, from: data) else { throw MarketError.decode }
        return dl
    }

    // MARK: - Authenticated writes

    /// The manifest fields the server's `ManifestInput` accepts (re-encoded from the
    /// locally-parsed TOML). A published extension can never claim to be a system one.
    struct PublishManifest: Codable, Sendable {
        let id: String
        let name: String
        let title: String
        let description: String
        let version: String
        let author: String
        let icon: String?
        let license: String?
        let system = false
    }

    /// Publish a new package or push a new version. `blobBase64` is the base64
    /// gzipped tarball of the extension directory; `kind`/`preview` are the
    /// marketplace category + look-and-feel strip (set for theme packages).
    static func publish(manifest: PublishManifest, blobBase64: String,
                        kind: String = "extension", preview: ThemePreview? = nil) async throws {
        guard let session = SupporterStore.load()?.session else { throw MarketError.notSignedIn }
        struct Body: Codable { let manifest: PublishManifest; let blob: String; let kind: String; let preview: ThemePreview? }
        let body = try JSONEncoder().encode(Body(manifest: manifest, blob: blobBase64, kind: kind, preview: preview))
        let (data, code) = try await send("POST", path: "/market/publish", session: session, body: body)
        guard code < 300 else { throw MarketError.http(code, errorText(data)) }
    }

    static func yank(id: String) async throws {
        guard let session = SupporterStore.load()?.session else { throw MarketError.notSignedIn }
        let (data, code) = try await send("DELETE", path: "/market/packages/\(id)", session: session, body: nil)
        guard code < 300 else { throw MarketError.http(code, errorText(data)) }
    }

    // MARK: - HTTP helpers

    // appending(path:) percent-encodes the path itself (preserving "/" and ".").
    // Pass RAW id/version segments — pre-encoding them here double-encodes ("." ->
    // "%2E" -> "%252E"), which the server reads as a literal id and 404s.
    private static func base(_ path: String) -> URL { ProsperServer.baseURL.appending(path: path) }

    private static func get(_ url: URL) async throws -> (Data, Int) {
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: r)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func send(_ method: String, path: String, session: String, body: Data?) async throws -> (Data, Int) {
        var r = URLRequest(url: base(path))
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

    private static func errorText(_ data: Data) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
    }

    private struct BrowseResponse: Codable { let packages: [Package]; let cursor: Int? }
    private struct IndexResponse: Codable {
        struct Row: Codable { let id: String; let latest_version: String }
        let packages: [Row]
    }
}
