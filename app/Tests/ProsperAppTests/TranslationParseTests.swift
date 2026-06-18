import XCTest
@testable import ProsperApp

/// Covers `CoreBridge.parseTranslation` and `TranslationResult`'s tolerant
/// decoder. The model is asked for `"primary": string`, but smaller models often
/// emit `primary` as a candidate object `{"text": ...}`. Strict decoding used to
/// fail and dump the raw JSON to the user; these guard the recovery paths.
final class TranslationParseTests: XCTestCase {

    func testParsesPlainStringPrimary() {
        let raw = #"{"detectedLanguage": "en", "primary": "инкарнирам", "candidates": [{"text": "инкарнирам", "label": "literal"}]}"#
        let r = CoreBridge.parseTranslation(raw)
        XCTAssertEqual(r.detectedLanguage, "en")
        XCTAssertEqual(r.primary, "инкарнирам")
        XCTAssertEqual(r.candidates.first?.text, "инкарнирам")
    }

    func testParsesObjectPrimary() {
        // Model emitted `primary` as an object (the bug from the report).
        let raw = #"{"detectedLanguage": "en", "primary": {"text": "инкарнирам", "label": "literal", "explanation": "to embody"}, "candidates": [{"text": "въплъщавам", "label": "formal"}]}"#
        let r = CoreBridge.parseTranslation(raw)
        XCTAssertEqual(r.detectedLanguage, "en")
        XCTAssertEqual(r.primary, "инкарнирам")
        XCTAssertEqual(r.candidates.first?.text, "въплъщавам")
    }

    func testEmptyPrimaryFallsBackToFirstCandidate() {
        let raw = #"{"primary": "", "candidates": [{"text": "въплъщавам"}]}"#
        let r = CoreBridge.parseTranslation(raw)
        XCTAssertEqual(r.primary, "въплъщавам")
    }

    func testFencedJSONStillParses() {
        let raw = "```json\n{\"primary\": {\"text\": \"hi\"}, \"candidates\": []}\n```"
        let r = CoreBridge.parseTranslation(raw)
        XCTAssertEqual(r.primary, "hi")
    }

    func testNonJSONFallsBackToRawText() {
        let r = CoreBridge.parseTranslation("just plain text")
        XCTAssertEqual(r.primary, "just plain text")
        XCTAssertTrue(r.candidates.isEmpty)
    }

    // MARK: - foreign-candidate filtering

    func testFilterDropsSisterLanguageCandidatesForBulgarian() {
        // Caught: candidates carrying a Cyrillic letter absent from the Bulgarian
        // alphabet — `і` (Ukrainian), `э` (Russian). NOT caught: misspellings that
        // use only valid Bulgarian letters (a different, harder problem).
        let cands = [
            TranslationCandidate(text: "въплътен", label: "formal", explanation: nil),
            TranslationCandidate(text: "втілесно", label: "ukr leak", explanation: nil),  // і
            TranslationCandidate(text: "этот", label: "rus leak", explanation: nil),       // э
            TranslationCandidate(text: "процъфтявам", label: "ok", explanation: nil),
        ]
        let kept = CoreBridge.filterForeignCandidates(cands, target: "Bulgarian")
        XCTAssertEqual(kept.map(\.text), ["въплътен", "процъфтявам"])
    }

    func testFilterKeepsLatinAndDigitsForBulgarian() {
        // Mixed-script / non-Cyrillic content must not be policed.
        let cands = [
            TranslationCandidate(text: "OK 123", label: nil, explanation: nil),
            TranslationCandidate(text: "въплътен #1", label: nil, explanation: nil),
        ]
        let kept = CoreBridge.filterForeignCandidates(cands, target: "Bulgarian")
        XCTAssertEqual(kept.count, 2)
    }

    func testFilterPolicesRussianTargetByItsAlphabet() {
        // For a Russian target: keep Russian-only letters (ы э ё), drop a
        // Ukrainian leak (і). Confirms the filter is per-target, not Bulgarian-only.
        let cands = [
            TranslationCandidate(text: "воплощённый", label: "ё ok", explanation: nil),
            TranslationCandidate(text: "это", label: "э ok", explanation: nil),
            TranslationCandidate(text: "втілений", label: "ukr leak", explanation: nil),  // і
        ]
        let kept = CoreBridge.filterForeignCandidates(cands, target: "Russian")
        XCTAssertEqual(kept.map(\.text), ["воплощённый", "это"])
    }

    func testFilterDisabledForUnknownTarget() {
        let cands = [TranslationCandidate(text: "втілесно", label: nil, explanation: nil)]
        // No alphabet known for "Klingon" → pass through unchanged.
        XCTAssertEqual(CoreBridge.filterForeignCandidates(cands, target: "Klingon").count, 1)
    }

    func testFilterDropsWholeOtherScriptLeaksForBulgarian() {
        // The reported bug: translating "gospel" to Bulgarian, the model leaked a
        // Chinese candidate (福音) alongside the correct Cyrillic one. The
        // Cyrillic-only check could not see it (no Cyrillic letters at all). Now any
        // hard-foreign script — CJK, kana, Hangul, Arabic, Hebrew, Greek, … — is
        // dropped for a Cyrillic target. Latin loanwords still pass.
        let cands = [
            TranslationCandidate(text: "евангелие", label: nil, explanation: nil),
            TranslationCandidate(text: "福音", label: nil, explanation: nil),        // Chinese
            TranslationCandidate(text: "ふくいん", label: nil, explanation: nil),      // Japanese kana
            TranslationCandidate(text: "복음", label: nil, explanation: nil),        // Korean
            TranslationCandidate(text: "إنجيل", label: nil, explanation: nil),       // Arabic
            TranslationCandidate(text: "Gospel", label: nil, explanation: nil),     // Latin — kept
        ]
        let kept = CoreBridge.filterForeignCandidates(cands, target: "Bulgarian")
        XCTAssertEqual(kept.map(\.text), ["евангелие", "Gospel"])
    }
}
