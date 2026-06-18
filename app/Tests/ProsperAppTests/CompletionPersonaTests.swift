import XCTest
@testable import ProsperApp

/// Covers the WS5 inline-completion personalization + context-budget refinements:
///
///   - `Preferences.structuredPersonaBlock`: renders only the *set* persona fields
///     (`userName` / `userLanguages` / `voiceStyle`) into one compact line, and is
///     `""` when every field is unset (the byte-identical no-persona path).
///   - `AppOverrideResolver.effectivePromptAddendum`: joins the persona block (first)
///     with the resolved free-form / per-app custom instructions, skipping empties.
///   - `CoreBridge.contextCharBudgets`: reserves the recent-text tail first, then
///     hands the remainder to the optional context pieces in best-keep order so the
///     easy-to-cut pieces (clipboard/OCR) are starved before the rest.
///
/// The persona/addendum cases drive the real `Preferences` (UserDefaults), so each
/// test snapshots and restores the keys it touches to stay order-independent and
/// leave the suite's defaults untouched. The budget allocator is pure, so those
/// cases need no setup.
final class CompletionPersonaTests: XCTestCase {

    private var savedName: String = ""
    private var savedLanguages: String = ""
    private var savedVoice: String = ""
    private var savedCustom: String = ""

    override func setUp() {
        super.setUp()
        savedName = Preferences.userName
        savedLanguages = Preferences.userLanguages
        savedVoice = Preferences.voiceStyle
        savedCustom = Preferences.customInstructions
        // Start every case from a clean, fully-unset persona.
        Preferences.userName = ""
        Preferences.userLanguages = ""
        Preferences.voiceStyle = ""
        Preferences.customInstructions = ""
    }

    override func tearDown() {
        Preferences.userName = savedName
        Preferences.userLanguages = savedLanguages
        Preferences.voiceStyle = savedVoice
        Preferences.customInstructions = savedCustom
        AppOverrideCache.shared.replace(with: [])
        super.tearDown()
    }

    // MARK: - structuredPersonaBlock

    /// All three fields unset ⇒ empty block ⇒ the system prompt is byte-identical to
    /// the no-persona path (the common case).
    func testPersonaBlockEmptyWhenAllUnset() {
        XCTAssertEqual(Preferences.structuredPersonaBlock, "")
    }

    /// Whitespace-only fields count as unset and contribute nothing.
    func testPersonaBlockTreatsWhitespaceAsUnset() {
        Preferences.userName = "   "
        Preferences.userLanguages = "\n\t"
        Preferences.voiceStyle = " "
        XCTAssertEqual(Preferences.structuredPersonaBlock, "")
    }

    /// Only the name set ⇒ only the name sentence.
    func testPersonaBlockNameOnly() {
        Preferences.userName = "Vince"
        XCTAssertEqual(Preferences.structuredPersonaBlock, "The user's name is Vince.")
    }

    /// Only the languages set ⇒ only the languages sentence.
    func testPersonaBlockLanguagesOnly() {
        Preferences.userLanguages = "English, Bulgarian"
        XCTAssertEqual(Preferences.structuredPersonaBlock, "They write in English, Bulgarian.")
    }

    /// Only the voice set ⇒ only the voice sentence.
    func testPersonaBlockVoiceOnly() {
        Preferences.voiceStyle = "concise"
        XCTAssertEqual(Preferences.structuredPersonaBlock, "Preferred voice: concise.")
    }

    /// All three set ⇒ name, then languages, then voice, space-joined into one line.
    func testPersonaBlockAllFields() {
        Preferences.userName = "Vince"
        Preferences.userLanguages = "English, Bulgarian"
        Preferences.voiceStyle = "friendly, professional, concise"
        XCTAssertEqual(
            Preferences.structuredPersonaBlock,
            "The user's name is Vince. They write in English, Bulgarian. "
                + "Preferred voice: friendly, professional, concise."
        )
    }

    /// A partial combo (name + voice, no languages) keeps field order and skips the
    /// gap rather than emitting an empty sentence.
    func testPersonaBlockSkipsTheUnsetMiddleField() {
        Preferences.userName = "Vince"
        Preferences.voiceStyle = "concise"
        XCTAssertEqual(
            Preferences.structuredPersonaBlock,
            "The user's name is Vince. Preferred voice: concise."
        )
    }

    /// Field values are trimmed before rendering.
    func testPersonaBlockTrimsValues() {
        Preferences.userName = "  Vince  "
        XCTAssertEqual(Preferences.structuredPersonaBlock, "The user's name is Vince.")
    }

    // MARK: - effectivePromptAddendum

    /// No persona, no custom instructions ⇒ empty addendum, so
    /// `completionSystemPrompt(custom:)` falls back to the base prompt verbatim.
    func testAddendumEmptyWhenNothingSet() {
        XCTAssertEqual(AppOverrideResolver.effectivePromptAddendum(forBundleId: nil), "")
    }

    /// Persona only ⇒ addendum is exactly the persona block.
    func testAddendumPersonaOnly() {
        Preferences.userName = "Vince"
        XCTAssertEqual(
            AppOverrideResolver.effectivePromptAddendum(forBundleId: nil),
            "The user's name is Vince."
        )
    }

    /// Custom only ⇒ addendum is exactly the resolved custom instructions, leaving the
    /// no-persona path byte-identical to before.
    func testAddendumCustomOnly() {
        Preferences.customInstructions = "Keep replies terse."
        XCTAssertEqual(
            AppOverrideResolver.effectivePromptAddendum(forBundleId: nil),
            "Keep replies terse."
        )
    }

    /// Both set ⇒ persona FIRST, then a blank line, then the custom instructions.
    func testAddendumJoinsPersonaThenCustom() {
        Preferences.userName = "Vince"
        Preferences.customInstructions = "Keep replies terse."
        XCTAssertEqual(
            AppOverrideResolver.effectivePromptAddendum(forBundleId: nil),
            "The user's name is Vince.\n\nKeep replies terse."
        )
    }

    // MARK: - contextCharBudgets

    /// When everything fits in the leftover budget, each piece keeps its full length —
    /// the basis for the byte-identical small-context guarantee.
    func testBudgetKeepsEverythingWhenItFits() {
        let pieces = [
            CoreBridge.ContextPiece(name: "clipboard", length: 50, order: 2),
            CoreBridge.ContextPiece(name: "frequent", length: 40, order: 1),
        ]
        let budget = CoreBridge.contextCharBudgets(recentTextChars: 100, pieces: pieces)
        XCTAssertEqual(budget["clipboard"], 50)
        XCTAssertEqual(budget["frequent"], 40)
    }

    /// The tail floor is reserved even when the tail itself is tiny: with a small cap,
    /// the floor eats the budget and leaves the optional pieces nothing.
    func testBudgetReservesTailFloor() {
        let pieces = [
            CoreBridge.ContextPiece(name: "clipboard", length: 500, order: 2),
        ]
        // cap 80 tokens ⇒ 320 total chars == the floor ⇒ remaining 0 for context.
        let budget = CoreBridge.contextCharBudgets(
            recentTextChars: 10,
            pieces: pieces,
            maxPromptTokens: 80,
            tailFloorChars: 320
        )
        XCTAssertEqual(budget["clipboard"], 0)
    }

    /// A long tail consumes the whole budget (beyond the floor) and starves the
    /// optional pieces — the tail is never sacrificed for context.
    func testBudgetLongTailStarvesContext() {
        let pieces = [
            CoreBridge.ContextPiece(name: "clipboard", length: 500, order: 2),
            CoreBridge.ContextPiece(name: "frequent", length: 100, order: 1),
        ]
        // cap 100 tokens ⇒ 400 total chars; tail 400 ⇒ remaining 0.
        let budget = CoreBridge.contextCharBudgets(
            recentTextChars: 400,
            pieces: pieces,
            maxPromptTokens: 100
        )
        XCTAssertEqual(budget["clipboard"], 0)
        XCTAssertEqual(budget["frequent"], 0)
    }

    /// When the remainder is partial, the easy-to-cut pieces (higher `order`,
    /// clipboard/OCR) are truncated FIRST while the best-keep pieces (lower `order`,
    /// frequent words/persona) survive.
    func testBudgetTruncatesClipboardBeforeFrequentWords() {
        let pieces = [
            CoreBridge.ContextPiece(name: "clipboard", length: 500, order: 2),
            CoreBridge.ContextPiece(name: "frequent", length: 40, order: 1),
        ]
        // cap 100 tokens ⇒ 400 total chars; tail 320 (== floor) ⇒ remaining 80.
        // best-keep first: frequent (order 1) takes its full 40, leaving 40 for
        // clipboard (order 2), which is the one that gets truncated.
        let budget = CoreBridge.contextCharBudgets(
            recentTextChars: 320,
            pieces: pieces,
            maxPromptTokens: 100,
            tailFloorChars: 320
        )
        XCTAssertEqual(budget["frequent"], 40)
        XCTAssertEqual(budget["clipboard"], 40)
    }

    /// Zero-length pieces never appear in the map (callers skip emitting an empty
    /// context block for them).
    func testBudgetSkipsZeroLengthPieces() {
        let pieces = [
            CoreBridge.ContextPiece(name: "clipboard", length: 0, order: 2),
            CoreBridge.ContextPiece(name: "frequent", length: 30, order: 1),
        ]
        let budget = CoreBridge.contextCharBudgets(recentTextChars: 100, pieces: pieces)
        XCTAssertNil(budget["clipboard"])
        XCTAssertEqual(budget["frequent"], 30)
    }
}
