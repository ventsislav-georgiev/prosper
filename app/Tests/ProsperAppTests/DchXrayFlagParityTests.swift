import XCTest
@testable import ProsperApp

/// #1247: the Mac's remote --xray scanner takes and refuses every flag as dch serve's ctl_xray does, in its order
/// and with its words (rframe.c:631-697 and serve.c ctl_request's --ref check, both at v1.99.0). Pure calls of DchCtl.refusal with literal argv values; the table
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
            ["--json", "--search", "-k"], ["--json", "--search", "ab"], ["--json", "--search", "na\u{EF}ve \u{E9} \u{2713}"],
            ["--json", "--clear"], ["--clear", "--json"],
            ["--json", "--tasks"], ["--tasks", "--json"],
            ["--json", "--memory"], ["--memory", "--json"],
        ]
        for a in ok { XCTAssertTrue(why(a) == nil, a.joined(separator: " ")) }
    }

    func testSearchLimits() {
        let max200 = String(repeating: "a", count: 200), over = String(repeating: "a", count: 201)
        let multi = String(repeating: "\u{E9}", count: 100), multiOver = String(repeating: "\u{E9}", count: 100) + "a"
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
        XCTAssertEqual(why(["--json", "--bogus"]), "--bogus is not allowed with --xray")
        XCTAssertEqual(why(["--json", "--tasks", "--task"]), "--task is not allowed with --xray")
        XCTAssertEqual(why(["--json", "--searches", "ab"]), "--searches is not allowed with --xray")
        XCTAssertEqual(why(["--json", "-k"]), "-k is not allowed with --xray")
    }

    /// Red on the old line `ctl does not allow \(shown(w)) with \(verb)` (every word, a dash or not).
    func testUnknownWordsAsRframeWordsThem() {
        for w in ["--config", "serve", "-h", "--help", "-f", "--all"] {
            XCTAssertEqual(why(["--json", w]), "\(w) is not allowed", w)
        }
        XCTAssertEqual(why(["--json", "x"]), "unexpected x after --xray")
        XCTAssertEqual(why(["--json", "--"]), "-- is not allowed with --xray")
        XCTAssertEqual(why(["--json", "-"]), "- is not allowed with --xray")
        XCTAssertEqual(why(["--json", "api"]), "unexpected api after --xray")
        let w60 = String(repeating: "a", count: 60), w61 = w60 + "b"
        XCTAssertEqual(why(["--json", w60]), "unexpected \(w60) after --xray", "60 bytes whole")
        XCTAssertEqual(why(["--json", w61]), "unexpected \(w60) after --xray", "61 bytes cut to 60 (%.60s)")
        XCTAssertEqual(why(["--json", "-" + w60]), "-" + String(w60.dropLast()) + " is not allowed with --xray")
        XCTAssertEqual(why(["--json", "--search", "ab", "--bogus"]), "--bogus is not allowed with --xray")
    }

    /// Red on the old order: the old scan checked every value inline, so a bad --scope beat a missing --json, and a
    /// bad --budget-ms beat the exclusion.
    func testOrderOfChecksIsRframes() {
        XCTAssertEqual(why(["--bogus"]), "--bogus is not allowed with --xray", "the scan before --json")
        XCTAssertEqual(why(["--clear", "--clear"]), "--clear twice")
        XCTAssertEqual(why(["--json", "--json"]), "--json twice")
        XCTAssertEqual(why(["--ref", "x", "--ref", "y", "--json"]), "--ref twice")
        XCTAssertEqual(why(["--scope"]), "--scope needs a value", "the scan before --json")
        XCTAssertEqual(why(["--ref", "x", "--scope", "global"]), needsJSON, "json before the scope value")
        XCTAssertEqual(why(["--ref", "\u{202E}"]), needsJSON, "json before the ref bytes")
        XCTAssertEqual(why(["--chapter", "a b"]), needsJSON, "json before the anchor")
        XCTAssertEqual(why(["--json", "--ref", "x", "--follow", "--scope", "global"]), exclusion, "exclusion before the scope value")
        XCTAssertEqual(why(["--json", "--ref", "x", "--chapter", "a b"]), exclusion, "exclusion before the anchor")
        XCTAssertEqual(why(["--json", "--follow", "--scope", "global"]), withRef, "with-ref before the scope value")
        XCTAssertEqual(why(["--json", "--chapter", "a b", "--budget-ms", "1"]), withRef, "with-ref before the anchor")
        XCTAssertEqual(why(["--json", "--ref", "x", "--scope", "global", "--budget-ms", "1"]), "bad scope", "scope before budget")
        XCTAssertEqual(why(["--json", "--ref", "x", "--budget-ms", "1"]), "bad budget")
        XCTAssertEqual(why(["--json", "--ref", "\u{202E}", "--scope", "global"]), "bad scope", "the values before the ref bytes")
        XCTAssertEqual(why(["--json", "--chapter", "a b"]), "bad anchor")
        XCTAssertEqual(why(["--json", "--ref", "x", "--scope", "Session"]), "bad scope")
    }

    /// Red on the old exclusion: --follow beside --tasks or --memory was refused (rframe.c:674-675, #446).
    func testFollowTakesTasksAndMemory() {
        for a in [["--follow", "--tasks"], ["--follow", "--memory"], ["--follow", "--tasks", "--memory"], ["--tasks", "--follow", "--memory"]] {
            XCTAssertTrue(why(["--json"] + a) == nil, a.joined(separator: " "))
        }
        for a in [["--follow", "--clear"], ["--follow", "--search", "ab"], ["--follow", "--ref", "x"], ["--follow", "--chapter", "c1"],
                  ["--follow", "--tasks", "--clear"], ["--follow", "--memory", "--ref", "x"], ["--tasks", "--memory", "--clear"]] {
            XCTAssertEqual(why(["--json"] + a), exclusion, a.joined(separator: " "))
        }
        XCTAssertTrue(DchCtl.follows(["--xray", "api", "--follow", "--tasks", "--json"]))
    }

    /// Red on the old rule `value.utf8.count <= 3`: dch takes a run of any length, clamps at 1000, then wants 50 to 300.
    func testBudgetIsADigitRunClampedAt1000() {
        func b(_ v: String) -> String? { why(["--json", "--ref", "x", "--budget-ms", v]) }
        for ok in ["50", "300", "0050", "00100", "000300", String(repeating: "0", count: 40) + "50", "100"] { XCTAssertTrue(b(ok) == nil, ok) }
        for bad in ["49", "301", "0", "", "1000", "1001", "99999999999999999999", String(repeating: "9", count: 400), "1e2", "-50", "+50",
                    "5 0", "50 ", "\u{FF15}\u{FF10}", "0x32", "100.0", "\u{0665}\u{0660}"] {
            XCTAssertEqual(b(bad), "bad budget", bad.debugDescription)
        }
    }

    /// Red on the old refOK: U+061C, U+2028 and U+2029 (dch's cp_ctl) passed; "bad ref" was another text.
    func testRefBytesAndTheCodePointsRefOKGained() {
        func r(_ v: String) -> String? { why(["--json", "--ref", v]) }
        for bad in ["", "a\u{061C}b", "a\u{2028}b", "a\u{2029}b", "\u{061C}", "a\u{200E}", "a\u{200F}", "a\u{202A}", "a\u{202E}", "a\u{2066}",
                    "a\u{2069}", "a\u{1F}", "a\u{7F}", "a\u{80}", "a\u{9F}", String(repeating: "r", count: 257)] {
            XCTAssertEqual(r(bad), "bad ref", bad.debugDescription)
        }
        // each neighbour of a refused code point is no control: accepted
        for ok in ["a\u{061B}b", "a\u{061D}b", "a\u{2027}b", "a\u{202F}b", "a\u{2065}b", "a\u{206A}b", "a\u{200D}b", "a\u{A0}b", "a b",
                   "#831", "API-12", "a-b", String(repeating: "r", count: 256)] {
            XCTAssertTrue(r(ok) == nil, ok.debugDescription)
        }
    }

    /// "not a ref" (serve.c ctl_request, after the bytes): a blank text has no span; the Mac also refuses a leading "-".
    func testBlankOrDashTextIsNotARef() {
        for t in [" ", "   ", "\u{2003}", "\u{A0}", "\u{3000}", "\u{A0}\u{2003}", "-", "-x", "--ref", "--json"] {
            XCTAssertEqual(why(["--json", "--ref", t]), "not a ref", t.debugDescription)
        }
        XCTAssertEqual(why(["--json", "--ref", "\t"]), "bad ref", "a control is the byte rule first")
        XCTAssertTrue(why(["--json", "--ref", " x "]) == nil)
    }

    /// Red on the old texts "--xray takes one of --ref, --follow, --chapter", "--full goes with --ref", "--xray needs --json".
    func testOlderFlagsUseServesWords() {
        XCTAssertEqual(why(["--json", "--ref", "x", "--follow"]), exclusion)
        XCTAssertEqual(why(["--json", "--follow", "--chapter", "c1"]), exclusion)
        XCTAssertEqual(why(["--json", "--ref", "x", "--chapter", "c1"]), exclusion)
        for f in [["--full"], ["--scope", "all"], ["--budget-ms", "100"]] {
            XCTAssertEqual(why(["--json"] + f), withRef, f.joined(separator: " "))
            XCTAssertEqual(why(["--json", "--follow"] + f), withRef, f.joined(separator: " "))
            XCTAssertEqual(why(["--json", "--chapter", "c1"] + f), withRef, f.joined(separator: " "))
        }
        XCTAssertEqual(why(["--ref", "x"]), needsJSON)
        XCTAssertEqual(why(["--follow"]), needsJSON)
        XCTAssertEqual(why(["--chapter", "c1"]), needsJSON)
        XCTAssertEqual(why([]), needsJSON)
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
        XCTAssertEqual(why(["--json", "--search", "ab", "--bogus"]), "--bogus is not allowed with --xray")
    }

    func testAcceptedArgvIsCarriedAsOwnElements() {
        // follow is read from the same scan; a search text equal to a flag name is a value, not a flag.
        XCTAssertFalse(DchCtl.follows(["--xray", "api", "--search", "--follow", "--json"]))
        XCTAssertFalse(DchCtl.follows(["--xray", "api", "--tasks", "--json"]))
    }
}
