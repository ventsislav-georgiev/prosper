import Foundation

/// Opt-out usage analytics driver. Sends one `daily_snapshot` event to Aptabase
/// (EU cloud) at most once per 24h. Everything is gated on `Preferences.analyticsEnabled`
/// (default ON); when off we never send.
///
/// We POST the Aptabase event ourselves instead of going through the SDK. The SDK
/// stamps "sent" the moment it enqueues, then flushes on a 60s in-memory timer with
/// no success signal and no cross-launch persistence — so an offline send is lost
/// AND the 24h gate advances, skipping that day entirely. By sending ourselves we
/// only stamp `lastSent` after a confirmed delivery: offline → not stamped → retried
/// on the next hourly tick → sent once online, and the next send is 24h after that
/// actual delivery. (Aptabase event schema mirrors aptabase-swift's EventDispatcher.)
@MainActor
final class AnalyticsService {
    static let shared = AnalyticsService()

    /// Aptabase cloud app key (EU region routed from the `A-EU-` prefix below).
    private static let appKey = "A-EU-3462248518"

    private var timer: Timer?
    private var sending = false

    /// Source of the live extension registry. A daily snapshot is only complete once
    /// the registry has loaded (its extension counts + per-system usage are part of
    /// the payload). If it's still nil we DELAY the send rather than ship a partial
    /// snapshot — the hourly tick retries, and `lastSent` isn't stamped, so no day is
    /// skipped. Set on launch (`AppDelegate`); seam kept overridable for tests.
    var registryProvider: () -> ExtensionRegistry? = { SettingsHooks.shared.extensionRegistry }

    private init() {}

    /// Call from `applicationDidFinishLaunching`. Idempotent — also re-callable when
    /// the user flips the toggle back on. No-op while analytics are disabled.
    func start() {
        guard Preferences.analyticsEnabled else { return }
        // App is designed to never shut off → poll hourly, send only when ≥24h
        // elapsed (or when a prior send failed and never stamped). Survives
        // sleep/clock drift better than one 24h fire.
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in self.maybeSend() }
        }
        timer = t
        // First check shortly after launch so a fresh install reports day one.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self.maybeSend()
        }
    }

    /// Send the snapshot if enabled and ≥24h since the last *confirmed* send.
    func maybeSend() {
        if let last = AnalyticsStore.lastSent, Date().timeIntervalSince(last) < 86_400 { return }
        send()
    }

    /// Force a send now (ignores the 24h gate) — backs the Analytics "Send now"
    /// button. Returns true on confirmed delivery. Still no-op while disabled or a
    /// send is already in flight.
    @discardableResult
    func sendNow() async -> Bool {
        guard Preferences.analyticsEnabled, !sending else { return false }
        // Registry not loaded yet → no confirmed data; the caller retries.
        guard let registry = registryProvider() else { return false }
        sending = true
        defer { sending = false }
        let ok = await Self.post(props: AnalyticsSnapshot.build(registry: registry))
        if ok { AnalyticsStore.lastSent = Date() }
        return ok
    }

    private func send() {
        guard Preferences.analyticsEnabled, !sending else { return }
        // Registry not loaded yet → delay; the hourly tick retries, lastSent unstamped.
        guard let registry = registryProvider() else { return }
        sending = true
        let props = AnalyticsSnapshot.build(registry: registry)
        Task { @MainActor in
            defer { sending = false }
            // Stamp only on confirmed delivery (2xx) or permanent rejection (4xx —
            // e.g. bad key/payload; retrying daily won't fix it). Network errors and
            // 5xx leave `lastSent` untouched so the next hourly tick retries.
            if await Self.post(props: props) { AnalyticsStore.lastSent = Date() }
        }
    }

    // MARK: - Aptabase POST

    /// EU/US/self-host base URL from the app-key region prefix (we use EU).
    private static var baseURL: String {
        let region = appKey.split(separator: "-").dropFirst().first.map(String.init) ?? ""
        switch region {
        case "US": return "https://us.aptabase.com"
        case "EU": return "https://eu.aptabase.com"
        default:   return "https://eu.aptabase.com"
        }
    }

    /// POST a single event. Returns true when the snapshot was accepted (or
    /// permanently rejected — no point retrying), false on a retryable failure.
    private static func post(props: [String: Any]) async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/v0/events") else { return false }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let info = Bundle.main.infoDictionary
        let event: [String: Any] = [
            "timestamp": iso8601.string(from: Date()),
            "sessionId": UUID().uuidString.lowercased(),   // daily ping, fresh session
            "eventName": "daily_snapshot",
            "systemProps": [
                "isDebug": isDebug,
                "locale": Locale.current.language.languageCode?.identifier ?? "",
                "osName": "macOS",
                "osVersion": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
                "appBuildNumber": info?["CFBundleVersion"] as? String ?? "",
                "sdkVersion": "prosper@1",
                "deviceModel": deviceModel,
            ],
            "props": props,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: [event]) else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(appKey, forHTTPHeaderField: "App-Key")
        req.timeoutInterval = 30
        req.httpBody = body
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return code < 500   // 2xx ok, 4xx permanent (don't retry); 5xx/network → retry
        } catch {
            return false        // offline / DNS / timeout → retry next tick
        }
    }

    private static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Coarse hardware class (e.g. "Mac15,3") — shared by millions of units, not
    /// identifying; matches what aptabase-swift sent before.
    private static var deviceModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private static let iso8601: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
