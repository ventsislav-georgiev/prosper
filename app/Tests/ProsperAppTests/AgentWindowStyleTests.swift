import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1378: the Agent Sessions window's style (Standard, No title bar, Borderless; Borderless's rounded corners) and the
/// drag area behind the sidebar title row and the session header. Offscreen only: every window is built and never shown,
/// ordered in or made key; key and mouse events are built and handed to a never-shown window or view, never posted; the
/// minimise and the drag run into recorders. The two settings live in Preferences.defaults, the private in-memory test
/// store; every row saves them, the theme values and the split gate, and puts them back in a defer.
@MainActor
final class AgentWindowStyleTests: XCTestCase {
    /// The D1 class's fakes (store, sessions, a model with every outside effect replaced); its rows are not run from here.
    private let d1 = AgentWindowD1Tests()
    static let keys = ["agentWindowStyle", "agentWindowRoundedCorners"]
    static let standardMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// A Standard window on an otherwise unset store (#1478: unset now builds Borderless), the style put back after; for rows
    /// that test the title-bar chrome or sample the Standard layout. Shared by the other Agent Sessions window rows.
    static func makeStandardWindow(_ m: AgentWindowModel) -> AgentsNSWindow {
        let d = Preferences.defaults, saved = d.object(forKey: "agentWindowStyle")
        defer { if let saved { d.set(saved, forKey: "agentWindowStyle") } else { d.removeObject(forKey: "agentWindowStyle") } }
        Preferences.agentWindowStyle = .standard
        return AgentsWindow.makeWindow(m, autosave: nil)
    }

    /// Runs `body` with both settings unset, the gate off, scale 1, opacity 1, no frost; all put back after.
    func withStyleRow(_ body: () throws -> Void) rethrows {
        let d = Preferences.defaults
        let saved = Self.keys.map { d.object(forKey: $0) }
        let theme = (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost), gate = AgentPaneLayout.splitsEnabled
        defer {
            for (k, v) in zip(Self.keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
            (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost) = theme
            AgentPaneLayout.splitsEnabled = gate
        }
        XCTAssertFalse(d === UserDefaults.standard, "a private defaults store")
        for k in Self.keys { d.removeObject(forKey: k) }
        (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost) = (1, 1, false)
        AgentPaneLayout.splitsEnabled = false
        try body()
    }

    /// The real window for the settings in force, never shown, with one session selected and laid out.
    func built(_ body: (AgentsNSWindow) throws -> Void) throws {
        let m = d1.windowModel(d1.store([d1.session("api", .working), d1.session("api-qa", .idle)]))
        defer { m.close() }
        m.setVisible(true)   // the model builds its sections only while visible
        m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "api")))
        let win = AgentsWindow.makeWindow(m, autosave: nil)
        defer { win.contentViewController = nil }
        for _ in 0..<3 {
            win.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(win.isVisible, "built, never shown")
        try body(win)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    func key(_ c: String, _ code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                                       context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code))
    }

    /// Window-space frames of the drag views, the sidebar's first (leftmost).
    func dragFrames(_ v: NSView) -> [CGRect] {
        var out = v is AgentWindowDragView ? [v.convert(v.bounds, to: nil)] : []
        for s in v.subviews { out += dragFrames(s) }
        return out.sorted { $0.minX < $1.minX }
    }

    func hit(_ win: NSWindow, _ p: CGPoint) -> NSView? {
        guard let cv = win.contentView, let sup = cv.superview else { return nil }
        return cv.hitTest(sup.convert(p, from: nil))
    }

    /// QA R1378-s1: the frame view's own hit at window point `p`, so a titlebar container over the content is seen.
    func frameHit(_ win: NSWindow, _ p: CGPoint) -> NSView? {
        guard let frame = win.contentView?.superview else { return nil }
        return frame.hitTest(frame.superview?.convert(p, from: nil) ?? p)
    }

    // MARK: The style per setting

    func testStandardIsTodaysWindow() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .standard   // #1478: was the unset default
            try built { win in
                XCTAssertEqual(win.style, .standard)
                XCTAssertEqual(win.styleMask, Self.standardMask, "#860's mask, no .fullSizeContentView")
                XCTAssertEqual(win.titleVisibility, .hidden)
                XCTAssertTrue(win.titlebarAppearsTransparent)
                for b in Self.buttons {
                    let button = try XCTUnwrap(win.standardWindowButton(b), "\(b.rawValue)")
                    XCTAssertFalse(button.isHidden, "the traffic lights show")
                }
                XCTAssertTrue(win.canBecomeKey)
                XCTAssertTrue(win.canBecomeMain)
                XCTAssertTrue(win.isOpaque, "opacity 1, no frost: the theme's opaque window")
                XCTAssertEqual(win.backgroundColor.alphaComponent, 1)
                let cv = try XCTUnwrap(win.contentView)
                XCTAssertLessThan(cv.convert(cv.bounds, to: nil).maxY, win.frame.height, "the content starts under the title bar band")
                XCTAssertEqual(cv.layer?.cornerRadius ?? 0, 0)
            }
        }
    }

    /// #1478: a fresh store builds a Borderless window with square corners; a stored Standard and a stored `true` are kept.
    func testUnsetStoreBuildsBorderlessSquareAndStoredChoicesWin() throws {
        try withStyleRow {
            try built { win in
                XCTAssertEqual(win.style, .borderless)
                XCTAssertFalse(win.styleMask.contains(.titled))
                XCTAssertFalse(win.roundedCorners)
                XCTAssertTrue(win.isOpaque, "square: opaque")
                XCTAssertEqual(win.contentView?.layer?.cornerRadius ?? 0, 0)
            }
            Preferences.agentWindowStyle = .standard
            Preferences.agentWindowRoundedCorners = true
            try built { win in
                XCTAssertEqual(win.style, .standard, "a stored Standard is kept")
                XCTAssertEqual(win.styleMask, Self.standardMask)
            }
            Preferences.agentWindowStyle = .borderless
            try built { win in XCTAssertTrue(win.roundedCorners, "a stored true is kept") }
        }
    }

    func testNoTitleBarHidesTheBarAndTheButtonsAndMovesTheContentUp() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .noTitleBar
            try built { win in
                XCTAssertEqual(win.style, .noTitleBar)
                XCTAssertEqual(win.styleMask, Self.standardMask.union(.fullSizeContentView))
                XCTAssertEqual(win.titleVisibility, .hidden)
                XCTAssertTrue(win.titlebarAppearsTransparent)
                for b in Self.buttons {
                    XCTAssertTrue(win.standardWindowButton(b).map(\.isHidden) ?? true, "button \(b.rawValue) hidden")
                }
                XCTAssertTrue(win.canBecomeKey)
                XCTAssertTrue(win.canBecomeMain)
                let cv = try XCTUnwrap(win.contentView)
                XCTAssertEqual(cv.convert(cv.bounds, to: nil).maxY, win.frame.height, accuracy: 0.5, "the content reaches the top edge")
                let sidebar = try XCTUnwrap(dragFrames(cv).first, "the title row's drag area")
                XCTAssertEqual(sidebar.maxY, win.frame.height, accuracy: 0.5, "the title row itself sits at the top (no safe-area pad)")
            }
        }
    }

    func testBorderlessHasNoFrameAndStillTakesTheKeys() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .borderless
            try built { win in
                XCTAssertEqual(win.style, .borderless)
                XCTAssertEqual(win.styleMask, [.resizable, .miniaturizable], ".borderless (0), resizable, miniaturizable")
                XCTAssertFalse(win.styleMask.contains(.titled))
                for b in Self.buttons {
                    XCTAssertTrue(win.standardWindowButton(b).map(\.isHidden) ?? true, "button \(b.rawValue) not shown")
                }
                XCTAssertTrue(win.canBecomeKey, "a borderless NSWindow answers false by default")
                XCTAssertTrue(win.canBecomeMain)
                XCTAssertTrue(win.hasShadow)
                let cv = try XCTUnwrap(win.contentView)
                XCTAssertEqual(cv.convert(cv.bounds, to: nil).maxY, win.frame.height, accuracy: 0.5)
                let sidebar = try XCTUnwrap(dragFrames(cv).first)
                XCTAssertEqual(sidebar.maxY, win.frame.height, accuracy: 0.5)
            }
        }
    }

    /// Rounded: clear outside the content's rounded mask. Square: opaque to the edges in the theme's colour, and it stays
    /// so when the theme hook re-runs applyWindowOpacity at opacity 0.8 (no wallpaper behind a screen-sized window).
    func testBorderlessRoundedCornersOnAndOff() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .borderless
            Preferences.agentWindowRoundedCorners = true   // #1478: was the unset default
            try built { win in
                let cv = try XCTUnwrap(win.contentView)
                XCTAssertTrue(win.roundedCorners, "on when stored")
                XCTAssertFalse(win.isOpaque)
                XCTAssertEqual(win.backgroundColor.alphaComponent, 0, "clear outside the corners")
                XCTAssertEqual(cv.layer?.cornerRadius, AgentsWindow.cornerRadius)
                XCTAssertEqual(cv.layer?.masksToBounds, true)
                XCTAssertGreaterThan(AgentsWindow.cornerRadius, 0)
            }
            Preferences.agentWindowRoundedCorners = false
            try built { win in
                let cv = try XCTUnwrap(win.contentView)
                XCTAssertFalse(win.roundedCorners)
                XCTAssertTrue(win.isOpaque, "square: opaque")
                XCTAssertEqual(win.backgroundColor.alphaComponent, 1)
                XCTAssertEqual(cv.layer?.cornerRadius ?? 0, 0, "square")
                XCTAssertEqual(cv.layer?.masksToBounds ?? false, false)
                ThemeRuntime.opacity = 0.8
                AppDelegate.applyThemedWindowSizing([win], scale: 1)
                XCTAssertTrue(win.isOpaque, "the theme hook keeps it opaque")
                XCTAssertEqual(win.backgroundColor.alphaComponent, 1)
            }
        }
    }

    /// A change in Settings restyles the open window in place: Standard -> Borderless -> No title bar -> Standard ends
    /// with today's literals again.
    func testRestyleInPlaceReturnsToStandard() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .standard   // #1478: was the unset default
            try built { win in
                AgentsWindow.applyStyle(win, style: .borderless, rounded: true)
                XCTAssertFalse(win.styleMask.contains(.titled))
                AgentsWindow.applyStyle(win, style: .noTitleBar, rounded: true)
                XCTAssertTrue(win.styleMask.contains(.fullSizeContentView))
                XCTAssertEqual(win.contentView?.layer?.cornerRadius ?? 0, 0, "the mask is Borderless's only")
                AgentsWindow.applyStyle(win, style: .standard, rounded: false)
                XCTAssertEqual(win.styleMask, Self.standardMask)
                for b in Self.buttons { XCTAssertEqual(win.standardWindowButton(b)?.isHidden, false) }
                XCTAssertTrue(win.isOpaque)
                XCTAssertEqual(win.backgroundColor.alphaComponent, 1)
            }
        }
    }

    /// #2045: what a Standard window's chrome is, for comparing a live switch with a fresh build.
    struct StandardChrome: Equatable {
        let mask: NSWindow.StyleMask, frame: CGRect, content: CGRect, opaque: Bool, fill: [CGFloat], buttonsShown: Bool
        let transparentBar: Bool, titleHidden: Bool
    }
    /// sRGB components, so two NSColors made from the same theme colour compare by value.
    static func rgba(_ c: NSColor?) -> [CGFloat] {
        guard let c = c?.usingColorSpace(.sRGB) else { return [] }
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { ($0 * 1000).rounded() / 1000 }
    }
    func chrome(_ win: AgentsNSWindow) throws -> StandardChrome {
        let cv = try XCTUnwrap(win.contentView)
        return StandardChrome(mask: win.styleMask, frame: win.frame, content: cv.convert(cv.bounds, to: nil), opaque: win.isOpaque,
                              fill: Self.rgba(win.backgroundColor), buttonsShown: Self.buttons.allSatisfy { win.standardWindowButton($0)?.isHidden == false },
                              transparentBar: win.titlebarAppearsTransparent, titleHidden: win.titleVisibility == .hidden)
    }

    /// #2045 (operator 2026-11-27: the traffic lights over the sidebar's "Agent Sessions" header after a live switch, fixed by a
    /// restart): the content sits below the title bar and its buttons on a fresh Standard build and after a switch to Standard
    /// from every other style; each switch, a round trip Standard -> X -> Standard included, leaves the window as it was built.
    func testEveryPathToStandardKeepsTheContentBelowTheTitleBar() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .standard
            try built { win in
                @MainActor func below(_ what: String) throws {
                    let cv = try XCTUnwrap(win.contentView)
                    let content = cv.convert(cv.bounds, to: nil)
                    XCTAssertLessThanOrEqual(content.maxY, win.contentLayoutRect.maxY + 0.5, "\(what): the content's top under the bar")
                    XCTAssertLessThan(content.maxY, win.frame.height, "\(what): a title bar band above the content")
                    for b in Self.buttons {
                        let button = try XCTUnwrap(win.standardWindowButton(b), "\(what) \(b.rawValue)")
                        XCTAssertFalse(button.isHidden, "\(what) \(b.rawValue)")
                        let f = button.convert(button.bounds, to: nil)
                        XCTAssertFalse(f.intersects(content), "\(what): button \(b.rawValue) \(f) over the content \(content)")
                    }
                }
                try below("fresh")
                let fresh = try chrome(win)
                for (from, rounded) in [(AgentWindowStyle.borderless, true), (.borderless, false), (.noTitleBar, false), (.standard, false)] {
                    AgentsWindow.applyStyle(win, style: from, rounded: rounded)
                    win.contentView?.layoutSubtreeIfNeeded()
                    AgentsWindow.applyStyle(win, style: .standard, rounded: false)
                    try below("\(from) rounded \(rounded) -> standard")
                    XCTAssertEqual(try chrome(win), fresh, "\(from) rounded \(rounded) -> standard: as built")
                }
            }
        }
    }

    /// #2045 (a colleague's see-through strip): after a switch to Standard the strip's fill is the fresh Standard build's,
    /// applyWindowOpacity's for the theme (Settings' strip), under an opaque theme and a translucent frosted one.
    func testTheStripAfterASwitchToStandardIsTheThemesFill() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .standard
            for (opacity, frost) in [(CGFloat(1), false), (CGFloat(0.8), true)] {
                (ThemeRuntime.opacity, ThemeRuntime.frost) = (opacity, frost)
                let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: Self.standardMask,
                                        backing: .buffered, defer: true)
                settings.isReleasedWhenClosed = false
                SettingsWindow.applyWindowOpacity(settings)
                try built { win in
                    let what = "opacity \(opacity) frost \(frost)"
                    XCTAssertEqual(win.isOpaque, settings.isOpaque, "\(what): fresh")
                    XCTAssertEqual(Self.rgba(settings.backgroundColor).count, 4, "\(what): an sRGB fill to compare")
                    XCTAssertEqual(Self.rgba(win.backgroundColor), Self.rgba(settings.backgroundColor), "\(what): fresh, Settings' strip")
                    XCTAssertEqual(win.backgroundColor.alphaComponent, opacity >= 0.999 && !frost ? 1 : ThemeRuntime.backdropFillOpacity,
                                   accuracy: 0.001, what)
                    for (from, rounded) in [(AgentWindowStyle.borderless, true), (.borderless, false), (.noTitleBar, false)] {
                        AgentsWindow.applyStyle(win, style: from, rounded: rounded)
                        AgentsWindow.applyStyle(win, style: .standard, rounded: rounded)
                        XCTAssertEqual(win.isOpaque, settings.isOpaque, "\(what): \(from) rounded \(rounded) -> standard")
                        XCTAssertEqual(Self.rgba(win.backgroundColor), Self.rgba(settings.backgroundColor), "\(what): \(from) rounded \(rounded) -> standard")
                    }
                }
            }
        }
    }

    /// Command-W closes and Command-M minimises in No title bar and Borderless (built key events handed to the window);
    /// Standard keeps today's keys (no Command-M).
    func testCommandWClosesAndCommandMMinimisesWithoutTheButtons() throws {
        try withStyleRow {
            for style in AgentWindowStyle.allCases {
                Preferences.agentWindowStyle = style
                try built { win in
                    var minimised = 0
                    win.minimize = { _ in minimised += 1 }
                    let handled = win.performKeyEquivalent(with: try key("m", 46))
                    XCTAssertEqual(minimised, style == .standard ? 0 : 1, "\(style) Command-M")
                    if style != .standard { XCTAssertTrue(handled) }
                    nonisolated(unsafe) var closed = 0
                    let o = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: nil) { _ in
                        closed += 1
                    }
                    defer { NotificationCenter.default.removeObserver(o) }
                    XCTAssertTrue(win.performKeyEquivalent(with: try key("w", 13)))
                    if style != .standard { XCTAssertEqual(closed, 1, "\(style) Command-W closes") }
                }
            }
        }
    }

    // MARK: The drag area

    /// The empty parts of the sidebar title row and of the header land on the drag view (it moves the window); the "+",
    /// ">_", the sidebar's and the header's "..." and the first control after the header's title (its state chip) do not.
    /// Every style, UI scale 0.7, 0.85 and 1.0.
    @MainActor
    func testTheTitleRowAndTheHeaderDragAndTheirControlsDoNot() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        try withStyleRow {
            for style in AgentWindowStyle.allCases {
                for scale: CGFloat in [0.7, 0.85, 1.0] {
                    Preferences.agentWindowStyle = style
                    ThemeRuntime.scale = scale
                    try built { win in
                        let at = "\(style) at \(scale)"
                        let row = try XCTUnwrap(dragFrames(try XCTUnwrap(win.contentView)).first, "the title row's \(at)")
                        // The header in a never-shown window of its own (ticket 2: the built window's pane held no header drag view after 0.3 s of layout).
                        let st = d1.store([d1.session("api", .working)])
                        let hm = d1.windowModel(st)
                        hm.setVisible(true)   // the model builds its sections only while visible
                        defer { hm.close() }
                        let r = try XCTUnwrap(hm.sections.flatMap(\.rows).first { $0.session != nil }, "a live row \(at)")
                        let s = try XCTUnwrap(r.session)
                        let hw = NSWindow(contentRect: NSRect(x: 0, y: 0, width: sz(700), height: sz(140)), styleMask: [.borderless],
                                          backing: .buffered, defer: true)
                        hw.isReleasedWhenClosed = false
                        hw.contentView = NSHostingView(rootView: Themed {
                            AgentSessionHeader(row: r, session: s, cwd: nil, open: {}, store: st)
                                .frame(width: sz(700)).frame(maxHeight: .infinity, alignment: .top)
                        })
                        defer { hw.contentView = NSView() }
                        for _ in 0..<3 {
                            hw.contentView?.layoutSubtreeIfNeeded()
                            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        }
                        XCTAssertFalse(hw.isVisible)
                        let header = try XCTUnwrap(dragFrames(try XCTUnwrap(hw.contentView)).first, "the header's \(at)")
                        XCTAssertEqual(row.maxX, AgentWindowModel.fullSidebarWidth, accuracy: pixel, "the row spans the sidebar \(at)")
                        @MainActor func drags(_ p: CGPoint, _ what: String, in w: NSWindow? = nil) {
                            let v = hit(w ?? win, p)
                            XCTAssertTrue(v is AgentWindowDragView, "\(what) \(at): \(v.map { "\(type(of: $0))" } ?? "nil")")
                            XCTAssertEqual(v?.mouseDownCanMoveWindow, true, "\(what) \(at)")
                        }
                        @MainActor func keeps(_ p: CGPoint, _ what: String, in w: NSWindow? = nil) {
                            let v = hit(w ?? win, p)
                            XCTAssertTrue(v != nil, "\(what) \(at): nothing under it")
                            XCTAssertFalse(v.map { sequence(first: $0, next: { $0.superview }).contains { $0 is AgentWindowDragView } } ?? true,
                                           "\(what) \(at): a press would drag the window")
                        }
                        let rowY = row.maxY - AgentSidebarTitleRow.padTop - sz(9)
                        drags(CGPoint(x: row.minX + sz(5), y: rowY), "the row's leading padding")
                        drags(CGPoint(x: row.midX, y: row.maxY - sz(4)), "the row's top padding")
                        drags(CGPoint(x: row.minX + sz(14) + sz(20), y: rowY), "the window's name")
                        keeps(CGPoint(x: row.maxX - sz(14) - sz(9), y: rowY), "the + button")
                        keeps(CGPoint(x: row.maxX - sz(14) - sz(31), y: rowY), "the >_ button")
                        keeps(CGPoint(x: row.maxX - sz(14) - sz(40) - sz(4) - sz(9), y: rowY), "the sidebar's ... menu")
                        let lineY = header.maxY - AgentSessionHeader.padTop - AgentSessionHeader.lineHeight / 2
                        drags(CGPoint(x: header.minX + sz(6), y: lineY), "the header's leading padding", in: hw)
                        drags(CGPoint(x: header.midX, y: header.maxY - sz(4)), "the header's top padding", in: hw)
                        keeps(CGPoint(x: header.maxX - sz(16) - sz(9), y: lineY), "the header's ... menu", in: hw)
                        // The first point along the title line that is not the drag view: the chip after the title.
                        let chip = stride(from: header.minX + sz(16), to: header.maxX - sz(16), by: 2)
                            .first { !(hit(hw, CGPoint(x: $0, y: lineY)) is AgentWindowDragView) }
                        let x = try XCTUnwrap(chip, "a control on the title line \(at)")
                        XCTAssertLessThan(x, header.midX, "the chip, before the picker and the toggle \(at)")
                        keeps(CGPoint(x: x + 1, y: lineY), "the state chip", in: hw)
                    }
                }
            }
        }
    }

    /// Window-space frames of the scroll views on the sidebar's side of `x`.
    func scrollFrames(_ v: NSView, leftOf x: CGFloat) -> [CGRect] {
        let f = v.convert(v.bounds, to: nil)
        return (v is NSScrollView && f.minX < x ? [f] : []) + v.subviews.flatMap { scrollFrames($0, leftOf: x) }
    }

    /// Ticket 4: in No title bar at 0.7 the sidebar list's scroll view lay over the whole title row. The list never
    /// reaches into the title row, in every style at every scale.
    func testTheSidebarListStaysBelowTheTitleRow() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        try withStyleRow {
            for style in AgentWindowStyle.allCases {
                for scale: CGFloat in [0.7, 0.85, 1.0] {
                    Preferences.agentWindowStyle = style
                    ThemeRuntime.scale = scale
                    try built { win in
                        let cv = try XCTUnwrap(win.contentView)
                        let row = try XCTUnwrap(dragFrames(cv).first, "the title row \(style) at \(scale)")
                        let lists = scrollFrames(cv, leftOf: row.maxX - 1)
                        XCTAssertFalse(lists.isEmpty, "the session list \(style) at \(scale)")
                        for l in lists {
                            XCTAssertLessThanOrEqual(l.maxY, row.minY + pixel, "the list \(l) under the row \(row), \(style) at \(scale)")
                        }
                    }
                }
            }
        }
    }

    /// A press on the title row's "+", ">_" and "..." lands on the control itself: the same view as in Standard at
    /// scale 1, never the list's scroll view or the drag view. Every style, UI scale 0.7, 0.85 and 1.0.
    func testTheTitleRowButtonsTakeTheirOwnPresses() throws {
        try withStyleRow {
            var reference: [String: String] = [:]
            for style in AgentWindowStyle.allCases {
                for scale: CGFloat in [1.0, 0.85, 0.7] {
                    Preferences.agentWindowStyle = style
                    ThemeRuntime.scale = scale
                    try built { win in
                        let row = try XCTUnwrap(dragFrames(try XCTUnwrap(win.contentView)).first, "the title row \(style) at \(scale)")
                        let y = row.maxY - AgentSidebarTitleRow.padTop - sz(9)
                        for (what, dx) in [("+", sz(9)), (">_", sz(31)), ("...", sz(40) + sz(4) + sz(9))] {
                            let p = CGPoint(x: row.maxX - sz(14) - dx, y: y)
                            // QA R1378-s1: No title bar from the frame view, where the titlebar container lies over the band.
                            let v = try XCTUnwrap(style == .noTitleBar ? frameHit(win, p) : hit(win, p), "\(what) \(style) at \(scale)")
                            let chain = Array(sequence(first: v, next: { $0.superview }))
                            let name = "\(type(of: v))"
                            XCTAssertTrue(v.isDescendant(of: try XCTUnwrap(win.contentView)), "\(what) \(style) at \(scale): \(name)")
                            XCTAssertFalse(chain.contains { "\(type(of: $0))".contains("Titlebar") }, "\(what) \(style) at \(scale): \(name)")
                            XCTAssertFalse(chain.contains { $0 is NSScrollView }, "\(what) \(style) at \(scale): \(name)")
                            XCTAssertFalse(chain.contains { $0 is AgentWindowDragView }, "\(what) \(style) at \(scale): \(name)")
                            if reference[what] == nil { reference[what] = name }
                            XCTAssertEqual(name, reference[what], "\(what) \(style) at \(scale)")
                        }
                    }
                }
            }
        }
    }

    /// A press drags the window through performDrag (a recording window, the event built and never posted); the
    /// double-click follows the title bar's setting; the view adds no accessibility element.
    func testDragViewPressDoubleClickAndAccessibility() throws {
        final class Recorder: NSWindow {
            var drags = 0, zooms = 0, minimises = 0
            override func performDrag(with event: NSEvent) { drags += 1 }
            override func zoom(_ sender: Any?) { zooms += 1 }
            override func miniaturize(_ sender: Any?) { minimises += 1 }
        }
        let w = Recorder(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        let v = AgentWindowDragView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        w.contentView?.addSubview(v)
        defer { v.removeFromSuperview() }
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 50, y: 20), modifierFlags: [],
                                                     timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        XCTAssertTrue(v.mouseDownCanMoveWindow)
        XCTAssertTrue(v.acceptsFirstMouse(for: press))
        v.mouseDown(with: press)
        XCTAssertEqual(w.drags, 1)
        for (action, zooms, minimises) in [(nil, 1, 0), ("Maximize", 2, 0), ("Fill", 3, 0), ("None", 3, 0), ("Minimize", 3, 1)] as [(String?, Int, Int)] {
            AgentWindowDragView.doubleClick(action, w)
            XCTAssertEqual(w.zooms, zooms, "\(action ?? "unset")")
            XCTAssertEqual(w.minimises, minimises, "\(action ?? "unset")")
        }
        XCTAssertFalse(v.isAccessibilityElement())
        XCTAssertFalse(w.isVisible)
    }

    // MARK: The settings

    func testTheSettingsRoundTripThroughPreferences() throws {
        try withStyleRow {
            let d = Preferences.defaults
            XCTAssertEqual(AgentWindowStyle.allCases.map(\.rawValue), ["standard", "noTitleBar", "borderless"])
            XCTAssertEqual(AgentWindowStyle.allCases.map(\.label), ["Standard", "No title bar", "Borderless"])
            XCTAssertEqual(Preferences.agentWindowStyle, .borderless, "Borderless when unset (#1478)")
            XCTAssertFalse(Preferences.agentWindowRoundedCorners, "square when unset (#1478)")
            for s in AgentWindowStyle.allCases {
                Preferences.agentWindowStyle = s
                XCTAssertEqual(Preferences.agentWindowStyle, s)
                XCTAssertEqual(d.string(forKey: "agentWindowStyle"), s.rawValue)
            }
            d.set("fancy", forKey: "agentWindowStyle")
            XCTAssertEqual(Preferences.agentWindowStyle, .borderless, "an unknown value reads as the default, Borderless")
            d.set("standard", forKey: "agentWindowStyle")
            XCTAssertEqual(Preferences.agentWindowStyle, .standard, "a stored Standard wins over the default")
            Preferences.agentWindowRoundedCorners = false
            XCTAssertFalse(Preferences.agentWindowRoundedCorners)
            XCTAssertEqual(d.object(forKey: "agentWindowRoundedCorners") as? Bool, false)
            Preferences.agentWindowRoundedCorners = true
            XCTAssertTrue(Preferences.agentWindowRoundedCorners)
            XCTAssertEqual(AgentSessionsSection.roundedHint(.borderless), "Off: square corners, filling the window to its edges.")
            XCTAssertEqual(AgentSessionsSection.roundedHint(.standard), "Borderless only: a window with a title bar keeps rounded corners.")
            XCTAssertEqual(AgentSessionsSection.roundedHint(.noTitleBar), AgentSessionsSection.roundedHint(.standard))
            // #2046: titled styles show ON whatever is stored; Borderless shows the stored choice.
            let rows: [(AgentWindowStyle, Bool, Bool)] = [(.standard, false, true), (.standard, true, true), (.noTitleBar, false, true),
                                                          (.noTitleBar, true, true), (.borderless, false, false), (.borderless, true, true)]
            for (style, stored, shown) in rows {
                XCTAssertEqual(AgentSessionsSection.roundedShown(style: style, stored: stored), shown, "\(style) stored \(stored)")
            }
        }
    }

    // MARK: #2045: a live style switch rebuilds the window

    /// The open window for the settings in force, built by makeWindow through AgentsWindow.show (#1784's rig: present and
    /// dismissed are recorders, so it is never shown), then torn down after `body`.
    func opened(_ body: (AgentWindowD1Tests.HideRig, AgentsNSWindow) throws -> Void) throws {
        let r = AgentWindowD1Tests.HideRig(d1.store([d1.session("api", .working), d1.session("api-qa", .idle)]), real: true)
        let w = r.w
        defer { w.window?.close(); w.grace?.fire() }
        w.show()
        _ = try r.model()
        let win = try XCTUnwrap(w.window as? AgentsNSWindow)
        XCTAssertFalse(win.isVisible, "built, never shown")
        try body(r, win)
        XCTAssertFalse(w.window?.isVisible ?? false, "never shown")
    }

    /// A window's look for its style, to compare a rebuilt window with a fresh build (frames aside).
    static func look(_ win: AgentsNSWindow) -> String {
        "\(win.style) \(win.roundedCorners) \(win.styleMask.rawValue) \(buttons.map { win.standardWindowButton($0)?.isHidden ?? true }) "
            + "\(win.isOpaque) \(rgba(win.backgroundColor)) \(win.hasShadow) \(win.titlebarAppearsTransparent) \(win.titleVisibility.rawValue) "
            + "\(win.contentView?.layer?.cornerRadius ?? -1) \(win.contentView?.layer?.masksToBounds ?? false)"
    }

    /// #2045 round 6 (operator 2026-11-28: Borderless square switched live to Standard kept the traffic lights over the
    /// sidebar's header until a restart): Settings' style change (the setting, then restyle) replaces the window with a fresh
    /// build for the new style around the same model, pane runtime and content, in the old window's frame; the old one keeps
    /// no observer (its willClose starts no grace), the new one's willClose hides as before.
    func testALiveStyleSwitchRebuildsTheWindowAroundTheSameModel() throws {
        try withStyleRow {
            let switches: [(AgentWindowStyle, Bool, AgentWindowStyle)] = [(.borderless, false, .standard), (.borderless, true, .standard),
                                                                          (.noTitleBar, true, .standard), (.standard, true, .borderless),
                                                                          (.standard, true, .noTitleBar)]
            for (from, rounded, to) in switches {
                let what = "\(from) rounded \(rounded) -> \(to)"
                Preferences.agentWindowStyle = from
                Preferences.agentWindowRoundedCorners = rounded
                try opened { r, old in
                    let w = r.w, m = try XCTUnwrap(w.model, what)
                    let runtime = try XCTUnwrap(m.focusedRuntime, what), content = try XCTUnwrap(old.contentViewController, what)
                    let frame = old.frame
                    Preferences.agentWindowStyle = to
                    w.restyle()
                    let win = try XCTUnwrap(w.window as? AgentsNSWindow, what)
                    XCTAssertFalse(win === old, "\(what): a new window")
                    XCTAssertTrue(w.model === m && win.model === m, "\(what): the same model")
                    XCTAssertTrue(m.focusedRuntime === runtime, "\(what): the same pane runtime")
                    XCTAssertTrue(win.contentViewController === content && old.contentViewController == nil, "\(what): the content moved")
                    XCTAssertEqual(win.frame, frame, "\(what): the old window's frame")
                    XCTAssertEqual(win.identifier, AgentsWindow.themedIdentifier, what)
                    XCTAssertTrue(old.identifier == nil && old.model == nil, "\(what): the old window keeps no hook")
                    let fm = d1.windowModel(d1.store([d1.session("api", .working)]))
                    defer { fm.close() }
                    let fresh = AgentsWindow.makeWindow(fm, autosave: nil)
                    defer { fresh.contentViewController = nil }
                    XCTAssertEqual(Self.look(win), Self.look(fresh), "\(what): as a fresh build")
                    XCTAssertEqual(win.style, to, what)

                    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: old)
                    XCTAssertTrue(w.grace == nil && w.isOpen, "\(what): the old window's willClose starts no grace")
                    XCTAssertEqual(r.dismissed, 0, what)
                    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: win)
                    XCTAssertTrue(w.grace != nil && w.window === win, "\(what): the new window's willClose hides it")
                    XCTAssertEqual(r.built, 1, "\(what): show built once; the rebuild is restyle's")
                }
            }
        }
    }

    /// #1378: Rounded corners alone (Borderless round <-> square) restyle the open window in place: the same object.
    func testRoundedCornersAloneRestyleTheSameWindow() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .borderless
            Preferences.agentWindowRoundedCorners = true
            try opened { r, win in
                for rounded in [false, true] {
                    Preferences.agentWindowRoundedCorners = rounded
                    r.w.restyle()
                    XCTAssertTrue(r.w.window === win, "rounded \(rounded): in place")
                    XCTAssertEqual(win.roundedCorners, rounded)
                    XCTAssertEqual(win.contentView?.layer?.cornerRadius ?? -1, rounded ? AgentsWindow.cornerRadius : 0)
                }
            }
        }
    }

    /// #2068's gate note reaches the rebuilt window alone: the old window's observer went with it.
    func testTheXrayGateNoteReachesOnlyTheRebuiltWindow() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .borderless
            Preferences.agentWindowRoundedCorners = false
            try opened { r, old in
                Preferences.agentWindowStyle = .standard
                r.w.restyle()
                let win = try XCTUnwrap(r.w.window as? AgentsNSWindow)
                XCTAssertFalse(win === old)
                let (o, n) = (old.gateOpenings, win.gateOpenings)
                NotificationCenter.default.post(name: XrayPanels.gateOpened, object: nil)
                XCTAssertEqual(old.gateOpenings, o, "the old window takes no note")
                XCTAssertEqual(win.gateOpenings, n + 1, "the new window takes it once")
            }
        }
    }

    /// #1784: a window hidden in its grace and switched stays hidden under the same timer; the grace's end tears down the
    /// rebuilt window (the model with it), and a show inside the grace presents the rebuilt one.
    func testAStyleSwitchWhileHiddenKeepsTheGrace() throws {
        try withStyleRow {
            Preferences.agentWindowStyle = .standard
            try opened { r, old in
                let w = r.w, m = try XCTUnwrap(w.model)
                old.close()
                let g = try XCTUnwrap(w.grace)
                Preferences.agentWindowStyle = .borderless
                w.restyle()
                let win = try XCTUnwrap(w.window as? AgentsNSWindow)
                XCTAssertFalse(win === old)
                XCTAssertTrue(w.grace === g && g.isValid && !w.isOpen, "still hidden, the same timer")
                XCTAssertFalse(win.isVisible)
                XCTAssertTrue(w.model === m)
                XCTAssertEqual(r.dismissed, 1, "the hide's alone")
                w.show()
                XCTAssertTrue(w.window === win && w.grace == nil && r.presented == 2, "the rebuilt window presented")
                win.close()
                try XCTUnwrap(w.grace).fire()
                XCTAssertTrue(w.window == nil && w.model == nil, "the grace's end tears down the rebuilt window")
            }
        }
    }
}
