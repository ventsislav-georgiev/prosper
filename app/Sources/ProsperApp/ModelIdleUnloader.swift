import Foundation
import Darwin  // malloc_zone_pressure_relief (malloc/malloc.h)

/// Frees the shared on-device model after a period of inactivity — but ONLY while
/// inline autocomplete is off. With autocomplete on, the hot path needs the model on
/// every keystroke, so an idle unload would just thrash (unload → cold reload on the
/// next key); residency is then owned by `AppDelegate.reconcileModelResidency`.
///
/// Armed after each on-demand model use (Translate / `host.llm`), the only consumers
/// that load the model lazily. The idle window is user-configurable in the Translate
/// extension's settings (`idle_unload_minutes`, 0 = never unload).
///
/// Race safety: the unload goes through `unloadIdleEngines()`, which frees each engine
/// only when that engine is idle — so a timer firing mid-translation never frees GPU
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
    var unloadAction: () -> Void = { Task { await ModelIdleUnloader.unloadIdleEngines() } }
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

    /// Free every lazily-loaded inference engine. BOTH runtimes, always: the
    /// inline/translate model is the llama.cpp GGUF by default
    /// (`LlamaInlineEngine.isEnabled` → true), so an idle unload that touched only
    /// `MLXEngine` reclaimed *nothing* on the default path and left ~3 GB of weights,
    /// context and KV cache resident for the life of the process. Each engine is
    /// idempotent when already free, so this is safe to call repeatedly.
    ///
    /// What serializes this against a concurrent inference request:
    ///   • `MLXEngine` is an actor whose generations `await` internally, so it carries
    ///     an explicit `activeGenerations` counter — `unloadIfIdle()` no-ops while busy
    ///     and the next idle tick reclaims.
    ///   • `LlamaInlineEngine` is an actor whose `ensureLoaded` / `complete` / `generate`
    ///     are all NON-SUSPENDING (no `await` in their bodies — the decode loop is a
    ///     straight-line C call sequence). The actor's executor therefore runs each of
    ///     them to completion atomically, so an `unload()` message can only be delivered
    ///     BETWEEN requests, never inside one. No extra lock or busy counter is needed;
    ///     do not introduce an `await` inside those methods without adding one.
    ///
    /// Re-init is lazy and automatic: `complete`/`generate` already open with
    /// `try ensureLoaded(...)`, which is a no-op when `ctx != nil` and a full
    /// `llama_backend_init` + model + context re-load otherwise. Same seam that runs at
    /// first launch, so the first request after an idle unload simply pays a cold load.
    ///
    /// NOT torn down here, because nothing exposes a way to (see #096): ggml's Metal
    /// device is a process-lifetime singleton (`ggml_metal_device_get` → static vector,
    /// freed at exit) that owns the rsets keep-alive thread and the compiled shader
    /// library, and MLX's two `static ThreadPool{4}` in `mlx/io/load.cpp` plus its
    /// scheduler `StreamThread` are function-local statics with no C API. Note that
    /// `llama_backend_free()` is NOT that API — in b9866 it is a tail-call to
    /// `ggml_quantize_free()`, which frees only the IQ2/IQ3 quantization grids that a
    /// load-only workload never allocates.
    static func unloadIdleEngines() async {
        await MLXEngine.shared.unloadIfIdle()
        await LlamaInlineEngine.shared.unload()
        await relieveMemoryPressure()
    }

    /// Perf F5 (#098): after freeing the llama.cpp/ggml weights + KV (malloc + mmap,
    /// not MLX GPU buffers — see #096), ask the default malloc zones to return
    /// freed-but-dirty pages to the OS. `malloc_zone_pressure_relief(nil, 0)` walks
    /// every zone; on a multi-GB fragmented heap that can cost tens of ms (measured
    /// in `LlamaInlineEngineTests`), so it must never run on the main thread.
    ///
    /// `unloadIdleEngines` is `@MainActor`-isolated (inherited from this class), so
    /// without `Task.detached` the call after the two `await`s above would resume
    /// back on the main actor. `Task.detached` starts a fresh, unstructured task
    /// that inherits no actor/executor from the caller, so by construction this runs
    /// only on the global concurrent executor's utility-QoS pool — never the main
    /// thread (which also hosts the CGEventTap run loop, see EventTap.swift's
    /// `runLoop = CFRunLoopGetCurrent()`) and never the CoreAudio render thread (a
    /// dedicated HAL callback thread outside the Swift concurrency pool entirely).
    /// `.utility` keeps it off the user-interactive/user-initiated bands. Awaited
    /// (not fire-and-forget) so callers — including tests — observe it as part of
    /// the unload, but the awaiting caller itself is never the thread that runs it.
    private static func relieveMemoryPressure() async {
        await Task.detached(priority: .utility) {
            let released = malloc_zone_pressure_relief(nil, 0)
            TraceLog.emit("idle unload: malloc_zone_pressure_relief released \(released) bytes")
        }.value
    }

    /// Idle window elapsed. Re-checks the gate (autocomplete may have turned on since)
    /// then requests a busy-guarded unload.
    func fire() {
        pending = nil
        guard !isAutocompleteEnabled() else { return }
        unloadAction()
    }
}
