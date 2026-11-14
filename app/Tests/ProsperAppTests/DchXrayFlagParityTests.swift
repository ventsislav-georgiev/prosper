import XCTest
@testable import ProsperApp

/// #1247: the Mac's remote --xray scanner takes and refuses --search, --clear, --tasks and --memory as dch serve
/// 1.66.0's ctl_xray does (rframe.c:629-695). Pure calls of DchCtl.refusal with literal argv values; the table
/// is written out, never read from the product's own lists. Fakes only.
final class DchXrayFlagParityTests: XCTestCase {
    private func why(_ a: [String]) -> String? { DchCtl.refusal(["--xray", "api"] + a, create: true) }

    private let needsJSON = "--xray needs --json (the view is client-side only)"                       // rframe.c:675
    private let exclusion = "--ref, --search, --tasks, --memory, --follow, --chapter and --clear exclude each other"  // :677
    private let withRef = "--scope, --full and --budget-ms come with --ref"                             // :681
    private let badSearch = "bad search: 2 to 200 bytes, no control character"                          // :689

    func testAcceptedForms() {
        let ok: [[String]] = [
            ["--json", "--search", "example"], ["--search", "example", "--json"], ["--json", "--search", "--json"],
            ["--json", "--search", "-k"], ["--json", "--search", "ab"], ["--json", "--search", "naïve é ✓"],
            ["--json", "--clear"], ["--clear", "--json"],
            ["--json", "--tasks"], ["--tasks", "--json"],
            ["--json", "--memory"], ["--memory", "--json"],
        ]
        for a in ok { XCTAssertTrue(why(a) == nil, a.joined(separator: " ")) }
    }

    func testSearchLimits() {
        let max200 = String(repeating: "a", count: 200), over = String(repeating: "a", count: 201)
        let multi = String(repeating: "é", count: 100), multiOver = String(repeating: "é", count: 100) + "a"
        XCTAssertTrue(why(["--json", "--search", max200]) == nil)
        XCTAssertEqual(why(["--json", "--search", over]), badSearch)
        XCTAssertTrue(why(["--json", "--search", multi]) == nil, "200 bytes in 100 scalars")
        XCTAssertEqual(why(["--json", "--search", multiOver]), badSearch, "201 bytes")
        XCTAssertEqual(why(["--json", "--search", ""]), badSearch)
        XCTAssertEqual(why(["--json", "--search", "a"]), badSearch)
        for bad in ["a\u{1}b", "ab\n", "a\tb", "a\u{7f}b", "a\u{85}b", "a\u{202e}b", "a\u{2066}b", "a\u{200e}b", "a\u{200f}b",
                    "a\u{061c}b", "a\u{2028}b", "a\u{2029}b"] {
            XCTAssertEqual(why(["--json", "--search", bad]), badSearch, bad.debugDescription)
        }
        XCTAssertEqual(why(["--search"]), "--search needs a value")
        XCTAssertEqual(why(["--json", "--search"]), "--search needs a value")
    }

    func testExcludedPairs() {
        let pairs: [[String]] = [
            ["--search", "ab", "--clear"], ["--search", "ab", "--tasks"], ["--search", "ab", "--memory"],
            ["--search", "ab", "--follow"], ["--search", "ab", "--chapter", "c1"], ["--search", "ab", "--ref", "x"],
            ["--clear", "--tasks"], ["--clear", "--memory"], ["--clear", "--follow"], ["--clear", "--chapter", "c1"],
            ["--clear", "--ref", "x"], ["--tasks", "--memory"], ["--tasks", "--follow"], ["--tasks", "--chapter", "c1"],
            ["--tasks", "--ref", "x"], ["--memory", "--follow"], ["--memory", "--chapter", "c1"], ["--memory", "--ref", "x"],
        ]
        for p in pairs {
            XCTAssertEqual(why(["--json"] + p), exclusion, p.joined(separator: " "))
            XCTAssertEqual(why(p + ["--json"]), exclusion, p.joined(separator: " "))
        }
        XCTAssertEqual(why(["--json", "--search", "ab", "--clear", "--tasks"]), exclusion)
        XCTAssertEqual(why(["--json", "--search", "a", "--clear"]), exclusion, "the pair wins over the text, as dch's order")
    }

    func testNeedsJSONAndWithRef() {
        for a in [["--search", "ab"], ["--clear"], ["--tasks"], ["--memory"], ["--tasks", "--memory"]] {
            XCTAssertEqual(why(a), needsJSON, a.joined(separator: " "))
        }
        XCTAssertEqual(why(["--search", "a"]), needsJSON, "json first, as dch's order")
        for flag in ["--full"] { // each with-ref flag beside a new flag
            for m in [["--search", "ab"], ["--clear"], ["--tasks"], ["--memory"]] {
                XCTAssertEqual(why(["--json", flag] + m), withRef, ([flag] + m).joined(separator: " "))
            }
        }
        XCTAssertEqual(why(["--json", "--tasks", "--scope", "session"]), withRef)
        XCTAssertEqual(why(["--json", "--memory", "--budget-ms", "100"]), withRef)
        XCTAssertEqual(why(["--json", "--clear", "--full"]), withRef)
        XCTAssertEqual(why(["--json", "--search", "a", "--full"]), withRef, "with-ref before the text, as dch's order")
    }

    func testTwice() {
        XCTAssertEqual(why(["--json", "--search", "ab", "--search", "cd"]), "--search twice")
        XCTAssertEqual(why(["--json", "--clear", "--clear"]), "--clear twice")
        XCTAssertEqual(why(["--json", "--tasks", "--tasks"]), "--tasks twice")
        XCTAssertEqual(why(["--json", "--memory", "--memory"]), "--memory twice")
    }

    func testUnknownStillUnlisted() {
        XCTAssertEqual(why(["--json", "--bogus"]), "ctl does not allow --bogus with --xray")
        XCTAssertEqual(why(["--json", "--tasks", "--task"]), "ctl does not allow --task with --xray")
        XCTAssertEqual(why(["--json", "--searches", "ab"]), "ctl does not allow --searches with --xray")
        XCTAssertEqual(why(["--json", "-k"]), "ctl does not allow -k with --xray")
    }

    func testOldFlagsKeepTheirWords() {
        XCTAssertEqual(why(["--json", "--ref", "x", "--follow"]), "--xray takes one of --ref, --follow, --chapter")
        XCTAssertEqual(why(["--json", "--full"]), "--full goes with --ref")
        XCTAssertEqual(why(["--ref", "x"]), "--xray needs --json")
    }

    func testFlagSetEqualsRframeTable() {
        // rframe.c:632-633: --json --follow --clear --full --ref --chapter --scope --budget-ms --search --tasks --memory
        let table: Set<String> = ["--json", "--follow", "--clear", "--full", "--ref", "--chapter", "--scope", "--budget-ms",
                                  "--search", "--tasks", "--memory"]
        XCTAssertEqual(DchCtl.xrayFlags, table)
        XCTAssertEqual(DchCtl.xrayValued, ["--ref", "--chapter", "--scope", "--budget-ms", "--search"])
        // Behaviour, not only the list: each flag alone with --json is never "unlisted".
        for f in ["--follow", "--clear", "--tasks", "--memory"] {
            XCTAssertTrue(why(["--json", f]) == nil, f)
        }
        XCTAssertTrue(why(["--json", "--ref", "x", "--full", "--scope", "all", "--budget-ms", "50"]) == nil)
        XCTAssertTrue(why(["--json", "--chapter", "c1"]) == nil)
        XCTAssertEqual(why(["--json", "--search", "ab", "--bogus"]), "ctl does not allow --bogus with --xray")
    }

    func testAcceptedArgvIsCarriedAsOwnElements() {
        // follow is read from the same scan; a search text equal to a flag name is a value, not a flag.
        XCTAssertFalse(DchCtl.follows(["--xray", "api", "--search", "--follow", "--json"]))
        XCTAssertFalse(DchCtl.follows(["--xray", "api", "--tasks", "--json"]))
    }
}
