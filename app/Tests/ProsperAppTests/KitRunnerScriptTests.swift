import Foundation
import XCTest
@testable import ProsperApp

// #917 S3: the literal KitRunner.script run under the four system shells. Every row works in its
// own tempDir(): a made-up config home <tempDir>/cfg, the runner written there, and targets, hooks
// and settings the row wrote whose bodies are only printf lines (and at most one exit). Each Process
// is one of the four shells with the runner as its script, an explicit environment (PATH and HOME
// = the tempDir), the tempDir as its cwd, stdin from a Pipe or /dev/null, a 10 s deadline on the
// recorded process. No kit, tool, hook or shim of anyone's is run. The other-owner case of the
// hook and kit.env checks is DESCRIBED ONLY: a row cannot chown without root.

final class KitRunnerScriptTests: XCTestCase {
    static let shells = ["/bin/sh", "/bin/dash", "/bin/bash", "/bin/zsh"]
    static let ext = "com.example.kit"
    private var ran: [String] = []

    struct Kit {
        var root: URL, runner: String, kd: URL, config: URL, target: String, state: String
        var hooks: URL { config.appendingPathComponent("hooks", isDirectory: true) }
        var fired: URL { kd.appendingPathComponent("fired", isDirectory: true) }
        var tmp: URL { kd.appendingPathComponent("tmp", isDirectory: true) }
    }

    struct Run { var status: Int32, out: String, err: String, pid: Int32 }

    // MARK: helpers

    private func write(_ url: URL, _ text: String, mode: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// <root>/cfg/prosper/kit-runtime/prosper-kit-run, <root>/cfg/prosper/kits/<ext>/kit.env (0600),
    /// <root>/cfg/example-kit (KIT_CONFIG), a target that prints its argv and exits 0.
    private func makeKit(_ root: URL, ext: String = KitRunnerScriptTests.ext, targetBody: String = "printf 'T %s\\n' \"$@\"\n") throws -> Kit {
        let cfg = root.appendingPathComponent("cfg", isDirectory: true)
        let runner = cfg.appendingPathComponent("prosper/kit-runtime/prosper-kit-run")
        try write(runner, KitRunner.script, mode: 0o755)
        let kd = cfg.appendingPathComponent("prosper/kits", isDirectory: true).appendingPathComponent(ext, isDirectory: true)
        let config = cfg.appendingPathComponent("example-kit", isDirectory: true)
        try FileManager.default.createDirectory(at: config.appendingPathComponent("hooks"), withIntermediateDirectories: true)
        let live = kd.appendingPathComponent("live", isDirectory: true)
        let target = live.appendingPathComponent("tools/t")
        try write(target, "#!/bin/sh\n" + targetBody, mode: 0o755)
        let state = kd.appendingPathComponent("state's dir").path // a quote the parser must decode
        let ctx = KitRenderContext(extensionID: ext, kitDir: live.path, kitBin: kd.appendingPathComponent("bin").path,
                                   kitConfig: config.path, home: "/Users/example", runner: runner.path)
        let env = try XCTUnwrap(KitRunner.kitEnvText(ctx, stateDir: state))
        try write(kd.appendingPathComponent("kit.env"), env, mode: 0o600)
        return Kit(root: root, runner: runner.path, kd: kd, config: config, target: target.path, state: state)
    }

    private func hook(_ kit: Kit, _ file: String, _ body: String, mode: Int = 0o700, shebang: String = "#!/bin/sh") throws {
        try write(kit.hooks.appendingPathComponent(file), shebang + "\n" + body, mode: mode)
    }

    /// Runs `body` once per shell, in the literal order, and records what ran.
    private func eachShell(_ body: (String) throws -> Void) rethrows {
        for shell in Self.shells {
            ran.append(shell)
            try body(shell)
        }
    }

    private func run(_ shell: String, _ kit: Kit, _ args: [String], stdin: String? = nil, env extra: [String: String] = [:],
                     file: StaticString = #filePath, line: UInt = #line) throws -> Run {
        precondition(Self.shells.contains(shell))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // zsh as the system sh: sh emulation and no zsh startup file (what argv0 "sh" gives it).
        p.arguments = (shell == "/bin/zsh" ? ["--emulate", "sh"] : []) + [kit.runner] + args
        p.environment = extra.merging(["PATH": "/usr/bin:/bin", "HOME": kit.root.path]) { _, fixed in fixed }
        p.currentDirectoryURL = kit.root
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            let inPipe = Pipe()
            inPipe.fileHandleForWriting.write(Data(stdin.utf8)) // small: fits the pipe buffer before launch
            try inPipe.fileHandleForWriting.close()
            p.standardInput = inPipe
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        let pid = p.processIdentifier
        if done.wait(timeout: .now() + 10) == .timedOut {
            p.terminate() // the recorded process only
            XCTFail("\(shell): runner still running after 10 s", file: file, line: line)
            _ = done.wait(timeout: .now() + 5)
        }
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Run(status: p.isRunning ? -1 : p.terminationStatus, out: o, err: e, pid: pid)
    }

    private func lines(_ s: String) -> [String] { s.split(separator: "\n").map(String.init) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func tree(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
    }

    // MARK: the shells

    func testTheFourSystemShellsAreWhatRan() throws {
        let kit = try makeKit(tempDir())
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target, "x"])
            XCTAssertEqual(r.status, 0, shell)
            XCTAssertEqual(r.out, "T x\n", shell)
        }
        XCTAssertEqual(ran, ["/bin/sh", "/bin/dash", "/bin/bash", "/bin/zsh"])
    }

    // MARK: fast path

    func testFastPathExecsTarget() throws {
        let kit = try makeKit(tempDir(), targetBody: "printf '%s\\n' \"$$\"\nexit 4\n")
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target], stdin: "{}")
            XCTAssertEqual(r.status, 4, shell)
            XCTAssertEqual(r.out, "\(r.pid)\n", "\(shell): the target is the runner's own process (exec)")
            XCTAssertEqual(r.err, "", shell)
            XCTAssertFalse(exists(kit.tmp), "\(shell): no temp file on the fast path")
        }
    }

    func testNoExecDashDash() {
        XCTAssertFalse(KitRunner.script.contains("exec --"))
        XCTAssertTrue(KitRunner.script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(KitRunner.script.contains("\nset -u\n"))
        XCTAssertFalse(KitRunner.script.contains("set -e"))
        XCTAssertFalse(KitRunner.script.unicodeScalars.contains { !$0.isASCII })
    }

    // MARK: .pre and .post

    func testPreExit2BlocksWithItsStderr() throws {
        let kit = try makeKit(tempDir())
        try hook(kit, "t.pre", "printf 'blocked by the local guard\\n' >&2\nexit 2\n")
        try hook(kit, "t.post", "printf 'POST RAN\\n' >&2\n")
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target, "x"], stdin: "{}")
            XCTAssertEqual(r.status, 2, shell)
            XCTAssertEqual(r.out, "", "\(shell): the target did not run")
            XCTAssertEqual(r.err, "blocked by the local guard\n", "\(shell): .pre's stderr, and .post did not run")
        }
    }

    func testPostSeesKitStatusAndOutputDiscarded() throws {
        let kit = try makeKit(tempDir(), targetBody: "printf 'T\\n'\nexit 3\n")
        try hook(kit, "t.post", "printf 'POST STDOUT\\n'\nprintf 'status=%s\\n' \"${KIT_STATUS-unset}\" >&2\nexit 9\n")
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target], stdin: "{}", env: ["KIT_STATUS": "7"])
            XCTAssertEqual(r.status, 3, "\(shell): the target's status, .post's ignored")
            XCTAssertEqual(r.out, "T\n", "\(shell): .post's stdout discarded")
            XCTAssertEqual(r.err, "status=3\n", shell)
        }
    }

    /// .pre and .post are `#!/bin/sh /dev/stdin` files, and the target is `sh /dev/stdin`: each
    /// runs the stdin text (one printf line) as its script, so each sees stdin only if the runner
    /// buffered it and gave each its own copy. The hook files' own bodies are never read.
    func testStdinReachesPreTargetPost() throws {
        let kit = try makeKit(tempDir())
        try hook(kit, "t.pre", "printf 'unused\\n'\n", shebang: "#!/bin/sh /dev/stdin")
        try hook(kit, "t.post", "printf 'unused\\n'\n", shebang: "#!/bin/sh /dev/stdin")
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", "sh", "/dev/stdin"], stdin: "printf 'IN\\n' >&2\n")
            XCTAssertEqual(r.status, 0, shell)
            XCTAssertEqual(lines(r.err).filter { $0 == "IN" }.count, 3, "\(shell): \(r.err)")
        }
    }

    func testStdinTempIsRemoved() throws {
        let kit = try makeKit(tempDir())
        try hook(kit, "t.pre", "printf 'pre\\n'\n")
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target], stdin: "{\"a\":1}")
            XCTAssertEqual(r.status, 0, shell)
            XCTAssertTrue(exists(kit.tmp), "\(shell): the buffer was made under the kit's tmp folder")
            XCTAssertEqual(tree(kit.tmp), [], "\(shell): and removed on exit")
            let mode = try FileManager.default.attributesOfItem(atPath: kit.tmp.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o700, shell)
        }
    }

    func testWorldWritablePreSkipped() throws {
        let kit = try makeKit(tempDir())
        try hook(kit, "t.pre", "printf 'PRE RAN\\n' >&2\nexit 2\n", mode: 0o707)
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target, "x"], stdin: "{}")
            XCTAssertEqual(r.status, 0, shell)
            XCTAssertEqual(r.out, "T x\n", shell)
            XCTAssertFalse(r.err.contains("PRE RAN"), shell)
            XCTAssertEqual(lines(r.err).count, 1, shell)
            XCTAssertTrue(r.err.hasPrefix("prosper-kit-run: skipped t.pre:"), shell)
        }
    }

    func testGroupWritablePostSkipped() throws {
        let kit = try makeKit(tempDir())
        try hook(kit, "t.post", "printf 'POST RAN\\n' >&2\n", mode: 0o770)
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target], stdin: "{}")
            XCTAssertEqual(r.status, 0, shell)
            XCTAssertFalse(r.err.contains("POST RAN"), shell)
            XCTAssertEqual(lines(r.err), ["prosper-kit-run: skipped t.post: not a regular executable file of yours, or group- or world-writable"], shell)
        }
    }

    // MARK: kit.env, settings, fired

    func testUnsafeKitEnvEndsTheRun() throws {
        let kit = try makeKit(tempDir())
        let env = kit.kd.appendingPathComponent("kit.env")
        let text = try String(contentsOf: env, encoding: .utf8)
        let fm = FileManager.default
        let cases: [(String, () throws -> Void)] = [
            ("world-writable", { try fm.setAttributes([.posixPermissions: 0o606], ofItemAtPath: env.path) }),
            ("group-writable", { try fm.setAttributes([.posixPermissions: 0o660], ofItemAtPath: env.path) }),
            ("missing", { try fm.removeItem(at: env) }),
            ("symlink", {
                try fm.removeItem(at: env)
                try fm.createSymbolicLink(at: env, withDestinationURL: kit.kd.appendingPathComponent("real.env"))
            }),
            ("no KIT_CONFIG", { try Data("KIT_DIR='/a'\nKIT_BIN='/b'\nKIT_STATE_DIR='/c'\n".utf8).write(to: env) }),
        ]
        for (label, prepare) in cases {
            try? FileManager.default.removeItem(at: env)
            try write(env, text, mode: 0o600)
            try write(kit.kd.appendingPathComponent("real.env"), text, mode: 0o600)
            try prepare()
            try eachShell { shell in
                let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target])
                XCTAssertEqual(r.status, 78, "\(shell) \(label)")
                XCTAssertEqual(r.out, "", "\(shell) \(label): the target did not run")
                XCTAssertEqual(lines(r.err).count, 1, "\(shell) \(label)")
                XCTAssertFalse(exists(kit.fired), "\(shell) \(label): no marker")
            }
        }
    }

    func testSettingsEnvGivesKitKeys() throws {
        let kit = try makeKit(tempDir(), targetBody: """
        printf 'G=%s\\n' "${KIT_GREETING-unset}"
        printf 'L=%s\\n' "${KIT_LIMIT-unset}"
        printf 'D=%s\\n' "${KIT_DIR-unset}"
        printf 'B=%s\\n' "${KIT_BIN-unset}"
        printf 'C=%s\\n' "${KIT_CONFIG-unset}"
        printf 'S=%s\\n' "${KIT_STATE_DIR-unset}"
        printf 'X=%s\\n' "${KIT_BAD-unset}"

        """)
        let settings = try XCTUnwrap(KitRunner.settingsEnvText(["greeting": "it's $HOME `x`", "limit": "40"]))
        // Hand-made lines the parser must skip: not single-quoted, a stray quote, a runner key.
        try write(kit.config.appendingPathComponent(".settings.env"),
                  settings + "KIT_BAD=plain\nKIT_BAD='a'b'\nKIT_DIR='/Users/example/elsewhere'\n# KIT_BAD='comment'\n", mode: 0o600)
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target], env: ["KIT_DIR": "/Users/example/caller", "KIT_STATE_DIR": "/Users/example/caller"])
            XCTAssertEqual(r.status, 0, shell)
            XCTAssertEqual(lines(r.out), [
                "G=it's $HOME `x`", "L=40", "D=\(kit.kd.path)/live", "B=\(kit.kd.path)/bin", "C=\(kit.config.path)",
                "S=\(kit.state)", "X=unset",
            ], shell)
        }
    }

    func testSettingsEnvLineIsNotExecuted() throws {
        let kit = try makeKit(tempDir(), targetBody: "printf 'G=%s\\n' \"${KIT_GREETING-unset}\"\n")
        try write(kit.config.appendingPathComponent(".settings.env"),
                  "KIT_GREETING='hi'\nKIT_EVIL=$(printf X > marker)\nprintf X > marker\n", mode: 0o600)
        let marker = kit.root.appendingPathComponent("marker")
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target])
            XCTAssertEqual(r.out, "G=hi\n", shell)
            XCTAssertFalse(exists(marker), "\(shell): a settings line ran")
            try? FileManager.default.removeItem(at: marker)
        }
    }

    func testFiredMtimeBumped() throws {
        let kit = try makeKit(tempDir())
        let marker = kit.fired.appendingPathComponent("tools")
        try eachShell { shell in
            try? FileManager.default.removeItem(at: kit.fired)
            _ = try run(shell, kit, [Self.ext, "tools", "t", kit.target])
            XCTAssertTrue(exists(marker), shell)
            let mode = try FileManager.default.attributesOfItem(atPath: kit.fired.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o700, shell)
            let old = Date(timeIntervalSince1970: 1_000_000_000)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: marker.path)
            _ = try run(shell, kit, [Self.ext, "tools", "t", kit.target])
            let now = try FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
            XCTAssertGreaterThan(now ?? old, old, shell)
        }
    }

    // MARK: ids and arguments

    func testDashIDsAreArgumentsNotOptions() throws {
        let kit = try makeKit(tempDir(), ext: "-x.example")
        try hook(kit, "-n.pre", "printf 'PRE %s\\n' \"$@\" >&2\n")
        try eachShell { shell in
            try? FileManager.default.removeItem(at: kit.fired)
            let r = try run(shell, kit, ["-x.example", "-p", "-n", kit.target, "-v"], stdin: "{}")
            XCTAssertEqual(r.status, 0, shell)
            XCTAssertEqual(r.out, "T -v\n", shell)
            XCTAssertEqual(r.err, "PRE -v\n", shell)
            XCTAssertTrue(exists(kit.fired.appendingPathComponent("-p")), "\(shell): the marker of piece -p")
        }
    }

    func testSlashOrDotDotIDRefused() throws {
        let kit = try makeKit(tempDir())
        // With the id check removed every one of these still resolves inside the tempDir.
        let cases: [[String]] = [
            ["../outside-kit", "tools", "t"], [Self.ext, "a/b", "t"], [Self.ext, "..", "t"], [Self.ext, "tools", "a/b"],
            [".", "tools", "t"], [Self.ext, "tools", ".."], [Self.ext, "x y", "t"],
        ]
        let before = tree(kit.root)
        try eachShell { shell in
            for ids in cases {
                let r = try run(shell, kit, ids + [kit.target])
                XCTAssertEqual(r.status, 64, "\(shell) \(ids)")
                XCTAssertEqual(r.out, "", "\(shell) \(ids)")
                XCTAssertEqual(lines(r.err).count, 1, "\(shell) \(ids)")
                XCTAssertEqual(tree(kit.root), before, "\(shell) \(ids): nothing touched")
            }
        }
    }

    func testEmptyIDRefused() throws {
        let kit = try makeKit(tempDir())
        let before = tree(kit.root)
        try eachShell { shell in
            for ids in [["", "tools", "t"], [Self.ext, "", "t"], [Self.ext, "tools", ""]] {
                let r = try run(shell, kit, ids + [kit.target])
                XCTAssertEqual(r.status, 64, "\(shell) \(ids)")
                XCTAssertEqual(r.out, "", "\(shell) \(ids)")
                XCTAssertEqual(lines(r.err).count, 1, "\(shell) \(ids)")
                XCTAssertEqual(tree(kit.root), before, "\(shell) \(ids): nothing touched")
            }
        }
    }

    func testInterpreterIsArg4WhenNotAbsolute() throws {
        let kit = try makeKit(tempDir(), targetBody: "printf 'ARG %s\\n' \"$@\"\n")
        try eachShell { shell in
            let r = try run(shell, kit, [Self.ext, "tools", "t", "sh", kit.target, "a b", "-c"])
            XCTAssertEqual(r.status, 0, shell)
            XCTAssertEqual(r.out, "ARG a b\nARG -c\n", shell)
            for bad in [["-sh", kit.target], ["sh", "tools/t"], ["sh"]] {
                let b = try run(shell, kit, [Self.ext, "tools", "t"] + bad)
                XCTAssertEqual(b.status, 64, "\(shell) \(bad)")
                XCTAssertEqual(b.out, "", "\(shell) \(bad)")
            }
        }
    }

    /// A builtin passes the character check but has no path: refused on both paths before anything
    /// runs. Under a mutant that runs it, `eval` would run the argument as code: the marker name is
    /// relative, so it would land in the row's tempDir (the cwd).
    func testBuiltinInterpreterRefused() throws {
        let kit = try makeKit(tempDir(), targetBody: "printf 'ARG %s\\n' \"$@\"\n")
        let marker = kit.root.appendingPathComponent("marker")
        let pre = kit.hooks.appendingPathComponent("t.pre")
        try eachShell { shell in
            for hooked in [false, true] {
                if hooked { try hook(kit, "t.pre", "printf 'pre\\n'\n") } else { try? FileManager.default.removeItem(at: pre) }
                for builtin in ["eval", ".", "exec"] {
                    let r = try run(shell, kit, [Self.ext, "tools", "t", builtin, kit.target, ";printf X > marker"], stdin: "{}")
                    XCTAssertEqual(r.status, 64, "\(shell) \(builtin) hooked=\(hooked)")
                    XCTAssertEqual(r.out, "", "\(shell) \(builtin) hooked=\(hooked): the target did not run")
                    XCTAssertEqual(lines(r.err).count, 1, "\(shell) \(builtin) hooked=\(hooked)")
                    XCTAssertFalse(exists(marker), "\(shell) \(builtin) hooked=\(hooked)")
                    try? FileManager.default.removeItem(at: marker)
                }
                let ok = try run(shell, kit, [Self.ext, "tools", "t", "sh", kit.target, ";printf X > marker"], stdin: "{}")
                XCTAssertEqual(ok.status, 0, "\(shell) sh hooked=\(hooked)")
                XCTAssertEqual(ok.out, "ARG ;printf X > marker\n", "\(shell) sh hooked=\(hooked)")
                XCTAssertFalse(exists(marker), "\(shell) sh hooked=\(hooked)")
            }
        }
    }

    func testUnsafeSettingsFileSkipped() throws {
        let kit = try makeKit(tempDir(), targetBody: "printf 'G=%s\\n' \"${KIT_GREETING-unset}\"\n")
        let settings = kit.config.appendingPathComponent(".settings.env")
        let real = kit.root.appendingPathComponent("real-settings.env")
        try write(real, "KIT_GREETING='hi'\n", mode: 0o600)
        let skipped = "prosper-kit-run: skipped .settings.env: not a regular file of yours, or group- or world-writable"
        for (label, mode, link) in [("0666", 0o666, false), ("0660", 0o660, false), ("symlink", 0o600, true), ("0600", 0o600, false)] {
            try? FileManager.default.removeItem(at: settings)
            if link {
                try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: real)
            } else {
                try write(settings, "KIT_GREETING='hi'\n", mode: mode)
            }
            try eachShell { shell in
                let r = try run(shell, kit, [Self.ext, "tools", "t", kit.target])
                XCTAssertEqual(r.status, 0, "\(shell) \(label)")
                if label == "0600" {
                    XCTAssertEqual(r.out, "G=hi\n", "\(shell) \(label)")
                    XCTAssertEqual(r.err, "", "\(shell) \(label)")
                } else {
                    XCTAssertEqual(r.out, "G=unset\n", "\(shell) \(label)")
                    XCTAssertEqual(lines(r.err), [skipped], "\(shell) \(label)")
                }
            }
        }
    }

    // MARK: text builders

    func testKitEnvTextIsSingleQuoted() {
        let ctx = KitRenderContext(extensionID: Self.ext, kitDir: "/Users/example/k", kitBin: "/Users/example/b",
                                   kitConfig: "/Users/example/.config/example-kit", home: "/Users/example", runner: "/r")
        XCTAssertEqual(KitRunner.kitEnvText(ctx, stateDir: "/Users/example/it's"), """
        KIT_DIR='/Users/example/k'
        KIT_BIN='/Users/example/b'
        KIT_CONFIG='/Users/example/.config/example-kit'
        KIT_STATE_DIR='/Users/example/it'\\''s'

        """)
        XCTAssertTrue(KitRunner.kitEnvText(ctx, stateDir: "/a\nKIT_DIR='/b'") == nil)
    }

    func testSettingsValueWithALineBreakGivesNil() {
        XCTAssertEqual(KitRunner.settingsEnvText(["b_2": "x", "a": "y"]), "KIT_A='y'\nKIT_B_2='x'\n")
        XCTAssertEqual(KitRunner.settingsEnvText([:]), "")
        for bad in ["a\nKIT_X='y'", "a\rb", "a\u{0}b", "a\u{2028}b"] {
            XCTAssertTrue(KitRunner.settingsEnvText(["ok": "1", "k": bad]) == nil, bad.debugDescription)
        }
        for key in ["", "a-b", "a b", "dir", "status", "state_dir", "\u{00DF}", "a=b"] {
            XCTAssertTrue(KitRunner.settingsEnvText([key: "v"]) == nil, key.debugDescription)
        }
    }
}
