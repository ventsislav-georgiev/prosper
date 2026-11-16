import XCTest
@testable import ProsperApp

/// #1320 (QA #535 INFO a, b): Resume's record argument beside a session named `<file>.json`, and the skip
/// detail's "(record <file>)" when the file holds " (record ". Pure functions: no dch runs.
final class AgentIslandRecordTests: XCTestCase {
    private func rec(_ name: String, file: String) -> DchHistoryRecord {
        DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: name), ended: 100, end: "signal 9", file: file)
    }

    /// INFO a: dch reads `--revive work.json` as the file "work" and refuses it as ambiguous while a session is
    /// named "work.json" (rec_arg, dch.c:11204-11207 at v1.76.0). Then "work" goes by its plain name, which
    /// names the same record; a live "work.json" counts as much as a record of it.
    func testResumeOfWorkBesideASessionNamedWorkJsonPassesThePlainName() {
        let work = rec("work", file: "work")
        XCTAssertEqual(AgentIsland.reviveArgs(work, live: [], records: ["work.json"], exact: true),
                       ["--revive", "work", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(work, live: ["work.json"], records: [], exact: true),
                       ["--revive", "work", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(work, live: ["work", "work.json"], records: [], noMessage: true, exact: true),
                       ["--revive", "work", "--as", "work-2", "--no-message", "--json"], "the --as name as before")
        let aside = rec("work", file: "work.1762000000")
        XCTAssertEqual(AgentIsland.reviveArgs(aside, live: [], records: ["work.1762000000.json"], exact: true),
                       ["--revive", "work.1762000000", "--json"], "an aside record by its plain file")
        XCTAssertEqual(AgentIsland.reviveArgs(work, live: [], records: ["work.JSON", "api"], exact: true),
                       ["--revive", "work.json", "--json"], "dch compares the name exactly: no clash, the file form")
    }

    /// INFO a: "work.json" itself keeps `<file>.json` ("work.json.json"), beside a "work" or alone: its plain
    /// name would end in ".json" and be read as the file "work".
    func testResumeOfASessionNamedWorkJsonKeepsTheFileForm() {
        let wj = rec("work.json", file: "work.json")
        XCTAssertEqual(AgentIsland.reviveArgs(wj, live: [], records: [], exact: true), ["--revive", "work.json.json", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(wj, live: [], records: ["work"], exact: true), ["--revive", "work.json.json", "--json"])
        XCTAssertEqual(AgentIsland.reviveArgs(wj, live: ["work"], records: [], exact: true), ["--revive", "work.json.json", "--json"])
    }

    /// INFO b: dch's detail is "skipped \u{2014} claude <id> <where> (record <file>)" (dch.c:11316-11320), the file
    /// being the record's: its name or `<name>.<ended>`. A name that holds " (record " is read whole.
    func testRecordFileReadsAFileThatHoldsTheRecordTag() {
        func file(_ name: String, _ detail: String) -> String? {
            AgentIsland.recordFile(DchJSONLine(name: name, result: "skipped", reason: "live_sid", detail: detail))
        }
        XCTAssertEqual(file("api (record x", "skipped \u{2014} claude S already runs in live session api-qa (record api (record x)"),
                       "api (record x")
        XCTAssertEqual(file("api (record x", "skipped \u{2014} claude S ended in a newer record: stopped (record api (record x.1762000000)"),
                       "api (record x.1762000000", "an aside file of that name")
        XCTAssertEqual(file("api", "skipped \u{2014} claude S already runs in live session b (record c (record api)"), "api",
                       "a live name that holds the tag stays out")
        XCTAssertEqual(file("api", "skipped \u{2014} claude S already runs in live session b (record api-0a1b2c)"), "api-0a1b2c",
                       "a file of no known shape: the last tag, as before")
    }
}
