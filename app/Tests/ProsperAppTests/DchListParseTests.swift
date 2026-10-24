import XCTest
@testable import ProsperApp

/// The session list feeds the phone's UI, including each agent's state. dch 1.4
/// answers `--ls-json`; older binaries only have `-lj`'s TSV, so both shapes must
/// parse and a garbage/empty read must not invent sessions.
final class DchListParseTests: XCTestCase {

    func testParsesLsJson() {
        let json = """
        [{"name":"a","alias":"Agent A","activity_epoch":1784995163,"state":"blocked"},
         {"name":"b","alias":"","activity_epoch":0,"state":"idle"}]
        """
        let rows = DchCommand.parseListJSON(Data(json.utf8))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "a")
        XCTAssertEqual(rows[0].alias, "Agent A")
        XCTAssertEqual(rows[0].activityEpoch, 1784995163)
        XCTAssertEqual(rows[0].state, "blocked")
        XCTAssertEqual(rows[1].alias, "")
        XCTAssertEqual(rows[1].state, "idle")
    }

    /// `dch -l` labels a session with its alias, else the Claude Code session name
    /// running inside it. The phone shows the same, so an empty alias falls back to
    /// `harness` and only then to the raw socket name.
    func testHarnessNameFillsInForEmptyAlias() {
        let json = """
        [{"name":"prosper-main","alias":"","harness":"prosper","state":"working"},
         {"name":"a","alias":"Agent A","harness":"ignored","state":"idle"},
         {"name":"b","alias":"","harness":"","state":"idle"}]
        """
        let rows = DchCommand.parseListJSON(Data(json.utf8))
        XCTAssertEqual(rows[0].alias, "prosper")
        XCTAssertEqual(rows[1].alias, "Agent A")   // explicit alias still wins
        XCTAssertEqual(rows[2].alias, "")          // neither: the client shows the name
    }

    /// Newer dch counts the live subagents on Claude Code's agent panel; older dch
    /// omits the field, which reads as none rather than failing the row.
    func testParsesAgentCount() {
        let json = """
        [{"name":"a","state":"working","agents":3},
         {"name":"b","state":"idle"}]
        """
        let rows = DchCommand.parseListJSON(Data(json.utf8))
        XCTAssertEqual(rows[0].agents, 3)
        XCTAssertEqual(rows[1].agents, 0)
    }

    /// An older dch prints nothing for `--ls-json` — the caller must see "no rows"
    /// and fall back to the TSV list, not a half-built row.
    func testEmptyAndGarbageJsonYieldNoRows() {
        XCTAssertTrue(DchCommand.parseListJSON(Data()).isEmpty)
        XCTAssertTrue(DchCommand.parseListJSON(Data("dch: unknown option\n".utf8)).isEmpty)
        XCTAssertTrue(DchCommand.parseListJSON(Data("[{\"alias\":\"no name\"}]".utf8)).isEmpty)
    }

    // MARK: - Session meta (#506, dch 1.22)

    /// The README's exact rows, and a dch 1.21.1 row without either key.
    func testMetaDecodesWithAndWithoutTheKeys() {
        let json = """
        [{"name":"prosper-main","alias":"","harness":"prosper","activity_epoch":1792841476,"state":"working","version":"1.21.1","agents":2,"meta":{"tasks":{"done":485,"total":503,"in_progress":5,"queued":13},"prs":{"open":[],"merged":0}},"meta_epoch":1792841470},
         {"name":"b","alias":"","activity_epoch":1,"state":"idle","meta":{"tasks":{"done":22,"total":26,"in_progress":2,"queued":2},"prs":{"open":[{"url":"https://github.com/o/r/pull/12","repo":"o/r","num":12,"title":"Fix the thing"}],"merged":18}},"meta_epoch":1792841470},
         {"name":"old","alias":"A","activity_epoch":7,"state":"blocked","agents":1},
         {"name":"nul","alias":"","state":"idle","meta":null,"meta_epoch":0}]
        """
        let rows = DchCommand.parseListJSON(Data(json.utf8))
        XCTAssertEqual(rows.map(\.name), ["prosper-main", "b", "old", "nul"])
        XCTAssertEqual(rows[0].meta, DchSessionMeta(tasks: .init(done: 485, total: 503, inProgress: 5, queued: 13),
                                                    openPRs: [], merged: 0))
        XCTAssertEqual(rows[0].metaEpoch, 1792841470)
        XCTAssertEqual(rows[0].alias, "prosper")
        XCTAssertEqual(rows[0].agents, 2)
        XCTAssertEqual(rows[1].meta?.openPRs, [DchSessionMeta.PR(url: "https://github.com/o/r/pull/12", repo: "o/r",
                                                                 num: 12, title: "Fix the thing")])
        XCTAssertEqual(rows[1].meta?.merged, 18)
        XCTAssertEqual(rows[2], DchListRow(name: "old", alias: "A", activityEpoch: 7, state: "blocked", agents: 1),
                       "dch 1.21.1: no meta, epoch 0, the rest as before")
        XCTAssertNil(rows[3].meta)
        XCTAssertEqual(rows[3].metaEpoch, 0)
    }

    /// Any program in the session writes meta: a wrong type drops that key only.
    func testWrongTypedMetaKeysDropOnlyThemselves() {
        let json = """
        [{"name":"a","alias":"A","activity_epoch":5,"state":"working","agents":3,"meta_epoch":"soon",
          "meta":{"tasks":{"done":"5","total":true,"in_progress":2.5,"queued":4,"extra":{}},
                  "prs":{"open":[1,"x",{"url":5,"repo":"o/r","num":"7","title":["t"]},{"repo":"o/q","num":3}],"merged":"many"},
                  "unknown":[1,2]}},
         {"name":"b","state":"idle","meta":"not an object"},
         {"name":"c","state":"idle","meta":{"tasks":[],"prs":{"open":{"url":"x"},"merged":2}}}]
        """
        let rows = DchCommand.parseListJSON(Data(json.utf8))
        XCTAssertEqual(rows.map(\.name), ["a", "b", "c"], "no row dropped")
        XCTAssertEqual(rows[0].alias, "A"); XCTAssertEqual(rows[0].activityEpoch, 5)
        XCTAssertEqual(rows[0].state, "working"); XCTAssertEqual(rows[0].agents, 3)
        XCTAssertEqual(rows[0].metaEpoch, 0)
        XCTAssertEqual(rows[0].meta?.tasks, .init(done: nil, total: nil, inProgress: nil, queued: 4),
                       "a string, a bool and a fraction drop; the integer stays")
        XCTAssertEqual(rows[0].meta?.openPRs, [.init(url: "", repo: "o/r", num: nil, title: ""),
                                               .init(url: "", repo: "o/q", num: 3, title: "")])
        XCTAssertNil(rows[0].meta?.merged)
        XCTAssertNil(rows[1].meta, "not an object: no meta, row kept")
        XCTAssertEqual(rows[1].state, "idle")
        XCTAssertNil(rows[2].meta?.tasks)
        XCTAssertEqual(rows[2].meta?.openPRs, [])
        XCTAssertEqual(rows[2].meta?.merged, 2)
    }

    func testNegativeMetaCountsClampToZero() {
        let json = """
        [{"name":"a","meta_epoch":-9,"meta":{"tasks":{"done":-1,"total":-2,"in_progress":-3,"queued":-4},
          "prs":{"open":[{"url":"u","repo":"o/r","num":-5,"title":""}],"merged":-6}}}]
        """
        let row = DchCommand.parseListJSON(Data(json.utf8))[0]
        XCTAssertEqual(row.meta?.tasks, .init(done: 0, total: 0, inProgress: 0, queued: 0))
        XCTAssertEqual(row.meta?.merged, 0)
        XCTAssertEqual(row.meta?.openPRs.first?.num, 0)
        XCTAssertEqual(row.metaEpoch, 0)
    }

    func testOpenPRListIsCappedAtFiftyOnDecode() {
        let open = (1...60).map { #"{"url":"https://github.com/o/r/pull/\#($0)","repo":"o/r","num":\#($0)}"# }
        let json = #"[{"name":"a","meta":{"prs":{"open":[\#(open.joined(separator: ","))]}}}]"#
        let prs = DchCommand.parseListJSON(Data(json.utf8))[0].meta?.openPRs ?? []
        XCTAssertEqual(prs.count, 50)
        XCTAssertEqual(prs.last?.num, 50)
    }

    /// Only https://github.com/<owner>/<repo>/pull/<digits> opens; everything else is a label.
    func testPullURLAllowlist() {
        func url(_ s: String) -> URL? { DchSessionMeta.PR(url: s, repo: "", num: nil, title: "").pullURL }
        XCTAssertEqual(url("https://github.com/o/r/pull/12"), URL(string: "https://github.com/o/r/pull/12"))
        XCTAssertNotNil(url("https://github.com/payhawk/solution.cdv2-x_y/pull/12794"))
        XCTAssertNotNil(url("https://github.com/\(String(repeating: "o", count: 39))/\(String(repeating: "r", count: 100))/pull/1"),
                        "GitHub's own limits: owner 39, repo 100")
        for bad in ["http://github.com/o/r/pull/12",            // scheme
                    "HTTPS://github.com/o/r/pull/12",
                    "https://github.com.evil.com/o/r/pull/12",  // lookalike host
                    "https://evilgithub.com/o/r/pull/12",
                    "https://www.github.com/o/r/pull/12",
                    "https://GitHub.com/o/r/pull/12",
                    "https://user@github.com/o/r/pull/12",      // userinfo
                    "https://user:pw@github.com/o/r/pull/12",
                    "https://github.com:443/o/r/pull/12",       // port
                    "https://github.com/o/r/issues/12",         // non-pull path
                    "https://github.com/o/r/pulls/12",
                    "https://github.com/o/r/pull",
                    "https://github.com/o/pull/12",
                    "https://github.com/o/r/pull/12/files",     // extra segment
                    "https://github.com/o/r/pull/12/",
                    "https://github.com//o/r/pull/12",
                    "https://github.com/o/r/pull/12?x=1",       // query
                    "https://github.com/o/r/pull/12?",
                    "https://github.com/o/r/pull/12#x",         // fragment
                    "https://github.com/o/r/pull/12#",
                    "https://github.com/o/r/pull/1a",           // non-digits
                    "https://github.com/o/r/pull/-1",
                    "https://github.com/o/r/pull/%31",
                    "https://github.com/o/r/pull/١٢",
                    "https://github.com/o/r/pull/1234567890",   // longer than any real PR number
                    "https://github.com/\(String(repeating: "o", count: 40))/r/pull/1",   // owner over 39
                    "https://github.com/o/\(String(repeating: "r", count: 101))/pull/1",  // repo over 100
                    "https://github.com/o/../pull/12",
                    "https://github.com/o/r%2Fx/pull/12",
                    "javascript:alert(1)", "file:///etc/passwd", "", "github.com/o/r/pull/12"] {
            XCTAssertNil(url(bad), bad)
        }
    }

    func testPRLabelNamesWhatOpens() {
        typealias PR = DchSessionMeta.PR
        XCTAssertEqual(PR(url: "https://github.com/o/prosper/pull/12", repo: "x/other", num: 99, title: "").label,
                       "prosper#12", "an allowlisted URL is the label's source")
        XCTAssertEqual(PR(url: "http://github.com/o/prosper/pull/12", repo: "o/r", num: 3, title: "").label, "r#3")
        XCTAssertNil(PR(url: "nope", repo: "o/r", num: nil, title: "").label)
        XCTAssertNil(PR(url: "", repo: "", num: 4, title: "").label)
    }

    func testParsesTsvWithoutState() {
        let rows = DchCommand.parseListTSV("a\tAgent A\t1784995163\nb\t\t0\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].name, "a")
        XCTAssertEqual(rows[0].alias, "Agent A")
        XCTAssertEqual(rows[0].activityEpoch, 1784995163)
        XCTAssertEqual(rows[0].state, "")   // unknown, and the UI shows nothing for it
        XCTAssertEqual(rows[1].name, "b")
    }

    // MARK: - Remote Terminal list wire (#507)

    private func wire(_ row: DchListRow) -> String {
        let d = try! JSONSerialization.data(withJSONObject: row.metaWire, options: [.sortedKeys])
        return String(decoding: d, as: UTF8.self)
    }

    private func row(_ json: String) -> DchListRow {
        DchCommand.parseListJSON(Data(json.utf8))[0]
    }

    /// The phone gets the same meta Agent Island shows, re-encoded from the decode.
    func testMetaWireReencodesDecodedMeta() {
        let r = row("""
        [{"name":"a","state":"idle","meta_epoch":1784995200,"meta":{"tasks":{"done":3,"total":7,"in_progress":1,"queued":2,"x":9},
          "prs":{"open":[{"url":"https://github.com/o/prosper/pull/12","repo":"o/prosper","num":12,"title":"Fix it","extra":1}],"merged":4},
          "junk":true}}]
        """)
        XCTAssertEqual(wire(r), #"{"meta":{"prs":{"merged":4,"open":[{"num":12,"repo":"o\/prosper","title":"Fix it","url":"https:\/\/github.com\/o\/prosper\/pull\/12"}]},"tasks":{"done":3,"in_progress":1,"queued":2,"total":7}},"meta_epoch":1784995200}"#)
    }

    func testMetaWireAbsentWithoutMeta() {
        var r = row(#"[{"name":"a","state":"idle","meta_epoch":5}]"#)
        XCTAssertNil(r.meta)
        XCTAssertEqual(r.metaEpoch, 5)
        XCTAssertTrue(r.metaWire.isEmpty)
        r.metaEpoch = 0
        r.meta = DchSessionMeta()
        XCTAssertTrue(r.metaWire.isEmpty, "an empty meta sends no keys")
    }

    /// #522: nothing left after filtering (no task fields, no allowlisted PR, no
    /// merged count) means no meta and no meta_epoch, as with no meta at all.
    func testMetaWireAbsentWhenNothingSurvives() {
        let r = row("""
        [{"name":"a","meta_epoch":9,"meta":{"tasks":{"total":"7"},"prs":{"open":[{"url":"javascript:alert(1)","num":1}]}}}]
        """)
        XCTAssertNotNil(r.meta)
        XCTAssertTrue(r.metaWire.isEmpty)
        XCTAssertEqual(wire(row(#"[{"name":"a","meta":{"prs":{"merged":0}}}]"#)), #"{"meta":{"prs":{"merged":0,"open":[]}}}"#)
        XCTAssertEqual(wire(row(#"[{"name":"a","meta":{"tasks":{"queued":0}}}]"#)), #"{"meta":{"prs":{"open":[]},"tasks":{"queued":0}}}"#)
        XCTAssertEqual(wire(row(#"[{"name":"a","meta":{"tasks":{},"prs":{"open":[{"url":"https://github.com/o/r/pull/1"}]}}}]"#)),
                       #"{"meta":{"prs":{"open":[{"num":1,"repo":"o\/r","title":"","url":"https:\/\/github.com\/o\/r\/pull\/1"}]}}}"#)
    }

    func testMetaWireDropsNonAllowlistedPRs() {
        let r = row("""
        [{"name":"a","meta":{"prs":{"open":[
          {"url":"javascript:alert(1)","repo":"o/evil","num":1,"title":"x"},
          {"url":"https://github.com/o/r/pull/7","repo":"o/r","title":"ok"},
          {"url":"https://github.com.evil.example/o/r/pull/8","repo":"o/r","num":8,"title":"x"}]}}}]
        """)
        XCTAssertEqual(r.meta?.openPRs.count, 3)
        XCTAssertEqual(wire(r), #"{"meta":{"prs":{"open":[{"num":7,"repo":"o\/r","title":"ok","url":"https:\/\/github.com\/o\/r\/pull\/7"}]}}}"#)
    }

    func testMetaWireOmitsNilTaskFields() {
        let r = row(#"[{"name":"a","meta":{"tasks":{"done":2,"total":"7"}}}]"#)
        XCTAssertEqual(wire(r), #"{"meta":{"prs":{"open":[]},"tasks":{"done":2}}}"#)
        let empty = row(#"[{"name":"a","meta":{"tasks":{}}}]"#)
        XCTAssertTrue(empty.metaWire.isEmpty, "a fieldless tasks object is nothing")
    }

    func testMetaWireTruncatesRepoAndTitle() {
        let repo = String(repeating: "r", count: 100), title = String(repeating: "t", count: 300)
        var r = DchListRow(name: "a", alias: "", activityEpoch: 0, state: "", agents: 0)
        r.meta = DchSessionMeta(openPRs: [.init(url: "https://github.com/o/\(repo)/pull/1", repo: "o/r", num: 1, title: title)])
        let pr = ((r.metaWire["meta"] as? [String: Any])?["prs"] as? [String: Any])?["open"] as? [[String: Any]]
        XCTAssertEqual(pr?.first?["repo"] as? String, "o/" + String(repeating: "r", count: 98))
        XCTAssertEqual(pr?.first?["title"] as? String, String(repeating: "t", count: 200))
    }

    /// #522: the title cap counts unicode scalars, so combining marks cannot grow it:
    /// 300 "e" + U+0301 pairs are 300 Characters but 600 scalars; 200 scalars go out.
    func testMetaWireTitleCapCountsScalars() {
        var r = DchListRow(name: "a", alias: "", activityEpoch: 0, state: "", agents: 0)
        let title = String(repeating: "e\u{301}", count: 300)
        r.meta = DchSessionMeta(openPRs: [.init(url: "https://github.com/o/r/pull/1", repo: "o/r", num: 1, title: title)])
        let pr = ((r.metaWire["meta"] as? [String: Any])?["prs"] as? [String: Any])?["open"] as? [[String: Any]]
        let sent = try? XCTUnwrap(pr?.first?["title"] as? String)
        XCTAssertEqual(sent?.unicodeScalars.count, 200)
        XCTAssertEqual(sent, String(repeating: "e\u{301}", count: 100))
    }

    /// dch's repo/num are untrusted: a chip reading "o/safe#1" must not open evil/x#9.
    func testMetaWireRepoAndNumComeFromURL() {
        let r = row("""
        [{"name":"a","meta":{"prs":{"open":[{"url":"https://github.com/evil/x/pull/9","repo":"o/safe","num":1,"title":"t"}]}}}]
        """)
        XCTAssertEqual(wire(r), #"{"meta":{"prs":{"open":[{"num":9,"repo":"evil\/x","title":"t","url":"https:\/\/github.com\/evil\/x\/pull\/9"}]}}}"#)
    }
}
