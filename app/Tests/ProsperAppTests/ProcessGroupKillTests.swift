import XCTest
@testable import ProsperApp

/// #290: BunHarness tears its plugin host down with `CodexHarness.killGroup`, so a
/// SIGTERM-ignoring child the host spawned dies with it. No bun mock exists; this pins
/// the shared helper on a `/bin/sh` stand-in that is its own group leader, as the host is.
final class ProcessGroupKillTests: XCTestCase {
    func testKillGroupTakesDownASigtermIgnoringChild() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The leader and its child both ignore SIGTERM: only the group SIGKILL ends them.
        proc.arguments = ["-c", #"trap "" TERM; sleep 600 & echo $!; wait"#]
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        let child = try XCTUnwrap(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        let leader = proc.processIdentifier
        XCTAssertEqual(getpgid(leader), leader, "Process must spawn the child as its own group leader")
        XCTAssertEqual(getpgid(child), leader)

        CodexHarness.killGroup(leader)
        let deadline = Date().addingTimeInterval(8)   // 3 s grace + SIGKILL + reap
        while kill(child, 0) == 0, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if kill(child, 0) == 0 {
            kill(-leader, SIGKILL)   // don't leak it past a failing test
            XCTFail("the SIGTERM-ignoring child \(child) outlived killGroup")
        }
        proc.waitUntilExit()
    }
}
