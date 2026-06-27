import Foundation
import os.log

/// User-facing verbose troubleshooting trace, toggled in About. Off by default.
///
/// One flag drives two sinks:
///  • the app's own keep-awake / remote-wake CLIENT path logs here, and
///  • the flag is pushed to the root daemon via `RemoteWakeConfig.trace`, so the
///    dark-wake decision path (RemoteWakeObserver / RemoteWakeCore) logs too.
///
/// Both use the substring "ProsperTrace", so one predicate captures the whole story
/// across the app + daemon processes:
///   log show --last 1h --predicate 'eventMessage CONTAINS "ProsperTrace"'
enum TraceLog {
    static let key = "prosper.trace.verbose"
    private static let logger = Logger(subsystem: "eu.illegible.prosper", category: "trace")

    static var on: Bool { UserDefaults.standard.bool(forKey: key) }

    /// `@autoclosure` so the message string is never built when trace is off.
    static func emit(_ msg: @autoclosure () -> String) {
        guard on else { return }
        let s = msg()
        logger.log("ProsperTrace(app): \(s, privacy: .public)")
    }
}
