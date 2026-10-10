import os

/// Latency signposts (#195). About 0.5 µs per begin/end pair when nothing records; read them
/// with Instruments or `log show --signpost --predicate 'subsystem == "eu.illegible.prosper"'`.
enum Perf {
    nonisolated static let subsystem = "eu.illegible.prosper"
    nonisolated static let category = "perf"
    nonisolated static let signposter = OSSignposter(subsystem: subsystem, category: category)

    /// Ends an optional interval and consumes it, so a second call is a no-op (#337):
    /// ending the same state twice traps in -Onone builds. Every optional-state end goes here.
    nonisolated static func end(_ name: StaticString, _ state: inout OSSignpostIntervalState?) {
        guard let s = state else { return }
        state = nil
        signposter.endInterval(name, s)
    }
}
