import Darwin
import os
import XCTest
@testable import ProsperApp

/// #781: Always allow and the sidekick pattern written into dch's config, so dch 1.30.0+ (the full build)
/// answers prompts and the island's engine stands down. Every config file lives in the row's own tempDir();
/// the version and build of dch are injected fakes; no row runs dch, reads a real screen or sends a real key.
final class DchConfigWriterTests: XCTestCase {

    // MARK: - dch's reading of the file (dch.c dch_config_get, dch_config_bool), for the rows

    /// The value of the LAST line setting `key`, as dch reads it; nil when no line sets it.
    private static func dchValue(_ file: Data, _ key: String) -> String? {
        var v: String?
        for line in file.split(separator: 0x0A, omittingEmptySubsequences: false) where DchConfigWriter.setsKey(line, key) {
            v = String(decoding: line.drop { $0 != 0x3D }.dropFirst(), as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        }
        return v
    }

    private static func dchAllows(_ file: Data) -> Bool {
        ["true", "1", "yes", "on"].contains(dchValue(file, "auto_allow")?.lowercased() ?? "")
    }

    /// `dch --config`'s listing of `path`: the path, then every key normalised.
    private static func listing(_ path: String) -> String {
        let d = FileManager.default.contents(atPath: path) ?? Data()
        return "\(path)\nauto_allow = \(dchAllows(d))\nsidekick_pattern = \(dchValue(d, "sidekick_pattern") ?? "-qa")\n"
    }

    private func render(_ old: String, _ on: Bool = true, _ p: String = "-qa") -> String {
        String(decoding: DchConfigWriter.render(Data(old.utf8), autoAllow: on, pattern: p), as: UTF8.self)
    }

    // MARK: - The pure core

    func testAnEmptyFileGetsBothKeys() {
        XCTAssertEqual(render(""), "auto_allow = true\nsidekick_pattern = -qa\n")
        XCTAssertEqual(render("", false, ""), "auto_allow = false\nsidekick_pattern = \n")
    }

    func testEveryLineItDoesNotOwnIsKeptInPlace() {
        let old = "# dch config, by hand\npicker_sort = name\n\n  # sidekick_pattern = x\nauto_allow = false\n"
            + "remote_hosts = a=1,b\nsidekick_pattern = -qa\nxray_ring = 2M\n"
        XCTAssertEqual(render(old, true, "-(qa|reviewer)$"),
                       "# dch config, by hand\npicker_sort = name\n\n  # sidekick_pattern = x\nauto_allow = true\n"
                       + "remote_hosts = a=1,b\nsidekick_pattern = -(qa|reviewer)$\nxray_ring = 2M\n")
    }

    /// dch: the last line of a key wins; its own writer replaces the first and drops the later ones. So does Prosper.
    func testTheSameKeyTwiceKeepsOneLineWithTheNewValue() {
        let out = render("auto_allow = true\npicker_sort = name\nauto_allow = false\n\tauto_allow=yes\n", false, "")
        XCTAssertEqual(out, "auto_allow = false\npicker_sort = name\nsidekick_pattern = \n")
        XCTAssertFalse(Self.dchAllows(Data(out.utf8)))
    }

    func testALastLineWithoutANewlineGetsOne() {
        XCTAssertEqual(render("picker_sort = name"), "picker_sort = name\nauto_allow = true\nsidekick_pattern = -qa\n")
        XCTAssertEqual(render("auto_allow = false"), "auto_allow = true\nsidekick_pattern = -qa\n")
    }

    /// CRLF lines are kept as they are; the lines Prosper writes end in LF, as dch's own writer's do (dch trims the CR).
    func testCRLFLinesAreKept() {
        let out = render("picker_sort = name\r\nauto_allow = false\r\n")
        XCTAssertEqual(out, "picker_sort = name\r\nauto_allow = true\nsidekick_pattern = -qa\n")
        XCTAssertTrue(Self.dchAllows(Data(out.utf8)))
    }

    func testBytesThatAreNotUTF8AreKept() {
        let old = Data([0x23, 0xFF, 0xFE, 0x0A, 0x78, 0x20, 0x3D, 0x20, 0xC3, 0x28, 0x0A])
        let out = DchConfigWriter.render(old, autoAllow: true, pattern: "-qa")
        XCTAssertEqual(out, old + Data("auto_allow = true\nsidekick_pattern = -qa\n".utf8))
    }

    /// dch's config_line: spaces or tabs, the exact key, spaces or tabs, '='. Nothing else is the key.
    func testOnlyDchsKeyLinesAreOwned() {
        let old = "auto_allowed = true\n#auto_allow = true\nxauto_allow = true\nauto_allow true\n"
            + " \t auto_allow \t= \tyes\nsidekick_patterns = x\n"
        XCTAssertEqual(render(old, false),
                       "auto_allowed = true\n#auto_allow = true\nxauto_allow = true\nauto_allow true\n"
                       + "auto_allow = false\nsidekick_patterns = x\nsidekick_pattern = -qa\n")
    }

    /// A newline, a CR or another control character in the pattern never starts a line; neither does a
    /// pattern too long for dch's 256-byte buffer. An '=' or a '#' is part of the value.
    func testANewlineInThePatternNeverAddsALine() {
        for p in ["-qa\nauto_allow = true", "-qa\rauto_allow = true", "-qa\r\n", "\nauto_allow = true", "-qa\u{7F}",
                  String(repeating: "a", count: 256), String(repeating: "a", count: 10_000)] {
            let out = DchConfigWriter.render(Data(), autoAllow: false, pattern: p)
            XCTAssertEqual(String(decoding: out, as: UTF8.self), "auto_allow = false\nsidekick_pattern = \n", p.debugDescription)
            XCTAssertEqual(out.filter { $0 == 0x0A }.count, 2, p.debugDescription)
            XCTAssertFalse(Self.dchAllows(out), p.debugDescription)
        }
        let max = String(repeating: "a", count: DchConfigWriter.maxPatternBytes)
        XCTAssertEqual(render("", true, max), "auto_allow = true\nsidekick_pattern = \(max)\n")
        let out = Data(render("", true, "build=1#qa").utf8)
        XCTAssertEqual(Self.dchValue(out, "sidekick_pattern"), "build=1#qa", "dch reads it back whole")
    }

    func testRenderingTwiceChangesNothing() {
        for old in ["", "picker_sort = name", "auto_allow = true\r\nauto_allow = no\n# c\n", "sidekick_pattern = x\n\n"] {
            let once = DchConfigWriter.render(Data(old.utf8), autoAllow: true, pattern: "-qa")
            XCTAssertEqual(DchConfigWriter.render(once, autoAllow: true, pattern: "-qa"), once, old.debugDescription)
        }
    }

    // MARK: - The pattern: ICU on the Mac and the phone, POSIX ERE in dch

    private static let portable = ["-qa", "-(qa|reviewer)$", "^review", "qa|test", "build=1", "#qa", "v1\\.2",
                                   "-qa+", "^(api|web)-qa$", "x?-qa", "a b", "\\(qa\\)",
                                   // #1172: bracket sets of letters, digits and "_", ranges of one kind
                                   "[0-9]", "-qa[0-9]+$", "^[a-z]+-qa$", "build-[0-9][0-9]", "[A-Z_]x", "v[1-3]\\.[0-9]",
                                   "-(qa|r[0-9])$", "[a-cx-z]+-qa", "[Q]A$"]

    func testAPortablePatternIsWrittenAsTheIslandUsesIt() {
        for p in Self.portable { XCTAssertEqual(DchConfigWriter.sidekickValue(p), p, p) }
        XCTAssertEqual(DchConfigWriter.sidekickValue("  -qa \n"), "-qa", "trimmed as the island trims it")
        let max = String(repeating: "a", count: DchConfigWriter.maxPatternBytes)
        XCTAssertEqual(DchConfigWriter.sidekickValue(max), max)
    }

    /// Anything outside the shared subset is written empty: dch's picker shows no Sidekicks tab, never a
    /// different split. The island keeps its own pattern.
    func testAPatternDchWouldReadDifferentlyIsWrittenEmpty() {
        let cases = ["", "   ", "\\d+", "a.b", "(?i)qa", "a{2}", "(qa)+", "a*?", "a++", "|qa", "qa|", "a||b",
                     "()", "(|a)", "(a|)", "(qa", "qa)", "*qa", "^*", "\u{E9}-qa", "\\bqa", "\\-qa", "qa\\", "a*", "^", "x|^",
                     // QA R781-1: the empty-branch guards on patterns that do NOT match "" (so only portable() decides)
                     "x(|a)", "x(a|)y", "x(a||b)",
                     // #1172: "." and every set outside setMembers and one-kind ranges
                     "-qa.*", "x.+y", "x[^0-9]y", "x[]y", "x[a-]y", "x[-a]y", "x[a-c-e]y", "x[z-a]y", "x[a-Z]y", "x[0-z]y",
                     "x[_-a]y", "x[[:digit:]]y", "x[\\d]y", "x[a&&b]y", "x[a b]y", "x[a", "x]a", "x[a]]", "x[\u{E9}]y", "[0-9]*",
                     "-qa\nx", "-qa\rx", "q\ta", String(repeating: "a", count: DchConfigWriter.maxPatternBytes + 1),
                     String(repeating: "a", count: 10_000), String(repeating: "(", count: 10_000)]
        for p in cases { XCTAssertEqual(DchConfigWriter.sidekickValue(p), "", p.debugDescription) }
    }

    /// The proof on the machine: every portable pattern compiled the way dch compiles it (regcomp, extended,
    /// ignoring case) splits ASCII names exactly as the island's ICU split does, and never matches "".
    /// #1172: in the C locale dch runs in, and on non-ASCII names too (none holding K U+212A or ſ U+017F, the
    /// case-folding limit testWhatIsLeftOutReadsDifferently pins).
    func testEveryPortablePatternSplitsLikeDchsRegex() {
        let restore = Self.cLocale()
        defer { restore() }
        let names = ["api", "api-qa", "API-QA", "web-reviewer", "reviewer-web", "qa", "build=1", "#qa", "v1.2", "v1x2",
                     "test", "x-qaa", "a b", "-qa", "web-qa", "(qa)", "QA|TEST", "xx-qa",
                     "build-12", "build-1", "Ax", "_x", "bx", "v2.5", "v4.5", "-r7", "web-r7", "c-qa", "m-qa", "QA", "xa", "z-QA",
                     "\u{E9}-qa", "\u{41F}\u{440}\u{43E}\u{441}\u{43F}\u{435}\u{440}-qa", "\u{1F600}-qa", "\u{65E5}\u{672C}-qa1",
                     "\u{E4}1", "x\u{661}-qa", "\u{FF51}\u{FF41}", "build-\u{663}\u{663}", "-qa\u{E9}", "API-QA-\u{FC}", "\u{416}",
                     "v1\u{66B}2", "\u{C9}-QA", "build-\u{FF11}\u{FF12}"]
        for p in Self.portable {
            var re = regex_t()
            guard regcomp(&re, p, REG_EXTENDED | REG_ICASE | REG_NOSUB) == 0 else { XCTFail("\(p): not ERE"); continue }
            defer { regfree(&re) }
            let empty = regexec(&re, "", 0, nil, 0)
            XCTAssertNotEqual(empty, 0, "\(p): dch would take it as text")
            for n in names {
                let s = AgentSession(key: AgentSessionKey(dir: "/d", name: n), alias: "", activity: 0, state: .idle, agents: 0)
                let dch = regexec(&re, n, 0, nil, 0) == 0
                let island = !AgentIsland.split([s], pattern: p).sidekicks.isEmpty
                XCTAssertEqual(island, dch, "\(p) on \(n)")
            }
        }
    }

    // MARK: - The path and the gate

    func testThePathIsDchsRule() {
        let home = "/Users/example"
        XCTAssertEqual(DchConfigWriter.defaultPath(env: ["DCH_CONFIG": "/Users/example/dch.conf", "XDG_CONFIG_HOME": "/x",
                                                         "HOME": home]), "/Users/example/dch.conf")
        XCTAssertEqual(DchConfigWriter.defaultPath(env: ["DCH_CONFIG": "", "XDG_CONFIG_HOME": "/Users/example/.xdg",
                                                         "HOME": home]), "/Users/example/.xdg/dch/config")
        XCTAssertEqual(DchConfigWriter.defaultPath(env: ["XDG_CONFIG_HOME": "", "HOME": home]),
                       "/Users/example/.config/dch/config")
        XCTAssertNil(DchConfigWriter.defaultPath(env: ["HOME": ""]))
        XCTAssertNil(DchConfigWriter.defaultPath(env: [:]))
    }

    func testTheHandOffGateIsVersionAndTheFullBuild() {
        var asked = 0
        func value(_ toggle: Bool, _ v: [Int], _ build: String?) -> Bool? {
            DchConfigWriter.autoAllow(toggle: toggle, dch: DchCommand.Binary(path: "/Users/example/bin/dch", version: v)) { _ in
                asked += 1
                return build
            }
        }
        XCTAssertEqual(value(true, [1, 30, 0], "full"), true)
        XCTAssertEqual(value(true, [2, 0], "full"), true)
        XCTAssertEqual(value(true, [1, 30, 0], "lite"), false)
        XCTAssertEqual(value(true, [1, 30, 0], ""), false)
        XCTAssertEqual(value(true, [1, 30, 0], nil), nil, "a timed-out --build writes nothing")
        XCTAssertEqual(asked, 5)
        XCTAssertEqual(value(true, [1, 29, 2], "full"), false)
        XCTAssertEqual(value(true, [1, 29, 99], "full"), false)
        XCTAssertEqual(value(false, [1, 30, 0], "full"), false)
        XCTAssertEqual(asked, 5, "--build asked only past the version, and only with the toggle on")
    }

    // MARK: - The file layer, in tempDir()

    private func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    private func inode(_ path: String) -> UInt64 {
        var st = stat()
        return stat(path, &st) == 0 ? UInt64(st.st_ino) : 0
    }

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    func testAMissingFileIsCreatedWithItsFolder() {
        let dir = tempDir(), path = dir.appendingPathComponent("xdg/dch/config").path
        XCTAssertEqual(DchConfigWriter.write(path: path, autoAllow: true, pattern: "-qa"), .written)
        XCTAssertEqual(read(path), "auto_allow = true\nsidekick_pattern = -qa\n")
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("xdg/dch").path)
        XCTAssertEqual((attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// A rename, never a write in place: a hard link to the old file still holds the old bytes, the mode is
    /// kept, no temporary file is left, and the same values again write nothing.
    func testTheWriteIsAtomicAndKeepsTheMode() {
        let dir = tempDir(), path = dir.appendingPathComponent("config").path, keep = dir.appendingPathComponent("keep").path
        let old = "picker_sort = name\nauto_allow = false\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(old.utf8), attributes: [.posixPermissions: 0o600]))
        XCTAssertEqual(link(path, keep), 0)
        XCTAssertEqual(DchConfigWriter.write(path: path, autoAllow: true, pattern: "-qa"), .written)
        XCTAssertEqual(read(keep), old, "the old file was replaced, not rewritten")
        XCTAssertEqual(read(path), "picker_sort = name\nauto_allow = true\nsidekick_pattern = -qa\n")
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(names(dir), ["config", "keep"])
        let ino = inode(path)
        XCTAssertEqual(DchConfigWriter.write(path: path, autoAllow: true, pattern: "-qa"), .unchanged)
        XCTAssertEqual(inode(path), ino)
    }

    /// #781 r2: a file over maxFileBytes is refused before it is read and left byte for byte; one at the bound is written.
    /// #1172: of short "#" lines, since one line over dchLineBytes is refused on its own.
    func testAFileOverTheBoundIsRefusedAndKept() {
        let dir = tempDir(), over = dir.appendingPathComponent("over").path, at = dir.appendingPathComponent("at").path
        var big = Data(repeating: 0x23, count: DchConfigWriter.maxFileBytes)
        for i in stride(from: 1, to: big.count, by: 2) { big[i] = 0x0A }   // "#\n" lines, exactly maxFileBytes
        big.append(0x0A)
        XCTAssertTrue(FileManager.default.createFile(atPath: over, contents: big))
        guard case .refused = DchConfigWriter.write(path: over, autoAllow: true, pattern: "-qa") else {
            return XCTFail("over the bound: written")
        }
        XCTAssertTrue(FileManager.default.contents(atPath: over) == big, "over the bound: byte for byte")
        XCTAssertEqual(names(dir), ["over"])
        big.removeLast()
        XCTAssertEqual(big.count, DchConfigWriter.maxFileBytes)
        XCTAssertTrue(FileManager.default.createFile(atPath: at, contents: big))
        XCTAssertEqual(DchConfigWriter.write(path: at, autoAllow: true, pattern: "-qa"), .written)
        let tail = Data("auto_allow = true\nsidekick_pattern = -qa\n".utf8)
        XCTAssertTrue(FileManager.default.contents(atPath: at) == big + tail, "at the bound: written, the line kept")
    }

    /// As dch's own writer: the link's target is replaced, the link stays.
    func testASymbolicLinkIsFollowed() throws {
        let dir = tempDir(), real = dir.appendingPathComponent("dotfiles/config").path, path = dir.appendingPathComponent("config").path
        try FileManager.default.createDirectory(atPath: dir.appendingPathComponent("dotfiles").path, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: real, contents: Data("# mine\n".utf8)))
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: real)
        XCTAssertEqual(DchConfigWriter.write(path: path, autoAllow: false, pattern: "-qa"), .written)
        XCTAssertEqual(read(real), "# mine\nauto_allow = false\nsidekick_pattern = -qa\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path), real)
        XCTAssertEqual(names(dir.appendingPathComponent("dotfiles")), ["config"])
    }

    /// A link to nothing, a folder, an unreadable file, an unwritable folder, a path through a file: nothing changes.
    func testWhatCannotBeReadOrWrittenChangesNothing() throws {
        let dir = tempDir(), fm = FileManager.default
        func refused(_ path: String, _ why: String) {
            guard case .refused = DchConfigWriter.write(path: path, autoAllow: true, pattern: "-qa") else {
                return XCTFail("\(why): written")
            }
        }
        let dangling = dir.appendingPathComponent("dangling").path
        try fm.createSymbolicLink(atPath: dangling, withDestinationPath: dir.appendingPathComponent("nowhere").path)
        refused(dangling, "a link to nothing")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dangling), dir.appendingPathComponent("nowhere").path)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("nowhere").path))

        let folder = dir.appendingPathComponent("folder").path
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        refused(folder, "a folder")
        XCTAssertEqual(names(URL(fileURLWithPath: folder)), [])

        let locked = dir.appendingPathComponent("locked").path
        XCTAssertTrue(fm.createFile(atPath: locked, contents: Data("# mine\n".utf8), attributes: [.posixPermissions: 0o000]))
        addTeardownBlock { chmod(locked, 0o600) }
        refused(locked, "an unreadable file")
        chmod(locked, 0o600)
        XCTAssertEqual(read(locked), "# mine\n")

        let ro = dir.appendingPathComponent("ro"), inRO = ro.appendingPathComponent("config").path
        try fm.createDirectory(at: ro, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: inRO, contents: Data("# mine\n".utf8)))
        chmod(ro.path, 0o500)
        addTeardownBlock { chmod(ro.path, 0o700) }
        refused(inRO, "an unwritable folder")
        chmod(ro.path, 0o700)
        XCTAssertEqual(read(inRO), "# mine\n")
        XCTAssertEqual(names(ro), ["config"], "no temporary file left")

        let file = dir.appendingPathComponent("file").path
        XCTAssertTrue(fm.createFile(atPath: file, contents: Data("x\n".utf8)))
        refused(file + "/config", "a path through a file")
        XCTAssertEqual(read(file), "x\n")
    }

    // MARK: - The controller: who answers, and every way in

    private static func dialog(_ body: String) -> String {
        [String(repeating: "─", count: 90), " Bash command", "", "   \(body)", "   Clean the build tree", "",
         " Do you want to proceed?", " ❯ 1. Yes", "   2. No, and tell Claude what to do differently (esc)"]
            .joined(separator: "\n")
    }
    private static let screen = dialog("rm -rf .build")
    private static let sid = "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab"
    private static let dir = "/Users/example/.local/state/dch"
    private let key = AgentSessionKey(dir: DchConfigWriterTests.dir, name: "api")

    /// The keystroke recorder: the plain permission prompt, dch saying blocked, keys recorded only.
    private final class FakeIO: @unchecked Sendable {
        let lock = NSLock()
        var sends: [String] = []
        var io: AgentPromptIO {
            AgentPromptIO(read: { _ in DchConfigWriterTests.screen }, status: { _ in "blocked" },
                          send: { _, d in self.lock.withLock { self.sends.append(d) } })
        }
        var sent: [String] { lock.withLock { sends } }
    }

    /// The installed dch, faked: version, `--build`, and `--config` listing the row's own file; calls recorded.
    private final class FakeDch: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        /// #1172: `--ls-json` per socket dir (nil: that list times out), and a `--config` that times out.
        var ls: [String: String] = [:]
        var configTimesOut = false
        func called() -> [[String]] { lock.withLock { calls } }
    }

    @MainActor private func controller(_ f: FakeIO, on: Bool, version: [Int]?, build: String?, config: String) -> (AgentIslandController, FakeDch) {
        let c = AgentIslandController(), d = FakeDch()
        c.io = f.io
        c.showsPanel = false
        c.store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        c.store?.expanded = true
        c.autoAllowOn = { on }
        c.now = { Date(timeIntervalSince1970: 1_000_000) }
        c.after = { _, _ in }   // the verify and stand-down timers are not fired here
        c.dchConfigPath = { config }
        c.controlDch = { version.map { DchCommand.Binary(path: "/Users/example/bin/dch", version: $0) } }
        c.runDch = { _, args, env in
            d.lock.withLock { d.calls.append(args) }
            if args == ["--build"] { return build.map { Data(($0 + "\n").utf8) } }
            if args == ["--config"] { return d.lock.withLock { d.configTimesOut } ? nil : Data(DchConfigWriterTests.listing(config).utf8) }
            if args == ["--ls-json"] { return d.lock.withLock { d.ls[env["DCH_SOCKET_DIR"] ?? ""] }.map { Data($0.utf8) } }
            return nil
        }
        return (c, d)
    }

    private func row(master: String, claude: String? = DchConfigWriterTests.sid) -> AgentSession {
        AgentSession(key: key, alias: "", activity: 1, state: .blocked, agents: 0, version: master, claudeSessionID: claude)
    }

    @MainActor private func tick(_ c: AgentIslandController, _ s: AgentSession) {
        c.store?.sessions = [s]
        c.checkAutoAllow()
        c.refreshCards()
    }

    @MainActor private func drain(_ c: AgentIslandController) {
        for _ in 0..<2 {
            c.queue.sync {}
            let hopped = expectation(description: "main hops")
            DispatchQueue.main.async { hopped.fulfill() }
            wait(for: [hopped], timeout: 5)
        }
    }

    /// The pattern the island splits by, in the XCTest store, put back after the row.
    private func usePattern(tabs: Bool, _ pattern: String) {
        let keys = ["agentIslandSidekickTabs", "agentIslandSidekickPattern", "agentIslandSidekickPatternUpdated", "agentIslandAutoAllow"]
        let saved = keys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        Preferences.agentIslandSidekickTabs = tabs
        Preferences.agentIslandSidekickPattern = pattern
        Preferences.agentIslandSidekickPatternUpdated = 0
    }

    /// The toggle x the installed dch: below the gate, at it with the lite build, at it with the full build (and
    /// a hand-set auto_allow before Prosper writes). dch answers when its master can (1.29.0+, full) and the file
    /// says true; the island answers when it sends the "1". Never both; nobody with the toggle off.
    @MainActor func testTheTwoEnginesAreNeverOnAtOnce() {
        usePattern(tabs: true, "-qa")
        // toggle, installed dch, build, the file before, then who answers: island, dch
        let cases: [(Bool, [Int], String, String, Bool, Bool)] = [
            (false, [1, 29, 2], "full", "", false, false),
            (false, [1, 30, 0], "lite", "", false, false),
            (false, [1, 30, 0], "full", "", false, false),
            (false, [1, 30, 0], "full", "auto_allow = true\n", false, false),
            (true, [1, 29, 2], "full", "", true, false),
            // round 5: a 1.29 master would answer hook and ask prompts, so Prosper's false wins over a hand-set true
            (true, [1, 29, 2], "full", "auto_allow = true\n", true, false),
            (true, [1, 30, 0], "lite", "", true, false),
            (true, [1, 30, 0], "full", "", false, true),
            (true, [1, 30, 0], "full", "auto_allow = false\n", false, true),
        ]
        for (on, v, build, before, island, dch) in cases {
            let name = "toggle \(on), dch \(DchCommand.versionString(v)) \(build), before \(before.debugDescription)"
            let file = tempDir("whoAnswers").appendingPathComponent("config").path
            if !before.isEmpty { FileManager.default.createFile(atPath: file, contents: Data(before.utf8)) }
            let f = FakeIO(), (c, _) = controller(f, on: on, version: v, build: build, config: file)
            c.syncDchConfig()
            c.queue.sync {}
            let written = FileManager.default.contents(atPath: file) ?? Data()
            XCTAssertEqual(String(decoding: written, as: UTF8.self), "auto_allow = \(dch)\nsidekick_pattern = -qa\n", name)
            let dchAnswers = build == "full" && DchCommand.isAtLeast(v, [1, 29, 0]) && Self.dchAllows(written)
            tick(c, row(master: DchCommand.versionString(v)))
            drain(c)
            let islandAnswers = f.sent == ["1"]
            XCTAssertEqual(islandAnswers, island, "\(name): the island")
            XCTAssertEqual(dchAnswers, dch, "\(name): dch")
            XCTAssertFalse(islandAnswers && dchAnswers, "\(name): never both")
        }
    }

    /// No dch found, or its --build timed out at the gate: the file is not touched.
    @MainActor func testNoDchOrAnUnknownBuildWritesNothing() {
        usePattern(tabs: true, "-qa")
        for (version, build) in [(nil, "full"), ([1, 30, 0], nil)] as [([Int]?, String?)] {
            let file = tempDir("unknown").appendingPathComponent("config").path
            FileManager.default.createFile(atPath: file, contents: Data("auto_allow = true\n".utf8))
            let (c, _) = controller(FakeIO(), on: true, version: version, build: build, config: file)
            c.syncDchConfig()
            c.queue.sync {}
            XCTAssertEqual(read(file), "auto_allow = true\n", "\(String(describing: version)) \(String(describing: build))")
        }
    }

    /// #781 r2: turning the toggle off writes false with no dch found: no version, no --build needed.
    @MainActor func testToggleOffWritesFalseWithNoDchFound() {
        usePattern(tabs: true, "-qa")
        let file = tempDir().appendingPathComponent("config").path
        FileManager.default.createFile(atPath: file, contents: Data("# mine\nauto_allow = true\n".utf8))
        let (c, d) = controller(FakeIO(), on: false, version: nil, build: "full", config: file)
        c.syncDchConfig()
        c.queue.sync {}
        XCTAssertEqual(read(file), "# mine\nauto_allow = false\nsidekick_pattern = -qa\n")
        XCTAssertEqual(d.called(), [], "no --build asked")
    }

    /// The toggle (Settings' hook), the pattern (Settings' edit and the phone's adopt, #760) and the tabs each
    /// write the file at once; the island's own pattern stays as typed.
    @MainActor func testEveryChangeWritesTheConfig() {
        usePattern(tabs: true, "-qa")
        Preferences.agentIslandAutoAllow = false
        let file = tempDir().appendingPathComponent("config").path
        let shared = AgentIslandController.shared
        let (c, _) = controller(FakeIO(), on: false, version: [1, 30, 0], build: "full", config: file)
        c.autoAllowOn = { Preferences.agentIslandAutoAllow }   // the real setting, as the shared controller has it
        func settle() { c.queue.sync {}; shared.queue.sync {} }

        AgentIslandPane.autoAllowToggled(true, c)
        settle()
        XCTAssertEqual(read(file), "auto_allow = true\nsidekick_pattern = -qa\n", "the toggle on")
        AgentIslandPane.autoAllowToggled(false, c)
        settle()
        XCTAssertEqual(read(file), "auto_allow = false\nsidekick_pattern = -qa\n", "the toggle off")

        // Settings and the phone tell the shared controller; it writes this row's file for the length of the row.
        let saved = (shared.dchConfigPath, shared.controlDch, shared.runDch, shared.autoAllowOn, shared.after)
        defer { (shared.dchConfigPath, shared.controlDch, shared.runDch, shared.autoAllowOn, shared.after) = saved }
        (shared.dchConfigPath, shared.controlDch, shared.runDch, shared.autoAllowOn) = (c.dchConfigPath, c.controlDch, c.runDch, c.autoAllowOn)
        shared.after = { _, fire in fire() }   // #1172: the settle timer, fired at once here

        AgentIslandListSection.patternEdited("-(qa|reviewer)$", now: Date(timeIntervalSince1970: 1_000_000))
        settle()
        XCTAssertEqual(read(file), "auto_allow = false\nsidekick_pattern = -(qa|reviewer)$\n", "Settings' edit")

        let adopted = expectation(description: "the phone's reply")
        DchSidekickOps().handle(Data(#"{"pattern":"\\d+-qa","updated":4102444800000}"#.utf8)) { _ in adopted.fulfill() }
        wait(for: [adopted], timeout: 5)
        settle()
        XCTAssertEqual(Preferences.agentIslandSidekickPattern, "\\d+-qa", "the island keeps the phone's pattern")
        XCTAssertEqual(read(file), "auto_allow = false\nsidekick_pattern = \n", "the phone's adopt: not portable, empty")

        Preferences.agentIslandSidekickPattern = "-qa"
        shared.rowDetailsChanged()
        settle()
        XCTAssertEqual(read(file), "auto_allow = false\nsidekick_pattern = -qa\n")
        Preferences.agentIslandSidekickTabs = false
        shared.rowDetailsChanged()
        settle()
        XCTAssertEqual(read(file), "auto_allow = false\nsidekick_pattern = \n", "tabs off: the island splits nothing, nor does dch")
    }

    /// Start: the island's build (reload) writes the config once.
    @MainActor func testStartWritesTheConfig() {
        usePattern(tabs: true, "-qa")
        let file = tempDir().appendingPathComponent("config").path
        let (c, _) = controller(FakeIO(), on: true, version: [1, 30, 0], build: "full", config: file)
        c.store = nil
        c.center = NotificationCenter()
        c.screenCenter = { _ in NotificationCenter() }
        c.touchFonts = {}
        c.monitorClicks = { _ in nil }
        c.currentGeometry = { AgentWindowD1Tests.geometry }
        c.historyDirs = { [] }
        c.readHistory = { _, _ in [] }
        c.makePoller = { AgentIslandPoller(dirs: { [] }, list: { _, _ in [] }) }
        addTeardownBlock { @MainActor in c.extLive = false; c.reload() }
        c.extLive = true
        c.reload()
        c.queue.sync {}
        XCTAssertEqual(read(file), "auto_allow = true\nsidekick_pattern = -qa\n")
    }

    // MARK: - The rider: what Prosper may still type

    /// A dch too old for the gate lists no claude_session_id, so the island's engine types nothing.
    @MainActor func testADchTooOldForTheGateGetsNothingTyped() {
        let json = #"[{"name":"api","alias":"","activity_epoch":1,"state":"blocked","version":"1.29.2","agents":0,"auto_allowed":null}]"#
        let rows = AgentIsland.list(dirs: [Self.dir]) { args, _ in args == ["--ls-json"] ? Data(json.utf8) : nil }
        XCTAssertEqual(rows.count, 1)
        guard let s = rows.first else { return }
        XCTAssertTrue(s.claudeSessionID == nil)
        let f = FakeIO(), file = tempDir().appendingPathComponent("config").path
        let (c, d) = controller(f, on: true, version: [1, 29, 2], build: "full", config: file)
        let relisted = OSAllocatedUnfairLock(initialState: 0)
        c.claudeNow = { _ in relisted.withLock { $0 += 1 }; return true }
        tick(c, s)
        drain(c)
        XCTAssertEqual(f.sent, [], "nothing typed")
        XCTAssertFalse(c.heldByAutoAllow(key))
        XCTAssertEqual(c.published([s]).first?.state, .blocked, "Needs input")
        XCTAssertEqual(d.called(), [], "no dch asked")
        XCTAssertEqual(relisted.withLock { $0 }, 0)
    }

    /// The Claude Code left inside the poll window: the list read again for that session, on the controller's
    /// queue right before the key, decides. With it still named, the same check types its Yes (the control).
    @MainActor func testTheListIsReadAgainRightBeforeTheSend() {
        for still in [true, false] {
            let f = FakeIO(), file = tempDir().appendingPathComponent("config").path
            let (c, _) = controller(f, on: true, version: nil, build: nil, config: file)
            final class Asked: @unchecked Sendable {
                let lock = NSLock()
                var calls: [(AgentSessionKey, Bool)] = []
            }
            let asked = Asked()
            c.claudeNow = { k in asked.lock.withLock { asked.calls.append((k, Thread.isMainThread)) }; return still }
            tick(c, row(master: "1.60.0"))
            drain(c)
            XCTAssertEqual(f.sent, still ? ["1"] : [], "still \(still)")
            let calls = asked.lock.withLock { asked.calls }
            XCTAssertEqual(calls.count, 1, "still \(still): once, at the send")
            XCTAssertEqual(calls.first?.0, key)
            XCTAssertEqual(calls.first?.1, false, "on the controller's queue")
            if !still {
                XCTAssertFalse(c.heldByAutoAllow(key))
                XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .blocked, "Needs input")
            }
        }
    }

    // MARK: - #1172: the two engines side by side, the hold, the stand-down's timeout, the caption, the writes

    /// dch's regcomp (extended, ignoring case), as dch compiles the pattern; nil: not an ERE.
    private static func dchMatches(_ p: String, _ name: String) -> Bool? {
        var re = regex_t()
        guard regcomp(&re, p, REG_EXTENDED | REG_ICASE | REG_NOSUB) == 0 else { return nil }
        defer { regfree(&re) }
        return regexec(&re, name, 0, nil, 0) == 0
    }

    private static func islandMatches(_ p: String, _ name: String) -> Bool {
        let s = AgentSession(key: AgentSessionKey(dir: "/d", name: name), alias: "", activity: 0, state: .idle, agents: 0)
        return !AgentIsland.split([s], pattern: p).sidekicks.isEmpty
    }

    /// dch never calls setlocale, so it compiles in the C locale; the test process may hold another (LuaLocaleTests
    /// sets some), so the comparison rows set C for LC_CTYPE and LC_COLLATE and put the old ones back.
    private static func cLocale() -> () -> Void {
        let saved = [LC_CTYPE, LC_COLLATE].map { ($0, String(cString: setlocale($0, nil))) }
        for c in [LC_CTYPE, LC_COLLATE] { setlocale(c, "C") }
        return { for (c, n) in saved { setlocale(c, n) } }
    }

    /// Why each construct left out stays out: ICU and dch disagree on a name. And the one limit sets share with
    /// literal letters: ICU folds K U+212A to k and ſ U+017F to s, dch does not; a set answers as the literal does.
    func testWhatIsLeftOutReadsDifferently() {
        let restore = Self.cLocale()
        defer { restore() }
        // pattern, name, ICU, dch
        let differ: [(String, String, Bool, Bool)] = [
            ("a.b", "a\u{E9}b", true, false),          // "." is one byte in dch: é is two
            ("a.b", "a\u{1F600}b", true, false),
            ("a.*b", "a\nb", false, true),             // ICU's "." never takes a line end
            ("x[^0-9]y", "x\u{E9}y", true, false),     // a negated set takes one byte of é in dch
        ]
        for (p, n, icu, dch) in differ {
            XCTAssertEqual(Self.islandMatches(p, n), icu, "\(p) on \(n.debugDescription): ICU")
            XCTAssertEqual(Self.dchMatches(p, n), dch, "\(p) on \(n.debugDescription): dch")
            XCTAssertEqual(DchConfigWriter.sidekickValue(p), "", "\(p): not written")
        }
        for n in ["\u{212A}", "x\u{17F}y"] {
            for (literal, set) in [("k", "[k]"), ("s", "[s]"), ("k", "[j-l]"), ("s", "[r-t]"), ("K", "[K]")] {
                XCTAssertEqual(Self.islandMatches(set, n), Self.islandMatches(literal, n), "\(set) and \(literal) on \(n): ICU")
                XCTAssertEqual(Self.dchMatches(set, n), Self.dchMatches(literal, n), "\(set) and \(literal) on \(n): dch")
            }
        }
    }

    /// The set members are this literal list: every printable ASCII character inside a set is taken exactly when it
    /// is in it (the loop runs over the characters, not over the list under test); ranges only of one kind, low to high.
    func testTheSetMembersAreALiteralList() {
        let literal = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
        XCTAssertEqual(DchConfigWriter.setMembers, Set(literal.unicodeScalars))
        for v in UInt32(0x20)...0x7E {
            guard let u = Unicode.Scalar(v) else { continue }
            XCTAssertEqual(DchConfigWriter.portable("x[\(Character(u))]y"), literal.unicodeScalars.contains(u), "[\(Character(u))]")
        }
        let ranges: [(String, Bool)] = [("0-9", true), ("a-z", true), ("A-Z", true), ("3-3", true), ("b-y", true), ("a-cx-z", true),
                                        ("9-0", false), ("z-a", false), ("a-Z", false), ("A-z", false), ("0-a", false), ("_-a", false),
                                        ("a-_", false), ("a-c-e", false), ("a-", false), ("-a", false), ("^a", false), ("", false)]
        for (r, ok) in ranges { XCTAssertEqual(DchConfigWriter.portable("x[\(r)]y"), ok, r) }
    }

    func testWhichMasterVersionsHoldTrueBack() {
        let table: [(String, Bool)] = [
            ("1.28.6", false), ("1.30.0", false), ("1.63.0", false), ("2.0.0", false), ("0.9.9", false), ("1.30.10", false),
            ("1.29.0", true), ("1.29.2", true), ("1.29.99", true),
            // not plain X.Y.Z: unknown, so held
            ("", true), ("1.29", true), ("1.30", true), ("1.30.0-rc1", true), ("v1.30.0", true), ("1.30.0 ", true), ("abc", true),
            ("1..0", true), ("1.30.0.1", true), ("9999999999.0.0", true), ("1.3\u{FF10}.0", true), ("-1.30.0", true), ("1.30.\u{663}", true),
        ]
        for (v, holds) in table {
            XCTAssertEqual(DchConfigWriter.holdsTrue([v]), holds, v.debugDescription)
            XCTAssertEqual(DchConfigWriter.holdsTrue(["1.30.0", v, "1.63.0"]), holds, "among others: \(v.debugDescription)")
        }
        XCTAssertTrue(DchConfigWriter.holdsTrue(nil), "no list: unknown")
        XCTAssertFalse(DchConfigWriter.holdsTrue([]), "a list read whole with no masters")
        XCTAssertEqual(DchConfigWriter.masters([Data(#"[{"name":"api","version":"1.30.2"},{"name":"api-qa","version":7},{"name":"x"}]"#.utf8),
                                                Data("[]".utf8)]), ["1.30.2", "", ""])
        XCTAssertTrue(DchConfigWriter.masters([Data("[]".utf8), nil]) == nil, "one dir timed out")
        for bad in ["", "{}", "not json", #"["1.30.0"]"#, "[1]"] {
            XCTAssertTrue(DchConfigWriter.masters([Data(bad.utf8)]) == nil, bad)
        }
    }

    /// The newest list's masters, as the poll publishes them (idle rows: no prompt is checked).
    @MainActor private func listed(_ c: AgentIslandController, _ versions: [String]) {
        c.store?.sessions = versions.enumerated().map {
            AgentSession(key: AgentSessionKey(dir: Self.dir, name: "s\($0.offset)"), alias: "", activity: 1, state: .idle, agents: 0,
                         version: $0.element)
        }
        c.checkAutoAllow()
        c.queue.sync {}
    }

    /// Item 1: true waits while a 1.29.x master is listed and is written once it is gone; false at once when one
    /// comes back; a dir whose list times out holds it too, and a later sync writes true once the list reads again.
    @MainActor func testTrueWaitsWhileA129MasterIsListed() {
        usePattern(tabs: true, "-qa")
        let file = tempDir().appendingPathComponent("config").path
        let (c, d) = controller(FakeIO(), on: true, version: [1, 30, 0], build: "full", config: file)
        c.seedDirs = { [DchConfigWriterTests.dir] }
        func ls(_ json: String?) { d.lock.withLock { d.ls[Self.dir] = json } }
        func written() -> String? { read(file) }
        let on = "auto_allow = true\nsidekick_pattern = -qa\n", off = "auto_allow = false\nsidekick_pattern = -qa\n"

        ls(#"[{"name":"s0","version":"1.30.2"},{"name":"s1","version":"1.29.1"}]"#)
        c.syncDchConfig()
        c.queue.sync {}
        XCTAssertEqual(written(), off, "a 1.29.1 master is listed: false")
        listed(c, ["1.30.2", "1.29.1"])
        XCTAssertEqual(written(), off)

        ls(#"[{"name":"s0","version":"1.30.2"}]"#)
        listed(c, ["1.30.2"])
        XCTAssertEqual(written(), on, "the 1.29.1 master is gone: true")

        ls(#"[{"name":"s0","version":"1.30.2"},{"name":"s1","version":"1.29.0"}]"#)
        listed(c, ["1.30.2", "1.29.0"])
        XCTAssertEqual(written(), off, "a 1.29.0 master came: false at once")

        ls(#"[{"name":"s0","version":"1.30.2"},{"name":"s1","version":""}]"#)
        listed(c, ["1.30.2", ""])
        XCTAssertEqual(written(), off, "a master with no version: held")

        ls(nil)   // the sync's own list of the dir times out
        listed(c, ["1.30.2"])
        XCTAssertEqual(written(), off, "a list that timed out is not 'no masters'")
        ls("")
        c.syncDchConfig()
        c.queue.sync {}
        XCTAssertEqual(written(), off, "an empty answer is not a list either")

        ls(#"[{"name":"s0","version":"1.30.2"}]"#)
        c.syncDchConfig()   // any later sync: the toggle, the pattern, a list change
        c.queue.sync {}
        XCTAssertEqual(written(), on)
        XCTAssertTrue(d.called().contains(["--ls-json"]))

        c.autoAllowOn = { false }
        ls(#"[{"name":"s1","version":"1.29.1"}]"#)
        c.syncDchConfig()
        c.queue.sync {}
        XCTAssertEqual(written(), off, "the toggle off: false, whatever the list")
    }

    /// dch's own reading of auto_allow (dch.c config_line, dch_config_bool), and of the file when the stand-down's
    /// `--config` times out (mayAllow): nothing Prosper cannot read the way dch does counts as false.
    func testDchsReadingOfAutoAllow() throws {
        let table: [(String, Bool)] = [
            ("", false), ("auto_allow = true\n", true), ("auto_allow=TRUE", true), (" \tauto_allow\t=\tYes \r\n", true),
            ("auto_allow = on\nauto_allow = 0\n", false), ("auto_allow = 0\nauto_allow = 1\n", true), ("auto_allow = true # on\n", false),
            ("#auto_allow = true\n", false), ("auto_allowed = true\n", false), ("auto_allow = \rtrue\n", false),
            ("auto_allow = tru\u{E9}\n", false), ("auto_allow = \u{212A}\n", false),
        ]
        for (text, on) in table { XCTAssertTrue(DchConfigWriter.dchAllows(Data(text.utf8)) == on, text.debugDescription) }
        let long = Data(("auto_allow = false\n" + String(repeating: "#", count: DchConfigWriter.dchLineBytes) + "auto_allow = true\n").utf8)
        XCTAssertTrue(DchConfigWriter.dchAllows(long) == nil, "dch reads that line in pieces: unknown")

        let dir = tempDir(), fm = FileManager.default
        func file(_ name: String, _ text: String) -> String {
            let path = dir.appendingPathComponent(name).path
            XCTAssertTrue(fm.createFile(atPath: path, contents: Data(text.utf8)))
            return path
        }
        XCTAssertFalse(DchConfigWriter.mayAllow(path: nil), "no path: dch has no file")
        XCTAssertFalse(DchConfigWriter.mayAllow(path: dir.appendingPathComponent("none").path), "no file")
        XCTAssertFalse(DchConfigWriter.mayAllow(path: file("off", "auto_allow = false\n")))
        XCTAssertTrue(DchConfigWriter.mayAllow(path: file("on", "auto_allow = yes\n")))
        XCTAssertTrue(DchConfigWriter.mayAllow(path: dir.path), "a folder: unknown")
        XCTAssertTrue(DchConfigWriter.mayAllow(path: file("off", "") + "/config"), "a path through a file: unknown")
        let locked = file("locked", "auto_allow = false\n")
        chmod(locked, 0o000)
        addTeardownBlock { chmod(locked, 0o600) }
        XCTAssertTrue(DchConfigWriter.mayAllow(path: locked), "unreadable: unknown")
        chmod(locked, 0o600)
        let longPath = dir.appendingPathComponent("long").path
        XCTAssertTrue(fm.createFile(atPath: longPath, contents: long))
        XCTAssertTrue(DchConfigWriter.mayAllow(path: longPath), "a line read in pieces: unknown")
    }

    /// Item 2 (#792's leftover): the stand-down check's `dch --config` timing out reads the file instead. One that
    /// says true, or that Prosper cannot read as dch does, leaves the prompt to dch (then the human), never to both.
    @MainActor func testAConfigReadThatTimesOutReadsTheFile() throws {
        let cases: [(String, String?, Bool)] = [   // name, the file (nil: none), the island types its Yes
            ("true", "auto_allow = true\n", false),
            ("the last line wins", "auto_allow = false\n auto_allow\t=\tYES \r\n", false),
            ("false", "auto_allow = true\nauto_allow = false\n", true),
            ("no file", nil, true),
            ("not a bool", "auto_allow = true # on\n", true),
            ("a line dch reads in pieces", String(repeating: "#", count: DchConfigWriter.dchLineBytes + 1) + "\n", false),
        ]
        for (name, text, types) in cases {
            let f = FakeIO(), file = tempDir("timedOut").appendingPathComponent("config").path
            if let text { XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data(text.utf8)), name) }
            let (c, d) = controller(f, on: true, version: [1, 30, 0], build: "full", config: file)
            d.lock.withLock { d.configTimesOut = true }
            tick(c, row(master: "1.60.0"))
            drain(c)
            XCTAssertEqual(f.sent, types ? ["1"] : [], name)
            XCTAssertEqual(d.called().filter { $0 == ["--config"] }.count, 1, "\(name): --config asked once, timed out")
            if !types { XCTAssertEqual(c.published(c.store?.sessions ?? []).first?.state, .working, "\(name): held for dch") }
        }
        // No path (no DCH_CONFIG, XDG_CONFIG_HOME or HOME): dch has no file to say true, the island answers.
        let f = FakeIO(), (c, d) = controller(f, on: true, version: [1, 30, 0], build: "full", config: tempDir().path + "/config")
        c.dchConfigPath = { nil }
        d.lock.withLock { d.configTimesOut = true }
        tick(c, row(master: "1.60.0"))
        drain(c)
        XCTAssertEqual(f.sent, ["1"])
    }

    /// Item 4: Settings' caption says so when the pattern does not reach dch's picker, and only then.
    func testTheCaptionSaysWhenDchsPickerGetsNoPattern() {
        let note = AgentIsland.sidekickDchNote
        XCTAssertEqual(note, "dch's picker cannot use it: no Sidekicks tab there")
        XCTAssertNil(AgentIsland.sidekickCaption("-(qa|reviewer)$", tabs: true, names: []), "mirrored: no caption")
        XCTAssertNil(AgentIsland.sidekickCaption("build-[0-9]+$", tabs: true, names: []), "a set reaches dch now")
        XCTAssertEqual(AgentIsland.sidekickCaption("-qa.*", tabs: true, names: []), note, "a regex here, not in dch")
        XCTAssertEqual(AgentIsland.sidekickCaption("\u{E9}-qa", tabs: true, names: []), note)
        XCTAssertEqual(AgentIsland.sidekickCaption(String(repeating: "a", count: DchConfigWriter.maxPatternBytes + 1), tabs: true, names: []), note)
        XCTAssertEqual(AgentIsland.sidekickCaption("*-qa", tabs: true, names: []), "Not a valid regex: matched as text\n" + note)
        XCTAssertNil(AgentIsland.sidekickCaption("-qa.*", tabs: false, names: []), "tabs off: the field is disabled")
        XCTAssertNil(AgentIsland.sidekickCaption("  ", tabs: true, names: []), "empty: no split anywhere")
        for p in Self.portable + ["-qa.*", "x[^0-9]y", "\u{E9}-qa", "*-qa", "a|", "x(|a)"] {
            let says = AgentIsland.sidekickCaption(p, tabs: true, names: [])?.hasSuffix(note) == true
            XCTAssertEqual(says, DchConfigWriter.sidekickValue(p).isEmpty, p)
        }
    }

    /// Item 5, the number: "-reviewer" typed in Settings. With every keystroke settled before the next (#781's path,
    /// a sync per keystroke) the config is written 9 times for 9 keys; typed as one burst, once, when it settles.
    /// The settle timer is the controller's `after` seam, fired by hand: no wait in the row.
    @MainActor func testATypedPatternWritesOnceItSettles() {
        usePattern(tabs: true, "")
        let file = tempDir().appendingPathComponent("config").path
        let shared = AgentIslandController.shared
        let (c, _) = controller(FakeIO(), on: false, version: [1, 30, 0], build: "full", config: file)
        final class Timers { var pending: [@MainActor @Sendable () -> Void] = [], delays: [TimeInterval] = [] }
        let timers = Timers()
        let saved = (shared.dchConfigPath, shared.controlDch, shared.runDch, shared.autoAllowOn, shared.after)
        defer { (shared.dchConfigPath, shared.controlDch, shared.runDch, shared.autoAllowOn, shared.after) = saved }
        (shared.dchConfigPath, shared.controlDch, shared.runDch, shared.autoAllowOn) = (c.dchConfigPath, c.controlDch, c.runDch, c.autoAllowOn)
        shared.after = { delay, fire in timers.pending.append(fire); timers.delays.append(delay) }
        var writes = 0
        func fire() {
            let due = timers.pending
            timers.pending = []
            for f in due {
                let before = FileManager.default.contents(atPath: file)
                f()
                shared.queue.sync {}
                if FileManager.default.contents(atPath: file) != before { writes += 1 }
            }
        }
        var t = 1_000_000.0
        func type(_ word: String, settled: Bool) -> Int {
            writes = 0
            for n in 1...word.count {
                t += 1
                AgentIslandListSection.patternEdited(String(word.prefix(n)), now: Date(timeIntervalSince1970: t))
                if settled { fire() }
            }
            fire()
            return writes
        }
        let perKey = type("-reviewer", settled: true)
        AgentIslandListSection.patternEdited("", now: Date(timeIntervalSince1970: t + 1))
        fire()
        let burst = type("-reviewer", settled: false)
        print("#1172 config writes for \"-reviewer\" typed in Settings: \(perKey) with each keystroke settled, \(burst) as one burst")
        XCTAssertEqual(perKey, 9, "a write per keystroke when nothing coalesces")
        XCTAssertEqual(burst, 1, "one write after the burst")
        XCTAssertEqual(read(file), "auto_allow = false\nsidekick_pattern = -reviewer\n")
        XCTAssertEqual(Set(timers.delays), [AgentIslandController.dchConfigSettle])
    }

    /// QA R781-2: dch reads a line over dchLineBytes in pieces, and a piece may set a key render does not see (here
    /// a later `auto_allow = true` that would win over Prosper's false). Such a file is refused and kept; a line of
    /// exactly dchLineBytes is written.
    func testALineDchReadsInPiecesIsRefused() {
        let dir = tempDir(), path = dir.appendingPathComponent("config").path
        let long = "auto_allow = false\n" + String(repeating: "#", count: DchConfigWriter.dchLineBytes) + "auto_allow = true\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(long.utf8)))
        guard case .refused = DchConfigWriter.write(path: path, autoAllow: false, pattern: "-qa") else { return XCTFail("written") }
        XCTAssertEqual(read(path), long)
        XCTAssertEqual(names(dir), ["config"])
        let at = String(repeating: "#", count: DchConfigWriter.dchLineBytes) + "\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(at.utf8)))
        XCTAssertEqual(DchConfigWriter.write(path: path, autoAllow: false, pattern: "-qa"), .written)
        XCTAssertEqual(read(path), at + "auto_allow = false\nsidekick_pattern = -qa\n")
    }
}
