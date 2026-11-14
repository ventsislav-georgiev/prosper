import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1180 round 3 (N1236-a): the banner's note at the window's minimum width, read on the accessibility tree of windows
/// that are never shown (borderless, deferred, never ordered or made key). The AX flags are set on this test process's
/// own NSApplication only, the prior values read first and put back. Files are fakes in a tempDir(); the actions are
/// no-ops; nothing is opened, posted or copied. Everything here runs on the main actor.
@MainActor
final class TextViewerNoteWidthTests: XCTestCase {

    typealias R = MarkdownRenderer

    /// The joined note at the product cap, as plain(_:style:note:maxParagraphUnits:) joins it (pinned by
    /// MarkdownRendererTests.testCutNoteLiteralAndWithAnotherNote). It reaches the real window only through a Markdown file
    /// over 1 MiB with a line over the paragraph cap, whose layout this row must not do: the Markdown path takes no cap
    /// seam (TextViewerModel.refresh, TextViewerWindow.swift), so the root's own banner is drawn under the real header.
    static let joined = [R.tooLargeNote, R.cutNote(R.maxParagraphUnits)].joined(separator: " \u{00B7} ")

    /// The root's rows above the text, in its order: the header, its rule, a banner. The filler stands for the text view.
    private struct Rows: View {
        let model: TextViewerModel
        let note: String?
        var body: some View {
            VStack(spacing: 0) {
                TextViewerHeader(model: model)
                Rectangle().frame(height: 1)
                if let note { TextViewerRootView(model: model).banner(note) }
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private struct AXItem { let text: String; let frame: CGRect }

    private func axCollect(_ e: Any, _ out: inout [AXItem], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        let frame = o.responds(to: Selector("accessibilityFrame")) ? ((o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero) : .zero
        let label = text("accessibilityLabel")
        out.append(AXItem(text: label.isEmpty ? text("accessibilityValue") : label, frame: frame))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { axCollect(k, &out, depth: depth + 1) }
    }

    private func axFlags(_ set: [Bool]?) -> [Bool] {
        let attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"], app = NSApplication.shared
        let get = Selector(("accessibilityAttributeValue:")), put = Selector(("accessibilitySetValue:forAttribute:"))
        let prior = attrs.map { app.responds(to: get) ? ((app.perform(get, with: $0)?.takeUnretainedValue() as? NSNumber)?.boolValue ?? false) : false }
        if let set, app.responds(to: put) { for (a, f) in zip(attrs, set) { app.perform(put, with: NSNumber(value: f), with: a) } }
        return prior
    }

    /// `root` in a never-shown window of `size`, its AX tree walked until `done` holds, polled on the main run loop to a
    /// 5 s ceiling (no fixed wait); the flags are put back.
    private func axTree<V: View>(_ root: V, _ size: CGSize, until done: ([AXItem]) -> Bool) -> [AXItem] {
        let prior = axFlags(nil)
        defer { _ = axFlags(prior) }
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        _ = axFlags([true, true])
        var tree: [AXItem] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            tree = []
            axCollect(host, &tree)
        } while !done(tree) && Date() < deadline
        XCTAssertFalse(win.isVisible, "never shown")
        return tree
    }

    /// A plain file whose second line is cut at a cap of 8: its note is cutNote(8) (76 characters).
    private func cutModel() throws -> TextViewerModel {
        let url = tempDir("tv-note-width").appendingPathComponent("notes.txt")
        try Data(("ab\n" + String(repeating: "x", count: 20) + "\n").utf8).write(to: url)
        let actions = TextViewerActions(defaultApp: { _ in nil }, openWith: { _, _ in }, reveal: { _ in }, openURL: { _ in }, view: { _ in })
        let model = TextViewerModel(url: url, resolved: url, actions: actions, maxParagraphUnits: 8)
        let deadline = Date().addingTimeInterval(5)
        while model.state == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(model.output?.note == R.cutNote(8), "loaded and cut")
        return model
    }

    /// At the minimum content width and UI scale 0.7, 0.85 and 1.0 the joined note (about 112 characters) and the cut
    /// note in the real root are one line high, as high as the 27-character too-large note, and the header above the
    /// banner keeps every frame it has with no banner. Each note's whole text is on the tree. Before #1180 round 3 both
    /// long notes wrapped there (the banner had no line limit).
    func testJoinedNoteIsOneLineAtTheMinimumWidth() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let model = try cutModel()
        let joined = Self.joined, short = R.tooLargeNote, cut = R.cutNote(8)
        XCTAssertGreaterThan(joined.count, 100)
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let size = TextViewerWindows.contentMinSize(scale: scale)
            let tag = "scale \(scale) at \(size.width) x \(size.height)"
            func has(_ s: String) -> ([AXItem]) -> Bool { { t in t.contains { $0.text == s } && t.contains { $0.text == "notes.txt" } } }
            let one = axTree(Rows(model: model, note: short), size, until: has(short))
            let two = axTree(Rows(model: model, note: joined), size, until: has(joined))
            let none = axTree(Rows(model: model, note: nil), size, until: { t in t.contains { $0.text == "notes.txt" } })
            let real = axTree(TextViewerRootView(model: model), size, until: has(cut))
            let line = try XCTUnwrap(one.first { $0.text == short }, "\(tag): \(one.map(\.text))").frame
            let banner = try XCTUnwrap(two.first { $0.text == joined }, "\(tag): the whole joined text: \(two.map(\.text))").frame
            let cutBanner = try XCTUnwrap(real.first { $0.text == cut }, "\(tag): the whole cut note: \(real.map(\.text))").frame
            XCTAssertGreaterThan(line.height, 0, tag)
            XCTAssertEqual(banner.height, line.height, accuracy: 0.5, "\(tag): the joined note is one line")
            XCTAssertEqual(cutBanner.height, line.height, accuracy: 0.5, "\(tag): the cut note in the real root is one line")
            XCTAssertLessThanOrEqual(banner.width, size.width + 0.5, tag)
            // AX frames are in screen points, y up: the header is what lies above the banner.
            let header = two.filter { $0.frame.height > 0 && $0.frame.minY >= banner.maxY && $0.text != joined }
            XCTAssertTrue(header.contains { $0.text == "notes.txt" }, "\(tag): \(header.map(\.text))")
            for item in header {
                XCTAssertTrue(none.contains { $0.text == item.text && $0.frame == item.frame },
                              "\(tag): \(item.text) at \(item.frame) moved when the banner appeared")
            }
            fputs("tv1180c fact \(tag): one line \(line.height) pt, joined \(banner), cut note \(cutBanner), \(header.count) header elements unmoved\n", stderr)
        }
    }
}
