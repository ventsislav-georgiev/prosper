import Foundation
import XCTest
@testable import ProsperApp

/// #1723: the "Install pv Command" control and the pv script. No row builds `AdminPromptShell`, runs osascript
/// or the real `open`, or touches /usr/local/bin: the commands run unprivileged against a tempDir() target,
/// and the script runs under /bin/sh and /bin/dash with a fake `open` first on PATH.
@MainActor
final class PVCommandTests: XCTestCase {

    /// Runs each command with /bin/sh as the current user and records it.
    private final class LocalShell: PrivilegedShell, @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [String] = []
        var commands: [String] { lock.withLock { _commands } }

        func run(_ command: String) async -> String? {
            lock.withLock { _commands.append(command) }
            let r = PVCommandTests.exec("/bin/sh", ["-c", command])
            return r.status == 0 ? nil : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Sets the recording shell for one row and clears it at teardown.
    private func useShell() -> LocalShell {
        let shell = LocalShell()
        PVCommand.shell = shell
        addTeardownBlock { @MainActor in PVCommand.shell = nil }
        return shell
    }

    nonisolated static func exec(_ path: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil,
                                 stdin: String? = nil) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input
        do { try p.run() } catch { return (-1, "", "\(error)") }
        input.fileHandleForWriting.write(Data((stdin ?? "").utf8)) // small: fits the pipe buffer
        try? input.fileHandleForWriting.close()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, o, e)
    }

    private static let app = "/Applications/Pro sper's.app"

    /// The script under both shells: spaces and a quote in the app path and in a file name, a relative path
    /// resolved against the working dir, an absolute one kept, a name starting with a dash, and `-` saved to a .txt.
    func testScriptOpensEachPathUnderShAndDash() throws {
        let dir = tempDir()
        let fakeBin = dir.appendingPathComponent("fake bin"), cwd = dir.appendingPathComponent("work dir")
        let tmp = dir.appendingPathComponent("tmp"), log = dir.appendingPathComponent("open.log")
        for d in [fakeBin, cwd, tmp] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let open = fakeBin.appendingPathComponent("open")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\" >> \"$PV_LOG\"; done; echo >> \"$PV_LOG\"\n"
            .write(to: open, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        let script = dir.appendingPathComponent("pv")
        try PVCommand.script(appPath: Self.app).write(to: script, atomically: true, encoding: .utf8)

        for sh in ["/bin/sh", "/bin/dash"] {
            try? FileManager.default.removeItem(at: log)
            let env = ["PATH": "\(fakeBin.path):/usr/bin:/bin", "TMPDIR": tmp.path, "PV_LOG": log.path]
            let r = Self.exec(sh, [script.path, "a b.txt", "/abs/x.md", "-", "-it's.md"], cwd: cwd, env: env, stdin: "hello\n")
            XCTAssertEqual(r.status, 0, "\(sh): \(r.err)")
            let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, 4, sh)
            let a = "[-a][\(Self.app)]"
            XCTAssertEqual(lines.first, "\(a)[\(cwd.path)/a b.txt]", sh)
            XCTAssertTrue(lines.contains("\(a)[/abs/x.md]"), sh)
            XCTAssertEqual(lines.last, "\(a)[\(cwd.path)/-it's.md]", sh)
            let piped = try XCTUnwrap(lines.first { $0.hasPrefix("\(a)[\(tmp.path)/pv.") }, sh)
            let path = String(piped.dropFirst(a.count + 1).dropLast())
            XCTAssertTrue(path.hasSuffix("/stdin.txt"), sh)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "hello\n", sh)

            try? FileManager.default.removeItem(at: log)
            let bare = Self.exec(sh, [script.path], cwd: cwd, env: env)
            XCTAssertEqual(bare.status, 2, sh)
            XCTAssertTrue(bare.err.contains("usage: pv FILE..."), sh)
            XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "\(sh): no args must not run open")
        }
    }

    /// Install creates the missing dir and writes our script 755; Uninstall removes it. One command each.
    func testInstallThenUninstall() async throws {
        let shell = useShell()
        let target = tempDir().appendingPathComponent("bin dir/pv")
        let model = PVCommand(target: target, appURL: URL(fileURLWithPath: Self.app), scratch: tempDir())
        await model.refresh()
        XCTAssertEqual(model.state, .missing)

        await model.install()
        XCTAssertTrue(model.error == nil, model.error ?? "")
        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), model.script)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)

        await model.uninstall()
        XCTAssertEqual(model.state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(shell.commands.count, 2)
        XCTAssertFalse(shell.commands.contains { $0.contains("/usr/local/bin") })
        XCTAssertFalse(model.busy)
    }

    /// A pv we did not write (a file or a link) is never replaced or removed, and the reason is shown.
    func testRefusesAnotherPv() async throws {
        _ = useShell()
        let dir = tempDir()
        let file = dir.appendingPathComponent("pv"), other = "#!/bin/sh\necho pipe viewer\n"
        try other.write(to: file, atomically: true, encoding: .utf8)
        let model = PVCommand(target: file, appURL: URL(fileURLWithPath: Self.app), scratch: dir)
        await model.refresh()
        XCTAssertEqual(model.state, .other)
        await model.install()
        XCTAssertTrue(model.error?.contains("Another pv is at \(file.path)") == true, model.error ?? "nil")
        await model.uninstall()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), other)
        XCTAssertEqual(model.state, .other)

        // A link, even to our own script, is someone else's: install must not write through it.
        let ours = dir.appendingPathComponent("ours")
        try model.script.write(to: ours, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("pvlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ours)
        let linked = PVCommand(target: link, appURL: URL(fileURLWithPath: "/elsewhere/Prosper.app"), scratch: dir)
        await linked.refresh()
        XCTAssertEqual(linked.state, .other)
        await linked.install()
        await linked.uninstall()
        XCTAssertEqual(try String(contentsOf: ours, encoding: .utf8), model.script)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), ours.path)
    }

    /// Our script for another app path is ours: shown as outdated, and Install replaces it.
    func testOutdatedOwnScriptIsReplaced() async throws {
        _ = useShell()
        let target = tempDir().appendingPathComponent("pv")
        try PVCommand.script(appPath: "/Volumes/Old/Prosper.app").write(to: target, atomically: true, encoding: .utf8)
        let model = PVCommand(target: target, appURL: URL(fileURLWithPath: Self.app), scratch: tempDir())
        await model.refresh()
        XCTAssertEqual(model.state, .outdated)
        await model.install()
        XCTAssertEqual(model.state, .installed)
    }

    /// With no shell (the XCTest default) the buttons do nothing.
    func testNoShellRunsNothing() async {
        let shell = useShell()
        PVCommand.shell = nil
        let target = tempDir().appendingPathComponent("pv")
        let model = PVCommand(target: target, appURL: URL(fileURLWithPath: Self.app), scratch: tempDir())
        await model.install()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(shell.commands.isEmpty)
    }

    func testDefaultsAndAppleScriptQuoting() {
        XCTAssertEqual(PVCommand().target.path, "/usr/local/bin/pv")
        XCTAssertEqual(PVCommand.appleScript(#"echo "a\b""#),
                       #"do shell script "echo \"a\\b\"" with administrator privileges"#)
        XCTAssertEqual(PVCommand.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(PVCommandSection.status(.other, target: "/usr/local/bin/pv"),
                       "Another pv is at /usr/local/bin/pv. Prosper will not replace it.")
    }
}
