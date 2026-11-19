import Foundation

/// #1640: a one-shot dispatch timer whose wakeup has 10 % slack, so macOS can coalesce it. For delays nobody sees to the
/// millisecond; the delay itself is never changed.
public enum SlackTimer {
    /// 10 % of `delay`; zero for a non-finite or non-positive delay.
    public static func leeway(_ delay: TimeInterval) -> DispatchTimeInterval {
        guard delay.isFinite, delay > 0, delay < 1e8 else { return .nanoseconds(0) }
        return .nanoseconds(Int(delay * 1e8))
    }

    /// Built and scheduled but not resumed: the caller must resume() it (or cancel() then resume()) before it is released, or libdispatch traps.
    public static func make(queue: DispatchQueue, delay: TimeInterval, _ fire: @escaping @Sendable () -> Void)
        -> (source: DispatchSourceTimer, leeway: DispatchTimeInterval)
    {
        let s = DispatchSource.makeTimerSource(queue: queue)
        let lw = leeway(delay)
        s.schedule(deadline: .now() + delay, leeway: lw)
        s.setEventHandler(handler: fire)
        return (s, lw)
    }

    /// `DispatchQueue.main.asyncAfter` with slack: fires `fire` once on main after `delay`.
    public static func onMain(after delay: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        let s = make(queue: .main, delay: delay, fire).source
        // The handler holds the source until it fires; cancel() then drops the handler and the cycle with it.
        s.setEventHandler { fire(); s.cancel() }
        s.resume()
    }
}
