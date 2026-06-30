// Per-process network throughput via `nettop`.
//
// nettop is the only public source of per-PID byte counts on macOS. We run it in
// delta mode (`-d -L 2`): the second sample block is bytes transferred over the
// ~1 s interval, i.e. bytes/sec. nettop blocks for that interval, so refresh()
// runs it on a private queue and the poller reads the cached result (one tick of
// lag, never a stall). Coalesced: a refresh while one is in flight is a no-op.
//
// ponytail: nettop's text layout is stable in practice but not contractual — a
// future macOS could reshape it. Parsing is defensive: malformed rows are skipped
// and an empty parse leaves the previous cache intact rather than blanking the UI.

import Foundation

public struct NetProcInfo: Sendable, Equatable {
    public let pid: Int32
    public let name: String
    public let downBytesPerSec: Double
    public let upBytesPerSec: Double
    public init(pid: Int32, name: String, downBytesPerSec: Double, upBytesPerSec: Double) {
        self.pid = pid; self.name = name
        self.downBytesPerSec = downBytesPerSec; self.upBytesPerSec = upBytesPerSec
    }
}

public final class NetProcessReader {
    private let queue = DispatchQueue(label: "com.prosper.stats.nettop", qos: .utility)
    private let lock = NSLock()
    private var cached: [NetProcInfo] = []
    private var running = false
    /// Fired (on the reader's queue) the moment a fresh non-empty result is cached,
    /// so the poller can deliver it immediately instead of waiting for its next tick.
    public var onUpdate: (() -> Void)?

    public init() {}

    public func latest() -> [NetProcInfo] { lock.withLock { cached } }

    /// Kick a refresh unless one is already running. Returns immediately.
    public func refresh(limit: Int = 8) {
        let go: Bool = lock.withLock { if running { return false }; running = true; return true }
        guard go else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let rows = Self.run(limit: limit)
            self.lock.withLock {
                if !rows.isEmpty { self.cached = rows }
                self.running = false
            }
            if !rows.isEmpty { self.onUpdate?() }
        }
    }

    static func run(limit: Int) -> [NetProcInfo] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-L", "2", "-d", "-x", "-J", "bytes_in,bytes_out", "-t", "external"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }

        // Watchdog: nettop is usually ~0.2–1 s, but a cold/contended run (DNS/route
        // resolution, many live flows behind a VPN) can take ~5 s to emit its second
        // delta sample. A too-tight timeout kills it before that sample flushes, so
        // parse sees no delta rows, the cache never fills, and the popup is stuck on
        // "Sampling…" forever. 10 s clears the worst case with headroom; a genuinely
        // wedged process is still bounded (running stays true and coalesces until then).
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text, limit: limit)
    }

    /// Parse nettop delta output into per-process rates. Pure (no I/O) for testing.
    static func parse(_ text: String, limit: Int) -> [NetProcInfo] {
        // Two sample blocks, each preceded by a header line containing "bytes_in".
        // Rows after the LAST header are the delta block (bytes over the interval).
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let lastHeader = lines.lastIndex(where: { $0.contains("bytes_in") }) else { return [] }

        var out: [NetProcInfo] = []
        for line in lines[(lastHeader + 1)...] {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3 else { continue }
            // First column is "name.pid"; the process name itself may contain dots, so
            // split on the LAST dot and require a plausible pid (rejects rows whose
            // trailing segment isn't a real pid, e.g. an indented flow sub-row).
            let nameCol = cols[0]
            guard let dot = nameCol.lastIndex(of: "."),
                  let pid = Int32(nameCol[nameCol.index(after: dot)...]),
                  pid > 0, pid < 4_194_304 else { continue }   // macOS PID_MAX = 99999, headroom kept
            let name = String(nameCol[..<dot])
            guard !name.isEmpty else { continue }
            let down = Double(cols[1]) ?? 0
            let up = Double(cols[2]) ?? 0
            guard down > 0 || up > 0 else { continue }
            out.append(NetProcInfo(pid: pid, name: name, downBytesPerSec: down, upBytesPerSec: up))
        }
        return Array(out.sorted { ($0.downBytesPerSec + $0.upBytesPerSec) > ($1.downBytesPerSec + $1.upBytesPerSec) }
            .prefix(limit))
    }
}
