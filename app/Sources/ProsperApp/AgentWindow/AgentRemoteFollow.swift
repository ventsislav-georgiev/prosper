import Foundation

// #1555: `dch --ls-json --remote --follow` (dch >= 1.62.0, README "Following the list" at v1.99.0): the whole remote
// list once, then again as one complete line per change, until SIGTERM or the reader closes the pipe. A pipe reader,
// never a pty. The window model holds one while it is shown; tests hand it a fake through AgentWindowModel's seam.

/// A running follow child; `stop` ends it (its own recorded pid only, never once it was reaped).
protocol AgentRemoteFollowHandle: AnyObject {
    func stop()
}

/// Splits the follow stream into complete lines: a line cut across reads waits for its newline.
struct AgentRemoteFollowLines {
    private var pending = Data()

    /// Every line `chunk` completes, in order, without its "\n"; the cut tail is kept for the next chunk.
    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let lines = pending[..<last].split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
        pending = Data(pending[pending.index(after: last)...])
        return lines
    }
}

/// The real follow child: `dch <args>` with stdout on a pipe read on its own thread, stderr to /dev/null.
final class AgentRemoteFollowChild: AgentRemoteFollowHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var reaped = false
    private let process = Process()

    /// nil when it could not start. `onData` gets each stdout chunk and then `onExit` its status, both on main, in order.
    static func start(path: String, args: [String], env: [String: String],
                      onData: @escaping @MainActor @Sendable (Data) -> Void,
                      onExit: @escaping @MainActor @Sendable (Int32) -> Void) -> AgentRemoteFollowChild? {
        let child = AgentRemoteFollowChild(), p = child.process, pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = env
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in child.lock.withLock { child.reaped = true } }
        do { try p.run() } catch { return nil }
        child.lock.withLock { child.pid = p.processIdentifier }
        let read = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while case let chunk = read.availableData, !chunk.isEmpty {
                DispatchQueue.main.async { MainActor.assumeIsolated { onData(chunk) } }
            }
            // stdout closed: the child is exiting (shortcut: a grandchild holding the pipe would delay this; dch's
            // own children are captured, upgrade if one ever inherits stdout).
            child.process.waitUntilExit()
            let status = child.process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status) } }
        }
        return child
    }

    /// SIGTERM to the recorded pid, once, and only while it was not reaped (a reaped pid may be reused).
    func stop() {
        let target: pid_t? = lock.withLock {
            defer { pid = nil }
            return reaped ? nil : pid
        }
        if let target { _ = Darwin.kill(target, SIGTERM) }
    }
}
