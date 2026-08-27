import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// Pure plumbing checks for the llama inline engine. Decode-quality coverage
/// lives in the headless bench (needs the GGUF); these lock the flag/env
/// contract so a misread key can't silently route the wrong engine.
final class LlamaInlineEngineTests: XCTestCase {

    /// Resident footprint (`phys_footprint`, the same metric Activity Monitor's
    /// "Memory" column reads) — same pattern as `LoRATrainE2ETests`/
    /// `VisionOCRRetentionMeasurementTests`. 0 on failure.
    private func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "inlineEngineLlama")
        UserDefaults.standard.removeObject(forKey: "llamaInlineModel")
        super.tearDown()
    }

    func testEnabledByDefault() {
        UserDefaults.standard.removeObject(forKey: "inlineEngineLlama")
        // Env override may be set when the suite runs under a bench harness;
        // only assert the default when it isn't.
        if ProcessInfo.processInfo.environment["PROSPER_INLINE_ENGINE"] == nil {
            XCTAssertTrue(LlamaInlineEngine.isEnabled)
        }
    }

    func testDefaultsFlagDisables() {
        UserDefaults.standard.set(false, forKey: "inlineEngineLlama")
        XCTAssertFalse(LlamaInlineEngine.isEnabled)
    }

    func testModelFileURLDefaultsToAppSupportGGUF() {
        // Without the env override the path is app-managed and names the
        // default catalog model's file.
        if ProcessInfo.processInfo.environment["PROSPER_LLAMA_GGUF"] == nil {
            UserDefaults.standard.removeObject(forKey: "llamaInlineModel")
            let url = LlamaInlineEngine.modelFileURL
            XCTAssertTrue(url.path.hasSuffix("Prosper/models/gguf/gemma-4-E2B_q4_0-it.gguf"))
        }
    }

    func testCatalogSelectionPersistsAndRoutesFileURL() {
        UserDefaults.standard.removeObject(forKey: "llamaInlineModel")
        XCTAssertEqual(LlamaInlineEngine.selectedModelId, LlamaInlineEngine.catalog[0].id)
        let alt = LlamaInlineEngine.catalog[1]
        LlamaInlineEngine.selectModel(alt.id)
        XCTAssertEqual(LlamaInlineEngine.selectedModelId, alt.id)
        if ProcessInfo.processInfo.environment["PROSPER_LLAMA_GGUF"] == nil {
            XCTAssertTrue(LlamaInlineEngine.modelFileURL.path.hasSuffix("Prosper/models/gguf/\(alt.fileName)"))
        }
        // unknown id is a no-op
        LlamaInlineEngine.selectModel("nope")
        XCTAssertEqual(LlamaInlineEngine.selectedModelId, alt.id)
    }

    func testTunedParamsDefaults() {
        // Defaults are the recovered reference thresholds; env overrides are
        // covered by bench usage (setenv in-process is unreliable under XCTest).
        let p = LlamaInlineEngine.Params()
        XCTAssertEqual(p.searchWidth, 6)
        XCTAssertEqual(p.minBranchProbability, 0.10, accuracy: 0.0001)
        XCTAssertEqual(p.relativeCutoff, 0.30, accuracy: 0.0001)
        XCTAssertEqual(p.minAvgLogprob, -1.5, accuracy: 0.0001)
    }

    func testSplitRequiredPrefix() {
        // trailing partial word rides as required prefix WITH its leading
        // space (SentencePiece tokens carry the space)
        var s = LlamaInlineEngine.splitRequiredPrefix("I need to disc")
        XCTAssertEqual(s.prefill, "I need to")
        XCTAssertEqual(s.required, " disc")
        // boundary (trailing space): the space itself is required
        s = LlamaInlineEngine.splitRequiredPrefix("I need to ")
        XCTAssertEqual(s.prefill, "I need to")
        XCTAssertEqual(s.required, " ")
        // newline counts as boundary character too
        s = LlamaInlineEngine.splitRequiredPrefix("line one\nвто")
        XCTAssertEqual(s.prefill, "line one\n")
        XCTAssertEqual(s.required, "вто")
        // single bare word: everything is required, empty prefill
        s = LlamaInlineEngine.splitRequiredPrefix("Hel")
        XCTAssertEqual(s.prefill, "")
        XCTAssertEqual(s.required, "Hel")
        // empty stays empty
        s = LlamaInlineEngine.splitRequiredPrefix("")
        XCTAssertEqual(s.prefill, "")
        XCTAssertEqual(s.required, "")
    }

    func testTranslateGenerateSmoke() async throws {
        // Live decode smoke for the translate path (greedy generate + script
        // ban). Opt-in: needs the real GGUF and ~4GB RAM, so it only runs
        // with PROSPER_LLAMA_SMOKE=1.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROSPER_LLAMA_SMOKE"] == "1")
        try XCTSkipUnless(LlamaInlineEngine.modelIsDownloaded)
        try await LlamaInlineEngine.shared.ensureLoaded(params: LlamaInlineEngine.tunedParams())
        let out = try await LlamaInlineEngine.shared.generate(
            system: "You are a translator. Reply with ONLY the Bulgarian translation of the user's text.",
            user: "The weather is nice today and we should go for a walk.",
            maxTokens: 96,
            bannedCharacters: "ыэёіїєґЫЭЁІЇЄҐ")
        await LlamaInlineEngine.shared.unload()
        XCTAssertFalse(out.isEmpty)
        XCTAssertNil(out.unicodeScalars.first { "ыэёіїєґЫЭЁІЇЄҐ".unicodeScalars.contains($0) })
        // must actually be Cyrillic output, not an English echo
        XCTAssertTrue(out.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }, out)
    }

    func testTranslateStagedSmoke() async throws {
        // Live staged-pipeline smoke: milestones must advance to "done" and the
        // primary must be target-script text. Opt-in like the generate smoke.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROSPER_LLAMA_SMOKE"] == "1")
        try XCTSkipUnless(LlamaInlineEngine.modelIsDownloaded)
        UserDefaults.standard.set(true, forKey: "inlineEngineLlama")
        var seen: [String] = []
        var result: TranslationResult?
        for _ in 0..<600 {
            let snap = await MainActor.run {
                CoreBridge.translateStaged("incarnation", target: "Bulgarian", source: nil)
            }
            if seen.last != snap.status { seen.append(snap.status) }
            if snap.status == "done" || snap.status == "failed" {
                result = snap.result
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await LlamaInlineEngine.shared.unload()
        XCTAssertEqual(seen.last, "done", "milestones: \(seen)")
        let primary = result?.primary ?? ""
        XCTAssertTrue(
            primary.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }, primary)
    }

    /// #096 regression: load → generate → IDLE UNLOAD → generate again must work.
    /// The idle unloader now frees this engine too, so the reload seam
    /// (`generate` → `ensureLoaded`, no-op when hot, full re-init when cold) is on the
    /// critical path for every post-idle request. Drives the real
    /// `ModelIdleUnloader.unloadIdleEngines()`, not `unload()` directly, so the
    /// production wiring is what's exercised.
    ///
    /// Opt-in like the other live-decode smokes: needs the GGUF and ~4 GB.
    /// Re-init cost (measured, M-series, gemma-4-E2B q4_0, warm page cache) is printed —
    /// the first request after an idle unload pays it, by design.
    func testUnloadReloadRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROSPER_LLAMA_SMOKE"] == "1")
        try XCTSkipUnless(LlamaInlineEngine.modelIsDownloaded)

        let params = LlamaInlineEngine.tunedParams()
        try await LlamaInlineEngine.shared.ensureLoaded(params: params)
        XCTAssertTrue(LlamaInlineEngine.isLoadedSnapshot)
        XCTAssertGreaterThan(LlamaInlineEngine.residentBytesSnapshot, 0)
        let first = try await LlamaInlineEngine.shared.generate(
            system: "Reply with one short sentence.", user: "Say hello.", maxTokens: 16)
        XCTAssertFalse(first.isEmpty)

        // Idle unload through the shipping path.
        await ModelIdleUnloader.unloadIdleEngines()
        let loadedAfterUnload = await LlamaInlineEngine.shared.isLoaded
        XCTAssertFalse(loadedAfterUnload, "idle unload must free the llama context")
        XCTAssertFalse(LlamaInlineEngine.isLoadedSnapshot)
        XCTAssertEqual(LlamaInlineEngine.residentBytesSnapshot, 0)

        // Next request re-inits lazily — no explicit reload call anywhere.
        let t0 = CFAbsoluteTimeGetCurrent()
        let second = try await LlamaInlineEngine.shared.generate(
            system: "Reply with one short sentence.", user: "Say hello again.", maxTokens: 16)
        let reinitPlusDecode = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertFalse(second.isEmpty, "lazy re-init must serve the next request")
        XCTAssertTrue(LlamaInlineEngine.isLoadedSnapshot)
        print("#096 post-idle first request (re-init + 16-token decode): "
              + String(format: "%.2fs", reinitPlusDecode))

        // A second unload/reload cycle: re-init must not be one-shot. Timed bare, so
        // the number above can be split into re-init vs. decode.
        await ModelIdleUnloader.unloadIdleEngines()
        let t1 = CFAbsoluteTimeGetCurrent()
        try await LlamaInlineEngine.shared.ensureLoaded(params: params)
        print("#096 bare re-init (backend + model + context): "
              + String(format: "%.2fs", CFAbsoluteTimeGetCurrent() - t1))
        XCTAssertTrue(LlamaInlineEngine.isLoadedSnapshot)
        await LlamaInlineEngine.shared.unload()
    }

    /// Perf F5 (#098, HYPOTHESIS from #086): does `malloc_zone_pressure_relief`
    /// actually hand freed llama.cpp/ggml heap (malloc + mmap, not MLX GPU buffers)
    /// back to the OS after a real ~3.3 GB GGUF unload? Measures `phys_footprint`
    /// at the three points the ledger entry asks for — loaded, unloaded, post-relief
    /// — plus the relief call's own wall time, since a stall there is the regression
    /// this finding must not introduce. `unload()` is called directly (not through
    /// `ModelIdleUnloader.unloadIdleEngines()`) so the "after unload, before relief"
    /// point is observable in isolation; the relief call itself is the exact same
    /// `malloc_zone_pressure_relief(nil, 0)` `ModelIdleUnloader.relieveMemoryPressure()`
    /// runs off the main actor after both engine frees — a process-global zone
    /// operation, so calling it here measures the identical effect.
    func testUnloadThenPressureReliefReturnsHeapToOS() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROSPER_LLAMA_SMOKE"] == "1")
        try XCTSkipUnless(LlamaInlineEngine.modelIsDownloaded)

        try await LlamaInlineEngine.shared.ensureLoaded(params: LlamaInlineEngine.tunedParams())
        _ = try await LlamaInlineEngine.shared.generate(
            system: "Reply with one short sentence.", user: "Say hello.", maxTokens: 16)
        let beforeUnload = physFootprint()

        await LlamaInlineEngine.shared.unload()
        let afterUnload = physFootprint()

        let t0 = CFAbsoluteTimeGetCurrent()
        let zoneReleased = malloc_zone_pressure_relief(nil, 0)
        let reliefMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let afterRelief = physFootprint()

        func mb(_ b: UInt64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
        print("#098 phys_footprint: before-unload=\(mb(beforeUnload)) "
              + "after-unload=\(mb(afterUnload)) after-relief=\(mb(afterRelief)) "
              + "zone-reported-released=\(mb(UInt64(zoneReleased))) "
              + "relief-duration=\(String(format: "%.1fms", reliefMs))")

        XCTAssertLessThan(afterUnload, beforeUnload, "unload must drop the resident footprint")
        // Generous ceiling: the entry's own concern is "tens of ms"; a full-second
        // stall would be the actively-harmful case #3 in the task calls for moving
        // off the timer's thread.
        XCTAssertLessThan(reliefMs, 1000, "pressure relief must not stall for a full second")
    }

    func testEnsureLoadedThrowsWhenModelMissing() async {
        // No GGUF on test machines at the default path (and the engine must
        // fail loud, not crash) — unless one actually exists there.
        guard !LlamaInlineEngine.modelIsDownloaded else { return }
        do {
            try await LlamaInlineEngine.shared.ensureLoaded()
            XCTFail("expected modelMissing")
        } catch { /* expected */ }
    }
}
