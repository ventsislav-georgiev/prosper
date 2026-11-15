import XCTest
@testable import ProsperApp

/// #1181: the decode loop's step `ThinkGate.next` (the chain choice and the gate feed the engine's
/// loop calls once per token) driven through whole fake token sequences. No llama context, no
/// model file, no sampler: the chains are the strings "grammar" and "plain", and the token ids
/// are made up.
final class LlamaThinkChainTests: XCTestCase {
    /// Fake ids: 1 `<think>`, 2 `</think>`, 3 `<tool_call>`, 9 any other token.
    private let thinkOpen: Int32 = 1, thinkClose: Int32 = 2, toolCall: Int32 = 3, other: Int32 = 9

    /// Runs the step the way the decode loop does, at most `budget` times (the loop's
    /// `generated < budget`): returns the chain handed to the sampler at each step.
    private func chains(_ tokens: [Int32], budget: Int = .max) -> [String] {
        var gate = ThinkGate(open: thinkOpen, close: thinkClose)
        var picked: [String] = []
        for token in tokens.prefix(budget) {
            let fed = gate.next(grammar: "grammar", plain: "plain") { chain in
                picked.append(chain)
                return token
            }
            XCTAssertEqual(fed, token)
        }
        return picked
    }

    func testNoThinkBlockSamplesEveryTokenWithTheGrammar() {
        XCTAssertEqual(chains([other, other, toolCall, other]),
                       ["grammar", "grammar", "grammar", "grammar"])
    }

    func testBlockThatOpensFirstAndClosesSamplesPlainInside() {
        XCTAssertEqual(chains([thinkOpen, other, other, thinkClose, other]),
                       ["grammar", "plain", "plain", "plain", "grammar"])
    }

    /// A think tag after the first token is text: the grammar chain stays on.
    func testThinkTagAfterTextIsText() {
        XCTAssertEqual(chains([other, thinkOpen, toolCall, thinkClose, toolCall]),
                       ["grammar", "grammar", "grammar", "grammar", "grammar"])
    }

    /// The `<tool_call>` token inside the block is sampled by the plain chain, never the grammar.
    func testToolCallInsideTheBlockIsNotSampledWithTheGrammar() {
        XCTAssertEqual(chains([thinkOpen, other, toolCall, other, toolCall]),
                       ["grammar", "plain", "plain", "plain", "plain"])
    }

    /// After `</think>` the next token is sampled with the grammar chain, so the real call arms it.
    func testToolCallAfterTheBlockIsSampledWithTheGrammar() {
        XCTAssertEqual(chains([thinkOpen, toolCall, thinkClose, toolCall, other]),
                       ["grammar", "plain", "plain", "grammar", "grammar"])
    }

    func testUnclosedBlockStaysPlainToTheEnd() {
        XCTAssertEqual(chains([thinkOpen, other, toolCall, other, toolCall, other]),
                       ["grammar", "plain", "plain", "plain", "plain", "plain"])
    }

    /// The budget cuts the run inside the block: every step taken was plain after the opener,
    /// and the close the model would have sampled next never arrives.
    func testBudgetReachedInsideTheBlock() {
        XCTAssertEqual(chains([thinkOpen, other, other, thinkClose, toolCall], budget: 3),
                       ["grammar", "plain", "plain"])
    }
}
