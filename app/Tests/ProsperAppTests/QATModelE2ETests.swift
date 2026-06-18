import Foundation
import MLX
import XCTest

@testable import ProsperApp

/// ON-DEVICE validation that Gemma **QAT-4bit** (quantization-aware-trained,
/// heterogeneous / mixed-precision checkpoint) loads and generates through our
/// pinned `mlx-swift-lm` 3.31.3 stack — the exact production path MLXEngine uses.
///
/// Background: QAT checkpoints ship a `config.json` whose `quantization` block
/// interleaves a global `{group_size, bits:4}` with many per-layer overrides
/// (`bits:8`) and `false` skip flags. Older mlx-swift only parsed a flat config
/// → "config only / Setup failed". 3.31.3 added `QuantizationContainer` +
/// `PerLayerQuantization` (see MLXLMCommon/BaseConfiguration.swift) and applies
/// per-layer bits at load (MLXLMCommon/Load.swift `quantize(model:)` predicate).
/// This test proves the end-to-end load+generate actually works on-device.
///
/// QAT-4bit = ~4-bit size, near-6-bit quality (QAT ≥ post-training quant at equal
/// bits) — the "smarter, smaller" model. E2B is the smallest published QAT.
///
/// Gated behind `PROSPER_QAT_E2E=1` so normal `swift test`/CI skips the ~3-4 GB
/// download + GPU load. Run on this M4 with:
///   PROSPER_QAT_E2E=1 swift test --filter QATModelE2ETests 2>&1 | tee /tmp/qat-e2e.log
final class QATModelE2ETests: XCTestCase {

    /// Smallest published Gemma QAT-4bit (heterogeneous quant). Canonical HF
    /// casing is capital `E2B` (the lowercase repo 307-redirects to this).
    private let qatModelId = "mlx-community/gemma-4-E2B-it-qat-4bit"

    private func requireE2E() throws {
        guard ProcessInfo.processInfo.environment["PROSPER_QAT_E2E"] == "1" else {
            throw XCTSkip("Set PROSPER_QAT_E2E=1 to run the on-device QAT load+generate e2e.")
        }
    }

    func testQATModelLoadsAndGenerates() async throws {
        try requireE2E()
        ModelPaths.bootstrap()

        let engine = MLXEngine(modelId: qatModelId)

        // 1. LOAD — exercises QuantizationContainer decode + per-layer quantize.
        //    A flat-only parser (the old failure) would throw here on the
        //    interleaved per-layer keys / shape mismatch.
        let loadStart = Date()
        try await engine.load { fraction, status in
            if fraction > 0 { NSLog("qat-e2e: load %.0f%% — %@", fraction * 100, status) }
        }
        let loadSecs = Date().timeIntervalSince(loadStart)
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "QAT-4bit model failed to load")
        NSLog("qat-e2e: loaded in %.1fs", loadSecs)

        // 2. GENERATE — real GPU inference through the production chat-template path.
        let out = try await engine.generateInline(
            prompt: "The capital of France is",
            system: nil,
            maxTokens: 24,
            temperature: 0.0
        )
        NSLog("qat-e2e: completion = %@", out)

        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "QAT model loaded but produced empty output")
        // Greedy decode (temp 0) on a factual prompt should mention Paris — a weak
        // sanity check that per-layer dequant produced coherent weights, not garbage.
        XCTAssertTrue(
            trimmed.lowercased().contains("paris"),
            "QAT output not coherent (expected 'Paris'): \(trimmed)")
    }

    /// E4B QAT-4bit — the larger QAT sibling (more layers, same heterogeneous
    /// quant + KV-sharing arch). Proves the patch generalizes across the family,
    /// not just the E2B checkpoint, before we offer it in the picker.
    func testLargeQATModelLoadsAndGenerates() async throws {
        try requireE2E()
        ModelPaths.bootstrap()

        let engine = MLXEngine(modelId: "mlx-community/gemma-4-E4B-it-qat-4bit")
        try await engine.load { fraction, status in
            if fraction > 0 { NSLog("e4b-qat-e2e: load %.0f%% — %@", fraction * 100, status) }
        }
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "E4B QAT-4bit model failed to load")

        let out = try await engine.generateInline(
            prompt: "The capital of France is",
            system: nil,
            maxTokens: 24,
            temperature: 0.0
        )
        NSLog("e4b-qat-e2e: completion = %@", out)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "E4B QAT model loaded but produced empty output")
        XCTAssertTrue(
            trimmed.lowercased().contains("paris"),
            "E4B QAT output not coherent (expected 'Paris'): \(trimmed)")
    }

    /// REGRESSION: the QAT patch gates K/V proj+norm allocation to non-shared
    /// layers and strips the redundant shared-layer K/V weights in `sanitize`.
    /// A UNIFORM checkpoint ships those redundant weights for every layer, so
    /// this proves the patch keeps uniform models loadable (they would otherwise
    /// trip `verify: [.all]`'s `noUnusedKeys` on the now-unallocated modules).
    func testUniformModelLoadsAndGenerates() async throws {
        try requireE2E()
        ModelPaths.bootstrap()

        let engine = MLXEngine(modelId: "mlx-community/gemma-4-e2b-it-4bit")
        try await engine.load { fraction, status in
            if fraction > 0 { NSLog("uniform-e2e: load %.0f%% — %@", fraction * 100, status) }
        }
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "uniform 4-bit model failed to load")

        let out = try await engine.generateInline(
            prompt: "The capital of France is",
            system: nil,
            maxTokens: 24,
            temperature: 0.0
        )
        NSLog("uniform-e2e: completion = %@", out)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(trimmed.isEmpty, "uniform model loaded but produced empty output")
        XCTAssertTrue(
            trimmed.lowercased().contains("paris"),
            "uniform output not coherent (expected 'Paris'): \(trimmed)")
    }
}
