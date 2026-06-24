import Foundation
import LidHelperProtocol

/// Drives auth + supporter status against the Prosper backend (`server/`).
///
/// Networking mirrors `AnalyticsService`: plain `URLSession` async, short
/// timeouts, and fail-open behaviour — any network failure leaves the cached
/// entitlement untouched and the app on whatever status it last verified (free if
/// none). The login flow is browser-verify + app-poll: the app emails a one-time
/// link, the user clicks it in their browser, and the app polls until the
/// session + supporter token are ready.
@MainActor
final class SupporterClient: ObservableObject {
    static let shared = SupporterClient()

    enum LoginState: Equatable {
        case idle
        case sending          // emailing the link
        case awaitingClick    // link sent, polling
        case success
        case failed(String)
    }

    @Published private(set) var loginState: LoginState = .idle
    @Published private(set) var devices: [DeviceInfo] = []

    private var pollTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Apply any cached supporter token at launch, then (best-effort, online) refresh it.
    func startup() {
        Entitlements.shared.refreshFromCache()
        guard SupporterStore.load() != nil else { return }
        Task { await refreshStatus() }
    }

    var isSignedIn: Bool { SupporterStore.load() != nil }

    // MARK: - Login (magic link + poll)

    func login(email rawEmail: String) {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        pollTask?.cancel()
        loginState = .sending
        pollTask = Task { await runLogin(email: email) }
    }

    func cancelLogin() {
        pollTask?.cancel()
        loginState = .idle
    }

    private func runLogin(email: String) async {
        guard let pickup = await startLogin(email: email) else {
            loginState = .failed("Couldn't send the sign-in email. Check your address and try again.")
            return
        }
        loginState = .awaitingClick

        let deadline = Date().addingTimeInterval(15 * 60)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            switch await poll(pickup: pickup) {
            case .pending:
                continue
            case .expired:
                loginState = .failed("The sign-in link expired. Please try again.")
                return
            case .ready(let creds):
                await finishLogin(creds)
                return
            case .error:
                continue // transient — keep polling
            }
        }
        if !Task.isCancelled { loginState = .failed("Timed out waiting for the email link.") }
    }

    private func finishLogin(_ creds: StoredCredentials) async {
        SupporterStore.save(creds)
        Entitlements.shared.email = creds.email
        Entitlements.shared.apply(SupporterToken.verify(creds.token))
        loginState = .success
        await activateDevice()
        await refreshStatus()
    }

    // MARK: - Authenticated calls

    /// Mint a fresh supporter token for the current entitlement and cache it.
    func refreshStatus() async {
        guard var creds = SupporterStore.load() else { return }
        guard let data = try? await get("/supporter", session: creds.session) else { return }
        guard let resp = try? JSONDecoder().decode(SupporterResponse.self, from: data) else { return }
        creds.token = resp.token
        SupporterStore.save(creds)
        Entitlements.shared.apply(SupporterToken.verify(resp.token))
    }

    func activateDevice() async {
        guard let creds = SupporterStore.load() else { return }
        let body: [String: Any] = ["device_id": SupporterStore.deviceID(), "name": SupporterStore.deviceName()]
        _ = try? await post("/activate", session: creds.session, json: body)
    }

    func loadDevices() async {
        guard let creds = SupporterStore.load(),
              let data = try? await get("/devices", session: creds.session),
              let resp = try? JSONDecoder().decode(DevicesResponse.self, from: data) else { return }
        devices = resp.devices
    }

    func deactivate(deviceID: String) async {
        guard let creds = SupporterStore.load() else { return }
        _ = try? await request("DELETE", "/devices/\(deviceID)", session: creds.session, body: nil)
        await loadDevices()
    }

    func deleteAccount() async {
        if let creds = SupporterStore.load() {
            _ = try? await post("/account/delete", session: creds.session, json: [:])
        }
        signOut()
    }

    func signOut() {
        pollTask?.cancel()
        // Clear the server-side wake ETA before dropping creds: we're disarming the
        // daemon below, so the machine must stop advertising a wake time, or a paired
        // device shows a wakeable ETA for a Mac that won't wake. Snapshot the session
        // NOW — it stays valid server-side until expiry, so the detached DELETE works
        // even after SupporterStore.clear() wipes it locally.
        if let session = SupporterStore.load()?.session {
            let metaURL = UserDefaults.standard.string(forKey: LiveExtensionHostServices.wakeMetaURLKey)
                .flatMap(URL.init(string:))
            let logoutURL = URL(string: ProsperServer.baseURL.appending(path: "/auth/logout").absoluteString)
            // Best-effort, detached: the session stays valid server-side until expiry,
            // so these run fine after the local clear below. Revoke the session server-side
            // (a leaked 365-day token must die at sign-out, not live to TTL) and clear the
            // wake ETA (paired device shouldn't show a wakeable Mac that just disarmed).
            Task.detached {
                if let logoutURL {
                    var req = URLRequest(url: logoutURL)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 10
                    req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
                    _ = try? await URLSession.shared.data(for: req)
                }
                if let metaURL {
                    var req = URLRequest(url: metaURL)
                    req.httpMethod = "DELETE"
                    req.timeoutInterval = 10
                    req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
                    _ = try? await URLSession.shared.data(for: req)
                }
            }
        }
        UserDefaults.standard.removeObject(forKey: LiveExtensionHostServices.wakeMetaURLKey)
        SupporterStore.clear()
        Entitlements.shared.reset()
        devices = []
        loginState = .idle
        // Remote-wake is account-scoped: its persisted poll URL embeds this account's
        // acctTag. Signed out, the daemon would poll a dead URL forever (battery) and
        // couldn't be woken anyway (no session can POST a matching acctTag). Always
        // disarm — the daemon survives app restarts (RunAtLoad), so a fresh process
        // can't tell from in-memory state whether it's still armed on the old account.
        // ponytail: user re-enables after signing in, which re-derives the URL for the
        // new account. Login can't swap accounts without signOut (AccountPane gates it).
        //
        // Route through enqueueApply, NOT a bare Task: setRemoteWake/setDisabled are
        // @MainActor with await points, so a bare disarm could run between an in-flight
        // setDisabled(true)'s awaits and invalidate the shared connection (holdsLidOverride
        // isn't set until after that op's await) — tearing down a lid override mid-apply.
        // The serial chain orders it after any in-flight daemon op.
        LidSleepHelper.enqueueApply { _ = await LidSleepHelper.setRemoteWake(.disabled) }
    }

    // MARK: - Unauthenticated auth endpoints

    private func startLogin(email: String) async -> String? {
        guard let data = try? await post("/auth/start", session: nil, json: ["email": email]),
              let resp = try? JSONDecoder().decode(StartResponse.self, from: data) else { return nil }
        return resp.pickup
    }

    private enum PollResult { case pending, expired, ready(StoredCredentials), error }

    private func poll(pickup: String) async -> PollResult {
        guard let (data, code) = try? await requestRaw("POST", "/auth/poll", session: nil,
                                                        body: jsonBody(["pickup": pickup])) else {
            return .error
        }
        if code == 410 { return .expired }
        guard code < 300, let resp = try? JSONDecoder().decode(PollResponse.self, from: data) else {
            return .error
        }
        switch resp.status {
        case "ready":
            guard let session = resp.session, let token = resp.token, let email = resp.email else {
                return .error
            }
            return .ready(StoredCredentials(email: email, session: session, token: token))
        case "expired":
            return .expired
        default:
            return .pending
        }
    }

    // MARK: - HTTP helpers

    private func get(_ path: String, session: String?) async throws -> Data {
        let (data, code) = try await requestRaw("GET", path, session: session, body: nil)
        guard code < 300 else { throw URLError(.badServerResponse) }
        return data
    }

    @discardableResult
    private func post(_ path: String, session: String?, json: [String: Any]) async throws -> Data {
        let (data, code) = try await requestRaw("POST", path, session: session, body: jsonBody(json))
        guard code < 300 else { throw URLError(.badServerResponse) }
        return data
    }

    @discardableResult
    private func request(_ method: String, _ path: String, session: String?, body: Data?) async throws -> Data {
        let (data, code) = try await requestRaw(method, path, session: session, body: body)
        guard code < 300 else { throw URLError(.badServerResponse) }
        return data
    }

    private func requestRaw(_ method: String, _ path: String, session: String?, body: Data?) async throws -> (Data, Int) {
        var req = URLRequest(url: ProsperServer.baseURL.appending(path: path))
        req.httpMethod = method
        req.timeoutInterval = 30
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let session { req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func jsonBody(_ json: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: json)
    }
}

// MARK: - Wire types

struct DeviceInfo: Codable, Identifiable, Sendable {
    let device_id: String
    let name: String?
    let activated_at: Int
    let last_seen: Int
    var id: String { device_id }
}

private struct StartResponse: Codable { let pickup: String }
private struct PollResponse: Codable {
    let status: String
    let session: String?
    let token: String?
    let email: String?
}
private struct SupporterResponse: Codable {
    let token: String
    let status: String
    let exp: Int
}
private struct DevicesResponse: Codable { let devices: [DeviceInfo] }
