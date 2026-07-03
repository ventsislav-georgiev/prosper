import XCTest
@testable import ProsperApp

/// Pure plumbing checks for the llama inline engine. Decode-quality coverage
/// lives in the headless bench (needs the GGUF); these lock the flag/env
/// contract so a misread key can't silently route the wrong engine.
final class LlamaInlineEngineTests: XCTestCase {

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
