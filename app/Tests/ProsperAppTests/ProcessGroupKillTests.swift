import XCTest
@testable import ProsperApp

/// #290: BunHarness tears its plugin host down with `CodexHarness.killGroup`, so a
/// SIGTERM-ignoring grandchild must still go. #327: the blocking quit-path variant,
/// the guard predicate, and BunHarness's two call sites.
final class ProcessGroupKillTests: XCTestCase {
    /// A /bin/sh group leader that backgrounds `sleep 600` and prints its pid.
    private func spawnGroup(_ script: String) throws -> (proc: Process, leader: pid_t, child: pid_t) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        let leader = proc.processIdentifier
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        guard let child = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            kill(-leader, SIGKILL)
            throw XCTSkip("no child pid from the stand-in: \(line)")
        }
        return (proc, leader, child)
    }

    private let ignoringTerm = #"trap "" TERM; sleep 600 & echo $!; wait"#

    func testKillGroupTakesDownASigtermIgnoringChild() async throws {
        let (proc, leader, child) = try spawnGroup(ignoringTerm)
        defer { kill(-leader, SIGKILL); proc.waitUntilExit() }   // no leak if an assert below throws
        XCTAssertEqual(getpgid(leader), leader, "Process must spawn the child as its own group leader")
        XCTAssertEqual(getpgid(child), leader)

        CodexHarness.killGroup(leader)
        let deadline = Date().addingTimeInterval(8)   // 3 s grace + SIGKILL + reap
        while kill(child, 0) == 0, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if kill(child, 0) == 0 {
            kill(-leader, SIGKILL)   // don't leak it past a failing test
            XCTFail("the SIGTERM-ignoring child \(child) outlived killGroup")
        }
    }

    /// The quit path: SIGKILL has landed by the time the call returns, within grace + 1 s.
    func testBlockingKillGroupReturnsWithTheGroupGone() throws {
        let (proc, leader, child) = try spawnGroup(ignoringTerm)
        defer { kill(-leader, SIGKILL); proc.waitUntilExit() }
        let done = expectation(description: "blocking killGroup returned")
        DispatchQueue.global().async {   // off-thread so a never-ending wait fails instead of hanging
            CodexHarness.killGroup(leader, grace: 1, blocking: true)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertNotEqual(kill(child, 0), 0, "the SIGTERM-ignoring child \(child) outlived blocking killGroup")
    }

    /// The guard as a pure predicate: never call killGroup with these, a regressed guard
    /// would signal the whole login session or the xctest tree (#327).
    func testMayKillGroupRefusesOursAndTheSpecialPgids() throws {
        for pgid in [0, 1, -1, getpgrp()] as [pid_t] {
            XCTAssertFalse(CodexHarness.mayKillGroup(pgid), "pgid \(pgid)")
        }
        let (proc, leader, _) = try spawnGroup("sleep 600 & echo $!; wait")
        defer { kill(-leader, SIGKILL); proc.waitUntilExit() }
        XCTAssertTrue(CodexHarness.mayKillGroup(leader))

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Harness/CodexHarness.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "static func killGroup("))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        XCTAssertTrue(source[start.lowerBound..<end.lowerBound].contains("guard mayKillGroup(pgid)"),
                      "killGroup must gate on mayKillGroup before signalling")
    }

    /// BunHarness.stopHost (the process half of shutdown, minus the socket unlink) leaves
    /// no live group behind when it returns.
    @MainActor func testBunHarnessStopHostKillsTheHostGroup() throws {
        let harness = BunHarness()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", ignoringTerm]
        let out = Pipe()
        proc.standardOutput = out
        try harness.launch(proc)
        let leader = proc.processIdentifier
        defer { kill(-leader, SIGKILL); proc.waitUntilExit() }
        let child = try XCTUnwrap(pid_t(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))

        harness.stopHost()
        XCTAssertNotEqual(kill(child, 0), 0, "the host's SIGTERM-ignoring child \(child) outlived stopHost")
    }

    /// A host that exits on its own: the terminationHandler takes its children down.
    @MainActor func testBunHarnessHostExitKillsItsChildren() async throws {
        let harness = BunHarness()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 600 & echo $!; sleep 0.3"]
        let out = Pipe()
        proc.standardOutput = out
        try harness.launch(proc)
        let leader = proc.processIdentifier
        defer { kill(-leader, SIGKILL) }
        let child = try XCTUnwrap(pid_t(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))

        let deadline = Date().addingTimeInterval(5)
        while kill(child, 0) == 0, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNotEqual(kill(child, 0), 0, "the host's child \(child) outlived the host")
        withExtendedLifetime(harness) {}
    }
}
