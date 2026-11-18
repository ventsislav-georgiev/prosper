import Darwin
import Foundation
import os

/// #1563 (v2.1 7.3, 7.4): `host.process.run{argv=,timeout=,max_bytes=}` for the system tier. argv[1] is an absolute
/// path to an existing regular executable, run directly (no shell, no PATH lookup) with a fixed environment, stdin
/// /dev/null and the extension's directory as cwd. The child leads its own group (Foundation's Process spawns with
/// POSIX_SPAWN_SETPGROUP, ProcessGroupKillTests); a timeout or a dropped request ends that group with #833's kill
/// (CodexHarness.killGroup: SIGTERM, SIGKILL after 1 s). Each stream is capped and drained. At most two run at once
/// for the app, and each live group is in CodexHarness.livePGIDs so the quit drain takes it down.
enum ProcessRun {
    static let maxTimeout: TimeInterval = 10
    static let defaultTimeout: TimeInterval = 5
    static let maxBytes = 1 << 20
    static let maxConcurrent = 2
    /// argv entries past this are refused (a table that size is a bug, not a command line).
    static let maxArgs = 1024
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
    /// How long the reader keeps going past the deadline for the group kill to land (grace 1 s + 1 s).
    static let killSlack: TimeInterval = 2.5

    struct Result: Equatable, Sendable {
        var status: Int32?
        var stdout = ""
        var stderr = ""
        var timedOut = false
        var truncated = false
        /// The refusal, in host words: argv[1] in it went through OutsideText.shown.
        var error: String?

        var ok: Bool { error == nil && !timedOut && status == 0 }

        /// The Lua table: {ok, status, stdout, stderr, timed_out, truncated[, error]}.
        var lua: [String: Any] {
            var t: [String: Any] = ["ok": ok, "stdout": stdout, "stderr": stderr, "timed_out": timedOut,
                                    "truncated": truncated]
            if let status { t["status"] = Int(status) }
            if let error { t["error"] = error }
            return t
        }
    }

    static func refused(_ why: String) -> Result { Result(error: "host.process.run: " + why) }

    private static let running = OSAllocatedUnfairLock(initialState: 0)

    /// The refusal for `argv` run in `cwd`, nil when it may run. Only argv[0] (Lua's argv[1]) is checked: the rest
    /// are arguments, passed as they are.
    static func refusal(argv: [String], cwd: URL?) -> String? {
        guard let path = argv.first, !path.isEmpty else { return "argv[1] is missing" }
        guard argv.count <= maxArgs else { return "argv has more than \(maxArgs) entries" }
        let shown = OutsideText.shown(path)
        guard path.hasPrefix("/") else { return "argv[1] is not an absolute path: \(shown)" }
        var st = stat()
        guard stat(path, &st) == 0 else { return "argv[1] does not exist: \(shown)" }
        guard st.st_mode & S_IFMT == S_IFREG else { return "argv[1] is not a regular file: \(shown)" }
        guard access(path, X_OK) == 0 else { return "argv[1] is not executable: \(shown)" }
        return cwd == nil ? "the extension has no directory" : nil
    }

    /// Runs `argv` and returns how it ended. Cancelling the calling task (the request was dropped) kills the group.
    static func run(argv: [String], cwd: URL?, timeout: TimeInterval = defaultTimeout,
                    maxBytes cap: Int = maxBytes) async -> Result {
        if let why = refusal(argv: argv, cwd: cwd) { return refused(why) }
        guard let cwd else { return refused("the extension has no directory") }
        let taken = running.withLock { n -> Bool in
            guard n < maxConcurrent else { return false }
            n += 1
            return true
        }
        guard taken else { return refused("\(maxConcurrent) processes are already running") }
        let job = Job()
        let limit = min(max(timeout.isFinite ? timeout : defaultTimeout, 0), maxTimeout)
        let cap = min(max(cap, 0), maxBytes)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = job.execute(argv: argv, cwd: cwd, timeout: limit, cap: cap)
                    running.withLock { $0 -= 1 }
                    continuation.resume(returning: r)   // the one resume site
                }
            }
        } onCancel: {
            job.kill()
        }
    }

    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var stopped = false

        /// A dropped request or the timeout: the group goes (once), or the spawn does not happen.
        func kill() {
            let pid: pid_t = lock.withLock {
                defer { stopped = true }
                return stopped ? 0 : self.pid
            }
            if pid > 0 { CodexHarness.killGroup(pid, grace: 1) }
        }

        func execute(argv: [String], cwd: URL, timeout: TimeInterval, cap: Int) -> Result {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            process.environment = ProcessRun.environment
            process.currentDirectoryURL = cwd
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            lock.lock()
            guard !stopped else { lock.unlock(); return ProcessRun.refused("the request was dropped") }
            do {
                try process.run()
            } catch {
                lock.unlock()
                return ProcessRun.refused("argv[1] did not start: \(OutsideText.shown(argv[0]))")
            }
            pid = process.processIdentifier
            CodexHarness.livePGIDs.withLock { $0[pid] = CodexHarness.startTime(pid) ?? 0 }
            lock.unlock()

            let deadline = Date().addingTimeInterval(timeout)
            var timedOut = false
            var result = Result()
            var bufs = [Data(), Data()]
            var open = [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor]
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            // As ShellRunner (#1026): EOF alone is not the end, a child that left the group can hold a pipe; once the
            // leader is gone only what is already in the pipes is read. Past the deadline plus the kill's slack the
            // reader stops whatever is left, so a flood from an escaped child cannot hold it.
            while open.contains(where: { $0 >= 0 }) {
                let now = Date()
                if !timedOut, now >= deadline { timedOut = true; kill() }
                if now >= deadline.addingTimeInterval(ProcessRun.killSlack) { break }
                let exited = !process.isRunning   // before the poll: empty pipes after it are final
                var fds = open.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                let ready = poll(&fds, nfds_t(fds.count), exited ? 0 : 100)
                if ready < 0 { if errno == EINTR { continue }; break }
                if ready == 0 { if exited { break }; continue }
                for i in fds.indices where fds[i].fd >= 0 && fds[i].revents != 0 {
                    let n = buf.withUnsafeMutableBytes { read(fds[i].fd, $0.baseAddress, $0.count) }
                    if n < 0, errno == EINTR || errno == EAGAIN { continue }
                    if n <= 0 { open[i] = -1; continue }   // EOF or a read error: this stream is done
                    let room = cap - bufs[i].count
                    if n > room { result.truncated = true }   // drained: read on, keep nothing past the cap
                    bufs[i].append(contentsOf: buf[0..<min(n, max(room, 0))])
                }
            }
            try? out.fileHandleForReading.close()   // a writer still there gets SIGPIPE instead of a full pipe
            try? err.fileHandleForReading.close()
            if process.isRunning { kill() }   // left the reader early: the group goes before the wait
            process.waitUntilExit()
            let pgid = process.processIdentifier
            let killed = lock.withLock { () -> Bool in
                defer { pid = 0; stopped = true }   // reaped: a late cancel must not signal a recycled pid
                return stopped
            }
            // A group the kill took is unregistered by its escalate. A leader that ended by itself may leave members
            // behind: they go the same way (the id stays reserved while one lives); an empty group is unregistered here.
            if !killed {
                if CodexHarness.sendSignal(-pgid, 0) == 0 { CodexHarness.killGroup(pgid, grace: 1) }
                else { CodexHarness.livePGIDs.withLock { _ = $0.removeValue(forKey: pgid) } }
            }
            result.timedOut = timedOut
            // A signal death reads as the shell's 128 + signal, so status is always a number once it ran.
            let s = process.terminationStatus
            result.status = process.terminationReason == .uncaughtSignal ? 128 + s : s
            result.stdout = String(decoding: bufs[0], as: UTF8.self)
            result.stderr = String(decoding: bufs[1], as: UTF8.self)
            return result
        }
    }
}
