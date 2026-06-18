import XCTest
@testable import ProsperApp

/// Detection gate for the silent auto-continue nudge (`AgentController`). The
/// dominant failure is a local model ending a turn announcing a next step it never
/// performed; the gate must catch that without retriggering on a genuine final answer.
final class AgentAutoContinueTests: XCTestCase {

    // Should continue: stated-but-unperformed action.

    func testTrailingColonContinues() {
        XCTAssertTrue(AgentController.signalsContinuation(
            "Let me first check what's in one of the members CSV files to understand the structure:"))
    }

    func testLeadInVerbContinues() {
        XCTAssertTrue(AgentController.signalsContinuation("I'll now run the combine step."))
        XCTAssertTrue(AgentController.signalsContinuation("Next, I will read each file and extract the emails."))
        XCTAssertTrue(AgentController.signalsContinuation("Now I need to write the output file."))
    }

    func testUnparsedFunctionFragmentContinues() {
        // Model attempted a tool call that didn't parse → fragment leaks into content,
        // server reported `stop`. Strong continue signal.
        XCTAssertTrue(AgentController.signalsContinuation("Reading the file <function=shell"))
    }

    func testLeadInAfterPriorSentenceContinues() {
        XCTAssertTrue(AgentController.signalsContinuation(
            "I found three CSV files. Let me check the first one."))
    }

    // Should NOT continue: genuine final answer / completed work.

    func testFinalAnswerDoesNotContinue() {
        XCTAssertFalse(AgentController.signalsContinuation(
            "Done. Created memlocal.md with 142 unique emails combined from all members files."))
    }

    func testPlainSummaryDoesNotContinue() {
        XCTAssertFalse(AgentController.signalsContinuation(
            "The three files contained 142 emails total; duplicates were removed."))
    }

    func testProseMentioningFunctionTagWord() {
        // Mentions the word but no `<function=` fragment and no intent lead-in.
        XCTAssertFalse(AgentController.signalsContinuation(
            "The shell function returned exit code 0 and the file was written."))
    }

    func testEmptyDoesNotContinue() {
        XCTAssertFalse(AgentController.signalsContinuation("   \n  "))
    }
}
