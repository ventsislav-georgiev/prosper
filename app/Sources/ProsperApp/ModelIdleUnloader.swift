import Foundation

/// Frees the shared on-device model after a period of inactivity — but ONLY while
/// inline autocomplete is off. With autocomplete on, the hot path needs the model on
/// every keystroke, so an idle unload would just thrash (unload → cold reload on the
/// next key); residency is then owned by `AppDelegate.reconcileModelResidency`.
///
/// Armed after each on-demand model use (Translate / `host.llm`), the only consumers
/// that load the model lazily. The idle window is user-configurable in the Translate
/// extension's settings (`idle_unload_minutes`, 0 = never unload).
///
/// Race safety: the unload goes through `MLXEngine.unloadIfIdle()`, which no-ops while
/// a generation is in flight — so a timer firing mid-translation never frees GPU
/// buffers under an active compute; the next completion re-arms the timer.
///
/// ponytail: single shared timer; the idle window is global, not per-consumer. Fine —
/// the only lazy consumers are Translate and host.llm, both gated on the same model.
@MainActor
final class ModelIdleUnloader {
    static let shared = ModelIdleUnloader()

    // Injectable seams (defaults wire to the live app; tests override them).

    /// Idle window in minutes (0 = disabled). Wired at startup to the Translate
    /// extension's host.prefs; defaults to 2 until set.
    var minutesProvider: () -> Int = { 2 }
    /// Whether inline autocomplete owns the model right now (then: never idle-unload).
    var isAutocompleteEnabled: () -> Bool = { Preferences.autocompleteEnabled }
    /// Performs the actual unload. Default routes through the busy-guarded path.
    var unloadAction: () -> Void = { Task { await MLXEngine.shared.unloadIfIdle() } }
    /// Scheduler seam. Default uses a one-shot `Timer`; tests inject a synchronous fake.
    var scheduler: (TimeInterval, @escaping @Sendable () -> Void) -> Cancellable = { interval, fire in
        // Timer scheduled on the main runloop fires on the main thread → already isolated.
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        return Cancellable { t.invalidate() }
    }

    private var pending: Cancellable?

    /// A token whose `cancel` stops a scheduled fire. Decouples the unloader from `Timer`.
    final class Cancellable {
        private let onCancel: () -> Void
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() { onCancel() }
    }

    /// Parse a persisted `idle_unload_minutes` pref string into a safe minute count.
    /// Tolerates fractional input ("2.5" → 2) and guards nan/inf/overflow (→ default),
    /// since `Int(Double)` traps on those and the pref file can be hand-edited. Clamps 0…1440.
    static func minutes(fromPref raw: String?, default def: Int = 2) -> Int {
        raw.flatMap(Double.init).flatMap {
            $0.isFinite ? Int(min(max($0, 0), 1440)) : nil
        } ?? def
    }

    /// Idle window in seconds, or nil when the timer should NOT be armed (autocomplete
    /// owns the model, or the feature is disabled with 0 minutes). Pure — unit-testable.
    func plannedInterval() -> TimeInterval? {
        guard !isAutocompleteEnabled() else { return nil }
        let minutes = minutesProvider()
        guard minutes > 0 else { return nil }
        return TimeInterval(minutes) * 60
    }

    /// Note an on-demand model use (Translate / host.llm). Cancels any pending unload,
    /// then re-arms it for the configured idle window (or leaves it cancelled when
    /// `plannedInterval()` is nil).
    func noteUsage() {
        cancel()
        guard let interval = plannedInterval() else { return }
        pending = scheduler(interval) { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
    }

    /// Cancel any pending unload (e.g. autocomplete just turned on → it owns the model).
    func cancel() { pending?.cancel(); pending = nil }

    /// Idle window elapsed. Re-checks the gate (autocomplete may have turned on since)
    /// then requests a busy-guarded unload.
    func fire() {
        pending = nil
        guard !isAutocompleteEnabled() else { return }
        unloadAction()
    }
}
