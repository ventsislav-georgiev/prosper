import os

/// Latency signposts (#195). Intervals are free when nothing is recording; read them
/// with Instruments or `log show --signpost --predicate 'subsystem == "eu.illegible.prosper"'`.
enum Perf {
    nonisolated static let subsystem = "eu.illegible.prosper"
    nonisolated static let category = "perf"
    nonisolated static let signposter = OSSignposter(subsystem: subsystem, category: category)
}
