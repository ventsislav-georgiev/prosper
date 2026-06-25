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

    /// Lemon Squeezy pay-what-you-want checkout. Override with `PROSPER_CHECKOUT_URL`.
    static var checkoutURL: URL {
        if let override = ProcessInfo.processInfo.environment["PROSPER_CHECKOUT_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://getprosper.lemonsqueezy.com/checkout/buy/57a9d7e3-f288-43ad-ae0c-a089e71b75d1?discount=0")!
    }

    /// GitHub Sponsors page (0% fee, recurring tiers). Override with `PROSPER_SPONSORS_URL`.
    static var sponsorsURL: URL {
        if let override = ProcessInfo.processInfo.environment["PROSPER_SPONSORS_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "https://github.com/sponsors/ventsislav-georgiev")!
    }
}
