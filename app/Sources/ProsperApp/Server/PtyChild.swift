import Darwin
import Foundation

/// A child process attached to a pseudo-terminal. Used to run `dch` as a client
/// with a real controlling tty so its line discipline, SIGWINCH redraw, and raw
/// key handling behave exactly as in a terminal. Output is pumped on a dedicated
/// thread with back-pressure (the next read waits until the previous chunk is
/// handed off), so a fast stream (Claude Code) can't run the process out of memory.
final class PtyChild: @unchecked Sendable {
    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private let onOutput: ([UInt8]) -> Void
    private let onExit: (Int32) -> Void
    private var done = false
    private let lock = NSLock()

    enum PtyError: Error { case forkFailed }

    init(exe: String, args: [String], env: [String: String], cols: Int, rows: Int,
         onOutput: @escaping ([UInt8]) -> Void, onExit: @escaping (Int32) -> Void) throws {
        self.onOutput = onOutput
        self.onExit = onExit

        // Build C argv/envp BEFORE forking — the child (post-fork, pre-exec) must not
        // allocate or call non-async-signal-safe functions, so everything is ready.
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { if let p = $0 { free(p) } }
            envp.forEach { if let p = $0 { free(p) } }
        }

        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var amaster: Int32 = 0
        let child = forkpty(&amaster, nil, nil, &ws)
        if child < 0 { throw PtyError.forkFailed }
        if child == 0 {
            // Child: replace image. execve only touches the prebuilt C arrays.
            execve(exe, argv, envp)
            _exit(127)  // exec failed
        }
        masterFD = amaster
        pid = child
    }

    /// Start the output pump + the SIGCHLD-free reaper. Idempotent-ish: call once.
    func run() {
        let thread = Thread { [weak self] in self?.pump() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Blocking read loop on the pty master. EOF (child exited / closed its tty) ends
    /// the session; we reap the child for its exit code and notify.
    private func pump() {
        var buf = [UInt8](repeating: 0, count: 1 << 15)
        while true {
            let n = buf.withUnsafeMutableBytes { read(masterFD, $0.baseAddress, $0.count) }
            if n > 0 {
                onOutput(Array(buf[0..<n]))
            } else if n == 0 {
                break                       // EOF
            } else {
                if errno == EINTR { continue }
                break                       // EIO when the slave side is gone, etc.
            }
        }
        reap()
    }

    private func reap() {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()

        var status: Int32 = 0
        if pid > 0 { waitpid(pid, &status, 0) }
        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        onExit(code)
    }

    /// Write client keystrokes / pasted bytes to the pty. Partial writes are looped.
    func write(_ bytes: [UInt8]) {
        guard masterFD >= 0 else { return }
        var off = 0
        bytes.withUnsafeBytes { raw in
            while off < raw.count {
                let n = Darwin.write(masterFD, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n > 0 { off += n }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
        }
    }

    /// Push a new window size; dch's client gets SIGWINCH and forwards MSG_WINCH.
    func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    /// Detach: SIGHUP the dch client so it exits; its master daemon keeps running.
    func terminate() {
        lock.lock()
        let alreadyDone = done
        let p = pid
        lock.unlock()
        if !alreadyDone && p > 0 { kill(p, SIGHUP) }
        // pump()'s read will hit EOF and reap; closing the fd here would race it.
    }
}
