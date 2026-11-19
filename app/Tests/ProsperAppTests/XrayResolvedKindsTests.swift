import XCTest
@testable import ProsperApp

/// #1612: the card's resolver block for the shapes dch 1.110/1.111 send (commit, file ok and missing, pull) and for an
/// absent `resolved` (unknown sha, gh missing or offline: no line at all). Literal fakes (acme/api, /Users/example); no dch.
final class XrayResolvedKindsTests: XCTestCase {
    static func resolved(_ body: String) -> XrayRefStream.Resolved? {
        XrayRefStreamTests.parse([XrayRefStreamTests.first, ##"{"schema":1,"resolved":"## + body + "}", XrayRefStreamTests.done]).resolved
    }

    /// Red with resolvedText dropping the subtitle (the date and on-HEAD word) or showing the sha line only.
    @MainActor func testCommitShowsSubjectAndSubtitle() throws {
        let r = try XCTUnwrap(Self.resolved(#"{"kind":"commit","state":"ok","title":"Fix the login retry","subtitle":"Example Dev \#u{00B7} 3h ago \#u{00B7} abc1234 \#u{00B7} on HEAD","lines":[]}"#))
        XCTAssertEqual(XrayRefPopover.resolvedText(r), "Fix the login retry\nExample Dev \u{00B7} 3h ago \u{00B7} abc1234 \u{00B7} on HEAD")
        let off = try XCTUnwrap(Self.resolved(#"{"kind":"commit","state":"ok","title":"Fix","subtitle":"Example Dev \#u{00B7} 3h ago \#u{00B7} abc1234 \#u{00B7} not on HEAD"}"#))
        XCTAssertTrue(XrayRefPopover.resolvedText(off).hasSuffix("not on HEAD"))
    }

    /// Red with the subject kept raw: a bidi override and a stack of combining marks stay clean (OutsideText.shown).
    @MainActor func testCommitSubjectIsCleanedThroughOutsideText() throws {
        let marks = String(repeating: "\u{0301}", count: 8)
        let r = try XCTUnwrap(Self.resolved(#"{"kind":"commit","state":"ok","title":"Fix \u202Elogin\u200F\u0007 e\#(marks)","subtitle":"Example Dev \u202Eabc1234"}"#))
        let t = XrayRefPopover.resolvedText(r)
        XCTAssertEqual(t, "Fix login e" + String(repeating: "\u{0301}", count: OutsideText.maxMarks) + "\nExample Dev abc1234")
        XCTAssertFalse(t.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x200F || $0.value == 0x07 })
    }

    /// Red with "missing" falling to its raw state word, or ok drawing nothing of the path and mtime.
    @MainActor func testFileOkShowsPathAndMtimeAndMissingShowsMissing() throws {
        let ok = try XCTUnwrap(Self.resolved(#"{"kind":"file","state":"ok","title":"login.swift","subtitle":"/Users/example/acme/api/login.swift \#u{00B7} modified 2026-11-18 09:30 UTC","lines":[]}"#))
        XCTAssertEqual(ok.kind, "file")
        XCTAssertEqual(XrayRefPopover.resolvedText(ok), "login.swift\n/Users/example/acme/api/login.swift \u{00B7} modified 2026-11-18 09:30 UTC")
        let gone = try XCTUnwrap(Self.resolved(#"{"kind":"file","state":"missing","title":"Missing","subtitle":"/Users/example/acme/api/gone.swift","lines":[]}"#))
        XCTAssertEqual(XrayRefPopover.resolvedText(gone), "Missing")
    }

    /// Red with the pull kind dropped or its state and owner/repo#N subtitle lost (dch 1.111).
    @MainActor func testPullShowsTitleAndStateSubtitle() throws {
        let r = try XCTUnwrap(Self.resolved(#"{"kind":"pull","state":"ok","title":"Retry the login twice","subtitle":"open \#u{00B7} acme/api#12","lines":[]}"#))
        XCTAssertEqual(r.kind, "pull")
        XCTAssertEqual(XrayRefPopover.resolvedText(r), "Retry the login twice\nopen \u{00B7} acme/api#12")
        let issue = try XCTUnwrap(Self.resolved(#"{"kind":"issue","state":"ok","title":"Login fails","subtitle":"closed \#u{00B7} acme/api#7"}"#))
        XCTAssertEqual(XrayRefPopover.resolvedText(issue), "Login fails\nclosed \u{00B7} acme/api#7")
    }

    /// #1624 (dch 1.113 #515): a url ref's fetched page title and "<host> . fetched <age> in <session>". Red with the url
    /// kind dropped or the subtitle lost; the title is cleaned through OutsideText (bidi override, bell).
    @MainActor func testUrlShowsFetchedTitleAndHostSubtitle() throws {
        let r = try XCTUnwrap(Self.resolved(#"{"kind":"url","state":"ok","title":"Example \u202EDomain\u0007","subtitle":"example.com \#u{00B7} fetched 2h ago in api-qa","lines":[]}"#))
        XCTAssertEqual(r.kind, "url")
        XCTAssertEqual(XrayRefPopover.resolvedText(r), "Example Domain\nexample.com \u{00B7} fetched 2h ago in api-qa")
    }

    /// A url ref with no fetch in the transcript: dch sends no resolved key, so no title line (red with a placeholder made up).
    func testUrlWithNoFetchShowsNoLine() {
        let s = XrayRefStreamTests.parse([XrayRefStreamTests.first, XrayRefStreamTests.done])
        XCTAssertTrue(s.resolved == nil)
        XCTAssertTrue(s.done)
    }

    /// Unknown sha, or gh missing, unauthed, offline, timed out, xray_github off: no resolved key, so no line (red with a
    /// placeholder resolved made up): the mentions and the done line stay.
    func testNoResolvedLineLeavesMentionsAndDone() {
        let s = XrayRefStreamTests.parse([XrayRefStreamTests.first, XrayRefStreamTests.mention0, XrayRefStreamTests.done])
        XCTAssertTrue(s.resolved == nil)
        XCTAssertEqual(s.mentions.map(\.line), ["Work on #12 please"])
        XCTAssertTrue(s.done)
    }
}
