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
    /// #1179: a line is a C string to dch: it ends at its first NUL byte.
    private static func dchValue(_ file: Data, _ key: String) -> String? {
        var v: String?
        for whole in file.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = whole.prefix { $0 != 0 }
            guard DchConfigWriter.setsKey(line, key) else { continue }
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
                let island = !AgentIsland.split([s], pattern: p).firstGroup.isEmpty
                XCTAssertEqual(island, dch, "\(p) on \(n)")
            }
        }
    }

    // MARK: - #1184: the picker's other texts, line ends and the text fallback

    private static func sessions(_ rows: [(name: String, alias: String)]) -> [AgentSession] {
        rows.map { AgentSession(key: AgentSessionKey(dir: "/d", name: $0.name), alias: $0.alias, activity: 0, state: .idle, agents: 0) }
    }

    /// An alias or harness title can end in VT, FF, U+0085, U+2028, U+2029 (dch cuts LF, CR and blanks only); ICU's "$"
    /// would match before them, POSIX's does not. Literal table: alias, dch's answer (regexec), the island's.
    func testAnAliasEndingInALineSeparatorIsNotSplitOffByDollar() {
        let restore = Self.cLocale()
        defer { restore() }
        let table: [(alias: String, hit: Bool)] = [
            ("x-qa", true), ("x-qa\u{2028}", false), ("x-qa\u{2029}", false), ("x-qa\u{85}", false),
            ("x-qa\u{0B}", false), ("x-qa\u{0C}", false), ("x-qa\r", false), ("x-qa\u{2028}y", false), ("x-qay", false),
        ]
        for (alias, hit) in table {
            XCTAssertEqual(Self.dchMatches("-qa$", alias), hit, "dch: \(alias.debugDescription)")
            let split = AgentIsland.split(Self.sessions([(name: "api", alias: alias)]), pattern: "-qa$")
            XCTAssertEqual(!split.firstGroup.isEmpty, hit, "island: \(alias.debugDescription)")
        }
        // "^" at the other end: an alias starting with a separator is not "^qa"
        XCTAssertEqual(Self.dchMatches("^qa", "\u{2028}qa"), false)
        XCTAssertTrue(AgentIsland.split(Self.sessions([(name: "api", alias: "\u{2028}qa")]), pattern: "^qa").firstGroup.isEmpty)
    }

    /// #1210: dch's picker (pk_load) matches name, alias and harness title one by one, the title also when an
    /// alias is set. Literal table through parseListJSON and AgentIsland.list: name, alias, title (nil: no key, an
    /// older dch), pattern, dch's answer (regexec on each text, C locale), the island's. The label stays the alias.
    func testHarnessTitleSplitsAsDchsPickerAlsoWithAnAlias() {
        let restore = Self.cLocale()
        defer { restore() }
        // #1882: a 24 KB title under the 10 ms CPU deadline on a busy runner is no hit by design (#1220); lift it, as
        // testSplitSlowCallTallyFlipsToText does. The cap rows' own pattern: no other row's tally on "-qa$" reaches them.
        let saved = (AgentIsland.sidekickDeadline, AgentIsland.sidekickSlowCall, AgentIsland.sidekickSlowTotal)
        defer { (AgentIsland.sidekickDeadline, AgentIsland.sidekickSlowCall, AgentIsland.sidekickSlowTotal) = saved }
        (AgentIsland.sidekickDeadline, AgentIsland.sidekickSlowCall) = (.max, .max)
        let cap = DchListRow.maxHarnessBytes
        let atCap = String(repeating: "x", count: cap - 6) + "-atcap", overCap = "x" + atCap
        let table: [(name: String, alias: String, title: String?, pattern: String, dch: Bool, island: Bool)] = [
            ("api", "Agent A", "web-qa", "-qa$", true, true),      // title only, alias set
            ("api", "web-qa", "notes", "-qa$", true, true),        // alias
            ("api-qa", "Agent A", "notes", "-qa$", true, true),    // name
            ("api", "Agent A", "notes", "-qa$", false, false),     // none
            ("api", "Agent A", "", "-qa$", false, false),          // empty title
            ("api", "", "web-qa", "-qa$", true, true),             // no alias: the title is the label too
            ("api", "Agent A", nil, "-qa$", false, false),         // no key (dch before 1.9): as before
            ("api-qa", "", nil, "-qa$", true, true),
            ("api", "Agent A", "Web-1", "^web", true, true),       // anchored on the title alone
            ("api", "web-a", "qa", "aqa", false, false),           // never joined: "web-a"+"qa"
            ("api", "Agent A", atCap, "-atcap$", true, true),       // at the cap
            ("api", "Agent A", overCap, "-atcap$", true, false),    // over it: dch prints none so long; dropped
        ]
        for (name, alias, title, p, dch, island) in table {
            let what = "\(name)|\(alias)|\(title?.prefix(12) ?? "nil")|\(p)"
            XCTAssertEqual([name, alias, title ?? ""].contains { Self.dchMatches(p, $0) == true }, dch, "dch: \(what)")
            var o: [String: Any] = ["name": name, "alias": alias, "state": "idle"]
            if let title { o["harness"] = title }
            let json = (try? JSONSerialization.data(withJSONObject: [o])) ?? Data()
            let list = AgentIsland.list(dirs: ["/d"], run: { args, _ in args == ["--ls-json"] ? json : nil })
            XCTAssertEqual(list.count, 1, what)
            guard let s = list.first else { continue }
            XCTAssertEqual(!AgentIsland.split(list, pattern: p).firstGroup.isEmpty, island, "island: \(what)")
            let kept = title.map { $0.utf8.count <= cap ? $0 : "" } ?? ""
            XCTAssertEqual(s.harness, kept, what)
            XCTAssertEqual(s.title, !alias.isEmpty ? alias : !kept.isEmpty ? kept : name, "label: \(what)")
        }
    }

    /// #1210: the Settings caption names the three texts dch's picker matches.
    @MainActor func testTheCaptionNamesTheSessionTitle() {
        XCTAssertTrue(AgentIslandListSection.footer.hasPrefix("Sessions whose name, alias or session title matches the pattern"))
    }

    /// #1210 rider R1184-1: dch never calls setlocale, so its regcomp folds ASCII only and "." is one byte; the
    /// island folds and counts by Unicode. A person typing "é" means "É" too, so the island's answer is the right one
    /// and stays (sidekickRegex's comment). Literal rows: pattern, text, dch (C locale), island.
    func testANonASCIIPatternFoldsByUnicodeInTheIslandOnly() {
        let restore = Self.cLocale()
        defer { restore() }
        let rows: [(pattern: String, text: String, dch: Bool, island: Bool)] = [
            ("\u{E9}-qa", "\u{C9}-QA", false, true),   // accented letter against the other case
            ("^.$", "\u{E9}", false, true),             // one accented letter: two bytes to dch
            ("\u{E9}-qa", "\u{E9}-qa", true, true),
        ]
        for (p, t, dch, island) in rows {
            XCTAssertEqual(Self.dchMatches(p, t), dch, "dch: \(p) on \(t)")
            XCTAssertEqual(Self.islandMatches(p, t), island, "island: \(p) on \(t)")
        }
        // the text fallback (an invalid pattern): dch's tolower loop (pk_sidekick) folds ASCII only
        XCTAssertNil(Self.dchMatches("(\u{E9}", "x"))
        XCTAssertTrue(Self.islandMatches("(\u{E9}", "x(\u{C9}"))
        XCTAssertFalse(Self.islandMatches("(\u{E9}", "x(e"))
    }

    // MARK: - #1220 rider R1210-a: a long title never flips the pattern

    /// A fake thread-CPU clock (as AgentIslandTests' countingCPU, #1063): each read advances it `tick` ns, so a
    /// search's cost is its count of clock reads (one per ICU progress callback, about one per start position).
    private static func countingCPU(tick: UInt64) -> (clock: @Sendable () -> UInt64, reads: @Sendable () -> UInt64) {
        let now = OSAllocatedUnfairLock(initialState: UInt64(0))
        return ({ now.withLock { $0 += tick; return $0 } }, { now.withLock { $0 / tick } })
    }

    /// Runs `body` with the matcher's seams set, restored after. Patterns are unique per row: the cache is per process.
    private static func withSeams(deadline: UInt64, slowCall: UInt64, slowTotal: UInt64,
                                  _ body: (_ reads: @Sendable () -> UInt64) -> Void) {
        let saved = (AgentIsland.sidekickDeadline, AgentIsland.sidekickSlowCall, AgentIsland.sidekickSlowTotal, AgentIsland.sidekickCPU)
        defer { (AgentIsland.sidekickDeadline, AgentIsland.sidekickSlowCall, AgentIsland.sidekickSlowTotal, AgentIsland.sidekickCPU) = saved }
        let c = countingCPU(tick: 1_000)
        (AgentIsland.sidekickDeadline, AgentIsland.sidekickSlowCall, AgentIsland.sidekickSlowTotal, AgentIsland.sidekickCPU)
            = (deadline, slowCall, slowTotal, c.clock)
        body(c.reads)
    }

    private static func session(_ name: String, alias: String = "", title: String = "") -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: "/d", name: name), alias: alias, activity: 0, state: .idle, agents: 0, harness: title)
    }

    /// No match, and a leading ".*" scans the rest from each of its 510 start positions: 510 progress callbacks.
    private static func longTitle(_ tag: String) -> String { String(repeating: "a", count: 500) + "-qa\(tag)-x" }

    /// A title that runs past the call's deadline (100 reads) is no hit and leaves the pattern a regex; the same
    /// session's alias still hits, a short title still hits, and the call stops at the deadline: 102 reads.
    func testASlowTitleIsNoHitAndNeverFlipsThePattern() {
        let p = ".*-qa1220a$"
        // A total out of reach: the titles' own tally (testATitleTallyEndsItsRegexSearchOnly) never trips here.
        Self.withSeams(deadline: 100_000, slowCall: .max, slowTotal: .max) { reads in
            let list = [Self.session("api", alias: "api-qa1220a", title: Self.longTitle("1220a")),
                        Self.session("web", alias: "Agent B", title: Self.longTitle("1220a")),
                        Self.session("doc", alias: "Agent C", title: "doc-qa1220a")]
            XCTAssertEqual(AgentIsland.sidekickMatch(p), .regex, "the probe on \"\" runs here, outside the counted calls")
            for _ in 0..<3 {
                let before = reads()
                let r = AgentIsland.split(list, pattern: p)
                XCTAssertEqual(r.firstGroup.map(\.name), ["api", "doc"], "the alias and the short title, as a regex")
                XCTAssertEqual(r.primary.map(\.name), ["web"], "its title timed out: no hit")
                XCTAssertEqual(AgentIsland.sidekickMatch(p), .regex, "never flipped by a title")
                // One call shares one deadline: about 105 reads (start, 101 to pass it, ICU's callbacks after the stop,
                // measured 104 before the titles' tally added one read; the tail is ICU's and may differ on another macOS).
                // Were each title given a fresh deadline, both long titles would pay one: about 40 for names and aliases
                // + 2 x 105, about 250. 170 is between the two.
                XCTAssertLessThan(reads() - before, 170, "a split call still costs one deadline, not one per title")
            }
        }
    }

    /// The same timeout on a NAME still flips the pattern to text for the process, as before #1220, and Settings says so
    /// in the same words.
    func testASlowNameStillFlipsThePattern() {
        let p = ".*-qa1220b$"
        Self.withSeams(deadline: 100_000, slowCall: .max, slowTotal: 0) { _ in
            let r = AgentIsland.split([Self.session(Self.longTitle("1220b")), Self.session("api-qa1220b")], pattern: p)
            XCTAssertEqual(r.firstGroup.map(\.name), [], "flipped: matched as text, and no name holds the pattern's text")
            XCTAssertEqual(AgentIsland.sidekickMatch(p), .slow)
            XCTAssertEqual(AgentIsland.sidekickCaption(p, tabs: true, names: [])?.components(separatedBy: "\n").first,
                           "Too slow on a session name: matched as text")
        }
        XCTAssertEqual(AgentIsland.SidekickMatch.slow.caption, "Too slow on a session name: matched as text")
    }

    /// The same timeout on an ALIAS flips it too: names and aliases are accounted as before.
    func testASlowAliasStillFlipsThePattern() {
        let p = ".*-qa1220d$"
        Self.withSeams(deadline: 100_000, slowCall: .max, slowTotal: 0) { _ in
            _ = AgentIsland.split([Self.session("api", alias: Self.longTitle("1220d"))], pattern: p)
            XCTAssertEqual(AgentIsland.sidekickMatch(p), .slow)
        }
    }

    /// A title searched in time but over the slow-call bar (510 reads against 50) adds nothing to the tally; the same
    /// cost on a name flips the pattern (a total of 0: any call that counts flips it).
    func testATitlesTimeIsNotTallied() {
        let p = ".*-qa1220c$", q = ".*-qa1220e$"
        Self.withSeams(deadline: 5_000_000, slowCall: 50_000, slowTotal: 0) { _ in
            let list = [Self.session("api", alias: "Agent A", title: Self.longTitle("1220c")), Self.session("web", alias: "web-qa1220c")]
            for _ in 0..<3 { XCTAssertEqual(AgentIsland.split(list, pattern: p).firstGroup.map(\.name), ["web"]) }
            XCTAssertEqual(AgentIsland.sidekickMatch(p), .regex)
            _ = AgentIsland.split([Self.session(Self.longTitle("1220e"))], pattern: q)
            XCTAssertEqual(AgentIsland.sidekickMatch(q), .slow, "the same search on a name counts")
        }
    }

    /// #1220 round 2: the titles' own tally. Each call where the long title runs out the deadline adds the titles' part
    /// (about 105 - 40 = 65 reads, 65 µs) to it; past the 100 µs total (the second call) the titles are matched as
    /// text: no regex search of a title (the call's reads are the names' only, about 40; 105+ while titles were a
    /// regex), a title holding the pattern's text is a hit, the title-only regex match is not, and the pattern and its
    /// names and aliases stay a regex. Names never count here (slowCall out of reach), so only the titles' tally moves.
    func testATitleTallyEndsItsRegexSearchOnly() {
        let p = ".*-qa1220h$"
        Self.withSeams(deadline: 100_000, slowCall: .max, slowTotal: 100_000) { reads in
            let list = [Self.session("api", alias: "api-qa1220h", title: Self.longTitle("1220h")),
                        Self.session("doc", alias: "Agent C", title: "doc-qa1220h"),
                        Self.session("lit", alias: "Agent D", title: "x.*-QA1220H$y")]
            XCTAssertEqual(AgentIsland.sidekickMatch(p), .regex, "the probe on \"\" runs here, outside the counted calls")
            for call in 1...2 {
                let before = reads()
                XCTAssertEqual(AgentIsland.split(list, pattern: p).firstGroup.map(\.name), ["api", "doc"], "call \(call): titles a regex")
                XCTAssertGreaterThan(reads() - before, 100, "call \(call): slow once, under the total: still searched")
            }
            let before = reads()
            XCTAssertEqual(AgentIsland.split(list, pattern: p).firstGroup.map(\.name), ["api", "lit"],
                           "titles as text; the alias still a regex")
            XCTAssertLessThan(reads() - before, 75, "no regex search of a title")
            XCTAssertEqual(AgentIsland.sidekickMatch(p), .regex)
        }
    }

    /// #1220: Settings' caption searches the live sessions as split does (sidekickTexts). A slow title is no hit and
    /// leaves the pattern a regex, so the caption and the island agree (the island still takes the title-only match);
    /// a slow name still flips it and the caption says so in the same words.
    func testTheCaptionSearchesATitleAsATitle() {
        let p = ".*-qa1220f$", q = ".*-qa1220g$"
        Self.withSeams(deadline: 100_000, slowCall: .max, slowTotal: .max) { _ in
            let list = [Self.session("api", alias: "Agent A", title: Self.longTitle("1220f")),
                        Self.session("doc", alias: "Agent C", title: "doc-qa1220f")]
            let caption = AgentIsland.sidekickCaption(p, tabs: true, sessions: list)
            XCTAssertFalse(caption?.contains("Too slow") == true, caption ?? "nil")
            XCTAssertEqual(AgentIsland.sidekickMatch(p), .regex)
            XCTAssertEqual(AgentIsland.split(list, pattern: p).firstGroup.map(\.name), ["doc"], "the title-only match")
            let named = AgentIsland.sidekickCaption(q, tabs: true, sessions: [Self.session(Self.longTitle("1220g"))])
            XCTAssertEqual(named?.components(separatedBy: "\n").first, "Too slow on a session name: matched as text")
            XCTAssertEqual(AgentIsland.sidekickMatch(q), .slow)
        }
    }

    /// #1220: a blocked session the island answers is published as working with its title, so the phone's list frame
    /// does not drop the key for the length of an auto-answer.
    func testAnAnsweredSessionKeepsItsTitle() {
        let s = AgentSession(key: AgentSessionKey(dir: "/d", name: "api"), alias: "A", activity: 5, state: .blocked, agents: 1,
                             cwd: "/w/a", harness: "web-qa")
        let w = AgentIslandController.answering(s)
        XCTAssertEqual(w.state, .working)
        XCTAssertEqual([w.alias, w.cwd, w.harness], ["A", "/w/a", "web-qa"])
    }

    // MARK: - #1220: the title on the phone's list frame

    /// listPayload's "harness": only when non-empty, not what the alias already sends, and within maxHarnessBytes.
    /// Literal table: alias, title, the payload's bytes.
    func testTheTitleIsOnTheListFrameOnlyWhenTheAliasDoesNotCarryIt() {
        let cap = DchListRow.maxHarnessBytes
        let atCap = String(repeating: "x", count: cap), overCap = atCap + "x"
        func wire(_ alias: String, _ title: String) -> String {
            String(decoding: DchFrame.listPayload([DchListRow(name: "a", alias: alias, activityEpoch: 0, state: "idle", agents: 0,
                                                              harness: title)]), as: UTF8.self)
        }
        let table: [(alias: String, title: String, wire: String)] = [
            ("", "web-qa", #"[{"harness":"web-qa","name":"a","state":"idle"}]"#),                  // title only
            ("A", "web-qa", #"[{"alias":"A","harness":"web-qa","name":"a","state":"idle"}]"#),     // with an alias
            ("web-qa", "web-qa", #"[{"alias":"web-qa","name":"a","state":"idle"}]"#),              // equal: not twice
            ("A", "", #"[{"alias":"A","name":"a","state":"idle"}]"#),                              // empty
            ("A", "\u{41F}\u{440}\u{43E}-\u{1F600}", "[{\"alias\":\"A\",\"harness\":\"\u{41F}\u{440}\u{43E}-\u{1F600}\",\"name\":\"a\",\"state\":\"idle\"}]"),
            ("A", atCap, #"[{"alias":"A","harness":""# + atCap + #"","name":"a","state":"idle"}]"#), // at the cap
            ("A", overCap, #"[{"alias":"A","name":"a","state":"idle"}]"#),                          // over it: no key
        ]
        for (alias, title, w) in table { XCTAssertEqual(wire(alias, title), w, "\(alias)|\(title.prefix(12))") }
        // Through parseListJSON: a title folded into an empty alias goes once, as the alias.
        let json = Data(#"[{"name":"a","alias":"","harness":"web-qa"},{"name":"b","alias":"B","harness":"web-qa"}]"#.utf8)
        XCTAssertEqual(String(decoding: DchFrame.listPayload(DchCommand.parseListJSON(json)), as: UTF8.self),
                       #"[{"alias":"web-qa","name":"a"},{"alias":"B","harness":"web-qa","name":"b"}]"#)
    }

    /// Version skew. An older phone reads name, alias, state, agents and meta by key (prosper-ios decodeList): with the
    /// key, every other key of the row is the same. An older Mac sends no key: a row without a title is today's bytes.
    func testTheTitleKeyIsOnlyAddedOnBothSidesOfSkew() {
        let rows = [DchListRow(name: "a", alias: "A", activityEpoch: 0, state: "working", agents: 2, cwd: "/w/a", harness: "web-qa"),
                    DchListRow(name: "b", alias: "", activityEpoch: 0, state: "", agents: 0, harness: "notes")]
        let untitled = rows.map { var r = $0; r.harness = ""; return r }
        func parsed(_ d: Data) -> [NSDictionary] { ((try? JSONSerialization.jsonObject(with: d)) as? [NSDictionary]) ?? [] }
        let withKey = parsed(DchFrame.listPayload(rows)).map { d -> NSDictionary in
            let m = NSMutableDictionary(dictionary: d); m.removeObject(forKey: "harness"); return m
        }
        XCTAssertEqual(parsed(DchFrame.listPayload(rows)).compactMap { $0["harness"] as? String }, ["web-qa", "notes"])
        XCTAssertEqual(withKey, parsed(DchFrame.listPayload(untitled)), "an older phone: the key is extra, nothing else changes")
        XCTAssertEqual(String(decoding: DchFrame.listPayload(untitled), as: UTF8.self),
                       #"[{"agents":2,"alias":"A","cwd":"\/w\/a","name":"a","state":"working"},{"name":"b"}]"#,
                       "no title: the bytes from before #1220")
    }

    /// dch's picker: a pattern regcomp refuses, or one regexec finds in "", is matched as plain text ignoring case.
    /// The island does the same; literal table (pattern, text, expected).
    func testInvalidAndEmptyMatchingPatternsAreMatchedAsText() {
        let restore = Self.cLocale()
        defer { restore() }
        XCTAssertNil(Self.dchMatches("(qa", "x"), "dch: not an ERE, text")
        XCTAssertEqual(Self.dchMatches("(qa)*", ""), true, "dch: matches empty, text")
        let table: [(pattern: String, name: String, hit: Bool)] = [
            ("(qa", "web(QA", true), ("(qa", "web-qa", false), ("(qa", "web-qa(", false),
            ("(qa)*", "A-(QA)*", true), ("(qa)*", "api-qa", false), ("(qa)*", "api", false),
        ]
        for (p, n, hit) in table {
            let split = AgentIsland.split(Self.sessions([(name: n, alias: "")]), pattern: p)
            XCTAssertEqual(!split.firstGroup.isEmpty, hit, "\(p) on \(n)")
        }
        XCTAssertEqual(AgentIsland.sidekickMatch("(qa"), .invalid)
        XCTAssertEqual(AgentIsland.sidekickMatch("(qa)*"), .matchesEmpty)
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
        let keys = ["agentIslandSidekickTabs", "agentIslandSidekickPattern", "agentIslandSidekickPatternUpdated", "agentIslandAutoAllow",
                    "agentIslandSessionGroupsUpdated"]
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
        return !AgentIsland.split([s], pattern: p).firstGroup.isEmpty
    }

    /// dch never calls setlocale, so it compiles in the C locale; the test process may hold another (LuaLocaleTests
    /// sets some), so the comparison rows use C on this thread and put the old one back.
    /// #1210: per thread (newlocale/uselocale), so the process locale is never changed.
    private static func cLocale() -> () -> Void {
        // LC_COLLATE_MASK | LC_CTYPE_MASK (_locale_posix2008.h: 1 << 0, 1 << 1); the macros do not import into Swift.
        let c = newlocale(Int32(1 << 0 | 1 << 1), "C", nil)
        let old = uselocale(c)
        return { uselocale(old); if let c { freelocale(c) } }
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

    /// #1179 item 2: ICU's "$" also matches before a final line end, dch's POSIX "$" only at the very end. Over every
    /// scalar c of the BMP (and two above it), "-end$" on "x-end" + c reads differently in the two engines exactly on
    /// this literal list (NUL: dch's C string ends before it), and dch's session name rule (name_ok, copied from the
    /// supervisor's read) refuses every one of them. Aliases and masters older than that rule: report of #1179.
    func testTheEndAnchorDiffersOnlyOnNamesDchsRuleRefuses() {
        let restore = Self.cLocale()
        defer { restore() }
        func nameRuleRefuses(_ v: UInt32) -> Bool {
            switch v {
            case 0..<0x20, 0x7F...0x9F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C: true
            default: false
            }
        }
        let p = "-end$"
        XCTAssertEqual(DchConfigWriter.sidekickValue(p), p, "written to dch as the island uses it")
        var differ: [UInt32] = []
        for v in Array(UInt32(0)...0xFFFF) + [0x1F600, 0x10FFFF] {
            guard let u = Unicode.Scalar(v) else { continue }   // the surrogates
            let n = "x-end" + String(Character(u))
            if Self.islandMatches(p, n) != Self.dchMatches(p, n) { differ.append(v) }
        }
        // #1184: the island's regex takes LF as the only line end, so VT FF CR NEL LS PS no longer differ; NUL and LF still do
        XCTAssertEqual(differ, [0x00, 0x0A])
        XCTAssertEqual(differ.filter { !nameRuleRefuses($0) }, [], "a name dch can carry")
        XCTAssertTrue(!Self.islandMatches(p, "x-end\r\n") && Self.dchMatches(p, "x-end\r\n") == false, "CRLF: neither")
        XCTAssertTrue(Self.islandMatches(p, "x-end") && Self.dchMatches(p, "x-end") == true)
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

    /// #1179 item 3, the number behind "no sync per poll tick": a sync with the toggle on forks `--ls-json` once per
    /// socket dir and nothing else once the build is cached, so a sync on every 1 s tick would cost 120 process
    /// starts a minute with both of Prosper's dirs. Counted through the runDch seam.
    @MainActor func testASyncForksOneListPerSocketDir() {
        usePattern(tabs: true, "-qa")
        let file = tempDir().appendingPathComponent("config").path, other = "/Users/example/.local/state/dch-remote"
        let (c, d) = controller(FakeIO(), on: true, version: [1, 30, 0], build: "full", config: file)
        c.seedDirs = { [DchConfigWriterTests.dir, other] }
        d.lock.withLock { d.ls = [Self.dir: "[]", other: "[]"] }
        c.syncDchConfig()
        c.queue.sync {}
        XCTAssertEqual(d.called(), [["--build"], ["--ls-json"], ["--ls-json"]])
        for _ in 0..<3 {
            c.syncDchConfig()
            c.queue.sync {}
        }
        XCTAssertEqual(d.called().count, 3 + 3 * 2, "a later sync: one list per dir, nothing else forks")
        XCTAssertEqual(read(file), "auto_allow = true\nsidekick_pattern = -qa\n")
    }

    /// #1185: a controller with the toggle on, two seed dirs in the row's tempDir (the poll lists only the first),
    /// a seed scan whose readdir is counted, and reload's sync done (the build cached). `tick` runs one poll tick's
    /// seed scan on the poll queue, as the timer does, and gives the process starts and readdirs it caused.
    @MainActor private func seedScanned(_ file: String) -> (c: AgentIslandController, d: FakeDch, listed: String, unlisted: String,
                                                            tick: () -> (forks: Int, reads: Int)) {
        let listed = tempDir("listed").path, unlisted = tempDir("unlisted").path
        let (c, d) = controller(FakeIO(), on: true, version: [1, 30, 0], build: "full", config: file)
        c.seedDirs = { [listed, unlisted] }
        let reads = OSAllocatedUnfairLock(initialState: 0)
        c.seedScan = AgentSeedScan(scanner: AgentDirScanner(readDir: {
            reads.withLock { $0 += 1 }
            return (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        }))
        d.lock.withLock { d.ls = [listed: "[]", unlisted: "[]"] }
        c.syncDchConfig()
        c.queue.sync {}
        let scan = c.seedTick()
        return (c, d, listed, unlisted, {
            let f = d.called().count, r = reads.withLock { $0 }
            c.queue.sync { scan([listed]) }
            self.drain(c)
            return (d.called().count - f, reads.withLock { $0 } - r)
        })
    }

    /// #1185 (b1): an idle tick stats the unlisted seed dir and starts no process; a client's own file there moves
    /// its mtime (one readdir) but no .sock, so nothing starts; a session coming or going there syncs once (one
    /// `--ls-json` per seed dir: two); a session in the listed dir is the poll's own, nothing here. Fake files only.
    @MainActor func testTheUnlistedSeedDirIsScannedWithoutAProcessPerTick() {
        usePattern(tabs: true, "-qa")
        let s = seedScanned(tempDir().appendingPathComponent("config").path), fm = FileManager.default
        XCTAssertEqual(s.d.called(), [["--build"], ["--ls-json"], ["--ls-json"]], "reload's sync")
        XCTAssertTrue(s.tick() == (0, 1), "the first tick reads the dir once and only records it")
        for i in 0..<3 { XCTAssertTrue(s.tick() == (0, 0), "idle tick \(i): one stat, no readdir, no process") }
        XCTAssertTrue(fm.createFile(atPath: s.unlisted + "/api.sock.client.4242", contents: nil))
        XCTAssertTrue(s.tick() == (0, 1), "a client's file: one readdir, the .sock set unmoved, no process")
        XCTAssertTrue(fm.createFile(atPath: s.unlisted + "/api.sock", contents: nil))
        let came = s.tick()
        XCTAssertTrue(came.forks <= 2 && came.forks > 0, "a session came: \(came.forks) starts")
        XCTAssertEqual(Array(s.d.called().suffix(2)), [["--ls-json"], ["--ls-json"]])
        XCTAssertTrue(s.tick() == (0, 0), "idle again")
        XCTAssertNoThrow(try fm.removeItem(atPath: s.unlisted + "/api.sock"))
        XCTAssertEqual(s.tick().forks, 2, "the session went: one sync")
        XCTAssertTrue(fm.createFile(atPath: s.listed + "/api-qa.sock", contents: nil))
        XCTAssertTrue(s.tick() == (0, 0), "the listed dir is the poll's: not scanned here")
    }

    /// #1185 (b1): a 1.29.x master that appears in the seed dir the poll does not list writes false at its first
    /// tick, and true comes back at the tick after it goes.
    @MainActor func testA129MasterInTheUnlistedSeedDirWritesFalse() {
        usePattern(tabs: true, "-qa")
        let file = tempDir().appendingPathComponent("config").path, s = seedScanned(file)
        let on = "auto_allow = true\nsidekick_pattern = -qa\n", off = "auto_allow = false\nsidekick_pattern = -qa\n"
        XCTAssertEqual(read(file), on)
        _ = s.tick()
        s.d.lock.withLock { s.d.ls[s.unlisted] = #"[{"name":"api","version":"1.29.1"}]"# }
        XCTAssertTrue(FileManager.default.createFile(atPath: s.unlisted + "/api.sock", contents: nil))
        _ = s.tick()
        XCTAssertEqual(read(file), off, "the 1.29.1 master came: false at its first tick")
        s.d.lock.withLock { s.d.ls[s.unlisted] = "[]" }
        XCTAssertNoThrow(try FileManager.default.removeItem(atPath: s.unlisted + "/api.sock"))
        _ = s.tick()
        XCTAssertEqual(read(file), on, "it went: true again")
    }

    /// #1185 (QA 916): a config with a NUL line rewrites with that line cut at the NUL (what dch reads stays; a line
    /// with a NUL first goes), and the next read sees no NUL (a `--config` timeout then reads false: the island answers).
    func testARewriteCutsANulLine() {
        let path = tempDir().appendingPathComponent("config").path
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("# mine\nfoo = 1\u{0}2\n\u{0}bar = 3\nauto_allow = true\n".utf8)))
        XCTAssertTrue(DchConfigWriter.mayAllow(path: path), "before: a NUL reads unknown")
        XCTAssertEqual(DchConfigWriter.write(path: path, autoAllow: false, pattern: "-qa"), .written)
        let d = FileManager.default.contents(atPath: path) ?? Data()
        XCTAssertFalse(d.contains(0), "the next read sees no NUL")
        XCTAssertEqual(read(path), "# mine\nfoo = 1\nauto_allow = false\nsidekick_pattern = -qa\n")
        XCTAssertFalse(DchConfigWriter.mayAllow(path: path), "a later timeout reads false")
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

        // #1179: a NUL byte anywhere: dch reads each line up to it; Prosper says unknown, so the island stands down.
        let nul: [(String, Bool)] = [   // the file, what dch reads
            ("auto_allow = true\u{0} # off\n", true),                    // after the value
            ("\u{0}auto_allow = true\n", false),                         // before the key
            ("auto_allow = true\n# a\u{0}b\n", true),                    // in another line
            ("auto_allow = false\nauto_allow = yes\u{0}\n", true),
            ("auto_allow = false\n\u{0}\n", false),
        ]
        for (text, dch) in nul {
            XCTAssertEqual(Self.dchAllows(Data(text.utf8)), dch, "dch: \(text.debugDescription)")
            XCTAssertTrue(DchConfigWriter.dchAllows(Data(text.utf8)) == nil, "unknown: \(text.debugDescription)")
        }
        XCTAssertTrue(DchConfigWriter.mayAllow(path: file("nul", "auto_allow = true\u{0} # off\n")), "a NUL byte: unknown")
        XCTAssertTrue(DchConfigWriter.mayAllow(path: file("nulOff", "\u{0}auto_allow = true\n")), "even where dch reads false")
    }

    /// #1179: render finds exactly the key lines dch finds in a line holding a NUL byte (dch sees the bytes up to
    /// the NUL). So turning the toggle off writes a false dch reads, wherever the NUL stands. #1185: any other such line is cut at the NUL.
    func testANulByteLineIsCutAndItsKeyFound() {
        for set in ["auto_allow = true", " \tauto_allow\t=\tyes"] {
            let b = Array(set.utf8)
            for i in 0...b.count {
                let line = Data(b[..<i]) + Data([0]) + Data(b[i...]), old = line + Data("\n".utf8)
                XCTAssertEqual(DchConfigWriter.setsKey(line, "auto_allow"), DchConfigWriter.setsKey(line.prefix { $0 != 0 }, "auto_allow"),
                               "NUL at \(i) of \(set.debugDescription)")
                let new = DchConfigWriter.render(old, autoAllow: false, pattern: "-qa")
                XCTAssertFalse(Self.dchAllows(new), "dch reads false: NUL at \(i) of \(set.debugDescription)")
            }
        }
        let path = tempDir().appendingPathComponent("config").path
        let old = "auto_allow = true\u{0} # off\n\u{0}auto_allow = true\nsidekick_pattern = a\u{0}b\n# note\u{0}x\n"
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(old.utf8)))
        XCTAssertEqual(DchConfigWriter.write(path: path, autoAllow: false, pattern: "-qa"), .written, "no new refusal")
        XCTAssertEqual(read(path), "auto_allow = false\nsidekick_pattern = -qa\n# note\n",
                       "#1185: a line that sets no owned key is cut at its NUL, and dropped when nothing is left before it")
        let d = FileManager.default.contents(atPath: path) ?? Data()
        XCTAssertFalse(Self.dchAllows(d))
        XCTAssertEqual(Self.dchValue(d, "sidekick_pattern"), "-qa")
        XCTAssertTrue(DchConfigWriter.dchAllows(d) == false, "#1185: no NUL left, so a timeout reads false, not unknown")
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
            ("a NUL after the value", "auto_allow = true\u{0} # off\n", false),   // #1179: dch reads true
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
        // #1179 r2: a stale timer fired while the burst still goes on runs no sync and writes nothing (its gen is old),
        // and the newer timers stay pending. Syncs are counted through the dchConfigPath seam (one call per sync).
        let paths = OSAllocatedUnfairLock(initialState: 0), path = shared.dchConfigPath
        shared.dchConfigPath = { paths.withLock { $0 += 1 }; return path() }
        let word = "-reviewer", before = read(file)
        for n in 1...3 {
            t += 1
            AgentIslandListSection.patternEdited(String(word.prefix(n)), now: Date(timeIntervalSince1970: t))
        }
        XCTAssertEqual(timers.pending.count, 3, "a timer per keystroke")
        guard let stale = timers.pending.first else { return XCTFail("no timer scheduled") }
        timers.pending.removeFirst()
        let syncs = paths.withLock { $0 }
        stale()
        shared.queue.sync {}
        XCTAssertEqual(paths.withLock { $0 }, syncs, "a stale timer runs no sync")
        XCTAssertEqual(read(file), before, "a stale timer writes nothing (not \"-re\")")
        XCTAssertEqual(timers.pending.count, 2, "the newer timers are still pending")
        writes = 0
        for n in 4...word.count {
            t += 1
            AgentIslandListSection.patternEdited(String(word.prefix(n)), now: Date(timeIntervalSince1970: t))
        }
        fire()
        let burst = writes
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

/// #1757 (#1755 contract): `group = <name> = <regex>` lines for dch 1.124.0+, sidekick_pattern = the first group's.
extension DchConfigWriterTests {
    private static func group(_ name: String, _ pattern: String) -> SessionGroup {
        SessionGroup(id: name, name: name, pattern: pattern)
    }

    func testGroupLinesReplaceTheFilesOwnAtTheFirstPlaceAndNilKeepsThem() {
        let old = Data("# mine\ngroup = Old = x\nauto_allow = false\n  group=Older=y\nsidekick_pattern = -qa\n".utf8)
        let lines = DchConfigWriter.groupValues([Self.group("QA", "-qa$"), Self.group("Rev", "-rev$")])
        XCTAssertEqual(lines, ["QA = -qa$", "Rev = -rev$"])
        XCTAssertEqual(String(decoding: DchConfigWriter.render(old, autoAllow: false, pattern: "-qa$", groups: lines), as: UTF8.self),
                       "# mine\ngroup = QA = -qa$\ngroup = Rev = -rev$\nauto_allow = false\nsidekick_pattern = -qa$\n")
        XCTAssertEqual(String(decoding: DchConfigWriter.render(old, autoAllow: false, pattern: "-qa$"), as: UTF8.self),
                       "# mine\ngroup = Old = x\nauto_allow = false\n  group=Older=y\nsidekick_pattern = -qa$\n", "an older dch: its lines kept")
        XCTAssertEqual(String(decoding: DchConfigWriter.render(Data(), autoAllow: false, pattern: "-qa$", groups: lines), as: UTF8.self),
                       "auto_allow = false\nsidekick_pattern = -qa$\ngroup = QA = -qa$\ngroup = Rev = -rev$\n", "appended in order")
        XCTAssertEqual(String(decoding: DchConfigWriter.render(old, autoAllow: false, pattern: "", groups: []), as: UTF8.self),
                       "# mine\nauto_allow = false\nsidekick_pattern = \n", "the empty list: no group line, sidekick_pattern empty")
    }

    func testGroupValuesSkipWhatDchWouldSkipAndStopAtEight() {
        let bad = [Self.group("a=b", "-x"), Self.group(String(repeating: "n", count: 33), "-x"),
                   Self.group("Dots", "a.b"), Self.group("Blank", " ")]
        XCTAssertEqual(DchConfigWriter.groupValues(bad + [Self.group(" Ok ", "-ok$")]), ["Blank =", "Ok = -ok$"],
                       "an \"=\" or a 33-byte name, a non-portable regex: no line; #2062: a blank one is manual-only")
        let ten = (1...10).map { Self.group("g\($0)", "-p\($0)$") }
        XCTAssertEqual(DchConfigWriter.groupValues(ten), (1...8).map { "g\($0) = -p\($0)$" })
    }

    func testTheGroupsGateIsDch1_124_0() {
        let values = ["QA = -qa$"]
        let bin = { (v: [Int]) in DchCommand.Binary(path: "/Users/example/bin/dch", version: v) }
        XCTAssertNil(DchConfigWriter.groupLines(values, dch: bin([1, 123, 9])))
        XCTAssertNil(DchConfigWriter.groupLines(values, dch: nil), "no dch found: the file's lines kept")
        XCTAssertEqual(DchConfigWriter.groupLines(values, dch: bin([1, 124, 0])), values)
        XCTAssertEqual(DchConfigWriter.groupLines(values, dch: bin([2, 0, 0])), values)
    }

    /// The controller writes the stored groups for dch 1.124.0 and only sidekick_pattern (the first group's) below it.
    @MainActor func testTheControllerWritesGroupsOnlyForADchThatReadsThem() {
        usePattern(tabs: true, "-qa")
        let saved = Preferences.defaults.object(forKey: "agentIslandSessionGroups")
        addTeardownBlock {
            if let saved { Preferences.defaults.set(saved, forKey: "agentIslandSessionGroups") } else {
                Preferences.defaults.removeObject(forKey: "agentIslandSessionGroups")
            }
        }
        Preferences.agentIslandSessionGroups = [Self.group("Rev", "-rev$"), Self.group("Blank", ""), Self.group("QA", "-qa$")]
        for (v, want) in [([1, 123, 9], "auto_allow = false\nsidekick_pattern = -rev$\n"),
                          ([1, 124, 0], "auto_allow = false\nsidekick_pattern = -rev$\ngroup = Rev = -rev$\ngroup = Blank =\ngroup = QA = -qa$\n"
                           + "group_color = Rev = #2563EB\ngroup_color = Blank = #15803D\ngroup_color = QA = #DC2626\n")] {
            let file = tempDir("groupsGate").appendingPathComponent("config").path
            let (c, _) = controller(FakeIO(), on: false, version: v, build: "full", config: file)
            c.syncDchConfig()
            c.queue.sync {}
            XCTAssertEqual(read(file), want, "dch \(v)")
        }
        Preferences.agentIslandSessionGroups = []
        let file = tempDir("groupsEmpty").appendingPathComponent("config").path
        FileManager.default.createFile(atPath: file, contents: Data("group = Old = x\n".utf8))
        let (c, _) = controller(FakeIO(), on: false, version: [1, 124, 0], build: "full", config: file)
        c.syncDchConfig()
        c.queue.sync {}
        XCTAssertEqual(read(file), "auto_allow = false\nsidekick_pattern = \n", "the empty list: an empty key, never a missing one")
    }

    /// #2062 round 4: a blank legacy Sidekicks group (sidekicksID, the #571 key) is "no split", as before #2062, never a
    /// manual-only group: a stored [Sidekicks "", Ops ""] writes only `group = Ops =`, gives Sidekicks no tab and the
    /// Settings editor does not save it; Ops (a fresh id) stays manual.
    @MainActor func testABlankSidekicksGroupIsOffNotManual() {
        usePattern(tabs: true, "-qa")
        let saved = Preferences.defaults.object(forKey: "agentIslandSessionGroups")
        addTeardownBlock {
            if let saved { Preferences.defaults.set(saved, forKey: "agentIslandSessionGroups") } else {
                Preferences.defaults.removeObject(forKey: "agentIslandSessionGroups")
            }
        }
        let sk = SessionGroup(id: SessionGroup.sidekicksID, name: "Sidekicks", pattern: ""), ops = Self.group("Ops", "")
        XCTAssertTrue(sk.isOff && !sk.isManual && ops.isManual && !ops.isOff)
        XCTAssertEqual(DchConfigWriter.groupValues([sk, ops]), ["Ops ="])
        Preferences.agentIslandSessionGroups = [sk, ops]
        let file = tempDir("blankSidekicks").appendingPathComponent("config").path
        let (c, _) = controller(FakeIO(), on: false, version: [1, 199, 0], build: "full", config: file)
        c.syncDchConfig()
        c.queue.sync {}
        XCTAssertEqual(read(file), "auto_allow = false\nsidekick_pattern = \ngroup = Ops =\ngroup_color = Ops = #15803D\n")
        c.rowDetailsChanged()
        XCTAssertEqual(c.store?.sessionGroups.map(\.name), ["Ops"], "no Sidekicks tab, not in Move to group")
        let e = SessionGroupsEditor([sk, ops])
        XCTAssertEqual(e.reason(sk, stored: []), "No pattern yet: not saved")
        XCTAssertEqual(e.saved(stored: [sk, ops]), [ops], "the editor's save leaves the blank Sidekicks out, stored or not")
    }

    /// #1765: auto_allow = false lands before the dch probe returns; the group lines follow in a second write for
    /// dch 1.124.0 and the file keeps its own below it.
    @MainActor func testTheOffWriteLandsBeforeTheProbeReturns() {
        usePattern(tabs: true, "-qa")
        let saved = Preferences.defaults.object(forKey: "agentIslandSessionGroups")
        addTeardownBlock {
            if let saved { Preferences.defaults.set(saved, forKey: "agentIslandSessionGroups") } else {
                Preferences.defaults.removeObject(forKey: "agentIslandSessionGroups")
            }
        }
        Preferences.agentIslandSessionGroups = [Self.group("Rev", "-rev$")]
        for (v, want) in [([1, 123, 9], "auto_allow = false\ngroup = Old = x\nsidekick_pattern = -rev$\n"),
                          ([1, 124, 0], "auto_allow = false\ngroup = Rev = -rev$\ngroup_color = Rev = #2563EB\nsidekick_pattern = -rev$\n")] {
            let file = tempDir("offFirst").appendingPathComponent("config").path
            FileManager.default.createFile(atPath: file, contents: Data("auto_allow = true\ngroup = Old = x\n".utf8))
            let (c, _) = controller(FakeIO(), on: false, version: v, build: "full", config: file)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let bin = DchCommand.Binary(path: "/Users/example/bin/dch", version: v)
            c.controlDch = { entered.signal(); _ = release.wait(timeout: .now() + 5); return bin }
            c.syncDchConfig()
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "dch \(v): the probe was reached")
            let first = read(file)
            release.signal()
            c.queue.sync {}
            XCTAssertEqual(first, "auto_allow = false\ngroup = Old = x\nsidekick_pattern = -rev$\n",
                           "dch \(v): written before the probe returned, the file's own lines kept")
            XCTAssertEqual(read(file), want, "dch \(v)")
        }
    }
}

/// #1766 (QA R1757 n85): while the list is unstored, the group lines already in dch's file become the stored list
/// instead of being replaced with the migrated Sidekicks group; a stored list replacing different lines logs once.
/// Every file is a row's tempDir(); the defaults are the XCTest store's, put back after the row.
extension DchConfigWriterTests {
    /// No stored list for the row (the getter migrates) and no adopt check yet (#1788), both put back after it.
    private func unstoredGroups() {
        let saved = Preferences.defaults.object(forKey: "agentIslandSessionGroups")
        let checked = Preferences.defaults.object(forKey: "agentIslandDchGroupsAdoptChecked") as? Bool
        addTeardownBlock {
            if let saved { Preferences.defaults.set(saved, forKey: "agentIslandSessionGroups") } else {
                Preferences.defaults.removeObject(forKey: "agentIslandSessionGroups")
            }
            if let checked { Preferences.defaults.set(checked, forKey: "agentIslandDchGroupsAdoptChecked") } else {
                Preferences.defaults.removeObject(forKey: "agentIslandDchGroupsAdoptChecked")
            }
        }
        Preferences.defaults.removeObject(forKey: "agentIslandSessionGroups")
        Preferences.defaults.removeObject(forKey: "agentIslandDchGroupsAdoptChecked")
    }

    private func configFile(_ name: String, _ text: String) -> String {
        let file = tempDir(name).appendingPathComponent("config").path
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: Data(text.utf8)))
        return file
    }

    func testFileGroupValuesFindTheLinesRenderOwns() {
        let file = configFile("groupValues", "# group = Not = a\ngroup = Rev = -rev$\r\n  group=Older=y\ngroup_x = 1\n"
                              + "group = Cut = -c$\u{0}tail\n")
        XCTAssertEqual(DchConfigWriter.fileGroupValues(path: file), ["Rev = -rev$", "Older=y", "Cut = -c$"])
        var bad = Data("group = ".utf8)
        bad.append(contentsOf: [0xFF, 0x0A])
        bad.append(contentsOf: Array("group = QA = -qa$\n".utf8))
        XCTAssertTrue(FileManager.default.createFile(atPath: file, contents: bad))
        XCTAssertEqual(DchConfigWriter.fileGroupValues(path: file), ["QA = -qa$"], "a non-UTF-8 value skipped")
        XCTAssertEqual(DchConfigWriter.fileGroupValues(path: file + "-missing"), [])
        XCTAssertEqual(DchConfigWriter.fileGroupValues(path: (file as NSString).deletingLastPathComponent), [], "a folder")
    }

    func testAdoptableKeepsWhatDchKeepsAndStopsAtEight() {
        let got = DchConfigWriter.adoptable(["Rev = -rev$", "Dots = a.b", " = -x", String(repeating: "n", count: 33) + " = -x",
                                            "Blank = ", "noequal", "rev = -dup$", "Older=y"])
        XCTAssertEqual(got.map { "\($0.name) = \($0.pattern)" }, ["Rev = -rev$", "Blank = ", "Older = y"],
                       "a non-portable regex, a blank or 33-byte name, no \"=\", a second Rev: dropped; #2062: a blank regex is manual-only")
        XCTAssertEqual(Set(got.map(\.id)).count, 3, "an id each")
        XCTAssertTrue(got.allSatisfy { $0.id.count == 8 && $0.id != SessionGroup.sidekicksID })
        let ten = DchConfigWriter.adoptable((1...10).map { "g\($0) = -p\($0)$" })
        XCTAssertEqual(ten.map(\.name), (1...8).map { "g\($0)" })
    }

    @MainActor func testAnUnstoredListAdoptsTheFilesGroupLinesInOrder() {
        unstoredGroups()
        usePattern(tabs: true, "-qa")
        Preferences.agentIslandSessionGroupsUpdated = 0
        let file = configFile("adopt", "group = Rev = -rev$\n# mine\ngroup = QA = -qa$\n")
        let (c, _) = controller(FakeIO(), on: false, version: [1, 124, 0], build: "full", config: file)
        let logged = OSAllocatedUnfairLock(initialState: 0)
        c.groupsReplaced = { _, _ in logged.withLock { $0 += 1 } }
        c.syncDchConfig()
        drain(c)
        XCTAssertTrue(Preferences.agentIslandSessionGroupsStored)
        XCTAssertTrue(Preferences.agentIslandDchGroupsAdoptChecked, "#1788: the one check is flagged")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map { "\($0.name) = \($0.pattern)" }, ["Rev = -rev$", "QA = -qa$"])
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 1_000_000_000, "stamped as an edit (the controller's now)")
        XCTAssertEqual(read(file), "group = Rev = -rev$\n# mine\ngroup = QA = -qa$\nauto_allow = false\nsidekick_pattern = -qa\n",
                       "this sync keeps the file's lines")
        c.syncDchConfig()   // the write rowDetailsChanged schedules
        drain(c)
        XCTAssertEqual(read(file), "group = Rev = -rev$\ngroup = QA = -qa$\ngroup_color = Rev = #2563EB\ngroup_color = QA = #15803D\n"
                       + "# mine\nauto_allow = false\nsidekick_pattern = -rev$\n",
                       "the same lines, from the stored list")
        XCTAssertEqual(logged.withLock { $0 }, 0, "nothing replaced")
    }

    /// No valid group line: the Sidekicks group is written as before and the list stays unstored (lazy migration).
    @MainActor func testAnUnstoredListWithNoValidLinesWritesSidekicksAsBefore() {
        unstoredGroups()
        usePattern(tabs: true, "-qa")
        for (old, want) in [("picker_sort = name\n", "picker_sort = name\nauto_allow = false\nsidekick_pattern = -qa\ngroup = Sidekicks = -qa\ngroup_color = Sidekicks = #2563EB\n"),
                            ("group = Dots = a.b\n", "group = Sidekicks = -qa\ngroup_color = Sidekicks = #2563EB\nauto_allow = false\nsidekick_pattern = -qa\n")] {
            unstoredGroups()
            let file = configFile("noLines", old)
            let (c, _) = controller(FakeIO(), on: false, version: [1, 124, 0], build: "full", config: file)
            c.syncDchConfig()
            drain(c)
            XCTAssertFalse(Preferences.agentIslandSessionGroupsStored, old)
            XCTAssertEqual(read(file), want, old)
        }
    }

    /// #1780: two syncs, unstored and no hand lines: Prosper's own Sidekicks line is never adopted (no random id, no stamp move, no log).
    @MainActor func testAnUnstoredListDoesNotAdoptProspersOwnLines() {
        unstoredGroups()
        usePattern(tabs: true, "-qa")
        Preferences.agentIslandSessionGroupsUpdated = 7
        let file = configFile("own", "picker_sort = name\n")
        let (c, _) = controller(FakeIO(), on: false, version: [1, 124, 0], build: "full", config: file)
        let logged = OSAllocatedUnfairLock(initialState: 0)
        c.groupsReplaced = { _, _ in logged.withLock { $0 += 1 } }
        for _ in 0..<2 {
            c.syncDchConfig()
            drain(c)
        }
        XCTAssertTrue((read(file) ?? "").hasSuffix("group = Sidekicks = -qa\ngroup_color = Sidekicks = #2563EB\n"))
        XCTAssertFalse(Preferences.agentIslandSessionGroupsStored)
        XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, 7)
        XCTAssertEqual(logged.withLock { $0 }, 0)
    }

    /// #1779: a refused line is dropped from the adopted lines with one log; all refused: Sidekicks, one log.
    @MainActor func testDroppedGroupLinesLogOnceThroughTheSeam() {
        for (old, adopted, want) in [("group = Rev = -rev$\ngroup = Dots = a.b\n", ["Rev"],
                                      [["Rev = -rev$", "Dots = a.b", "->", "Rev = -rev$"]]),
                                     ("group = Dots = a.b\n", [], [["Dots = a.b", "->", "Sidekicks = -qa"]])] as [(String, [String], [[String]])] {
            unstoredGroups()
            usePattern(tabs: true, "-qa")
            let file = configFile("dropped", old)
            let (c, _) = controller(FakeIO(), on: false, version: [1, 124, 0], build: "full", config: file)
            let logged = OSAllocatedUnfairLock<[[String]]>(initialState: [])
            c.groupsReplaced = { had, lines in logged.withLock { $0.append(had + ["->"] + lines) } }
            c.syncDchConfig()
            drain(c)
            XCTAssertEqual(Preferences.agentIslandSessionGroupsStored, !adopted.isEmpty, old)
            if !adopted.isEmpty { XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.name), adopted, old) }
            XCTAssertEqual(logged.withLock { $0 }, want, old)
        }
    }

    @MainActor func testAStoredListReplacesDifferentLinesAndLogsOnce() {
        unstoredGroups()
        usePattern(tabs: true, "-qa")
        Preferences.agentIslandSessionGroups = [Self.group("Rev", "-rev$")]
        let file = configFile("replace", "group = Old = x\n")
        let (c, _) = controller(FakeIO(), on: false, version: [1, 124, 0], build: "full", config: file)
        let logged = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        c.groupsReplaced = { had, lines in logged.withLock { $0.append(had + ["->"] + lines) } }
        c.syncDchConfig()
        drain(c)
        XCTAssertEqual(read(file), "group = Rev = -rev$\ngroup_color = Rev = #2563EB\nauto_allow = false\nsidekick_pattern = -rev$\n")
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.name), ["Rev"], "the stored list is never adopted over")
        c.adoptDchGroups([Self.group("Late", "-late$")])   // an adopt hop landing after a save
        XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.name), ["Rev"], "a list stored meanwhile wins")
        c.syncDchConfig()
        drain(c)
        XCTAssertEqual(logged.withLock { $0 }, [["Old = x", "->", "Rev = -rev$"]], "one line, and none once equal")
    }

    @MainActor func testBelowDch1_124_0NothingIsAdopted() {
        unstoredGroups()
        usePattern(tabs: true, "-qa")
        for v in [[1, 123, 9], nil] as [[Int]?] {
            let file = configFile("old", "group = Rev = -rev$\n")
            let (c, _) = controller(FakeIO(), on: false, version: v, build: "full", config: file)
            let logged = OSAllocatedUnfairLock(initialState: 0)
            c.groupsReplaced = { _, _ in logged.withLock { $0 += 1 } }
            c.syncDchConfig()
            drain(c)
            XCTAssertFalse(Preferences.agentIslandSessionGroupsStored, "\(String(describing: v))")
            XCTAssertFalse(Preferences.agentIslandDchGroupsAdoptChecked, "#1788: no check without a dch that reads group lines")
            XCTAssertEqual(read(file), "group = Rev = -rev$\nauto_allow = false\nsidekick_pattern = -qa\n")
            XCTAssertEqual(logged.withLock { $0 }, 0)
        }
    }

    /// #1788 (QA R1776+1780 b2), all unstored: a first sync, then a phone pattern, a cleared pattern and Group tabs
    /// off, each followed by a sync. The file holds Prosper's previous lines every time: nothing is adopted, the #571
    /// value stays, its stamps stay the phone's (not the controller's now) and the file follows.
    @MainActor func testProspersPreviousLinesAreNeverAdoptedAfterTheFirstCheck() {
        unstoredGroups()
        usePattern(tabs: true, "-qa")
        Preferences.agentIslandSessionGroupsUpdated = 0
        let file = configFile("once", "picker_sort = name\n")
        let (c, _) = controller(FakeIO(), on: false, version: [1, 124, 0], build: "full", config: file)
        let logged = OSAllocatedUnfairLock(initialState: 0)
        c.groupsReplaced = { _, _ in logged.withLock { $0 += 1 } }
        c.syncDchConfig()
        drain(c)
        XCTAssertTrue(Preferences.agentIslandDchGroupsAdoptChecked, "flagged though nothing was adopted")
        XCTAssertTrue((read(file) ?? "").hasSuffix("group = Sidekicks = -qa\ngroup_color = Sidekicks = #2563EB\n"))
        for (step, pattern, tabs, want) in [(1, "-new", true, "group = Sidekicks = -new\ngroup_color = Sidekicks = #2563EB\n"), (2, "", true, nil),
                                            (3, "-qa", true, "group = Sidekicks = -qa\ngroup_color = Sidekicks = #2563EB\n"), (4, "-qa", false, nil)] as [(Int64, String, Bool, String?)] {
            if tabs { Preferences.adoptSidekickPattern(pattern, updated: step) } else { Preferences.agentIslandSidekickTabs = false }
            c.syncDchConfig()
            drain(c)
            let text = read(file) ?? ""
            XCTAssertFalse(Preferences.agentIslandSessionGroupsStored, "step \(step): nothing adopted")
            XCTAssertEqual(Preferences.agentIslandSidekickPattern, pattern, "step \(step): the #571 value stays")
            XCTAssertEqual(Preferences.agentIslandSessionGroups.map(\.id), [SessionGroup.sidekicksID], "step \(step)")
            XCTAssertEqual(Preferences.agentIslandSidekickPatternUpdated, tabs ? step : 3, "step \(step): the phone's stamp")
            XCTAssertEqual(Preferences.agentIslandSessionGroupsUpdated, tabs ? step : 3, "step \(step): not moved to now")
            if let want {
                XCTAssertTrue(text.hasSuffix(want) && text.contains("sidekick_pattern = \(pattern)\n"), "step \(step): \(text)")
            } else {
                XCTAssertFalse(text.contains("group = "), "step \(step): the file follows, no group line: \(text)")
                XCTAssertTrue(text.contains("sidekick_pattern = \n"), "step \(step): \(text)")
            }
        }
        // As for a stored list, a write that changes the file's group lines logs once (steps 1, 2, 4; step 3 had none).
        XCTAssertEqual(logged.withLock { $0 }, 3)
    }

    /// #1780 kept under #1788: the first check finding exactly Prosper's own line (an earlier Prosper's write) adopts
    /// nothing, logs nothing and flags the check.
    @MainActor func testTheFirstCheckOnProspersOwnLineAdoptsNothing() {
        unstoredGroups()
        usePattern(tabs: true, "-qa")
        let file = configFile("ownFirst", "group = Sidekicks = -qa\n")
        let (c, _) = controller(FakeIO(), on: false, version: [1, 124, 0], build: "full", config: file)
        let logged = OSAllocatedUnfairLock(initialState: 0)
        c.groupsReplaced = { _, _ in logged.withLock { $0 += 1 } }
        c.syncDchConfig()
        drain(c)
        XCTAssertFalse(Preferences.agentIslandSessionGroupsStored)
        XCTAssertTrue(Preferences.agentIslandDchGroupsAdoptChecked)
        XCTAssertEqual(logged.withLock { $0 }, 0)
    }

    /// #1788: once checked, a hand-written line is not adopted (the file follows the list, one log), and an adopt hop
    /// queued by a sync captured before the flag landed changes nothing.
    @MainActor func testOnceCheckedAHandLineIsReplacedNotAdopted() {
        unstoredGroups()
        usePattern(tabs: true, "-qa")
        Preferences.agentIslandDchGroupsAdoptChecked = true
        let file = configFile("checked", "group = Rev = -rev$\n")
        let (c, _) = controller(FakeIO(), on: false, version: [1, 124, 0], build: "full", config: file)
        let logged = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        c.groupsReplaced = { had, lines in logged.withLock { $0.append(had + ["->"] + lines) } }
        c.syncDchConfig()
        drain(c)
        XCTAssertFalse(Preferences.agentIslandSessionGroupsStored)
        XCTAssertEqual(read(file), "group = Sidekicks = -qa\ngroup_color = Sidekicks = #2563EB\nauto_allow = false\nsidekick_pattern = -qa\n")
        XCTAssertEqual(logged.withLock { $0 }, [["Rev = -rev$", "->", "Sidekicks = -qa"]])
        c.adoptDchGroups([Self.group("Late", "-late$")])
        XCTAssertFalse(Preferences.agentIslandSessionGroupsStored, "a late hop adopts nothing")
    }
}
