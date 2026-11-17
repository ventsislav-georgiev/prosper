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
}
