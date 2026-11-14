import AppKit
import Darwin
import Quartz
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1106 (design #1105 D8, D9, section 3, riders R1 and R3). Offscreen only: windows are built
/// through the `build` seam and never shown, ordered or made key; no event is posted; the
/// pasteboards are the private XCTest ones; files are fakes in a tempDir().
@MainActor
final class TextViewerWindowTests: XCTestCase {

    private struct Fakes {
        var presented: [NSWindow] = []
        var dismissed = 0
        var opened: [(URL, URL)] = []
        var revealed: [URL] = []
        var openedURLs: [URL] = []
        var viewed: [URL] = []
    }

    private var fakes = Fakes()

    private func registry() -> TextViewerWindows {
        let w = TextViewerWindows()
        w.build = { TextViewerWindows.makeWindow($0, autosave: nil) }
        w.present = { [unowned self] in self.fakes.presented.append($0) }
        w.dismissed = { [unowned self] _ in self.fakes.dismissed += 1 }
        w.actions = { [unowned self] in self.fakeActions() }
        w.imageLoader = { _, _, _ in nil }
        return w
    }

    private func fakeActions() -> TextViewerActions {
        TextViewerActions(defaultApp: { _ in URL(fileURLWithPath: "/Applications/Example.app") },
                          openWith: { [unowned self] in self.fakes.opened.append(($0, $1)) },
                          reveal: { [unowned self] in self.fakes.revealed.append($0) },
                          openURL: { [unowned self] in self.fakes.openedURLs.append($0) },
                          view: { [unowned self] in self.fakes.viewed.append($0) })
    }

    /// #1118 R1118-2: the file is read and rendered off the main thread; a condition polled on the
    /// main run loop to a 5 s deadline, never a fixed sleep.
    private func waitUntil(_ what: String, _ done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done(), "not within 5 s: \(what)", file: file, line: line)
    }

    private func loaded(_ model: TextViewerModel, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("\(model.name) loaded", { model.state != nil }, file: file, line: line)
    }

    private func loaded(_ w: TextViewerWindows, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("every window loaded", { w.entries.allSatisfy { $0.model.state != nil } }, file: file, line: line)
    }

    private func closeAll(_ w: TextViewerWindows) {
        for e in w.entries { e.window.close() }
    }

    private func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }

    /// D9: one window per file. The same path, a symlink to it, another case of its name and a
    /// hard link all focus the one window (counted through `present`); another file gets its own.
    func testSecondOpenFocusesTheOneWindow() throws {
        let dir = tempDir("tv-win")
        let a = dir.appendingPathComponent("Notes.md")
        try write("# a\n", a)
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let hard = dir.appendingPathComponent("hard.md")
        try FileManager.default.linkItem(at: a, to: hard)
        let w = registry()
        defer { closeAll(w) }
        w.open(a)
        w.open(a)
        w.open(link)
        w.open(hard)
        var opens = 4
        let otherCase = dir.appendingPathComponent("notes.md")
        if FileManager.default.fileExists(atPath: otherCase.path) {   // a case-insensitive volume (the default)
            w.open(otherCase)
            opens += 1
        }
        XCTAssertEqual(w.entries.count, 1)
        XCTAssertEqual(fakes.presented.count, opens)
        XCTAssertTrue(fakes.presented.allSatisfy { $0 === fakes.presented.first }, "always the same window")
        XCTAssertEqual(w.entries.first?.window.title, "Notes.md")

        let b = dir.appendingPathComponent("b.txt")
        try write("b\n", b)
        w.open(b)
        XCTAssertEqual(w.entries.count, 2)
        XCTAssertFalse(fakes.presented.last === fakes.presented.first)
        loaded(w)   // #1118: watched once the off-main load lands
        XCTAssertTrue(w.entries.allSatisfy { $0.watcher != nil }, "a shown file is watched")

        // A refused folder gets its window but no watcher (a FIFO would block the watcher open).
        let folder = dir.appendingPathComponent("folder.md", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        w.open(folder)
        XCTAssertEqual(w.entries.count, 3)
        loaded(w)
        XCTAssertTrue(w.entries.last?.watcher == nil, "a refused folder is not watched")

        closeAll(w)
        XCTAssertTrue(w.entries.isEmpty)
        XCTAssertEqual(fakes.dismissed, 3)
        XCTAssertFalse(fakes.presented.contains { $0.isVisible }, "never on screen")
    }

    /// D9 reload, R3: an external write shows up, polled to a 5 s deadline (the watcher's debounce
    /// is 0.2 s), never a fixed sleep.
    func testExternalWriteReloads() throws {
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("live.md")
        try write("one\n", url)
        let w = registry()
        defer { closeAll(w) }
        w.open(url)
        let model = try XCTUnwrap(w.entries.first?.model)
        loaded(model)
        waitUntil("watched", { w.entries.first?.watcher != nil })
        XCTAssertEqual(model.document?.text, "one\n")
        try Data("two\n".utf8).write(to: url, options: .atomic)   // an editor's save: a rename over the file
        waitUntil("reloaded", { model.document?.text == "two\n" })
        XCTAssertEqual(model.output?.text.string, "two", "the reload is rendered too")
    }

    /// R1118-7: the window reads the path it watches (resolved at open). A symlink retargeted after
    /// the open does not move the window: a write to the file it opened still shows there, and the
    /// new target's bytes never do.
    func testRetargetedSymlinkKeepsTheOpenedFile() throws {
        let dir = tempDir("tv-win")
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try write("a1\n", a)
        try write("b1\n", b)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        let w = registry()
        defer { closeAll(w) }
        w.open(link)
        let model = try XCTUnwrap(w.entries.first?.model)
        loaded(model)
        waitUntil("watched", { w.entries.first?.watcher != nil })
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
        try Data("a2\n".utf8).write(to: a, options: .atomic)
        waitUntil("the opened file reloaded", { model.document?.text == "a2\n" })
        XCTAssertEqual(model.document?.text, "a2\n")
        // Round 2: wait for this reload to land (a load requested before it is dropped by its generation).
        let n = model.loads
        model.reload()
        waitUntil("reloaded again", { model.loads > n })
        XCTAssertEqual(model.document?.text, "a2\n", "the reload read the opened file, not the new target")
    }

    /// Section 3 N7: opening writes nothing. The folder's entries (readdir, so AppleDouble names
    /// count too), sizes and mtimes, and the folder's own mtime, are the same after an open, a reload
    /// and a close.
    func testOpenWritesNothing() throws {
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("quiet.md")
        // #1118: rendered with the live image loader, a local and a remote image and links of every kind.
        try write("# quiet\n\n![pic](pic.png) ![far](https://example.com/far.png) [a](other.md) [b](https://example.com)\n", url)
        try pngData(width: 4, height: 4).write(to: dir.appendingPathComponent("pic.png"))
        let before = try listing(dir)
        let w = registry()
        w.imageLoader = ImagePolicy.load
        w.open(url)
        let model = try XCTUnwrap(w.entries.first?.model)
        loaded(model)
        XCTAssertEqual(model.output?.text.string.contains("\u{FFFC}"), true, "the local image is drawn")
        let first = try XCTUnwrap(model.output?.text)
        let n = model.loads
        model.reload()
        waitUntil("the reload landed", { model.loads > n })   // the same bytes: the shown text is kept
        XCTAssertTrue(model.output?.text === first, "an unchanged reload keeps the shown text")
        let view = NSHostingView(rootView: TextViewerRootView(model: model))
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        _ = try snapshot(view, backing: 1)
        closeAll(w)
        XCTAssertEqual(try listing(dir), before)
    }

    private func listing(_ dir: URL) throws -> [String] {
        func stamp(_ path: String) -> String {
            var st = stat()
            guard lstat(path, &st) == 0 else { return "gone" }
            return "\(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
        let d = try XCTUnwrap(opendir(dir.path))
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return ["<dir> " + stamp(dir.path)] + names.sorted().map { "\($0) " + stamp(dir.appendingPathComponent($0).path) }
    }

    /// The view drawn into a bitmap at an explicit backing scale, never in a window (as
    /// AgentWindowChromeTests.snapshot), after a settle bounded at 0.3 s.
    private func snapshot(_ v: NSView, backing: CGFloat) throws -> NSBitmapImageRep {
        func pending(_ v: NSView) -> Bool { v.needsLayout || v.needsDisplay || v.subviews.contains(where: pending) }
        let deadline = Date().addingTimeInterval(0.3)
        repeat {
            v.layoutSubtreeIfNeeded()
            v.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        } while pending(v) && Date() < deadline
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((v.bounds.width * backing).rounded()),
            pixelsHigh: Int((v.bounds.height * backing).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    private func luminance(_ c: NSColor?) -> CGFloat {
        guard let c = c?.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    /// D9 chrome, offscreen: the window's content drawn light and dark at UI scale 0.85 and 1.0. The
    /// backdrop follows the theme, the text is drawn in the monospaced body font at the scale, and
    /// the text pixels stand out from the backdrop.
    func testDrawsOffscreenLightAndDarkAtTwoScales() throws {
        _ = ThemeStore.shared   // its first use publishes the stored scale; touch it before pinning ours
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        ThemeRuntime.opacity = 1
        ThemeRuntime.frost = false
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("draw.txt")
        try write(String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: 30), url)
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved.1 : AgentWindowD1Tests.lightPalette
            for scale: CGFloat in [0.85, 1.0] {
                ThemeRuntime.scale = scale
                let model = TextViewerModel(url: url, resolved: url, actions: fakeActions())
                loaded(model)
                let win = TextViewerWindows.makeWindow(model, autosave: nil)
                defer { win.close() }
                XCTAssertEqual(win.identifier, TextViewerWindows.themedIdentifier)
                XCTAssertEqual(win.contentMinSize, TextViewerWindows.contentMinSize(scale: scale))
                let size = CGSize(width: 820 * scale, height: 640 * scale)
                let root = TextViewerRootView(model: model).environment(\.colorScheme, dark ? .dark : .light)
                let view = NSHostingView(rootView: root)
                view.frame = CGRect(origin: .zero, size: size)
                let rep = try snapshot(view, backing: 2)
                let tag = "\(dark ? "dark" : "light") \(scale)"
                XCTAssertEqual(rep.pixelsWide, Int((size.width * 2).rounded()), tag)
                let tv = try XCTUnwrap(model.textView, tag)
                XCTAssertEqual(tv.string.count, 45 * 30, tag)
                XCTAssertEqual(tv.font?.pointSize ?? 0, 13 * scale, accuracy: 0.01, tag)
                XCTAssertTrue(tv.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true, tag)
                // Backdrop at the bottom-right corner; text in the first lines of the column.
                let bg = rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh - 4)
                XCTAssertEqual(luminance(bg) < 0.5, dark, "\(tag): backdrop \(luminance(bg))")
                var ink = 0
                let top = Int(80 * scale * 2), bottom = Int(200 * scale * 2)
                for y in stride(from: top, to: bottom, by: 2) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 2)
                    where abs(luminance(rep.colorAt(x: x, y: y)) - luminance(bg)) > 0.25 { ink += 1 }
                }
                XCTAssertGreaterThan(ink, 200, "\(tag): no text drawn")
            }
        }
    }

    /// D8: ⌘C writes the selection as plain text plus RTF through Pasteboard.general, the private
    /// XCTest pasteboard; Cut and Paste do nothing in Read mode.
    func testCopyGoesThroughThePasteboardSeam() throws {
        let pb = Pasteboard.general
        XCTAssertTrue(pb.name.rawValue.hasPrefix("eu.illegible.prosper.xctest"), "the private test pasteboard")
        let (_, view) = TextViewerTextView.makeScrollable()
        view.show(NSAttributedString(string: "alpha beta gamma"))
        pb.clearContents()
        pb.setString("before", forType: .string)
        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.copy(nil)
        XCTAssertEqual(pb.string(forType: .string), "before", "no selection: the pasteboard is left alone")
        view.setSelectedRange(NSRange(location: 6, length: 4))
        view.copy(nil)
        XCTAssertEqual(pb.string(forType: .string), "beta")
        XCTAssertTrue(pb.types?.contains(.rtf) == true, "\(pb.types ?? [])")
        pb.clearContents()
        pb.setString("keep", forType: .string)
        view.cut(nil)
        view.paste(nil)
        XCTAssertEqual(view.string, "alpha beta gamma", "Read mode: no cut, no paste")
        XCTAssertEqual(pb.string(forType: .string), "keep")
    }

    /// R1118-1: an Option-drag column selection has several ranges; Copy joins them all with
    /// newlines (it used to copy the first only).
    func testCopyJoinsEverySelectedRange() throws {
        let pb = Pasteboard.general
        let (_, view) = TextViewerTextView.makeScrollable()
        view.show(NSAttributedString(string: "alpha beta gamma"))
        view.selectedRanges = [NSValue(range: NSRange(location: 0, length: 5)), NSValue(range: NSRange(location: 11, length: 5))]
        XCTAssertEqual(view.selectedRanges.count, 2)
        view.copy(nil)
        XCTAssertEqual(pb.string(forType: .string), "alpha\ngamma")
    }

    /// R1: ⌘E puts the selection on the find pasteboard seam, a private one under XCTest. No search
    /// is driven.
    func testUseSelectionForFindUsesTheFindSeam() throws {
        let find = TextViewerFind.pasteboard
        XCTAssertTrue(find.name.rawValue.hasPrefix("eu.illegible.prosper.xctest.find"), "the private find pasteboard")
        let (_, view) = TextViewerTextView.makeScrollable()
        view.show(NSAttributedString(string: "alpha beta gamma"))
        view.setSelectedRange(NSRange(location: 11, length: 5))
        view.useSelectionForFind()
        XCTAssertEqual(find.string(forType: .string), "gamma")
    }

    /// D8: the header's Copy menu (Copy Text, Copy Markdown Source, Copy Path) and Open With (the
    /// default app, Reveal in Finder) go through the seams.
    func testHeaderActions() throws {
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("menu.md")
        try write("# menu\n", url)
        let model = TextViewerModel(url: url, resolved: url, actions: fakeActions())
        XCTAssertTrue(model.isMarkdown)
        loaded(model)
        let pb = Pasteboard.general
        model.copyText()
        XCTAssertEqual(pb.string(forType: .string), "menu", "#1118: Copy Text is the rendered text")
        model.copyPath()
        XCTAssertEqual(pb.string(forType: .string), url.path)
        model.copySource()
        XCTAssertEqual(pb.string(forType: .string), "# menu\n")
        model.openInDefaultApp()
        model.reveal()
        XCTAssertEqual(fakes.opened.first?.0, url)
        XCTAssertEqual(fakes.opened.first?.1.lastPathComponent, "Example.app")
        XCTAssertEqual(fakes.revealed, [url])
        XCTAssertEqual(model.copyItems.map(\.title), ["Copy Text", "Copy Markdown Source", "Copy Path"])
        XCTAssertTrue(model.copyItems.allSatisfy(\.enabled))
    }

    /// R1118-9: a refused file has no text to copy, but it has a path: Copy Path stays enabled.
    func testCopyPathIsOnForARefusedFile() throws {
        let dir = tempDir("tv-win")
        let bin = dir.appendingPathComponent("bin.md")
        try Data([0x61, 0x00, 0x62]).write(to: bin)
        let model = TextViewerModel(url: bin, resolved: bin, actions: fakeActions())
        loaded(model)
        XCTAssertEqual(model.state, .failure(.binary))
        typealias C = TextViewerModel.CopyItem
        XCTAssertEqual(model.copyItems, [C(title: "Copy Text", enabled: false), C(title: "Copy Markdown Source", enabled: false),
                                         C(title: "Copy Path", enabled: true)])
        model.copyPath()
        XCTAssertEqual(Pasteboard.general.string(forType: .string), bin.path)
        let missing = TextViewerModel(url: dir.appendingPathComponent("gone.txt"), resolved: dir.appendingPathComponent("gone.txt"),
                                      actions: fakeActions())
        loaded(missing)
        XCTAssertEqual(missing.copyItems, [C(title: "Copy Text", enabled: false), C(title: "Copy Path", enabled: true)])
    }

    /// R1118-2, on the real queue: the file is read, rendered and its images loaded off the main
    /// thread, then published on it. The recorder runs where the loader runs.
    func testLoadsOffTheMainThread() throws {
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("off.md")
        try write("# off\n\n![a](a.png)\n", url)
        final class Threads: @unchecked Sendable {
            let lock = NSLock()
            var main: [Bool] = []
            func add(_ b: Bool) { lock.lock(); main.append(b); lock.unlock() }
            var all: [Bool] { lock.lock(); defer { lock.unlock() }; return main }
        }
        let seen = Threads()
        let model = TextViewerModel(url: url, resolved: url, actions: fakeActions(),
                                    imageLoader: { _, _, _ in seen.add(Thread.isMainThread); return nil })
        XCTAssertTrue(model.state == nil, "init returns before the read")
        loaded(model)
        XCTAssertEqual(seen.all, [false])
        XCTAssertEqual(model.output?.text.string, "off\n[image: a]")
    }

    /// D6: a click on a link reaches the model, which asks LinkPolicy again and acts only through
    /// its seams; AppKit's own link and data detection stay off. No link is opened.
    func testLinkClicksGoThroughThePolicy() throws {
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("links.md")
        try write("# Top\n\nbody\n", url)
        let model = TextViewerModel(url: url, resolved: url, actions: fakeActions())
        loaded(model)
        let (_, view) = TextViewerTextView.makeScrollable()
        XCTAssertFalse(view.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(view.isAutomaticDataDetectionEnabled)
        view.onLink = { [weak model] in model?.follow($0) }
        model.textView = view
        view.show(try XCTUnwrap(model.output?.text))
        for link in ["https://example.com/a", "other.md", "run.sh", "file:///Applications/Calculator.app",
                     "javascript:alert(1)", "prosper://sleep", "#top", "#nowhere"] {
            view.clicked(onLink: try XCTUnwrap(URL(string: link)), at: 0)
        }
        view.clicked(onLink: "mailto:a@example.com", at: 0)   // AppKit may hand over a String
        XCTAssertEqual(fakes.openedURLs.map(\.absoluteString), ["https://example.com/a", "mailto:a@example.com"])
        XCTAssertEqual(fakes.viewed.map(\.lastPathComponent), ["other.md", "run.sh"])
        XCTAssertEqual(fakes.revealed.map(\.path), ["/Applications/Calculator.app"])
        XCTAssertTrue(fakes.opened.isEmpty, "no default-app open")
    }

    // MARK: Round 2 item 3: AppKit's other paths to a link. Offscreen: an unordered window, a made
    // right-mouse event handed to menu(for:) directly; no menu pops up, no event is posted. The only
    // link ever acted on is "#top" (a scroll); Copy Link, Look Up, Services and Share are listed only.

    /// A stock text view whose link click is recorded and goes no further.
    private final class StockView: NSTextView {
        var follows: [String] = []
        override func clicked(onLink link: Any, at charIndex: Int) { follows.append("\(link)") }
    }

    private static let topLink: NSAttributedString = {
        let s = NSMutableAttributedString(string: "go top now", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        s.addAttributes([.link: URL(string: "#top")!, .toolTip: "#top"], range: NSRange(location: 3, length: 3))
        return s
    }()

    /// The window, and a right-mouse-down at character `index` of `view` (already in that window).
    private func rightClick(_ view: NSTextView, _ window: NSWindow, at index: Int) throws -> NSEvent {
        let lm = try XCTUnwrap(view.layoutManager), tc = try XCTUnwrap(view.textContainer)
        lm.ensureLayout(for: tc)
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        let p = view.convert(NSPoint(x: r.midX + view.textContainerOrigin.x, y: r.midY + view.textContainerOrigin.y), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1))
    }

    private func describe(_ menu: NSMenu?, _ indent: String = "") -> [String] {
        (menu?.items ?? []).flatMap { item -> [String] in
            let line = "\(indent)\(item.isSeparatorItem ? "---" : item.title) -> \(item.action.map(NSStringFromSelector) ?? "nil")"
            return [line] + describe(item.submenu, indent + "  ")
        }
    }

    private func fact(_ s: String) { fputs("tv1b fact \(s)\n", stderr) }

    /// The accessibility link elements under `view` (the NSAccessibility attribute AXLinkUIElements,
    /// or children whose role is a link).
    private func axLinks(_ view: NSView) -> [NSObject] {
        let named = view.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXLinkUIElements")) as? [NSObject] ?? []
        let children = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
            .filter { ($0.accessibilityAttributeValue(.role) as? String) == NSAccessibility.Role.link.rawValue }
        return named.isEmpty ? children : named
    }

    /// Facts: the stock view's menu at a link, its accessibility link and press, its Quick Look items.
    func testStockLinkPathsFacts() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = StockView(usingTextLayoutManager: false)   // TextKit 1, as ours
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        view.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        view.isEditable = false
        view.isSelectable = true
        window.contentView = view
        view.textStorage?.setAttributedString(Self.topLink)
        let menu = view.menu(for: try rightClick(view, window, at: 4))
        fact("stock menu at a link: \(describe(menu).joined(separator: " | "))")
        fact("stock displaysLinkToolTips \(view.displaysLinkToolTips); Quick Look items at the link: \(view.quickLookPreviewableItems(inRanges: [NSValue(range: NSRange(location: 3, length: 3))]))")
        if let open = menu?.items.first(where: { $0.title == "Open Link" }), let action = open.action {
            fact("Open Link target \(String(describing: open.target)) action \(NSStringFromSelector(action))")
            _ = ((open.target as? NSObject) ?? view).perform(action, with: open)
            fact("after Open Link on #top: clicked(onLink:) saw \(view.follows)")
            XCTAssertEqual(view.follows, ["#top"], "Open Link goes through clicked(onLink:at:), once")
        }
        view.follows = []
        fact("stock accessibility role \(view.accessibilityRole()?.rawValue ?? "nil"); attributes \(view.accessibilityAttributeNames().map(\.rawValue))")
        for link in axLinks(view) {
            fact("stock AX link role \(link.accessibilityAttributeValue(.role) ?? "nil") url \(link.accessibilityAttributeValue(.url) ?? "nil") actions \(link.accessibilityActionNames().map(\.rawValue))")
            if link.accessibilityActionNames().contains(.press) {
                link.accessibilityPerformAction(.press)
                fact("after AXPress on #top: clicked(onLink:) saw \(view.follows)")
                XCTAssertEqual(view.follows, ["#top"], "AXPress goes through clicked(onLink:at:), once")
            }
        }
        if axLinks(view).isEmpty { fact("stock view exposes no AX link element") }
    }

    /// Ours: at a link the menu is Copy and Copy Link Address (the tooltip's target), nothing that
    /// opens; Copy Link Address writes the Pasteboard.general seam; Quick Look has nothing; an
    /// accessibility press goes through clicked(onLink:at:) to the model's policy.
    func testLinkMenuIsInert() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let (scroll, view) = TextViewerTextView.makeScrollable()
        scroll.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = scroll
        var follows: [URL] = []
        view.onLink = { follows.append($0) }
        view.show(Self.topLink)
        let menu = view.menu(for: try rightClick(view, window, at: 4))
        fact("our menu at a link: \(describe(menu).joined(separator: " | "))")
        XCTAssertEqual(Set(describe(menu)), ["Copy -> copy:", "Copy Link Address -> copyLinkAddress:"])
        XCTAssertEqual(describe(menu).count, 2)
        let off = view.menu(for: try rightClick(view, window, at: 0))
        fact("our menu off a link: \(describe(off).joined(separator: " | "))")
        XCTAssertFalse(describe(off).contains("Copy Link Address -> copyLinkAddress:"))
        let item = try XCTUnwrap(menu?.items.first(where: { $0.action == #selector(TextViewerTextView.copyLinkAddress(_:)) }))
        view.copyLinkAddress(item)
        XCTAssertEqual(Pasteboard.general.string(forType: .string), "#top")
        XCTAssertTrue(view.quickLookPreviewableItems(inRanges: [NSValue(range: NSRange(location: 0, length: 10))]).isEmpty,
                      "the stock list holds the link's URL: nothing for Quick Look to preview")
        // Round 3 (F3), the Round 2 facts asserted: one AX link element, its actions hold AXPress, one
        // press reaches the seam once.
        let links = axLinks(view)
        XCTAssertEqual(links.count, 1)
        let link = try XCTUnwrap(links.first)
        XCTAssertTrue(link.accessibilityActionNames().contains(.press), "\(link.accessibilityActionNames())")
        XCTAssertTrue(follows.isEmpty)
        link.accessibilityPerformAction(.press)
        XCTAssertEqual(follows.map(\.absoluteString), ["#top"], "a press reaches the seam once")
    }

    /// Round 3 (F1): a force click at a link starts no immediate action. NSTextView adds an
    /// NSImmediateActionGestureRecognizer at init, and its force click previews a link's target without
    /// passing through quickLook(with:); ours refuses every recognizer outside keptRecognizers. Reads
    /// recognizers only: no event, no preview, nothing shown.
    func testForceClickHasNoImmediateAction() throws {
        func names(_ v: NSView) -> [String] { v.gestureRecognizers.map { NSStringFromClass(type(of: $0)) }.sorted() }
        let immediate = "NSImmediateActionGestureRecognizer"
        let stock = names(NSTextView(usingTextLayoutManager: false))
        fact("stock TextKit 1 recognizers: \(stock)")
        XCTAssertEqual(stock.filter { $0 == immediate }.count, 1, "the recognizer this guards against: \(stock)")
        XCTAssertEqual(Set(stock), TextViewerTextView.keptRecognizers.union([immediate]),
                       "a stock recognizer was added or renamed: read what it does before keeping it")
        let kept = stock.filter { $0 != immediate }
        let (scroll, view) = TextViewerTextView.makeScrollable()
        XCTAssertEqual(names(view), kept, "everything else the stock view adds is kept")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        scroll.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = scroll
        view.show(Self.topLink)
        view.isEditable = true
        view.isEditable = false
        XCTAssertEqual(names(view), kept, "in a window, with a link shown, after an editable toggle")
        // The decision, fail closed: a recognizer of a class not on the list is refused; a kept one is not.
        let novel = Novel()
        view.addGestureRecognizer(novel)
        XCTAssertFalse(view.gestureRecognizers.contains(novel))
        let click = NSClickGestureRecognizer()
        view.addGestureRecognizer(click)
        XCTAssertTrue(view.gestureRecognizers.contains(click))
    }

    private final class Novel: NSGestureRecognizer {}

    /// Round 4 (R3-1): both rules of TextViewerTextView.keeps on this Mac. The list was read on macOS 27
    /// only; older systems refuse just the immediate-action recognizer, by class and any subclass, and keep
    /// everything else. Pure decisions on recognizer objects: no event, nothing shown.
    func testRecognizerRulesForOlderAndNewerSystems() throws {
        let stock = NSTextView(usingTextLayoutManager: false).gestureRecognizers
        let immediate = try XCTUnwrap(stock.first { NSStringFromClass(type(of: $0)) == "NSImmediateActionGestureRecognizer" })
        let immediateClass: AnyClass = type(of: immediate)
        let subName = "TV1118ImmediateSubclass"
        let sub: AnyClass = try XCTUnwrap(NSClassFromString(subName) ?? {
            let c = objc_allocateClassPair(immediateClass, subName, 0)
            if let c { objc_registerClassPair(c) }
            return c
        }())
        let subRecognizer = try XCTUnwrap((sub as? NSObject.Type)?.init() as? NSGestureRecognizer)
        // Older systems (macOS 14 to 26): only the immediate-action recognizer and its subclass are refused.
        XCTAssertFalse(TextViewerTextView.keeps(immediate, listRule: false))
        XCTAssertFalse(TextViewerTextView.keeps(subRecognizer, listRule: false), "a subclass is refused too")
        XCTAssertTrue(TextViewerTextView.keeps(Novel(), listRule: false))
        XCTAssertTrue(TextViewerTextView.keeps(NSClickGestureRecognizer(), listRule: false))
        XCTAssertEqual(stock.filter { !TextViewerTextView.keeps($0, listRule: false) }.count, 1, "every other stock recognizer is kept")
        // macOS 27 and later: the list.
        XCTAssertFalse(TextViewerTextView.keeps(immediate, listRule: true))
        XCTAssertFalse(TextViewerTextView.keeps(Novel(), listRule: true))
        XCTAssertTrue(TextViewerTextView.keeps(NSClickGestureRecognizer(), listRule: true))
    }

    /// R1118-8: closing a window stops its watcher, removes its close observer and drops its entry.
    func testCloseTearsDown() throws {
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("close.txt")
        try write("c\n", url)
        let w = registry()
        w.open(url)
        let entry = try XCTUnwrap(w.entries.first)
        loaded(w)
        waitUntil("watched", { entry.watcher != nil })
        XCTAssertNotNil(entry.observer)
        weak let watcher = entry.watcher
        entry.window.close()
        XCTAssertTrue(w.entries.isEmpty)
        XCTAssertTrue(entry.watcher == nil && entry.observer == nil && entry.model.onFirstLoad == nil)
        XCTAssertTrue(watcher == nil, "the watcher is released, not only stopped")
        XCTAssertEqual(fakes.dismissed, 1)
        try write("d\n", url)   // a write after the close reaches no one
        entry.window.close()
        XCTAssertEqual(fakes.dismissed, 1, "the observer is gone: a second close is not torn down twice")
    }

    /// D5 offscreen, light and dark: a rendered Markdown document draws its heading larger than its
    /// body, its table as an NSTextTable, and ink on the backdrop. Never in a window on screen.
    func testDrawsMarkdownOffscreenLightAndDark() throws {
        _ = ThemeStore.shared
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        ThemeRuntime.opacity = 1
        ThemeRuntime.frost = false
        ThemeRuntime.scale = 1
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("draw.md")
        try write("# Heading\n\nSome **bold** text and `code`.\n\n| a | b |\n|---|--:|\n| 1 | 2 |\n\n> quoted\n", url)
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved.1 : AgentWindowD1Tests.lightPalette
            let model = TextViewerModel(url: url, resolved: url, actions: fakeActions())
            loaded(model)
            let root = TextViewerRootView(model: model).environment(\.colorScheme, dark ? .dark : .light)
            let view = NSHostingView(rootView: root)
            view.frame = CGRect(x: 0, y: 0, width: 820, height: 640)
            let rep = try snapshot(view, backing: 2)
            let tag = dark ? "dark" : "light"
            let storage = try XCTUnwrap(model.textView?.textStorage, tag)
            XCTAssertTrue(storage.string.hasPrefix("Heading\n"), tag)
            let headFont = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            XCTAssertEqual(headFont?.pointSize ?? 0, 20, accuracy: 0.01, tag)
            let cell = (storage.string as NSString).range(of: "2")
            let blocks = (storage.attribute(.paragraphStyle, at: cell.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks
            XCTAssertTrue(blocks?.contains { $0 is NSTextTableBlock } == true, tag)
            let bg = rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh - 4)
            XCTAssertEqual(luminance(bg) < 0.5, dark, "\(tag): backdrop \(luminance(bg))")
            var ink = 0
            for y in stride(from: 160, to: 600, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2)
                where abs(luminance(rep.colorAt(x: x, y: y)) - luminance(bg)) > 0.25 { ink += 1 }
            }
            XCTAssertGreaterThan(ink, 200, "\(tag): nothing drawn")
        }
    }

    /// The brief: Read is on the left and is the only mode; Edit is drawn, disabled, until P3.
    func testReadIsLeftAndEditIsOff() {
        XCTAssertEqual(TextViewerModeSwitch.segments,
                       [.init(title: "Read", enabled: true), .init(title: "Edit", enabled: false)])
    }

    private func key(_ chars: String, _ mods: NSEvent.ModifierFlags, code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: chars,
                                       charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    /// D9 keys: the window routes its own; events are built, never posted.
    func testKeyRoutes() throws {
        typealias R = TextViewerNSWindow.KeyRoute
        XCTAssertEqual(TextViewerNSWindow.route(try key("w", .command, code: 13)), R.close)
        XCTAssertEqual(TextViewerNSWindow.route(try key("f", .command, code: 3)), R.find(.showFindInterface))
        XCTAssertEqual(TextViewerNSWindow.route(try key("g", .command, code: 5)), R.find(.nextMatch))
        XCTAssertEqual(TextViewerNSWindow.route(try key("G", [.command, .shift], code: 5)), R.find(.previousMatch))
        XCTAssertEqual(TextViewerNSWindow.route(try key("e", .command, code: 14)), R.useSelectionForFind)
        XCTAssertEqual(TextViewerNSWindow.route(try key("t", .command, code: 17)), R.pass, "no Edit until P3")
        XCTAssertEqual(TextViewerNSWindow.route(try key("c", .command, code: 8)), R.pass, "⌘C is the Edit menu's")
        XCTAssertEqual(TextViewerNSWindow.route(try key("w", [], code: 13)), R.pass)
        // R1118-4: ⌘W with Command alone; ⇧⌘W and ⌥⌘W are not this window's close.
        XCTAssertEqual(TextViewerNSWindow.route(try key("W", [.command, .shift], code: 13)), R.pass)
        XCTAssertEqual(TextViewerNSWindow.route(try key("w", [.command, .option], code: 13)), R.pass)
        XCTAssertEqual(TextViewerNSWindow.route(try key("f", [.command, .option], code: 3)), R.pass, "⌥⌘F is not Find")
        XCTAssertEqual(TextViewerNSWindow.route(try key("g", [], code: 5)), R.pass)
    }

    /// The theme hook (AppDelegate.applyThemedWindowSizing) finds the viewer by its identifier.
    func testThemeHookSizesTheViewer() throws {
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("t.txt")
        try write("t\n", url)
        let win = TextViewerWindows.makeWindow(TextViewerModel(url: url, resolved: url, actions: fakeActions()), autosave: nil)
        defer { win.close() }
        AppDelegate.applyThemedWindowSizing([win], scale: 1.3)
        XCTAssertEqual(win.contentMinSize, TextViewerWindows.contentMinSize(scale: 1.3))
    }

    /// Section 3 N1, N2, N6: the viewer's source never reaches a network, web view, script engine or
    /// process API, and never the system pasteboard directly.
    func testSourceGuard() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/TextViewer")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertEqual(names, ["ImagePolicy.swift", "LinkPolicy.swift", "MarkdownRenderer.swift", "TextViewerDocument.swift",
                               "TextViewerRouting.swift", "TextViewerTextView.swift", "TextViewerWindow.swift"])
        // #1118: no URL-based loader either (Data(contentsOf:), CGImageSourceCreateWithURL, NSImage(contentsOf:)):
        // every byte is read through the guarded open in TextViewerDocument and ImagePolicy.
        let banned = ["URLSession", "WKWebView", "WebView", "WebKit", "JavaScriptCore", "NSAttributedString(html",
                      "Process(", "posix_spawn", "NSTask", "system(", "popen", "NSPasteboard.general",
                      "os_log", "Logger(", "NSLog", "print(", "URLRequest", "Data(contentsOf", "NSImage(contentsOf",
                      "String(contentsOf", "contentsOfFile", "CreateWithURL", "documentType", "NSAppleScript", "dlopen"]
        for name in names {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for word in banned { XCTAssertFalse(text.contains(word), "\(name) uses \(word)") }
        }
    }
}
