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
