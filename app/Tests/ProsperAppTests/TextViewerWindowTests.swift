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
    /// passing through quickLook(with:). Reads recognizers only: no event, no preview, nothing shown.
    /// R886-8, what it proves where: on every system, the stock view's one immediate-action recognizer
    /// is refused and every other stock recognizer kept, in and out of a window. On macOS 27 and later
    /// (keptRecognizers was read on 27.2) also: no stock class is off the list, and a novel class is
    /// refused (fail closed). On macOS 14 to 26 the list was never read, so it is not compared there,
    /// and a novel class is kept (that system's rule). A system whose stock view adds no
    /// immediate-action recognizer is skipped: the guard has nothing to refuse there.
    func testForceClickHasNoImmediateAction() throws {
        func names(_ v: NSView) -> [String] { v.gestureRecognizers.map { NSStringFromClass(type(of: $0)) }.sorted() }
        let immediate = "NSImmediateActionGestureRecognizer"
        let stock = names(NSTextView(usingTextLayoutManager: false))
        fact("stock TextKit 1 recognizers: \(stock)")
        let listRule: Bool
        if #available(macOS 27, *) { listRule = true } else { listRule = false }
        if !listRule, !stock.contains(immediate) {
            throw XCTSkip("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) adds no \(immediate): nothing to refuse")
        }
        XCTAssertEqual(stock.filter { $0 == immediate }.count, 1, "the recognizer this guards against: \(stock)")
        if listRule {
            // A subset, not equality: macOS 27.0 lacks NSDragGestureRecognizer and _NSTextSelectionMouseEmulationBlocker.
            let unknown = Set(stock).subtracting(TextViewerTextView.keptRecognizers.union([immediate]))
            XCTAssertTrue(unknown.isEmpty, "a stock recognizer was added or renamed: read what it does before keeping it: \(unknown.sorted())")
        }
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
        // macOS 27+, fail closed: a recognizer of a class not on the list is refused. 14 to 26: kept.
        let novel = Novel()
        view.addGestureRecognizer(novel)
        XCTAssertEqual(view.gestureRecognizers.contains(novel), !listRule, "list rule \(listRule)")
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

    /// R1162-1: a direction control in the file's own name is shown escaped in the title and the header.
    /// Literal table (scalar, expected escape), plus set equality with LinkPolicy's list.
    func testDirectionControlsInTheNameAreShownEscaped() {
        let table: [(UInt32, String)] = [
            (0x202A, "\\u{202A}"), (0x202B, "\\u{202B}"), (0x202C, "\\u{202C}"), (0x202D, "\\u{202D}"),
            (0x202E, "\\u{202E}"), (0x2066, "\\u{2066}"), (0x2067, "\\u{2067}"), (0x2068, "\\u{2068}"),
            (0x2069, "\\u{2069}"), (0x200E, "\\u{200E}"), (0x200F, "\\u{200F}"), (0x061C, "\\u{61C}")]
        XCTAssertEqual(Set(table.map(\.0)), LinkPolicy.bidiControls, "the table covers the whole list")
        let dir = tempDir("tv-bidi")
        for (scalar, shown) in table {
            let name = "a" + String(Unicode.Scalar(scalar) ?? "?") + "b.txt"
            let url = dir.appendingPathComponent(name)
            let model = TextViewerModel(url: url, resolved: url, actions: fakeActions())
            XCTAssertEqual(model.shownName, "a" + shown + "b.txt", String(scalar, radix: 16))
            XCTAssertEqual(TextViewerWindows.makeWindow(model, autosave: nil).title, "a" + shown + "b.txt")
        }
        let plain = dir.appendingPathComponent("Notes.md")
        XCTAssertEqual(TextViewerModel(url: plain, resolved: plain, actions: fakeActions()).shownName, "Notes.md")
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
        let n = entry.model.loads
        XCTAssertTrue(w.changed(entry.model), "a watcher fire while open reloads")
        waitUntil("that reload landed", { entry.model.loads > n })
        entry.window.close()
        XCTAssertTrue(w.entries.isEmpty)
        // onFirstLoad is cleared by the first load already: testCloseBeforeTheFirstLoadStartsNoWatcher pins close's part.
        XCTAssertTrue(entry.watcher == nil && entry.observer == nil)
        XCTAssertTrue(watcher == nil, "the watcher is released, not only stopped")
        XCTAssertEqual(fakes.dismissed, 1)
        // A fire already queued to main when the window closed: it reloads nothing.
        XCTAssertFalse(w.changed(entry.model), "a watcher fire after the close does nothing")
        entry.window.close()
        XCTAssertEqual(fakes.dismissed, 1, "the observer is gone: a second close is not torn down twice")
    }

    /// R886-2 (QA S3): closed before its first load lands. The load publishes on the main actor, so a
    /// close in the same main turn as the open comes first; the load lands later and starts no watcher.
    func testCloseBeforeTheFirstLoadStartsNoWatcher() throws {
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("early.txt")
        try write("e\n", url)
        let w = registry()
        w.open(url)
        let entry = try XCTUnwrap(w.entries.first)
        XCTAssertTrue(entry.model.state == nil && entry.model.onFirstLoad != nil, "before the first load: the hook is set")
        entry.window.close()
        XCTAssertTrue(w.entries.isEmpty)
        XCTAssertTrue(entry.model.onFirstLoad == nil, "close cleared the hook")
        loaded(entry.model)
        XCTAssertEqual(entry.model.document?.text, "e\n")
        XCTAssertTrue(entry.watcher == nil, "a load landing after the close starts no watcher")
    }

    /// What the off-main seams saw, lock-guarded; `gate` holds the one call a row picks, 10 s at most
    /// (a row that fails opens it in a defer, so no thread stays blocked).
    private final class Held: @unchecked Sendable {
        let lock = NSLock()
        let gate = DispatchSemaphore(value: 0)
        private var seenList: [String] = []
        @discardableResult func add(_ s: String) -> Int { lock.lock(); defer { lock.unlock() }; seenList.append(s); return seenList.count }
        var seen: [String] { lock.lock(); defer { lock.unlock() }; return seenList }
        func hold() { _ = gate.wait(timeout: .now() + 10) }
    }

    /// A read seam: the n-th read returns the n-th text (the last after that); `holdFirst` holds the
    /// first read on the gate. @Sendable and nonisolated: the model calls it off the main thread.
    nonisolated private static func reads(_ texts: [String], into rec: Held, holdFirst: Bool = false)
        -> @Sendable (URL) -> Result<TextViewerDocument, TextViewerDocument.Refusal> {
        { _ in
            let n = rec.add("read")
            if holdFirst, n == 1 { rec.hold() }
            return TextViewerDocument.decode(Data((texts.dropFirst(n - 1).first ?? texts.last ?? "").utf8))
        }
    }

    /// Waits (5 s ceiling) until `job` has ended; the waiting Task is cancelled after.
    private func ended(_ job: Task<Void, Never>, file: StaticString = #filePath, line: UInt = #line) {
        let done = Held()
        let waiter = Task.detached { await job.value; done.add("ended") }   // nonisolated
        waitUntil("the held load ended", { done.seen == ["ended"] }, file: file, line: line)
        waiter.cancel()
    }

    private static let oldText = "# old\n\n![o](old.png)\n", newText = "# new\n\n![n](new.png)\n"

    /// R886-2 (QA S1, S2): two loads where the older ends last. The first is held in its render (the
    /// image loader, past its cancellation check); a reload reads and applies the new text; then the
    /// held render is let go and that load ends: the new text stays and one load was applied.
    func testStaleLoadEndingLastIsDropped() throws {
        let url = tempDir("tv-win").appendingPathComponent("order.md")
        let images = Held()
        let model = TextViewerModel(url: url, resolved: url, actions: fakeActions(),
                                    imageLoader: { src, _, _ in   // off the main thread, in the render
                                        images.add(src.lastPathComponent)
                                        if src.lastPathComponent == "old.png" { images.hold() }
                                        return nil
                                    },
                                    read: Self.reads([Self.oldText, Self.newText], into: Held()))
        defer { images.gate.signal() }
        waitUntil("the first load is in its render", { images.seen == ["old.png"] })
        let first = try XCTUnwrap(model.job)
        model.reload()
        waitUntil("the newer load applied", { model.loads == 1 })
        XCTAssertEqual(model.document?.text, Self.newText)
        images.gate.signal()
        ended(first)
        XCTAssertEqual(images.seen, ["old.png", "new.png"])
        XCTAssertEqual(model.loads, 1, "the older load was not applied")
        XCTAssertEqual(model.document?.text, Self.newText, "the older load ending last does not win")
    }

    /// R886-2 (the cancellation): a load superseded while it reads skips its render. The first read is
    /// held; a reload reads, renders and applies the new text; then the held read returns and that load
    /// ends without rendering (the image loader never sees its image).
    func testLoadSupersededInItsReadSkipsTheRender() throws {
        let url = tempDir("tv-win").appendingPathComponent("cancel.md")
        let reads = Held(), images = Held()
        let model = TextViewerModel(url: url, resolved: url, actions: fakeActions(),
                                    imageLoader: { src, _, _ in images.add(src.lastPathComponent); return nil },   // off main
                                    read: Self.reads([Self.oldText, Self.newText], into: reads, holdFirst: true))
        defer { reads.gate.signal() }
        waitUntil("the first load is in its read", { reads.seen.count == 1 })
        let first = try XCTUnwrap(model.job)
        model.reload()
        waitUntil("the newer load applied", { model.loads == 1 })
        reads.gate.signal()
        ended(first)
        XCTAssertEqual(images.seen, ["new.png"], "the superseded load did not render")
        XCTAssertEqual(model.loads, 1)
        XCTAssertEqual(model.document?.text, Self.newText)
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

    /// #1107 D15, the entry's done-condition through the window's own chain: the header's action puts ONE
    /// PNG of the whole document (taller than the window) on the test pasteboard, as wide as the live
    /// column plus margins and as tall as the live view's laid-out text plus margins; the notice says
    /// its size; the live view's scroll and selection are the same after. Unwindowed, so backing 1.
    /// Bytes: the settle snapshot 820 x 400 x 4 = 1,312,000; the image 792 x about 1,950 x 4 = about 6.2 MB.
    func testScreenshotCopiesTheWholeDocumentAndLeavesTheViewAlone() throws {
        _ = ThemeStore.shared
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        ThemeRuntime.opacity = 1
        ThemeRuntime.frost = false
        ThemeRuntime.scale = 1
        let url = tempDir("tv-shot").appendingPathComponent("shot.txt")
        try write((1...120).map { "Line \($0) of the screenshot sample" }.joined(separator: "\n") + "\n", url)
        let model = TextViewerModel(url: url, resolved: url, actions: fakeActions())
        loaded(model)
        let view = NSHostingView(rootView: TextViewerRootView(model: model))
        view.frame = CGRect(x: 0, y: 0, width: 820, height: 400)
        _ = try snapshot(view, backing: 1)
        let tv = try XCTUnwrap(model.textView)
        tv.setSelectedRange(NSRange(location: 40, length: 12))
        let clip = try XCTUnwrap(tv.enclosingScrollView?.contentView)
        clip.scroll(to: NSPoint(x: 0, y: 600))
        tv.enclosingScrollView?.reflectScrolledClipView(clip)
        let visible = tv.visibleRect, selection = tv.selectedRanges
        XCTAssertGreaterThan(visible.minY, 0, "scrolled down before the screenshot")
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString("before", forType: .string)
        model.screenshot()
        XCTAssertEqual(tv.visibleRect, visible, "the live view is not scrolled")
        XCTAssertEqual(tv.selectedRanges, selection, "nor its selection changed")
        XCTAssertEqual(pb.pasteboardItems?.count, 1)
        XCTAssertEqual(pb.pasteboardItems?.first?.types, [.png], "PNG data only (pb.types adds the server's translations)")
        let rep = try XCTUnwrap(pb.data(forType: .png).flatMap(NSBitmapImageRep.init(data:)))
        let lm = try XCTUnwrap(tv.layoutManager), tc = try XCTUnwrap(tv.textContainer)
        let height = lm.usedRect(for: tc).height
        XCTAssertGreaterThan(height, 400, "taller than the window")
        XCTAssertEqual(rep.pixelsWide, Int((tc.size.width + 2 * DocumentImage.margin).rounded(.up)))
        XCTAssertEqual(rep.pixelsHigh, Int((height + 2 * DocumentImage.margin).rounded(.up)))
        XCTAssertEqual(model.notice, DocumentImage.copiedNotice(width: rep.pixelsWide, height: rep.pixelsHigh))
    }

    /// #1107: with the Screenshot button the header fits the window's minimum width at UI scale 0.7, 0.85
    /// and 1.0: the size it takes when offered that width (the name truncates; where the titled menus do not
    /// fit they show icons) is within it. Ticket 1 measured the ideal width with titles: 327 pt at 0.7
    /// (minimum 294) and 359 at 0.85 (minimum 357). The button has a size of its own (fixedSize). Measured,
    /// never drawn on screen.
    func testHeaderFitsTheMinimumWidthAtEveryScale() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let url = tempDir("tv-head").appendingPathComponent("a.md")
        try write("# a\n", url)
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let model = TextViewerModel(url: url, resolved: url, actions: fakeActions())
            let minimum = TextViewerWindows.contentMinSize(scale: scale).width
            let header = NSHostingController(rootView: TextViewerHeader(model: model))
                .sizeThatFits(in: CGSize(width: minimum, height: 200)).width
            XCTAssertLessThanOrEqual(header, minimum, "scale \(scale): header \(header)")
            let button = NSHostingView(rootView: TextViewerScreenshotButton(model: model)).fittingSize
            XCTAssertGreaterThan(button.width, 0, "scale \(scale)")
            XCTAssertGreaterThan(button.height, 0, "scale \(scale)")
        }
    }

    /// The brief: Read is on the left; Edit is drawn, disabled, until P3, unless #1109's Terminal setting turns it on.
    func testReadIsLeftAndEditIsOff() {
        XCTAssertEqual(TextViewerModeSwitch.segments(canEdit: false),
                       [.init(title: "Read", enabled: true), .init(title: "Edit", enabled: false)])
        XCTAssertEqual(TextViewerModeSwitch.segments(canEdit: true),
                       [.init(title: "Read", enabled: true), .init(title: "Edit", enabled: true)])
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
        XCTAssertEqual(TextViewerNSWindow.route(try key("t", .command, code: 17)), R.toggleMode, "#1109: Read | Edit (passed on while Edit is off)")
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
        XCTAssertEqual(names, ["CapsuleSwitch.swift", "DocumentImage.swift", "ImagePolicy.swift", "LinkPolicy.swift", "MarkdownRenderer.swift", "TextFileWriter.swift",
                               "TextViewerDocument.swift", "TextViewerRouting.swift", "TextViewerTextView.swift", "TextViewerWindow.swift"])
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

    /// R1107-4 (b), R1107-2: a screenshot's notice timer clears only its own notice. Two screenshots; the first
    /// timer ends after the second notice is up and leaves it; the second timer clears it. The wait is the seam
    /// (returns at once): no 5 s and no fixed wait; the timers are awaited. The image goes to the private test
    /// pasteboard (Pasteboard.general under XCTest); the view is never in a window.
    func testScreenshotNoticeTimerClearsOnlyItsOwn() async throws {
        let url = tempDir("tv-notice").appendingPathComponent("a.txt")
        try write("one line\n", url)
        let model = TextViewerModel(url: url, resolved: url, actions: fakeActions())
        await model.job?.value
        let (_, view) = TextViewerTextView.makeScrollable()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.show(try XCTUnwrap(model.output?.text))
        model.textView = view
        model.noticeWait = {}
        model.screenshot()
        let first = try XCTUnwrap(model.noticeTimer)
        // The second timer is held until the first has ended (awaiting one lets every ready main-actor job run).
        let gate = NoticeGate()
        model.noticeWait = { await gate.wait() }
        model.screenshot()
        let second = try XCTUnwrap(model.noticeTimer)
        XCTAssertTrue(model.notice != nil, "the second screenshot's notice is up")
        await first.value
        XCTAssertTrue(model.notice != nil, "the first timer left the newer notice")
        gate.open()
        await second.value
        XCTAssertTrue(model.notice == nil, "the second timer cleared its own notice")
        withExtendedLifetime(view) {}
    }

    /// A wait the row ends itself (main actor): open() before or after wait() both let it return.
    @MainActor private final class NoticeGate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }
}

/// #1236: the cut through the model (a small cap passed in through its seam), its note on the accessibility tree and
/// across a reload. Offscreen: windows never shown; the private pasteboard; fakes in a tempDir().
extension TextViewerWindowTests {

    func testReloadKeepsTheCutAndTheNoteAndCopyTextCopiesWhatIsShown() throws {
        let url = tempDir("tv-cut").appendingPathComponent("long.txt")
        try write("ab\n" + String(repeating: "x", count: 20) + "\nafter\n", url)
        let model = TextViewerModel(url: url, resolved: url, actions: fakeActions(), maxParagraphUnits: 8)
        loaded(model)
        XCTAssertEqual(model.output?.text.string, "ab\nxxxxxxxx")
        XCTAssertEqual(model.output?.note, MarkdownRenderer.cutNote(8))
        model.copyText()
        XCTAssertEqual(Pasteboard.general.string(forType: .string), "ab\nxxxxxxxx", "Copy Text copies what is shown")
        let first = try XCTUnwrap(model.output?.text)
        var n = model.loads
        model.reload()
        waitUntil("the same bytes reloaded", { model.loads > n })
        XCTAssertTrue(model.output?.text === first, "the same bytes keep the shown text")
        XCTAssertEqual(model.output?.note, MarkdownRenderer.cutNote(8))
        try write("cd\n" + String(repeating: "y", count: 30) + "\n", url)
        n = model.loads
        model.reload()
        waitUntil("the new bytes reloaded", { model.loads > n })
        XCTAssertEqual(model.output?.text.string, "cd\nyyyyyyyy", "a reload cuts again")
        XCTAssertEqual(model.output?.note, MarkdownRenderer.cutNote(8), "and keeps the note")
        try write("cd\nyyyyyyyy\n", url)
        n = model.loads
        model.reload()
        waitUntil("the short bytes reloaded", { model.loads > n })
        XCTAssertEqual(model.output?.text.string, "cd\nyyyyyyyy\n", "at the cap: whole")
        XCTAssertTrue(model.output?.note == nil, "and no note")
    }

    private struct AXItem { let text: String; let frame: CGRect }

    /// The root view in a never-shown window, its AX tree walked (built once this process asks, as the AX client
    /// rows of AgentIslandCountSymbolsTests do; the flags are put back) until `done` holds, to a 5 s ceiling.
    private func axTree(_ model: TextViewerModel, _ size: CGSize, until done: ([AXItem]) -> Bool) -> [AXItem] {
        let (win, host) = AXTreeSupport.hosted(TextViewerRootView(model: model), size)
        defer { win.close() }
        let restore = AXTreeSupport.axOn()   // after hosting, as before; puts the flags back as found
        defer { restore() }
        // A label, else the value (the rows' reads); the poll loop is the shared one: layout, one 0.05 s pump, walk, 5 s ceiling.
        func items(_ t: [AXTreeNode]) -> [AXItem] { t.map { AXItem(text: $0.label.isEmpty ? $0.value : $0.label, frame: $0.frame) } }
        let tree = items(AXTreeSupport.poll(host) { done(items($0)) })
        XCTAssertFalse(win.isVisible, "never shown")
        return tree
    }

    /// The note is read on the accessibility tree at UI scale 0.7, 0.85 and 1.0, and every element above it (the header)
    /// keeps its frame when it appears: the note is a row of its own below the header and its rule, never in it.
    func testCutNoteOnTheAccessibilityTreeAtEveryScale() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let dir = tempDir("tv-cut")
        let long = dir.appendingPathComponent("long/notes.txt"), short = dir.appendingPathComponent("short/notes.txt")
        for u in [long, short] { try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try write("ab\n" + String(repeating: "x", count: 20) + "\nafter\n", long)
        try write("ab\n" + String(repeating: "x", count: 8) + "\nafter\n", short)
        let note = MarkdownRenderer.cutNote(8)
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let size = CGSize(width: 820 * scale, height: 640 * scale)
            func tree(_ url: URL, _ done: @escaping ([AXItem]) -> Bool) -> [AXItem] {
                let model = TextViewerModel(url: url, resolved: url, actions: fakeActions(), maxParagraphUnits: 8)
                loaded(model)
                return axTree(model, size, until: done)
            }
            let with = tree(long) { t in t.contains { $0.text == note } && t.contains { $0.text == "notes.txt" } }
            let without = tree(short) { t in t.contains { $0.text == "notes.txt" } }
            let tag = "scale \(scale)"
            let banner = try XCTUnwrap(with.first { $0.text == note }, "\(tag): \(with.map(\.text))")
            XCTAssertFalse(without.contains { $0.text == note }, tag)
            // AX frames are in screen points, y up: the header is the part above the note.
            let header = with.filter { $0.frame.height > 0 && $0.frame.minY >= banner.frame.maxY && $0.text != note }
            XCTAssertTrue(header.contains { $0.text == "notes.txt" }, "\(tag): \(header.map(\.text))")
            for item in header {
                XCTAssertTrue(without.contains { $0.text == item.text && $0.frame == item.frame },
                              "\(tag): \(item.text) at \(item.frame) moved when the note appeared")
            }
            fputs("tv1236 fact \(tag): note frame \(banner.frame), \(header.count) header elements unmoved\n", stderr)
        }
    }
}

/// R1108-r5-a: a reload of the same bytes from a new inode keeps the shown text (and so the selection and scroll) and the model
/// takes the new identity; other bytes replace the text as before. Offscreen: no window; the row's own files in a tempDir().
extension TextViewerWindowTests {

    private func fileIdentity(_ url: URL) -> TextViewerDocument.Identity? {
        var s = stat()
        guard lstat(url.path, &s) == 0 else { return nil }
        return TextViewerDocument.Identity(path: url.path, device: s.st_dev, inode: s.st_ino)
    }

    func testTheSameBytesFromANewInodeKeepTheShownTextAndTakeTheNewIdentity() throws {
        let dir = tempDir("tv-r5a")
        let url = dir.appendingPathComponent("a.txt")
        try write("same\n", url)
        let model = TextViewerModel(url: url, resolved: url, actions: fakeActions())
        loaded(model)
        XCTAssertEqual(model.output?.text.string, "same\n")
        let before = try XCTUnwrap(fileIdentity(url))
        XCTAssertEqual(model.identity, before)
        let first = try XCTUnwrap(model.output?.text)
        // Another program's atomic save: the row renames its own sibling over the file.
        func replace(_ text: String) throws {
            let side = dir.appendingPathComponent("side.txt")
            try write(text, side)
            XCTAssertEqual(rename(side.path, url.path), 0)
        }
        try replace("same\n")
        let after = try XCTUnwrap(fileIdentity(url))
        XCTAssertNotEqual(after.inode, before.inode, "a new inode")
        var n = model.loads
        model.reload()
        waitUntil("the same bytes reloaded", { model.loads > n })
        XCTAssertTrue(model.output?.text === first, "the same bytes from a new inode keep the shown text")
        XCTAssertEqual(model.identity, after, "the model holds the new inode's identity")
        try replace("other\n")
        let other = try XCTUnwrap(fileIdentity(url))
        n = model.loads
        model.reload()
        waitUntil("the other bytes reloaded", { model.loads > n })
        XCTAssertFalse(model.output?.text === first, "other bytes replace the shown text")
        XCTAssertEqual(model.output?.text.string, "other\n")
        XCTAssertEqual(model.document?.text, "other\n")
        XCTAssertEqual(model.identity, other)
    }

    /// The row reads through its own link (resolved: the link, so the retarget reaches the load) and retargets it at its other
    /// file with the same bytes: the shown text kept, the identity the new target's.
    func testALinkRetargetedAtTheSameBytesKeepsTheShownTextAndTakesTheNewTarget() throws {
        let dir = tempDir("tv-r5a-link")
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt")
        try write("same\n", a)
        try write("same\n", b)
        let link = dir.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink("a.txt", link.path), 0)
        let model = TextViewerModel(url: link, resolved: link, actions: fakeActions())
        loaded(model)
        XCTAssertEqual(model.identity, fileIdentity(a))
        let first = try XCTUnwrap(model.output?.text)
        XCTAssertEqual(unlink(link.path), 0)
        XCTAssertEqual(symlink("b.txt", link.path), 0)
        let n = model.loads
        model.reload()
        waitUntil("reloaded through the retargeted link", { model.loads > n })
        XCTAssertTrue(model.output?.text === first, "the same bytes keep the shown text")
        XCTAssertEqual(model.identity?.path, b.path, "the identity's path is the new target's")
        XCTAssertEqual(model.identity, fileIdentity(b))
    }
}
