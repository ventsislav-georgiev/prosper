import AppKit
import Darwin
import XCTest
@testable import ProsperApp

/// #1162 (QA 886, riders R886-1 and R886-7). Offscreen only: no window, no event, nothing shown, no link
/// shown; files, folders and links are fakes in the row's own tempDir(), every link points inside it.
@MainActor
final class TextViewerKeepRuleTests: XCTestCase {

    private final class Novel: NSGestureRecognizer {}

    private func names(_ v: NSView) -> [String] { v.gestureRecognizers.map { NSStringFromClass(type(of: $0)) }.sorted() }

    /// R886-1: a set through the gestureRecognizers setter goes through the keep rule, as an add does.
    /// The immediate-action recognizer is refused by both rules; a click recognizer is kept by both; a
    /// class not on the list is refused where the list rule applies (macOS 27 and later) and kept before.
    /// Subset rule, never equality with the system's list: no kept recognizer is of an unknown class.
    func testSetterGoesThroughKeepRule() throws {
        let immediateType = try XCTUnwrap(NSClassFromString("NSImmediateActionGestureRecognizer") as? NSGestureRecognizer.Type)
        let (_, view) = TextViewerTextView.makeScrollable()
        let before = names(view)
        let immediate = immediateType.init(target: nil, action: nil)
        let novel = Novel(), click = NSClickGestureRecognizer()
        view.gestureRecognizers = view.gestureRecognizers + [immediate, novel, click]
        let after = view.gestureRecognizers
        XCTAssertFalse(after.contains(immediate), "the immediate-action recognizer set through the setter")
        XCTAssertTrue(after.contains(click))
        XCTAssertEqual(after.contains(novel), !TextViewerTextView.listRule,
                       "a class not on the list, set through the setter (list rule: \(TextViewerTextView.listRule))")
        XCTAssertEqual(names(view), (before + ["NSClickGestureRecognizer"] + (TextViewerTextView.listRule ? [] : [NSStringFromClass(Novel.self)])).sorted(),
                       "what the view kept before is kept through a get and set")
        if TextViewerTextView.listRule {
            let unknown = Set(names(view)).subtracting(TextViewerTextView.keptRecognizers)
            XCTAssertTrue(unknown.isEmpty, "\(unknown.sorted())")
        }
        view.gestureRecognizers = []
        XCTAssertTrue(view.gestureRecognizers.isEmpty, "an empty set empties the view")
    }

    // MARK: R886-7, the image open

    private func canonical(_ dir: URL) throws -> String {
        try XCTUnwrap(realpath(dir.path, nil).map { p in defer { free(p) }; return String(cString: p) })
    }

    private func url(_ s: String) throws -> URL { try XCTUnwrap(URL(string: s), s) }

    /// A folder on the way checked by the walk, then swapped for a link before the open: the open refuses
    /// it (O_NOFOLLOW_ANY), as it refuses a link in the last name or above the root. The walk itself still
    /// resolves the in-tree link, so the same source loads when asked again.
    func testOpenRefusesALinkSwappedInAfterTheCheck() throws {
        let dir = tempDir("tv1162-swap")
        let root = try canonical(dir)
        let doc = dir.appendingPathComponent("doc.md")
        try Data("# doc\n".utf8).write(to: doc)
        try FileManager.default.createDirectory(atPath: root + "/real", withIntermediateDirectories: false)
        try pngData(width: 8, height: 8).write(to: URL(fileURLWithPath: root + "/real/pic.png"))
        let checked = try XCTUnwrap(ImagePolicy.inside(try url("real/pic.png"), document: doc))
        XCTAssertEqual(checked, root + "/real/pic.png")
        XCTAssertTrue((ImagePolicy.read(checked)?.count ?? 0) > 0, "the path as checked opens")
        // The swap: the folder moves away and a link to it takes its name.
        XCTAssertEqual(rename(root + "/real", root + "/moved"), 0)
        XCTAssertEqual(symlink("moved", root + "/real"), 0)
        XCTAssertTrue(ImagePolicy.read(checked) == nil, "a folder on the way swapped for a link after the check")
        XCTAssertTrue((ImagePolicy.read(root + "/moved/pic.png")?.count ?? 0) > 0, "no link on the way: opens")
        XCTAssertEqual(symlink("moved/pic.png", root + "/last.png"), 0)
        XCTAssertTrue(ImagePolicy.read(root + "/last.png") == nil, "a link in the last name")
        if dir.path != root {   // $TMPDIR is spelled through /var, a link to /private/var
            XCTAssertTrue(ImagePolicy.read(dir.path + "/moved/pic.png") == nil, "a link above the root")
        }
        XCTAssertEqual(ImagePolicy.inside(try url("real/pic.png"), document: doc), root + "/moved/pic.png")
        XCTAssertTrue(ImagePolicy.load(try url("real/pic.png"), document: doc, maxPixelSize: 64)?.width == 8)
    }

    /// The walk's edge: a chain of 32 links (maxSymlinkHops) loads, one of 33 is refused.
    func testThirtyTwoHopsLoadAndThirtyThreeDoNot() throws {
        let dir = tempDir("tv1162-hops")
        let root = try canonical(dir)
        let doc = dir.appendingPathComponent("doc.md")
        try Data("# doc\n".utf8).write(to: doc)
        try pngData(width: 8, height: 8).write(to: dir.appendingPathComponent("pic.png"))
        XCTAssertEqual(ImagePolicy.maxSymlinkHops, 32)
        for (prefix, count) in [("a", 32), ("b", 33)] {
            for i in 1...count {
                let target = i == count ? "pic.png" : "\(prefix)\(i + 1).png"
                XCTAssertEqual(symlink(target, root + "/\(prefix)\(i).png"), 0, "\(prefix)\(i)")
            }
        }
        XCTAssertEqual(ImagePolicy.inside(try url("a1.png"), document: doc), root + "/pic.png", "32 hops")
        XCTAssertTrue(ImagePolicy.load(try url("a1.png"), document: doc, maxPixelSize: 64)?.width == 8, "32 hops")
        XCTAssertTrue(ImagePolicy.inside(try url("b1.png"), document: doc) == nil, "33 hops")
        XCTAssertTrue(ImagePolicy.load(try url("b1.png"), document: doc, maxPixelSize: 64) == nil, "33 hops")
        XCTAssertEqual(ImagePolicy.inside(try url("b2.png"), document: doc), root + "/pic.png", "the same chain from 32 hops")
    }
}
