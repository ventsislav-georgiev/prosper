import Darwin
import XCTest
@testable import ProsperApp

/// #915 (spec B24, B26): the ccpool extension's shipped POSIX sh scripts, run under /bin/sh against listeners on
/// ephemeral loopback ports (CCPOOL_PORT is always set; the default port is never dialled). TOOL is a scratch sh
/// script that writes its ANTHROPIC_BASE_URL and arguments to a file; PATH holds only that dir, /usr/bin and /bin.
final class CCPoolScriptsTests: XCTestCase {
    private var binDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions/ccpool/bin", isDirectory: true)
    }

    private struct Run {
        let status: Int32
        let out: String
        let err: String
    }

    private struct Tool {
        let dir: URL
        let record: URL
        var path: String { dir.appendingPathComponent("claude").path }
        var ran: String? { try? String(contentsOf: record, encoding: .utf8) }
    }

    /// A scratch TOOL named `claude` (so the default TOOL is it too) that records what it was started with.
    private func tool() throws -> Tool {
        let dir = tempDir()
        let record = dir.appendingPathComponent("ran.txt")
        let body = "#!/bin/sh\n{ printf 'BASE=%s\\n' \"${ANTHROPIC_BASE_URL-unset}\"; "
            + "for a in \"$@\"; do printf 'ARG=%s\\n' \"$a\"; done; } > '\(record.path)'\n"
        let url = dir.appendingPathComponent("claude")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return Tool(dir: dir, record: record)
    }

    private func run(_ script: String, _ args: [String] = [], env: [String: String], path: String = "/usr/bin:/bin",
                     stdin: FileHandle = FileHandle.nullDevice, timeout: TimeInterval = 15) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [binDir.appendingPathComponent(script).path] + args
        p.environment = env.merging(["PATH": path]) { _, new in new }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning {
            p.terminate()   // the pid this test started
            XCTFail("\(script) did not finish within \(timeout) s")
        }
        p.waitUntilExit()
        return Run(status: p.terminationStatus,
                   out: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                   err: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// The real proxy on an ephemeral port, its health answer naming `current`. Upstream 127.0.0.1:9, never dialled.
    private func pool(current: String = "alpha") throws -> UInt16 {
        let store = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        _ = try store.addAccount(label: current, token: "tok-\(current)", secrets: secrets)
        store.mutate { $0.current = current }
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: CCPoolCapturingLogger())
        addTeardownBlock { service.stop() }
        guard case .running(let port) = service.start() else {
            XCTFail("the pool did not start: \(service.status)")
            return 0
        }
        return port
    }

    /// A listener that answers every request with `headers` and `body`.
    private func listener(_ headers: [(String, String)], _ body: String) throws -> UInt16 {
        let server = try CCPoolFakeServer { _, _ in .respond(200, headers, Data(body.utf8)) }
        addTeardownBlock { server.stop() }
        XCTAssertNotEqual(server.port, 0)
        return server.port
    }

    /// A loopback port nothing listens on: bound by the kernel's pick, then closed at once.
    private func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { XCTFail("socket"); return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        XCTAssertTrue(ok, "bind")
        return UInt16(bigEndian: addr.sin_port)
    }

    // MARK: ccpool-launch

    // A ccpool proxy answers: TOOL runs with ANTHROPIC_BASE_URL at the pool and its arguments after "--".
    func testLaunchRunsToolThroughARunningPool() throws {
        let t = try tool()
        let port = try pool()
        let named = try run("ccpool-launch", [t.path, "--", "x y", "z"], env: ["CCPOOL_PORT": "\(port)"])
        XCTAssertEqual(named.status, 0, named.err)
        XCTAssertEqual(t.ran, "BASE=http://127.0.0.1:\(port)\nARG=x y\nARG=z\n")

        // TOOL defaults to claude, found on PATH (the scratch one: PATH holds no other dir with a claude).
        try FileManager.default.removeItem(at: t.record)
        let byDefault = try run("ccpool-launch", ["--", "-p", "hi"], env: ["CCPOOL_PORT": "\(port)"],
                                path: "\(t.dir.path):/usr/bin:/bin")
        XCTAssertEqual(byDefault.status, 0, byDefault.err)
        XCTAssertEqual(t.ran, "BASE=http://127.0.0.1:\(port)\nARG=-p\nARG=hi\n")
    }

    // #1200: ANTHROPIC_BASE_URL already points elsewhere (another proxy in front): exit 3, TOOL never runs. Already at
    // this pool: it runs.
    func testLaunchLeavesASessionBehindAnotherProxyAlone() throws {
        let t = try tool()
        let port = try pool()
        let other = try run("ccpool-launch", [t.path], env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:1"])
        XCTAssertEqual(other.status, 3)
        XCTAssertEqual(other.err, "ccpool-launch: ANTHROPIC_BASE_URL is already set; a session behind another proxy is not routed through the pool\n")
        XCTAssertTrue(t.ran == nil, "TOOL ran behind another proxy")

        let same = try run("ccpool-launch", [t.path], env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"])
        XCTAssertEqual(same.status, 0, same.err)
        XCTAssertEqual(t.ran, "BASE=http://127.0.0.1:\(port)\n")
    }

    // Something that is not ccpool holds the port: exit 2, TOOL never runs.
    func testLaunchRefusesAForeignListener() throws {
        let t = try tool()
        let port = try listener([("Server", "nginx")], "hello")
        let r = try run("ccpool-launch", [t.path], env: ["CCPOOL_PORT": "\(port)"])
        XCTAssertEqual(r.status, 2)
        XCTAssertEqual(r.err, "ccpool-launch: port \(port) is held by another program\n")
        XCTAssertTrue(t.ran == nil, "TOOL ran on a foreign listener")
    }

    // A listener that names itself ccpool only in its health JSON (no Server header) counts as the pool.
    func testLaunchAcceptsAHealthAnswerWithoutTheServerHeader() throws {
        let t = try tool()
        let port = try listener([("Content-Type", "application/json")], #"{"current": null, "service": "ccpool-proxy"}"#)
        let r = try run("ccpool-launch", [t.path], env: ["CCPOOL_PORT": "\(port)"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(t.ran, "BASE=http://127.0.0.1:\(port)\n")
    }

    // Nothing listens: the native proxy cannot be started from a shell, so exit 1 and TOOL never runs.
    func testLaunchSaysThePoolIsNotRunning() throws {
        let t = try tool()
        let r = try run("ccpool-launch", [t.path], env: ["CCPOOL_PORT": "\(freePort())"])
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(r.err, "ccpool-launch: the pool is not running; turn it on in Prosper Settings \u{203A} Agent Account Pool\n")
        XCTAssertTrue(t.ran == nil, "TOOL ran with nothing listening")
    }

    // A CCPOOL_PORT that is not a port: refused before any probe.
    func testLaunchRefusesABadPort() throws {
        let t = try tool()
        for bad in ["abc", "0", "65536", "1234567", "12a"] {
            let r = try run("ccpool-launch", [t.path], env: ["CCPOOL_PORT": bad])
            XCTAssertEqual(r.status, 64, bad)
        }
        XCTAssertTrue(t.ran == nil)
    }

    // MARK: ccpool-statusline

    func testStatuslineNamesTheCurrentAccountWhenRoutedAndUp() throws {
        let port = try pool(current: "alpha")
        let r = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out, "\u{1B}[32mccpool alpha\u{1B}[0m")
    }

    func testStatuslineSaysDownWhenRoutedAndTheHealthAnswerFails() throws {
        let port = freePort()
        let r = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)/"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out, "\u{1B}[31mccpool down\u{1B}[0m")
        let foreign = try listener([("Server", "nginx")], "hello")
        let f = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(foreign)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(foreign)"])
        XCTAssertEqual(f.out, "\u{1B}[31mccpool down\u{1B}[0m", "a foreign answer is not the pool")
    }

    // Not routed: nothing at all (no URL, or a URL that is not this pool).
    func testStatuslinePrintsNothingWhenNotRouted() throws {
        let port = try pool()
        for env in [["CCPOOL_PORT": "\(port)"],
                    ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:1"]] {
            let r = try run("ccpool-statusline", env: env)
            XCTAssertEqual(r.status, 0)
            XCTAssertEqual(r.out, "", "\(env)")
        }
    }

    // #1485: a session behind headroom has BASE at headroom and TARGET at its upstream. TARGET, when set and non-empty,
    // is the URL that counts; the loopback, port and health checks are the same for it.
    func testStatuslineReadsTheTargetUrlFirst() throws {
        let port = try pool(current: "alpha")
        let behind = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:1",
                                                        "ANTHROPIC_TARGET_API_URL": "http://127.0.0.1:\(port)"])
        XCTAssertEqual(behind.out, "\u{1B}[32mccpool alpha\u{1B}[0m", "TARGET at the pool, BASE at headroom")

        // An empty TARGET is unset: BASE counts.
        let empty = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)",
                                                       "ANTHROPIC_TARGET_API_URL": ""])
        XCTAssertEqual(empty.out, "\u{1B}[32mccpool alpha\u{1B}[0m")

        // TARGET names something else: BASE at the pool does not count.
        let other = try listener([("Server", "nginx")], "hello")
        let elsewhere = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)",
                                                           "ANTHROPIC_TARGET_API_URL": "http://127.0.0.1:\(other)"])
        XCTAssertEqual(elsewhere.out, "")
    }

    // BASE at a non-ccpool listener and no TARGET: nothing. BASE-only is the old rule.
    func testStatuslineBaseAtAnotherListenerWithNoTargetPrintsNothing() throws {
        let other = try listener([("Server", "nginx")], "hello")
        let port = try pool()
        let r = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(other)"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out, "")
    }

    // TARGET at a closed pool port: red "down", whatever BASE is.
    func testStatuslineSaysDownWhenTheTargetIsDown() throws {
        let port = freePort()
        let r = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:1",
                                                   "ANTHROPIC_TARGET_API_URL": "http://127.0.0.1:\(port)"])
        XCTAssertEqual(r.out, "\u{1B}[31mccpool down\u{1B}[0m")
    }

    // TARGET not on loopback: nothing printed and no connection made (a scratch curl on PATH records any call).
    func testStatuslineNeverDialsANonLoopbackTarget() throws {
        let dir = tempDir()
        let record = dir.appendingPathComponent("curl-ran.txt")
        let curl = dir.appendingPathComponent("curl")
        try "#!/bin/sh\necho ran > '\(record.path)'\n".write(to: curl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        let port = try pool()
        let r = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)",
                                                   "ANTHROPIC_TARGET_API_URL": "http://example-host:1"],
                        path: "\(dir.path):/usr/bin:/bin")
        XCTAssertEqual(r.out, "")
        XCTAssertTrue(!FileManager.default.fileExists(atPath: record.path), "curl ran for a non-loopback target")
    }

    // A label is user text: ESC (C0), DEL and a C1 control are dropped; the rest prints through printf '%s'.
    func testStatuslineStripsControlCharactersFromTheLabel() throws {
        let port = try listener([("Server", "ccpool"), ("Content-Type", "application/json")],
                                #"{"current":"a\u001b[31mb\u007fc\u009bd%s","service":"ccpool-proxy"}"#)
        let r = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"])
        XCTAssertEqual(r.out, "\u{1B}[32mccpool a[31mbcd%s\u{1B}[0m")
        XCTAssertEqual(r.out.unicodeScalars.filter { $0.value == 0x1B }.count, 2, "only the colour codes carry ESC")
    }

    // Invisible format and bidi characters (U+00AD, U+200B-U+200F, U+202A-U+202E, U+2066-U+2069, U+FEFF) are dropped
    // too; neighbouring visible text (U+2010, U+2060 range edges, accents) is kept.
    func testStatuslineStripsInvisibleFormatCharactersFromTheLabel() throws {
        let port = try listener([("Server", "ccpool"), ("Content-Type", "application/json")],
                                #"{"current":"a\u202eb\u200bc\u00add\u200fe\u202af\u2066g\u2069h\ufeffi\u200a\u2010j\u00e9","service":"ccpool-proxy"}"#)
        let r = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"])
        XCTAssertEqual(r.out, "\u{1B}[32mccpool abcdefghi\u{200A}\u{2010}j\u{E9}\u{1B}[0m")
    }

    // A label made only of those characters leaves nothing: the bare "ccpool".
    func testStatuslineWithAnInvisibleOnlyLabelPrintsJustCCPool() throws {
        let port = try listener([("Server", "ccpool"), ("Content-Type", "application/json")],
                                #"{"current":"\u202e\u200b\ufeff\u00ad","service":"ccpool-proxy"}"#)
        let r = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"])
        XCTAssertEqual(r.out, "\u{1B}[32mccpool\u{1B}[0m")
    }

    // Claude Code's statusLine JSON on a stdin that stays open: drained in the background, never waited on.
    func testStatuslineNeverWaitsOnStdin() throws {
        let input = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        input.fileHandleForWriting.write(Data(#"{"session_id":"api"}"#.utf8))
        let port = freePort()
        let started = Date()
        let r = try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"],
                        stdin: input.fileHandleForReading, timeout: 10)
        XCTAssertEqual(r.out, "\u{1B}[31mccpool down\u{1B}[0m")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // #1673: the statusline reads session_id from stdin and shows that session's account; else the current one.
    func testStatuslineShowsTheSessionsOwnAccountAndFallsBack() throws {
        let port = try listener([("Server", "ccpool"), ("Content-Type", "application/json")],
                                #"{"current":"alpha","service":"ccpool-proxy","sessions":{"api":"beta","api-qa":"gam%s"}}"#)
        func shown(_ stdin: String) throws -> String {
            let input = Pipe()
            defer { try? input.fileHandleForWriting.close() }
            input.fileHandleForWriting.write(Data(stdin.utf8))   // left open: the script never waits for EOF
            return try run("ccpool-statusline", env: ["CCPOOL_PORT": "\(port)", "ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"],
                           stdin: input.fileHandleForReading, timeout: 10).out
        }
        let green = "\u{1B}[32m", plain = "\u{1B}[0m"
        XCTAssertEqual(try shown(#"{"model":{},"session_id":"api","cwd":"/x"}"#), "\(green)ccpool beta\(plain)")
        XCTAssertEqual(try shown(#"{"session_id": "api-qa"}"#), "\(green)ccpool gam%s\(plain)")
        XCTAssertEqual(try shown(#"{"session_id":"unknown"}"#), "\(green)ccpool alpha\(plain)", "unknown sid: current")
        XCTAssertEqual(try shown(#"{"session_id":"a.b"}"#), "\(green)ccpool alpha\(plain)", "a dotted id is never looked up")
        XCTAssertEqual(try shown(#"{"session_id":"api/../x"}"#), "\(green)ccpool alpha\(plain)")
        XCTAssertEqual(try shown(#"{"model":{}}"#), "\(green)ccpool alpha\(plain)", "no session_id: current")
        XCTAssertEqual(try shown("not json"), "\(green)ccpool alpha\(plain)")
    }

    // MARK: Terminal use (spec 3.5)

    // The pane names the launcher inside the app bundle (Contents/Resources/extensions/ccpool/bin), and that path
    // names the file this tree ships.
    @MainActor
    func testTerminalUseNamesTheShippedLauncher() throws {
        let bundled = URL(fileURLWithPath: "/Applications/Example.app/Contents/Resources/extensions", isDirectory: true)
        let path = "/Applications/Example.app/Contents/Resources/extensions/ccpool/bin/ccpool-launch"
        XCTAssertEqual(CCPoolRuntime.launcherPath(extensionsDir: bundled), path)
        XCTAssertTrue(CCPoolRuntime.launcherPath(extensionsDir: nil) == nil)
        let source = binDir.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: try XCTUnwrap(CCPoolRuntime.launcherPath(extensionsDir: source))))

        let dir = tempDir()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let rt = CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old").appendingPathComponent("vault-file"),
                               defaults: scratchDefaults("ccpool-terminal"), probeBase: cfg.upstream,
                               logger: CCPoolCapturingLogger(), launcherPath: CCPoolRuntime.launcherPath(extensionsDir: bundled))
        XCTAssertEqual(rt.model.launcherText, "Or run \(path), which checks the proxy first.")
        XCTAssertEqual(rt.model.terminalCommand, "ANTHROPIC_BASE_URL=http://127.0.0.1:0 claude", "the configured port")
    }

    // MARK: Both

    func testScriptsArePlainPOSIXShellAndExecutable() throws {
        for name in ["ccpool-launch", "ccpool-statusline"] {
            let url = binDir.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("#!/bin/sh\n"), name)
            XCTAssertTrue(data.allSatisfy { $0 == 0x0A || (0x20...0x7E).contains($0) }, "\(name): ASCII text only")
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
            XCTAssertEqual(mode & 0o111, 0o111, "\(name) is shipped executable")
            for shell in ["/bin/sh", "/bin/dash"] where FileManager.default.isExecutableFile(atPath: shell) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: shell)
                p.arguments = ["-n", url.path]
                p.standardInput = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                XCTAssertEqual(p.terminationStatus, 0, "\(shell) -n \(name)")
            }
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("security "), "\(name) never reads the Keychain")
        }
    }
}
