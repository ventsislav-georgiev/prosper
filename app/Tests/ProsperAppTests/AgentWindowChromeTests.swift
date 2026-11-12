import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #860: the Agent Sessions window wears Settings' chrome and theme surfaces, at the live
/// opacity and frost. Offscreen only: views render through NSHostingViews never put in a
/// window, the real window is built but never shown, ordered or made key, and no event is posted.
extension AgentWindowD1Tests {

    /// Renders `view` over a solid `canvas` (a known backdrop, so a faded surface shows as a
    /// blend with it) through an NSHostingView that is never put in a window.
    @MainActor
    func renderOver<V: View>(_ view: V, size: CGSize, canvas: NSColor, dark: Bool, backing: CGFloat) throws -> NSBitmapImageRep {
        let root = ZStack(alignment: .topLeading) {
            Color(nsColor: canvas)
            view.frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, dark ? .dark : .light)
        let h = NSHostingView(rootView: root)
        h.frame = CGRect(origin: .zero, size: size)
        return try snapshot(h, backing: backing)
    }

    /// The view drawn into a bitmap at an explicit backing scale (r6: 1 is CI's runner, 2 is Retina),
    /// so one local run proves both. Not bitmapImageRepForCachingDisplay: that follows the main
    /// screen's scale, which is the only thing it would add.
    @MainActor
    func snapshot(_ v: NSView, backing: CGFloat) throws -> NSBitmapImageRep {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((v.bounds.width * backing).rounded()),
            pixelsHigh: Int((v.bounds.height * backing).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    /// `n` backing pixels of `rep` as an area in pt² (the same number at backing 1 and 2).
    func pt2(_ n: Int, _ rep: NSBitmapImageRep, _ size: CGSize) -> CGFloat {
        CGFloat(n) * size.width * size.height / CGFloat(rep.pixelsWide * rep.pixelsHigh)
    }

    /// The sRGB pixel at a point given in view points (top-left origin).
    func pixel(_ rep: NSBitmapImageRep, _ p: CGPoint, in size: CGSize) -> NSColor? {
        let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
        return rep.colorAt(x: Int(p.x * sx), y: Int(p.y * sy))?.usingColorSpace(.sRGB)
    }

    func rgba(_ c: NSColor?) -> String {
        guard let c else { return "nil" }
        return String(format: "%.3f %.3f %.3f a%.3f", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    func saveTo860(_ rep: NSBitmapImageRep, _ name: String) throws {
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: tempDir("agents-window-860").appendingPathComponent("\(name).png"))
        if let dir = Self.renderDir { try png.write(to: dir.appendingPathComponent("\(name).png")) }
    }

    /// Evidence for the review (before and after the change; PROSPER_860_PHASE names the run):
    /// the window at a dark and a light theme, UI scale 1.0 and 0.7, opacity 1.0 and 0.8, frost
    /// off and on, over a mid-grey canvas. Logs the body's backdrop pixels next to Settings'
    /// SettingsBackground at the same setting. Asserts nothing about the look itself.
    @MainActor
    func testChrome860EvidenceRenders() throws {
        guard Self.renderDir != nil else { throw XCTSkip("#860 evidence renders: set the render dir to write them") }
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        let phase = ProcessInfo.processInfo.environment["PROSPER_860_PHASE"] ?? "run"
        let convo = Self.corpus.appendingPathComponent("2.1.318/b-compaction-agents-more-tools.jsonl")
        let (m, _) = demoModel(convo)
        defer { m.close() }
        let s = try XCTUnwrap(m.selectedRow?.session)
        let canvas = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        var log: [String] = []
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved.1 : Self.lightPalette
            for scale: CGFloat in [1.0, 0.7] {
                ThemeRuntime.scale = scale
                for (opacity, frost) in [(1.0, false), (0.8, false), (1.0, true), (0.8, true)] as [(CGFloat, Bool)] {
                    ThemeRuntime.opacity = opacity
                    ThemeRuntime.frost = frost
                    for mode in [AgentPaneMode.terminal, .transcript] {
                        m.setMode(mode, for: s)
                        let tag = "\(phase)-\(mode == .terminal ? "term" : "tx")-\(dark ? "dark" : "light")-s\(scale)-o\(opacity)\(frost ? "-frost" : "")"
                        let size = CGSize(width: 1000 * scale, height: 680 * scale)
                        let rep = try renderOver(AgentWindowRootView(model: m, scrolls: false), size: size, canvas: canvas, dark: dark, backing: 2)
                        try saveTo860(rep, "window-\(tag)")
                        guard mode == .transcript else { continue }
                        // Padding spots of the detail column (the header's top-left, the input pane's
                        // bottom-left, the transcript's right edge) and the rail's empty bottom slot,
                        // next to Settings' SettingsBackground at the same spots.
                        let side = 290 * scale + 1
                        let detail = CGSize(width: size.width - side, height: size.height)
                        let settings = try renderOver(SettingsBackground(), size: detail, canvas: canvas, dark: dark, backing: 2)
                        var line = tag
                        for (name, p) in [("header", CGPoint(x: 4 * scale, y: 4 * scale)),
                                          ("input", CGPoint(x: 4 * scale, y: size.height - 3 * scale)),
                                          ("transcript", CGPoint(x: detail.width - 4 * scale, y: size.height * 0.5))] {
                            line += " \(name)=\(rgba(pixel(rep, CGPoint(x: side + p.x, y: p.y), in: size)))"
                                + " settings=\(rgba(pixel(settings, p, in: detail)))"
                        }
                        line += " rail=\(rgba(pixel(rep, CGPoint(x: 4 * scale, y: size.height - 3 * scale), in: size)))"
                        log.append(line)
                    }
                }
            }
        }
        m.setMode(.terminal, for: s)
        if let dir = Self.renderDir {
            try log.joined(separator: "\n").write(to: dir.appendingPathComponent("pixels-\(phase).txt"), atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - #860 checks (after the change)

/// SettingsSidebar's rail surface, row bar, row fill and NeonSection's title label exactly as
/// they were inline at 92065c5, so the lifted shared pieces can be compared pixel for pixel.
private struct Legacy860SidebarSurface: View {
    var body: some View {
        ZStack {
            if ThemeRuntime.frost { VisualEffectBackground() }
            ZStack {
                Neon.sidebar
                LinearGradient(colors: [Neon.blue.opacity(0.06), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
            .opacity(ThemeRuntime.backdropFillOpacity)
        }
    }
}

private struct Legacy860Row: View {
    let selected: Bool
    var body: some View {
        HStack(spacing: sz(11)) {
            RoundedRectangle(cornerRadius: sz(2))
                .fill(Neon.blue)
                .frame(width: sz(3), height: sz(18))
                .shadow(color: Neon.blue.opacity(0.9), radius: sz(4))
                .opacity(selected ? 1 : 0)
            Image(systemName: "paintpalette.fill")
                .font(Neon.font(13, weight: .semibold))
                .frame(width: sz(20))
                .foregroundStyle(selected ? Neon.blueBright : Neon.textSecondary)
            neonAccentedText("QuickLinks", accent: "Links")
                .font(Neon.font(13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Neon.textPrimary : Neon.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, sz(8))
        .padding(.trailing, sz(8))
        .background(
            RoundedRectangle(cornerRadius: sz(9), style: .continuous)
                .fill(selected ? Neon.blue.opacity(0.14) : .clear)
                .overlay(
                    RoundedRectangle(cornerRadius: sz(9), style: .continuous)
                        .strokeBorder(Neon.blue.opacity(selected ? 0.45 : 0), lineWidth: 1)))
    }
}

private struct Shared860Row: View {
    let selected: Bool
    var body: some View {
        HStack(spacing: sz(11)) {
            NeonSelectionBar()
                .opacity(selected ? 1 : 0)
            Image(systemName: "paintpalette.fill")
                .font(Neon.font(13, weight: .semibold))
                .frame(width: sz(20))
                .foregroundStyle(selected ? Neon.blueBright : Neon.textSecondary)
            neonAccentedText("QuickLinks", accent: "Links")
                .font(Neon.font(13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Neon.textPrimary : Neon.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, sz(8))
        .padding(.trailing, sz(8))
        .background(NeonSelectedRowFill(selected: selected))
    }
}

private struct Legacy860Label: View {
    var body: some View {
        HStack(spacing: sz(8)) {
            RoundedRectangle(cornerRadius: sz(1))
                .fill(Neon.blue)
                .frame(width: sz(3), height: sz(12))
                .shadow(color: Neon.blue.opacity(0.9), radius: sz(4))
            neonAccentedText("Menu Bar Icon", accent: "Icon")
                .font(Neon.font(11, weight: .bold))
                .textCase(.uppercase)
                .tracking(sz(1.4))
                .foregroundStyle(Neon.textSecondary)
        }
    }
}

/// The Agent sidebar's section header as it was at 92065c5 (its height is the fixed slot).
private struct Legacy860AgentHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: sz(5)) {
            if title == AgentSidebar.needsYouTitle {
                Circle().fill(AgentState.blocked.color).frame(width: sz(5), height: sz(5))
            } else {
                Image(systemName: "chevron.right").font(Neon.font(8, weight: .bold)).frame(width: sz(9), height: sz(9))
            }
            Text(title.uppercased()).font(Neon.font(9.5, weight: .bold)).tracking(0.8)
            Text("12").font(Neon.font(9.5, weight: .medium).monospacedDigit())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, sz(8)).padding(.top, sz(12)).padding(.bottom, sz(4))
    }
}

extension AgentWindowD1Tests {

    func bytes(_ rep: NSBitmapImageRep) -> Data {
        Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    func assertClose(_ a: NSColor?, _ b: NSColor?, _ what: String, tolerance: CGFloat = 0.02,
                     file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTFail("no pixel: \(what)", file: file, line: line) }
        for (x, y, c) in [(a.redComponent, b.redComponent, "red"), (a.greenComponent, b.greenComponent, "green"),
                          (a.blueComponent, b.blueComponent, "blue"), (a.alphaComponent, b.alphaComponent, "alpha")] {
            XCTAssertEqual(x, y, accuracy: tolerance, "\(what) \(c)", file: file, line: line)
        }
    }

    /// Pixels of `rep` (inside `rect`, view points) whose sRGB value passes `test`.
    func band(_ rep: NSBitmapImageRep, _ test: (NSColor) -> Bool, in rect: CGRect, size: CGSize) -> Int {
        let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
        var n = 0
        for y in Int(rect.minY * sy)..<min(rep.pixelsHigh, Int(rect.maxY * sy)) {
            for x in Int(rect.minX * sx)..<min(rep.pixelsWide, Int(rect.maxX * sx)) {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), test(c) { n += 1 }
            }
        }
        return n
    }

    /// Pixels of `rep` (inside `rect`, view points) within `tolerance` of `color` per channel.
    func count(_ rep: NSBitmapImageRep, near color: NSColor, in rect: CGRect, size: CGSize, tolerance: CGFloat = 0.06) -> Int {
        guard let want = color.usingColorSpace(.sRGB) else { return 0 }
        let sx = CGFloat(rep.pixelsWide) / size.width, sy = CGFloat(rep.pixelsHigh) / size.height
        var n = 0
        for y in Int(rect.minY * sy)..<min(rep.pixelsHigh, Int(rect.maxY * sy)) {
            for x in Int(rect.minX * sx)..<min(rep.pixelsWide, Int(rect.maxX * sx)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.95 else { continue }
                if abs(c.redComponent - want.redComponent) < tolerance, abs(c.greenComponent - want.greenComponent) < tolerance,
                   abs(c.blueComponent - want.blueComponent) < tolerance { n += 1 }
            }
        }
        return n
    }

    /// The lifted pieces draw Settings exactly as the inline code did (no behaviour change for
    /// Settings): the rail surface, a selected and an unselected row, the section label, at a
    /// dark and a light theme, UI scale 1.0 and 0.7, opacity 1.0 and 0.8. Byte-equal bitmaps.
    @MainActor
    func testChrome860SharedPiecesDrawSettingsExactlyAsBefore() throws {
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        ThemeRuntime.frost = false
        let canvas = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved.1 : Self.lightPalette
            for scale: CGFloat in [1.0, 0.7] {
                ThemeRuntime.scale = scale
                for (opacity, backing) in [(1.0, 1.0), (1.0, 2.0), (0.8, 1.0), (0.8, 2.0)] as [(CGFloat, CGFloat)] {
                    ThemeRuntime.opacity = opacity
                    let tag = "\(dark ? "dark" : "light")-s\(scale)-o\(opacity)-x\(Int(backing))"
                    let size = CGSize(width: 218 * scale, height: 160 * scale)
                    let before = VStack(alignment: .leading, spacing: sz(10)) {
                        Legacy860Label()
                        Legacy860Row(selected: true)
                        Legacy860Row(selected: false)
                    }.padding(sz(12)).frame(width: size.width, height: size.height, alignment: .topLeading)
                        .background(Legacy860SidebarSurface())
                    let after = VStack(alignment: .leading, spacing: sz(10)) {
                        NeonSectionLabel(title: "Menu Bar Icon", accent: "Icon")
                        Shared860Row(selected: true)
                        Shared860Row(selected: false)
                    }.padding(sz(12)).frame(width: size.width, height: size.height, alignment: .topLeading)
                        .background(NeonSidebarSurface())
                    let b = try renderOver(before, size: size, canvas: canvas, dark: dark, backing: backing)
                    let a = try renderOver(after, size: size, canvas: canvas, dark: dark, backing: backing)
                    try saveTo860(b, "settings-rail-before-\(tag)")
                    try saveTo860(a, "settings-rail-after-\(tag)")
                    XCTAssertEqual(bytes(b), bytes(a), "Settings rail pieces draw the same pixels (\(tag))")
                    // The bar (3x18 pt) and the tick (3x12 pt) are 44 pt² at UI scale 0.7; their accent cores > 10 pt².
                    let accent = pt2(count(a, near: NSColor(Neon.blue), in: CGRect(origin: .zero, size: size), size: size), a, size)
                    XCTAssertGreaterThan(accent, 10,
                                         "the accent bar and tick are there to compare (\(tag))")
                }
            }
        }
    }

    /// The window's chrome is Settings': the title hidden, the strip transparent and painted by the
    /// window background, no full-size content view (the content starts under the strip, as Settings'),
    /// and the theme hook re-applies opacity, frost and the scaled minimum to it exactly as to Settings.
    @MainActor
    func testChrome860WindowHidesTitleAndFollowsTheThemeHookLikeSettings() throws {
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        ThemeRuntime.scale = 1
        ThemeRuntime.opacity = 0.8
        ThemeRuntime.frost = false
        let m = windowModel(store([session("a", .idle)]))
        defer { m.close() }
        let win = AgentsWindow.makeWindow(m, autosave: nil)
        XCTAssertFalse(win.isVisible, "built, never shown")
        XCTAssertEqual(win.titleVisibility, .hidden, "the title is hidden, as Settings'")
        XCTAssertTrue(win.titlebarAppearsTransparent)
        XCTAssertFalse(win.styleMask.contains(.fullSizeContentView), "the strip is the window background, as Settings'")
        XCTAssertEqual(win.title, AgentsWindow.title, "the Window menu still names it")
        XCTAssertEqual(win.identifier, AgentsWindow.themedIdentifier)
        XCTAssertEqual(win.frameAutosaveName, "", "no autosave in a test")
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        settings.isReleasedWhenClosed = false
        settings.identifier = SettingsWindow.themedIdentifier
        settings.titleVisibility = .hidden
        settings.titlebarAppearsTransparent = true
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved.1 : Self.lightPalette
            for (opacity, frost, scale) in [(1.0, false, 1.0), (0.8, false, 0.7), (1.0, true, 1.0), (0.8, true, 0.85)]
                as [(CGFloat, Bool, CGFloat)] {
                ThemeRuntime.opacity = opacity
                ThemeRuntime.frost = frost
                let tag = "\(dark ? "dark" : "light") o\(opacity) frost \(frost) s\(scale)"
                AppDelegate.applyThemedWindowSizing([win, settings], scale: scale)
                XCTAssertEqual(win.isOpaque, settings.isOpaque, tag)
                XCTAssertEqual(win.isOpaque, !frost && opacity >= 0.999, tag)
                assertClose(win.backgroundColor.usingColorSpace(.sRGB), settings.backgroundColor.usingColorSpace(.sRGB),
                            "strip colour \(tag)", tolerance: 0.001)
                assertClose(win.backgroundColor.usingColorSpace(.sRGB),
                            NSColor(Neon.bgTop).withAlphaComponent(win.isOpaque ? 1 : ThemeRuntime.backdropFillOpacity)
                                .usingColorSpace(.sRGB), "strip is the backdrop's top colour \(tag)", tolerance: 0.001)
                XCTAssertEqual(win.contentMinSize, AgentsWindow.contentMinSize(scale: scale), tag)
                let content = win.contentRect(forFrameRect: win.frame).size
                XCTAssertGreaterThanOrEqual(content.width, win.contentMinSize.width, tag)
                XCTAssertGreaterThanOrEqual(content.height, win.contentMinSize.height, tag)
            }
        }
        XCTAssertFalse(win.isVisible, "never on screen")
        win.contentViewController = nil
    }

    /// The body wears Settings' surfaces at the live opacity and frost: the detail column's empty
    /// corner is SettingsBackground's pixel and the rail's empty slot is NeonSidebarSurface's, blended
    /// over the same known canvas, at a dark and a light theme, UI scale 1.0 and 0.7, opacity 1.0 and
    /// 0.8, frost off and on. Opacity 0.8 lets the canvas through (two canvases give two pixels);
    /// 1.0 without frost does not.
    @MainActor
    func testChrome860BodyIsSettingsBackdropAtTheLiveOpacity() throws {
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        let m = windowModel(store([session("prosper", .working), session("infra", .blocked), session("notes", .idle)]))
        m.setVisible(true)
        defer { m.close() }
        // `m` (sessions, no click) checks the rail; its detail shows the first row's terminal, which stays
        // opaque by design (report section 3).
        // A selected session in Transcript mode: its header band, input band and transcript sit on the
        // backdrop too (padding spots: the header's top-left, the input's bottom-left, the transcript's right edge).
        let (demo, _) = demoModel(Self.corpus.appendingPathComponent("2.1.318/b-compaction-agents-more-tools.jsonl"))
        defer { demo.close() }
        demo.setMode(.transcript, for: try XCTUnwrap(demo.selectedRow?.session))
        XCTAssertEqual(demo.paneMode, .transcript)
        let grey = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        // Warm-up: the process's first offscreen gradient snapshot can come back part-drawn (seen at opacity
        // 1.0: Settings' own backdrop let ~12% of the canvas through, the window matching it exactly).
        for canvas in [grey, magenta] {
            for backing: CGFloat in [1, 2] {
                _ = try renderOver(SettingsBackground(), size: CGSize(width: 200, height: 200), canvas: canvas, dark: true, backing: backing)
                _ = try renderOver(AgentWindowRootView(model: demo, scrolls: false), size: CGSize(width: 1000, height: 680),
                                   canvas: canvas, dark: true, backing: backing)
            }
        }
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved.1 : Self.lightPalette
            for scale: CGFloat in [1.0, 0.7] {
                ThemeRuntime.scale = scale
                for (opacity, frost) in [(1.0, false), (0.8, false), (1.0, true), (0.8, true)] as [(CGFloat, Bool)] {
                    for backing: CGFloat in [1, 2] {
                        ThemeRuntime.opacity = opacity
                        ThemeRuntime.frost = frost
                        let tag = "\(dark ? "dark" : "light")-s\(scale)-o\(opacity)\(frost ? "-frost" : "")-x\(Int(backing))"
                        let size = CGSize(width: 1000 * scale, height: 680 * scale)
                        let side = sz(290) + 1
                        let detail = CGSize(width: size.width - side, height: size.height)
                        let rail = CGSize(width: sz(290), height: size.height)
                        let corner = CGPoint(x: 4 * scale, y: size.height - 4 * scale)
                        var seen: [NSColor?] = [], seenS: [NSColor?] = []
                        for canvas in [grey, magenta] {
                            let rep = try renderOver(AgentWindowRootView(model: m, scrolls: false), size: size, canvas: canvas, dark: dark, backing: backing)
                            if canvas == grey { try saveTo860(rep, "after-rail-\(tag)") }
                            let s = try renderOver(SettingsBackground(), size: detail, canvas: canvas, dark: dark, backing: backing)
                            let r = try renderOver(NeonSidebarSurface(), size: rail, canvas: canvas, dark: dark, backing: backing)
                            assertClose(pixel(rep, corner, in: size), pixel(r, corner, in: rail), "rail = NeonSidebarSurface \(tag)")
                            let tx = try renderOver(AgentWindowRootView(model: demo, scrolls: false), size: size, canvas: canvas, dark: dark, backing: backing)
                            if canvas == grey { try saveTo860(tx, "after-transcript-\(tag)") }
                            for (name, p) in [("header", CGPoint(x: 4 * scale, y: 4 * scale)), ("input", corner),
                                              ("transcript", CGPoint(x: detail.width - 4 * scale, y: size.height * 0.5))] {
                                assertClose(pixel(tx, CGPoint(x: side + p.x, y: p.y), in: size), pixel(s, p, in: detail),
                                            "\(name) on SettingsBackground \(tag)")
                            }
                            seen.append(pixel(tx, CGPoint(x: side + 4 * scale, y: 4 * scale), in: size))
                            seenS.append(pixel(s, CGPoint(x: 4 * scale, y: 4 * scale), in: detail))
                        }
                        // Frost's blur is AppKit's to draw offscreen; only the plain fade is pinned here.
                        guard !frost, let a = seen[0], let b = seen[1] else { continue }
                        let through = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                        if opacity < 1 {
                            XCTAssertGreaterThan(through, 0.1, "opacity \(opacity): the backdrop behind shows through (\(tag))")
                        } else {
                            XCTAssertLessThan(through, 0.01, "opacity 1.0: opaque (\(tag)) window \(rgba(a)) / \(rgba(b)), "
                                              + "Settings \(rgba(seenS[0])) / \(rgba(seenS[1]))")
                        }
                    }
                }
            }
        }
    }

    /// The live window (Themed root, built by makeWindow, never shown): the selected row wears the
    /// accent (bar, fill, edge) and the section headers the accent tick; a theme select repaints the
    /// open window with the new accent and appearance, and an opacity change fades its body in place.
    @MainActor
    func testChrome860SelectedRowAccentAndLiveRetheme() throws {
        let saved = (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost)
        func reset() {
            ThemeStore.shared.setOpacity(1.0)
            ThemeStore.shared.setFrost(false)
            Preferences.defaults.removeObject(forKey: "prosper.activeThemeID")
            ThemeStore.shared.setAvailable([])
        }
        reset()
        defer { reset(); (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        ThemeRuntime.scale = 1
        let m = windowModel(store([session("prosper", .working), session("infra", .blocked), session("notes", .idle)]))
        m.setVisible(true)
        defer { m.close() }
        let win = AgentsWindow.makeWindow(m, autosave: nil)
        defer { win.contentViewController = nil }
        let view = try XCTUnwrap(win.contentView)
        let size = view.bounds.size
        let rail = CGRect(x: 0, y: 0, width: sz(290), height: size.height)

        // Hue bands, not exact colours: the window's bitmap colour space shifts saturated sRGB a little.
        // (the default accent renders at about 0.38 0.79 0.98)
        let cyan: (NSColor) -> Bool = { $0.blueComponent > 0.85 && $0.greenComponent > 0.65 && $0.redComponent < 0.5 }
        let pink: (NSColor) -> Bool = { $0.redComponent > 0.75 && $0.blueComponent > 0.75 && $0.greenComponent < 0.35 }
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "prosper")))
        // r6: every snapshot at backing 1 (CI) and 2 (Retina); counts compared as areas in pt².
        let backings: [CGFloat] = [1, 2]
        // The rail's leading strip holds only the selection bar (3x18 pt); the next strip the SESSIONS tick.
        let barStrip = CGRect(x: 0, y: 0, width: sz(14), height: size.height)
        let tickStrip = CGRect(x: sz(14), y: 0, width: sz(26), height: size.height)
        for backing in backings {
            let first = try snapshot(view, backing: backing)
            try saveTo860(first, "live-default-selected-x\(Int(backing))")
            let bar = pt2(band(first, cyan, in: barStrip, size: size), first, size)
            let tick = pt2(band(first, cyan, in: tickStrip, size: size), first, size)
            XCTAssertGreaterThan(bar, 25, "the selected row's bar wears the accent (x\(Int(backing)))")
            XCTAssertGreaterThan(tick, 10, "the section header tick wears the accent (x\(Int(backing)))")
        }

        // A theme select (accent #FF00FF, light) reaches the open window: the new accent shows, the old one is gone.
        let dir = tempDir("theme860")
        let json = dir.appendingPathComponent("theme.json")
        try Data(##"{ "appearance": "light", "colors": { "blue": "#FF00FF", "bgTop": "#F4F4F8", "bgBottom": "#E8E8EE", "sidebar": "#EEEEF4" } }"##.utf8)
            .write(to: json)
        let d = ThemeDescriptor(id: "t.860", title: "Probe 860", appearance: .light, extensionID: "e860", jsonPath: json)
        // Each lifted piece alone, under a root that never re-renders: it must observe the store itself
        // (#089), or inside Settings' select-without-teardown root it would keep the old palette.
        let pieces: [(String, NSHostingView<AnyView>)] = [
            ("bar", NSHostingView(rootView: AnyView(NeonSelectionBar().padding(8)))),
            ("fill", NSHostingView(rootView: AnyView(NeonSelectedRowFill(selected: true).frame(width: 60, height: 30)))),
            ("label", NSHostingView(rootView: AnyView(NeonSectionLabel(title: "Sessions").padding(8)))),
            ("surface", NSHostingView(rootView: AnyView(NeonSidebarSurface().frame(width: 60, height: 60)))),
        ]
        var before: [String: Data] = [:]
        for (name, h) in pieces {
            h.frame = CGRect(origin: .zero, size: h.fittingSize)
            for backing in backings { before["\(name)-\(backing)"] = bytes(try snapshot(h, backing: backing)) }
        }
        ThemeStore.shared.setAvailable([d])
        ThemeStore.shared.select(id: d.id)
        XCTAssertEqual(ThemeStore.shared.activeID, d.id)
        for (name, h) in pieces {
            for backing in backings {
                XCTAssertNotEqual(bytes(try snapshot(h, backing: backing)), before["\(name)-\(backing)"],
                                  "\(name) repaints on a theme select by itself (x\(Int(backing)))")
            }
        }
        var opaque: [CGFloat: NSColor] = [:]
        // The title row is 30 pt of top padding, a 13 pt line and 8 pt below it: rows and headers start under 54 pt.
        let belowTitle = CGRect(x: 0, y: sz(54), width: sz(290), height: size.height - sz(54))
        for backing in backings {
            let second = try snapshot(view, backing: backing)
            try saveTo860(second, "live-probe-selected-x\(Int(backing))")
            let newAccent = pt2(band(second, pink, in: rail, size: size), second, size)
            // Below the rail's title row: its "Sessions" word is Neon.blueBright (neonAccentedText), which
            // this probe theme leaves at the default cyan; it is not the accent (r6: 57 pt² of it at x1).
            let oldAccent = pt2(band(second, cyan, in: belowTitle, size: size), second, size)
            XCTAssertGreaterThan(newAccent, 40, "the new accent repaints the open window (x\(Int(backing)))")
            XCTAssertLessThan(oldAccent, 1.25, "no pixel of the old accent is left (x\(Int(backing)))")
            let sidebarPixel = try XCTUnwrap(pixel(second, CGPoint(x: 4, y: size.height - 4), in: size))
            XCTAssertGreaterThan(sidebarPixel.redComponent, 0.8, "the light theme's rail, not the dark one (x\(Int(backing)))")
            // The header's top-left padding (the terminal below it stays opaque by design).
            opaque[backing] = try XCTUnwrap(pixel(second, CGPoint(x: sz(290) + 5, y: 4), in: size))
        }

        // An opacity change (backdropTick, no rebuild) fades the open window's body in place.
        ThemeStore.shared.setOpacity(0.8)
        AppDelegate.applyThemedWindowSizing([win], scale: ThemeRuntime.scale)
        XCTAssertFalse(win.isOpaque)
        for backing in backings {
            let third = try snapshot(view, backing: backing)
            try saveTo860(third, "live-probe-opacity-0.8-x\(Int(backing))")
            let faded = try XCTUnwrap(pixel(third, CGPoint(x: sz(290) + 5, y: 4), in: size))
            XCTAssertEqual(try XCTUnwrap(opaque[backing]).alphaComponent, 1, accuracy: 0.01, "x\(Int(backing))")
            XCTAssertEqual(faded.alphaComponent, 0.8, accuracy: 0.03, "the body's backdrop is at the live opacity (x\(Int(backing)))")
        }
        XCTAssertFalse(win.isVisible, "never on screen")
    }

    /// The fixed slots (#828/#829): the restyled section header keeps the old header's height at
    /// every scale (Needs you, a folding section, folded), and a row is the same height selected or not.
    @MainActor
    func testChrome860HeadersAndRowsKeepTheirSlots() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            let old = NSHostingView(rootView: Legacy860AgentHeader(title: "Sessions").frame(width: sz(274))).fittingSize.height
            for (title, toggle, folded) in [(AgentSidebar.needsYouTitle, false, false), ("Sessions", true, false), ("History", true, true)] {
                let h = NSHostingView(rootView: AgentSectionHeader(title: title, count: 12, collapsed: folded,
                                                                   toggle: toggle ? {} : nil).frame(width: sz(274)))
                XCTAssertEqual(h.fittingSize.height, old, accuracy: 0.01, "\(title) header at \(scale)")
            }
            let m = windowModel(store([session("prosper", .working)]))
            m.setVisible(true)
            defer { m.close() }
            let row = try XCTUnwrap(m.sections.first?.rows.first)
            let on = NSHostingView(rootView: AgentSidebarRowView(row: row, selected: true).frame(width: sz(274))).fittingSize
            let off = NSHostingView(rootView: AgentSidebarRowView(row: row, selected: false).frame(width: sz(274))).fittingSize
            XCTAssertEqual(on, off, "row at \(scale)")
        }
    }

    /// r5 (mutant c2): the Needs you header tints BOTH its tick and its title in the blocked colour
    /// (amber), and a plain header has neither. Areas in pt², at backing 1 and 2.
    @MainActor
    func testChrome860NeedsYouTintsTickAndTitle() throws {
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette) = saved }
        ThemeRuntime.scale = 1
        let canvas = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        let size = CGSize(width: 274, height: 40)
        let amber: (NSColor) -> Bool = { $0.redComponent > 0.8 && $0.greenComponent > 0.5 && $0.greenComponent < 0.85 && $0.blueComponent < 0.3 }
        let cyan: (NSColor) -> Bool = { $0.blueComponent > 0.85 && $0.greenComponent > 0.65 && $0.redComponent < 0.5 }
        // Header padding 8 pt, tick 3 pt wide, spacing 8 pt: the tick and its glow sit left of x 16,
        // the title starts at 19 (the glow's faint tail never passes the amber band).
        let tick = CGRect(x: 0, y: 0, width: 16, height: size.height)
        let title = CGRect(x: 20, y: 0, width: 80, height: size.height)
        for dark in [true, false] {
            for backing: CGFloat in [1, 2] {
                ThemeRuntime.palette = dark ? saved.1 : Self.lightPalette
                let tag = "\(dark ? "dark" : "light")-x\(Int(backing))"
                let needs = try renderOver(AgentSectionHeader(title: AgentSidebar.needsYouTitle, count: 1), size: size,
                                           canvas: canvas, dark: dark, backing: backing)
                let plain = try renderOver(AgentSectionHeader(title: "Sessions", count: 1, toggle: {}), size: size,
                                           canvas: canvas, dark: dark, backing: backing)
                try saveTo860(needs, "header-needs-you-\(tag)")
                let tickAmber = pt2(band(needs, amber, in: tick, size: size), needs, size)
                let titleAmber = pt2(band(needs, amber, in: title, size: size), needs, size)
                XCTAssertGreaterThan(tickAmber, 10, "Needs you: the tick is amber (\(tag))")
                XCTAssertEqual(band(needs, cyan, in: tick, size: size), 0, "Needs you: no accent tick (\(tag))")
                XCTAssertGreaterThan(titleAmber, 40, "Needs you: the title is amber (\(tag))")
                XCTAssertEqual(band(plain, amber, in: CGRect(origin: .zero, size: size), size: size), 0,
                               "a plain header has no amber (\(tag))")
            }
        }
    }

    /// r5 (mutants c3, c3a): in the LIVE window (makeWindow, never shown) the selected row wears
    /// Settings' accent fill and edge, not only the bar, and an unselected row wears neither. Two
    /// snapshots, row P selected then row N: every row-content pixel is the same in both, so the
    /// blue difference along a row's middle band is its background alone. The fill adds about
    /// 0.14 of the accent, the 1 pt edge about 0.5 (a 1 pt line is one backing pixel at backing 1,
    /// two at 2). Counts are areas in pt², at backing 1 and 2.
    @MainActor
    func testChrome860SelectedRowFillAndEdgeInTheLiveWindow() throws {
        let saved = (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost)
        func reset() {
            ThemeStore.shared.setOpacity(1.0)
            ThemeStore.shared.setFrost(false)
            Preferences.defaults.removeObject(forKey: "prosper.activeThemeID")
            ThemeStore.shared.setAvailable([])
        }
        reset()
        defer { reset(); (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        ThemeRuntime.scale = 1
        let m = windowModel(store([session("prosper", .working), session("notes", .idle)]))
        m.setVisible(true)
        defer { m.close() }
        let win = AgentsWindow.makeWindow(m, autosave: nil)
        defer { win.contentViewController = nil }
        let view = try XCTUnwrap(win.contentView)
        let size = view.bounds.size
        let cyan: (NSColor) -> Bool = { $0.blueComponent > 0.85 && $0.greenComponent > 0.65 && $0.redComponent < 0.5 }
        let barStrip = CGRect(x: 0, y: 0, width: sz(14), height: size.height)

        /// The selected row's middle (view points), from the selection bar's cyan rows.
        func barMid(_ rep: NSBitmapImageRep) throws -> CGFloat {
            let s = CGFloat(rep.pixelsHigh) / size.height
            var ys: [Int] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<Int(barStrip.maxX * s) {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), cyan(c) { ys.append(y); break }
                }
            }
            let lo = try XCTUnwrap(ys.min()), hi = try XCTUnwrap(ys.max())
            return CGFloat(lo + hi) / 2 / s
        }
        /// Blue differences `on - off` over the right half of the rail (clear of the bar's glow), in
        /// the 8 pt band around `mid`: (fill pixels, edge pixels, pixels bluer by > 0.03).
        func row(_ on: NSBitmapImageRep, _ off: NSBitmapImageRep, mid: CGFloat) -> (fill: Int, edge: Int, any: Int) {
            let s = CGFloat(on.pixelsWide) / size.width
            var fill = 0, edge = 0, any = 0
            for y in Int((mid - 4) * s)..<Int((mid + 4) * s) {
                for x in Int(sz(145) * s)..<Int(sz(290) * s) {
                    guard let a = on.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          let b = off.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let d = a.blueComponent - b.blueComponent
                    if d > 0.03 { any += 1 }
                    if d > 0.05 && d < 0.25 { fill += 1 }
                    if d > 0.3 { edge += 1 }
                }
            }
            return (fill, edge, any)
        }

        let backings: [CGFloat] = [1, 2]
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "prosper")))
        let ps = try backings.map { try snapshot(view, backing: $0) }
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "notes")))
        let ns = try backings.map { try snapshot(view, backing: $0) }
        for (i, backing) in backings.enumerated() {
            let p = ps[i], n = ns[i], x = "x\(Int(backing))"
            try saveTo860(p, "live-rows-prosper-selected-\(x)")
            try saveTo860(n, "live-rows-notes-selected-\(x)")
            let pMid = try barMid(p), nMid = try barMid(n)
            XCTAssertGreaterThan(abs(pMid - nMid), sz(20), "two different rows (\(x))")
            for (name, on, off, mid) in [("prosper", p, n, pMid), ("notes", n, p, nMid)] {
                let r = row(on, off, mid: mid)
                let fill = pt2(r.fill, on, size), edge = pt2(r.edge, on, size)
                // About 135 pt of fill per point row (minus the age text), 8 pt high.
                XCTAssertGreaterThan(fill, 400, "\(name) selected: the accent fill (\(x), \(r))")
                // The right edge: one 1 pt column, 8 pt high, less a backing pixel of antialiasing at each end.
                XCTAssertGreaterThanOrEqual(edge, 6, "\(name) selected: the accent edge (\(x), \(r))")
                // The same band with the row unselected: nothing bluer than when selected elsewhere.
                XCTAssertEqual(row(off, on, mid: mid).any, 0, "\(name) unselected: no fill, no edge (\(x))")
            }
        }
        XCTAssertFalse(win.isVisible, "never on screen")
    }

    /// r5 (mutant c4): the 1 pt divider between rail and detail is a translucent stroke with no fill
    /// of its own under it, so at opacity 0.8 the canvas shows through it like the columns beside it
    /// (two canvases give two pixels at every backing pixel of the column). At 1.0 nothing is
    /// asserted: offscreen there is no window background behind it (in the window that is bgTop).
    @MainActor
    func testChrome860DividerLetsTheBackdropThrough() throws {
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette, ThemeRuntime.opacity, ThemeRuntime.frost) = saved }
        ThemeRuntime.scale = 1
        ThemeRuntime.frost = false
        let m = windowModel(store([session("prosper", .working), session("notes", .idle)]))
        m.setVisible(true)
        defer { m.close() }
        let grey = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        let size = CGSize(width: 1000, height: 680)
        // The divider is the 1 pt column right of the 290 pt rail (whole points at scale 1).
        let column = CGRect(x: sz(290), y: 100, width: 1, height: 400)
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved.1 : Self.lightPalette
            for backing: CGFloat in [1, 2] {
                ThemeRuntime.opacity = 0.8
                let tag = "\(dark ? "dark" : "light")-x\(Int(backing))"
                let g = try renderOver(AgentWindowRootView(model: m, scrolls: false), size: size, canvas: grey, dark: dark, backing: backing)
                let mg = try renderOver(AgentWindowRootView(model: m, scrolls: false), size: size, canvas: magenta, dark: dark, backing: backing)
                let s = CGFloat(g.pixelsWide) / size.width
                var through = 0, total = 0
                for y in Int(column.minY * s)..<Int(column.maxY * s) {
                    for x in Int(column.minX * s)..<Int(column.maxX * s) {
                        guard let a = g.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              let b = mg.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        total += 1
                        if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) > 0.1 { through += 1 }
                    }
                }
                XCTAssertEqual(pt2(total, g, size), 400, accuracy: 0.01, tag)
                XCTAssertEqual(through, total, "opacity 0.8: the canvas shows through every divider pixel (\(tag))")
            }
        }
    }
}
