import Foundation

/// Headless inline-completion bench. Env-gated so it runs BEFORE any GUI/AppKit
/// init and exits — no window, no accessibility, no ghost overlay, no focus
/// stealing. It drives the SAME completion pipeline the live app uses
/// (`buildCompletionPrompt` + the retry ladder + `sanitizeCompletion`), so the
/// text it prints is what the ghost would show for that prefix, but ~10× faster
/// per case (one model load, then raw MLX generation instead of a GUI round-trip).
///
/// Use it for CONTENT/QUALITY iteration (language drift, echo, mid-word); use the
/// GUI+ghost bench for UI/UX feel (live-while-typing, rendering). Deliberately
/// omits OCR / clipboard / app-surface context so runs are deterministic — those
/// channels are off in the corpus cases anyway.
///
///   PROSPER_HEADLESS_BENCH=<corpus.json> [PROSPER_HEADLESS_OUT=<out.json>] \
///     [PROSPER_HEADLESS_IDS=lat02,lat29] ProsperApp
enum HeadlessBenchCLI {
    struct Case: Decodable { let id: String; let lang: String; let kind: String?
        let prefix: String; let expect: String?; let after: String? }
    struct Corpus: Decodable { let cases: [Case] }

    static func runIfRequested() {
        guard let corpusPath = ProcessInfo.processInfo.environment["PROSPER_HEADLESS_BENCH"],
              !corpusPath.isEmpty else { return }
        let env = ProcessInfo.processInfo.environment
        let outPath = env["PROSPER_HEADLESS_OUT"]
        let idFilter: Set<String>? = env["PROSPER_HEADLESS_IDS"].map {
            Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        }

        guard let data = FileManager.default.contents(atPath: corpusPath) else {
            FileHandle.standardError.write(Data("headless: cannot read \(corpusPath)\n".utf8)); exit(2)
        }
        var cases: [Case]
        if let c = try? JSONDecoder().decode(Corpus.self, from: data) { cases = c.cases }
        else if let arr = try? JSONDecoder().decode([Case].self, from: data) { cases = arr }
        else { FileHandle.standardError.write(Data("headless: bad corpus JSON\n".utf8)); exit(2) }
        if let idFilter { cases = cases.filter { idFilter.contains($0.id) } }

        print("headless: \(cases.count) cases, model=\(Preferences.coreModel)")
        let frozen = cases
        // Everything (load, generate loop, write, exit) runs inside the Task so no
        // mutable state crosses the actor boundary (Swift 6 Sendable). main just
        // parks on the semaphore; the Task terminates the process itself.
        Task {
            do { try await MLXEngine.shared.load { _, _ in } }
            catch { FileHandle.standardError.write(Data("headless: model load failed: \(error)\n".utf8)); exit(1) }
            var out: [[String: Any]] = []
            for c in frozen {
                // Each case is an unrelated prefix; drop the primed KV prefix so the
                // reuse-trim math can't go stale (that aborts MLX).
                await MLXEngine.shared.resetInlineCache()
                let start = Date()
                let (completion, detected, latinBg) = await complete(before: c.prefix, after: c.after ?? "")
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                // Replicate AutocompleteEngine.showInstantGhost's DECISION (pure part:
                // derive + the mid-word hasPrefix guard) so we can prove headlessly
                // whether the instant lexicon ghost would fire garbage or suppress.
                let ghost = instantGhostRemainder(shadow: c.prefix)
                print("  \(c.id) \(c.lang) → \(completion.map { "\"\($0)\"" } ?? "∅")  (\(ms)ms, \(detected ?? "auto")\(latinBg ? "+bg" : ""))  snap=\(ghost.map { "\"\($0)\"" } ?? "—")")
                out.append([
                    "id": c.id, "lang": c.lang, "kind": c.kind ?? "", "prefix": c.prefix,
                    "expect": c.expect ?? "", "completion": completion ?? "",
                    "latencyMs": ms, "detectedLang": detected ?? "", "latinBg": latinBg,
                    "instantSnap": ghost ?? "",
                ])
            }
            let payload: [String: Any] = ["tool": "prosper-headless", "results": out]
            if let outPath, let json = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
                try? json.write(to: URL(fileURLWithPath: outPath))
                print("headless: wrote \(outPath)")
            }
            exit(0)
        }
        // Block forever; the Task above calls exit().
        RunLoop.main.run()
    }

    /// Pure replica of `AutocompleteEngine.showInstantGhost`'s ghost-text decision:
    /// what (if anything) the instant lexicon ghost would render for this shadow.
    /// Returns nil when it would suppress (no instant ghost). Same guards: shadow
    /// ≥2, and mid-word requires the candidate word to actually start with the
    /// fragment. If this returns a bad word for a Cyrillic-transliterated fragment,
    /// the artifact IS a real product bug, not a bench-capture quirk.
    private static func instantGhostRemainder(shadow: String) -> String? {
        guard shadow.count >= 2 else { return nil }
        let cands = CompletionCandidates.derive(before: shadow, after: "", lexicon: Lexicon.shared)
        guard let word = cands.words.first else { return nil }
        if cands.atBoundary { return " " + word }
        let frag = cands.fragment
        guard word.hasPrefix(frag), word != frag else { return nil }
        let remainder = String(word.dropFirst(frag.count))
        return remainder.isEmpty ? nil : remainder
    }

    /// Mirrors `CoreBridge.complete()`'s core: build the same prompt + system, run
    /// the same temperature/reprompt ladder, sanitize identically. Returns the
    /// completion (nil if the ladder never produced one), the detected language,
    /// and whether the transliterated-Bulgarian steer fired.
    private static func complete(before: String, after: String) async -> (String?, String?, Bool) {
        let length = Preferences.completionLength
        let maxTokens = length.maxTokens
        let maxWords = length.maxWords
        let detected = CoreBridge.dominantLanguageName(of: before)
        // Mirror CoreBridge.complete()'s Bulgarian-Cyrillic pin (short Cyrillic
        // context detects as nil/Russian and the model completes in Russian).
        let language = CoreBridge.shouldPinBulgarianCyrillic(before: before, detected: detected)
            ? "Bulgarian" : detected
        let latinBg = CoreBridge.looksLikeTransliteratedBulgarian(before)
        let bgCyrillic = language == "Bulgarian" && CoreBridge.isCyrillicScript(before)
        // A/B: PROSPER_MINIMAL=1 strips all language rules / candidate hints / persona
        // to test whether Gemma continues (esp. latinica) MORE naturally when we stop
        // instructing it — the "Cotypist got it first try, same model" hypothesis.
        let minimal = ProcessInfo.processInfo.environment["PROSPER_MINIMAL"] == "1"
        // A/B: PROSPER_SEED_SAMPLES=<file> feeds newline-delimited examples of the
        // user's own writing straight into the prompt (the previousUserInputs
        // block) WITHOUT touching the on-disk corpus — so we can measure whether
        // few-shot voice grounding fixes latinica drift before wiring live.
        let seedSamples: [String] = {
            guard let p = ProcessInfo.processInfo.environment["PROSPER_SEED_SAMPLES"],
                  let txt = try? String(contentsOfFile: p, encoding: .utf8) else { return [] }
            return txt.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }()
        let system: String
        let prompt: String
        let nudgedPrompt: String
        let nudge = "IMPORTANT: You must output a continuation — returning "
            + "nothing or an empty answer is not allowed. Even if the text "
            + "already reads as complete, write the next few words the user "
            + "would most plausibly type (up to \(maxWords) words). Do not "
            + "repeat words already in the text. Write in the same language "
            + "as the text\(language.map { " (\($0))" } ?? "").\n\n"
        if minimal {
            system = "Continue the user's text inline, like a phone keyboard. Output ONLY "
                + "the few words that come next in the SAME language and script — nothing else."
            prompt = before
            nudgedPrompt = nudge + before
        } else {
            system = CoreBridge.completionSystemPrompt(
                custom: "", length: length,
                language: latinBg ? nil : language, transliteratedBulgarian: latinBg,
                userLanguages: CoreBridge.osLanguagesList()
            )
            prompt = CoreBridge.buildCompletionPrompt(
                before: before, after: after, clipboard: nil,
                writingSamples: seedSamples,
                reservedSystemChars: system.count
            )
            // Reprompt rungs carry the nudge as a `directive` INSIDE the prompt
            // (shared context prefix, KV-cache-friendly) — same as CoreBridge.
            nudgedPrompt = CoreBridge.buildCompletionPrompt(
                before: before, after: after, clipboard: nil,
                writingSamples: seedSamples,
                directive: nudge,
                reservedSystemChars: system.count
            )
        }
        // Mirror CoreBridge.complete()'s ladder EXACTLY so the bench measures the
        // shipping path: GREEDY first rung (deterministic per context — the ghost
        // stability lever) except for transliterated Bulgarian, where greedy
        // argmax collapses to empty on ambiguous Latin-Slavic text (regress:
        // latinica coverage 90% vs 98%) and the gemma-native sampled rung stays.
        // PROSPER_TEMP0/PROSPER_TOPP0 still override rung-0 for A/B.
        let env = ProcessInfo.processInfo.environment
        typealias Rung = (temperature: Float, topK: Int?, topP: Float, reprompt: Bool)
        let defaultTemp0: Float = latinBg ? 1.0 : 0.0
        let temp0 = Float(env["PROSPER_TEMP0"] ?? "") ?? defaultTemp0
        let attempts: [Rung] = [
            (temp0, temp0 == 0 ? nil : 64, Float(env["PROSPER_TOPP0"] ?? "") ?? (temp0 == 0 ? 1.0 : 0.95), false),
            (1.0, 64, 0.95, false),  // plain sampled retry (recovers greedy-empty)
            (1.0, 64, 0.95, true),
            (0.8, 64, 0.95, true),
        ]
        for (temp, topK, topp, reprompt) in attempts {
            do {
                let raw = try await MLXEngine.shared.generateInlineRouted(
                    prompt: reprompt ? nudgedPrompt : prompt, system: system,
                    maxTokens: maxTokens, temperature: temp, topP: topp, stop: ["\n"],
                    maxWords: maxWords, topK: topK
                )
                if let s = CoreBridge.sanitizeCompletion(raw, before: before, after: after,
                                                         transliterateCyrillic: latinBg,
                                                         bulgarianCyrillic: bgCyrillic), !s.isEmpty,
                   !CoreBridge.echoesWritingSample(s, samples: seedSamples) {
                    return (s, language, latinBg)
                }
            } catch { /* climb the ladder */ }
        }
        return (nil, language, latinBg)
    }
}
