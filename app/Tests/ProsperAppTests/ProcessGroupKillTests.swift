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

    /// Polls `kill(pid, 0)` every 10 ms until ESRCH or the timeout. The group probe in
    /// escalate skips zombies, so killGroup can return before launchd reaps an orphan,
    /// and `kill(pid, 0)` on a not-yet-reaped zombie still answers 0 (#375).
    private func waitGone(_ pid: pid_t, timeout: TimeInterval = 1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            if Date() >= deadline { return false }
            usleep(10_000)
        }
    }

    /// Fake pgid for the recorder rows: above PID_MAX (99999 on macOS), so no real group
    /// can ever carry it, whatever the state of the `sendSignal` seam (a detached escalate
    /// outliving the swap, or a row failing before the defer restores it) (#375).
    private static let fakePGID: pid_t = 424242

    private let ignoringTerm = #"trap "" TERM; sleep 600 & echo $!; wait"#

    func testKillGroupTakesDownASigtermIgnoringChild() async throws {
        let (proc, leader, child) = try spawnGroup(ignoringTerm)
        defer { kill(-leader, SIGKILL); proc.waitUntilExit() }   // no leak if an assert below throws
        XCTAssertEqual(getpgid(leader), leader, "Process must spawn the child as its own group leader")
        XCTAssertEqual(getpgid(child), leader)

        CodexHarness.killGroup(leader)
        if !waitGone(child, timeout: 8) {   // 3 s grace + SIGKILL + reap
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
        XCTAssertTrue(waitGone(child), "the SIGTERM-ignoring child \(child) outlived blocking killGroup")
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
        XCTAssertGreaterThan(Self.fakePGID, 99_999, "fake pgids must exceed PID_MAX so a real signal can never land")
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

        let accepted = recordingSignals { CodexHarness.killGroup(Self.fakePGID, grace: 0.1, blocking: true) }
            .filter { $0.pid == -Self.fakePGID }
        XCTAssertEqual(accepted.first?.sig, SIGTERM)
        XCTAssertFalse(accepted.contains { $0.sig == SIGKILL }, "probe said gone; no SIGKILL")
    }

    /// The quit path's registry: everything registered gets a group SIGTERM and the
    /// registry is drained (#361).
    func testKillLiveGroupsBlockingSignalsAndDrainsTheRegistry() {
        CodexHarness.livePGIDs.withLock { _ = $0.insert(Self.fakePGID) }
        let sent = recordingSignals { CodexHarness.killLiveGroupsBlocking(grace: 0.1) }
        XCTAssertTrue(sent.contains { $0.pid == -Self.fakePGID && $0.sig == SIGTERM }, "\(sent)")
        XCTAssertTrue(CodexHarness.livePGIDs.withLock { $0.isEmpty })
    }

    /// Polls the registry until `pgid` leaves it or the timeout: escalate unregisters a
    /// group at its end, off the caller's thread (#377).
    private func waitUnregistered(_ pgid: pid_t, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while CodexHarness.livePGIDs.withLock({ $0.contains(pgid) }) {
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// The registry tracks a real start/shutdown: a silent stand-in codex (never answers
    /// `initialize`) is registered once spawned and gone from the registry once shutdown's
    /// escalate ends.
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
        let gone = try await waitUnregistered(leader, timeout: 5)
        XCTAssertTrue(gone, "shutdown left the group registered")
    }

    /// #377: a codex that exits on its own leaves a SIGTERM-ignoring child; the group stays
    /// registered through handleTermination's 3 s grace (so a quit then still kills it
    /// inline) and leaves the registry once the escalate has SIGKILLed the child.
    func testHandleTerminationKeepsTheGroupRegisteredUntilEscalateEnds() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-tests/pgkill-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("codex")
        let pidFile = dir.appendingPathComponent("pid"), childFile = dir.appendingPathComponent("child")
        try """
            #!/bin/sh
            trap "" TERM
            /bin/sleep 600 &
            echo $! > '\(childFile.path)'
            echo $$ > '\(pidFile.path)'
            /bin/sleep 0.3
            """.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let harness = CodexHarness(executableURL: exe, codexHome: dir.appendingPathComponent("home"),
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "t")
        // The exit fails the pending initialize, so start returns once handleTermination ran.
        do { try await harness.start(); XCTFail("start succeeded against an exiting stand-in") } catch {}
        func readPid(_ url: URL) -> pid_t? {
            (try? String(contentsOf: url, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let leader = try XCTUnwrap(readPid(pidFile), "stand-in codex never started")
        let child = try XCTUnwrap(readPid(childFile), "stand-in codex never forked its child")
        defer { kill(child, SIGKILL) }   // by pid: the row reaps its stand-in child even when an assert throws

        XCTAssertEqual(kill(child, 0), 0, "the SIGTERM-ignoring child died before the grace ended")
        XCTAssertTrue(CodexHarness.livePGIDs.withLock { $0.contains(leader) },
                      "handleTermination unregistered the group before its escalate ended")
        XCTAssertTrue(waitGone(child, timeout: 8), "the SIGTERM-ignoring child \(child) outlived handleTermination")
        let gone = try await waitUnregistered(leader, timeout: 2)
        XCTAssertTrue(gone, "the group stayed registered after its escalate ended")
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
        XCTAssertTrue(waitGone(child), "the host's SIGTERM-ignoring child \(child) outlived stopHost")
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

        XCTAssertTrue(waitGone(child, timeout: 5), "the host's child \(child) outlived the host")
        withExtendedLifetime(harness) {}
    }
}
