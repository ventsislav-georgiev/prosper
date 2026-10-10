import XCTest
import os
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
        XCTAssertEqual(getpgid(leader), leader)
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
        XCTAssertEqual(getpgid(leader), leader)
        XCTAssertTrue(CodexHarness.mayKillGroup(leader))
    }

    /// Swaps `CodexHarness.sendSignal` for a recorder that never forwards: every probe
    /// answers -1 (group gone), so escalate stops at once and nothing real is signalled.
    private func recordingSignals(_ body: () -> Void) -> [(pid: pid_t, sig: Int32)] {
        let log = OSAllocatedUnfairLock(initialState: [(pid: pid_t, sig: Int32)]())
        let saved = CodexHarness.sendSignal
        CodexHarness.sendSignal = { pid, sig in log.withLock { $0.append((pid, sig)) }; return -1 }
        defer { CodexHarness.sendSignal = saved }
        body()
        return log.withLock { $0 }
    }

    /// killGroup gates on mayKillGroup before its first signal: a rejected pgid sends
    /// nothing, an accepted one leads with SIGTERM to the group (#361).
    func testKillGroupSendsNothingForRejectedPgidsAndSigtermFirstOtherwise() {
        let rejected: [pid_t] = [1, getpgrp()]
        let sent = recordingSignals {
            for pgid in rejected { CodexHarness.killGroup(pgid, grace: 0.1, blocking: true) }
        }
        // Filter: a detached escalate from an earlier test may land in the window.
        XCTAssertEqual(sent.filter { rejected.contains(-$0.pid) }.map(\.sig), [], "signalled a rejected pgid")

        let accepted = recordingSignals { CodexHarness.killGroup(424242, grace: 0.1, blocking: true) }
            .filter { $0.pid == -424242 }
        XCTAssertEqual(accepted.first?.sig, SIGTERM)
        XCTAssertFalse(accepted.contains { $0.sig == SIGKILL }, "probe said gone; no SIGKILL")
    }

    /// The quit path's registry: everything registered gets a group SIGTERM and the
    /// registry is drained (#361).
    func testKillLiveGroupsBlockingSignalsAndDrainsTheRegistry() {
        CodexHarness.livePGIDs.withLock { _ = $0.insert(424242) }
        let sent = recordingSignals { CodexHarness.killLiveGroupsBlocking(grace: 0.1) }
        XCTAssertTrue(sent.contains { $0.pid == -424242 && $0.sig == SIGTERM }, "\(sent)")
        XCTAssertTrue(CodexHarness.livePGIDs.withLock { $0.isEmpty })
    }

    /// The registry tracks a real start/shutdown: a silent stand-in codex (never answers
    /// `initialize`) is registered once spawned and gone from the registry after shutdown.
    func testStartRegistersTheCodexGroupAndShutdownUnregistersIt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-tests/pgkill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("codex"), pidFile = dir.appendingPathComponent("pid")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 600\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let harness = CodexHarness(executableURL: exe, codexHome: dir.appendingPathComponent("home"),
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "t")
        let starting = Task { try await harness.start() }
        let deadline = Date().addingTimeInterval(5)
        var pid: pid_t?
        func registered() -> Bool { pid.map { p in CodexHarness.livePGIDs.withLock { $0.contains(p) } } ?? false }
        while !registered(), Date() < deadline {   // the child may write its pid before run() returns
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if !registered() { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let leader = try XCTUnwrap(pid, "stand-in codex never started")
        defer { kill(-leader, SIGKILL) }   // no leak if an assert below throws
        XCTAssertEqual(getpgid(leader), leader)
        XCTAssertTrue(CodexHarness.livePGIDs.withLock { $0.contains(leader) }, "start did not register the group")

        await harness.shutdown()
        _ = try? await starting.value
        XCTAssertFalse(CodexHarness.livePGIDs.withLock { $0.contains(leader) }, "shutdown left the group registered")
    }

    /// A scan by necessity: applicationWillTerminate can't run in a test (it needs a
    /// launched Prosper). Pins the codex teardown before the atexit `_exit` shortcut.
    func testApplicationWillTerminateKillsCodexGroupsBeforeAtexit() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/AppDelegate.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func applicationWillTerminate("))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        let call = try XCTUnwrap(body.range(of: "CodexHarness.killLiveGroupsBlocking("), "quit path never kills codex")
        let exit = try XCTUnwrap(body.range(of: "atexit { _exit"))
        XCTAssertLessThan(call.lowerBound, exit.lowerBound, "codex teardown must run before atexit { _exit(0) }")
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
        XCTAssertEqual(getpgid(leader), leader)

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
