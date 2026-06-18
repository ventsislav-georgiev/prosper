import Foundation

/// Single source of truth for the user's status. Every feature in Prosper is
/// free — this exists only to reflect whether the user is a **supporter** (they
/// chipped in), which lights up a badge and lists their name in the About pane.
///
/// **Fails open**: unknown / expired / unverifiable token ⇒ `.free`. The app must
/// never hard-stop because the server was unreachable.
@MainActor
final class Entitlements: ObservableObject {
    static let shared = Entitlements()

    enum Status: String, Sendable { case free, supporter }

    @Published private(set) var status: Status = .free
    @Published var email: String?
    @Published private(set) var expiry: Date?

    var isSupporter: Bool { status == .supporter }

    private init() {}

    /// Load the cached supporter token (if any) and apply it. Call at launch.
    func refreshFromCache() {
        guard let creds = SupporterStore.load() else { apply(nil); return }
        email = creds.email
        apply(SupporterToken.verify(creds.token))
    }

    /// Apply verified claims (or `nil` → free). Keeps the published status in sync.
    func apply(_ claims: SupporterClaims?) {
        guard let claims else {
            status = .free
            expiry = nil
            return
        }
        status = Status(rawValue: claims.status) ?? .free
        expiry = claims.expiry
    }

    /// Drop all entitlement state (sign-out / account deletion).
    func reset() {
        status = .free
        email = nil
        expiry = nil
    }
}
