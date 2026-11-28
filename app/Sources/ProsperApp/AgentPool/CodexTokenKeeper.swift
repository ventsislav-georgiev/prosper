import Foundation

/// #2007 (design #2003 section 4, Token refresh; sections 10 and 11): the one holder of each Codex login's refresh chain.
/// Refresh tokens are single-use and rotate, so per account one refresh is in flight and every other caller waits on
/// it. The new item is written to the Keychain before anyone is handed the new access token. A refused refresh token
/// signs the account out (the #1278 `refused` stamp; the pane row says "Signed out: sign in again") and is never
/// retried; a network error is not a sign-out (the next trigger tries again). Nothing here logs a token or a body.
final class CodexTokenKeeper: @unchecked Sendable {
    static let productionURL = URL(string: "https://auth.openai.com/oauth/token")!
    // shortcut: Codex's public OAuth client id; the supervisor checked it against the strings of the installed Codex
    // 0.167.2 on 2026-11-27 (codex not executed); P5 re-checks it when the Codex version changes
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Refresh when the access token's exp is this close (or past).
    static let expMargin: Double = 3600
    /// Refresh when last_refresh is older than this (Codex itself waits ~8 days).
    static let maxAge: Double = 7 * 86400
    /// At most this much of a refusal body is read.
    static let bodyCap = 4096
    /// A 4xx whose body names any of these is a dead chain (design section 11; a plan change kills it at once too).
    /// "refresh token" covers every auth detail that names it, "refresh token was already used" included.
    static let signedOutWords = ["refresh_token_reused", "invalid_refresh_token", "refresh token was already used", "invalid_grant", "refresh token"]

    enum Outcome: Equatable, Sendable {
        /// The stored item now (just refreshed, or refreshed by another caller since `stale` was read).
        case refreshed(String)
        /// The refresh token was refused, or the account is already refused: sign in again.
        case signedOut
        /// No answer (network, a 5xx, a reply without a token, a Keychain write that failed): nothing changed.
        case failed
    }

    private let store: AgentPoolStore
    private let secrets: AgentPoolSecrets
    private let url: URL
    private let log: AgentPoolLogger
    private let session: URLSession
    private let lock = NSLock()
    /// Account id -> the callers waiting on its one refresh in flight.
    private var flights: [String: [@Sendable (Outcome) -> Void]] = [:]

    init(store: AgentPoolStore, secrets: AgentPoolSecrets, url: URL, logger: AgentPoolLogger) {
        self.store = store
        self.secrets = secrets
        self.url = url
        self.log = logger
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 30
        // QA R2007 F1: a 3xx is the answer (settles as .failed); following it would re-POST the refresh token to Location.
        session = URLSession(configuration: cfg, delegate: AgentPoolNoRedirect(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Whether `c` should be refreshed before use: exp within `expMargin`, or last_refresh older than `maxAge`. A login
    /// that cannot refresh never is.
    static func due(_ c: CodexCredential, now: Double) -> Bool {
        guard c.canRefresh, now.isFinite else { return false }
        if let exp = CodexCredential.jwtExp(c.accessToken), exp - now < expMargin { return true }
        if let last = c.lastRefresh, now - last > maxAge { return true }
        return false
    }

    /// Whether a 4xx refusal body names a dead refresh chain.
    static func signsOut(status: Int, body: Data) -> Bool {
        guard (400...499).contains(status) else { return false }
        let text = String(decoding: body.prefix(bodyCap), as: UTF8.self).lowercased()
        return signedOutWords.contains { text.contains($0) }
    }

    /// Refresh account `id`'s login, or wait on the refresh already in flight. `stale` is the access token the caller
    /// saw rejected or due: a stored item that carries another one was refreshed meanwhile and is the answer, no POST.
    /// `done` runs once, on a queue of the keeper's choosing.
    func refresh(id: String, stale: String, done: @escaping @Sendable (Outcome) -> Void) {
        let key = id
        let joined = lock.withLock { () -> Bool in
            defer { flights[key, default: []].append(done) }
            return flights[key] != nil
        }
        if joined { return }
        let finish: @Sendable (Outcome) -> Void = { [self] o in
            for d in lock.withLock({ flights.removeValue(forKey: key) ?? [] }) { d(o) }
        }
        let label = store.read { st in st.label(ofID: id) }
        guard let label, let item = (try? secrets.token(id: id)) ?? nil, let cred = CodexCredential.decode(item) else {
            return finish(.failed)
        }
        if cred.accessToken != stale { return finish(.refreshed(item)) }
        if store.read({ $0.accounts[label]?.refused }) != nil { return finish(.signedOut) }
        guard cred.canRefresh, let rt = cred.refreshToken else { return finish(.failed) }
        guard !AgentPoolService.refusesUnderTest(url) else {
            log.note(label, "token refresh refused: the production auth host under XCTest")
            return finish(.failed)
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": rt, "scope": "openid profile email",
        ], options: [.sortedKeys])
        session.dataTask(with: req) { [self] data, response, error in
            finish(settle(id: id, label: label, old: cred, data: data, response: response, error: error))
        }.resume()
    }

    private func settle(id: String, label: String, old: CodexCredential, data: Data?, response: URLResponse?, error: Error?) -> Outcome {
        guard error == nil, let http = response as? HTTPURLResponse else {
            log.note(label, "token refresh failed: no answer; trying again on the next trigger")
            return .failed
        }
        let status = http.statusCode
        guard (200...299).contains(status) else {
            if Self.signsOut(status: status, body: data ?? Data()) {
                let now = store.now
                store.mutate { st in
                    if let owner = st.label(ofID: id), st.accounts[owner]?.refused == nil, now.isFinite, (0..<1e12).contains(now) {
                        st.accounts[owner]?.refused = Int(now)
                    }
                }
                log.note(label, "signed out: the refresh token was refused (status \(status)); sign in again")
                return .signedOut
            }
            log.note(label, "token refresh failed: status \(status); trying again on the next trigger")
            return .failed
        }
        guard let obj = data.flatMap({ (try? JSONSerialization.jsonObject(with: $0.prefix(1 << 20))) as? [String: Any] }),
              let access = obj["access_token"] as? String, !access.isEmpty else {
            log.note(label, "token refresh failed: the answer held no access token; trying again on the next trigger")
            return .failed
        }
        var cred = old
        cred.accessToken = access
        if let r = obj["refresh_token"] as? String, !r.isEmpty { cred.refreshToken = r }
        if let i = obj["id_token"] as? String, !i.isEmpty { cred.idToken = i }
        cred.lastRefresh = store.now
        // Written before anyone is handed the new access token: a crash in between leaves a valid stored login.
        guard let item = cred.encoded() else { return .failed }
        // QA R2007 F2: the owner as it is now. A removal during the POST writes nothing (the update-only write could not
        // re-create the item either); a rename during it keeps the new label.
        guard let owner = store.read({ $0.label(ofID: id) }) else {
            log.note(label, "token refresh dropped: account removed during refresh")
            return .failed
        }
        do { try secrets.replace(token: item, id: id, label: owner) } catch {
            log.note(owner, "token refresh failed: the new login could not be stored")
            return .failed
        }
        log.note(owner, "token refreshed")
        return .refreshed(item)
    }
}
