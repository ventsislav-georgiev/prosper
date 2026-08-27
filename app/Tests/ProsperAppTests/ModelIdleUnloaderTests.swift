import Darwin
import Foundation
import XCTest
@testable import ProsperApp

@MainActor
final class ModelIdleUnloaderTests: XCTestCase {

    // MARK: plannedInterval gating (pure)

    func testNoIntervalWhenAutocompleteOn() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { true }
        u.minutesProvider = { 5 }
        XCTAssertNil(u.plannedInterval())
    }

    func testNoIntervalWhenMinutesZero() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { false }
        u.minutesProvider = { 0 }
        XCTAssertNil(u.plannedInterval())
    }

    func testIntervalIsMinutesTimesSixty() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { false }
        u.minutesProvider = { 2 }
        XCTAssertEqual(u.plannedInterval(), 120)
    }

    // MARK: noteUsage arms / cancels via injected scheduler

    func testNoteUsageArmsSchedulerWithPlannedInterval() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { false }
        u.minutesProvider = { 3 }
        var armed: TimeInterval?
        u.scheduler = { interval, _ in armed = interval; return .init({}) }
        u.noteUsage()
        XCTAssertEqual(armed, 180)
    }

    func testNoteUsageDoesNotArmWhenGated() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { true }
        var armed = false
        u.scheduler = { _, _ in armed = true; return .init({}) }
        u.noteUsage()
        XCTAssertFalse(armed)
    }

    func testNoteUsageCancelsPreviousBeforeRearming() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { false }
        u.minutesProvider = { 1 }
        var cancels = 0
        u.scheduler = { _, _ in .init({ cancels += 1 }) }
        u.noteUsage()           // arm #1
        u.noteUsage()           // cancel #1, arm #2
        XCTAssertEqual(cancels, 1)
    }

    func testCancelStopsPending() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { false }
        u.minutesProvider = { 1 }
        var cancelled = false
        u.scheduler = { _, _ in .init({ cancelled = true }) }
        u.noteUsage()
        u.cancel()
        XCTAssertTrue(cancelled)
    }

    // MARK: fire respects gate + invokes unloadAction

    func testFireUnloadsWhenAutocompleteOff() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { false }
        var unloaded = false
        u.unloadAction = { unloaded = true }
        u.fire()
        XCTAssertTrue(unloaded)
    }

    func testFireSkipsUnloadWhenAutocompleteTurnedOn() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { true }
        var unloaded = false
        u.unloadAction = { unloaded = true }
        u.fire()
        XCTAssertFalse(unloaded)
    }

    // MARK: pref parsing (pure, hand-edit-safe)

    func testMinutesParsing() {
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: "5"), 5)
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: "2.5"), 2)   // fractional truncates
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: "0"), 0)     // valid: disables
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: nil), 2)     // unset → default
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: ""), 2)      // junk → default
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: "abc"), 2)
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: "-3"), 0)    // clamped ≥ 0
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: "99999"), 1440) // clamped ≤ 1440
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: "inf"), 2)   // no Int(Double) trap
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: "nan"), 2)
        XCTAssertEqual(ModelIdleUnloader.minutes(fromPref: "1e400"), 2) // overflow → default
    }

    // MARK: real unload path (#096)

    /// The default `unloadAction` must reach BOTH runtimes. Before #096 it only hit
    /// `MLXEngine`, so on the default engine path (`LlamaInlineEngine.isEnabled` → true)
    /// an idle unload reclaimed nothing and the GGUF stayed resident for the process's
    /// life. Headless half of the proof: the seam exists, runs against the live
    /// singletons, is safe with nothing loaded and is idempotent (a second call must not
    /// double-free). The load → unload → reload round-trip needs the real GGUF and lives
    /// in `LlamaInlineEngineTests.testUnloadReloadRoundTrip` (PROSPER_LLAMA_SMOKE=1).
    func testUnloadIdleEnginesIsSafeAndIdempotentWithNothingLoaded() async {
        await ModelIdleUnloader.unloadIdleEngines()
        await ModelIdleUnloader.unloadIdleEngines()
        XCTAssertFalse(LlamaInlineEngine.isLoadedSnapshot)
        XCTAssertFalse(MLXEngine.isInlineModelLoaded)
        XCTAssertEqual(LlamaInlineEngine.residentBytesSnapshot, 0)
        let llamaLoaded = await LlamaInlineEngine.shared.isLoaded
        XCTAssertFalse(llamaLoaded)
    }

    /// `fire()` with the SHIPPING `unloadAction` (not an injected fake) must drive the
    /// real teardown without crashing — locks the default closure's wiring, which the
    /// injected-seam tests above deliberately bypass.
    func testFireWithDefaultUnloadActionDrivesRealTeardown() async {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { false }
        u.fire()                                   // spawns the unload Task
        await ModelIdleUnloader.unloadIdleEngines() // join: same actors, so this queues behind it
        XCTAssertFalse(LlamaInlineEngine.isLoadedSnapshot)
    }

    // MARK: hot-path budget
    //
    // The idle-unload machinery must add ZERO cost to the inline-autocomplete keystroke
    // path. That is guaranteed structurally — the inline path is MLXEngine.generateInlineRouted,
    // separate from the busy-counted MLXEngine.generate; noteUsage() is never called on it; and
    // while autocomplete is ON, plannedInterval() short-circuits to nil before any work.
    // This locks the gating decision well under the budget so a regression that makes it
    // allocate or loop fails here. Budget: 100k gate decisions < 50ms (~500ns each).
    func testGatingIsCheap() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { true }   // hot-path state: autocomplete owns the model
        u.minutesProvider = { 2 }
        measure {
            for _ in 0..<100_000 { _ = u.plannedInterval() }
        }
    }

    // Timer firing path: scheduler captures fire callback; invoking it unloads.
    // MARK: relieveMemoryPressure (perf F5, #098)

    /// Small-scale, always-on (no PROSPER_LLAMA_SMOKE gate) proof that
    /// `malloc_zone_pressure_relief` — the call `unloadIdleEngines()` now runs after
    /// freeing both engines — is callable and returns promptly. Can't drive a real
    /// multi-GB model load headlessly here; the ~3.3 GB GGUF numbers are measured by
    /// `LlamaInlineEngineTests.testUnloadThenPressureReliefReturnsHeapToOS` under
    /// PROSPER_LLAMA_SMOKE=1.
    func testMallocPressureReliefIsCallableAndFast() {
        var ptrs: [UnsafeMutableRawPointer] = []
        for _ in 0..<40 {                    // 40 × 8 MB ≈ 320 MB, roughly the F5 finding's size
            guard let p = malloc(8 * 1024 * 1024) else { continue }
            memset(p, 0xAB, 8 * 1024 * 1024) // touch every page so it's actually dirty/resident
            ptrs.append(p)
        }
        for p in ptrs { free(p) }
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = malloc_zone_pressure_relief(nil, 0)
        let duration = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertLessThan(duration, 2.0, "pressure relief must not stall")
    }

    func testScheduledCallbackUnloads() {
        let u = ModelIdleUnloader()
        u.isAutocompleteEnabled = { false }
        u.minutesProvider = { 1 }
        var fire: (() -> Void)?
        u.scheduler = { _, cb in fire = cb; return .init({}) }
        var unloaded = false
        u.unloadAction = { unloaded = true }
        u.noteUsage()
        fire?()
        XCTAssertTrue(unloaded)
    }
}
