import Foundation

/// In-app debug endpoint for headless completion measurement WITHOUT a second
/// model load or quitting the GUI (see the "run model while typing" work). Gated
/// on `PROSPER_DEBUG_ENDPOINT=1`; when on, the live app polls a request file and
/// writes results — so I can measure warm-cache generation latency against the
/// already-resident model as many times as I like, no disruption.
///
///   PROSPER_DEBUG_ENDPOINT=1 PROSPER_DEBUG_REQ=<req.json> PROSPER_DEBUG_OUT=<out.json> Prosper
///
/// Request:  {"id":"r1","mode":"typing"|"single","sentences":[...],"stepChars":3,"minChars":3}
/// - typing: feed each sentence's GROWING prefixes (every stepChars) with the KV
///   cache kept WARM across steps (reset once per sentence) → measures the real
///   per-keystroke gen cost while typing.
/// - single: one cold completion per sentence (cache reset each) → the pause-latency
///   we have today.
/// Output:   {"id":"r1","results":[{"sentence":..,"steps":[{"chars":N,"latencyMs":M,"completion":..}]}]}
@MainActor
enum DebugCompletionEndpoint {
    private static var lastMtime: Date = .distantPast
    private static var busy = false

    static func observeIfEnabled() {
        let env = ProcessInfo.processInfo.environment
        guard env["PROSPER_DEBUG_ENDPOINT"] == "1",
              let reqPath = env["PROSPER_DEBUG_REQ"], !reqPath.isEmpty,
              let outPath = env["PROSPER_DEBUG_OUT"], !outPath.isEmpty else { return }
        NSLog("prosper: debug completion endpoint watching \(reqPath)")
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            MainActor.assumeIsolated { poll(reqPath: reqPath, outPath: outPath) }
        }
    }

    private static func poll(reqPath: String, outPath: String) {
        guard !busy,
              let attrs = try? FileManager.default.attributesOfItem(atPath: reqPath),
              let mtime = attrs[.modificationDate] as? Date, mtime > lastMtime,
              let data = FileManager.default.contents(atPath: reqPath),
              let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        lastMtime = mtime
        busy = true
        let id = req["id"] as? String ?? "req"
        let mode = req["mode"] as? String ?? "typing"
        let sentences = req["sentences"] as? [String] ?? []
        let stepChars = max(1, req["stepChars"] as? Int ?? 3)
        let minChars = max(2, req["minChars"] as? Int ?? 3)
        Task {
            try? await MLXEngine.shared.load { _, _ in }
            var results: [[String: Any]] = []
            for sentence in sentences {
                let chars = Array(sentence)
                var steps: [[String: Any]] = []
                if mode == "single" {
                    await MLXEngine.shared.resetInlineCache()
                    let (c, ms) = await completeOnce(before: sentence)
                    steps.append(["chars": chars.count, "latencyMs": ms, "completion": c ?? ""])
                } else {
                    await MLXEngine.shared.resetInlineCache()   // warm across the sentence's growth
                    var end = minChars
                    while end <= chars.count {
                        let prefix = String(chars[0..<end])
                        let (c, ms) = await completeOnce(before: prefix)
                        steps.append(["chars": end, "latencyMs": ms, "completion": c ?? "", "prefix": prefix])
                        end += stepChars
                    }
                }
                results.append(["sentence": sentence, "steps": steps])
            }
            let payload: [String: Any] = ["id": id, "mode": mode, "results": results]
            if let json = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
                try? json.write(to: URL(fileURLWithPath: outPath))
            }
            NSLog("prosper: debug endpoint wrote \(outPath) for id=\(id)")
            busy = false
        }
    }

    /// One rung-0 completion against the CURRENT (possibly warm) inline cache.
    /// Returns (sanitized completion, latencyMs). Same prompt build as complete().
    private static func completeOnce(before: String) async -> (String?, Int) {
        let length = Preferences.completionLength
        let language = CoreBridge.dominantLanguageName(of: before)
        let latinBg = CoreBridge.looksLikeTransliteratedBulgarian(before)
        let system = CoreBridge.completionSystemPrompt(
            custom: "", length: length,
            language: latinBg ? nil : language, transliteratedBulgarian: latinBg
        )
        let candidates = CompletionCandidates.derive(before: before, after: "", lexicon: Lexicon.shared)
        let prompt = CoreBridge.buildCompletionPrompt(
            before: before, after: "", clipboard: nil, candidates: candidates
        )
        let start = Date()
        let raw = try? await MLXEngine.shared.generateInlineRouted(
            prompt: prompt, system: system, maxTokens: length.maxTokens,
            temperature: 0.2, topP: 0.9, stop: ["\n"], maxWords: length.maxWords
        )
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let comp = raw.flatMap { CoreBridge.sanitizeCompletion($0, before: before, after: "") }
        return (comp, ms)
    }
}
