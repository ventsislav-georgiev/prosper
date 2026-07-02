import XCTest
@testable import ProsperApp

/// Covers the non-LLM completion-candidate pipeline: `SymSpell` typo correction,
/// `Lexicon` prefix/bigram prediction, the `CompletionCandidates` provider that
/// merges them, and the prompt builders that feed candidates to the LLM. All use
/// small hand-built dictionaries (no `Bundle.main`), so they are deterministic.
final class CompletionCandidatesTests: XCTestCase {

    /// A compact lexicon mirroring the "website d → download" scenario.
    private func makeLexicon() -> Lexicon {
        let freq: [String: Int] = [
            "the": 100_000, "to": 90_000, "down": 8_000, "do": 50_000,
            "download": 6_000, "downloads": 1_200, "design": 5_000,
            "development": 4_000, "developer": 2_000, "domain": 3_000,
            "documentation": 2_500, "website": 7_000, "web": 4_500,
            "there": 9_000, "three": 1_000, "download's": 10,
        ]
        let bigrams: [String: [String]] = [
            // "website" most often precedes these (order = descending count).
            "website": ["design", "development", "download", "uses", "owner"],
            "the": ["website", "design", "download"],
        ]
        return Lexicon(frequency: freq, bigrams: bigrams)
    }

    // MARK: - SymSpell

    func testSymSpellCorrectsTransposition() {
        let s = makeLexicon().symSpell
        // "downlaod" — transposed a/o — distance 1 from "download".
        XCTAssertTrue(s.lookup("downlaod").contains("download"))
    }

    func testSymSpellCorrectsInsertionTypo() {
        let s = makeLexicon().symSpell
        // "downlload" — an extra l — distance 1 from "download".
        XCTAssertTrue(s.lookup("downlload").contains("download"))
    }

    func testSymSpellCorrectsDeletionTypo() {
        let s = makeLexicon().symSpell
        // "donload" — missing w — distance 1 from "download".
        XCTAssertTrue(s.lookup("donload").contains("download"))
    }

    func testSymSpellReturnsKnownWordAsItself() {
        let s = makeLexicon().symSpell
        XCTAssertTrue(s.isKnownWord("download"))
        XCTAssertTrue(s.lookup("download").contains("download"))
    }

    func testSymSpellRanksByFrequency() {
        // "thes" is distance 1 from both "the" (freq 100k) and "there"/"three";
        // the most frequent correction comes first.
        let s = makeLexicon().symSpell
        let hits = s.lookup("thee", limit: 3)
        XCTAssertEqual(hits.first, "the")
    }

    func testSymSpellEmptyOnGibberish() {
        let s = makeLexicon().symSpell
        XCTAssertTrue(s.lookup("xqzkw").isEmpty)
    }

    func testEditDistanceBasics() {
        XCTAssertEqual(SymSpell.editDistance("download", "downlaod"), 1) // adjacent transposition = 1 (Damerau/OSA)
        XCTAssertEqual(SymSpell.editDistance("cat", "cat"), 0)
        XCTAssertEqual(SymSpell.editDistance("cat", "cot"), 1)
        XCTAssertEqual(SymSpell.editDistance("", "abc"), 3)
        XCTAssertEqual(SymSpell.editDistance("kitten", "sitting"), 3)
    }

    // MARK: - Lexicon prefix + bigram

    func testPrefixCompletionsRankedByFrequency() {
        let lex = makeLexicon()
        let hits = lex.prefixCompletions("do", limit: 5)
        XCTAssertFalse(hits.contains("do")) // the prefix itself is excluded
        // "do" is not returned but "domain","download","downloads","documentation"
        // are; ordering is by frequency.
        XCTAssertTrue(hits.contains("download"))
        XCTAssertTrue(hits.contains("domain"))
        // domain (3000) ranks above documentation (2500).
        if let di = hits.firstIndex(of: "domain"), let doci = hits.firstIndex(of: "documentation") {
            XCTAssertLessThan(di, doci)
        }
    }

    func testPrefixCompletionsNarrowFragment() {
        let lex = makeLexicon()
        let hits = lex.prefixCompletions("downl", limit: 5)
        XCTAssertEqual(Set(hits), ["download", "downloads", "download's"])
    }

    func testPrefixCompletionsEmptyForUnknownPrefix() {
        XCTAssertTrue(makeLexicon().prefixCompletions("zzz").isEmpty)
        XCTAssertTrue(makeLexicon().prefixCompletions("").isEmpty)
    }

    func testNextWordsFromBigram() {
        let lex = makeLexicon()
        XCTAssertEqual(lex.nextWords(after: "website", limit: 3), ["design", "development", "download"])
        XCTAssertTrue(lex.nextWords(after: "unknownword").isEmpty)
    }

    func testEmptyLexiconReturnsNothing() {
        XCTAssertTrue(Lexicon.empty.prefixCompletions("d").isEmpty)
        XCTAssertTrue(Lexicon.empty.nextWords(after: "the").isEmpty)
        XCTAssertFalse(Lexicon.empty.isKnownWord("the"))
    }

    // MARK: - fragment / headWord extraction

    func testTrailingWord() {
        XCTAssertEqual(CompletionCandidates.trailingWord("website d"), "d")
        XCTAssertEqual(CompletionCandidates.trailingWord("website "), "")
        XCTAssertEqual(CompletionCandidates.trailingWord("Hello World"), "world")
        XCTAssertEqual(CompletionCandidates.trailingWord(""), "")
        XCTAssertEqual(CompletionCandidates.trailingWord("end."), "")
    }

    func testHeadWord() {
        XCTAssertEqual(CompletionCandidates.headWord("website d", droppingFragment: "d"), "website")
        XCTAssertEqual(CompletionCandidates.headWord("website ", droppingFragment: ""), "website")
        XCTAssertEqual(CompletionCandidates.headWord("d", droppingFragment: "d"), nil)
        XCTAssertEqual(CompletionCandidates.headWord("the API docu", droppingFragment: "docu"), "api")
    }

    // MARK: - CompletionCandidates.derive

    func testDeriveMidWordPrefersContextBigram() {
        // "website d" → fragment "d", head "website". The bigram next-words that
        // start with "d" (download, design — actually "design" then "development"
        // then "download") must come before generic dictionary prefix hits.
        let c = CompletionCandidates.derive(before: "website d", lexicon: makeLexicon())
        XCTAssertEqual(c.fragment, "d")
        XCTAssertEqual(c.headWord, "website")
        XCTAssertFalse(c.atBoundary)
        XCTAssertTrue(c.words.contains("download"))
        XCTAssertTrue(c.words.contains("design"))
        // Context-aware bigram∩prefix words lead the list.
        XCTAssertEqual(c.words.first, "design") // website→design (highest bigram count) starts with d
    }

    func testDeriveBoundaryPredictsNextWord() {
        let c = CompletionCandidates.derive(before: "the website ", lexicon: makeLexicon())
        XCTAssertEqual(c.fragment, "")
        XCTAssertEqual(c.headWord, "website")
        XCTAssertTrue(c.atBoundary)
        XCTAssertEqual(c.words.first, "design")
        XCTAssertFalse(c.words.contains("website")) // never echo the head word
    }

    func testDeriveExcludesFragmentAndHead() {
        let c = CompletionCandidates.derive(before: "web", lexicon: makeLexicon())
        XCTAssertTrue(c.words.contains("website"))
        XCTAssertFalse(c.words.contains("web")) // the fragment itself is excluded
    }

    func testDeriveSuppressedWhenCursorMidExistingWord() {
        // Cursor sits inside an existing word (after starts with a letter): nothing
        // to complete, must not glue.
        let c = CompletionCandidates.derive(before: "web", after: "site", lexicon: makeLexicon())
        XCTAssertTrue(c.isEmpty)
    }

    func testDeriveIncludesTypoCorrection() {
        // "downlaod" is a transposition typo; no prefix completion exists, so the
        // SymSpell correction "download" must surface.
        let c = CompletionCandidates.derive(before: "the downlaod", lexicon: makeLexicon())
        XCTAssertTrue(c.words.contains("download"))
    }

    func testDeriveEmptyLexiconNoCandidates() {
        let c = CompletionCandidates.derive(before: "website d", lexicon: .empty)
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(c.fragment, "d") // structure still populated
    }

    func testDeriveRespectsLimit() {
        let c = CompletionCandidates.derive(before: "the d", lexicon: makeLexicon(), limit: 2)
        XCTAssertLessThanOrEqual(c.words.count, 2)
    }

    // MARK: - Prompt builders

    func testSystemPromptHasRobustRules() {
        let p = CoreBridge.completionSystemPrompt(custom: "")
        XCTAssertTrue(p.contains("never restate what the user already typed"))
        XCTAssertTrue(p.contains("mid-word"))
        XCTAssertTrue(p.contains("phone keyboard"))
    }

    func testSystemPromptAppendsCustomInstructions() {
        let p = CoreBridge.completionSystemPrompt(custom: "Write in British English.")
        XCTAssertTrue(p.contains("About the user"))
        XCTAssertTrue(p.contains("British English"))
    }

    func testSystemPromptTransliteratedBulgarianSteersShlyokavitsa() {
        let p = CoreBridge.completionSystemPrompt(custom: "", transliteratedBulgarian: true)
        XCTAssertTrue(p.contains("shlyokavitsa"))
        XCTAssertTrue(p.contains("NOT Croatian"))
    }

    func testLatinBulgarianDetection() {
        // Confident Slavic-Latin detection over Latin-script text → treat as
        // transliterated Bulgarian. English / Cyrillic must NOT trigger it.
        XCTAssertTrue(CoreBridge.isSlavicLatinLanguage("Croatian"))
        XCTAssertFalse(CoreBridge.isSlavicLatinLanguage("English"))
        XCTAssertFalse(CoreBridge.isSlavicLatinLanguage(nil))
        XCTAssertTrue(CoreBridge.isLatinScript("kak si bratle"))
        XCTAssertFalse(CoreBridge.isLatinScript("как си брат"))
    }

    func testBuildPromptMidWordInjectsNoHint() {
        let c = CompletionCandidates.derive(before: "website d", lexicon: makeLexicon())
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "website d", after: "", clipboard: nil, candidates: c
        )
        // No mid-word hint: it changed per keystroke BEFORE the text (KV-cache
        // thrash = typing lag) and the small model mangled it into garbage
        // completions. The prompt simply ends mid-word; the model finishes the
        // word naturally, and the prompt must end exactly at the cursor.
        XCTAssertFalse(prompt.contains("starts with"))
        XCTAssertFalse(prompt.contains("most likely"))
        XCTAssertTrue(prompt.hasSuffix("website d"))
    }

    func testBuildPromptBoundaryOmitsCandidateList() {
        let c = CompletionCandidates.derive(before: "the website ", lexicon: makeLexicon())
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "the website ", after: "", clipboard: nil, candidates: c
        )
        // At a word boundary we no longer inject any candidate word-list: the
        // 2B/4-bit model regurgitated such lists verbatim. Only mid-word gets a hint.
        XCTAssertFalse(prompt.contains("Suggested words"))
        XCTAssertFalse(prompt.contains("most likely"))
    }

    func testBuildPromptOmitsCandidateBlockWhenEmpty() {
        let c = CompletionCandidates.derive(before: "website d", lexicon: .empty)
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "website d", after: "", clipboard: nil, candidates: c
        )
        XCTAssertFalse(prompt.contains("Suggested words"))
        XCTAssertFalse(prompt.contains("partial word"))
    }

    func testBuildPromptInjectsGroundingContext() {
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "Hey ", after: "", clipboard: nil,
            fieldLabel: "Message to Plamen Redjov", windowTitle: "Plamen Redjov (DM) - Slack"
        )
        XCTAssertTrue(prompt.contains("Field: Message to Plamen Redjov"))
        XCTAssertTrue(prompt.contains("Window: Plamen Redjov (DM) - Slack"))
    }

    func testBuildPromptOmitsGroundingWhenAbsent() {
        let prompt = CoreBridge.buildCompletionPrompt(before: "Hey ", after: "", clipboard: nil)
        XCTAssertFalse(prompt.contains("Field:"))
        XCTAssertFalse(prompt.contains("Window:"))
    }

    func testBuildPromptInjectsWritingSamples() {
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "Zdr, ", after: "", clipboard: nil,
            writingSamples: ["kak si bratle, vsichko nared li e", "shte se vidim utre v ofisa"]
        )
        XCTAssertTrue(prompt.contains("Examples of how the user usually writes"))
        XCTAssertTrue(prompt.contains("- kak si bratle, vsichko nared li e"))
        XCTAssertTrue(prompt.contains("- shte se vidim utre v ofisa"))
    }

    func testBuildPromptOmitsWritingSamplesWhenAbsent() {
        let prompt = CoreBridge.buildCompletionPrompt(before: "Zdr, ", after: "", clipboard: nil)
        XCTAssertFalse(prompt.contains("Examples of how the user usually writes"))
    }

    func testTransliterateCyrillicToLatinShlyokavitsa() {
        XCTAssertEqual(CoreBridge.transliterateCyrillicToLatin("благодаря"), "blagodarq")
        XCTAssertEqual(CoreBridge.transliterateCyrillicToLatin("моля"), "molq")
        XCTAssertEqual(CoreBridge.transliterateCyrillicToLatin("ще"), "shte")
        // Mixed script (model half-transliterated) still normalizes to all-Latin.
        XCTAssertEqual(CoreBridge.transliterateCyrillicToLatin("на обqd"), "na obqd")
        // Latin passes through untouched.
        XCTAssertEqual(CoreBridge.transliterateCyrillicToLatin("kak si"), "kak si")
        // Casing: uppercase source capitalizes the multigraph.
        XCTAssertEqual(CoreBridge.transliterateCyrillicToLatin("Що"), "Shto")
    }

    func testSanitizeTransliteratesWhenLatinBulgarian() {
        let out = CoreBridge.sanitizeCompletion("помогна", before: "Molq ", after: "",
                                                transliterateCyrillic: true)
        XCTAssertEqual(out, "pomogna")
    }

    func testEchoesWritingSampleGuard() {
        let samples = ["shte se vidim utre v ofisa"]
        XCTAssertTrue(CoreBridge.echoesWritingSample("shte se vidim utre", samples: samples))
        XCTAssertFalse(CoreBridge.echoesWritingSample("da", samples: samples))  // too short
        XCTAssertFalse(CoreBridge.echoesWritingSample("kak si bratle", samples: samples))
    }

    func testEchoesWritingSampleRejectsInstructionHeaderLeak() {
        let samples = ["shte se vidim utre v ofisa"]
        // High-temp small-model leak: continuing the injected instruction header
        // instead of the user text. Must be rejected as an echo.
        XCTAssertTrue(CoreBridge.echoesWritingSample("Examples of how the user", samples: samples))
        XCTAssertTrue(CoreBridge.echoesWritingSample("match their voice", samples: samples))
        XCTAssertTrue(CoreBridge.echoesWritingSample("The user frequently writes", samples: samples))
        // Guard is inert when no samples were injected (header never rendered).
        XCTAssertFalse(CoreBridge.echoesWritingSample("Examples of how the user", samples: []))
        // A genuine completion that merely shares a common word is NOT rejected.
        XCTAssertFalse(CoreBridge.echoesWritingSample("voice message", samples: samples))
    }

    func testCutImmediateRepeatIgnoresTrailingPunctuation() {
        // "je je." — the trailing period must not hide the stutter.
        XCTAssertEqual(CoreBridge.cutImmediateRepeat("da obsa je je."), "da obsa je")
        XCTAssertEqual(CoreBridge.cutImmediateRepeat("the the"), "the")
        XCTAssertEqual(CoreBridge.cutImmediateRepeat("all good here"), "all good here")
    }

    func testContainsForeignScriptRejectsGarbageBurst() {
        // Cyrillic prompt, suggestion carries a Devanagari burst → reject.
        XCTAssertTrue(CoreBridge.containsForeignScript("заर्डर", before: "Молq, потвардете вашата"))
        // Pure Cyrillic continuation of Cyrillic text → allowed.
        XCTAssertFalse(CoreBridge.containsForeignScript("поръчка", before: "Молq, потвардете вашата"))
        // Latin loanword inside Cyrillic text → allowed (Latin always permitted).
        XCTAssertFalse(CoreBridge.containsForeignScript("iPhone Pro", before: "Купих си нов"))
        // Latinica: Latin suggestion on Latin prefix → allowed.
        XCTAssertFalse(CoreBridge.containsForeignScript("shte doida utre", before: "Zdravei, kak si"))
    }

    func testBuildPromptFimShapeWithAfterText() {
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "Dear ", after: ", thanks", clipboard: nil, candidates: nil
        )
        XCTAssertTrue(prompt.contains("Before cursor:"))
        XCTAssertTrue(prompt.contains("After cursor:"))
    }

    // MARK: - App writing-surface classification

    func testSurfaceClassifiesKnownApps() {
        XCTAssertEqual(AppProfile.surface(for: "org.telegram.desktop", kind: .electron), .chat)
        XCTAssertEqual(AppProfile.surface(for: "com.apple.mail", kind: .standard), .email)
        XCTAssertEqual(AppProfile.surface(for: "com.apple.dt.Xcode", kind: .standard), .code)
        XCTAssertEqual(AppProfile.surface(for: "com.apple.Notes", kind: .standard), .notes)
    }

    func testSurfaceFallsBackToKind() {
        XCTAssertEqual(AppProfile.surface(for: "com.apple.Terminal", kind: .terminal), .terminal)
        XCTAssertEqual(AppProfile.surface(for: "com.unknown.app", kind: .browser), .browser)
        XCTAssertEqual(AppProfile.surface(for: "com.unknown.app", kind: .standard), .generic)
    }

    func testDisplayNameNilForNilOrUnknownBundle() {
        // Dynamic resolution (no hardcoded id→name table): nil id → nil, and a
        // bundle id no app claims → nil. Installed apps resolve at runtime.
        XCTAssertNil(AppProfile.displayName(for: nil))
        XCTAssertNil(AppProfile.displayName(for: "com.nonexistent.prosper.test.app"))
    }

    func testSurfaceFromWebHost() {
        XCTAssertEqual(AppProfile.surface(forHost: "web.telegram.org"), .chat)
        XCTAssertEqual(AppProfile.surface(forHost: "mail.google.com"), .email)
        XCTAssertEqual(AppProfile.surface(forHost: "www.reddit.com"), .social)
        XCTAssertEqual(AppProfile.surface(forHost: "github.com"), .code)
        XCTAssertEqual(AppProfile.surface(forHost: "docs.google.com"), .docs)
        XCTAssertEqual(AppProfile.surface(forHost: "example.com"), .browser) // unknown site
        XCTAssertEqual(AppProfile.surface(forHost: nil), .browser)
    }

    func testBuildPromptInjectsAppContextForChat() {
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "see you ", after: "", clipboard: nil,
            appName: "Telegram", appSurface: .chat
        )
        XCTAssertTrue(prompt.contains("Telegram"))
        XCTAssertTrue(prompt.contains("chat")) // surface label
        XCTAssertTrue(prompt.contains("casual")) // chat tone hint
    }

    func testBuildPromptInjectsEmailToneHint() {
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "Dear Sir, ", after: "", clipboard: nil,
            appName: "Mail", appSurface: .email
        )
        XCTAssertTrue(prompt.contains("Mail"))
        XCTAssertTrue(prompt.contains("professional"))
    }

    func testBuildPromptNamesWebsiteWhenHostPresent() {
        // Web-domain context: the site is named, and the host-derived surface's
        // tone hint is applied.
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "lol ", after: "", clipboard: nil,
            appName: "Safari", appSurface: .chat, siteHost: "web.telegram.org"
        )
        XCTAssertTrue(prompt.contains("web.telegram.org"))
        XCTAssertTrue(prompt.contains("Safari"))
        XCTAssertTrue(prompt.contains("casual"))
    }

    func testBuildPromptOmitsAppContextForGeneric() {
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "hello ", after: "", clipboard: nil,
            appName: nil, appSurface: .generic
        )
        XCTAssertFalse(prompt.contains("typing into"))
        XCTAssertFalse(prompt.contains("typing on"))
    }

    func testSituationLinePrefersHostOverApp() {
        let line = CoreBridge.situationLine(appName: "Chrome", siteHost: "github.com", surface: .code)
        XCTAssertEqual(line, "The user is typing on the website github.com in Chrome on macOS.")
    }

    func testSurfaceIsConversational() {
        for s in [AppProfile.Surface.chat, .email, .social] {
            XCTAssertTrue(s.isConversational, "\(s) should be conversational")
        }
        for s in [AppProfile.Surface.notes, .code, .docs, .terminal, .browser, .generic] {
            XCTAssertFalse(s.isConversational, "\(s) should not be conversational")
        }
    }

    func testBuildPromptLabelsConversationContext() {
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "А ти беше ли чел ", after: "", clipboard: nil,
            onScreenText: "Помня с някой че говорихме за четвърта.",
            onScreenIsConversation: true,
            appName: "Telegram", appSurface: .chat
        )
        XCTAssertTrue(prompt.contains("conversation visible on screen"))
        XCTAssertTrue(prompt.contains("Помня с някой"))
        XCTAssertFalse(prompt.contains("On-screen text near the cursor"))
    }

    func testBuildPromptGenericOnScreenWhenNotConversation() {
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "the ", after: "", clipboard: nil,
            onScreenText: "Run build",
            onScreenIsConversation: false,
            appName: "Terminal", appSurface: .terminal
        )
        XCTAssertTrue(prompt.contains("On-screen text near the cursor"))
        XCTAssertFalse(prompt.contains("conversation visible on screen"))
    }

    func testBuildPromptCapsAfterCursorHead() {
        // Mid-document typing: the post-caret rest of a long file must not ship
        // whole — it would blow the token window and behead the system prompt.
        let longAfter = String(repeating: "later paragraph text ", count: 100) // ~2100 chars
        let prompt = CoreBridge.buildCompletionPrompt(
            before: "The fix is ", after: longAfter, clipboard: nil
        )
        XCTAssertTrue(prompt.contains("After cursor:"))
        let afterSection = prompt.components(separatedBy: "After cursor:").last ?? ""
        XCTAssertLessThanOrEqual(afterSection.count, 420, "after-cursor head not capped: \(afterSection.count) chars")
        // Short after passes through untouched.
        let short = CoreBridge.buildCompletionPrompt(
            before: "The fix is ", after: " and that is all.", clipboard: nil
        )
        XCTAssertTrue(short.contains(" and that is all."))
    }

    func testAfterHeadChargedAgainstTailAllowance() {
        // The tail reservation covers BOTH sides of the caret: a long `before`
        // plus a 400-char afterHead must yield a SHORTER before-section than the
        // same `before` with a tiny after — otherwise the combined tail rides
        // over the budget and only the system-beheading backstop catches it.
        func beforeSection(after: String) -> Int {
            let p = CoreBridge.buildCompletionPrompt(
                before: String(repeating: "word ", count: 1200), // 6000 chars
                after: after, clipboard: nil
            )
            let body = p.components(separatedBy: "Before cursor:\n").last ?? ""
            return (body.components(separatedBy: "\n\nAfter cursor:").first ?? "").count
        }
        let withBigAfter = beforeSection(after: String(repeating: "x", count: 800))
        let withTinyAfter = beforeSection(after: " ok.")
        XCTAssertLessThan(withBigAfter, withTinyAfter,
                          "before-section not charged for afterHead: \(withBigAfter) vs \(withTinyAfter)")
    }
}
