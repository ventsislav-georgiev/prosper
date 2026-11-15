import XCTest
@testable import ProsperApp

/// #1269 step A: the load-earlier orphan (a page's open calls take the live results) and the
/// image-only prompt (it opens a turn). Pure: transcripts are literal values, no IO, no window.
/// Nothing here runs a closure off the main actor; the rows are plain synchronous tests.
extension AgentWindowD1Tests {

    private var tfImage: [String: Any] { ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": ""]] }

    private func tfUser(_ parts: [[String: Any]]) -> [String: Any] {
        entry("user", ["message": ["role": "user", "content": parts]])
    }

    private func tfPrompt(_ text: String) -> [String: Any] {
        entry("user", ["message": ["role": "user", "content": text]])
    }

    // MARK: item 4: the load-earlier orphan

    /// Red before: prepend() never put the page's open call into `pending`, so the live result
    /// found no call (add(), the `else` of `pending.removeValue`) and made an orphan card.
    func testTranscriptFollowupLiveResultClosesACallOnAPrependedPage() {
        var live = asm([say("later")])
        live.prepend(asm([toolUse("t1", "Bash", ["command": "ls"])]))
        XCTAssertTrue(live.blocks.first?.pending == true, "open on the page")
        live.add(TranscriptDecoder.decode(line: line(toolResult("t1", "out"))), source: nil)
        XCTAssertEqual(live.blocks.count, 2, "no orphan Tool result card: \(live.blocks.map(\.body))")
        XCTAssertTrue(live.orphans.isEmpty)
        XCTAssertTrue(live.blocks.first?.pending == false)
        guard let b0 = live.blocks.first, case .bash("ls", _, let out?, _) = b0.body else { return XCTFail("\(live.blocks.map(\.body))") }
        XCTAssertEqual(out.text, "out")
    }

    /// Red before: the second call's result is not the problem, the first one's is; with two
    /// open calls on the page only the one with a result closes.
    func testTranscriptFollowupTwoOpenCallsOneResultTheOtherStaysPending() {
        var live = asm([say("later")])
        live.prepend(asm([toolUse("t1", "Bash", ["command": "ls"]), toolUse("t2", "Bash", ["command": "pwd"])]))
        live.add(TranscriptDecoder.decode(line: line(toolResult("t1", "out"))), source: nil)
        XCTAssertEqual(live.blocks.count, 3, "no orphan card")
        XCTAssertEqual(live.blocks.map(\.pending), [false, true, false])
        XCTAssertTrue(live.orphans.isEmpty)
    }

    /// Pins today's behaviour and the mutant that carries closed calls: a call closed on its own
    /// page adds nothing to `pending`, so a second result for the id is an orphan.
    func testTranscriptFollowupAClosedCallOnThePageAddsNothingToPending() {
        var live = asm([say("later")])
        live.prepend(asm([toolUse("t1", "Bash", ["command": "ls"]), toolResult("t1", "out")]))
        XCTAssertEqual(live.blocks.map(\.pending), [false, false])
        live.add(TranscriptDecoder.decode(line: line(toolResult("t1", "again"))), source: nil)
        XCTAssertEqual(live.blocks.count, 3, "the stray result is its own card")
        XCTAssertTrue(live.orphans["t1"] != nil)
    }

    /// Pins today's pairing (a result that came before the page): the orphan folds into the call and
    /// the id is not carried as open.
    func testTranscriptFollowupAResultThatCameBeforeThePageStillPairs() {
        var live = asm([toolResult("t1", "out"), say("later")])
        live.prepend(asm([toolUse("t1", "Bash", ["command": "ls"])]))
        XCTAssertEqual(live.blocks.count, 2)
        XCTAssertTrue(live.orphans.isEmpty)
        XCTAssertEqual(live.blocks.map(\.pending), [false, false])
        live.add(TranscriptDecoder.decode(line: line(toolResult("t1", "again"))), source: nil)
        XCTAssertEqual(live.blocks.count, 3, "the id is closed: a second result is an orphan")
    }

    /// An empty page and the same page twice: no id is tracked twice and nothing else changes.
    func testTranscriptFollowupAnEmptyPageAndARepeatedPageChangeNothing() {
        var live = asm([say("later")])
        live.prepend(asm([]))
        XCTAssertEqual(live.blocks.count, 1)
        live.add(TranscriptDecoder.decode(line: line(toolResult("t9", "x"))), source: nil)
        XCTAssertEqual(live.blocks.count, 2, "an empty page opened no call: the result is an orphan")
        var twice = asm([say("later")])
        twice.prepend(asm([toolUse("t1", "Bash", ["command": "ls"])]))
        twice.prepend(asm([toolUse("t1", "Bash", ["command": "ls"])]))
        XCTAssertEqual(twice.blocks.count, 3)
        twice.add(TranscriptDecoder.decode(line: line(toolResult("t1", "out"))), source: nil)
        XCTAssertEqual(twice.blocks.count, 3, "closed one call, made no orphan")
        XCTAssertEqual(twice.blocks.filter(\.pending).count, 1, "the id is tracked once")
    }

    /// The carried calls stay bounded by maxPending: the oldest are dropped, as add() drops them.
    func testTranscriptFollowupCarriedCallsStayWithinMaxPending() {
        var live = asm([say("later")], maxPending: 4)
        live.prepend(asm((0..<6).map { toolUse("c\($0)", "Bash", ["command": "ls"]) }, maxPending: 100))
        XCTAssertEqual(live.blocks.count, 7)
        live.add(TranscriptDecoder.decode(line: line(toolResult("c5", "x"))), source: nil)
        XCTAssertEqual(live.blocks.count, 7, "a kept call closes in place")
        live.add(TranscriptDecoder.decode(line: line(toolResult("c0", "x"))), source: nil)
        XCTAssertEqual(live.blocks.count, 8, "a dropped call keeps reading running: its result is an orphan")
        XCTAssertTrue(live.orphans["c0"] != nil)
    }

    // MARK: item 2: the image-only prompt

    private func tfImageOnlyBlocks() -> [TranscriptBlock] {
        asm([tfPrompt("go"), toolUse("b", "Bash", ["command": "ls"]), toolResult("b", "f"), say("Done."),
             tfUser([tfImage]), say("Seen.")]).blocks
    }

    /// Red before: TranscriptVerbosity.turns() starts a turn only at isPrompt, and an image-only
    /// user line decodes to a lone `.image` block, so it folded into the previous turn.
    func testTranscriptFollowupAnImageOnlyPromptStartsATurn() {
        let blocks = tfImageOnlyBlocks()
        XCTAssertEqual(blocks.map(kind), ["user", "bash", "assistant", "user", "image", "assistant"])
        XCTAssertEqual(TranscriptVerbosity.turns(blocks).map(\.count), [3, 3])
    }

    func testTranscriptFollowupAnImageOnlyPromptStartsATurnAtEveryLevel() {
        let blocks = tfImageOnlyBlocks()
        for level in [AgentVerbosity.focused, .default, .verbose] {
            let t = tags(TranscriptVerbosity.project(blocks, level: level))
            XCTAssertEqual(t.filter { $0 == "block:user" }.count, 2, "\(level): \(t)")
            XCTAssertTrue(t.contains("block:image"), "\(level): \(t)")
        }
        let focused = tags(TranscriptVerbosity.project(blocks, level: .focused))
        XCTAssertEqual(Array(focused.prefix(3)), ["block:user", "summary:1/0/0:0", "block:assistant"],
                       "the first turn's steps are not mixed with the image turn: \(focused)")
    }

    /// Pins: an image inside a prompt with text, and a pasted image after a prompt, stay in the one turn
    /// and get no extra card.
    func testTranscriptFollowupAnImageWithTextOrAfterAPromptKeepsItsTurn() {
        let withText = asm([tfPrompt("go"), say("a"), tfUser([["type": "text", "text": "look"], tfImage]), say("b")]).blocks
        XCTAssertEqual(withText.map(kind), ["user", "assistant", "user", "image", "assistant"])
        XCTAssertEqual(TranscriptVerbosity.turns(withText).map(\.count), [2, 3])
        let pasted = asm([tfPrompt("go"), tfUser([tfImage]), say("b")]).blocks
        XCTAssertEqual(pasted.map(kind), ["user", "image", "assistant"], "no extra card after a lead")
        XCTAssertEqual(TranscriptVerbosity.turns(pasted).map(\.count), [3])
    }

    /// Pins: an image beside a tool result, and a tool result that holds an image inside, never
    /// start a turn (the first has a result in its entry, the second decodes to no image block).
    func testTranscriptFollowupAToolResultWithAnImageDoesNotStartATurn() {
        let beside = asm([tfPrompt("go"), toolUse("b", "Bash", ["command": "ls"]),
                          tfUser([["type": "tool_result", "tool_use_id": "b", "content": "f"], tfImage]), say("b")]).blocks
        XCTAssertEqual(beside.map(kind), ["user", "bash", "image", "assistant"])
        XCTAssertEqual(TranscriptVerbosity.turns(beside).map(\.count), [4])
        let inside = asm([tfPrompt("go"), toolUse("b", "Bash", ["command": "ls"]),
                          tfUser([["type": "tool_result", "tool_use_id": "b", "content": [tfImage]]]), say("b")]).blocks
        XCTAssertEqual(inside.map(kind), ["user", "bash", "assistant"])
        XCTAssertEqual(TranscriptVerbosity.turns(inside).map(\.count), [3])
    }

    // MARK: step C, R1269-a: the "[image]" card on a page loaded later

    private func tfImageLed() -> TranscriptAssembler { asm([tfUser([tfImage]), say("Seen.")]) }

    private func tfCard(_ b: TranscriptBlock?) -> Bool {
        if case .user(let c)? = b?.body { c.text == "[image]" } else { false }
    }

    /// Red before: prepend() added no card, so the image-only first line folded into the page's turn (one turn of 5).
    func testTranscriptFollowupAPageLoadedLaterGivesTheImageItsCard() {
        var live = tfImageLed()
        live.prepend(asm([tfPrompt("go"), toolUse("b", "Bash", ["command": "ls"]), toolResult("b", "f"), say("Done.")]))
        XCTAssertEqual(live.blocks.map(kind), ["user", "bash", "assistant", "user", "image", "assistant"])
        XCTAssertEqual(live.blocks.map(\.id), [-4, -3, -2, -1, 0, 1], "the page ends one lower; the card is just below the floor")
        XCTAssertTrue(tfCard(live.blocks.first { $0.id == -1 }))
        XCTAssertEqual(TranscriptVerbosity.turns(live.blocks).map(\.count), [3, 3])
    }

    /// Pins: a page whose last block is a prompt (no step) inserts nothing; ids as before.
    func testTranscriptFollowupAPageEndingInAPromptAddsNoCard() {
        var live = tfImageLed()
        live.prepend(asm([tfPrompt("look")]))
        XCTAssertEqual(live.blocks.map(kind), ["user", "image", "assistant"])
        XCTAssertEqual(live.blocks.map(\.id), [-1, 0, 1])
        XCTAssertEqual(TranscriptVerbosity.turns(live.blocks).map(\.count), [3])
    }

    /// Two prepends in a row: each image-only first line gets its card once a step is above it; ids unique, in order.
    /// Red before: no card on either prepend ([-4, -3, -2, -1, 0, 1]).
    func testTranscriptFollowupTwoPrependsKeepIdsUniqueAndOrdered() {
        var live = tfImageLed()
        live.prepend(asm([tfUser([tfImage]), say("a")]))
        XCTAssertEqual(live.blocks.map(\.id), [-3, -2, -1, 0, 1])
        live.prepend(asm([tfPrompt("go"), say("Done.")]))
        XCTAssertEqual(live.blocks.map(\.id), [-6, -5, -4, -3, -2, -1, 0, 1])
        XCTAssertEqual(live.blocks.map(kind), ["user", "assistant", "user", "image", "assistant", "user", "image", "assistant"])
        XCTAssertEqual(live.blocks.filter { tfCard($0) }.map(\.id), [-4, -1])
        XCTAssertEqual(TranscriptVerbosity.turns(live.blocks).map(\.count), [2, 3, 3])
    }

    /// Step A's carried open call keeps its shifted id with the card in: its live result closes it in place.
    /// Red before: no card (4 blocks, ids [-2, -1, 0, 1]).
    func testTranscriptFollowupACarriedCallKeepsItsShiftedIdWithTheCard() {
        var live = tfImageLed()
        live.prepend(asm([tfPrompt("go"), toolUse("t1", "Bash", ["command": "ls"])]))
        XCTAssertEqual(live.blocks.map(\.id), [-3, -2, -1, 0, 1])
        XCTAssertEqual(live.blocks.map(\.pending), [false, true, false, false, false])
        live.add(TranscriptDecoder.decode(line: line(toolResult("t1", "out"))), source: nil)
        XCTAssertEqual(live.blocks.map(\.id), [-3, -2, -1, 0, 1], "no orphan card: \(live.blocks.map(\.body))")
        XCTAssertEqual(live.blocks.map(\.pending), [false, false, false, false, false])
        XCTAssertTrue(live.orphans.isEmpty)
    }

    // MARK: step D, R1269-c-q1 and QA r1153 INFO: the dropped front

    /// Red before (trim() kept leadsWithImageOnly for the line it dropped): the prepend that removed the orphan card put a
    /// stray "[image]" card above "a", the line now first.
    func testTranscriptFollowupATrimmedImageLineLeavesNoCard() {
        var live = TranscriptAssembler()
        live.maxBlocks = 3
        for e in [tfUser([tfImage]), say("a"), toolResult("t1", "out"), say("b")] {
            live.add(TranscriptDecoder.decode(line: line(e)), source: nil)
        }
        XCTAssertEqual(live.dropped, 1, "the image line was trimmed")
        live.prepend(asm([tfPrompt("go"), toolUse("t1", "Bash", ["command": "ls"])]))
        XCTAssertEqual(live.blocks.map(kind), ["user", "bash", "assistant", "assistant"], "the orphan card was removed, no card added")
        XCTAssertFalse(live.blocks.contains { tfCard($0) })
    }

    /// Red before (atHistoryCap read the count alone): with a block dropped for the bound and the count under it again
    /// (here: the bound raised by one), Load earlier joined a page above the hole and the dropped blocks were gone unmarked.
    @MainActor
    func testTranscriptFollowupNoPageIsJoinedAboveADroppedBlock() throws {
        let url = tempDir().appendingPathComponent("hole.jsonl")
        try write(url, (0..<200).map { say("message \($0) " + String(repeating: "x", count: 40)) })
        let m = AgentTranscriptModel()
        m.offMain = { $0() }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.pageBytes = 4096
        m.maxBlocks = 5
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "s", transcriptPath: url.path))
        m.start()
        defer { m.stop() }
        m.maxBlocks = 6
        XCTAssertEqual(m.blocks.count, 5, "under the bound again")
        XCTAssertTrue(m.olderAvailable)
        XCTAssertTrue(m.atHistoryCap, "a block was dropped: older history is in the terminal")
        let before = m.blocks.map(\.id)
        m.loadEarlier()
        XCTAssertEqual(m.blocks.map(\.id), before)
    }
}

