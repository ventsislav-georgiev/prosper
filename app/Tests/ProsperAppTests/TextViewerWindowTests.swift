import AppKit
import Darwin
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
    }

    private var fakes = Fakes()

    private func registry() -> TextViewerWindows {
        let w = TextViewerWindows()
        w.build = { TextViewerWindows.makeWindow($0, autosave: nil) }
        w.present = { [unowned self] in self.fakes.presented.append($0) }
        w.dismissed = { [unowned self] _ in self.fakes.dismissed += 1 }
        w.actions = { [unowned self] in self.fakeActions() }
        return w
    }

    private func fakeActions() -> TextViewerActions {
        TextViewerActions(defaultApp: { _ in URL(fileURLWithPath: "/Applications/Example.app") },
                          openWith: { [unowned self] in self.fakes.opened.append(($0, $1)) },
                          reveal: { [unowned self] in self.fakes.revealed.append($0) })
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
        XCTAssertTrue(w.entries.allSatisfy { $0.watcher != nil }, "a shown file is watched")

        // A refused folder gets its window but no watcher (a FIFO would block the watcher open).
        let folder = dir.appendingPathComponent("folder.md", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        w.open(folder)
        XCTAssertEqual(w.entries.count, 3)
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
        XCTAssertEqual(model.document?.text, "one\n")
        try Data("two\n".utf8).write(to: url, options: .atomic)   // an editor's save: a rename over the file
        let deadline = Date().addingTimeInterval(5)
        while model.document?.text != "two\n", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(model.document?.text, "two\n")
    }

    /// Section 3 N7: opening writes nothing. The folder's entries (readdir, so AppleDouble names
    /// count too), sizes and mtimes, and the folder's own mtime, are the same after an open, a reload
    /// and a close.
    func testOpenWritesNothing() throws {
        let dir = tempDir("tv-win")
        let url = dir.appendingPathComponent("quiet.md")
        try write("# quiet\n", url)
        let before = try listing(dir)
        let w = registry()
        w.open(url)
        let model = try XCTUnwrap(w.entries.first?.model)
        model.reload()
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
        view.show("alpha beta gamma", font: .monospacedSystemFont(ofSize: 13, weight: .regular), color: .textColor)
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

    /// R1: ⌘E puts the selection on the find pasteboard seam, a private one under XCTest. No search
    /// is driven.
    func testUseSelectionForFindUsesTheFindSeam() throws {
        let find = TextViewerFind.pasteboard
        XCTAssertTrue(find.name.rawValue.hasPrefix("eu.illegible.prosper.xctest.find"), "the private find pasteboard")
        let (_, view) = TextViewerTextView.makeScrollable()
        view.show("alpha beta gamma", font: .monospacedSystemFont(ofSize: 13, weight: .regular), color: .textColor)
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
        let pb = Pasteboard.general
        model.copyText()
        XCTAssertEqual(pb.string(forType: .string), "# menu\n")
        model.copyPath()
        XCTAssertEqual(pb.string(forType: .string), url.path)
        model.copySource()
        XCTAssertEqual(pb.string(forType: .string), "# menu\n")
        model.openInDefaultApp()
        model.reveal()
        XCTAssertEqual(fakes.opened.first?.0, url)
        XCTAssertEqual(fakes.opened.first?.1.lastPathComponent, "Example.app")
        XCTAssertEqual(fakes.revealed, [url])
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
        XCTAssertEqual(names, ["TextViewerDocument.swift", "TextViewerRouting.swift",
                               "TextViewerTextView.swift", "TextViewerWindow.swift"])
        let banned = ["URLSession", "WKWebView", "WebView", "WebKit", "JavaScriptCore", "NSAttributedString(html",
                      "Process(", "posix_spawn", "NSTask", "system(", "popen", "NSPasteboard.general",
                      "os_log", "Logger(", "NSLog", "print("]
        for name in names {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for word in banned { XCTAssertFalse(text.contains(word), "\(name) uses \(word)") }
        }
    }
}
