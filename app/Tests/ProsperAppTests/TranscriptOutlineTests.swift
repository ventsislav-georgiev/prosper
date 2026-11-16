import XCTest
@testable import ProsperApp

/// #904 (#832 X1 step A, spec v2.1 8.1 and 8.4): chapters and the row a block shows in. Fake literal blocks only; no file,
/// no window, no dch.
final class TranscriptOutlineTests: XCTestCase {

    private func b(_ id: Int, _ body: BlockBody, children: [TranscriptBlock] = []) -> TranscriptBlock {
        TranscriptBlock(id: id, body: body, tier: .specific, version: "2.1.300", source: nil, children: children)
    }
    private func user(_ id: Int, _ text: String) -> TranscriptBlock { b(id, .user(Clip(text, cap: 10_000))) }
    private func say(_ id: Int, _ text: String) -> TranscriptBlock { b(id, .assistant(Clip(text, cap: 10_000))) }
    private func bash(_ id: Int, _ cmd: String, error: Bool = false) -> TranscriptBlock {
        b(id, .bash(command: cmd, description: nil, output: Clip("ok", cap: 100), isError: error))
    }

    /// Red before: TranscriptOutline did not exist. A partial first turn, a prompt (first non-blank line, whitespace
    /// collapsed), a slash command, a compaction, and an error turn.
    func testChapterKindsTitlesOrdinalsAndErrors() {
        let blocks = [say(0, "tail of an earlier turn"), bash(1, "ls"),
                      user(2, "  \n   Fix   the\tbuild  \nsecond line"), say(3, "done"),
                      b(4, .command(name: "/model", args: "opus")), say(5, "ok"),
                      b(6, .compaction(trigger: "auto", preTokens: nil, summary: nil)), say(7, "resumed"),
                      user(8, "run the tests"), bash(9, "make test", error: true), say(10, "one failed")]
        let c = TranscriptOutline.chapters(blocks)
        XCTAssertEqual(c.map(\.id), [0, 2, 4, 6, 8])
        XCTAssertEqual(c.map(\.ordinal), [1, 2, 3, 4, 5])
        XCTAssertEqual(c.map(\.kind), [.partial, .prompt, .slash, .compaction, .prompt])
        XCTAssertEqual(c.map(\.title), ["Earlier part of a turn", "Fix the build", "/model opus", "Conversation compacted",
                                        "run the tests"])
        XCTAssertEqual(c.map(\.hasError), [false, false, false, false, true])
        // A pasted image leads its prompt: still a prompt, titled by its text.
        let lead = TranscriptOutline.chapters([b(0, .image), user(1, "what is this"), say(2, "a chart")])
        XCTAssertEqual(lead.map(\.kind), [.prompt])
        XCTAssertEqual(lead.first?.title, "what is this")
        XCTAssertEqual(lead.first?.id, 0, "the id is the turn's first block")
        XCTAssertEqual(TranscriptOutline.chapters([b(0, .command(name: "/clear", args: nil))]).first?.title, "/clear")
        XCTAssertTrue(TranscriptOutline.chapters([]).isEmpty)
    }

    /// Ruling on #904 r1 (v1 OQ-A, no merge): turns() puts a prompt right after a compaction in the compaction's turn;
    /// the outline makes them two chapters, the prompt's id its own (first) block's. Red before: one chapter, id 2.
    func testCompactionThenPromptAreTwoChapters() {
        let blocks = [user(0, "start"), say(1, "ok"),
                      b(2, .compaction(trigger: "auto", preTokens: nil, summary: nil)), user(3, "carry on"),
                      bash(4, "make", error: true), say(5, "failed"),
                      b(6, .compaction(trigger: "manual", preTokens: nil, summary: nil)), b(7, .image), user(8, "see this")]
        XCTAssertEqual(TranscriptVerbosity.turns(blocks).map { $0.first?.id }, [0, 2, 6], "turns() is unchanged")
        let c = TranscriptOutline.chapters(blocks)
        XCTAssertEqual(c.map(\.id), [0, 2, 3, 6, 7], "an image before a prompt goes with the prompt")
        XCTAssertEqual(c.map(\.kind), [.prompt, .compaction, .prompt, .compaction, .prompt])
        XCTAssertEqual(c.map(\.title), ["start", "Conversation compacted", "carry on", "Conversation compacted", "see this"])
        XCTAssertEqual(c.map(\.ordinal), [1, 2, 3, 4, 5])
        XCTAssertEqual(c.map(\.hasError), [false, false, true, false, false], "the steps' error is the prompt's chapter's")
        // The prompt's chapter is a jump target: its own row, in the compaction's turn.
        let t = TranscriptOutline.target(3, in: blocks, level: .focused)
        XCTAssertEqual(t?.turn, 2)
        XCTAssertEqual(t?.row, "b3")
    }

    /// Ruling on #904 r1 (decision 2): chapters run on main in publish(). Their cost on a 2000-block transcript (the
    /// model's maxBlocks), best of 5, printed as "X1C"; the bound is loose (a debug build under a loaded gate).
    func testChaptersCostOn2000Blocks() {
        let blocks = (0..<500).flatMap { i in
            [user(4 * i, "Prompt \(i) " + String(repeating: "word ", count: 40)), bash(4 * i + 1, "make \(i)"),
             b(4 * i + 2, .thinking(Clip("hmm", cap: 100))), say(4 * i + 3, "Done \(i)")]
        }
        XCTAssertEqual(blocks.count, 2000)
        var best = Double.infinity, n = 0
        for _ in 0..<5 {
            let t0 = Date()
            n = TranscriptOutline.chapters(blocks).count
            best = min(best, Date().timeIntervalSince(t0))
        }
        print(String(format: "X1C chapters of 2000 blocks: %.2f ms (best of 5), %d chapters", best * 1000, n))
        XCTAssertEqual(n, 500)
        XCTAssertLessThan(best, 0.25)
    }

    /// A subagent's own prompt is a step of its turn, never a chapter; its failed step marks the turn.
    func testSubagentThreadIsNotAChapter() {
        let thread = b(2, .thread(agentId: "a1", title: "Explore"),
                       children: [user(3, "Search the repo"), bash(4, "grep -r x", error: true), say(5, "found")])
        let c = TranscriptOutline.chapters([user(0, "look around"), say(1, "starting"), thread, say(6, "done")])
        XCTAssertEqual(c.map(\.id), [0])
        XCTAssertEqual(c.first?.hasError, true, "Focused's summary counts the subagent's error")
    }

    /// Red under a cap by characters: 119 letters and a 5-scalar family emoji are 120 characters but 124 scalars.
    func testTitleCapIs120ScalarsAndNeverSplitsAnEmoji() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let t = TranscriptOutline.title(String(repeating: "a", count: 119) + family + "tail", or: "")
        XCTAssertEqual(t, String(repeating: "a", count: 119), "the emoji would pass the cap: left out whole")
        XCTAssertLessThanOrEqual(t.unicodeScalars.count, 120)
        let fits = TranscriptOutline.title(String(repeating: "a", count: 115) + family, or: "")
        XCTAssertEqual(fits.unicodeScalars.count, 120, "exactly 120 scalars stay")
        XCTAssertTrue(fits.hasSuffix(family))
        XCTAssertEqual(TranscriptOutline.title(String(repeating: "b", count: 121), or: "").unicodeScalars.count, 120)
        XCTAssertEqual(TranscriptOutline.title(" \n\t\n", or: "Prompt"), "Prompt", "a blank prompt has a title")
        let slash = TranscriptOutline.chapters([b(0, .command(name: "/review", args: String(repeating: "x", count: 200)))])
        XCTAssertEqual(slash.first?.title.unicodeScalars.count, 120)
    }

    /// Ids hold across a poll (blocks appended) and a page (blocks prepended with lower ids): the old partial first
    /// turn joins the page's last prompt, every later chapter keeps its id.
    func testChapterIdsAreStableAcrossPollsAndPaging() {
        let live = [say(10, "end of an earlier turn"), user(11, "B"), say(12, "b"), user(13, "C"), say(14, "c")]
        let before = TranscriptOutline.chapters(live)
        XCTAssertEqual(before.map(\.id), [10, 11, 13])
        XCTAssertEqual(before.first?.kind, .partial)
        let polled = TranscriptOutline.chapters(live + [bash(15, "make"), user(16, "D")])
        XCTAssertEqual(Array(polled.map(\.id).prefix(3)), [10, 11, 13], "a poll keeps every id")
        let paged = TranscriptOutline.chapters([user(7, "A"), say(8, "a"), bash(9, "ls")] + live)
        XCTAssertEqual(paged.map(\.id), [7, 11, 13], "the partial turn is A's now; B and C keep their ids")
        XCTAssertEqual(paged.map(\.kind), [.prompt, .prompt, .prompt])
        XCTAssertEqual(paged.map(\.ordinal), [1, 2, 3])
    }

    /// The model publishes the chapters of its blocks (read from a fake file in tempDir, no dch).
    @MainActor
    func testModelPublishesChaptersWithItsBlocks() throws {
        let url = tempDir().appendingPathComponent("o.jsonl")
        try JumpFixture.write(url, JumpFixture.turns(3))
        let m = JumpFixture.model(url)
        defer { m.stop() }
        XCTAssertEqual(m.chapters.map(\.id), [0, 3, 6])
        XCTAssertEqual(m.chapters, TranscriptOutline.chapters(m.blocks))
        XCTAssertEqual(m.chapters.map(\.title), ["Prompt 0", "Prompt 1", "Prompt 2"])
    }

    /// Red before: rowID did not exist. The row a block shows in at each level; a level switch keeps the chapter ids
    /// (chapters never read the level) and a prompt chapter's row is its own "b<id>" at every level.
    func testRowIDAtEveryLevel() {
        let thread = b(3, .thread(agentId: "a1", title: "Explore"),
                       children: [bash(4, "a"), bash(5, "b"), bash(6, "c"), bash(7, "d")])
        let blocks = [user(0, "go"), b(1, .thinking(Clip("hmm", cap: 100))), bash(2, "make"), thread, say(8, "done"),
                      user(9, "again"), say(10, "ok")]
        func row(_ id: Int, _ l: AgentVerbosity) -> String? { TranscriptVerbosity.rowID(containing: id, in: blocks, level: l) }
        // Verbose: every block is its own card; a subagent step is inside its thread's card.
        XCTAssertEqual(row(2, .verbose), "b2")
        XCTAssertEqual(row(1, .verbose), "b1")
        XCTAssertEqual(row(4, .verbose), "b3")
        // Default: one-line rows; a step past the thread's tail is still the thread's row; thinking shows nowhere.
        XCTAssertEqual(row(2, .default), "b2")
        XCTAssertEqual(row(4, .default), "b3", "dropped from the tail of 3, still in the thread")
        XCTAssertEqual(row(7, .default), "b3")
        XCTAssertTrue(row(1, .default) == nil, "hidden at Default")
        // Focused: the steps fold into the turn's summary row, the subagent's steps too; prompt and reply are their own.
        XCTAssertEqual(row(2, .focused), "s0")
        XCTAssertEqual(row(5, .focused), "s0")
        XCTAssertEqual(row(8, .focused), "b8")
        XCTAssertTrue(row(99, .focused) == nil, "not loaded")
        let ids = TranscriptOutline.chapters(blocks).map(\.id)
        XCTAssertEqual(ids, [0, 9])
        for l in AgentVerbosity.allCases {
            XCTAssertEqual(ids.map { row($0, l) }, ids.map { "b\($0)" }, "\(l)")
        }
    }

    /// Where a jump lands: the turn (the LazyVStack's child) and the row inside it.
    func testJumpTargetIsTheTurnAndTheRow() {
        let blocks = [user(0, "go"), bash(1, "make"), say(2, "done"), user(3, "next"), bash(4, "ls"), say(5, "ok")]
        let t = TranscriptOutline.target(4, in: blocks, level: .focused)
        XCTAssertEqual(t?.turn, 3)
        XCTAssertEqual(t?.row, "s3")
        XCTAssertEqual(TranscriptOutline.target(4, in: blocks, level: .default)?.row, "b4")
        XCTAssertTrue(TranscriptOutline.target(42, in: blocks, level: .default) == nil)
    }
}
