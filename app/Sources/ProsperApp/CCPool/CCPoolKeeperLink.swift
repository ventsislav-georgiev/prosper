import CCPoolKeeperCore
import Darwin
import Foundation

/// #1676: the app's side of the ccpool port keeper (Sources/CCPoolKeeper). The service asks a running keeper for the
/// listening fd before it binds its own (`fetch`), spawns one with a dup of a fresh listener (`spawn`), and tells it to
/// exit when ccpool is turned off or the app quits for good (`exit`). The one connection it keeps open while the app
/// runs is the control link: the keeper idle-exits 60 s after the last one closes.
///
/// R1676 n14: only an app signed with a team gets a link (the keeper admits only a peer of its team, so an ad-hoc or
/// self-signed build could neither fetch from nor stop one): with none, `init` is nil and the service runs as with no
/// keeper.
///
/// Isolation: none; every call runs on the service's caller (the life cycle's queue), state behind `lock`.
final class CCPoolKeeperLink: @unchecked Sendable {
    let directory: URL
    let port: UInt16
    /// Starts the keeper with `listening` as its fd 3 and `control` as its fd 4; its pid or nil. A seam: tests record.
    let spawner: @Sendable (_ listening: Int32, _ control: Int32) -> pid_t?
    private let lock = NSLock()
    private var control: Int32 = -1

    /// nil when the app has no team (`team` nil): no keeper is spawned, fetched from or told to exit.
    init?(directory: URL, port: UInt16, spawner: @escaping @Sendable (_ listening: Int32, _ control: Int32) -> pid_t?,
          team: String? = PortKeeper.systemOwnTeam) {
        guard team != nil else { return nil }
        self.directory = directory
        self.port = port
        self.spawner = spawner
    }

    var socketPath: String { PortKeeper.socketPath(dir: directory.path, port: port) }

    /// The keeper's listening socket (a new fd the caller owns), or nil when no keeper answers. The connection stays open.
    func fetch() -> Int32? {
        lock.withLock {
            guard let c = connected() else { return nil }
            var b = PortKeeper.fetch
            guard Darwin.write(c, &b, 1) == 1, let fd = PortKeeper.receiveFD(c) else {
                dropLocked()
                return nil
            }
            return fd
        }
    }

    /// Start a keeper holding `listening` (a fd the caller keeps): its control link replaces any held one. False when
    /// the dir is not safe, the socketpair fails, or the spawner refused.
    @discardableResult
    func spawn(listening fd: Int32) -> Bool {
        guard PortKeeper.secureDir(directory.path) else { return false }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return false }
        pair.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC); Self.noSigPipe($0) }
        let pid = spawner(fd, pair[1])
        close(pair[1])
        guard pid != nil else {
            close(pair[0])
            return false
        }
        lock.withLock {
            dropLocked()
            control = pair[0]
        }
        return true
    }

    /// ccpool turned off, or the app quits for good: the keeper closes the port and exits (one reached over the socket
    /// when this app holds no link, e.g. one left by an earlier launch). No-op when none runs.
    func exit() {
        lock.withLock {
            guard let c = connected() else { return }
            var b = PortKeeper.exit
            _ = Darwin.write(c, &b, 1)
            // The keeper admits a fresh link only while its peer is still connected: wait for it to close ours (EOF, or the
            // 2 s receive timeout) before closing, or the byte is lost.
            var r: UInt8 = 0
            while Darwin.read(c, &r, 1) > 0 {}
            dropLocked()
        }
    }

    /// The app goes away but the keeper stays (an update relaunch): just close the link.
    func detach() { lock.withLock { dropLocked() } }

    private func dropLocked() {
        if control >= 0 { close(control) }
        control = -1
    }

    /// The held link, or a new connection to the keeper's socket (same uid only; 2 s send and receive timeouts). A path
    /// too long for sun_path is refused, never connected truncated (R1676 n19). The keeper's code is not checked: after
    /// an update its file on disk is the new bundle's, so a static check of the running (old) keeper fails and would
    /// refuse the hand-off; and a same-uid process able to plant this socket could as well bind the port first.
    private func connected() -> Int32? {
        if control >= 0 { return control }
        guard PortKeeper.fitsUnixAddr(socketPath) else { return nil }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        Self.noSigPipe(s)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard PortKeeper.withUnixAddr(socketPath, { Darwin.connect(s, $0, $1) }) == 0, PortKeeper.systemPeerUID(s) == getuid() else {
            close(s)
            return nil
        }
        control = s
        return s
    }

    private static func noSigPipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The production spawner: posix_spawn of `executable` in its own session (setsid), every fd closed but the two
    /// (POSIX_SPAWN_CLOEXEC_DEFAULT), stdio on /dev/null, an empty environment. Refuses under XCTest, so no test starts a
    /// real keeper. The child is reaped by a process source, never waited on a thread.
    static func posixSpawn(executable: String, directory: URL, port: UInt16) -> @Sendable (Int32, Int32) -> pid_t? {
        { listening, control in
            guard NSClassFromString("XCTestCase") == nil, FileManager.default.isExecutableFile(atPath: executable) else { return nil }
            var fa: posix_spawn_file_actions_t?
            var attr: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&fa) == 0 else { return nil }
            defer { posix_spawn_file_actions_destroy(&fa) }
            guard posix_spawnattr_init(&attr) == 0 else { return nil }
            defer { posix_spawnattr_destroy(&attr) }
            posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
            posix_spawn_file_actions_adddup2(&fa, listening, 3)
            posix_spawn_file_actions_adddup2(&fa, control, 4)
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))
            let argv = [executable, "--port", String(port), "--dir", directory.path]
            let cargv = argv.map { strdup($0) } + [nil]
            defer { cargv.forEach { free($0) } }
            let envp: [UnsafeMutablePointer<CChar>?] = [nil]
            var pid: pid_t = 0
            guard posix_spawn(&pid, executable, &fa, &attr, cargv, envp) == 0 else { return nil }
            let reap = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
            reap.setEventHandler {
                var st: Int32 = 0
                _ = waitpid(pid, &st, WNOHANG)
                reap.cancel()
            }
            reap.resume()
            // A keeper that exited before the source was armed (a second one, on the lock) is reaped here.
            var st: Int32 = 0
            if waitpid(pid, &st, WNOHANG) == pid { reap.cancel() }
            return pid
        }
    }
}
