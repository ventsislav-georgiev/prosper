import Foundation

/// Validated remote-wake config. The app sends this as a JSON string over XPC;
/// the daemon decodes + `sanitized()`s it before acting. Carries the poll URL
/// (app injects the derived wake id + worker base — the daemon never sees the
/// raw device key) plus the cadence/safety knobs the user controls.
///
/// `Codable` so decode is one line; every field is re-validated in `sanitized()`
/// because the on-disk file is the trust boundary (fail-safe = disable on any
/// bad value, never act on a half-parsed config).
public struct RemoteWakeConfig: Codable, Equatable, Sendable {
    /// Schema tag — bump if the shape changes; an unknown version disables.
    public var version: Int
    public var enabled: Bool
    /// Full poll URL incl. derived wake id, e.g. `https://host/wake/<id>`.
    public var pollURL: String
    /// Dark-wake cadence in seconds, on charger / on battery.
    public var intervalAC: Double
    public var intervalBatt: Double
    /// Refuse to wake-promote on battery below this % (drain-attack cap).
    public var batteryFloor: Int

    public init(version: Int = RemoteWakeConfig.currentVersion,
                enabled: Bool,
                pollURL: String,
                intervalAC: Double,
                intervalBatt: Double,
                batteryFloor: Int) {
        self.version = version
        self.enabled = enabled
        self.pollURL = pollURL
        self.intervalAC = intervalAC
        self.intervalBatt = intervalBatt
        self.batteryFloor = batteryFloor
    }

    public static let currentVersion = 1
    /// Hosts the root daemon will poll. Defense-in-depth: even though the config
    /// arrives from the code-sign-pinned app, a tampered file can't redirect the
    /// root GET anywhere else. 127.0.0.1/localhost cover `PROSPER_SERVER_URL` dev.
    public static let allowedHosts: Set<String> = ["prosper.illegible.eu", "127.0.0.1", "localhost"]
    private static let minInterval = 5.0
    private static let maxInterval = 86400.0  // 1 day — the longest battery cadence the UI offers

    /// The disabled sentinel returned whenever validation rejects a config — the
    /// daemon treats this exactly like an explicit user-disable (idle-exit).
    public static let disabled = RemoteWakeConfig(
        version: currentVersion, enabled: false, pollURL: "",
        intervalAC: 30, intervalBatt: 300, batteryFloor: 20)

    /// Validate + clamp. Returns `disabled` (fail-safe) on any unknown version,
    /// bad URL, or non-allowlisted host so a corrupt file can never arm the daemon
    /// or point the root poll at an arbitrary host. Clamps intervals/floor in range.
    public func sanitized() -> RemoteWakeConfig {
        guard version == RemoteWakeConfig.currentVersion else { return .disabled }
        guard enabled else { return .disabled }
        guard let u = URL(string: pollURL), u.scheme == "https" || (u.scheme == "http" && (u.host == "127.0.0.1" || u.host == "localhost")),
              let host = u.host, RemoteWakeConfig.allowedHosts.contains(host) else { return .disabled }
        func clampInterval(_ v: Double) -> Double {
            min(RemoteWakeConfig.maxInterval, max(RemoteWakeConfig.minInterval, v))
        }
        return RemoteWakeConfig(
            version: version,
            enabled: true,
            pollURL: pollURL,
            intervalAC: clampInterval(intervalAC),
            intervalBatt: clampInterval(intervalBatt),
            batteryFloor: min(100, max(0, batteryFloor)))
    }

    /// Decode an XPC/file JSON string, already sanitized. Any decode failure →
    /// `disabled`, never a throw the daemon must remember to catch.
    public static func from(json: String) -> RemoteWakeConfig {
        guard let data = json.data(using: .utf8),
              let cfg = try? JSONDecoder().decode(RemoteWakeConfig.self, from: data) else {
            return .disabled
        }
        return cfg.sanitized()
    }

    /// Re-encode for the daemon to persist to its root-owned file.
    public func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// Pure, dependency-free decision core for remote-wake — the daemon side that
/// has NO IOKit, network, or process state. Mirrors `LidHelperCore`: the daemon
/// serializes every call on its private queue and injects the side effects
/// (`schedule`, `cancelAll`, `poll`, `promote`). Lives in the shared contract
/// lib so the safety-critical decisions (debounce, fail-safe-sleep, battery
/// floor, residency gating) are unit-testable without root/IOKit/launchd.
///
/// Strict isolation from `LidHelperCore`: zero shared mutable state. The ONLY
/// coupling with the lid path is in `main.swift`, which gates its idle-exit on
/// `!isResident` so an armed remote-wake daemon stays alive.
///
/// Not thread-safe by design; the caller owns serialization.
public final class RemoteWakeCore {
    /// What `onWake` did, for the daemon to log/act on.
    public enum WakeOutcome: Equatable {
        case ignored   // disabled, or collapsed by debounce — leave the armed event
        case slept     // polled, no promote → re-armed next wake
        case promoted  // server said "1" and battery floor met → declared user activity
    }
    /// What `applyConfig` decided about residency.
    public enum ConfigOutcome: Equatable {
        case armResident  // enabled → daemon stays alive + armed
        case idleExit     // disabled → daemon may idle-exit
    }

    /// Cancel-our-events then arm one wake `secs` from now (the spike's armNextWake).
    private let schedule: (Double) -> Void
    /// Cancel our pending wake(s) without re-arming.
    private let cancelAll: () -> Void
    /// Bounded GET → the current request token (an opaque per-request string), or
    /// `nil` for "no request" / any fail-safe (non-200, timeout, parse-fail, "0").
    /// The token edge-triggers: we promote only when it differs from the last one we
    /// acted on, so a request fires exactly once without the server mutating on read.
    private let poll: () -> String?
    /// Promote dark→full wake (`IOPMAssertionDeclareUserActivity`).
    private let promote: () -> Void
    private let now: () -> Date

    public private(set) var config: RemoteWakeConfig = .disabled
    /// Resident = enabled + armed + observing. Independent of XPC connection
    /// count: the daemon must survive with zero clients while remote-wake is on.
    public private(set) var pinned = false
    private var lastWakeTs = Date.distantPast
    /// The request token we last promoted on. In-memory only — the daemon stays
    /// resident across dark wakes, so this survives sleep; a daemon restart resets it,
    /// which at worst replays one already-handled wake (harmless, rare).
    private var lastWakeToken: String?

    /// Collapses powerd's multiple capability notifications per wake (CPU up, then
    /// network up, plus stray lineages) into a single check+arm.
    public let debounce: Double

    public init(schedule: @escaping (Double) -> Void,
                cancelAll: @escaping () -> Void,
                poll: @escaping () -> String?,
                promote: @escaping () -> Void,
                now: @escaping () -> Date = Date.init,
                debounce: Double = 10) {
        self.schedule = schedule
        self.cancelAll = cancelAll
        self.poll = poll
        self.promote = promote
        self.now = now
        self.debounce = debounce
    }

    public var isResident: Bool { pinned }
    public var enabled: Bool { config.enabled }

    private func interval(onAC: Bool) -> Double {
        onAC ? config.intervalAC : config.intervalBatt
    }

    /// Apply a (sanitized) config. Enabled → go resident + arm the first wake;
    /// disabled → cancel everything and report idle-exit. `onAC` picks the first
    /// interval (re-chosen power-aware on every wake).
    @discardableResult
    public func applyConfig(_ raw: RemoteWakeConfig, onAC: Bool) -> ConfigOutcome {
        config = raw.sanitized()
        if config.enabled {
            pinned = true
            schedule(interval(onAC: onAC))   // schedule cancels-before-arm
            return .armResident
        }
        pinned = false
        cancelAll()
        return .idleExit
    }

    /// Battery floor: on charger or unknown battery always allow (the floor only
    /// guards against draining a known-low battery; an unknown reading must not
    /// strand a wake the user explicitly requested).
    private func canPromote(onAC: Bool, battPct: Int) -> Bool {
        if onAC || battPct < 0 { return true }
        return battPct >= config.batteryFloor
    }

    /// powerd gave us CPU on a (dark) wake. Debounce, then (only if we could act)
    /// poll and promote-or-sleep. Always re-arms the next wake so plugging in lets a
    /// later wake promote. Stays resident after a promote so the cadence survives the
    /// next sleep.
    ///
    /// Battery floor is checked BEFORE the poll on purpose: below it a request couldn't
    /// promote anyway, so we skip the network GET (saves the radio) and leave
    /// `lastWakeToken` unchanged — when the battery recovers, the same still-pending
    /// token reads as new and promotes. The GET is a pure read; once-per-request comes
    /// from the in-memory token dedupe below, not from the server mutating state.
    ///
    /// HOT PATH — runs on every dark wake while the machine is asleep, so the
    /// *decision* (everything except the injected network `poll`) must be near-free
    /// to keep the wake window short and the radio/CPU on-time minimal. Budget:
    /// **< 1 µs/call** decision-only (the real `poll` GET dominates wall time and is
    /// bounded separately at 3 s + 1 retry). Guarded by `RemoteWakeCorePerfTests`.
    public func onWake(onAC: Bool, battPct: Int) -> WakeOutcome {
        guard pinned else { return .ignored }
        let t = now()
        if t.timeIntervalSince(lastWakeTs) < debounce { return .ignored }
        lastWakeTs = t
        defer { schedule(interval(onAC: onAC)) }   // every acted wake re-arms the next

        guard canPromote(onAC: onAC, battPct: battPct) else { return .slept }
        // Edge-trigger: promote only on a well-formed token we haven't acted on. A
        // repeat of the same token (the request still sitting in KV until TTL) must NOT
        // re-promote, or the Mac would wake itself every poll — the whole-night drain bug.
        //
        // The shape check is the captive-portal fail-safe: a hotel/airport proxy can
        // answer the GET with 200 + an HTML login page, which `poll` returns as a
        // non-nil body. Without this guard that HTML reads as a "new token" → a false
        // promote (drain) on every poll. Only the server's UUID token shape counts; any
        // other 200 body is treated as no-request (sleep), and we leave `lastWakeToken`
        // untouched so the real token still promotes once the captive network clears.
        guard let token = poll(), RemoteWakeCore.isWakeToken(token),
              token != lastWakeToken else { return .slept }
        lastWakeToken = token
        promote()
        return .promoted
    }

    /// A valid wake token is the server's `crypto.randomUUID()` — 8-4-4-4-12 lowercase
    /// hex. Dependency-free shape check (no regex alloc); runs only on the rare
    /// promote-candidate path, not the steady-state deduped wake. Rejects captive-portal
    /// HTML and any other garbage 200 body.
    static func isWakeToken(_ s: String) -> Bool {
        let u = s.utf8
        guard u.count == 36 else { return false }
        var i = 0
        for c in u {
            if i == 8 || i == 13 || i == 18 || i == 23 {
                if c != UInt8(ascii: "-") { return false }
            } else if !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {  // 0-9, a-f
                return false
            }
            i += 1
        }
        return true
    }
}
