import Foundation

/// Daemon-wide verbose trace gate, mirrored from `RemoteWakeConfig.trace` whenever a
/// config is applied (see RemoteWakeObserver). NSLog → the unified log, which the
/// user reads AFTER the fact with:
///   log show --last 1h --predicate 'eventMessage CONTAINS "ProsperTrace"'
/// That retrospective read is the whole point: the wake decisions happen during dark
/// wake while the user is away, so a live stream is useless — the unified log keeps
/// them. Off = a single bool check, zero log cost. Single-writer (the daemon's serial
/// queue sets it, the wake path reads it), so `unsafe` global is fine.
nonisolated(unsafe) var daemonTrace = false

@inline(__always) func dtrace(_ msg: @autoclosure () -> String) {
    if daemonTrace { NSLog("ProsperTrace: %@", msg()) }
}
