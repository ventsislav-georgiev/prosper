import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import LidHelperProtocol

// IOKit/network side of remote-wake — everything RemoteWakeCore injects as a
// side effect. Mirrors the validated feasibility spike (darkcheck.swift):
// register an IOPMConnection observer so powerd hands us CPU on each dark wake,
// hold the wake window with a PreventSystemSleep assertion, run one bounded GET,
// and let the pure core decide promote-vs-sleep. All core access is serialized
// on the daemon's queue `q`; the IOPMConnection callback hops onto it.
//
// ponytail: uses the public kIOPMAssertionTypePreventSystemSleep to hold the
// ~9s window — proven sufficient across the overnight run. Upgrade to the SPI
// kIOPMAssertionTypeBackgroundTask only if a future macOS shortens the window
// below the poll time.

// CFString isn't Sendable to Swift 6, but these are immutable interned literals.
private nonisolated(unsafe) let kWakeOrPowerOn = "wakepoweron" as CFString
private nonisolated(unsafe) let wakeOwner = "ProsperRemoteWake" as CFString

/// C trampoline: powerd calls this with our `self` pointer in `param`.
private func wakeTrampoline(_ param: UnsafeMutableRawPointer?,
                            _ conn: IOPMConnection?,
                            _ token: IOPMConnectionMessageToken,
                            _ caps: IOPMCapabilityBits) {
    guard let param else { return }
    Unmanaged<RemoteWakeObserver>.fromOpaque(param)
        .takeUnretainedValue()
        .handleWake(conn: conn, token: token, caps: caps)
}

final class RemoteWakeObserver: @unchecked Sendable {
    /// Root-owned config the app pushes over XPC; daemon-written ONLY.
    static let configDir = "/Library/Application Support/Prosper"
    static let configPath = "\(configDir)/remote-wake.json"

    private let q: DispatchQueue
    private var core: RemoteWakeCore!
    private var connection: IOPMConnection?
    /// Set by the daemon: invoked on `q` right after a wake promotes, so it can hold
    /// `disablesleep` open for the session that's about to connect. nil = no hook.
    var onPromote: (() -> Void)?

    init(queue: DispatchQueue) {
        self.q = queue
        self.core = RemoteWakeCore(
            schedule: { [weak self] in self?.armNextWake($0) },
            cancelAll: { [weak self] in self?.cancelOurEvents() },
            poll: { [weak self] in self?.doPoll() ?? nil },
            promote: { [weak self] in self?.promote() })
    }

    var isResident: Bool { core.isResident }

    /// Cold-launch: register the powerd observer on THIS (main) runloop, then read
    /// + apply the persisted config. The observer is registered UNCONDITIONALLY —
    /// it MUST schedule on the main runloop (a DispatchQueue worker thread has no
    /// CFRunLoop, so registering lazily from the XPC path on `q` would silently
    /// never fire). A disabled daemon registers it harmlessly for the ~10s until
    /// idle-exit; when enabled, `core.pinned` gates whether wakes do anything.
    func startFromDisk() {
        registerObserver()
        let cfg = RemoteWakeConfig.from(json: Self.readConfig())
        q.sync { _ = core.applyConfig(cfg, onAC: Self.onAC()) }
    }

    /// Live update from the app over XPC. Persists then applies. Must run on `q`.
    /// The observer is already registered (startFromDisk at launch), so this only
    /// flips the core's residency. Returns whether remote-wake is now resident.
    func apply(json: String) -> Bool {
        let cfg = RemoteWakeConfig.from(json: json)
        Self.writeConfig(cfg.enabled ? cfg.jsonString() : RemoteWakeConfig.disabled.jsonString())
        _ = core.applyConfig(cfg, onAC: Self.onAC())
        return core.isResident
    }

    // MARK: - powerd observer

    private func registerObserver() {
        guard connection == nil else { return }
        var conn: IOPMConnection?
        let interests = IOPMCapabilityBits(UInt32(kIOPMCapabilityCPU) | UInt32(kIOPMCapabilityNetwork))
        let cr = IOPMConnectionCreate("ProsperRemoteWake" as CFString, interests, &conn)
        guard cr == kIOReturnSuccess, let c = conn else {
            NSLog("RemoteWake: IOPMConnectionCreate failed 0x%x", cr)
            return
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOPMConnectionSetNotification(c, me, wakeTrampoline)
        IOPMConnectionScheduleWithRunLoop(c, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        connection = c
    }

    /// Called by powerd on each capability change. Holds the wake window, then
    /// serializes the decision on `q` (poll blocks up to ~6s; the assertion keeps
    /// the system awake across it). Acknowledge last so powerd may re-sleep.
    func handleWake(conn: IOPMConnection?, token: IOPMConnectionMessageToken, caps: IOPMCapabilityBits) {
        let cpu = (caps & UInt32(kIOPMCapabilityCPU)) != 0
        if cpu {
            var hold: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "ProsperRemoteWakeCheck" as CFString, &hold)
            q.sync { _ = core.onWake(onAC: Self.onAC(), battPct: Self.battPct()) }
            if hold != 0 { IOPMAssertionRelease(hold) }
        }
        if let conn { IOPMConnectionAcknowledgeEvent(conn, token) }
    }

    // MARK: - injected effects (run on `q`)

    /// Cancel every wake we scheduled so exactly one stays pending — IOPMSchedule
    /// only ADDS, so without this multi-notify + stray lineages double the cadence.
    private func cancelOurEvents() {
        guard let arr = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] else { return }
        for ev in arr where (ev["scheduledby"] as? String) == (wakeOwner as String) {
            if let t = ev["time"] as? Date {
                IOPMCancelScheduledPowerEvent(t as CFDate, wakeOwner, kWakeOrPowerOn)
            }
        }
    }

    private func armNextWake(_ secs: Double) {
        cancelOurEvents()
        let when = Date(timeIntervalSinceNow: secs) as CFDate
        let r = IOPMSchedulePowerEvent(when, wakeOwner, kWakeOrPowerOn)
        if r != kIOReturnSuccess { NSLog("RemoteWake: arm +%.0fs failed 0x%x", secs, r) }
    }

    private func promote() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("ProsperRemoteWake" as CFString, kIOPMUserActiveLocal, &id)
        NSLog("RemoteWake: promoted to full wake")
        // DeclareUserActivity only pokes the idle timer — it holds nothing. Hand off
        // to the daemon's keep-awake hold so the Mac stays up for the session instead
        // of idle/clamshell sleeping mid-command. Runs on `q` (we're inside onWake).
        onPromote?()
    }

    /// Bounded GET, 10s timeout + 1 retry. Returns the request token on a clean 200
    /// (the body, unless it's "0" = no request), else `nil` (non-200, timeout,
    /// parse-fail). The core edge-triggers on a *change* in this token.
    ///
    /// The 10s budget is deliberate: on a battery dark wake the Wi-Fi radio needs a
    /// few seconds to re-associate AND the worker round-trip alone measures ~3s, so a
    /// tight 3s timeout (the original) ALWAYS timed out → never promoted. The
    /// PreventSystemSleep assertion in handleWake holds the wake window across this, so
    /// the only cost of waiting is a little radio-on time, paid once per pending wake.
    private func doPoll() -> String? {
        guard let url = URL(string: core.config.pollURL) else { return nil }
        for attempt in 0..<2 {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "GET"
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            // The semaphore serializes the completion against the read below, but
            // Swift 6 can't prove that for captured vars — a Sendable box does.
            let out = PollResult()
            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
                out.code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if let d = data { out.body = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                sem.signal()
            }
            task.resume()
            if sem.wait(timeout: .now() + 11) == .timedOut {
                task.cancel()   // NEVER read `out` here: no signal => no happens-before, so the
                continue        // cancelled completion's late write would race the read. Retry/end.
            }
            if out.code == 200 { return out.body == "0" ? nil : out.body }  // token, or nil for "0"
            // transient (code 0 / 5xx): loop retries once, then falls through to nil
        }
        return nil
    }

    /// Box for the poll completion's two fields. Access is serialized by the
    /// semaphore (signal happens-before the wait returns), so no lock needed.
    private final class PollResult: @unchecked Sendable {
        var code = 0
        var body = ""
    }

    // MARK: - power source helpers

    static func onAC() -> Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return (IOPSGetProvidingPowerSourceType(snap)?.takeRetainedValue() as String?) == kIOPMACPowerKey
    }

    static func battPct() -> Int {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let d = IOPSGetPowerSourceDescription(snap, first)?.takeUnretainedValue() as? [String: Any],
              let cur = d[kIOPSCurrentCapacityKey as String] as? Int else { return -1 }
        return cur
    }

    // MARK: - config file (root:wheel, dir 0755 / file 0600, daemon-written only)

    static func readConfig() -> String {
        (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "{}"
    }

    static func writeConfig(_ json: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: configPath, contents: json.data(using: .utf8),
                      attributes: [.posixPermissions: 0o600])
    }
}
