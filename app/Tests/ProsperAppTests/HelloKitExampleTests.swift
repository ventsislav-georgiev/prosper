import Foundation
import TOMLDecoder
import XCTest
@testable import ProsperApp

// #919 S5: the example kit app/Examples/kits/hello-kit. Every root (claude:, the config home, the state dir) is under the
// row's own tempDir(); the consent is KitRTConsent; no window, no claude, no dch. The kit's two scripts are run only
// under a stub environment (a fixed PATH and KIT_GREETING), never the real home.

final class HelloKitExampleTests: XCTestCase {
    static let ext = "com.example.kit.hello"
    static let slug = "hello-kit"
    static let greeting = "Hello from hello-kit"

    /// app/Examples/kits/hello-kit, from this file's place in the tree (app/Tests/ProsperAppTests/)
    static let kitDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Examples/kits/hello-kit", isDirectory: true)

    private func manifest() throws -> ExtensionManifest {
        let text = try String(contentsOf: Self.kitDir.appendingPathComponent("extension.toml"), encoding: .utf8)
        return try TOMLDecoder().decodeGuarded(ExtensionManifest.self, from: text)
    }

    private func validated(_ dir: URL, _ source: KitInstallSource) throws -> KitValidated {
        switch KitValidator.validate(kitDir: dir, manifest: try manifest(), source: source, otherKitSlugs: []) {
        case .ok(let v): return v
        case .refused(let r): XCTFail("refused: \(r)"); throw CocoaError(.fileReadUnknown)
        }
    }

    /// a copy of the kit under the row's tempDir (modes kept), so no row works on the repository's own files
    private func copy(_ root: URL) throws -> URL {
        let dst = root.appendingPathComponent("sources/hello-kit", isDirectory: true)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.kitDir, to: dst)
        return dst
    }

    private func env(_ label: String = #function) throws -> KitRuntimeTests.Env {
        let root = tempDir(label)
        let roots = ManagedConfigRoots(claude: root.appendingPathComponent("claude home", isDirectory: true),
                                       configHome: root.appendingPathComponent("config", isDirectory: true),
                                       stateDir: root.appendingPathComponent("state", isDirectory: true))
        for d in [roots.claude, roots.configHome] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(KitRuntimeTests.userMD.utf8).write(to: roots.claude.appendingPathComponent("CLAUDE.md"))
        try Data(KitRuntimeTests.userSettings.utf8).write(to: roots.claude.appendingPathComponent("settings.json"))
        let clock = MCClock(), consent = KitRTConsent()
        let mc = ManagedConfig(roots: roots, consent: consent, writer: ManagedConfigPOSIXWriter(), now: { clock.now() })
        return KitRuntimeTests.Env(root: root, roots: roots, consent: consent, provider: ManagedConfigProvider(mc))
    }

    private func bytes(_ u: URL) -> [UInt8]? { (try? Data(contentsOf: u)).map(Array.init) }

    // MARK: rows

    func testTheExampleValidatesAsMarketAndLocalWithNoWarning() throws {
        for source in [KitInstallSource.market, .local] {
            let v = try validated(Self.kitDir, source)
            XCTAssertEqual(v.warnings, [], "\(source)")
            XCTAssertEqual(v.extensionID, Self.ext)
            XCTAssertEqual(v.slug, Self.slug)
            XCTAssertEqual(v.kit.pieces.map(\.kind), [.claudeMD, .hook, .tools])
            XCTAssertEqual(v.kit.settings.map(\.key), ["greeting"])
            XCTAssertEqual(v.tools["tools"]?.map(\.name), ["hello"])
            XCTAssertEqual(v.localPiece, "rules")
        }
        XCTAssertEqual(try manifest().extension.author, "Example Org")
    }

    func testAHostFromTheFirstKitReleaseOnLoadsTheExample() throws {
        let m = try manifest()
        XCTAssertEqual(m.extension.host.min_version, "2.175.0")
        // the loader drops a pre-release suffix before comparing: a 2.175.0 beta host loads it, 2.174.x does not
        for host in ["2.175.0", "2.175.0-beta.19", "2.176.0"] { XCTAssertNoThrow(try ExtensionLoader.validate(m, hostVersion: host), host) }
        XCTAssertThrowsError(try ExtensionLoader.validate(m, hostVersion: "2.174.9"))
    }

    func testApplyWritesOneBlockOneHookGroupOneShimAndTheSettingsEnv() async throws {
        let e = try env()
        let rt = KitRuntime(provider: e.provider, store: try KitStore(configHome: e.roots.configHome, extID: Self.ext),
                            isTrusted: { _ in true }, now: { Date() })
        let dir = try copy(e.root)
        let ext = LoadedExtension(manifest: try manifest(), directory: dir, isSystem: false)
        let (md, st) = (bytes(e.claudeMD), bytes(e.settings))
        let layout = rt.store.layout

        let r = await rt.apply(ext)
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.refused, nil)
        let newMD = try XCTUnwrap(String(contentsOf: e.claudeMD, encoding: .utf8))
        XCTAssertTrue(newMD.hasPrefix(KitRuntimeTests.userMD), newMD)
        let line = KitRender.importLine(layout.live + "/CLAUDE.md") ?? "?"
        XCTAssertEqual(newMD.components(separatedBy: line).count - 1, 1, "one managed import line: \(newMD)")
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: e.settings)) as? [String: Any])
        let groups = try XCTUnwrap((doc["hooks"] as? [String: Any])?["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        let command = (groups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        XCTAssertTrue(command?.contains("hooks/hello-hook.sh") == true, "\(String(describing: command))")
        XCTAssertEqual(((doc["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.count, 1, "the person's own group stays")
        // the dir also holds Prosper's own ".prosper-shims" marker: the shims are the other names
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: layout.bin).filter { !$0.hasPrefix(".") }.sorted(), ["hello"])

        // the settings form writes .settings.env from the manifest default (the Kit pane's save does the same)
        var form: [String: String] = [:]
        for s in try validated(dir, .local).kit.settings { if case .string(let d)? = s.defaultValue { form[s.key] = d } }
        XCTAssertEqual(form, ["greeting": Self.greeting])
        try rt.store.writeSettingsEnv(form)
        XCTAssertEqual(rt.store.readSettingsEnv()["KIT_GREETING"], Self.greeting)
        let envText = try String(contentsOfFile: e.roots.configHome.path + "/" + Self.slug + "/.settings.env", encoding: .utf8)
        XCTAssertTrue(envText.contains("KIT_GREETING="), envText)

        let removed = await rt.remove(ext)
        XCTAssertEqual(removed.failures, [])
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
    }

    func testTheHookAndTheToolRunUnderEveryShellWithAStubEnv() throws {
        let shells = ["/bin/sh", "/bin/bash", "/bin/dash", "/bin/zsh"].filter { FileManager.default.isExecutableFile(atPath: $0) }
        XCTAssertTrue(shells.contains("/bin/sh"))
        let hook = Self.kitDir.appendingPathComponent("hooks/hello-hook.sh").path
        let tool = Self.kitDir.appendingPathComponent("tools/hello").path
        let stub = ["PATH": "/usr/bin:/bin", "KIT_GREETING": "Hi from a stub"]
        // the first line is the shebang's own: both files start with a POSIX sh one, and the mode is 0755 in the tree
        for path in [hook, tool] {
            let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
            XCTAssertEqual(mode & 0o111, 0o111, path)
            XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8).components(separatedBy: "\n").first, "#!/bin/sh")
        }
        for shell in shells {
            let h = try run(shell, [hook], stub)
            XCTAssertEqual(h.status, 0, "\(shell) hook")
            XCTAssertEqual(h.err, "Hi from a stub\n", "\(shell) hook")
            XCTAssertEqual(h.out, "", "\(shell) hook")
            let t = try run(shell, [tool], stub)
            XCTAssertEqual(t.status, 0, "\(shell) tool")
            XCTAssertEqual(t.out, "Hi from a stub\n", "\(shell) tool")
            // no setting yet: the default line, still exit 0
            let d = try run(shell, [hook], ["PATH": "/usr/bin:/bin"])
            XCTAssertEqual(d.status, 0, "\(shell) default")
            XCTAssertEqual(d.err, Self.greeting + "\n", "\(shell) default")
        }
        // and the file itself, through its shebang
        let direct = try run(hook, [], stub)
        XCTAssertEqual(direct.status, 0)
        XCTAssertEqual(direct.err, "Hi from a stub\n")
    }

    private func run(_ exe: String, _ args: [String], _ env: [String: String]) throws -> (status: Int32, out: String, err: String) {
        let p = Process(), o = Pipe(), er = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = o
        p.standardError = er
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: er.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, out, err)
    }

    func testTheListingPreviewIsMadeAndFitsTheCap() throws {
        let v = try validated(Self.kitDir, .market)
        let readme = try String(contentsOf: Self.kitDir.appendingPathComponent("README.md"), encoding: .utf8)
        let preview = KitListingPreview.make(v, readme: readme)
        XCTAssertFalse(preview.summary.isEmpty)
        XCTAssertTrue(preview.readme.hasPrefix("# Hello Kit"), preview.readme)
        let encoded = try JSONEncoder().encode(preview)
        XCTAssertLessThan(encoded.count, 16384)
    }

    func testThePackedTreeIsUnder256KiB() throws {
        let b64 = try RemoteInstaller.packageForPublish(Self.kitDir)
        let size = try XCTUnwrap(Data(base64Encoded: b64)).count
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThan(size, 256 << 10)
    }

    func testNoFileCarriesAHomePathOrADomainThatIsNotExample() throws {
        var files = 0
        for case let rel as String in FileManager.default.enumerator(atPath: Self.kitDir.path)?.allObjects ?? [] {
            let u = Self.kitDir.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            files += 1
            let text = try String(contentsOf: u, encoding: .utf8)
            XCTAssertFalse(text.contains("/Users/"), rel)
            XCTAssertTrue(text.unicodeScalars.allSatisfy { $0.isASCII }, "\(rel): ASCII only")
            let hosts = try NSRegularExpression(pattern: "https?://([^/\\s\"')]+)").matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            for h in hosts { XCTAssertTrue(h == "example.com" || h.hasSuffix(".example.com"), "\(rel): \(h)") }
        }
        XCTAssertEqual(files, 6)
    }
}
