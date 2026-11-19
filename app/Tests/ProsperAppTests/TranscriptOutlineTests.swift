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
}

/// #1633: the outline kept between polls (`TranscriptOutline.Builder`) reads only what a poll changed and always equals a
/// full build. Fake literal blocks only; rows count blocks read, never time.
final class TranscriptOutlineBuilderTests: XCTestCase {
    private func b(_ id: Int, _ body: BlockBody, children: [TranscriptBlock] = []) -> TranscriptBlock {
        TranscriptBlock(id: id, body: body, tier: .specific, version: "2.1.300", source: nil, children: children)
    }
    private func user(_ id: Int, _ text: String, peer: String? = nil) -> TranscriptBlock {
        var c = Clip(text, cap: 10_000)
        if let peer { c.origin = PromptOrigin(peer: peer) }
        return b(id, .user(c))
    }
    private func say(_ id: Int, _ text: String) -> TranscriptBlock { b(id, .assistant(Clip(text, cap: 10_000))) }
    private func bash(_ id: Int, _ cmd: String, error: Bool = false) -> TranscriptBlock {
        b(id, .bash(command: cmd, description: nil, output: Clip("ok", cap: 100), isError: error))
    }
    /// What publish() built at 944bac96, over everything: the oracle.
    private func full(_ blocks: [TranscriptBlock], _ asides: [TranscriptBlock]) -> [TranscriptOutline.Chapter] {
        let floor = blocks.first?.id ?? Int.min
        return TranscriptOutline.chapters((blocks + asides.filter { $0.id >= floor }).sorted { $0.id < $1.id })
    }

    /// Red before: publish() ran `TranscriptOutline.chapters` over all 1500 blocks for every poll with lines
    /// (AgentTranscriptModel.swift:689 at 944bac96). One new step, its result, a new prompt: a constant few blocks read.
    func testOneNewBlockReadsOneBlockNotTheTranscript() {
        var blocks = (0..<500).flatMap { i in [user(3 * i, "Prompt \(i)"), bash(3 * i + 1, "make \(i)"), say(3 * i + 2, "Done \(i)")] }
        var o = TranscriptOutline.Builder()
        o.update(blocks: blocks, asides: [], dirty: [])
        XCTAssertEqual(o.chapters, full(blocks, []))
        XCTAssertGreaterThanOrEqual(o.examined, 1500, "the first build reads everything")
        var e = o.examined
        blocks.append(bash(1500, "make more"))
        o.update(blocks: blocks, asides: [], dirty: [])
        XCTAssertEqual(o.examined - e, 1, "one new step over 1500 blocks: one block read")
        XCTAssertEqual(o.chapters, full(blocks, []))
        e = o.examined
        blocks[blocks.count - 1] = bash(1500, "make more", error: true)   // its result lands in place, failed
        o.update(blocks: blocks, asides: [], dirty: [1500])
        XCTAssertEqual(o.examined - e, 1, "a result in place: that step alone is read again")
        XCTAssertTrue(o.chapters.last?.hasError == true)
        XCTAssertEqual(o.chapters, full(blocks, []))
        e = o.examined
        blocks.append(user(1501, "next"))
        o.update(blocks: blocks, asides: [], dirty: [])
        XCTAssertLessThanOrEqual(o.examined - e, 2, "a new prompt: only the new turn")
        XCTAssertEqual(o.chapters, full(blocks, []))
        e = o.examined
        o.update(blocks: blocks, asides: [], dirty: [])
        XCTAssertEqual(o.examined - e, 0, "nothing new: nothing read")
    }

    /// The streaming case: one long turn (an agent at work), 1500 steps. Red before as above: the whole turn per poll.
    func testOneNewStepOfALongTurnReadsOneBlock() {
        var blocks = [user(0, "Refactor the parser")]
            + (1...1500).map { i in i % 2 == 0 ? say(i, "step \(i)") : bash(i, "make \(i)") }
        var o = TranscriptOutline.Builder()
        o.update(blocks: blocks, asides: [], dirty: [])
        var e = o.examined
        blocks.append(bash(1501, "make test"))
        o.update(blocks: blocks, asides: [], dirty: [])
        XCTAssertEqual(o.examined - e, 1)
        e = o.examined
        blocks[blocks.count - 1] = bash(1501, "make test", error: true)
        blocks.append(say(1502, "one failed"))
        o.update(blocks: blocks, asides: [], dirty: [1501])
        XCTAssertEqual(o.examined - e, 2, "the result in place and the new answer")
        XCTAssertEqual(o.chapters, full(blocks, []))
        XCTAssertEqual(o.chapters.last?.response, "one failed")
        XCTAssertEqual(o.chapters.last?.tools, "Bash 751")
        // A step that changed tool, and an answer rewritten: the turn is folded again (red under retally-name, -answer).
        blocks[1] = b(1, .read(path: "/Users/example/a.swift", detail: nil))
        blocks[blocks.count - 1] = say(1502, "all green")
        o.update(blocks: blocks, asides: [], dirty: [1, 1502])
        XCTAssertEqual(o.chapters.last?.tools, "Read 1, Bash 750")
        XCTAssertEqual(o.chapters.last?.response, "all green")
        XCTAssertEqual(o.chapters, full(blocks, []))
    }

    /// CI 44507460812 step 287: a front drop leaves only an image of the cut turn, so `turns` joins it to the next
    /// prompt's turn. Red before: the drop kept it a partial chapter of its own (id 2) ahead of the slash chapter (id 3).
    func testADropThatLeavesOnlyAnImageJoinsItToTheNextTurn() {
        var blocks = [user(0, "A"), bash(1, "make"), b(2, .image), b(3, .command(name: "/model", args: "opus")),
                      bash(4, "ls"), user(5, "B"), say(6, "b")]
        var o = TranscriptOutline.Builder()
        o.update(blocks: blocks, asides: [], dirty: [])
        XCTAssertEqual(o.chapters, full(blocks, []))
        let e = o.examined
        blocks.removeFirst(2)
        o.update(blocks: blocks, asides: [], dirty: [])
        XCTAssertEqual(o.chapters.map(\.id), [2, 5])
        XCTAssertEqual(o.chapters.map(\.kind), [.slash, .prompt])
        XCTAssertEqual(o.chapters, full(blocks, []))
        XCTAssertEqual(o.examined - e, 4, "the cut rest (1) and the joined turn (3); B's turn is kept, not read")
    }

    /// A seeded stream of appends, prompts, images, peer asides, compactions, results in place (in old turns and the
    /// last part), a tool that changes kind, subagent steps and front drops (to empty too), in batches: after every
    /// update the kept chapters equal a full build. Red under each fold mutant in mutants.txt.
    func testEveryUpdateEqualsAFullBuild() {
        var seed: UInt64 = 0x1633
        func rnd(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var blocks: [TranscriptBlock] = [], asides: [TranscriptBlock] = [], dirty = Set<Int>(), next = 0
        var o = TranscriptOutline.Builder()
        func take() -> Int { defer { next += 1 }; return next }
        func someIndex(_ f: (TranscriptBlock) -> Bool) -> Int? {
            let c = blocks.indices.filter { f(blocks[$0]) }
            return c.isEmpty ? nil : c[rnd(c.count)]
        }
        func isBash(_ x: TranscriptBlock) -> Bool { if case .bash = x.body { true } else { false } }
        for step in 0..<700 {
            switch rnd(14) {
            case 0, 1: blocks.append(bash(take(), "make", error: rnd(5) == 0))
            case 2: blocks.append(say(take(), "answer \(step)"))
            case 3: blocks.append(b(take(), .read(path: "/Users/example/a.swift", detail: nil)))
            case 4: blocks.append(user(take(), "prompt \(step)"))
            case 5: blocks.append(b(take(), .image))
            case 6: asides.append(user(take(), "from a peer \(step)", peer: rnd(2) == 0 ? "api-qa" : ""))
            case 7: blocks.append(rnd(2) == 0 ? b(take(), .compaction(trigger: "auto", preTokens: nil, summary: nil))
                                               : b(take(), .command(name: "/model", args: "opus")))
            case 8, 9:
                if let i = someIndex(isBash), case .bash(let c, let d, let out, let err) = blocks[i].body {
                    blocks[i].body = .bash(command: c, description: d, output: out, isError: !err)
                    dirty.insert(blocks[i].id)
                }
            case 10:
                if let i = someIndex(isBash) {
                    blocks[i].body = .read(path: "/Users/example/b.swift", detail: rnd(2) == 0 ? "error: gone" : nil)
                    dirty.insert(blocks[i].id)
                }
            case 11:
                if let i = someIndex({ if case .thread = $0.body { true } else { false } }), rnd(2) == 0 {
                    blocks[i].children.append(bash(take(), "sub", error: rnd(4) == 0))
                    dirty.insert(blocks[i].id)
                } else {
                    blocks.append(b(take(), .thread(agentId: "a\(step)", title: "Explore"), children: [say(take(), "sub")]))
                }
            case 12: blocks.removeFirst(min(blocks.count, 1 + rnd(3)))
            default: blocks.removeFirst(min(blocks.count, rnd(2)))
            }
            guard rnd(3) != 0 else { continue }   // some polls land several changes at once
            o.update(blocks: blocks, asides: asides, dirty: dirty)
            dirty = []
            XCTAssertEqual(o.chapters, full(blocks, asides), "step \(step)")
            if o.chapters != full(blocks, asides) { return }
        }
        XCTAssertGreaterThan(o.chapters.count, 3, "the stream ends with a few chapters")
    }
}
