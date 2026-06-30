// Top processes via the `top` CLI, with an Activity-Monitor-style Energy Impact.
//
// libproc (proc_pid_rusage / PROC_PIDTASKINFO) returns EPERM for processes owned
// by another user, so a non-root app silently drops every root-owned daemon —
// exactly the ones that spike CPU/wakeups (WindowServer, kernel_task, the security
// agent). `top` is the only public source that reports per-process CPU AND idle
// wakeups for ALL users without elevation (Activity Monitor / exelban-Stats use it
// the same way).
//
// Run in delta mode (`-l 2`): the FIRST frame's %CPU is the average since each
// process launched; the SECOND frame is the real rate over the sample interval.
// We parse the last frame only. top blocks for that interval (~1 s), so refresh()
// runs it on a private queue and the poller reads the cached result — one tick of
// lag, never a stall. Coalesced: a refresh while one is in flight is a no-op.
//
// ENERGY IMPACT. Activity Monitor's "Energy" number is not %CPU — it's a weighted
// score (weights live in /usr/share/pmenergy/Mac-<board>.plist). On Apple Silicon
// the two terms that dominate and that we can read per-process unprivileged are:
//     energy = 100·(kcpu_time·cpu_fraction + kcpu_wakeups·idle_wakeups_per_sec)
// with the standard weights kcpu_time = 1, kcpu_wakeups = 0.0002 (so the displayed
// value is cpu% + 0.02·wakeups/s). That wakeups term is exactly what top's own
// POWER column omits — which is why POWER ≈ %CPU and looked like CPU. We compute
// it ourselves: top's IDLEW is a cumulative counter, so we diff it across refreshes
// to get a per-second rate.
// ponytail: GPU/disk/network weights from the plist are ~0 (or unavailable per
// process via top), so we skip them; CPU + wakeups is what Activity Monitor's
// number is dominated by in practice. Wire the plist + extra columns only if a
// model needs the GPU term.
//
// COMMAND is the LAST -stats column so a process name with spaces ("Google
// Chrome") parses cleanly — the leading tokens are fixed, the rest is the name.
//
// ponytail: top's text layout is stable in practice but not contractual. Parsing
// is defensive — malformed rows are skipped and an empty parse leaves the previous
// cache intact rather than blanking the UI.

import Foundation

public final class TopProcessReader {
    private let queue = DispatchQueue(label: "com.prosper.stats.top", qos: .utility)
    private let lock = NSLock()
    private var cached: [ProcInfo] = []
    private var running = false
    // Energy Impact needs Δwakeups/Δt; IDLEW from top is cumulative, so remember
    // the previous reading per pid and the wall time of that sample.
    private var prevWake: [Int32: Double] = [:]
    private var prevTime: Double = 0
    private let now: () -> Double
    /// Fired (on the reader's queue) the moment a fresh non-empty result is cached,
    /// so the poller can deliver it immediately instead of waiting for its next tick.
    public var onUpdate: (() -> Void)?

    // Standard Activity Monitor energy weights (default.plist; identical across the
    // per-model plists for these two terms). Displayed value = 100 × rate.
    static let kCPU = 1.0
    static let kWakeups = 0.0002

    public init(now: @escaping () -> Double = NetworkReader.monotonicSeconds) { self.now = now }

    public func latest() -> [ProcInfo] { lock.withLock { cached } }

    /// One cumulative row straight from top, before the wakeup-rate is known.
    struct Raw { let pid: Int32; let name: String; let cpu: Double; let wakeups: Double }

    /// Kick a refresh unless one is already running. Returns immediately.
    public func refresh(limit: Int = 5) {
        let go: Bool = lock.withLock { if running { return false }; running = true; return true }
        guard go else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let raw = Self.run(limit: limit)
            let rows = self.computeEnergy(raw, limit: limit)
            self.lock.withLock {
                if !rows.isEmpty { self.cached = rows }
                self.running = false
            }
            if !rows.isEmpty { self.onUpdate?() }
        }
    }

    /// Convert cumulative top rows into ProcInfo with a per-second energy-impact
    /// score. Pure aside from the monotonic clock — diffs IDLEW against the prior
    /// sample. The first call has no baseline, so the wakeups term is 0 that tick
    /// (energy == cpu%) and fills in from the next refresh on.
    private func computeEnergy(_ raw: [Raw], limit: Int) -> [ProcInfo] {
        guard !raw.isEmpty else { return [] }
        let t = now()
        let dt = prevTime > 0 ? max(0.001, t - prevTime) : 0
        var out: [ProcInfo] = []
        for r in raw {
            let wkRate = dt > 0 ? max(0, (r.wakeups - (prevWake[r.pid] ?? r.wakeups)) / dt) : 0
            let energy = Self.kCPU * (r.cpu * 100) + Self.kWakeups * 100 * wkRate
            out.append(ProcInfo(pid: r.pid, name: r.name, cpu: r.cpu, memory: 0, power: energy))
        }
        prevWake = Dictionary(raw.map { ($0.pid, $0.wakeups) }, uniquingKeysWith: { a, _ in a })
        prevTime = t
        // top already ranked the window by cpu; keep that order for the CPU list.
        // The poller re-sorts by `power` for the battery (energy) list.
        return Array(out.prefix(limit))
    }

    static func run(limit: Int) -> [Raw] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        // -n caps rows top itself ranks (by cpu); headroom over `limit` so the
        // sort below is stable. IDLEW = idle-wakeup counter (cumulative).
        p.arguments = ["-l", "2", "-o", "cpu", "-n", "\(max(limit, 5) + 3)",
                       "-stats", "pid,cpu,idlew,command"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }

        // Watchdog: top blocks ~1 s by design (the -l 2 interval), but a wedged box
        // could hang it. Kill after 5 s so a stuck process can't freeze refresh()
        // forever (running would stay true and coalesce every future refresh away).
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text, limit: limit)
    }

    /// Parse `top -l 2` output into cumulative per-process rows. Pure (no I/O).
    static func parse(_ text: String, limit: Int) -> [Raw] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // The 2nd (delta) frame begins at the LAST "PID …" header line; rows follow it.
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [] }

        var out: [Raw] = []
        for line in lines[(header + 1)...] {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 4,
                  let pid = Int32(cols[0]), pid > 0,
                  let pct = Double(cols[1]) else { continue }
            // IDLEW carries a trailing +/-/* delta marker ("94274+") — keep digits only.
            let wakeups = Double(cols[2].filter(\.isNumber)) ?? 0
            // COMMAND is everything after pid+cpu+idlew — rejoined so spaced names survive.
            let name = cols[3...].joined(separator: " ")
            guard !name.isEmpty else { continue }
            // top reports %CPU as percent of ONE core (can exceed 100 for multi-thread);
            // ProcInfo.cpu is core-seconds/sec, so /100.
            out.append(Raw(pid: pid, name: name, cpu: max(0, pct / 100), wakeups: max(0, wakeups)))
        }
        return Array(out.prefix(limit))
    }
}
