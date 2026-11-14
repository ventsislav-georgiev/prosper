import XCTest
import LuaRuntime
@testable import ProsperApp

/// Host services whose fs calls go to the real disk (FSReads), so a read answers with the
/// file's bytes. Every path a test passes is under a tempDir() home; watches are recorded.
private final class DiskServices: ExtensionHostServices, @unchecked Sendable {
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }
    func fsExists(_ path: String) -> Bool { FSReads.exists(path) }
    func fsAttributesJSON(_ path: String) -> String { FSReads.attributesJSON(path) }
    func fsRead(_ path: String) -> String? { FSReads.read(path) }
    var watches: [(path: String, hideSecrets: Bool)] = []
    func fsWatch(extensionID: String, path: String, handler: String, hideSecrets: Bool) {
        watches.append((path, hideSecrets))
    }
    var hits = "[]"
    func filesSearch(_ optsJSON: String) async -> String { hits }
}

/// #921 (OQ-70): below the system tier the extension host answers a secret path as missing.
final class ExtensionSecretPathsTests: XCTestCase {
    /// listed path (relative to home) → a fake file at or below it.
    private let fakes: [(listed: String, file: String)] = [
        (".ssh", ".ssh/id_test"),
        ("Library/Keychains", "Library/Keychains/login.keychain-db"),
        (".ccpool", ".ccpool/vault.json"),
        (".config/mcpbridge", ".config/mcpbridge/config.json"),
        (".claude/settings.json", ".claude/settings.json"),
        (".aws", ".aws/credentials"),
        (".gnupg", ".gnupg/pubring.kbx"),
        (".netrc", ".netrc"),
        (".git-credentials", ".git-credentials"),
        (".npmrc", ".npmrc"),
        (".config/gh", ".config/gh/hosts.yml"),
        (".config/gcloud", ".config/gcloud/credentials.db"),
        (".kube", ".kube/config"),
        (".docker/config.json", ".docker/config.json"),
        (".claude.json", ".claude.json"),
        (".claude/.credentials.json", ".claude/.credentials.json"),
        (".config/prosper/device.key", ".config/prosper/device.key"),
        (".config/prosper/supporter.dat", ".config/prosper/supporter.dat"),
    ]
    private var home = ""

    override func setUpWithError() throws {
        home = tempDir("secret-home").path
        for f in fakes { try write(f.file, "fake:" + f.file) }
        let saved = SecretPaths.home, savedEnv = SecretPaths.environment, savedLog = SecretPaths.log
        SecretPaths.home = home
        SecretPaths.environment = [:]
        addTeardownBlock {
            SecretPaths.home = saved; SecretPaths.environment = savedEnv
            SecretPaths.log = savedLog; SecretPaths.onCanonical = nil
        }
    }

    private func path(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }

    private func write(_ rel: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path(rel))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func link(_ rel: String, to target: String) throws {
        try FileManager.default.createDirectory(atPath: (path(rel) as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path(rel), withDestinationPath: path(target))
    }

    /// One Lua VM; `fn(p)` returns what the extension sees, as a string.
    private func host(system: Bool, _ svc: DiskServices = DiskServices()) throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.example.secret", services: svc, privileged: system, trusted: true).install(into: lua)
        try lua.run("""
        function rd(p) local s = host.fs.read(p); if s == nil then return "NIL" end return s end
        function ex(p) return tostring(host.fs.exists(p)) end
        function at(p) local a = host.fs.attributes(p); return tostring(a.exists) .. "|" .. tostring(a.isDir) end
        function ls(p) return table.concat(host.fs.list_dirs(p), ",") end
        function wt(p) host.fs.watch(p, "on_change"); return "ok" end
        """)
        return lua
    }

    private func call(_ lua: LuaRuntime, _ fn: String, _ p: String) throws -> String {
        try lua.callGlobal(fn, [p]) ?? "<no answer>"
    }

    func testEachListedPathIsMissingBelowSystemTierAndReadAtSystemTier() throws {
        let automation = try host(system: false), system = try host(system: true)
        for f in fakes {
            XCTAssertEqual(try call(automation, "rd", path(f.file)), "NIL", f.listed)
            XCTAssertEqual(try call(automation, "ex", path(f.listed)), "false", f.listed)
            XCTAssertEqual(try call(automation, "at", path(f.listed)), "false|nil", f.listed)
            XCTAssertEqual(try call(system, "rd", path(f.file)), "fake:" + f.file, f.listed)
            XCTAssertEqual(try call(system, "ex", path(f.listed)), "true", f.listed)
        }
    }

    /// A path added to SecretPaths.listed without a row in `fakes` turns this red.
    func testEveryListedPathHasAFakeRow() {
        XCTAssertEqual(Set(SecretPaths.listed), Set(fakes.map { f in f.listed }))
    }

    func testCCPoolHomeSetAndAbsoluteIsRefused() throws {
        let pool = tempDir("pool")
        try Data("fake:pool-vault".utf8).write(to: pool.appendingPathComponent("vault.json"))
        SecretPaths.environment = ["CCPOOL_HOME": pool.path]
        let file = pool.appendingPathComponent("vault.json").path
        XCTAssertTrue(SecretPaths.denies(file))
        XCTAssertEqual(try call(try host(system: false), "rd", file), "NIL")
        XCTAssertEqual(try call(try host(system: true), "rd", file), "fake:pool-vault")
    }

    func testCCPoolHomeRelativeOrEmptyIsIgnored() throws {
        for value in ["pool", "", "./pool"] {
            SecretPaths.environment = ["CCPOOL_HOME": value]
            XCTAssertEqual(SecretPaths.matcher().roots.count, SecretPaths.listed.count, value)
        }
        try write("pool/vault.json", "plain:pool")
        SecretPaths.environment = ["CCPOOL_HOME": "pool"]
        XCTAssertEqual(try call(try host(system: false), "rd", path("pool/vault.json")), "plain:pool")
    }

    func testCCPoolHomeUnsetIsIgnored() throws {
        SecretPaths.environment = ["OTHER": "/Users/example/.ccpool-elsewhere"]
        XCTAssertEqual(SecretPaths.matcher().roots.count, SecretPaths.listed.count)
        try write("pool/vault.json", "plain:pool")
        XCTAssertEqual(try call(try host(system: false), "rd", path("pool/vault.json")), "plain:pool")
    }

    /// The filter keeps its own copy of the pool's variable name, so it does not depend on the pool
    /// module; this row turns red when either name changes.
    func testCCPoolHomeNameMatchesCCPool() {
        XCTAssertEqual(SecretPaths.ccpoolHomeVariable, CCPoolMigration.homeVariable)
    }

    /// #1201 (R921-4): CCPOOL_HOME protects the folder the pool would open for the same value: a relative
    /// value counts from the app's working directory, a leading "~" included; a "~" value is refused under
    /// the home as well. The working directory is a folder in the fake home, set through the seam.
    func testCCPoolHomeRelativeAndTildeValuesAreRefused() throws {
        let savedCwd = SecretPaths.workingDirectory
        addTeardownBlock { SecretPaths.workingDirectory = savedCwd }
        SecretPaths.workingDirectory = path("work")
        let poolFile = "work/pool/vault.json", literal = "work/~/vault/vault.json", expanded = "vault/vault.json"
        for f in [poolFile, literal, expanded, "work/other/vault.json"] { try write(f, "fake:" + f) }
        let cases: [(value: String, refused: [String], allowed: [String])] = [
            ("pool", [poolFile], [literal, expanded]),
            ("./pool", [poolFile], [literal, expanded]),
            ("~/vault", [literal, expanded], [poolFile]),
        ]
        for c in cases {
            SecretPaths.environment = ["CCPOOL_HOME": c.value]
            XCTAssertEqual(SecretPaths.matcher().roots.count, SecretPaths.listed.count + c.refused.count, c.value)
            let automation = try host(system: false), system = try host(system: true)
            for f in c.refused {
                XCTAssertEqual(try call(automation, "rd", path(f)), "NIL", c.value + " " + f)
                XCTAssertEqual(try call(system, "rd", path(f)), "fake:" + f, c.value + " " + f)
            }
            for f in c.allowed + ["work/other/vault.json"] {
                XCTAssertEqual(try call(automation, "rd", path(f)), "fake:" + f, c.value + " " + f)
            }
        }
    }

    /// One notice line per refused path per VM (the #1048 shape): repeated calls on one path stay
    /// quiet, a new VM notices again, the system tier never logs, and distinct paths past the cap
    /// stay silent. No line names the path.
    func testRefusalNoticeOncePerPathPerVM() throws {
        var lines: [String] = []
        SecretPaths.log = { lines.append($0) }
        let automation = try host(system: false)
        let file = path(".ssh/id_test")
        for fn in ["rd", "ex", "at", "rd", "ls", "rd"] { _ = try call(automation, fn, file) }
        XCTAssertEqual(lines, ["com.example.secret: host.fs.read refused a secret path"])
        XCTAssertEqual(try call(automation, "ex", path(".aws")), "false")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last, "com.example.secret: host.fs.exists refused a secret path")
        _ = try call(try host(system: false), "rd", file)
        XCTAssertEqual(lines.count, 3, "a new VM notices the same path once")
        XCTAssertEqual(try call(try host(system: true), "rd", file), "fake:.ssh/id_test")
        XCTAssertEqual(lines.count, 3, "the system tier is never refused")
        for i in 0..<(SecretPaths.noticeCap + 5) {
            XCTAssertEqual(try call(automation, "ex", path(".ssh/missing\(i)")), "false")
        }
        XCTAssertEqual(lines.count, 3 + SecretPaths.noticeCap - 2, "two paths were already noticed in this VM")
        // #1201: the key is a hash, so two long paths that share their first 256 characters are two paths.
        let fresh = try host(system: false), long = path(".ssh/" + String(repeating: "d/", count: 1_000))
        let before = lines.count
        for p in [long + "a", long + "b", long + "a"] { XCTAssertEqual(try call(fresh, "ex", p), "false") }
        XCTAssertEqual(lines.count, before + 2, "one line per long path")
        XCTAssertFalse(lines.contains { $0.contains(home) || $0.contains(".ssh") })
    }

    /// The filter's cost on the calling queue, counted in resolved paths (canonical calls), never
    /// timed: below the system tier one host.fs call, alone in its handler run, resolves every root once
    /// plus its own path (several calls in one run: testRootsResolvedOncePerHandlerRun); one
    /// watch callback batch (visiblePaths) and one files.search answer resolve the roots once plus
    /// one per path; the system tier and an unfiltered watch resolve nothing.
    func testFilterCostIsRootsOncePlusOnePerPath() throws {
        var resolved = 0
        let prefix = home
        SecretPaths.onCanonical = { if $0.hasPrefix(prefix) { resolved += 1 } }
        let roots = SecretPaths.listed.count
        try write("plain.txt", "plain")
        let automation = try host(system: false), system = try host(system: true)

        resolved = 0
        XCTAssertEqual(try call(automation, "rd", path(".ssh/id_test")), "NIL")
        XCTAssertEqual(resolved, roots + 1, "refused read")
        resolved = 0
        XCTAssertEqual(try call(automation, "rd", path("plain.txt")), "plain")
        XCTAssertEqual(resolved, roots + 1, "allowed read")
        resolved = 0
        XCTAssertEqual(try call(system, "rd", path(".ssh/id_test")), "fake:.ssh/id_test")
        XCTAssertEqual(resolved, 0, "system tier")

        let batch = (0..<1_000).map { path("busy/f\($0).txt") } + [path(".ssh/id_test")]
        resolved = 0
        XCTAssertEqual(ExtensionFSWatch.visiblePaths(batch, hideSecrets: true)?.count, 1_000)
        XCTAssertEqual(resolved, roots + batch.count, "one watch batch")
        resolved = 0
        XCTAssertEqual(ExtensionFSWatch.visiblePaths(batch, hideSecrets: false)?.count, batch.count)
        XCTAssertEqual(resolved, 0, "unfiltered watch")

        let hits = String(decoding: try JSONSerialization.data(withJSONObject: [["path": path("plain.txt")],
                                                                                ["path": path(".ssh/id_test")]]), as: UTF8.self)
        resolved = 0
        XCTAssertTrue(SecretPaths.filterHits(hits).contains("plain.txt"))
        XCTAssertEqual(resolved, roots + 2, "one files.search answer")
    }

    /// #1201: below the system tier the roots are resolved once per entry into the VM (one handler run),
    /// counted in resolved paths: N host.fs calls in one run cost roots + N; the next run, a run after a
    /// throw and a second VM entered from inside the first each resolve their own roots.
    func testRootsResolvedOncePerHandlerRun() throws {
        var resolved = 0
        let prefix = home
        SecretPaths.onCanonical = { if $0.hasPrefix(prefix) { resolved += 1 } }
        let roots = SecretPaths.listed.count
        try write("plain.txt", "plain")
        let lua = try host(system: false), other = try host(system: false)
        let script = """
        function many(base)
            local seen = 0
            for i = 1, 20 do if host.fs.exists(base .. "/f" .. i) then seen = seen + 1 end end
            if host.fs.read(base .. "/plain.txt") ~= nil then seen = seen + 1 end
            if host.fs.read(base .. "/.ssh/id_test") ~= nil then seen = seen + 100 end
            host.fs.list_dirs(base)
            host.fs.attributes(base .. "/plain.txt")
            return tostring(seen)
        end
        function boom(base) host.fs.exists(base .. "/plain.txt"); error("handler failed") end
        function cross(base)
            host.fs.exists(base .. "/a")
            call_other()
            host.fs.exists(base .. "/b")
            return "ok"
        end
        """
        try lua.run(script)
        try other.run(script)
        let calls = 24
        resolved = 0
        XCTAssertEqual(try lua.callGlobal("many", [home]), "1")
        XCTAssertEqual(resolved, roots + calls, "one handler run")
        resolved = 0
        XCTAssertEqual(try lua.callGlobal("many", [home]), "1")
        XCTAssertEqual(resolved, roots + calls, "the next run resolves the roots again")
        resolved = 0
        XCTAssertThrowsError(try lua.callGlobal("boom", [home]))
        XCTAssertEqual(resolved, roots + 1, "a run that throws")
        resolved = 0
        XCTAssertEqual(try lua.callGlobal("many", [home]), "1")
        XCTAssertEqual(resolved, roots + calls, "a run after a throw resolves the roots again")
        let base = home
        var otherCost = 0
        lua.register("call_other") { _ in
            let before = resolved
            XCTAssertEqual(try? other.callGlobal("many", [base]), "1")
            otherCost = resolved - before
            return 0
        }
        resolved = 0
        XCTAssertEqual(try lua.callGlobal("cross", [home]), "ok")
        XCTAssertEqual(otherCost, roots + calls, "a second VM entered mid-run never sees the first VM's roots")
        XCTAssertEqual(resolved, 2 * roots + 2 + calls, "and the first VM keeps its own across that call")
    }

    /// The data volume's firmlink spelling of the same home: /System/Volumes/Data + its realpath.
    func testFirmlinkSpellingIsRefused() throws {
        let real = try XCTUnwrap(KitPOSIXFileReader().realPath(home))
        let file = "/System/Volumes/Data" + real + "/.ssh/id_test"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file), "no /System/Volumes/Data spelling on this host")
        XCTAssertTrue(SecretPaths.denies(file))
        XCTAssertEqual(try call(try host(system: false), "rd", file), "NIL")
        XCTAssertEqual(try call(try host(system: true), "rd", file), "fake:.ssh/id_test")
    }

    /// The by-inode spelling /.vol/<st_dev>/<inode>/<rest>: inode 2 is the volume root, so any
    /// extension can build /.vol/<dev>/2/<absolute path>. realpath(3) returns NULL for it and for
    /// its folder, so only canonical()'s last branch (existingPrefixResolved) resolves it.
    func testByInodeSpellingIsRefused() throws {
        let real = try XCTUnwrap(KitPOSIXFileReader().realPath(home))
        let ssh = try FileManager.default.attributesOfItem(atPath: real + "/.ssh")
        let dev = try XCTUnwrap(ssh[.systemNumber] as? NSNumber), ino = try XCTUnwrap(ssh[.systemFileNumber] as? NSNumber)
        let byRoot = "/.vol/\(dev)/2" + real, byFolder = "/.vol/\(dev)/\(ino)"
        try write("notes/a.txt", "plain:a")
        try XCTSkipUnless((try? Data(contentsOf: URL(fileURLWithPath: byRoot + "/notes/a.txt"))) != nil,
                          "the /.vol spelling of the temp home cannot be opened on this host")
        let automation = try host(system: false), system = try host(system: true)
        for file in [byRoot + "/.ssh/id_test", byFolder + "/id_test"] {
            XCTAssertTrue(SecretPaths.denies(file), file)
            XCTAssertEqual(try call(automation, "rd", file), "NIL", file)
            XCTAssertEqual(try call(automation, "ex", file), "false", file)
            XCTAssertEqual(try call(automation, "at", file), "false|nil", file)
            XCTAssertEqual(try call(system, "rd", file), "fake:.ssh/id_test", file)
        }
        for missing in [byRoot + "/.ssh/not-there", byFolder + "/not-there", byRoot + "/.ssh/new-dir/x", byFolder + "/new-dir/x"] {
            XCTAssertTrue(SecretPaths.denies(missing), missing)
            XCTAssertTrue(ExtensionFSWatch.visiblePaths([missing], hideSecrets: true) == nil, missing)
        }
        XCTAssertEqual(try call(automation, "ls", byFolder), "")
        XCTAssertNotEqual(try call(system, "ls", byFolder), "", "the folder lists at the system tier, so the empty answer is the refusal")
        // Not every /.vol path is refused: a plain file by the same spelling still reads.
        XCTAssertEqual(try call(automation, "rd", byRoot + "/notes/a.txt"), "plain:a")
    }

    /// One level missing goes through realpath of the folder. Two levels missing go through
    /// NSURL.resolvingSymlinksInPath, which drops /private while realpath spells the root
    /// /private/var/...: without the /private fold they never match (a home under /var: every
    /// test home, and /var/root).
    func testMissingFileBelowExistingSecretFolderIsRefused() {
        XCTAssertTrue(SecretPaths.denies(path(".ssh/not-yet-there")))
        XCTAssertTrue(ExtensionFSWatch.visiblePaths([path(".ssh/just-deleted")], hideSecrets: true) == nil)
        XCTAssertTrue(SecretPaths.denies(path(".ssh/new-dir/not-yet-there")))
        XCTAssertTrue(ExtensionFSWatch.visiblePaths([path(".aws/sso/cache/gone.json")], hideSecrets: true) == nil)
    }

    func testFilesSearchThroughTheBridgeDropsSecretHitsBelowSystemTier() throws {
        let plain = path("notes/a.txt")
        let hits = #"[{"name":"vault.json","path":"\#(path(".ccpool/vault.json"))"},{"name":"a.txt","path":"\#(plain)"}]"#
        let svcBelow = DiskServices(), svcSystem = DiskServices()
        svcBelow.hits = hits
        svcSystem.hits = hits
        let below = try host(system: false, svcBelow), system = try host(system: true, svcSystem)
        let script = """
        function fs(q)
            local out = {}
            for _, h in ipairs(host.files.search{ name = q }) do out[#out + 1] = h.name end
            return table.concat(out, ",")
        end
        """
        try below.run(script)
        try system.run(script)
        // The bridge blocks its thread on the async search: call it off main.
        var answers: [String] = []
        let done = expectation(description: "search off main")
        DispatchQueue.global().async {
            answers = [below, system].map { lua in (try? lua.callGlobal("fs", ["any"])) ?? "<no answer>" }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(answers.first, "a.txt")
        XCTAssertEqual(answers.last, "vault.json,a.txt")
    }

    /// Prints the cost of 5,000 paths through visiblePaths (one matcher per batch) against one
    /// `denies` per path (the round 1 shape). Measured, never asserted on time.
    func testVisiblePathsBatchTiming() throws {
        try FileManager.default.createDirectory(atPath: path("busy"), withIntermediateDirectories: true)
        var paths: [String] = []
        for i in 0..<5_000 {
            let p = path("busy/f\(i).txt")
            if i < 500 { try Data().write(to: URL(fileURLWithPath: p)) }
            paths.append(i % 100 == 0 ? path(".ssh/id_test") : p)
        }
        // The per-path shape (one `denies` each, round 1) on the first 500 only: it is ~6x slower.
        let t0 = Date()
        let perPath = paths.prefix(500).filter { !SecretPaths.denies($0) }
        let t1 = Date()
        let batch = ExtensionFSWatch.visiblePaths(paths, hideSecrets: true)
        let t2 = Date()
        XCTAssertEqual(batch?.count, 4_950)
        XCTAssertEqual(batch.map { Array($0.prefix(perPath.count)) }, perPath)
        print(String(format: "#921 timing: per-path denies 500 paths %.1f ms; visiblePaths batch 5000 paths %.1f ms",
                     t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000))
    }

    func testListDirsOfSecretFolderIsEmptyBelowSystemTier() throws {
        try FileManager.default.createDirectory(atPath: path(".ssh/sub"), withIntermediateDirectories: true)
        XCTAssertEqual(try call(try host(system: false), "ls", path(".ssh")), "")
        XCTAssertEqual(try call(try host(system: true), "ls", path(".ssh")), "id_test,sub")
    }

    /// #1201 (R921-3): below the system tier a listing of a visible folder does not name a secret child
    /// (also through a symlinked folder, another letter case and the CCPOOL_HOME folder); the system tier
    /// names them. The children are judged below the resolved folder: one listing costs the roots and the
    /// folder, for any number of children (counted in resolved paths, never timed).
    func testListDirsOfVisibleFolderNamesNoSecretChild() throws {
        var resolved = 0
        let prefix = home
        SecretPaths.onCanonical = { if $0.hasPrefix(prefix) { resolved += 1 } }
        let roots = SecretPaths.listed.count
        for i in 0..<300 {
            try FileManager.default.createDirectory(atPath: path("Library/f\(i)"), withIntermediateDirectories: true)
        }
        try link("notes/cfg", to: ".config")
        let automation = try host(system: false), system = try host(system: true)
        resolved = 0
        XCTAssertEqual(try call(automation, "ls", path(".config")), "prosper")
        XCTAssertEqual(resolved, roots + 1, "one listing: the roots and the folder, nothing per child")
        let library = try call(automation, "ls", path("Library")).split(separator: ",")
        XCTAssertEqual(library.count, 300)
        XCTAssertFalse(library.contains("Keychains"))
        XCTAssertEqual(resolved, 2 * (roots + 1), "301 children cost no resolved path either")
        XCTAssertEqual(try call(automation, "ls", path("notes/cfg")), "prosper")
        XCTAssertEqual(try call(automation, "ls", home), ".claude,.config,.docker,Library,notes")
        XCTAssertEqual(try call(system, "ls", path(".config")), "gcloud,gh,mcpbridge,prosper")
        XCTAssertTrue(try call(system, "ls", path("Library")).split(separator: ",").contains("Keychains"))
        let caseSensitive = try URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        if caseSensitive != true { XCTAssertEqual(try call(automation, "ls", path(".CONFIG")), "prosper") }
        let real = try XCTUnwrap(KitPOSIXFileReader().realPath(home))
        if FileManager.default.fileExists(atPath: "/System/Volumes/Data" + real + "/.config") {
            XCTAssertEqual(try call(automation, "ls", "/System/Volumes/Data" + real + "/.config"), "prosper")
        }
        try write("vaults/pool/vault.json", "fake:pool")
        try FileManager.default.createDirectory(atPath: path("vaults/plain"), withIntermediateDirectories: true)
        SecretPaths.environment = ["CCPOOL_HOME": path("vaults/pool")]
        XCTAssertEqual(try call(automation, "ls", path("vaults")), "plain")
        XCTAssertEqual(try call(system, "ls", path("vaults")), "plain,pool")
    }

    /// list_dirs judges a child by its name below the resolved folder. That is exact because the live
    /// listing names real folders only: no symlink, no hidden name, no file. This row turns red if it changes.
    func testLiveListingNamesRealFoldersOnly() throws {
        for dir in ["tree/real", "tree/.hidden"] {
            try FileManager.default.createDirectory(atPath: path(dir), withIntermediateDirectories: true)
        }
        try write("tree/file.txt", "plain")
        try link("tree/link", to: "tree/real")
        XCTAssertEqual(LiveExtensionHostServices.shared.listDirectories(path("tree")), ["real"])
    }

    func testSymlinkFromAllowedFolderIntoSecretOneIsRefused() throws {
        try link("notes/dir", to: ".ssh")
        try link("notes/key", to: ".claude/settings.json")
        let automation = try host(system: false), system = try host(system: true)
        XCTAssertEqual(try call(automation, "rd", path("notes/dir/id_test")), "NIL")
        XCTAssertEqual(try call(automation, "rd", path("notes/key")), "NIL")
        XCTAssertEqual(try call(automation, "ls", path("notes/dir")), "")
        XCTAssertEqual(try call(system, "rd", path("notes/dir/id_test")), "fake:.ssh/id_test")
        XCTAssertEqual(try call(system, "rd", path("notes/key")), "fake:.claude/settings.json")
    }

    func testDotDotPathIntoSecretFolderIsRefused() throws {
        try FileManager.default.createDirectory(atPath: path("notes"), withIntermediateDirectories: true)
        // notes/lib -> Library, so notes/lib/.. is the home dir for the kernel (lexically it is notes).
        try link("notes/lib", to: "Library")
        let automation = try host(system: false)
        XCTAssertEqual(try call(automation, "rd", path("notes/../.ssh/id_test")), "NIL")
        XCTAssertEqual(try call(automation, "rd", path("notes/lib/../.ssh/id_test")), "NIL")
        XCTAssertEqual(try call(try host(system: true), "rd", path("notes/lib/../.ssh/id_test")), "fake:.ssh/id_test")
    }

    func testDifferentLetterCaseIsRefused() throws {
        let caseSensitive = try URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        try XCTSkipIf(caseSensitive == true, "the temp volume is case-sensitive")
        XCTAssertEqual(try call(try host(system: false), "rd", path(".SSH/ID_TEST")), "NIL")
        XCTAssertEqual(try call(try host(system: false), "rd", path(".Claude/Settings.JSON")), "NIL")
        XCTAssertEqual(try call(try host(system: true), "rd", path(".SSH/ID_TEST")), "fake:.ssh/id_test")
        // A listed path that does not exist yet: no realpath, so only the case fold can match it.
        try FileManager.default.removeItem(atPath: path(".ccpool"))
        XCTAssertTrue(SecretPaths.denies(path(".CCPOOL/vault.json")))
        XCTAssertTrue(SecretPaths.Matcher(roots: ["/Users/example/.ssh"], caseInsensitive: true).denies("/Users/example/.SSH/a"))
        XCTAssertFalse(SecretPaths.Matcher(roots: ["/Users/example/.ssh"], caseInsensitive: false).denies("/Users/example/.SSH/a"))
    }

    func testTrailingSlashIsRefused() throws {
        let automation = try host(system: false)
        XCTAssertEqual(try call(automation, "ex", path(".ssh/")), "false")
        XCTAssertEqual(try call(automation, "ls", path("Library/Keychains/")), "")
        XCTAssertTrue(SecretPaths.denies(path(".claude/settings.json/")))
        XCTAssertEqual(try call(try host(system: true), "ex", path(".ssh/")), "true")
    }

    func testSiblingSharingOnlyAPrefixIsAllowed() throws {
        let siblings = [".sshfoo/key", ".ccpool-old/vault.json", ".claude/settings.json.bak",
                        "Library/KeychainsBackup/x", ".config/mcpbridge2/config.json",
                        ".netrc.bak", ".claude.json.old", ".config/prosper/device.key.txt", ".awsx/config"]
        for s in siblings { try write(s, "plain:" + s) }
        let automation = try host(system: false)
        for s in siblings {
            XCTAssertEqual(try call(automation, "rd", path(s)), "plain:" + s, s)
        }
        XCTAssertFalse(SecretPaths.isAtOrBelow("/Users/example/.sshfoo", "/Users/example/.ssh"))
    }

    func testRefusedAnswerEqualsMissingAnswer() throws {
        let automation = try host(system: false)
        let secret = path(".ssh/id_test"), missing = path("nothing-here/id_test")
        for fn in ["rd", "ex", "at", "ls"] {
            XCTAssertEqual(try call(automation, fn, secret), try call(automation, fn, missing), fn)
        }
        XCTAssertEqual(try call(automation, "ls", path(".ssh")), try call(automation, "ls", path("nothing-here")))
    }

    func testWatchOfSecretPathIsDroppedBelowSystemTier() throws {
        let below = DiskServices(), sys = DiskServices()
        _ = try call(try host(system: false, below), "wt", path(".ssh"))
        _ = try call(try host(system: false, below), "wt", home)
        _ = try call(try host(system: true, sys), "wt", path(".ssh"))
        XCTAssertEqual(below.watches.map { w in w.path }, [home])
        XCTAssertEqual(below.watches.first?.hideSecrets, true)
        XCTAssertEqual(sys.watches.map { w in w.path }, [path(".ssh")])
        XCTAssertEqual(sys.watches.first?.hideSecrets, false)
    }

    func testWatchPayloadDropsSecretPaths() {
        let secret = path(".ssh/id_test"), plain = path("notes/a.txt")
        XCTAssertEqual(ExtensionFSWatch.visiblePaths([secret, plain], hideSecrets: true), [plain])
        XCTAssertTrue(ExtensionFSWatch.visiblePaths([secret], hideSecrets: true) == nil)
        XCTAssertEqual(ExtensionFSWatch.visiblePaths([secret, plain], hideSecrets: false), [secret, plain])
        XCTAssertEqual(ExtensionFSWatch.visiblePaths([], hideSecrets: true), [])
    }

    func testFilesSearchHitsDropSecretPaths() throws {
        let plain = path("notes/a.txt")
        let json = #"[{"name":"vault.json","path":"\#(path(".ccpool/vault.json"))"},{"name":"a.txt","path":"\#(plain)"}]"#
        let kept = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(SecretPaths.filterHits(json).utf8)) as? [[String: Any]])
        XCTAssertEqual(kept.compactMap { $0["path"] as? String }, [plain])
        let clean = #"[{"name":"a.txt","path":"\#(plain)"}]"#
        XCTAssertEqual(SecretPaths.filterHits(clean), clean)
        XCTAssertEqual(SecretPaths.filterHits("not json"), "[]")
    }
}
