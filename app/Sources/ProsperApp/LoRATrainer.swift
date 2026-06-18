import CoreGraphics
import Foundation
import HuggingFace
import IOKit.ps
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXOptimizers
import Tokenizers

// On-device LoRA personalization trainer (WS6). Trains a small LoRA adapter on the
// user's accepted (prompt, completion) pairs collected by `TypingHistoryStore`, then
// writes `adapters.safetensors` + `adapter_config.json` into a per-model adapter dir
// that `MLXEngine.loadAdapter()` can serve at inference.
//
// EVERYTHING IS OFF BY DEFAULT. `train()` returns `.skipped` unless `loraEnabled` is
// on AND enough accepted samples exist. Training loads a FRESH model container so the
// live serving container is never frozen/mutated.

/// One on-device LoRA training example: the text before the cursor (`prompt`) and the
/// accepted continuation (`completion`). Kept as a PAIR (not pre-concatenated) so the
/// trainer can wrap the prompt in the SAME chat template the inference path uses — see
/// `LoRATrainer.templatedText`.
struct LoRATrainingPair: Sendable, Equatable {
    let prompt: String
    let completion: String
}

/// Outcome of a `LoRATrainer.train()` run.
enum TrainResult: Sendable, Equatable {
    /// Training did not run; `reason` says why (feature off, too few samples, …).
    case skipped(reason: String)
    /// Training ran to completion; final losses are the last reported values.
    case trained(iterations: Int, finalTrainLoss: Float, finalValidLoss: Float)
    /// Training started but failed; `message` is the error description.
    case failed(message: String)
}

/// Thread-safe cancellation flag shared between the `LoRATrainer` actor and the
/// synchronous `LoRATrain.train` progress callback (which runs inside the model
/// container's isolation and cannot `await` the actor). A single lock-guarded Bool.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func reset() { lock.lock(); value = false; lock.unlock() }
    func request() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Drives on-device LoRA fine-tuning. Stateless except for a cancellation flag.
actor LoRATrainer {
    static let shared = LoRATrainer()

    /// NSLog prefix for all training progress (mirrors the `prosper-lora:` convention).
    private static let logPrefix = "prosper-lora:"

    /// Cancellation flag, shared with the synchronous training callback.
    private let cancelFlag = CancelFlag()

    /// The model id this trainer fine-tunes (the live serving model).
    private let modelId: String

    init(modelId: String = Preferences.coreModel) {
        self.modelId = modelId
    }

    /// Request cancellation of any in-flight training run.
    func cancel() { cancelFlag.request() }

    // MARK: - Adapter directory

    /// Per-model adapter directory:
    /// `Application Support/Prosper/lora/<sanitized-modelId>/`. Mirrors
    /// `TypingHistoryStore`'s base-dir derivation. Created on demand.
    static func adapterDirectory(for modelId: String) throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Prosper", isDirectory: true)
        .appendingPathComponent("lora", isDirectory: true)
        .appendingPathComponent(Preferences.sanitizedModelId(modelId), isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Off-peak gate (WS6 scheduling)

    /// Pure, unit-testable off-peak gate: training is allowed only when the machine
    /// has been idle long enough AND is on wall power (avoids draining battery and
    /// stealing cycles while the user is actively typing). The caller wires the real
    /// idle/power signals; this just decides.
    static func isOffPeak(idleSeconds: Double, onPower: Bool) -> Bool {
        idleSeconds > 300 && onPower
    }

    /// Seconds since the last HID input event (key/mouse/etc.) across the whole
    /// session, via `CGEventSource`. `~0` is the "any input event type" sentinel
    /// (`kCGAnyInputEventType`). Returns 0 on failure (treated as "active" → not idle).
    static func currentIdleSeconds() -> Double {
        let anyInput = CGEventType(rawValue: ~0)!
        let secs = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return secs.isFinite && secs >= 0 ? secs : 0
    }

    /// True iff the providing power source is AC (wall power), via IOKit power-sources.
    /// Returns false (treated as "on battery" → don't train) on any failure.
    static func onACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else {
            return false
        }
        return type == kIOPSACPowerValue
    }

    /// Reads the live idle + power signals and applies the pure `isOffPeak` gate.
    static func isOffPeakNow() -> Bool {
        isOffPeak(idleSeconds: currentIdleSeconds(), onPower: onACPower())
    }

    /// Off-peak-gated training entry point. Trains only when the machine is idle AND on
    /// wall power; otherwise returns `.skipped`. The scheduler timer calls this.
    @discardableResult
    func runIfOffPeak() async -> TrainResult {
        guard Self.isOffPeakNow() else {
            return .skipped(reason: "not off-peak (idle/power gate)")
        }
        return await trainNowIfEligible()
    }

    // MARK: - Scheduler

    /// Installs a repeating off-peak check on the main run loop. Fires every
    /// `intervalSeconds` (default 20 min); each fire runs `runIfOffPeak()` on the actor.
    /// Idempotent guards live in `train()`/`isOffPeakNow` — a fire while ineligible is a
    /// cheap no-op. Call once from app launch.
    @MainActor
    static func startScheduler(intervalSeconds: TimeInterval = 1200) {
        guard scheduler == nil else { return }
        scheduler = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { _ in
            Task { await LoRATrainer.shared.runIfOffPeak() }
        }
    }

    @MainActor private static var scheduler: Timer?

    // MARK: - Dataset split

    /// Pure 90/10 train/validation split (deterministic prefix split — the dataset is
    /// already most-recent-first). At least one element goes to each side when the
    /// dataset has ≥ 2 elements. Extracted so the index math is unit-testable.
    static func split<T>(_ dataset: [T]) -> (train: [T], valid: [T]) {
        guard dataset.count >= 2 else { return (dataset, dataset) }
        let validCount = max(1, dataset.count / 10)
        let trainCount = dataset.count - validCount
        return (Array(dataset.prefix(trainCount)), Array(dataset.suffix(validCount)))
    }

    // MARK: - Chat-template alignment (Risk 3 fix)

    /// Wraps a `(prompt, completion)` pair in the SAME Gemma chat-turn markers the
    /// inference path applies (`generateInline` sends the prompt as a `.user` turn and
    /// the model generates the continuation as the assistant turn). Training on this
    /// templated string — instead of the raw `prompt + completion` concat — aligns the
    /// train-time and serve-time token distributions, so the adapter actually shifts the
    /// chat-templated inference output (the e2e showed raw-concat training had only a
    /// partial effect through the template).
    ///
    /// We emit the literal turn markers as text rather than round-tripping through
    /// `tokenizer.applyChatTemplate` (which returns ids, forcing a lossy decode/re-encode):
    /// `LoRATrain.train` tokenizes this string itself, and Gemma's tokenizer maps the
    /// `<start_of_turn>` / `<end_of_turn>` added-tokens back to their special ids. BOS is
    /// added by the tokenizer, so it is intentionally NOT included here.
    static func templatedText(prompt: String, completion: String) -> String {
        "<start_of_turn>user\n\(prompt)<end_of_turn>\n<start_of_turn>model\n\(completion)<end_of_turn>"
    }

    // MARK: - Config

    /// Builds the `LoRAConfiguration` from preferences (rank, numLayers; scale fixed
    /// at the library default 10.0). Shared by training and the persisted
    /// `adapter_config.json` so serve-time reload matches train-time shape.
    static func configuration() -> LoRAConfiguration {
        LoRAConfiguration(
            numLayers: Preferences.loraNumLayers,
            fineTuneType: .lora,
            loraParameters: .init(rank: Preferences.loraRank, scale: 10.0)
        )
    }

    // MARK: - Manual scheduling entry point

    /// Manual entry point the app can call. Runs `train()` and logs the outcome.
    /// Off-peak wiring (idle/power) is the caller's responsibility — see `isOffPeak`.
    @discardableResult
    func trainNowIfEligible() async -> TrainResult {
        let result = await train()
        NSLog("%@ trainNowIfEligible -> %@", Self.logPrefix, "\(result)")
        return result
    }

    // MARK: - Train

    /// Train a LoRA adapter on the user's accepted completions. Loads a FRESH model
    /// container (never the live serving container), injects LoRA layers, trains, and
    /// writes `adapters.safetensors` + `adapter_config.json` into the adapter dir.
    func train() async -> TrainResult {
        guard Preferences.loraEnabled else {
            return .skipped(reason: "loraEnabled is off")
        }

        let dataset = await TypingHistoryStore.shared.trainingDataset()
        let minSamples = Preferences.loraMinSamples
        guard dataset.count >= minSamples else {
            return .skipped(
                reason: "too few samples: \(dataset.count) < \(minSamples)")
        }
        return await runTraining(dataset: dataset)
    }

    /// Core training run over an explicit dataset (gates already passed). Loads a
    /// FRESH model container, injects LoRA layers, trains, and writes
    /// `adapters.safetensors` + `adapter_config.json`. Exposed (internal) so the
    /// on-device e2e harness can drive the real trainer with a controlled in-memory
    /// dataset — no `TypingHistoryStore`/DB side effects.
    func runTraining(dataset: [LoRATrainingPair]) async -> TrainResult {
        cancelFlag.reset()

        // Wrap each pair in the inference chat template (Risk 3 fix), then split.
        let texts = dataset.map { Self.templatedText(prompt: $0.prompt, completion: $0.completion) }
        let (trainSet, validSet) = Self.split(texts)
        let cfg = Self.configuration()
        let iterations = Preferences.loraIterations

        let adapterDir: URL
        do {
            adapterDir = try Self.adapterDirectory(for: modelId)
        } catch {
            return .failed(message: "adapter dir: \(error.localizedDescription)")
        }
        let weightsURL = adapterDir.appendingPathComponent("adapters.safetensors")

        MLXEngine.configureMemoryLimits()
        NSLog("%@ training on %d samples (%d train / %d valid), %d iterations",
              Self.logPrefix, dataset.count, trainSet.count, validSet.count, iterations)

        // Load a FRESH container so the live serving container is untouched.
        let container: ModelContainer
        do {
            let configuration = ModelConfiguration(id: modelId)
            let downloader = #hubDownloader()
            let loader = #huggingFaceTokenizerLoader()
            container = try await LLMModelFactory.shared.loadContainer(
                from: downloader, using: loader, configuration: configuration
            ) { _ in }
        } catch {
            return .failed(message: "model load: \(error.localizedDescription)")
        }

        // Run training inside the container's isolation. `LoRATrain.train` is
        // synchronous and CPU/GPU-bound; the closure evals all MLXArrays before
        // returning, so nothing non-Sendable escapes. The cancel flag is a
        // lock-guarded box captured by the @Sendable closure.
        let cancelFlag = self.cancelFlag

        do {
            let outcome: TrainResult = try await container.perform(
                values: TrainArgs(
                    train: trainSet, valid: validSet, cfg: cfg,
                    iterations: iterations, weightsURL: weightsURL
                )
            ) { context, args in
                let adapter = try LoRAContainer.from(model: context.model, configuration: args.cfg)
                try adapter.load(into: context.model)

                var lastTrainLoss: Float = .nan
                var lastValidLoss: Float = .nan
                let optimizer = Adam(learningRate: 1e-5)
                let params = LoRATrain.Parameters(
                    batchSize: 4,
                    iterations: args.iterations,
                    stepsPerReport: 10,
                    stepsPerEval: 100,
                    validationBatches: 10,
                    saveEvery: 100,
                    adapterURL: args.weightsURL
                )
                try LoRATrain.train(
                    model: context.model,
                    train: args.train,
                    validate: args.valid,
                    optimizer: optimizer,
                    tokenizer: context.tokenizer,
                    parameters: params
                ) { progress in
                    switch progress {
                    case .train(let it, let loss, _, _):
                        lastTrainLoss = loss
                        NSLog("%@ iter %d train loss %.4f", Self.logPrefix, it + 1, loss)
                    case .validation(let it, let loss, _):
                        lastValidLoss = loss
                        NSLog("%@ iter %d valid loss %.4f", Self.logPrefix, it + 1, loss)
                    case .save(let it, let url):
                        NSLog("%@ iter %d saved %@", Self.logPrefix, it + 1, url.lastPathComponent)
                    }
                    return cancelFlag.isSet ? .stop : .more
                }

                // Persist final weights (train() only writes on `saveEvery`; a short
                // run may finish before the first save), then the config so
                // `LoRAContainer.from(directory:)` can reload the pair.
                try LoRATrain.saveLoRAWeights(model: context.model, url: args.weightsURL)
                return .trained(
                    iterations: args.iterations,
                    finalTrainLoss: lastTrainLoss,
                    finalValidLoss: lastValidLoss
                )
            }

            // Write adapter_config.json beside the weights so the serve-side
            // `LoRAContainer.from(directory:)` can reconstruct the layer shape.
            try writeAdapterConfig(cfg, to: adapterDir)
            Preferences.loraLastTrained = Date()
            NSLog("%@ done: %@", Self.logPrefix, "\(outcome)")
            return outcome
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Encodes the `LoRAConfiguration` to `adapter_config.json` (sorted keys) in the
    /// adapter directory. Public-ish for reuse/testing of the round-trip.
    func writeAdapterConfig(_ cfg: LoRAConfiguration, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(cfg)
        let url = directory.appendingPathComponent("adapter_config.json")
        try data.write(to: url, options: .atomic)
    }
}

/// Non-Sendable bundle of training arguments threaded into `perform(values:)`.
private struct TrainArgs: Sendable {
    let train: [String]
    let valid: [String]
    let cfg: LoRAConfiguration
    let iterations: Int
    let weightsURL: URL
}
