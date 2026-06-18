import Darwin
import Foundation
import MLX
import XCTest

@testable import ProsperApp

/// ON-DEVICE end-to-end validation of WS6 LoRA (risks 1/2/3). Gated behind the
/// `PROSPER_LORA_E2E=1` environment variable so a normal `swift test` (and CI) skips
/// it — it downloads/loads the ~5 GB model and runs real GPU training.
///
/// Run on this M4 machine with:
///   PROSPER_LORA_E2E=1 swift test --filter LoRATrainE2ETests 2>&1 | tee /tmp/lora-e2e.log
///
/// It drives the REAL `LoRATrainer.runTraining(dataset:)` over a controlled in-memory
/// dataset (NO TypingHistoryStore/DB side effects — the user's real history is never
/// touched) and reports:
///   • Risk 1 — peak phys_footprint during training (OOM headroom on the 6-bit base).
///   • Risk 2 — train/valid loss trajectory (does QLoRA converge on small data?).
///   • Risk 3 — base-vs-adapter inference output via the chat-template path
///     (`generateInline`), revealing whether an adapter trained on raw prompt+completion
///     still influences the chat-templated inference distribution.
final class LoRATrainE2ETests: XCTestCase {

    private func requireE2E() throws {
        guard ProcessInfo.processInfo.environment["PROSPER_LORA_E2E"] == "1" else {
            throw XCTSkip("Set PROSPER_LORA_E2E=1 to run the on-device LoRA e2e (loads the model + trains on GPU).")
        }
    }

    // MARK: - phys_footprint sampler

    /// Current resident phys_footprint in MB (the same metric Activity Monitor's
    /// "Memory" column and the OS memory-pressure killer use). -1 on failure.
    private static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }

    /// Background peak-RSS sampler. `peak` is lock-guarded; `stop()` halts polling.
    private final class MemorySampler: @unchecked Sendable {
        private let lock = NSLock()
        private var _peak: Double = 0
        private var running = true
        var peak: Double { lock.lock(); defer { lock.unlock() }; return _peak }
        func stop() { lock.lock(); running = false; lock.unlock() }
        func start() {
            Thread.detachNewThread { [weak self] in
                while true {
                    guard let self else { return }
                    self.lock.lock()
                    let go = self.running
                    self.lock.unlock()
                    if !go { return }
                    let m = LoRATrainE2ETests.physFootprintMB()
                    self.lock.lock()
                    if m > self._peak { self._peak = m }
                    self.lock.unlock()
                    usleep(200_000)  // 200 ms
                }
            }
        }
    }

    // MARK: - Distinctive synthetic dataset

    /// A user whose accepted completions end with a rare signature the base model is
    /// very unlikely to emit on its own ("Cheers, Vince ⟡"). If the adapter learns it,
    /// risks 2 (convergence) and 3 (train/inference template carry-over) hold.
    private static func makeDataset() -> (train: [LoRATrainingPair], heldOutPrompt: String, signature: String) {
        let signature = "Cheers, Vince ⟡"
        let openers = [
            "Hi team, quick update on the migration: it's done and tests pass. ",
            "Thanks for flagging that — I pushed a fix and redeployed. ",
            "Morning all, the nightly build is green and artifacts are up. ",
            "Following up on the incident: root cause found, patch is in review. ",
            "Heads up: I rotated the credentials and updated the vault. ",
            "Quick note — the dashboard now shows the new latency panel. ",
            "Reviewed the PR, left a couple of comments, otherwise looks solid. ",
            "The data export finished overnight; numbers match the staging run. ",
            "Bumped the dependencies and the flaky test is stable now. ",
            "Confirmed the rollback worked; traffic is back to baseline. ",
        ]
        let middles = [
            "Let me know if anything looks off.\n",
            "Shout if you want me to dig deeper.\n",
            "Happy to pair on the next step.\n",
            "Will keep an eye on the graphs today.\n",
        ]
        var train: [LoRATrainingPair] = []
        // 10 openers × 4 middles = 40 distinct accepted pairs. The prompt is the opener
        // (the text before the cursor at suggest time); the completion is the rest +
        // the rare signature — so the adapter learns to continue an opener with the
        // signature, and the held-out prompt below is a fresh opener.
        for o in openers {
            for m in middles {
                train.append(LoRATrainingPair(prompt: o, completion: m + signature))
            }
        }
        let heldOutPrompt = "Hi all, the release is out and the dashboards look green. "
        return (train, heldOutPrompt, signature)
    }

    // MARK: - The run

    func test_onDevice_lora_train_and_serve() async throws {
        try requireE2E()

        let modelId = Preferences.coreModel
        print("=== LoRA E2E === model=\(modelId)")

        // Controlled training hyperparameters (small but real).
        // Canonical small-but-real hyperparameters. NOTE: this synthetic dataset (a
        // fixed rare signature appended to every sample, uncorrelated with the prompt)
        // is a convergence/memory/template-alignment probe — NOT a generalization test.
        // Bumping rank/iters past this only overfits (train→0.06 / valid→3.07 observed
        // at rank16/iters400); 8/200 is the sweet spot for this probe.
        Preferences.loraNumLayers = 8
        Preferences.loraRank = 8
        Preferences.loraIterations = 200

        let (dataset, heldOutPrompt, signature) = Self.makeDataset()
        print("dataset: \(dataset.count) samples; signature=\"\(signature)\"")

        // --- Risk 1: peak memory during training ---
        let sampler = MemorySampler()
        let beforeMB = Self.physFootprintMB()
        sampler.start()

        let start = Date()
        let result = await LoRATrainer.shared.runTraining(dataset: dataset)
        let elapsed = Date().timeIntervalSince(start)

        sampler.stop()
        let peakMB = sampler.peak

        print("=== RESULT ===")
        print("train result: \(result)")
        print(String(format: "elapsed: %.1fs", elapsed))
        print(String(format: "RISK1 phys_footprint: before=%.0f MB  peak=%.0f MB  delta=%.0f MB  (machine RAM=48 GB)",
                     beforeMB, peakMB, peakMB - beforeMB))

        // --- Risk 2: convergence ---
        switch result {
        case .trained(let iters, let trainLoss, let validLoss):
            print(String(format: "RISK2 convergence: iterations=%d  finalTrainLoss=%.4f  finalValidLoss=%.4f",
                         iters, trainLoss, validLoss))
            XCTAssertTrue(trainLoss.isFinite, "train loss must be finite")
            XCTAssertGreaterThan(trainLoss, 0, "train loss must be > 0")
            XCTAssertLessThan(trainLoss, 12.0, "train loss implausibly high — training likely diverged")
        case .skipped(let reason):
            XCTFail("training skipped unexpectedly: \(reason)")
            return
        case .failed(let message):
            XCTFail("training failed: \(message)")
            return
        }

        // Confirm adapter artifacts were written.
        let adapterDir = try LoRATrainer.adapterDirectory(for: modelId)
        let weights = adapterDir.appendingPathComponent("adapters.safetensors")
        let config = adapterDir.appendingPathComponent("adapter_config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: weights.path), "adapters.safetensors missing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path), "adapter_config.json missing")
        print("adapter dir: \(adapterDir.path)")

        // --- Risk 3: base vs adapter inference through the chat-template path ---
        let engine = MLXEngine()
        try await engine.load { _, _ in }

        let baseOut = try await engine.generateInline(
            prompt: heldOutPrompt, system: nil, maxTokens: 32, temperature: 0.0, maxWords: 0)
        print("BASE   output: \"\(baseOut)\"")

        await engine.loadAdapter()
        let adapterLoaded = await engine.isAdapterLoaded
        XCTAssertTrue(adapterLoaded, "adapter failed to load into the serving engine")

        let adapterOut = try await engine.generateInline(
            prompt: heldOutPrompt, system: nil, maxTokens: 32, temperature: 0.0, maxWords: 0)
        print("ADAPTER output: \"\(adapterOut)\"")

        let baseHasSig = baseOut.contains(signature) || baseOut.contains("Vince")
        let adapterHasSig = adapterOut.contains(signature) || adapterOut.contains("Vince")
        let changed = baseOut != adapterOut
        print("RISK3 template carry-over: outputChanged=\(changed)  baseHasSignature=\(baseHasSig)  adapterHasSignature=\(adapterHasSig)")
        print("  → if adapterHasSignature but not base: adapter trained on raw concat DOES influence chat-templated inference (risk 3 mitigated).")
        print("  → if outputChanged but neither has signature: adapter has effect but didn't fully learn the target (tune iters/rank/data).")
        print("  → if outputChanged==false: adapter had NO effect through the chat template (risk 3 CONFIRMED — persist a templated prompt snapshot).")

        // We do not hard-assert the signature (small data / few iters) — the run is a
        // measurement. We DO assert the adapter loaded and the pipeline ran clean.
        XCTAssertFalse(adapterOut.isEmpty || baseOut.isEmpty, "inference produced empty output")
    }
}
