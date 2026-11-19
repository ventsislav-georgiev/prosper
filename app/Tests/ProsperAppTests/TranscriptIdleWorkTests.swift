import Combine
import XCTest
@testable import ProsperApp

/// #1632 (perf audit): an open transcript pane whose file is quiet does no SwiftUI work per tick, and the Agents window's
/// timers carry a tolerance so macOS can coalesce their wakeups. Rows count publishes and sends, never time.
@MainActor
final class TranscriptIdleWorkTests: XCTestCase {
    func testAQuietTickPublishesNothingAndNewLinesPublishOnce() throws {
        let url = tempDir().appendingPathComponent("idle.jsonl")
        try JumpFixture.write(url, JumpFixture.turns(2))
        let m = JumpFixture.model(url)
        defer { m.stop() }
        XCTAssertEqual(m.blocks.count, 6)
        let p0 = m.publishes
        var sends = 0
        let sub = m.objectWillChange.sink { sends += 1 }
        defer { sub.cancel() }
        for _ in 0..<5 { m.tick() }
        XCTAssertEqual(m.publishes, p0, "five quiet ticks: no publish")
        XCTAssertEqual(sends, 0, "five quiet ticks: nothing sent to SwiftUI")
        XCTAssertEqual(m.mode, .conversation)
        try JumpFixture.append(url, JumpFixture.turns(1, from: 2))
        m.tick()
        XCTAssertEqual(m.publishes, p0 + 1, "new lines: one publish")
        XCTAssertEqual(m.blocks.count, 9)
        XCTAssertGreaterThan(sends, 0)
    }

    /// Supervisor add-on (QA's read of #1632): the idle branch of finishPoll still re-checks the mode. A tick that finds
    /// the file gone reads no lines: the mode turns to the missing one, with no publish. Red under mutant idle-else-empty.
    func testAMissingFileTickChangesTheModeWithoutAPublish() throws {
        let url = tempDir().appendingPathComponent("gone.jsonl")
        try JumpFixture.write(url, JumpFixture.turns(1))
        let m = JumpFixture.model(url)
        defer { m.stop() }
        XCTAssertEqual(m.mode, .conversation)
        let p0 = m.publishes
        try FileManager.default.removeItem(at: url)
        m.tick()
        let missing = AgentTranscriptModel.mode(source: m.source, hasView: true, nullSince: nil, missing: true,
                                                live: TierCounts(), lastGrowth: nil, toolPending: false, now: Date())
        XCTAssertNotEqual(missing, .conversation)
        XCTAssertEqual(m.mode, missing)
        XCTAssertEqual(m.publishes, p0, "a missing file: no lines, no publish")
    }

    /// #1633: the outline is kept in the assembler between polls; a reopen (a shorter file) starts a fresh one and the
    /// memory bound's front drop re-folds the cut turn. Both equal a full build. Red under mutants keep-outline-on-reopen
    /// and drop-skips-cut-turn.
    func testAReopenAndAFrontDropGiveTheFullBuild() throws {
        let url = tempDir().appendingPathComponent("reopen.jsonl")
        try JumpFixture.write(url, JumpFixture.turns(5))
        let m = JumpFixture.model(url)
        defer { m.stop() }
        XCTAssertEqual(m.chapters.count, 5)
        XCTAssertEqual(m.chapters, TranscriptOutline.chapters(m.blocks))
        m.maxBlocks = 10
        try JumpFixture.write(url, JumpFixture.turns(1, from: 7))   // shorter: the tail reopens on a fresh assembler
        m.tick()
        XCTAssertEqual(m.chapters.map(\.title), ["Prompt 7"])
        XCTAssertEqual(m.chapters, TranscriptOutline.chapters(m.blocks))
        try JumpFixture.append(url, JumpFixture.turns(2, from: 8))   // 9 blocks, three turns
        m.tick()
        XCTAssertEqual(m.chapters.count, 3)
        try JumpFixture.append(url, JumpFixture.turns(1, from: 10))   // 12 blocks: two drop, the first turn is cut
        m.tick()
        XCTAssertEqual(m.blocks.count, 10)
        XCTAssertEqual(m.chapters.first?.kind, .partial, "the cut turn's rest")
        XCTAssertEqual(m.chapters.first?.ordinal, 1)
        XCTAssertEqual(m.chapters, TranscriptOutline.chapters(m.blocks))
    }

    /// #1633: a failed result landing a poll after its call marks the call's block changed, so the kept outline shows
    /// the error. Red under mutant result-not-touched.
    func testALateFailedResultMarksTheChapter() throws {
        let url = tempDir().appendingPathComponent("late.jsonl")
        let call = JumpFixture.entry("assistant", ["message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": "c9", "name": "Bash", "input": ["command": "make test"]]]]])
        try JumpFixture.write(url, JumpFixture.turns(2) + [JumpFixture.user("Run the tests"), call])
        let m = JumpFixture.model(url)
        defer { m.stop() }
        XCTAssertTrue(m.chapters.last?.hasError == false)
        try JumpFixture.append(url, [JumpFixture.entry("user", ["message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "c9", "content": "1 failed", "is_error": true]]]])])
        m.tick()
        XCTAssertTrue(m.chapters.last?.hasError == true)
        XCTAssertEqual(m.chapters, TranscriptOutline.chapters(m.blocks))
    }

    func testTheTranscriptTickAndTheAgeClockHaveATolerance() throws {
        let url = tempDir().appendingPathComponent("tol.jsonl")
        try JumpFixture.write(url, JumpFixture.turns(1))
        let m = JumpFixture.model(url)   // tickInterval 3600
        defer { m.stop() }
        XCTAssertEqual(m.timer?.tolerance ?? 0, 1800, accuracy: 0.001)
        let clock = AgentWindowModel.makeAgeClock(30) {}
        defer { clock.invalidate() }
        XCTAssertEqual(clock.tolerance, 3, accuracy: 0.001)
    }
}

/// #1637: the remaining one-shot timers have a 10 % tolerance; each is built unarmed so no wall clock is needed.
@MainActor
final class OneShotTimerToleranceTests: XCTestCase {
    func testTheIdleUnloadTimerHasATolerance() {
        let t = ModelIdleUnloader.makeTimer(120) {}
        XCTAssertEqual(t.tolerance, 12, accuracy: 0.001)
    }

    func testTheSpawnDeadlineTimerHasATolerance() {
        let t = AgentWindowModel.makeSpawnDeadline(15.5) { _ in }
        XCTAssertEqual(t.tolerance, 1.55, accuracy: 0.001)
    }

    func testTheRehideTimerHasATolerance() {
        let t = MenuBarManager.makeRehideTimer(10) {}
        XCTAssertEqual(t.tolerance, 1, accuracy: 0.001)
    }
}
