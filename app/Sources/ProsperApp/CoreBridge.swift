import AppKit
import Foundation
import NaturalLanguage

// MARK: - Codable models

struct Health: Codable {
    let ok: Bool
    let ollama: Bool
    let model: Bool
    let message: String
}

struct TranslationCandidate: Codable {
    let text: String
    let label: String?
    let explanation: String?
}

struct TranslationResult: Codable {
    let detectedLanguage: String?
    let primary: String
    let candidates: [TranslationCandidate]

    init(detectedLanguage: String?, primary: String, candidates: [TranslationCandidate]) {
        self.detectedLanguage = detectedLanguage
        self.primary = primary
        self.candidates = candidates
    }

    private enum CodingKeys: String, CodingKey {
        case detectedLanguage, primary, candidates
    }

    /// Tolerant decode. The prompt asks for `"primary": string`, but smaller
    /// models often emit it as a candidate object `{"text": ...}` (the same shape
    /// as `candidates`). Strict decoding would fail and dump raw JSON to the user.
    /// Accept a plain string, an object with `.text`, or fall back to the first
    /// candidate.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detectedLanguage = try c.decodeIfPresent(String.self, forKey: .detectedLanguage)
        candidates = (try? c.decode([TranslationCandidate].self, forKey: .candidates)) ?? []
        if let s = try? c.decode(String.self, forKey: .primary), !s.isEmpty {
            primary = s
        } else if let obj = try? c.decode(TranslationCandidate.self, forKey: .primary) {
            primary = obj.text
        } else {
            primary = candidates.first?.text ?? ""
        }
    }
}

struct Suggestion: Codable {
    let suggestion: String?
    let error: String?
}

struct SetupProgress: Codable {
    let phase: String
    let status: String
    let completed: UInt64?
    let total: UInt64?
    let percent: Double?
}

// MARK: - CoreBridge

/// Swift facade over the inference engine. Previously backed by the Rust
/// `prosper_core` C ABI; now reimplemented on top of `MLXEngine` (Apple MLX).
/// The public method signatures and main-queue callback contract are preserved
/// so the UI layer (RunnerPanel, ModelSetup, AutocompleteEngine, MenuBar)
/// keeps compiling unchanged.
enum CoreBridge {

    // Translation system prompt — ported verbatim from the Rust core
    // (core/src/translate.rs SYSTEM_PROMPT) so behavior is unchanged.
    private static let translationSystemPrompt = """
    You are a professional translator with native fluency in every language. You \
    translate the text the user gives you and respond with STRICTLY a single JSON \
    object — no markdown, no code fences, no prose before or after it.

    Translate faithfully: preserve the original meaning, tone, register \
    (formal/casual), and intent. Do not answer, explain, censor, add to, or omit \
    from the text — only translate it. Keep names, numbers, URLs, code, and \
    placeholders intact, and mirror the input's formatting.

    The JSON must have this exact shape:
    {"detectedLanguage": string, "primary": string, "candidates": [{"text": string, "label": string, "explanation": string}]}
    - "detectedLanguage": the source language you detected (e.g. "en", "bg").
    - "primary": your single best translation, as a PLAIN STRING (never an object).
    - "candidates": 2 to 5 distinct alternatives, including the primary. Each has \
    "text" (the alternative), "label" (1-2 words: formal, casual, literal, \
    idiomatic, slang, …), and "explanation" (under 12 words on when to use it).

    CRITICAL: write every "label" and "explanation" in the TARGET language the user \
    asks for — never in the source language. The reader understands the target \
    language, not necessarily the source. If the input is a single word, give its \
    distinct senses or forms as the candidates.
    """

    // Stage-1 translation system prompt. The single best translation is produced
    // on its own, focused pass — small models (gemma e2b) bleed sister-language
    // spellings (Russian/Ukrainian into Bulgarian, etc.) when also forced to emit
    // labels, notes and alternatives as structured JSON in one shot. Isolating the
    // primary, with a hard orthography constraint and no JSON envelope, gives the
    // word the user actually pastes the best shot at correct native spelling.
    private static let primaryTranslationSystemPrompt = """
    You are a precise, faithful translator. Output ONLY the single best \
    translation of the user's text — nothing else. No quotes, no labels, no \
    explanation, no alternatives, no notes, no surrounding text.

    Use only correct, standard spelling, alphabet, and vocabulary of the target \
    language. Never use words, letters, or spellings borrowed from any other \
    language — especially closely related ones that share an alphabet (for \
    Bulgarian, never Russian or Ukrainian spellings; write "съществително", never \
    "существително"; "въплътен", never "втілесно").

    Preserve the original meaning, tone, and register (formal/casual). Do not \
    answer, explain, censor, add to, or omit from the text — only translate it. \
    Keep names, numbers, URLs, code, and placeholders intact.
    """

    // Stage-3 refinement system prompt. When the draft (stage 2) leaks a sister
    // language, instead of dropping the offending alternatives we hand the draft
    // back to the model as a proofreading task — easier than generation, and it
    // FIXES the words rather than removing them, so the candidate count and senses
    // are preserved. Catches both foreign-letter leaks and same-alphabet
    // misspellings that a character check cannot see.
    private static let refineTranslationSystemPrompt = """
    You are a meticulous proofreader. You receive a JSON object of translations \
    that may contain mistakes. Rewrite it so that EVERY string value — "primary", \
    and each candidate's "text", "label", and "explanation" — is correct, standard, \
    natural language of the requested target.

    Fix any word that is misspelled or borrowed from another language, especially a \
    closely related one that shares the alphabet (for Bulgarian, replace Russian or \
    Ukrainian forms with the correct Bulgarian word: "съществително" not \
    "существително"; "въплътен"/"въплътено" not "втілесно"; never use the letters \
    ы э ё і ї є ґ in Bulgarian).

    Keep the SAME JSON shape, the SAME number of candidates, and the SAME meaning, \
    sense, and register of each entry — only correct the language. Respond with \
    STRICTLY the corrected JSON object: no markdown, no code fences, no prose.

    Shape: {"detectedLanguage": string, "primary": string, "candidates": [{"text": \
    string, "label": string, "explanation": string}]}
    """

    // MARK: init

    /// No-op compatibility shim. The MLX engine has no connection/host config;
    /// the model id is read from `Preferences`. Kept so existing callers compile.
    @discardableResult
    static func initialize(host: String, model: String, timeoutMs: Int) -> Bool {
        return true
    }

    // MARK: health

    /// Reports model-loaded state. There is no Ollama daemon anymore, so `ollama`
    /// mirrors the model-loaded flag for backward compatibility with callers that
    /// check it (e.g. ModelSetup readiness gate).
    static func health(completion: @escaping @MainActor @Sendable (Health?) -> Void) {
        Task {
            let loaded = await MLXEngine.shared.isLoaded
            let result = Health(
                ok: loaded,
                ollama: loaded,
                model: loaded,
                message: loaded ? "Model loaded." : "Model not loaded."
            )
            await MainActor.run { completion(result) }
        }
    }

    // MARK: ensureModel

    /// Downloads + loads the model via `MLXEngine.load`, forwarding progress as a
    /// `SetupProgress` (fraction expressed as `percent` 0..100). Completion fires
    /// on the main queue with success/failure.
    static func ensureModel(
        progress: @escaping @MainActor @Sendable (SetupProgress) -> Void,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        Task {
            do {
                try await MLXEngine.shared.load { fraction, status in
                    let pct = max(0.0, min(fraction, 1.0)) * 100.0
                    let phase = fraction >= 1.0 ? "done" : "download"
                    let update = SetupProgress(
                        phase: phase,
                        status: status,
                        completed: nil,
                        total: nil,
                        percent: pct
                    )
                    Task { @MainActor in progress(update) }
                }
                await MainActor.run { completion(true) }
                // Warm the kernels/buffer pool off the readiness path so the first
                // real completion isn't paid cold.
                Task { await MLXEngine.shared.warmup() }
                // WS2: when speculative decoding is enabled, load the draft model off
                // the readiness path (best-effort, lazy, idempotent). On failure the
                // draft stays unloaded and `generateInlineRouted` keeps using the
                // single-model path — never worse than today.
                if Preferences.speculativeDecodingEnabled {
                    Task { try? await MLXEngine.shared.loadDraft { _, _ in } }
                }
                // WS6: when a trained LoRA adapter is active, load it off the readiness
                // path (best-effort, gated, idempotent). On failure the adapter stays
                // unloaded and inference is byte-identical to the base model. Gated on
                // the per-session A/B arm, NOT `loraServingActive` directly: a fraction
                // of sessions are held out as baseline (adapter NOT loaded) so both A/B
                // arms accrue samples and `LoRAEvaluator.shouldDisable` can fire.
                if LoRAEvaluator.sessionServesAdapter {
                    Task { await MLXEngine.shared.loadAdapter() }
                }
            } catch {
                NSLog("ProsperModelLoad error for \(Preferences.coreModel): \(error)")
                let update = SetupProgress(
                    phase: "error",
                    status: error.localizedDescription,
                    completed: nil,
                    total: nil,
                    percent: nil
                )
                await MainActor.run {
                    progress(update)
                    completion(false)
                }
            }
        }
    }

    /// Live-switch the running model to the currently-selected `Preferences.coreModel`:
    /// drops the old weights, then downloads (if missing) + loads + warms the new model
    /// through the SAME path as `ensureModel` (which also reloads the draft + LoRA
    /// adapter for the new model). Surfaces download progress so the picker can show the
    /// setup window. No app restart required.
    static func switchModel(
        progress: @escaping @MainActor @Sendable (SetupProgress) -> Void,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        Task {
            await MLXEngine.shared.prepareSwitch(to: Preferences.coreModel)
            ensureModel(progress: progress, completion: completion)
        }
    }

    /// Aborts an in-flight model load/download started by `ensureModel` /
    /// `switchModel`. Cancels the load task and frees any partial state via
    /// `MLXEngine.unload`. The pending `completion(false)` still fires.
    static func cancelModelLoad() {
        Task { await MLXEngine.shared.requestUnload() }
    }

    // MARK: translate

    static func translate(
        _ input: String,
        target: String,
        source: String?,
        completion: @escaping @MainActor @Sendable (TranslationResult?) -> Void
    ) {
        Task {
            do {
                // Lazy-load: the model is resident only while inline autocomplete is
                // on, so a host.llm/Translate call may arrive cold. `load` is
                // idempotent (no-op when already resident).
                try await MLXEngine.shared.load { _, _ in }
                // Stage 1 — the single best translation, on a focused pass for
                // maximum orthographic accuracy (this is the word the user pastes).
                let primaryPrompt = buildPrimaryTranslationPrompt(
                    input: input, target: target, source: source)
                let primaryRaw = try await MLXEngine.shared.generate(
                    prompt: primaryPrompt,
                    system: primaryTranslationSystemPrompt,
                    maxTokens: 96,
                    temperature: 0
                )
                let primary = cleanPrimaryTranslation(primaryRaw)

                // Stage 2 — alternatives + detected language (best-effort
                // enrichment). A leak here is cosmetic: extras are deduped against
                // the authoritative stage-1 primary and shown only as suggestions.
                let prompt = buildTranslationPrompt(input: input, target: target, source: source)
                let raw = try await MLXEngine.shared.generate(
                    prompt: prompt,
                    system: translationSystemPrompt,
                    maxTokens: 320,
                    temperature: 0
                )
                var enriched = parseTranslation(raw)

                // Stage 3 — refinement. Small models leak sister-language spellings
                // into the alternatives (Ukrainian/Russian into Bulgarian, …). A
                // character check is a cheap leak *detector*, but dropping the
                // offenders shrinks the list and can't see same-alphabet
                // misspellings. So when a leak is detected we hand the draft back to
                // the model to REWRITE every field in correct target language —
                // fixing the words while preserving their number and sense. The
                // common (clean) case skips this entirely, so it costs nothing then.
                let isForeign = foreignTextDetector(forTarget: target)
                let leaked = isForeign.map { f in
                    enriched.candidates.contains { f($0.text) }
                } ?? false
                if leaked, let refined = await refineTranslation(enriched, target: target) {
                    enriched = refined
                }

                // Final safety net: if refinement still left a foreign-letter
                // candidate (or no refinement ran), drop the residue so a clearly
                // wrong-alphabet word never reaches the user.
                let candidates = filterForeignCandidates(enriched.candidates, target: target)

                // Authoritative primary from stage 1; fall back to stage 2 only if
                // stage 1 produced nothing usable.
                let result = primary.isEmpty
                    ? TranslationResult(
                        detectedLanguage: enriched.detectedLanguage,
                        primary: enriched.primary,
                        candidates: candidates)
                    : TranslationResult(
                        detectedLanguage: enriched.detectedLanguage,
                        primary: primary,
                        candidates: candidates)
                await MainActor.run {
                    ModelIdleUnloader.shared.noteUsage()
                    completion(result)
                }
            } catch {
                await MainActor.run {
                    ModelIdleUnloader.shared.noteUsage()
                    completion(nil)
                }
            }
        }
    }

    /// Stage-3 refinement: re-prompt the model with its own draft and ask it to
    /// rewrite every field in correct target language, preserving structure, count,
    /// and sense. Returns the corrected result, or nil if generation/parse fails
    /// (caller then keeps the draft + the character-level net).
    private static func refineTranslation(
        _ draft: TranslationResult, target: String
    ) async -> TranslationResult? {
        guard let payload = encodeTranslation(draft) else { return nil }
        let resolvedTarget = target.trimmingCharacters(in: .whitespaces).isEmpty
            ? "English"
            : target.trimmingCharacters(in: .whitespaces)
        let nativeLine = nativeTargetDirective(forTarget: resolvedTarget).map { "\($0)\n" } ?? ""
        let prompt = """
        \(nativeLine)Target language: \(resolvedTarget).
        Correct the following translation JSON so every value is proper \(resolvedTarget):

        \(payload)
        """
        guard let raw = try? await MLXEngine.shared.generate(
            prompt: prompt,
            system: refineTranslationSystemPrompt,
            maxTokens: 320,
            temperature: 0
        ) else { return nil }
        let refined = parseTranslation(raw)
        // Guard against a degenerate refinement that returned nothing usable.
        guard !refined.primary.isEmpty || !refined.candidates.isEmpty else { return nil }
        return refined
    }

    /// Serialize a `TranslationResult` back to the compact JSON the refinement
    /// prompt expects (mirrors the model's own output shape).
    private static func encodeTranslation(_ r: TranslationResult) -> String? {
        let obj: [String: Any] = [
            "detectedLanguage": r.detectedLanguage ?? "",
            "primary": r.primary,
            "candidates": r.candidates.map { c -> [String: String] in
                var item = ["text": c.text]
                if let l = c.label { item["label"] = l }
                if let e = c.explanation { item["explanation"] = e }
                return item
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// Strip a stage-1 primary translation down to the bare text: drop code
    /// fences, take the first non-empty line, and remove wrapping quotes the model
    /// sometimes adds despite being told not to.
    private static func cleanPrimaryTranslation(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a ```...``` fence if the model wrapped the answer in one.
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // First non-empty line (focused prompt should yield exactly one).
        if let line = s.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) {
            s = line
        }
        // Strip a single pair of wrapping quotes (straight or typographic).
        for (open, close) in [("\"", "\""), ("'", "'"), ("“", "”"), ("«", "»")] {
            if s.hasPrefix(open), s.hasSuffix(close), s.count >= 2 {
                s = String(s.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return s
    }

    /// Remove candidates that contain a letter foreign to the target language's
    /// alphabet. Only languages with a known alphabet are policed; for any other
    /// target the candidates pass through unchanged.
    static func filterForeignCandidates(
        _ candidates: [TranslationCandidate], target: String
    ) -> [TranslationCandidate] {
        guard let isForeign = foreignTextDetector(forTarget: target) else { return candidates }
        return candidates.filter { !isForeign($0.text) }
    }

    /// Lowercase alphabets keyed by language name and ISO code. Only Cyrillic-
    /// script languages are listed: that is where small models confuse closely
    /// related alphabets (e.g. leaking Ukrainian `і` or Russian `э` into a
    /// Bulgarian translation). Each set is exactly the letters that language uses,
    /// so any Cyrillic letter NOT in the set is, by definition, foreign to it —
    /// which is how a Russian target now also rejects Ukrainian-only letters, etc.
    /// Latin and other scripts are intentionally absent: they fail differently
    /// (diacritics, not foreign letters), so an unlisted target disables filtering.
    private static let cyrillicAlphabets: [String: Set<Character>] = {
        let table: [(letters: String, keys: [String])] = [
            ("абвгдежзийклмнопрстуфхцчшщъьюя",
             ["bulgarian", "bg", "bul", "български"]),
            ("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
             ["russian", "ru", "rus", "русский"]),
            ("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя",
             ["ukrainian", "uk", "ua", "ukr", "українська"]),
        ]
        var map: [String: Set<Character>] = [:]
        for entry in table {
            let set = Set(entry.letters)
            for key in entry.keys { map[key] = set }
        }
        return map
    }()

    /// True for a scalar belonging to a "hard-foreign" script — one whose presence
    /// in a Cyrillic-script translation is unambiguously wrong (a whole-other-script
    /// leak, e.g. Chinese 福音 or Japanese kana surfacing for a Bulgarian target).
    /// Latin is deliberately NOT here: loanwords, names, and codes legitimately use
    /// it. These are the blocks small models most often slip into.
    private static func isHardForeignScalar(_ v: UInt32) -> Bool {
        switch v {
        case 0x0370...0x03FF, 0x1F00...0x1FFF:  // Greek (+ extended)
            return true
        case 0x0590...0x05FF:  // Hebrew
            return true
        case 0x0600...0x06FF, 0x0750...0x077F:  // Arabic (+ supplement)
            return true
        case 0x0900...0x097F:  // Devanagari
            return true
        case 0x0E00...0x0E7F:  // Thai
            return true
        case 0x1100...0x11FF, 0xAC00...0xD7AF:  // Hangul (Jamo + syllables)
            return true
        case 0x3040...0x309F, 0x30A0...0x30FF:  // Hiragana, Katakana
            return true
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:  // CJK (ext-A, unified, compat)
            return true
        case 0x20000...0x2FA1F:  // CJK supplementary planes
            return true
        default:
            return false
        }
    }

    /// Maps a target-language name/code to a predicate that returns true when the
    /// text is foreign to that target: either a Cyrillic letter outside the
    /// target's alphabet (sister-language leak), or any character from a wholly
    /// different non-Latin script (CJK, kana, Hangul, Arabic, …). Returns nil
    /// (filtering disabled) for any language without a known alphabet.
    private static func foreignTextDetector(forTarget target: String) -> ((String) -> Bool)? {
        let key = target.trimmingCharacters(in: .whitespaces).lowercased()
        guard let allowed = cyrillicAlphabets[key] else { return nil }
        return { text in
            for ch in text.lowercased() {
                for scalar in ch.unicodeScalars {
                    let v = scalar.value
                    // Whole-other-script leak (the common small-model failure that
                    // the Cyrillic-only check below could never see).
                    if isHardForeignScalar(v) { return true }
                    // A Cyrillic letter not in this language's alphabet.
                    if (0x0400...0x04FF).contains(v), !allowed.contains(ch) { return true }
                }
            }
            return false
        }
    }

    /// A short imperative, written IN the target language, telling the model to
    /// answer only in that language. Small models steer far more reliably when the
    /// instruction itself is in the target tongue than when an English sentence
    /// merely names it. Only languages we have a hand-checked native phrasing for
    /// are listed; any other target returns nil (the English prompt, which already
    /// names the target, is left to do the work). Keyed by the same names/codes as
    /// `cyrillicAlphabets`.
    private static let nativeTargetDirectives: [String: String] = {
        let table: [(directive: String, keys: [String])] = [
            ("ВАЖНО: Превеждай само на български език. Използвай единствено български думи и букви — никога руски, украински или думи от друг език.",
             ["bulgarian", "bg", "bul", "български"]),
            ("ВАЖНО: Переводи только на русский язык. Используй только русские слова и буквы — никакие другие языки.",
             ["russian", "ru", "rus", "русский"]),
            ("ВАЖЛИВО: Перекладай лише українською мовою. Використовуй лише українські слова та літери — жодних інших мов.",
             ["ukrainian", "uk", "ua", "ukr", "українська"]),
        ]
        var map: [String: String] = [:]
        for entry in table {
            for key in entry.keys { map[key] = entry.directive }
        }
        return map
    }()

    /// Native-language directive for `target`, or nil when none is known.
    private static func nativeTargetDirective(forTarget target: String) -> String? {
        nativeTargetDirectives[target.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    // MARK: complete

    /// Requests an inline completion. Returns the backing `Task` so the caller can
    /// `cancel()` it the instant the request is superseded (next keystroke) —
    /// cancellation propagates into `MLXEngine.generate`, which aborts prefill/decode
    /// rather than draining the GPU on output that will be discarded anyway.
    @discardableResult
    static func complete(
        before: String,
        after: String,
        bundleId: String? = nil,
        caretScreenRect: CGRect? = nil,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) -> Task<Void, Never> {
        // Agent mode owns the GPU + RAM: the inline model is unloaded while a coding
        // agent run is active (ModelResidencyCoordinator). Skip silently rather than
        // trigger a multi-GB reload that would fight the agent for memory.
        if ModelResidencyCoordinator.isAgentActive {
            TraceLog.emit("complete: skipped — coding agent owns the GPU")
            return Task { await MainActor.run { completion(nil) } }
        }
        let length = Preferences.completionLength
        let maxTokens = length.maxTokens
        let maxWords = length.maxWords
        // Pin the completion language to the language the user is typing in —
        // detection is on-device and stable while typing the same text, so the
        // system prompt (KV-cache prefix) only re-prefills on a genuine switch.
        let language = dominantLanguageName(of: before)
        let system = completionSystemPrompt(
            custom: AppOverrideResolver.effectivePromptAddendum(forBundleId: bundleId),
            length: length, language: language
        )
        let clipboard = Preferences.useClipboardContext ? clipboardContextSnippet() : nil
        let personalize = Preferences.collectTypingHistory && Preferences.personalizeWordChoice > 0
        // On-screen text context: recognize text near the caret (Vision/ANE) and
        // feed it to the *text* model — recovers context in Electron/Chromium apps
        // where AX exposes little. Both the "screenshots" and "OCR" toggles now feed
        // this single cheap channel: inline completion never runs the multimodal
        // VLM image path, which costs seconds per keystroke and made typing feel
        // dead. OCR is captured through `ScreenContextCache` (throttled + cached),
        // so the hot path never blocks on a screenshot. Requires Screen Recording
        // permission; off by default.
        let wantsScreenText = Preferences.useScreenshotContext || Preferences.useOCRContext

        return Task {
            let frequentWords = personalize ? await TypingHistoryStore.shared.frequentWords() : []
            // Non-LLM candidates: bundled-lexicon prefix/bigram/typo prediction +
            // the OS lexicon, fed to the model as hints (it always runs). This is
            // what keeps "website d" continuing as "ownload" instead of the model
            // regurgitating a word already on screen. See CompletionCandidates.
            let fragment = CompletionCandidates.trailingWord(before)
            let osCompletions = fragment.isEmpty ? [] : await osLexiconCompletions(for: fragment)
            let candidates = CompletionCandidates.derive(
                before: before, after: after,
                lexicon: Lexicon.shared, osCompletions: osCompletions
            )
            // App context: name + writing surface (chat/email/code/…) so the model
            // matches the tone and length the situation calls for. For browsers and
            // Electron apps the active web host is the most specific context (e.g.
            // web.telegram.org → chat), so prefer it and infer the surface from it.
            // Resolved before OCR because the surface decides *how* we capture.
            let profile = AppProfile.profile(for: bundleId)
            let appName = AppProfile.displayName(for: bundleId)
            let siteHost: String? = await MainActor.run {
                if profile.kind == .browser { return BrowserURL.currentHost() }
                if profile.isElectron, ChromiumPasteboard.hasChromiumFlavors() {
                    return ChromiumPasteboard.sourceHost()
                }
                return nil
            }
            let appSurface = siteHost != nil
                ? AppProfile.surface(forHost: siteHost)
                : AppProfile.surface(for: bundleId, kind: profile.kind)
            // OCR context. On a conversational surface (chat/email/social) the dialog
            // scrolls *above* the input field, so capture a tall region reaching
            // upward and feed it as conversation history; elsewhere grab the thin
            // band hugging the caret. Recovers context where AX exposes little
            // (Electron/Chromium, Qt apps like Telegram desktop). Read through the
            // throttled cache so repeated keystrokes reuse one capture instead of
            // OCR-ing the screen every time.
            let onScreenIsConversation = wantsScreenText && appSurface.isConversational
            let onScreenText: String? = (wantsScreenText && caretScreenRect != nil)
                ? await MainActor.run {
                    ScreenContextCache.shared.onScreenText(
                        around: caretScreenRect!, conversation: onScreenIsConversation
                    )
                }
                : nil
            let prompt = buildCompletionPrompt(
                before: before, after: after,
                clipboard: clipboard, frequentWords: frequentWords,
                hasImage: false, onScreenText: onScreenText,
                onScreenIsConversation: onScreenIsConversation && onScreenText != nil,
                candidates: candidates,
                appName: appName, appSurface: appSurface, siteHost: siteHost
            )
            // Quality tuning: low temperature for determinism, nucleus sampling,
            // hard stop at the first newline so a completion stays on one line, and
            // a word cap (maxWords) so decode stops as soon as the target word count
            // is reached — the primary latency lever now that accept is word-by-word.
            //
            // NOTE: we intentionally do NOT pass a repetition penalty. The vendored
            // mlx-swift-lm repetition-penalty processor aborts with a fatal
            // `[broadcast_shapes] Shapes (N) and (M) cannot be broadcast` for this
            // model whenever the prompt is longer than `repetitionContextSize`
            // (N = context size, M = sequence length) — an unrecoverable abort, not
            // a catchable error. Loop/echo suppression is instead handled by the
            // newline stop, the word cap, the short token budget, and `sanitizeCompletion`.
            // Superseded before we reached the model? Drop without touching the
            // engine — the next keystroke already scheduled a fresh request.
            if Task.isCancelled { return }
            // Cold-start guard (P0.4): unlike translate/generate, this path never
            // explicitly loaded the model — on the rare genuinely-cold case
            // (autocomplete just toggled on, model still warming) the first
            // generation would race the next keystroke's cancel and silently drop.
            // load() is idempotent and coalesced (no-op once resident), so the warm
            // path pays nothing; the accessory stays `.thinking` meanwhile.
            do { try await MLXEngine.shared.load { _, _ in } }
            catch { if Task.isCancelled { return } }
            if Task.isCancelled { return }
            // Always-suggest contract: whether the text is "enough" is the USER's
            // decision, never the model's. If a generation comes back empty (or
            // sanitization eats it as an echo), retry up the ladder: first resample
            // with higher temperature, then REPROMPT with an explicit "you must
            // continue" directive. A new keystroke cancels this task, so the ladder
            // never races a fresh request; the nudged prompt changes the cached
            // prefix (one extra prefill) only on the retry rungs, so the common
            // first-try path is byte-identical to before.
            let nudge = "IMPORTANT: You must output a continuation — returning "
                + "nothing or an empty answer is not allowed. Even if the text "
                + "already reads as complete, write the next few words the user "
                + "would most plausibly type (up to \(maxWords) words). Do not "
                + "repeat words already in the text. Write in the same language "
                + "as the text\(language.map { " (\($0))" } ?? "").\n\n"
            let attempts: [(temperature: Float, reprompt: Bool)] = [
                (0.2, false),  // normal: deterministic, cached prompt prefix
                (0.5, false),  // resample: same prompt, more diverse sampling
                (0.7, true),   // reprompt: explicit must-continue directive
                (0.8, true),
                (0.9, true),
                (1.0, true),   // last try: maximum diversity + directive
            ]
            var result: String?
            var rungsRun = 0
            for attempt in attempts {
                if Task.isCancelled { return }
                rungsRun += 1
                do {
                    // Always the text path: a fast single-line completion. Visual
                    // context arrives as cheap cached OCR text in the prompt, never
                    // the multimodal VLM image path (too slow for per-keystroke
                    // inline). `generateInline` reuses the KV cache across
                    // keystrokes, re-prefilling only the tokens that changed since
                    // the last completion. `generateInlineRouted` picks the decode
                    // path internally (WS2): the speculative iterator when
                    // enabled+draft-loaded, else this same single-model
                    // `generateInline` — so this call site is unchanged.
                    let raw = try await MLXEngine.shared.generateInlineRouted(
                        prompt: attempt.reprompt ? nudge + prompt : prompt,
                        system: system,
                        maxTokens: maxTokens, temperature: attempt.temperature,
                        topP: 0.9, stop: ["\n"], maxWords: maxWords
                    )
                    if let suggestion = sanitizeCompletion(raw, before: before, after: after),
                       !suggestion.isEmpty {
                        result = suggestion
                        break
                    }
                } catch {
                    if Task.isCancelled { return }
                    // Transient engine error (e.g. a guarded MLX runtime error):
                    // treat like an empty result and climb to the next rung.
                    NSLog("prosper complete: attempt failed (temp %.1f): %@",
                          attempt.temperature, String(describing: error))
                }
            }
            TraceLog.emit("complete: \(result == nil ? "EMPTY" : "ok(\(result!.count)ch)") after \(rungsRun) rung(s), lang=\(language ?? "auto")")
            await MainActor.run { completion(result) }
        }
    }

    /// Cleans raw model output into a usable inline continuation, or nil.
    /// - strips surrounding quotes/backticks and a leading restatement of `before`
    /// - removes a leading overlap where the model re-emits the tail of `before`
    /// - rejects any echo of text already written (leading, interior, or of the
    ///   text after the caret) and cuts internal word/phrase loops
    /// - collapses runaway whitespace and trims trailing blank lines
    static func sanitizeCompletion(_ raw: String, before: String, after: String = "") -> String? {
        var s = raw

        // Strip a leading code fence the model may have wrapped output in.
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
            if let fence = s.range(of: "```") { s = String(s[..<fence.lowerBound]) }
        }

        // Strip matched surrounding quotes/backticks.
        for q in ["\"", "'", "`"] {
            if s.hasPrefix(q) && s.hasSuffix(q) && s.count >= 2 {
                s = String(s.dropFirst().dropLast())
            }
        }

        // Prompt-scaffold guard: with near-empty context (a single word in a web
        // form) small instruct models sometimes parrot the INSTRUCTION instead of
        // continuing — the literal "Continue this text. Output only the
        // continuation:" ends up as the ghost. None of the echo guards below can
        // catch it (they compare against the user's text, not the prompt), so
        // reject any output containing a distinctive prompt/nudge phrase and let
        // the retry ladder reprompt.
        if Self.echoesPromptScaffold(s) { return nil }

        // Drop a leading overlap: the longest suffix of `before` that the model
        // re-emits at the head of `s` (it echoing what the user already typed). The
        // bound covers a full-line restatement, not just the last few words. We try
        // the raw head first, then a whitespace-trimmed head, since the model often
        // prefixes the echo with a stray space ("the quick" + " quick brown").
        let beforeTail = String(before.suffix(400))
        let tailChars = Array(beforeTail)
        if let stripped = Self.dropLeadingOverlap(s, tail: tailChars) {
            s = stripped
        } else {
            let lead = s.prefix { $0 == " " || $0 == "\t" }
            if !lead.isEmpty,
               let stripped = Self.dropLeadingOverlap(String(s.dropFirst(lead.count)), tail: tailChars) {
                s = stripped
            }
        }

        // Regurgitation guard: small models often re-emit a word that's already on
        // screen instead of continuing from the cursor. Worst case is mid-word: with
        // `before` = "website d" the model returns "website", which glues onto the
        // partial word as "dwebsite". `dropLeadingOverlap` can't catch this — the
        // echo isn't a prefix/suffix overlap, it's a word lifted from earlier in the
        // buffer. Drop the whole suggestion when its first word duplicates a recently
        // typed word, so we show nothing rather than garbage.
        if Self.echoesRecentWord(s, before: before) { return nil }

        // Regurgitation guard #2: head/middle echo. Instruct models (gemma-it) told
        // to "continue this text" often RESTATE the document instead of continuing it
        // — e.g. after "…what happens after " they emit "Dear team, thank", the
        // sentence's own opening. `dropLeadingOverlap` only catches an echo of the
        // *tail* of `before`; `echoesRecentWord` only the last word. Neither catches a
        // span lifted from the *start/middle*. Detect it: if the completion's leading
        // multi-word span appears verbatim earlier in `before`, it is a restatement —
        // show nothing rather than a duplicated, wrongly-capitalised fragment.
        if Self.echoesEarlierSpan(s, before: before) { return nil }

        // Language guard: a continuation in a visibly different script than the
        // user's text (Bulgarian typed, English suggested) is never wanted —
        // reject so the retry ladder reprompts instead of showing it.
        if Self.mismatchedScript(s, before: before) { return nil }

        // Regurgitation guard #3: interior echo. The leading-span guard above only
        // inspects the completion's HEAD; a suggestion can start fresh and then
        // lift a phrase verbatim from earlier text ("…thanks for the report. I
        // will" + "review thanks for the report"). Reject when ANY multi-word
        // window of the completion appears verbatim in `before` — the user never
        // wants to be offered words they already wrote.
        if Self.echoesAnywhere(s, before: before) { return nil }

        // Internal loop guard: small models sometimes stutter ("the the", "in the
        // in the …"). Cut the suggestion at the first immediate word/bigram repeat
        // so at least the clean head survives instead of showing the loop.
        s = Self.cutImmediateRepeat(s)

        // Mid-line gap fill: never re-emit what already sits AFTER the caret.
        // Drop the longest tail of the suggestion that equals the head of `after`
        // (the model "completing into" existing text); if the whole suggestion was
        // such an echo this leaves it empty and the final emptiness check rejects.
        if !after.isEmpty {
            s = Self.dropTrailingOverlap(s, afterHead: String(after.prefix(400)))
        }

        // Trim trailing blank lines, keep at most a single trailing newline run.
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        while s.hasSuffix("\n\n") { s = String(s.dropLast()) }

        let trimmedEnds = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedEnds.isEmpty ? nil : s.hasPrefix(" ") || s.hasPrefix("\n") ? s : trimmedEnds
    }

    /// Returns `s` with its longest leading run removed that equals a suffix of
    /// `tail` (the user's preceding text, as a char array), or nil if there is no
    /// overlap. Scans longest-first so the maximal echo is stripped.
    static func dropLeadingOverlap(_ s: String, tail: [Character]) -> String? {
        let sChars = Array(s)
        var overlap = min(tail.count, sChars.count)
        while overlap > 0 {
            if Array(tail.suffix(overlap)) == Array(sChars.prefix(overlap)) {
                return String(sChars.dropFirst(overlap))
            }
            overlap -= 1
        }
        return nil
    }

    /// True when the completion's first word duplicates a word the user just typed
    /// — the small-model "regurgitation" failure (e.g. continuing "website d" with
    /// "website"). Two cases are treated as echoes:
    ///   * mid-word: `before` ends without a separator, so the completion glues onto
    ///     the partial word; any first-word match against the last few typed words
    ///     is almost certainly an echo.
    ///   * otherwise: only an exact repeat of the immediately preceding word.
    /// First words shorter than 3 characters (a, to, the, …) are ignored, since
    /// short-word repeats are frequently legitimate.
    static func echoesRecentWord(_ s: String, before: String) -> Bool {
        let head = s.drop { $0 == " " || $0 == "\t" }
        let firstWord = String(head.prefix { $0.isLetter || $0.isNumber }).lowercased()
        guard firstWord.count >= 3 else { return false }
        let recentWords = before.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
        let midWord = before.last.map { $0.isLetter || $0.isNumber } ?? false
        if midWord, Set(recentWords.suffix(8)).contains(firstWord) { return true }
        return firstWord == recentWords.last
    }

    /// True when the completion's leading multi-word span appears verbatim somewhere
    /// in `before` — the instruct-model "restatement" failure, where the model echoes
    /// the document's own opening/middle instead of continuing it (e.g. after
    /// "…what happens after " it emits "Dear team, thank", the sentence's start).
    /// `dropLeadingOverlap`/`echoesRecentWord` only guard the tail/last word; this
    /// catches an interior span lifted from anywhere earlier.
    ///
    /// Normalises both sides (lowercase, collapse whitespace) and tests progressively
    /// shorter leading spans of the completion (5→2 words). A match counts only when
    /// the span is ≥12 chars AND ≥2 words, so legitimate short connectors
    /// ("of the", "and so") are not rejected. Returns true → caller shows nothing.
    static func echoesEarlierSpan(_ s: String, before: String) -> Bool {
        func norm(_ t: String) -> String {
            t.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                .joined(separator: " ")
        }
        let nBefore = norm(before)
        guard !nBefore.isEmpty else { return false }
        let compWords = norm(s).split(separator: " ").map(String.init)
        guard compWords.count >= 2 else { return false }
        var k = min(5, compWords.count)
        while k >= 2 {
            let span = compWords.prefix(k).joined(separator: " ")
            if span.count >= 12, nBefore.contains(span) { return true }
            k -= 1
        }
        return false
    }

    /// True when ANY 3-word window of the completion (≥12 chars, so legitimate
    /// short connectors like "of the and" survive) appears verbatim in `before`.
    /// Generalizes `echoesEarlierSpan` from the completion's head to its whole
    /// body: a suggestion that starts fresh but then lifts a phrase the user
    /// already wrote is still a regurgitation and must be rejected.
    /// Distinctive phrases from `buildCompletionPrompt`, the retry-ladder nudge,
    /// and the system prompt. A completion containing any of these is the model
    /// regurgitating its instructions, never user text — reject outright.
    private static let promptScaffoldPhrases: [String] = [
        "continue this text",
        "output only the continuation",
        "output only the text",
        "fill the gap at the cursor",
        "before cursor",
        "after cursor",
        "you must output a continuation",
        "do not repeat words already",
        "write in the same language",
        "suggested words (likely",
        "suggested completions of that word",
        "clipboard context (may be relevant",
        "on-screen text near the cursor",
        "the user frequently writes these words",
        "the conversation visible on screen",
        "output nothing",
        "inline autocomplete",
    ]

    /// True when the model parroted prompt scaffolding instead of continuing the
    /// user's text (happens with near-empty context). Case-insensitive contains.
    static func echoesPromptScaffold(_ s: String) -> Bool {
        let lower = s.lowercased()
        return Self.promptScaffoldPhrases.contains { lower.contains($0) }
    }

    static func echoesAnywhere(_ s: String, before: String) -> Bool {
        func norm(_ t: String) -> [String] {
            t.lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                .map(String.init)
        }
        let beforeNorm = norm(before).joined(separator: " ")
        guard !beforeNorm.isEmpty else { return false }
        let words = norm(s)
        guard words.count >= 3 else { return false }
        for i in 0...(words.count - 3) {
            let window = words[i ..< i + 3].joined(separator: " ")
            if window.count >= 12, beforeNorm.contains(window) { return true }
        }
        return false
    }

    /// Cuts the suggestion at the first immediate repetition — a word directly
    /// followed by itself ("the the") or a bigram directly followed by itself
    /// ("in the in the") — keeping the clean head. Case-insensitive; single-char
    /// repeats ("a a") are left alone (can be legitimate, and are harmless).
    /// Preserves the suggestion's leading whitespace (it carries word-boundary
    /// meaning for insertion).
    static func cutImmediateRepeat(_ s: String) -> String {
        let lead = String(s.prefix { $0 == " " || $0 == "\t" })
        let words = s.dropFirst(lead.count)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard words.count >= 2 else { return s }
        var cut = words.count
        for i in 0 ..< words.count - 1 {
            let a = words[i].lowercased()
            if a.count >= 2, a == words[i + 1].lowercased() { cut = i + 1; break }
            if i + 3 < words.count,
               a == words[i + 2].lowercased(),
               words[i + 1].lowercased() == words[i + 3].lowercased(),
               (a + words[i + 1]).count >= 4 {
                cut = i + 2
                break
            }
        }
        guard cut < words.count else { return s }
        return lead + words.prefix(cut).joined(separator: " ")
    }

    /// English display name of the dominant language of `text` ("Bulgarian",
    /// "German", …), or nil when detection is not confident / text is too short.
    /// Used to pin the completion language explicitly in the system prompt — a
    /// small model told merely to "match the language" still drifts to English;
    /// naming the language holds it. On-device (NaturalLanguage), microseconds.
    ///
    /// The confidence bar is HIGH on purpose: transliterated text (Bulgarian
    /// typed in Latin letters, "iskam da prodyljim…") confuses the recognizer
    /// into low-confidence guesses of other Latin-script languages; pinning a
    /// wrong language would be worse than no pin. Below the bar we return nil
    /// and the prompt falls back to the generic "match the text's language,
    /// never switch" rule, which imitates whatever the text looks like —
    /// including latinica.
    static func dominantLanguageName(of text: String) -> String? {
        let sample = String(text.suffix(300))
        guard sample.count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let lang = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang],
              confidence >= 0.8 else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: lang.rawValue)
    }

    /// True when the completion's script visibly disagrees with the script the
    /// user is writing in — e.g. Cyrillic (Bulgarian) text continued in Latin
    /// (English). Compares the dominant Unicode script of the letters on each
    /// side; both sides need ≥3 letters and ≥70% dominance before a mismatch is
    /// declared, so mixed text (a Bulgarian sentence quoting an English product
    /// name) and symbol-only completions are never rejected.
    static func mismatchedScript(_ s: String, before: String) -> Bool {
        func dominantScript(_ text: String) -> (script: String, share: Double, letters: Int)? {
            var counts: [String: Int] = [:]
            var total = 0
            for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
                let script: String
                switch scalar.value {
                case 0x0041...0x024F, 0x1E00...0x1EFF: script = "latin"
                case 0x0400...0x052F: script = "cyrillic"
                case 0x0370...0x03FF: script = "greek"
                case 0x0590...0x05FF: script = "hebrew"
                case 0x0600...0x06FF, 0x0750...0x077F: script = "arabic"
                case 0x4E00...0x9FFF, 0x3040...0x30FF: script = "cjk"
                case 0xAC00...0xD7AF: script = "hangul"
                default: continue
                }
                counts[script, default: 0] += 1
                total += 1
            }
            guard total >= 3, let top = counts.max(by: { $0.value < $1.value }) else { return nil }
            return (top.key, Double(top.value) / Double(total), total)
        }
        guard let beforeScript = dominantScript(String(before.suffix(300))),
              let sugScript = dominantScript(s),
              beforeScript.share >= 0.7, sugScript.share >= 0.7,
              // A short foreign token can be a legitimate proper noun ("купих си
              // iPhone"); only a substantial run in the wrong script is a
              // language drift worth rejecting.
              sugScript.letters >= 8 else { return false }
        return beforeScript.script != sugScript.script
    }

    /// Returns `s` with its longest trailing run removed that equals a prefix of
    /// `afterHead` (the text already sitting after the caret) — the gap-fill
    /// failure where the model re-types the upcoming text instead of stopping at
    /// it. Scans longest-first so the maximal echo is stripped; returns `s`
    /// unchanged when there is no overlap.
    static func dropTrailingOverlap(_ s: String, afterHead: String) -> String {
        let sChars = Array(s)
        let headChars = Array(afterHead)
        var overlap = min(headChars.count, sChars.count)
        while overlap > 0 {
            if Array(sChars.suffix(overlap)) == Array(headChars.prefix(overlap)) {
                // Only cut at a word boundary: the whole suggestion, or the cut
                // point touches whitespace. A bare shared letter ("dog" vs after
                // "great") must NOT shave characters off the final word.
                let boundaryOK = overlap == sChars.count
                    || sChars[sChars.count - overlap - 1].isWhitespace
                    || sChars[sChars.count - overlap].isWhitespace
                if boundaryOK { return String(sChars.dropLast(overlap)) }
            }
            overlap -= 1
        }
        return s
    }

    // MARK: generate

    /// Generic single-shot generation. Returns trimmed output, or nil on error.
    static func generate(
        prompt: String,
        system: String?,
        maxTokens: Int = 256,
        temperature: Float = 0.2,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        Task {
            do {
                // Lazy-load: the model is resident only while inline autocomplete is
                // on, so a host.llm call may arrive cold. `load` is idempotent.
                try await MLXEngine.shared.load { _, _ in }
                let raw = try await MLXEngine.shared.generate(
                    prompt: prompt,
                    system: system,
                    maxTokens: maxTokens,
                    temperature: temperature
                )
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    ModelIdleUnloader.shared.noteUsage()
                    completion(trimmed.isEmpty ? nil : trimmed)
                }
            } catch {
                await MainActor.run {
                    ModelIdleUnloader.shared.noteUsage()
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Prompt construction

    /// Inline-completion system prompt, optionally augmented with the user's
    /// custom instructions (tone/language/style) from Preferences.
    static func completionSystemPrompt(
        custom: String, length: CompletionLength = .medium, language: String? = nil
    ) -> String {
        // Language pinning. The generic "match the user's language" rule is not
        // enough for a small model — with English few-shot examples it drifts to
        // English on non-English text. Naming the detected language as a hard
        // rule (and disclaiming the examples) holds it.
        let languageRule = language.map {
            "The text is written in \($0). Your continuation MUST be in \($0) — "
                + "never switch to another language. The examples below are "
                + "English only to demonstrate the FORMAT, not the language. "
                + "Match the user's tone, casing, and punctuation."
        } ?? "Match the user's language, tone, casing, and punctuation. Never "
            + "switch to a different language than the text is written in."
        // Length steering. maxWords/maxTokens only HARD-CAP the output; without a
        // matching instruction gemma defaults to the shortest possible continuation
        // (one word), so the "Long" setting never produced longer suggestions. This
        // line tells the model the TARGET span to aim for, scaled to the user's
        // chosen band, and replaces the old unconditional "prefer the shortest"
        // guidance that actively fought the longer settings.
        let lengthDirective: String = {
            switch length {
            case .short:
                return "Aim for the next one to three words — the immediate next word or two. Stop at a natural boundary."
            case .medium:
                return "Aim for the next three to five words — a brief phrase. Stop at a natural boundary."
            case .long:
                return "Aim for a fuller continuation of about five to seven words — a complete phrase or clause, not just one word. Stop at a natural boundary."
            }
        }()
        // Few-shot examples must DEMONSTRATE the chosen band: with uniformly short
        // examples the model imitates their length and the "Long" setting collapses
        // back to one word regardless of the directive above. Scale the example
        // outputs to the band so the examples and the directive agree.
        let examples: String = {
            switch length {
            case .short:
                return """
                Examples (→ is the cursor; output is exactly what follows it):
                "The quick brown fox jumps over the lazy →"            → "dog."
                "Thanks for your email. I'll get back to →"            → "you shortly."
                Mid-word, suggestion "download": "Visit the website and downlo→" → "ad"
                """
            case .medium:
                return """
                Examples (→ is the cursor; output is exactly what follows it):
                "The quick brown fox jumps over the lazy →"            → "dog lying by the fence."
                "Thanks for your email. I'll get back to →"            → "you shortly with the details."
                "Let me know if you →"                                 → "have any questions about this."
                Mid-word, suggestion "download": "Visit the website and downlo→" → "ad the latest version"
                """
            case .long:
                return """
                Examples (→ is the cursor; output is exactly what follows it):
                "The quick brown fox jumps over the lazy →"            → "dog that was lying by the fence."
                "Thanks for your email. I'll get back to →"            → "you shortly with all the details you need."
                "Let me know if you →"                                 → "have any questions about this proposal."
                Mid-word, suggestion "download": "Visit the website and downlo→" → "ad the latest version from the page"
                """
            }
        }()
        let base = """
        You are the inline autocomplete engine inside Prosper, a macOS typing \
        assistant. A real person is typing on their Mac right now, in whatever app \
        they have focused — sending a chat message, writing an email, jotting a \
        note, or editing code. As they type, you predict the small next piece of \
        text they are about to write and show it inline as grey "ghost text" they \
        can accept with the Tab key. So your output is not an answer or a reply — \
        it is the words this same person would type next, in their own voice.

        What you get to work with: the text immediately before the cursor (→) and \
        sometimes the text after it, which app they are in and what kind of writing \
        that implies, optionally nearby on-screen text or their clipboard, and a \
        list of dictionary-derived suggested words. Use all of it to make the \
        continuation fit the person, the app, and the moment. Predict the most \
        likely continuation from exactly where the cursor stops.

        How to use the hints:
        - A "Suggested words" list may be provided. It is computed from a dictionary \
        (word frequencies and which words commonly follow the previous word) and is \
        ordered best-first. Treat it as strong guidance, not a constraint: pick the \
        entry that best fits the sentence, or ignore the list if none fit.
        - If the text ends mid-word, the suggestions are full words that the partial \
        word should become. Output ONLY the missing letters (and a natural \
        continuation after), never the letters already typed.

        Hard rules:
        - Output ONLY the raw continuation text that comes after the cursor. No \
        quotes, no code fences, no commentary, no labels, no leading "...".
        - NEVER repeat any word the user already typed. Continue from the exact \
        cursor position. If the text ends mid-word, your output must begin with the \
        very next character of that same word (e.g. after "downlo" output "ad"), \
        never restart the word ("download") and never glue a new word onto the \
        fragment ("downloadwebsite").
        - \(languageRule)
        - \(lengthDirective) Keep it on one line.
        - ALWAYS output a continuation. Never output nothing — even when the text \
        reads as complete, predict the next words the person would most plausibly \
        type. Whether the text is finished is the user's decision, not yours.
        - Spacing: when your continuation begins a NEW word and the text does not \
        already end with a space, START your output with a single space. When you \
        are finishing the word the text ends in, start immediately with its \
        remaining letters, no space.

        \(examples)
        """
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base + "\n\nAdditional user instructions:\n" + trimmed
    }

    /// Build the stage-1 user prompt: just translate, no JSON envelope.
    private static func buildPrimaryTranslationPrompt(
        input: String,
        target: String,
        source: String?
    ) -> String {
        let resolvedTarget = target.trimmingCharacters(in: .whitespaces).isEmpty
            ? "English"
            : target.trimmingCharacters(in: .whitespaces)
        let resolvedSource: String
        if let source {
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            resolvedSource = (!trimmed.isEmpty && trimmed.lowercased() != "auto")
                ? trimmed
                : "auto-detect"
        } else {
            resolvedSource = "auto-detect"
        }
        let nativeLine = nativeTargetDirective(forTarget: resolvedTarget).map { "\($0)\n" } ?? ""
        return """
        \(nativeLine)Translate the following text into \(resolvedTarget). Source language: \(resolvedSource).
        Output only the translation in correct, standard \(resolvedTarget).

        Text:
        \(input)
        """
    }

    /// Build the translation user prompt — ported from `core/src/translate.rs`.
    private static func buildTranslationPrompt(
        input: String,
        target: String,
        source: String?
    ) -> String {
        let resolvedTarget = target.trimmingCharacters(in: .whitespaces).isEmpty
            ? "English"
            : target.trimmingCharacters(in: .whitespaces)
        let resolvedSource: String
        if let source {
            let trimmed = source.trimmingCharacters(in: .whitespaces)
            resolvedSource = (!trimmed.isEmpty && trimmed.lowercased() != "auto")
                ? trimmed
                : "auto-detect"
        } else {
            resolvedSource = "auto-detect"
        }
        let nativeLine = nativeTargetDirective(forTarget: resolvedTarget).map { "\($0)\n" } ?? ""
        return """
        \(nativeLine)Translate the following text into \(resolvedTarget). Source language: \(resolvedSource).
        Write the "primary" translation, and every "label" and "explanation", in \(resolvedTarget).
        Use only correct, standard \(resolvedTarget) spelling, alphabet, and vocabulary. \
        Do NOT mix in words, letters, or spellings borrowed from any other language — \
        especially closely related ones that share an alphabet (e.g. for Bulgarian do not \
        use Russian spellings: write "съществително", never "существително").

        Text:
        \(input)
        """
    }

    /// One sentence describing where the user is typing, or nil when there's
    /// nothing useful to say. Names the web site when present (it's the most
    /// specific context), otherwise the app and what kind of writing it implies.
    static func situationLine(appName: String?, siteHost: String?, surface: AppProfile.Surface?) -> String? {
        if let siteHost, !siteHost.isEmpty {
            let inApp = appName.map { " in \($0)" } ?? ""
            return "The user is typing on the website \(siteHost)\(inApp) on macOS."
        }
        let s = surface ?? .generic
        if let appName {
            let qualifier = s != .generic ? " (\(s.label))" : ""
            return "The user is typing into \(appName)\(qualifier) on macOS."
        }
        if s != .generic {
            return "The user is typing into \(s.label) on macOS."
        }
        return nil
    }

    // MARK: - Context budget guard

    /// Mirror of `MLXEngine.maxPromptTokens` (the hard prompt-token cap). Kept as a
    /// local `static let` so the budget allocator does not import `MLXEngine` and
    /// risk a build cycle. If the engine cap changes, update this to match.
    static let maxPromptTokensMirror = 480

    /// Cheap chars≈tokens heuristic: ~4 characters per token, no tokenizer.
    private static let charsPerToken = 4

    /// One optional context piece competing for the leftover prompt budget. `order`
    /// is the cut priority — **higher cuts first** (clipboard/OCR before frequent
    /// words before persona), so the most predictive context survives longest.
    struct ContextPiece {
        let name: String
        let length: Int
        let order: Int
    }

    /// Per-piece character allowances after reserving the recent-text tail.
    ///
    /// The text immediately before the cursor (the "tail") is the single most
    /// predictive signal, so it is reserved FIRST — up to `tailFloorChars` is held
    /// for it unconditionally and never truncated here. Whatever budget remains is
    /// then handed out to the optional pieces in best-keep order (lowest `order`
    /// first), so when space runs short the high-`order` pieces (clipboard/OCR) are
    /// starved before the low-`order` ones (persona/frequent words).
    ///
    /// Pure and deterministic: no I/O, no Preferences reads. `maxPromptTokens`
    /// defaults to the engine cap mirror; callers may inject a smaller cap in tests.
    /// Returns a `[name: allowedChars]` map; a piece absent from the map (or mapped
    /// to 0) gets nothing. Pieces already within budget keep their full length.
    static func contextCharBudgets(
        recentTextChars: Int,
        pieces: [ContextPiece],
        maxPromptTokens: Int = maxPromptTokensMirror,
        tailFloorChars: Int = 320
    ) -> [String: Int] {
        let totalChars = max(0, maxPromptTokens * charsPerToken)
        // Reserve the tail first: at least the floor, but never more than the whole
        // budget. The tail is allowed to consume everything if it is long enough.
        let tailReserved = min(totalChars, max(tailFloorChars, min(recentTextChars, totalChars)))
        var remaining = max(0, totalChars - tailReserved)

        var result: [String: Int] = [:]
        // Best-keep first (lowest cut order): these get fed before the easy-to-cut
        // pieces, so a tie on budget exhaustion starves clipboard/OCR last-fed.
        for piece in pieces.sorted(by: { $0.order < $1.order }) {
            guard piece.length > 0 else { continue }
            let granted = min(piece.length, remaining)
            result[piece.name] = granted
            remaining -= granted
        }
        return result
    }

    /// Truncates `text` to at most `budget[name]` characters (0 / missing ⇒ empty),
    /// preserving the prefix. Returns `nil` when nothing of the piece survives so
    /// callers can skip emitting an empty context block.
    private static func clip(_ text: String, to name: String, in budget: [String: Int]) -> String? {
        let allowed = budget[name] ?? 0
        guard allowed > 0 else { return nil }
        if text.count <= allowed { return text }
        return String(text.prefix(allowed))
    }

    /// Build a continuation prompt from the text surrounding the caret, with
    /// optional clipboard context prepended.
    static func buildCompletionPrompt(
        before: String, after: String,
        clipboard: String?, frequentWords: [String] = [],
        hasImage: Bool = false, onScreenText: String? = nil,
        onScreenIsConversation: Bool = false,
        candidates: CompletionCandidates? = nil,
        appName: String? = nil, appSurface: AppProfile.Surface? = nil,
        siteHost: String? = nil
    ) -> String {
        var ctx = ""
        // Situational context: where the user is typing (app, and the web site if
        // it's a browser/Electron surface) and what kind of writing that implies.
        // Steers tone/length so a chat message stays casual and an email composed.
        if let line = situationLine(appName: appName, siteHost: siteHost, surface: appSurface) {
            let hint = (appSurface ?? .generic).promptHint
            ctx += hint.isEmpty ? "\(line)\n\n" : "\(line) \(hint)\n\n"
        }
        if hasImage {
            ctx += "A screenshot of the area around the cursor is attached for "
                + "visual context (surrounding UI/text). Use it only to disambiguate "
                + "intent; never describe the image.\n\n"
        }
        // Context-budget guard. The recent-text tail (`before` for end-of-line
        // completions, or `before` + `after` for a gap fill) is the single most
        // predictive signal, so it is reserved FIRST; the optional context pieces
        // below may only consume the leftover prompt budget. When the user's
        // clipboard/OCR capture is enormous it gets truncated here instead of
        // pushing the tail past `MLXEngine.maxPromptTokens`. Cut priority (highest
        // `order` cut first): on-screen text and clipboard go before the frequent
        // words. Pieces that fit entirely are untouched, so the common small-context
        // path is byte-identical to passing them through directly.
        let frequentWordsJoined = frequentWords.isEmpty
            ? ""
            : frequentWords.joined(separator: ", ")
        let tailChars = before.count + after.count
        let budget = contextCharBudgets(
            recentTextChars: tailChars,
            pieces: [
                ContextPiece(name: "onScreen", length: onScreenText?.count ?? 0, order: 2),
                ContextPiece(name: "clipboard", length: clipboard?.count ?? 0, order: 2),
                ContextPiece(name: "frequent", length: frequentWordsJoined.count, order: 1),
            ]
        )
        if let onScreenText, let clipped = clip(onScreenText, to: "onScreen", in: budget) {
            if onScreenIsConversation {
                ctx += "The conversation visible on screen so far (oldest first, the "
                    + "most recent message last). The text after \"Before cursor\" is "
                    + "the reply the user is currently typing — continue only that "
                    + "reply in their voice; do not quote, repeat, or answer earlier "
                    + "lines:\n\(clipped)\n\n"
            } else {
                ctx += "On-screen text near the cursor (for context only; do not repeat "
                    + "it verbatim):\n\(clipped)\n\n"
            }
        }
        if let clipboard, let clipped = clip(clipboard, to: "clipboard", in: budget) {
            ctx += "Clipboard context (may be relevant):\n\(clipped)\n\n"
        }
        if !frequentWordsJoined.isEmpty,
           let clipped = clip(frequentWordsJoined, to: "frequent", in: budget) {
            ctx += "The user frequently writes these words; prefer them when natural: "
                + clipped + ".\n\n"
        }
        // Non-LLM candidate hints (dictionary prefix/bigram/typo). Strong guidance.
        if let candidates, !candidates.isEmpty {
            let list = candidates.words.joined(separator: ", ")
            if candidates.atBoundary {
                ctx += "Suggested words (likely to come next, best first): \(list).\n\n"
            } else {
                ctx += "The text ends mid-word with the partial word "
                    + "\"\(candidates.fragment)\". Suggested completions of that word "
                    + "(full words, best first): \(list). Output only the letters that "
                    + "finish the word, not the whole word.\n\n"
            }
        }
        if after.isEmpty {
            return "\(ctx)Continue this text. Output only the continuation:\n\(before)"
        }
        return """
        \(ctx)Fill the gap at the cursor (between the two parts). Output only the \
        text that belongs at the cursor — it must read naturally before "After cursor".

        Before cursor:
        \(before)

        After cursor:
        \(after)
        """
    }

    /// Reads a capped snippet of the current clipboard text for completion context.
    private static func clipboardContextSnippet(limit: Int = 500) -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit))
    }

    /// Prefix completions for `fragment` from the OS lexicon (NSSpellChecker), as
    /// full words. Zero-bundle, locale-aware, and complements the bundled
    /// dictionary (e.g. proper nouns / words the dictionary lacks). Runs on the
    /// main actor as AppKit requires; returns [] for short fragments or on miss.
    static func osLexiconCompletions(for fragment: String, limit: Int = 6) async -> [String] {
        guard fragment.count >= 2 else { return [] }
        return await MainActor.run {
            let checker = NSSpellChecker.shared
            let range = NSRange(location: 0, length: (fragment as NSString).length)
            let words = checker.completions(
                forPartialWordRange: range,
                in: fragment,
                language: nil,
                inSpellDocumentWithTag: 0
            ) ?? []
            return limit < words.count ? Array(words.prefix(limit)) : words
        }
    }

    // MARK: - Translation parsing (ported from core/src/translate.rs)

    /// Robustly parse model output into a `TranslationResult`.
    /// Handles clean JSON, ```-fenced JSON, JSON preceded by prose, and pure
    /// non-JSON (falls back to using the raw text as the primary translation).
    static func parseTranslation(_ raw: String) -> TranslationResult {
        if let slice = extractJSONObject(raw) {
            // First try the slice as-is. If it fails, the usual culprit is a
            // string value that quotes a word with unescaped `"` (e.g. an
            // explanation: `means "foo" or bar`), which prematurely closes the
            // string and makes the whole object unparseable — historically this
            // dumped the raw JSON blob at the user. Repair the stray quotes and
            // retry before giving up.
            for candidate in [slice, repairUnescapedQuotes(slice)] {
                if let data = candidate.data(using: .utf8),
                   let result = try? JSONDecoder().decode(TranslationResult.self, from: data) {
                    return result
                }
            }
        }
        // Fallback: treat the raw model output as the translation itself.
        return TranslationResult(
            detectedLanguage: nil,
            primary: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            candidates: []
        )
    }

    /// Escape double quotes that appear *inside* a JSON string value/key — the
    /// single most common malformation in small-model JSON output. We walk the
    /// text tracking string state; a `"` only closes the current string when the
    /// next significant character terminates a value or key (`:` `,` `}` `]`, or
    /// end of input). Any other in-string `"` is treated as literal content and
    /// escaped. Already-escaped sequences (`\"`, `\\`) pass through untouched.
    private static func repairUnescapedQuotes(_ s: String) -> String {
        let chars = Array(s)
        var out = String()
        out.reserveCapacity(chars.count + 16)
        var inString = false
        var i = 0
        func nextSignificant(after idx: Int) -> Character? {
            var j = idx + 1
            while j < chars.count, chars[j] == " " || chars[j] == "\n"
                || chars[j] == "\r" || chars[j] == "\t" { j += 1 }
            return j < chars.count ? chars[j] : nil
        }
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" {
                // Preserve an escape sequence (backslash + the char it escapes).
                out.append(ch)
                if i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                i += 1; continue
            }
            if ch == "\"" {
                if !inString {
                    inString = true
                    out.append(ch)
                } else {
                    switch nextSignificant(after: i) {
                    case nil, ":", ",", "}", "]":
                        inString = false
                        out.append(ch)            // structural close
                    default:
                        out.append("\\\"")        // stray inner quote → escape
                    }
                }
                i += 1; continue
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// Strip code fences and slice the outermost `{...}` from arbitrary text.
    private static func extractJSONObject(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let start = trimmed.firstIndex(of: "{"),
            let end = trimmed.lastIndex(of: "}"),
            start <= end
        else {
            return nil
        }
        return String(trimmed[start...end])
    }
}
