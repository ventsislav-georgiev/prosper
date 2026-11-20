import AppKit
import GhosttyTerminal
import os
import XCTest
@testable import ProsperApp

/// #1480: a file path in a terminal link opens in the Text Viewer, resolved against the session's folder.
/// Fake files in a scratch folder; the viewer is a recorder (never a window), openURL a recorder, the home a seam.
@MainActor
final class AgentTerminalFileLinkTests: XCTestCase {
    private struct Fixture {
        let rig: AgentTerminalTests.Rig
        let dir: URL
    }

    private func fixture() throws -> Fixture {
        let dir = tempDir()
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("docs/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Example.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("home"), withIntermediateDirectories: true)
        for f in ["docs/draft.txt", "docs/my notes.md", "home/todo.md", "page.html"] {
            try "fake\n".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        let script = dir.appendingPathComponent("run.sh")
        try "echo fake\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let rig = AgentTerminalTests.Rig()
        rig.c.attach(AgentSessionKey(dir: "/Users/example/dch", name: "api"))
        rig.c.cwd = { _ in dir.path }
        rig.c.homeDirectory = { dir.appendingPathComponent("home").path }
        return Fixture(rig: rig, dir: dir)
    }

    private func shown(_ f: Fixture) -> [String] { f.rig.shown.map(\.path) }

    func testARelativePathOpensAgainstTheSessionFolder() throws {
        let f = try fixture()
        f.rig.c.open("docs/draft.txt")
        XCTAssertEqual(shown(f), [f.dir.path + "/docs/draft.txt"])
        XCTAssertTrue(f.rig.opened.isEmpty)
    }

    func testTrailingPunctuationIsStripped() throws {
        let f = try fixture()
        for t in ["docs/draft.txt.", "docs/draft.txt,", "docs/draft.txt;", "docs/draft.txt:", "docs/draft.txt)", "docs/draft.txt]",
                  "docs/draft.txt\"", "docs/draft.txt'", "docs/draft.txt\u{201D}", "docs/draft.txt.)"] {
            f.rig.c.open(t)
        }
        XCTAssertEqual(shown(f), Array(repeating: f.dir.path + "/docs/draft.txt", count: 10))
    }

    func testALineAndColumnSuffixIsRemoved() throws {
        let f = try fixture()
        for t in ["docs/draft.txt:12", "docs/draft.txt:12:3", "docs/draft.txt:12:3."] { f.rig.c.open(t) }
        XCTAssertEqual(shown(f), Array(repeating: f.dir.path + "/docs/draft.txt", count: 3))
    }

    func testAFileURLIsDecodedOnce() throws {
        let f = try fixture()
        f.rig.c.open("file://" + f.dir.path + "/docs/my%20notes.md")
        XCTAssertEqual(shown(f), [f.dir.path + "/docs/my notes.md"])
        f.rig.c.open("file://" + f.dir.path + "/docs/my%2520notes.md")   // decoded once: a name with a literal "%20" does not exist
        XCTAssertEqual(shown(f).count, 1)
    }

    func testAnAbsolutePathAndATildePath() throws {
        let f = try fixture()
        f.rig.c.open(f.dir.path + "/docs/draft.txt")
        f.rig.c.open("~/todo.md")
        XCTAssertEqual(shown(f), [f.dir.path + "/docs/draft.txt", f.dir.path + "/home/todo.md"])
    }

    func testDotDotIsResolvedBeforeTheChecks() throws {
        let f = try fixture()
        f.rig.c.open("docs/sub/../draft.txt")
        XCTAssertEqual(shown(f), [f.dir.path + "/docs/draft.txt"])
    }

    func testASymlinkToATextFileOpensAndOneToADirectoryDoesNot() throws {
        let f = try fixture()
        let fm = FileManager.default
        try fm.createSymbolicLink(at: f.dir.appendingPathComponent("link.txt"), withDestinationURL: f.dir.appendingPathComponent("docs/draft.txt"))
        try fm.createSymbolicLink(at: f.dir.appendingPathComponent("dirlink.txt"), withDestinationURL: f.dir.appendingPathComponent("docs"))
        f.rig.c.open("link.txt")
        f.rig.c.open("dirlink.txt")
        XCTAssertEqual(shown(f), [f.dir.path + "/link.txt"])
    }

    /// QA s1: the link's name never decides the type, its resolved target does.
    func testTheTargetOfASymlinkDecidesTheType() throws {
        let f = try fixture()
        let fm = FileManager.default
        try "fake\n".write(to: f.dir.appendingPathComponent("key"), atomically: true, encoding: .utf8)
        for (link, target) in [("to-html.md", "page.html"), ("to-key.md", "key"), ("ok.txt", "docs/draft.txt")] {
            try fm.createSymbolicLink(at: f.dir.appendingPathComponent(link), withDestinationURL: f.dir.appendingPathComponent(target))
        }
        for t in ["to-html.md", "to-key.md", "ok.txt"] { f.rig.c.open(t) }
        XCTAssertEqual(shown(f), [f.dir.path + "/ok.txt"])
    }

    func testNothingElseOpensOrRuns() throws {
        let f = try fixture()
        for t in ["docs", "docs/", "missing.txt", "page.html", "Example.app", "Example.app/Contents", "run.sh", "", ".", ":12", "~",
                  "file:///", "file://" + f.dir.path + "/page.html", "docs/draft\u{0}.txt"] {
            f.rig.c.open(t)
        }
        XCTAssertTrue(shown(f).isEmpty, "\(shown(f))")
        XCTAssertTrue(f.rig.opened.isEmpty, "a file never reaches openURL")
    }

    func testARelativePathIsNeverResolvedAgainstTheProcessFolder() throws {
        let f = try fixture()
        let here = FileManager.default.currentDirectoryPath
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: here).sorted().first {
            AgentTerminalFileLink.isViewable(URL(fileURLWithPath: here + "/" + $0))
        })
        f.rig.c.open(name)   // the session's folder has no such file
        f.rig.c.cwd = { _ in nil }
        f.rig.c.open(name)   // and a session with no known folder resolves nothing relative
        XCTAssertTrue(shown(f).isEmpty, "\(shown(f))")
    }

    func testWebAndMailStillGoToOpenURL() throws {
        let f = try fixture()
        for t in ["https://example.com/a.md", "http://example.com/b.txt", "mailto:someone@example.com"] { f.rig.c.open(t) }
        XCTAssertEqual(f.rig.opened.map(\.absoluteString), ["https://example.com/a.md", "http://example.com/b.txt", "mailto:someone@example.com"])
        XCTAssertTrue(shown(f).isEmpty)
    }

    func testTheIntakeGateAppliesWithTheViewerExtensionOff() throws {
        let f = try fixture()
        let intake = TextViewerIntake()
        intake.ready()
        var shownByIntake: [URL] = [], notified = 0
        intake.show = { shownByIntake.append($0) }
        intake.notifyOff = { notified += 1 }
        f.rig.c.showFile = { intake.receive($0) }
        intake.isEnabled = { false }
        f.rig.c.open("docs/draft.txt")
        XCTAssertEqual(notified, 1)
        XCTAssertTrue(shownByIntake.isEmpty, "off: notified, never handed off")
        intake.isEnabled = { true }
        f.rig.c.open("docs/draft.txt")
        XCTAssertEqual(shownByIntake.map(\.path), [f.dir.path + "/docs/draft.txt"])
    }

    func testTheResolverIsPure() {
        XCTAssertEqual(AgentTerminalFileLink.resolve("a/b.md:3.", cwd: "/Users/example/p", home: "/Users/example")?.path, "/Users/example/p/a/b.md")
        XCTAssertEqual(AgentTerminalFileLink.resolve("~/n.md", cwd: nil, home: "/Users/example")?.path, "/Users/example/n.md")
        XCTAssertTrue(AgentTerminalFileLink.resolve("a/b.md", cwd: nil, home: "/Users/example") == nil)
        XCTAssertTrue(AgentTerminalFileLink.resolve("a/b.md", cwd: "relative", home: "/Users/example") == nil)
    }

    /// #1719 (incident 2026-11-20): the link the operator Cmd+Shift-clicked, trailing period included.
    static let incidentLink = "~/Documents/ai-reviewer-weekly-update-2026-11-20.txt."

    func testTheIncidentLinkResolvesUnderHomeWithoutItsPeriod() {
        XCTAssertEqual(AgentTerminalFileLink.resolve(Self.incidentLink, cwd: nil, home: "/Users/example")?.path,
                       "/Users/example/Documents/ai-reviewer-weekly-update-2026-11-20.txt")
    }

    /// #1719: a Cmd+Shift click on the link, then libghostty's open_url on the release (it calls back on main): the click
    /// returns having queued exactly one disk check and run none; the main thread never stats the path (a stat under a
    /// TCC-guarded or iCloud folder can block it; the file is made only after the click, so a check on the click would
    /// queue nothing). The held check, run, shows the file once.
    func testACommandShiftClickOnTheIncidentLinkReturnsBeforeAnyDiskCheck() throws {
        let f = try fixture()
        let docs = f.dir.appendingPathComponent("home/Documents")
        var held: [@Sendable () -> Void] = []
        f.rig.c.fileCheck = { held.append($0) }
        let v = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
        v.owner = f.rig.c
        var passed: [NSEvent.EventType] = []
        v.passedClick = { passed.append($0.type) }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 40, y: 380), modifierFlags: [.command, .shift],
                                                     timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { v.mouseDown(with: e) } else { v.mouseUp(with: e) }
        }
        v.terminalDidRequestOpenURL(Self.incidentLink, kind: .text)
        XCTAssertEqual(passed, [.leftMouseDown, .leftMouseUp], "the click goes on to libghostty, as before")
        XCTAssertEqual(held.count, 1, "one disk check queued")
        XCTAssertTrue(shown(f).isEmpty, "nothing shown, nothing checked, on the click")
        // The file appears only now: a check made during the click would have found nothing and queued nothing.
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "fake\n".write(to: docs.appendingPathComponent("ai-reviewer-weekly-update-2026-11-20.txt"), atomically: true, encoding: .utf8)
        held.first?()
        XCTAssertEqual(shown(f), [docs.path + "/ai-reviewer-weekly-update-2026-11-20.txt"])
        XCTAssertEqual(held.count, 1)
    }

    /// #1719: the product's check never runs on the calling (main) thread.
    func testTheLinkDiskCheckRunsOffMainByDefault() {
        let done = DispatchSemaphore(value: 0)
        let onMain = OSAllocatedUnfairLock(initialState: true)
        AgentTerminalController().fileCheck {
            onMain.withLock { $0 = Thread.isMainThread }
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        XCTAssertFalse(onMain.withLock { $0 })
    }

    /// #1730 (n53): open() through its own default fileCheck (a real global queue and the main hop) on a real temp file:
    /// the file shows once, on main, with the run loop spun (catches an isolation trap or a wrong hop).
    func testOpenThroughTheDefaultOffMainCheckShowsTheFileOnce() throws {
        let f = try fixture()
        let c = AgentTerminalController()
        c.attach(AgentSessionKey(dir: "/Users/example/dch", name: "api"))
        c.cwd = { _ in f.dir.path }
        var got: [(URL, Bool)] = []
        c.showFile = { got.append(($0, Thread.isMainThread)) }
        c.open("docs/draft.txt")
        XCTAssertTrue(got.isEmpty, "the check is off main: nothing shown before the run loop turns")
        let end = Date().addingTimeInterval(30)
        while got.isEmpty && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))   // a second show would land here
        XCTAssertEqual(got.map { $0.0.path }, [f.dir.path + "/docs/draft.txt"])
        XCTAssertEqual(got.map { $0.1 }, [true])
    }

    /// #1730 (n54): a slow link then a fast one, checks held and finished in reverse: only the newest click's file shows,
    /// whichever order the checks end in.
    func testASlowLinkFollowedByAFastOneShowsOnlyTheFastFile() throws {
        let f = try fixture()
        var held: [@Sendable () -> Void] = []
        f.rig.c.fileCheck = { held.append($0) }
        f.rig.c.open("docs/draft.txt")   // slow
        f.rig.c.open("home/todo.md")     // fast
        XCTAssertEqual(held.count, 2)
        held.last?()
        held.first?()   // the slow check ends last
        XCTAssertEqual(shown(f), [f.dir.path + "/home/todo.md"])
        // Same result when the slow one ends first, and a later click opens again.
        held = []
        f.rig.c.open("docs/draft.txt")
        f.rig.c.open("home/todo.md")
        held.first?()
        held.last?()
        XCTAssertEqual(shown(f), [f.dir.path + "/home/todo.md", f.dir.path + "/home/todo.md"])
        f.rig.c.fileCheck = { $0() }
        f.rig.c.open("docs/draft.txt")
        XCTAssertEqual(shown(f).last, f.dir.path + "/docs/draft.txt")
    }

    // MARK: #1724 (operator 2026-11-20): Cmd alone opens and underlines a link while the program reports the mouse

    /// The operator's screenshot shapes (a Claude Code session): bare relative paths, a path in prose, an absolute one.
    static func captureLines(_ dir: URL) -> String {
        "  Updated CHANGELOG.md and docs/ADR-001-mlx-engine.md (see `extensions.md`).\n"
            + "  the plain words and/or e.g. Node here\n"
            + "  " + dir.path + "/docs/draft.txt\n"
            + "  https://example.org/acme/7\n"
    }

    /// A pane over `captureLines` with mouse reporting `captured`, never in a window; cells 8 x 17 pt at (4, 2) (no
    /// window: scale 2); each left down and up handed on to libghostty recorded.
    private func captureView(_ f: Fixture, captured: Bool) throws -> (AgentTerminalHostView, () -> [NSEvent.EventType]) {
        for name in ["CHANGELOG.md", "docs/ADR-001-mlx-engine.md"] {
            try "fake\n".write(to: f.dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let v = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
        v.owner = f.rig.c
        v.gridMetrics = TerminalGridMetrics(columns: 80, rows: 24, widthPixels: 1280, heightPixels: 816, cellWidthPixels: 16, cellHeightPixels: 34)
        let text = Self.captureLines(f.dir)
        v.viewportText = { text }
        v.mouseCaptured = { captured }
        v.marks.after = { _, _ in }   // output's settle never runs
        final class Box { var passed: [NSEvent.EventType] = [] }
        let box = Box()
        v.passedClick = { box.passed.append($0.type) }
        return (v, { box.passed })
    }

    /// A left down and up at a cell, built and handed straight to the view (never posted).
    private func click(_ v: AgentTerminalHostView, col: Int, row: Int, _ flags: NSEvent.ModifierFlags) throws {
        let at = NSPoint(x: 4 + 8 * CGFloat(col) + 1, y: v.bounds.height - (2 + 17 * CGFloat(row) + 1))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { v.mouseDown(with: e) } else { v.mouseUp(with: e) }
        }
    }

    /// The pointer over a cell through the overlay's own mouseMoved (a built event, never posted).
    private func move(_ v: AgentTerminalHostView, col: Int, row: Int, _ flags: NSEvent.ModifierFlags = .command) throws {
        let p = CGPoint(x: 4 + 8 * CGFloat(col) + 1, y: 2 + 17 * CGFloat(row) + 1)
        let e = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: v.marks.convert(p, to: nil), modifierFlags: flags,
                                                 timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        v.marks.mouseMoved(with: e)
    }

    /// Red at the parent: mouseDown had no link branch (old: `refClick(at: q)` then `passedClick?(event)` and
    /// `super.mouseDown`), so every Cmd-down went to the program and nothing opened.
    func testACommandDownOnAPathWithMouseReportingOpensItAndReachesNoProgram() throws {
        let f = try fixture()
        let (v, passed) = try captureView(f, captured: true)
        try click(v, col: 12, row: 0, .command)          // CHANGELOG.md
        try click(v, col: 35, row: 0, .command)          // docs/ADR-001-mlx-engine.md
        try click(v, col: 10, row: 2, .command)          // the absolute path
        XCTAssertEqual(shown(f), [f.dir.path + "/CHANGELOG.md", f.dir.path + "/docs/ADR-001-mlx-engine.md", f.dir.path + "/docs/draft.txt"])
        XCTAssertTrue(passed().isEmpty, "no down, no up reached libghostty or the program")
        XCTAssertFalse(v.pinnedDown, "the up ended the taken click")
        try click(v, col: 6, row: 3, .command)           // a URL goes to openURL
        XCTAssertEqual(f.rig.opened.map(\.absoluteString), ["https://example.org/acme/7"])
        try click(v, col: 66, row: 0, .command)          // extensions.md: no such file, taken, nothing shown
        XCTAssertEqual(shown(f).count, 3)
        XCTAssertTrue(passed().isEmpty)
    }

    /// Red if a plain click, a Cmd+Shift click (libghostty's own link path, #1719) or a Cmd click on prose is taken, or
    /// a Cmd click with mouse reporting off is (libghostty links it itself then).
    func testOtherClicksStillReachTheProgram() throws {
        let f = try fixture()
        let (v, passed) = try captureView(f, captured: true)
        try click(v, col: 12, row: 0, [])
        try click(v, col: 12, row: 0, [.command, .shift])
        try click(v, col: 4, row: 1, .command)           // "the"
        try click(v, col: 18, row: 1, .command)          // "and/or"
        XCTAssertEqual(passed().count, 8)
        XCTAssertTrue(shown(f).isEmpty && f.rig.opened.isEmpty)
        let (off, offPassed) = try captureView(f, captured: false)
        try click(off, col: 12, row: 0, .command)
        XCTAssertEqual(offPassed(), [.leftMouseDown, .leftMouseUp])
        XCTAssertTrue(shown(f).isEmpty)
    }

    /// Red if the Command hover underlines nothing over a path (old: command() set only the ref hover), underlines prose
    /// or without Command, reads the viewport on a move inside the same cell or more than once per output, or checks the disk (extensions.md has no file
    /// and is underlined by shape).
    func testTheCommandHoverUnderlinesALinkByShapeOnly() throws {
        let f = try fixture()
        let (v, _) = try captureView(f, captured: true)
        try move(v, col: 12, row: 0, [])
        XCTAssertTrue(v.marks.link == nil, "no Command, no underline")
        XCTAssertEqual(v.linkReads, 0)
        try move(v, col: 12, row: 0)
        XCTAssertEqual(v.marks.link, XrayGridMarksView.Mark(row: 0, col: 10, cells: 12, key: "CHANGELOG.md"))
        try move(v, col: 13, row: 0)
        try move(v, col: 13, row: 0)
        XCTAssertEqual(v.linkReads, 2, "one read per cell entered, none for a move inside it")
        try move(v, col: 66, row: 0)
        XCTAssertEqual(v.marks.link?.key, "extensions.md")
        for col in [4, 18, 25, 30] {                     // the, and/or, e.g., Node
            try move(v, col: col, row: 1)
            XCTAssertTrue(v.marks.link == nil, "prose at column \(col)")
        }
        try move(v, col: 12, row: 0)
        let reads = v.linkReads
        v.marks.output()
        XCTAssertEqual(v.linkReads, reads + 1, "output under a Command hover: one re-read per drain")
        XCTAssertEqual(v.marks.link?.key, "CHANGELOG.md")
        v.marks.command(false)
        XCTAssertTrue(v.marks.link == nil, "Command up drops it")
        v.mouseCaptured = { false }
        try move(v, col: 13, row: 0)
        XCTAssertTrue(v.marks.link == nil, "no capture: libghostty's own hover")
    }

    /// Red if a prose word, a quote or trailing punctuation is part of a link, or a link's cells are off.
    func testTheLinkTokenIsTight() {
        func t(_ line: String, _ col: Int) -> String? { AgentTerminalFileLink.token(atColumn: col, in: line)?.text }
        XCTAssertEqual(t("see `CHANGELOG.md`.", 6), "CHANGELOG.md")
        XCTAssertEqual(t("(docs/x.md:12).", 3), "docs/x.md:12")
        XCTAssertEqual(t("at ~/notes, then", 5), "~/notes")
        XCTAssertEqual(t("open https://example.org/a).", 8), "https://example.org/a")
        XCTAssertEqual(AgentTerminalFileLink.token(atColumn: 5, in: "日本 a/b.md")?.col, 5, "a wide character takes two cells")
        for (line, col) in [("the plain words", 5), ("and/or", 1), ("e.g.", 1), ("Node", 1), ("v1.2", 1), ("1/2", 0), ("a  b", 1),
                            ("docs/", 1), ("x.md", 9), ("src/app", 2), ("http://", 2), ("~/", 0)] {
            XCTAssertTrue(AgentTerminalFileLink.token(atColumn: col, in: line) == nil, "\(line) at \(col)")
        }
    }
}
