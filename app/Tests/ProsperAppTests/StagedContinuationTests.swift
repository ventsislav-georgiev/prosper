import XCTest
@testable import ProsperApp

/// B4 staged-continuation epoch + typed-suffix commit gate.
final class StagedContinuationTests: XCTestCase {

    private let staged = StagedContinuation(epoch: 7, inputLine: "let me ", result: "know if you need anything")

    func testCommitsWhenEpochAndInputMatch() {
        XCTAssertEqual(staged.commit(currentEpoch: 7, currentInputLine: "let me "),
                       "know if you need anything")
    }

    func testRejectsOnEpochChange() {
        XCTAssertNil(staged.commit(currentEpoch: 8, currentInputLine: "let me "))
    }

    func testForwardTypingIntoStagedReturnsRemainder() {
        XCTAssertEqual(staged.commit(currentEpoch: 7, currentInputLine: "let me know if "),
                       "you need anything")
    }

    func testRejectsOnDivergentTyping() {
        XCTAssertNil(staged.commit(currentEpoch: 7, currentInputLine: "let me tell "))
    }

    func testRejectsWhenFullyTypedOut() {
        // Typed the whole staged result → nothing left to show.
        XCTAssertNil(staged.commit(currentEpoch: 7,
                                   currentInputLine: "let me know if you need anything"))
    }

    func testRejectsUnrelatedContext() {
        XCTAssertNil(staged.commit(currentEpoch: 7, currentInputLine: "different"))
    }
}
