import XCTest

@testable import ProsperApp

/// Hot-path compute budgets for the inline-autocomplete pipeline. Each test pins
/// an explicit ceiling on a per-keystroke / per-candidate / per-generation cost so
/// a superlinear or accidentally-O(vocab) regression fails loudly instead of
/// showing up as typing lag. Ceilings are generous (guarding shape, not jitter);
/// the comment on each states the requirement it encodes.
final class AutocompleteHotPathBudgetTests: XCTestCase {

    /// REQUIREMENT: `sanitizeCompletion` runs once per candidate per ladder rung
    /// on every keystroke's completion — its guards (echo, script, repeat) must
    /// stay linear in the completion+context, never in the document. 1k calls on
    /// a realistic 300-char context ≪ one decode's budget.
    func testSanitizeCompletionBudget() {
        let before = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 7)
            + "And then we "
        let raw = "decided to ship the release on Friday afternoon"
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<1_000 {
                _ = CoreBridge.sanitizeCompletion(raw, before: before)
            }
        }
        XCTAssertLessThan(elapsed, .milliseconds(500), "sanitizeCompletion regressed: \(elapsed)")
    }

    /// REQUIREMENT: the B1 script-mask build enumerates the whole vocabulary ONCE
    /// per (script, vocab) — `isAllowed` must stay a plain scalar scan (~µs/piece)
    /// so even a cold 256k-vocab build stays a one-time sub-second cost. Scaled:
    /// 50k pieces < 250ms.
    func testScriptClassifierVocabScanBudget() {
        let pieces = (0..<50_000).map { i -> String in
            switch i % 4 {
            case 0: return "hello\(i % 97)"
            case 1: return "мир\(i % 89)"
            case 2: return " ▁.,!"
            default: return "λόγος\(i % 83)"  // Greek — blocked under .cyrillic
            }
        }
        let clock = ContinuousClock()
        var blocked = 0
        let elapsed = clock.measure {
            for p in pieces where !ScriptClassifier.isAllowed(p, target: .cyrillic) {
                blocked += 1
            }
        }
        XCTAssertGreaterThan(blocked, 0)
        XCTAssertLessThan(elapsed, .milliseconds(250), "isAllowed vocab scan regressed: \(elapsed)")
    }

    /// REQUIREMENT: `echoesWritingSample` + `echoesScreenContext` run per candidate
    /// per rung with the writing-samples/OCR features on — normalization must stay
    /// linear in suggestion+samples.
    func testEchoGuardsBudget() {
        let samples = (0..<8).map { "sample sentence number \($0) that the user wrote before, long enough to matter." }
        let screen = String(repeating: "visible conversation line with some words. ", count: 20)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<1_000 {
                _ = CoreBridge.echoesWritingSample("a fresh continuation of thought", samples: samples)
                _ = CoreBridge.echoesScreenContext("a fresh continuation of thought", screen: screen)
            }
        }
        XCTAssertLessThan(elapsed, .milliseconds(500), "echo guards regressed: \(elapsed)")
    }
}
