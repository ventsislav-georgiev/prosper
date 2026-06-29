// Top processes by CPU via the `top` CLI.
//
// libproc (proc_pid_rusage / PROC_PIDTASKINFO) returns EPERM for processes owned
// by another user, so a non-root app silently drops every root-owned daemon —
// exactly the ones that spike CPU (mds, kernel_task, the security agent). `top`
// is the only public source that reports per-process CPU for ALL users without
// elevation (Activity Monitor / exelban-Stats use it the same way).
//
// Run in delta mode (`-l 2`): the FIRST frame's %CPU is the average since each
// process launched; the SECOND frame is the real rate over the sample interval.
// We parse the last frame only. top blocks for that interval (~1 s), so refresh()
// runs it on a private queue and the poller reads the cached result — one tick of
// lag, never a stall. Coalesced: a refresh while one is in flight is a no-op.
//
// COMMAND is the LAST -stats column so a process name with spaces ("Google
// Chrome") parses cleanly — pid/cpu are fixed leading tokens, the rest is the name.
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

    public init() {}

    public func latest() -> [ProcInfo] { lock.withLock { cached } }

    /// Kick a refresh unless one is already running. Returns immediately.
    public func refresh(limit: Int = 5) {
        let go: Bool = lock.withLock { if running { return false }; running = true; return true }
        guard go else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let rows = Self.run(limit: limit)
            self.lock.withLock {
                if !rows.isEmpty { self.cached = rows }
                self.running = false
            }
        }
    }

    static func run(limit: Int) -> [ProcInfo] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        // -n caps rows top itself ranks (by cpu); a little headroom over `limit` so the
        // sort below is stable. -stats keeps the output narrow (pid,cpu,command only).
        p.arguments = ["-l", "2", "-o", "cpu", "-n", "\(max(limit, 5) + 3)",
                       "-stats", "pid,cpu,command"]
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

    /// Parse `top -l 2` output into per-process CPU rates. Pure (no I/O) for testing.
    static func parse(_ text: String, limit: Int) -> [ProcInfo] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // The 2nd (delta) frame begins at the LAST "PID …" header line; rows follow it.
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [] }

        var out: [ProcInfo] = []
        for line in lines[(header + 1)...] {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 3,
                  let pid = Int32(cols[0]), pid > 0,
                  let pct = Double(cols[1]) else { continue }
            // COMMAND is everything after pid+cpu — rejoined so spaced names survive.
            let name = cols[2...].joined(separator: " ")
            guard !name.isEmpty else { continue }
            // top reports %CPU as percent of ONE core (can exceed 100 for multi-thread);
            // ProcInfo.cpu is core-seconds/sec, so /100. memory unused on the CPU list.
            out.append(ProcInfo(pid: pid, name: name, cpu: max(0, pct / 100), memory: 0))
        }
        return Array(out.sorted { $0.cpu > $1.cpu }.prefix(limit))
    }
}
