import Darwin
import Foundation
import Security

/// #1676: the ccpool port keeper's core, shared by the keeper executable (Sources/CCPoolKeeper) and the app's link
/// (CCPool/CCPoolKeeperLink.swift). It holds a dup of the proxy's listening socket across a Prosper relaunch and hands it
/// back over SCM_RIGHTS to a same-user peer that passes the code-sign check. It never accept()s on that socket (queued
/// connections wait in the backlog), never polls, never opens a network connection, never reads the Keychain, never execs.
///
/// Protocol on the control socket (a 0600 Unix socket in a 0700 dir; or the socketpair end the spawning app hands over):
/// the app writes one byte, "F" (fetch: the reply is one byte carrying the listening fd) or "X" (exit). EOF is a
/// disconnect. Everything runs on one serial queue, in dispatch sources: no timer while an app is connected, and one
/// one-shot idle timer after the last one leaves.
public final class PortKeeper: @unchecked Sendable {
    public static let fetch: UInt8 = 0x46   // "F"
    public static let exit: UInt8 = 0x58    // "X"
    public static let reply: UInt8 = 0x4B   // "K"
    /// No app connected for this long after a disconnect: the keeper exits (a crashed or removed app never leaves it).
    public static let idleLimit: DispatchTimeInterval = .seconds(15 * 60)
    /// The bundle identifier a peer must be signed as (with this keeper's team).
    public static let appIdentifier = "eu.illegible.prosper"

    public let port: UInt16
    public let queue = DispatchQueue(label: "eu.illegible.prosper.ccpool-keeper")
    /// The held listening fd; -1 once closed (on exit).
    public private(set) var listenFD: Int32
    private var server: DispatchSourceRead?
    private var serverFD: Int32 = -1
    private var socketPath: String?
    private var clients: [Int32: DispatchSourceRead] = [:]
    private var idle: DispatchSourceTimer?
    private var done = false

    // Seams (tests): the peer's uid and audit token, the code-sign check, the own team, the idle limit, what exit does.
    public var peerUID: @Sendable (Int32) -> uid_t? = PortKeeper.systemPeerUID
    public var peerToken: @Sendable (Int32) -> Data? = PortKeeper.systemPeerToken
    /// Whether the peer's code (by audit token) is valid, this team's and signed as `appIdentifier`.
    public var signedLikeApp: @Sendable (_ token: Data, _ team: String) -> Bool = PortKeeper.systemSignedLikeApp
    /// This keeper's own team identifier; nil (ad-hoc or self-signed build): the socket goes to nobody (fail closed).
    public var ownTeam: @Sendable () -> String? = { PortKeeper.systemOwnTeam }
    public var idleAfter: DispatchTimeInterval = PortKeeper.idleLimit
    private let onExit: @Sendable () -> Void

    /// Counters a test reads (on `queue`): idle timers armed and fired, fds handed out, peers refused.
    public private(set) var idleArmed = 0
    public private(set) var idleFired = 0
    public private(set) var handedOut = 0
    public private(set) var refused = 0

    /// Takes ownership of `listening`.
    public init(listening: Int32, port: UInt16, onExit: @escaping @Sendable () -> Void) {
        listenFD = listening
        self.port = port
        self.onExit = onExit
    }

    // MARK: Files

    /// The keeper's dir must be a real directory, this user's, mode 0700 (made so when missing).
    public static func secureDir(_ path: String) -> Bool {
        if mkdir(path, 0o700) != 0, errno != EEXIST { return false }
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid() && (st.st_mode & 0o077) == 0
    }

    public static func socketPath(dir: String, port: UInt16) -> String { dir + "/k\(port).sock" }

    /// One keeper per user and port: an exclusive flock on `<dir>/k<port>.lock`, the fd held for the process's life.
    /// nil when the dir is not safe or another keeper holds the lock.
    public static func lock(dir: String, port: UInt16) -> Int32? {
        guard secureDir(dir) else { return nil }
        let fd = open(dir + "/k\(port).lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }

    /// The port an IPv4 socket is bound to, or nil.
    public static func boundPort(_ fd: Int32) -> UInt16? {
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let r = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard r == 0, a.sin_family == sa_family_t(AF_INET) else { return nil }
        return UInt16(bigEndian: a.sin_port)
    }

    // MARK: Run

    /// Bind the control socket at `socketPath` (0600) and serve; `control` is the spawning app's socketpair end (it
    /// goes through the same peer check). False, nothing started, when the held fd is not bound to `port` or the socket
    /// cannot be made. Call once, off `queue`.
    public func start(socketPath path: String, control: Int32?) -> Bool {
        guard Self.boundPort(listenFD) == port, path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        _ = fcntl(s, F_SETFL, O_NONBLOCK)
        // We hold the lock: a socket file left at the path is a dead keeper's.
        unlink(path)
        guard Self.withUnixAddr(path, { Darwin.bind(s, $0, $1) }) == 0, chmod(path, 0o600) == 0, listen(s, 8) == 0 else {
            close(s)
            unlink(path)
            return false
        }
        serverFD = s
        socketPath = path
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        queue.sync {
            server = src
            src.resume()
            if let control { admit(control) }
            if clients.isEmpty { armIdle() }
        }
        return true
    }

    private func acceptAll() {
        while !done {
            let c = accept(serverFD, nil, nil)
            if c >= 0 { admit(c); continue }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return
        }
    }

    /// Same uid and, by its audit token, signed as Prosper with this keeper's team; else closed at once, nothing sent.
    /// A keeper with no team of its own admits nobody.
    private func admit(_ c: Int32) {
        _ = fcntl(c, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard peerUID(c) == getuid(), let team = ownTeam(), let token = peerToken(c), signedLikeApp(token, team) else {
            refused += 1
            close(c)
            return
        }
        _ = fcntl(c, F_SETFL, O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: queue)
        src.setEventHandler { [weak self] in self?.read(c) }
        src.setCancelHandler { close(c) }
        clients[c] = src
        idle?.cancel()
        idle = nil
        src.resume()
    }

    private func read(_ c: Int32) {
        var b: UInt8 = 0
        let n = Darwin.read(c, &b, 1)
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        guard n == 1 else { return drop(c) }
        switch b {
        case Self.fetch:
            // A keeper whose fd no longer holds the port has nothing to keep.
            guard listenFD >= 0, Self.boundPort(listenFD) == port else { return shutdown() }
            if Self.sendFD(c, listenFD) { handedOut += 1 } else { drop(c) }
        case Self.exit:
            shutdown()
        default:
            drop(c)
        }
    }

    private func drop(_ c: Int32) {
        clients.removeValue(forKey: c)?.cancel()
        if clients.isEmpty, !done { armIdle() }
    }

    /// One-shot: fires once after `idleAfter`, cancelled by the next app; never repeats.
    private func armIdle() {
        idle?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + idleAfter, repeating: .never)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            idleFired += 1
            if clients.isEmpty { shutdown() }
        }
        idle = t
        idleArmed += 1
        t.resume()
    }

    /// Close everything (the held port first), remove the socket file and exit. On `queue`.
    public func shutdown() {
        guard !done else { return }
        done = true
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        idle?.cancel()
        idle = nil
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
        if let server {
            let fd = serverFD
            server.setCancelHandler { close(fd) }
            server.cancel()
        }
        server = nil
        if let socketPath { unlink(socketPath) }
        onExit()
    }

    // MARK: Peer checks

    public static func systemPeerUID(_ c: Int32) -> uid_t? {
        var uid = uid_t.max
        var gid = gid_t.max
        return getpeereid(c, &uid, &gid) == 0 ? uid : nil
    }

    /// The peer's audit token (LOCAL_PEERTOKEN): names the process instance, so a reused pid cannot pass for it.
    public static func systemPeerToken(_ c: Int32) -> Data? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(c, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0, Int(len) == MemoryLayout<audit_token_t>.size else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// The process's own team identifier, read once; nil unsigned, ad-hoc or with no team (then nothing is handed out).
    public static let systemOwnTeam: String? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, let team = signingInfo(me)?.team, !team.isEmpty,
              team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return team
    }()

    /// The peer's code, found by its audit token, satisfies an Apple-anchored requirement for `team` and `appIdentifier`
    /// (SecCodeCheckValidity), and its signing info says the same identifier and team.
    public static func systemSignedLikeApp(_ token: Data, _ team: String) -> Bool {
        guard team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        var guest: SecCode?
        let attrs = [kSecGuestAttributeAudit: token as NSData] as CFDictionary
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(appIdentifier)\""
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req,
              SecCodeCopyGuestWithAttributes(nil, attrs, [], &guest) == errSecSuccess, let guest,
              SecCodeCheckValidity(guest, [], req) == errSecSuccess,
              let info = signingInfo(guest) else { return false }
        return info.id == appIdentifier && info.team == team
    }

    private static func signingInfo(_ code: SecCode) -> (id: String?, team: String?)? {
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return nil }
        var dict: CFDictionary?
        guard SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &dict) == errSecSuccess,
              let d = dict as? [String: Any] else { return nil }
        return (d[kSecCodeInfoIdentifier as String] as? String, d[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    // MARK: SCM_RIGHTS

    // cmsghdr is 12 bytes on Darwin (4-byte aligned): one fd makes a 16-byte control message, the fd at offset 12.
    private static let cmsgHeader = MemoryLayout<cmsghdr>.size
    private static let cmsgSpace = cmsgHeader + MemoryLayout<Int32>.size

    /// Send one reply byte carrying `fd`.
    public static func sendFD(_ sock: Int32, _ fd: Int32) -> Bool {
        var byte = reply
        let ctl = UnsafeMutableRawPointer.allocate(byteCount: cmsgSpace, alignment: 4)
        defer { ctl.deallocate() }
        ctl.initializeMemory(as: UInt8.self, repeating: 0, count: cmsgSpace)
        ctl.storeBytes(of: cmsghdr(cmsg_len: socklen_t(cmsgSpace), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS), as: cmsghdr.self)
        ctl.storeBytes(of: fd, toByteOffset: cmsgHeader, as: Int32.self)
        return withUnsafeMutablePointer(to: &byte) { b in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(b), iov_len: 1)
            return withUnsafeMutablePointer(to: &iov) { iovp in
                var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                                 msg_control: ctl, msg_controllen: socklen_t(cmsgSpace), msg_flags: 0)
                return sendmsg(sock, &msg, 0) == 1
            }
        }
    }

    /// Receive the reply byte and the one fd it carries (close-on-exec), or nil. Anything else, extra fds included, is
    /// refused and every fd that came with it closed.
    public static func receiveFD(_ sock: Int32) -> Int32? {
        var byte: UInt8 = 0
        let cap = 64
        let ctl = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 4)
        defer { ctl.deallocate() }
        ctl.initializeMemory(as: UInt8.self, repeating: 0, count: cap)
        var msg = msghdr()
        let n = withUnsafeMutablePointer(to: &byte) { b in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(b), iov_len: 1)
            return withUnsafeMutablePointer(to: &iov) { iovp in
                msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                             msg_control: ctl, msg_controllen: socklen_t(cap), msg_flags: 0)
                return recvmsg(sock, &msg, 0)
            }
        }
        guard n == 1 else { return nil }
        let got = Int(msg.msg_controllen)
        let h = ctl.load(as: cmsghdr.self)
        var fds: [Int32] = []
        if got >= cmsgSpace, h.cmsg_level == SOL_SOCKET, h.cmsg_type == SCM_RIGHTS, Int(h.cmsg_len) >= cmsgSpace,
           Int(h.cmsg_len) <= got {
            let count = (Int(h.cmsg_len) - cmsgHeader) / MemoryLayout<Int32>.size
            fds = (0..<count).map { ctl.load(fromByteOffset: cmsgHeader + $0 * 4, as: Int32.self) }
        }
        guard byte == reply, fds.count == 1, msg.msg_flags & MSG_CTRUNC == 0 else {
            fds.forEach { close($0) }
            return nil
        }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        return fds[0]
    }

    public static func withUnixAddr<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: a.sun_path) - 1))
        withUnsafeMutableBytes(of: &a.sun_path) { dst in dst.copyBytes(from: bytes) }
        a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
}
