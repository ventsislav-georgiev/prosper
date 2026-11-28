import CCPoolKeeperCore
import Darwin
import Foundation

// #1676: the ccpool port keeper. Spawned detached by Prosper (AgentPoolKeeperLink.posixSpawn: setsid, every other fd
// closed, stdio on /dev/null, an empty environment) with the proxy's listening socket on fd 3 and the spawning app's
// control socketpair end on fd 4. argv: --port <n> --dir <0700 dir>. It holds the port across a relaunch and hands it
// to the next Prosper; see PortKeeper. Exit 0 also when another keeper already holds the lock.

signal(SIGPIPE, SIG_IGN)
signal(SIGHUP, SIG_IGN)
// Cheap and contained: a handful of fds (lock, listening, control socket, a few apps), plus room for what Security's
// code-sign check opens (R1676 n18: 16 was tight).
var files = rlimit(rlim_cur: 64, rlim_max: 64)
setrlimit(RLIMIT_NOFILE, &files)

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let portText = value("--port"), let port = UInt16(portText), port != 0, let dir = value("--dir"), dir.hasPrefix("/") else {
    exit(2)
}
guard PortKeeper.lock(dir: dir, port: port) != nil else { exit(0) }   // another keeper holds this user's port
let keeper = PortKeeper(listening: 3, port: port, onExit: { exit(0) })
guard keeper.start(socketPath: PortKeeper.socketPath(dir: dir, port: port), control: 4) else { exit(1) }
dispatchMain()
