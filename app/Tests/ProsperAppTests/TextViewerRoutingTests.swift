import XCTest
@testable import ProsperApp

/// #1106 (design #1105 D3): application(_:open:)'s branch. Text documents go to the viewer, every
/// other URL to the link path exactly as before. Recorders only: nothing is opened.
@MainActor
final class TextViewerRoutingTests: XCTestCase {

    private func route(_ urls: [URL]) -> (documents: [URL], links: [String]) {
        var documents: [URL] = [], links: [String] = []
        TextViewerRouting.route(urls, document: { documents.append($0) }, link: { links.append($0) })
        return (documents, links)
    }

    func testDocumentsGoToTheViewerAndLinksToTheRouter() throws {
        let docs = ["notes.md", "README.MD", "guide.markdown", "a.mdown", "b.mkd", "todo.txt", "plain.text"]
            .map { URL(fileURLWithPath: "/Users/example/\($0)") }
        let links = [URL(fileURLWithPath: "/Users/example/page.html"), URL(fileURLWithPath: "/Users/example/old.htm"),
                     try XCTUnwrap(URL(string: "https://example.com/x.md")), try XCTUnwrap(URL(string: "prosper://sleep")),
                     URL(fileURLWithPath: "/Users/example/photo.png")]
        let r = route(docs + links)
        XCTAssertEqual(r.documents, docs)
        XCTAssertEqual(r.links, ["file:///Users/example/page.html", "file:///Users/example/old.htm",
                                 "https://example.com/x.md", "prosper://sleep", "file:///Users/example/photo.png"])
    }

    /// The viewer refuses a bad file itself; the router never sees it (it would hand a text file to a browser).
    func testMissingFileAndFolderNamedMdReachTheViewerAndAreRefused() throws {
        let dir = tempDir("tv-route")
        let missing = dir.appendingPathComponent("x.md")
        let folder = dir.appendingPathComponent("y.md", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let r = route([missing, folder])
        XCTAssertEqual(r.documents.count, 2)
        XCTAssertTrue(r.links.isEmpty, "\(r.links)")
        XCTAssertEqual(TextViewerDocument.load(missing), .failure(.missing))
        XCTAssertEqual(TextViewerDocument.load(folder), .failure(.notRegular))
    }

    func testIsMarkdownTellsMarkdownFromText() {
        XCTAssertTrue(TextViewerRouting.isMarkdown(URL(fileURLWithPath: "/Users/example/a.md")))
        XCTAssertTrue(TextViewerRouting.isMarkdown(URL(fileURLWithPath: "/Users/example/a.MARKDOWN")))
        XCTAssertFalse(TextViewerRouting.isMarkdown(URL(fileURLWithPath: "/Users/example/a.txt")))
    }

    /// D3 cold launch and D14's gate: nothing opens before ready(); after it, an enabled viewer
    /// shows each document in order, a disabled one posts one notice each and shows nothing.
    func testIntakeBuffersUntilReadyThenChecksTheGate() {
        let a = URL(fileURLWithPath: "/Users/example/a.md"), b = URL(fileURLWithPath: "/Users/example/b.txt")
        var shown: [URL] = [], notices = 0, enabled = true
        let intake = TextViewerIntake()
        intake.isEnabled = { enabled }
        intake.notifyOff = { notices += 1 }
        intake.show = { shown.append($0) }
        intake.receive(a)
        intake.receive(b)
        XCTAssertTrue(shown.isEmpty, "opened before the extensions loaded")
        intake.ready()
        XCTAssertEqual(shown, [a, b])
        enabled = false
        intake.receive(a)
        XCTAssertEqual(shown, [a, b])
        XCTAssertEqual(notices, 1)
    }
}
