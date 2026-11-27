import Foundation
import StatsCore

/// #1859: four small commands: notify (a visible notice from the agent), stats.get (the System Stats headline numbers),
/// diagnostics (the Agent Sessions Diagnostics text, scrubbed) and updates.check (an information-only Sparkle check:
/// it never downloads or installs); #1871 updates.install (the menu's Check for Updates without UI). On demand only: no
/// observer, no poll, no timer.
@MainActor
enum ControlInfo {
    // MARK: - Seams (rows swap these; the defaults are the app's)

    static var now: () -> Date = { Date() }
    /// The last stats snapshot the poller delivered (all nil while System Stats is off).
    static var snapshot: @MainActor () -> StatsSnapshot = { StatsController.shared.store.snapshot }
    /// The Diagnostics pane's text for the window's focused transcript (an empty one while no window is open).
    static var diagnosticsText: @MainActor () -> String = {
        if let m = ControlSessions.model() { return AgentDiagnostics.text(m.transcript) }
        return AgentDiagnostics.text(prosper: AppInfo.shortVersion, dch: "", version: nil, counts: [:], errors: [])
    }
    static var probe: @MainActor () async -> AppUpdater.Probe? = { await AppUpdater.shared.probeForUpdate() }
    static var install: @MainActor () async -> AppUpdater.Install = { await AppUpdater.shared.installNow() }

    // MARK: - notify

    static let notifyGap: TimeInterval = 10
    static let titleMax = 80, bodyMax = 200
    private static var lastNotify: Date?

    /// Title and body are outside text (OutsideText.shown); the notice reads "Agent notified: title: body". One per
    /// `notifyGap` seconds: a pure timestamp check, taken only after the notice is built. One global gap: the channel has
    /// no caller identity. Not undoable (a notice cannot be taken back).
    static func notify(_ args: [String: ControlJSON]) throws -> ControlChange {
        guard case .string(let t)? = args["title"], case .string(let b)? = args["body"] else {
            throw ControlError("notify needs a title and a body")
        }
        let title = OutsideText.shown(t, max: titleMax).trimmingCharacters(in: .whitespaces)
        let body = OutsideText.shown(b, max: bodyMax).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { throw ControlError("argument 'title' is empty") }
        let at = now()
        if let last = lastNotify, at.timeIntervalSince(last) < notifyGap, at >= last {
            throw ControlError("notify is limited to one per \(Int(notifyGap)) seconds")
        }
        lastNotify = at
        return ControlChange(summary: body.isEmpty ? title : "\(title): \(body)", verb: "notified")
    }

    static func resetNotify() { lastNotify = nil }
    static func resetProbe() { lastProbe = nil }

    // MARK: - stats.get

    /// A NaN or infinite reading is null (JSON cannot carry it, and the reply would fail to encode).
    static func num(_ d: Double) -> ControlJSON { d.isFinite ? .number(d) : .null }

    /// {"cpu", "memory", "disk", "network", "gpu", "power", "battery", "temperature"}: only the modules the poller
    /// sampled. Headline numbers only: no process list, no SSID or address, no sensor names.
    static func stats() -> ControlJSON {
        let s = snapshot()
        var o: [String: ControlJSON] = [:]
        if let c = s.cpu { o["cpu"] = .object(["total": num(c.total), "loadAverage": .array(c.loadAverage.map(num)), "uptimeSeconds": num(Double(c.uptimeSeconds))]) }
        if let m = s.memory {
            o["memory"] = .object(["total": num(Double(m.total)), "used": num(Double(m.used)), "free": num(Double(m.free)),
                                   "swapUsed": num(Double(m.swapUsed)), "pressureLevel": num(Double(m.pressureLevel))])
        }
        if let d = s.disk { o["disk"] = .object(["readBytesPerSec": num(d.readBytesPerSec), "writeBytesPerSec": num(d.writeBytesPerSec)]) }
        if let n = s.network { o["network"] = .object(["uploadBytesPerSec": num(n.uploadBytesPerSec), "downloadBytesPerSec": num(n.downloadBytesPerSec)]) }
        if let g = s.gpu { o["gpu"] = .object(["utilization": num(g.utilization)]) }
        if let p = s.power { o["power"] = .object(["totalWatts": num(p.totalWatts)]) }
        if let b = s.battery {
            o["battery"] = .object(["charge": num(b.charge), "charging": .bool(b.isCharging), "pluggedIn": .bool(b.isPluggedIn),
                                    "cycles": num(Double(b.cycleCount)), "health": num(b.health)])
        }
        if let t = s.headlineTemperature(pinned: Preferences.sensorsHeadlineSensor) { o["temperature"] = num(t) }
        return .object(o)
    }

    // MARK: - diagnostics

    private static let secretShaped = try! NSRegularExpression(
        pattern: #"\b(?:sk|pk|ghp|gho|ghs|xox[a-z])[-_][A-Za-z0-9_-]{8,}|[A-Za-z0-9_+/=.-]{32,}|/Users/[^/\s]+"#)

    /// Anything key-, token- or path-shaped (a known key prefix, a 32+ character run, a home directory) becomes
    /// "[removed]". The pane holds versions, tier counts and parse-error reasons, so this is a second net.
    static func scrub(_ text: String) -> String {
        let r = NSRange(text.startIndex..., in: text)
        return secretShaped.stringByReplacingMatches(in: text, range: r, withTemplate: "[removed]")
    }

    static func diagnostics() -> ControlJSON { .object(["text": .string(scrub(diagnosticsText()))]) }

    // MARK: - updates.check

    static let probeGap: TimeInterval = 600
    private static var lastProbe: (at: Date, probe: AppUpdater.Probe)?

    /// A read, so it does not fetch the appcast on every call: within `probeGap` (10 minutes) of the last answered
    /// probe the same answer comes back with "cached": true. A failure is not kept, so a retry after going online fetches.
    /// Each real probe also makes Sparkle write its own last-check date (SULastCheckTime); left as is.
    static func updatesCheck() async throws -> ControlJSON {
        let at = now()
        var cached = false
        let p: AppUpdater.Probe
        if let last = lastProbe, at.timeIntervalSince(last.at) < probeGap, at >= last.at {
            p = last.probe
            cached = true
        } else {
            guard let fresh = await probe() else { throw ControlError("the updater is not available or a check is already running") }
            p = fresh
            if case .failed = fresh {} else { lastProbe = (now(), fresh) }
        }
        var o: [String: ControlJSON] = ["version": .string(AppInfo.shortVersion), "cached": .bool(cached)]
        switch p {
        case .upToDate: o["updateAvailable"] = .bool(false)
        case .found(let v): o["updateAvailable"] = .bool(true); o["latest"] = .string(OutsideText.shown(v, max: 32))
        case .failed(let why): throw ControlError("update check failed: \(OutsideText.shown(why, max: 200))")
        }
        return .object(o)
    }

    // MARK: - updates.install

    static let installNote = "Prosper relaunches by itself when the update is installed; read version afterwards"

    /// #1871: the menu's Check for Updates without UI. Replies at once (never waits for the relaunch, which ends the
    /// process that answers). nil change: nothing started (up to date), so no notice and no log line.
    static func updatesInstall() async throws -> (ControlJSON, ControlChange?) {
        let current = AppInfo.shortVersion
        switch await install() {
        case .off: throw ControlError("updates are off for this build (no updater or no SUFeedURL)")
        case .busy: throw ControlError("an update check or download is already running; try again when it ends")
        case .failed(let why): throw ControlError("update check failed: \(OutsideText.shown(why, max: 200))")
        case .upToDate: return (.object(["started": .bool(false), "reason": .string("up to date"), "current": .string(current)]), nil)
        case .started(let v):
            let latest = OutsideText.shown(v, max: 32)
            lastProbe = nil // the kept updates.check answer is stale once an install starts
            let o: ControlJSON = .object(["started": .bool(true), "current": .string(current), "latest": .string(latest), "note": .string(installNote)])
            return (o, ControlChange(summary: "\(current) to \(latest); Prosper relaunches by itself (no Undo)", result: o, verb: "started an update install"))
        }
    }
}

extension ControlRegistry {
    /// #1859: wired in ControlRegistry.standard().
    static func registerInfo(_ r: inout ControlRegistry) {
        r.register(.change(name: "notify", summary: "Show the person a short notice (\"Agent notified: ...\"). One per 10 seconds.", args: [
            "title": ControlArg(type: "string", required: true, summary: "at most 80 characters"),
            "body": ControlArg(type: "string", required: true, summary: "at most 200 characters; may be empty"),
        ]) { _, a in try ControlInfo.notify(a) })
        r.register(ControlCommand(name: "stats.get", summary: "System Stats headline numbers (cpu, memory, disk, network, gpu, power, battery, temperature); only the modules that are on.",
                                  args: [:], mutates: false) { _, _ in ControlInfo.stats() })
        r.register(ControlCommand(name: "diagnostics", summary: "The Agent Sessions Diagnostics text: versions, tier counts, last parse errors (secret-shaped text removed).",
                                  args: [:], mutates: false) { _, _ in ControlInfo.diagnostics() })
        r.register(ControlCommand(name: "updates.check", summary: "Ask whether a newer Prosper exists. Check only: nothing is downloaded or installed.",
                                  args: [:], mutates: false,
                                  run: { _, _ in throw ControlError("updates.check awaits its answer: send it through the control channel") },
                                  runAsync: { _, _ in try await ControlInfo.updatesCheck() }))
        // #1871: as ControlCommand.change (switch-gated in reply), but the log line and notice only when an install started.
        r.register(ControlCommand(name: "updates.install", summary: "Check for a newer Prosper and, when one exists, download and install it now; Prosper relaunches by itself. No Undo.",
                                  args: [:], mutates: true,
                                  run: { _, _ in throw ControlError("updates.install awaits its answer: send it through the control channel") },
                                  runAsync: { reg, _ in
            let (o, c) = try await ControlInfo.updatesInstall()
            if let c { reg.changes.record(command: "updates.install", summary: c.summary, verb: c.verb, undo: nil, sender: reg.sender) }
            return o
        }))
    }
}
