import XCTest

@testable import ProsperApp

/// File-inbox transport behind the `prosper agent <prompt>` CLI: jobs round-trip
/// in submit order, the inbox is emptied by a drain, and junk files are discarded
/// instead of being re-read forever.
final class AgentCLIInboxTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-inbox-test-\(UUID().uuidString)", isDirectory: true)
        AgentCLI.inboxOverride = dir
    }

    override func tearDownWithError() throws {
        AgentCLI.inboxOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTripPreservesOrderAndDrains() throws {
        try AgentCLI.enqueue(.init(prompt: "first", cwd: "/tmp"))
        try AgentCLI.enqueue(.init(prompt: "second", cwd: nil))
        try AgentCLI.enqueue(.init(prompt: "third", cwd: nil))

        let jobs = AgentCLI.takeInbox()
        XCTAssertEqual(jobs.map(\.prompt), ["first", "second", "third"])
        XCTAssertEqual(jobs[0].cwd, "/tmp")

        XCTAssertTrue(AgentCLI.takeInbox().isEmpty, "drain must empty the inbox")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(left.isEmpty, "no files may remain after a drain: \(left)")
    }

    func testJunkAndEmptyPromptFilesAreDiscarded() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("000-junk.json"))
        try AgentCLI.enqueue(.init(prompt: "  ", cwd: nil))   // whitespace-only
        try AgentCLI.enqueue(.init(prompt: "real", cwd: nil))

        let jobs = AgentCLI.takeInbox()
        XCTAssertEqual(jobs.map(\.prompt), ["real"])
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(left.isEmpty, "junk files must be deleted, not retried: \(left)")
    }

    func testEmptyInboxIsEmpty() {
        XCTAssertTrue(AgentCLI.takeInbox().isEmpty)
    }
}
