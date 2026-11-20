import Foundation
import XCTest
@testable import ProsperApp

/// #1723: the "Install prosper Command" control and its script (#1732: renamed from pv). No row builds
/// `AdminPromptShell`, runs osascript or the real `open`, or touches /usr/local/bin: the commands run unprivileged against a tempDir() target,
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

    private static let id = "eu.illegible.prosper"

    /// The script under both shells: #1732 opens by bundle id (`open -b`), a space and a quote in a file name,
    /// a relative path resolved against the working dir, an absolute one kept, a name starting with a dash,
    /// and `-` saved to a .txt.
    func testScriptOpensEachPathUnderShAndDash() throws {
        let dir = tempDir()
        let fakeBin = dir.appendingPathComponent("fake bin"), cwd = dir.appendingPathComponent("work dir")
        let tmp = dir.appendingPathComponent("tmp"), log = dir.appendingPathComponent("open.log")
        for d in [fakeBin, cwd, tmp] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let open = fakeBin.appendingPathComponent("open")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\" >> \"$PV_LOG\"; done; echo >> \"$PV_LOG\"\n"
            .write(to: open, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        let script = dir.appendingPathComponent("prosper")
        try PVCommand.script(bundleID: Self.id).write(to: script, atomically: true, encoding: .utf8)

        for sh in ["/bin/sh", "/bin/dash"] {
            try? FileManager.default.removeItem(at: log)
            let env = ["PATH": "\(fakeBin.path):/usr/bin:/bin", "TMPDIR": tmp.path, "PV_LOG": log.path]
            let r = Self.exec(sh, [script.path, "a b.txt", "/abs/x.md", "-", "-it's.md"], cwd: cwd, env: env, stdin: "hello\n")
            XCTAssertEqual(r.status, 0, "\(sh): \(r.err)")
            let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, 4, sh)
            let a = "[-b][\(Self.id)]"
            XCTAssertEqual(lines.first, "\(a)[\(cwd.path)/a b.txt]", sh)
            XCTAssertTrue(lines.contains("\(a)[/abs/x.md]"), sh)
            XCTAssertEqual(lines.last, "\(a)[\(cwd.path)/-it's.md]", sh)
            let piped = try XCTUnwrap(lines.first { $0.hasPrefix("\(a)[\(tmp.path)/prosper.") }, sh)
            let path = String(piped.dropFirst(a.count + 1).dropLast())
            XCTAssertTrue(path.hasSuffix("/stdin.txt"), sh)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "hello\n", sh)

            try? FileManager.default.removeItem(at: log)
            let bare = Self.exec(sh, [script.path], cwd: cwd, env: env)
            XCTAssertEqual(bare.status, 2, sh)
            XCTAssertTrue(bare.err.contains("usage: prosper FILE..."), sh)
            XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "\(sh): no args must not run open")
        }
    }

    /// Install creates the missing dir and writes our script 755; Uninstall removes it. One command each.
    func testInstallThenUninstall() async throws {
        let shell = useShell()
        let target = tempDir().appendingPathComponent("bin dir/prosper")
        let model = PVCommand(target: target, bundleID: Self.id)
        await model.refresh()
        XCTAssertEqual(model.state, .missing)

        await model.install()
        XCTAssertTrue(model.error == nil, model.error ?? "")
        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), model.script)
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
        // #1732: no temp dir is left behind and pv is never installed.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path),
                       ["prosper"])

        await model.uninstall()
        XCTAssertEqual(model.state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(shell.commands.count, 2)
        XCTAssertFalse(shell.commands.contains { $0.contains("/usr/local/bin") })
        XCTAssertFalse(model.busy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), [])
    }

    /// #1732 (QA n55): root reads no file a user can write. The script travels inside the command, through
    /// both quoting layers (sh single quotes, then the AppleScript string), and lands byte for byte, quote and
    /// backslash included. The command names no path but the target's dir and no cp writes onto the target.
    func testInstallCommandCarriesTheScriptAndRenamesOverTheTarget() async throws {
        let shell = useShell()
        let target = tempDir().appendingPathComponent("prosper")
        let model = PVCommand(target: target, bundleID: #"it's \ "odd""#)
        XCTAssertTrue(model.script.contains(#"'it'\''s \ "odd"'"#), model.script)
        await model.install()
        XCTAssertTrue(model.error == nil, model.error ?? "")
        XCTAssertEqual(try Data(contentsOf: target), Data(model.script.utf8))
        XCTAssertEqual(model.state, .installed)

        XCTAssertEqual(shell.commands.count, 1)
        let command = try XCTUnwrap(shell.commands.last)
        XCTAssertEqual(command.components(separatedBy: PVCommand.quote(model.script)).count, 2, "the script, once")
        let rest = command.replacingOccurrences(of: PVCommand.quote(model.script), with: "''")
        let dir = target.deletingLastPathComponent().path
        for path in ["TMPDIR", NSTemporaryDirectory(), FileManager.default.temporaryDirectory.path, "prosper-pv-"] {
            XCTAssertFalse(rest.replacingOccurrences(of: dir, with: "").contains(path), path)
        }
        // Every quoted path is in the target's dir (the unquoted ones are /bin and /usr/bin tools).
        let quoted = rest.components(separatedBy: "'").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        XCTAssertTrue(quoted.contains(dir), rest)
        for q in quoted where q.hasPrefix("/") { XCTAssertTrue(q.hasPrefix(dir), q) }
        XCTAssertFalse(rest.contains("/bin/cp"), rest)
        XCTAssertTrue(rest.contains(#"cd "$d" && [ -O . ] && "#), "a dir swapped in by name is refused as root")
        XCTAssertTrue(rest.contains("/usr/bin/mktemp -d \(PVCommand.quote(dir + "/.prosper.XXXXXX"))"), rest)
        XCTAssertTrue(rest.contains("/bin/mv -fh new \(PVCommand.quote(target.path));"), rest)
        // The target is named by the three refusal tests and the rename, nothing else.
        XCTAssertEqual(rest.components(separatedBy: PVCommand.quote(target.path)).count, 5, rest)

        // The AppleScript layer gives /bin/sh back the same command, so the same bytes land.
        let apple = PVCommand.appleScript(command)
        let head = "do shell script \"", tail = "\" with administrator privileges"
        XCTAssertTrue(apple.hasPrefix(head) && apple.hasSuffix(tail))
        var decoded = "", escaped = false
        for c in apple.dropFirst(head.count).dropLast(tail.count) {
            if escaped { decoded.append(c); escaped = false } else if c == "\\" { escaped = true } else {
                XCTAssertNotEqual(c, "\"", "an unescaped quote ends the AppleScript string early")
                decoded.append(c)
            }
        }
        XCTAssertEqual(decoded, command)
    }

    /// #1732: a link swapped in after the -L check is replaced by the rename, never written through. The tail
    /// of the real command (everything after the refusal) runs against a target that is a link to a scratch file.
    func testLinkSwappedInAfterTheCheckIsReplacedNotFollowed() throws {
        let dir = tempDir()
        let victim = dir.appendingPathComponent("victim"), target = dir.appendingPathComponent("bin/prosper")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "keep\n".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
        let script = PVCommand.script(bundleID: Self.id)
        let command = PVCommand.installCommand(script: script, target: target.path)
        let refusal = try XCTUnwrap(command.range(of: "exit 3; fi; "))
        let r = Self.exec("/bin/sh", ["-c", String(command[refusal.upperBound...])])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep\n")
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try Data(contentsOf: target), Data(script.utf8))
    }

    /// A command we did not write (a file or a link) is never replaced or removed, and the reason is shown.
    func testRefusesAnotherCommand() async throws {
        _ = useShell()
        let dir = tempDir()
        let file = dir.appendingPathComponent("prosper"), other = "#!/bin/sh\necho pipe viewer\n"
        try other.write(to: file, atomically: true, encoding: .utf8)
        let model = PVCommand(target: file, bundleID: Self.id)
        await model.refresh()
        XCTAssertEqual(model.state, .other)
        await model.install()
        XCTAssertTrue(model.error?.contains("Another command is at \(file.path)") == true, model.error ?? "nil")
        await model.uninstall()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), other)
        XCTAssertEqual(model.state, .other)

        // A link, even to our own script, is someone else's: install must not write through it.
        let ours = dir.appendingPathComponent("ours")
        try model.script.write(to: ours, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("prosperlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ours)
        let linked = PVCommand(target: link, bundleID: Self.id)
        await linked.refresh()
        XCTAssertEqual(linked.state, .other)
        await linked.install()
        await linked.uninstall()
        XCTAssertEqual(try String(contentsOf: ours, encoding: .utf8), model.script)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), ours.path)
    }

    /// An older text with our marker (one that opened by app path) is ours: shown as outdated, and Install replaces it.
    func testOutdatedOwnScriptIsReplaced() async throws {
        _ = useShell()
        let target = tempDir().appendingPathComponent("prosper")
        try "#!/bin/sh\n\(PVCommand.marker) old\napp='/Volumes/Old/Prosper.app'\nopen -a \"$app\" \"$@\"\n"
            .write(to: target, atomically: true, encoding: .utf8)
        let model = PVCommand(target: target, bundleID: Self.id)
        await model.refresh()
        XCTAssertEqual(model.state, .outdated)
        await model.install()
        XCTAssertEqual(model.state, .installed)
    }

    /// #1732 (QA n57): Uninstall also removes #1723's pv next to the target, only when it is a regular file with
    /// the old marker. A pv without it, or a link to one with it, stays. The old marker never makes `prosper` ours.
    func testUninstallRemovesOnlyOurOldPv() async throws {
        _ = useShell()
        let dir = tempDir(), pv = dir.appendingPathComponent("pv"), target = dir.appendingPathComponent("prosper")
        let old = "#!/bin/sh\n\(PVCommand.legacyMarker) installed by Prosper\nopen -a '/Applications/Prosper.app' \"$@\"\n"
        let model = PVCommand(target: target, bundleID: Self.id)
        try old.write(to: target, atomically: true, encoding: .utf8)
        await model.refresh()
        XCTAssertEqual(model.state, .other)
        try FileManager.default.removeItem(at: target)

        try old.write(to: pv, atomically: true, encoding: .utf8)
        await model.install()
        XCTAssertEqual(try String(contentsOf: pv, encoding: .utf8), old, "install never touches pv")
        await model.uninstall()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])

        let foreign = "#!/bin/sh\necho pipe viewer\n"
        try foreign.write(to: pv, atomically: true, encoding: .utf8)
        await model.uninstall()
        XCTAssertEqual(try String(contentsOf: pv, encoding: .utf8), foreign)
        try FileManager.default.removeItem(at: pv)

        let ours = dir.appendingPathComponent("old")
        try old.write(to: ours, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: pv, withDestinationURL: ours)
        await model.uninstall()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: pv.path), ours.path)
        XCTAssertEqual(try String(contentsOf: ours, encoding: .utf8), old)
    }

    /// With no shell (the XCTest default) the buttons do nothing.
    func testNoShellRunsNothing() async {
        let shell = useShell()
        PVCommand.shell = nil
        let target = tempDir().appendingPathComponent("prosper")
        let model = PVCommand(target: target, bundleID: Self.id)
        await model.install()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(shell.commands.isEmpty)
    }

    func testDefaultsAndAppleScriptQuoting() {
        XCTAssertEqual(PVCommand().target.path, "/usr/local/bin/prosper")
        XCTAssertEqual(PVCommand.appleScript(#"echo "a\b""#),
                       #"do shell script "echo \"a\\b\"" with administrator privileges"#)
        XCTAssertEqual(PVCommand.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(PVCommandSection.status(.other, target: "/usr/local/bin/prosper"),
                       "Another command is at /usr/local/bin/prosper. Prosper will not replace it.")
    }
}
