import Foundation

/// Base URL of the Prosper backend (the Cloudflare Worker in `server/`).
///
/// Set `productionURL` to your deployed `workers.dev` (or custom-domain) URL
/// after the first `wrangler deploy`. For local development against
/// `wrangler dev`, export `PROSPER_SERVER_URL=http://127.0.0.1:8787`.
enum ProsperServer {
    private static let productionURL = "https://prosper.illegible.eu"

    static var baseURL: URL {
        if let override = ProcessInfo.processInfo.environment["PROSPER_SERVER_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: productionURL)!
    }

    /// `true` until the placeholder above is replaced and no override is set —
    /// lets the UI hide account features rather than hit a dead host.
    static var isConfigured: Bool {
        baseURL.host != "prosper-server.example.workers.dev"
    }
}
