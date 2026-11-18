import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #891 (OQ-86, "Yes, keep everything"): a theme, accent, light or dark, opacity, frost or UI-size change re-themes the
/// open Agent Sessions window in place: no view is torn down. Offscreen only: the window is built by makeWindow and its
/// content hosted in a never-shown window at a forced 1x and 2x backing (OverlayRig); nothing is ordered front or made
/// key, no event is posted. Themes change only through ThemeStore (scratch defaults); the terminal is the recorder of
/// the terminal-mode rows (fakeTerminal: no dch, no pty), its font action a recorder too.
extension AgentWindowD1Tests {

    /// Two probe themes (an accent each; one light, one dark) and the store put back after the row.
    @MainActor
    func rethemeProbes() throws -> (light: ThemeDescriptor, dark: ThemeDescriptor) {
        let dir = tempDir("theme891")
        func probe(_ id: String, _ appearance: ThemeAppearance, _ json: String) throws -> ThemeDescriptor {
            let url = dir.appendingPathComponent("\(id).json")
            try Data(json.utf8).write(to: url)
            return ThemeDescriptor(id: "t.\(id)", title: "Probe \(id)", appearance: appearance, extensionID: "e\(id)", jsonPath: url)
        }
        let light = try probe("891l", .light, ##"{ "appearance": "light", "colors": { "blue": "#FF00FF", "bgTop": "#F4F4F8", "bgBottom": "#E8E8EE", "sidebar": "#EEEEF4", "textPrimary": "#142234" } }"##)
        let dark = try probe("891d", .dark, ##"{ "appearance": "dark", "colors": { "blue": "#00FF66" } }"##)
        return (light, dark)
    }

    @MainActor
    func withRethemeStore(_ body: () throws -> Void) rethrows {
        let saved = (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost, Preferences.agentWindowTerminalFontSize)
        func reset() {
            ThemeStore.shared.setOpacity(1.0)
            ThemeStore.shared.setFrost(false)
            ThemeStore.shared.setScale(1.0)
            Preferences.defaults.removeObject(forKey: "prosper.activeThemeID")
            ThemeStore.shared.setAvailable([])
        }
        reset()
        Preferences.agentWindowTerminalFontSize = nil   // the terminal's size follows the UI size (12 x scale)
        defer {
            reset()
            (ThemeRuntime.scale, ThemeRuntime.opacity, ThemeRuntime.frost) = (saved.0, saved.1, saved.2)
            Preferences.agentWindowTerminalFontSize = saved.3
        }
        try body()
    }

    /// Every kind of change the entry names, in order, through the store's own setters.
    @MainActor
    func rethemeChanges(_ p: (light: ThemeDescriptor, dark: ThemeDescriptor)) -> [(name: String, size: Bool, apply: () -> Void)] {
        [
            ("theme select (light, new accent)", false, { ThemeStore.shared.setAvailable([p.light, p.dark]); ThemeStore.shared.select(id: p.light.id) }),
            ("theme select (dark, another accent)", false, { ThemeStore.shared.select(id: p.dark.id) }),
            ("opacity", false, { ThemeStore.shared.setOpacity(0.8) }),
            ("frost on", false, { ThemeStore.shared.setFrost(true) }),
            ("frost off", false, { ThemeStore.shared.setFrost(false) }),
            ("UI size", true, { ThemeStore.shared.setScale(0.85) }),
        ]
    }

    /// A live session in Terminal mode on the terminal recorder, its log kept (overlayModel's setup).
    @MainActor
    func rethemeModel() -> (AgentWindowModel, AgentSessionKey, (spawned: () -> [AgentTerminalSpawn], children: () -> [AgentTerminalTests.FakeChild])) {
        let s = session("api", .working, ago: 20)
        let m = windowModel(store([s]))
        let log = fakeTerminal(m)
        m.setVisible(true)
        m.select(.live(s.key))
        XCTAssertTrue(m.paneHasTerminal, "a live session opens in Terminal")
        return (m, s.key, log)
    }

    @MainActor
    func rethemeSettle(_ rig: OverlayRig) {
        for _ in 0..<6 { settle(rig.host.view) }
    }

    /// Same terminal host view, same scroll views, same hosting root before and after each change; the terminal's
    /// attach untouched (no second spawn, no terminate); one font action, on the size change only. Frost (QA #735
    /// INFO-4): the blur view is in the hierarchy exactly while frost is live (the blur draws nothing offscreen, so the
    /// structure is the check).
    /// Red on the parent: AgentsWindow.swift:95 `Themed { ... }` keyed the root on `.id(theme.generation)`, so the
    /// first theme select made a new AgentTerminalHostView and new scroll views.
    @MainActor
    func testRetheme891ViewsTerminalAndAttachSurviveEveryKindOfChange() throws {
        try withRethemeStore {
            let probes = try rethemeProbes()
            for backing: CGFloat in [1, 2] {
                let (m, key, log) = rethemeModel()
                defer { m.close() }
                XCTAssertEqual(log.spawned().count, 1, "attached once (x\(Int(backing)))")
                var actions: [String] = []
                m.terminal.fontAction = { _, a in actions.append(a) }
                let rig = OverlayRig(m, size: CGSize(width: 1000, height: 680), backing: backing)
                defer { rig.close() }
                rig.settle(self)
                let spawns = log.spawned().count
                let host = try XCTUnwrap(m.terminal.view, "the terminal is drawn (x\(Int(backing)))")
                let scrolls = focusViews(rig.host.view, NSScrollView.self).map(ObjectIdentifier.init)
                let root = ObjectIdentifier(rig.host.view)
                XCTAssertTrue(actions.isEmpty, "the first draw sends no font action (x\(Int(backing)))")
                for change in rethemeChanges(probes) {
                    let tag = "\(change.name) x\(Int(backing))"
                    let before = AgentTerminalController.fontSize
                    actions = []
                    change.apply()
                    rethemeSettle(rig)
                    XCTAssertTrue(m.terminal.view === host, "the terminal host view is kept: \(tag)")
                    XCTAssertTrue(host.window === rig.win, "and still in the window: \(tag)")
                    XCTAssertEqual(focusViews(rig.host.view, NSScrollView.self).map(ObjectIdentifier.init), scrolls, "scroll views kept: \(tag)")
                    XCTAssertEqual(ObjectIdentifier(rig.host.view), root, tag)
                    XCTAssertEqual(log.spawned().count, spawns, "no second attach: \(tag)")
                    XCTAssertEqual(log.children().last?.terminated ?? -1, 0, "no detach: \(tag)")
                    XCTAssertEqual(m.terminal.key, key, "the same session attached: \(tag)")
                    if change.size {
                        XCTAssertNotEqual(AgentTerminalController.fontSize, before, "the size change moves the terminal font: \(tag)")
                        XCTAssertEqual(actions, ["set_font_size:\(Float(AgentTerminalController.fontSize))"],
                                       "one resize through the font action, once: \(tag)")
                    } else {
                        XCTAssertEqual(actions, [], "no font action without a size change: \(tag)")
                    }
                    if change.name.hasPrefix("frost") {
                        let blur = focusViews(rig.host.view, NSVisualEffectView.self).count
                        XCTAssertEqual(blur > 0, ThemeRuntime.frost, "the frost view is present exactly while frost is live: \(tag)")
                    }
                }
            }
        }
    }

    /// An open Rename field keeps its field, its text and the keyboard across each change; the edit is not ended.
    /// Red on the parent: the rebuild freed the field (the edit's field became a new one, the old one's focus left).
    @MainActor
    func testRetheme891OpenRenameFieldKeepsItsTextAndFocus() throws {
        try withRethemeStore {
            let probes = try rethemeProbes()
            for backing: CGFloat in [1, 2] {
                let (m, key, _) = rethemeModel()
                defer { m.close() }
                let rig = OverlayRig(m, size: CGSize(width: 1000, height: 680), backing: backing)
                defer { rig.close() }
                rig.settle(self)
                let edit = AgentRenameEdit(key: key, text: "api renamed")
                m.openRenameField(edit)
                rethemeSettle(rig)
                let field = try XCTUnwrap(edit.field, "the header draws the Rename field (x\(Int(backing)))")
                // The first responder of a window that is never shown or made key: no keyboard is taken from the human.
                XCTAssertTrue(rig.win.makeFirstResponder(field))
                func focused() -> Bool {
                    rig.win.firstResponder === field || ((rig.win.firstResponder as? NSText)?.delegate as AnyObject?) === field
                }
                XCTAssertTrue(focused(), "x\(Int(backing))")
                for change in rethemeChanges(probes) {
                    let tag = "\(change.name) x\(Int(backing))"
                    change.apply()
                    rethemeSettle(rig)
                    XCTAssertTrue(m.renameEdit === edit, "the edit goes on: \(tag)")
                    XCTAssertTrue(edit.field === field, "the same field: \(tag)")
                    XCTAssertEqual(field.stringValue, "api renamed", "its text: \(tag)")
                    XCTAssertTrue(focused(), "and the keyboard: \(tag)")
                    // Colours and fonts live: the field re-reads them in place (its update runs on the store change).
                    let ink = field.textColor?.usingColorSpace(.sRGB), want = NSColor(Neon.textPrimary).usingColorSpace(.sRGB)
                    XCTAssertEqual(ink?.redComponent ?? -1, want?.redComponent ?? -2, accuracy: 0.01, "the theme's text colour: \(tag)")
                    XCTAssertEqual(field.font?.pointSize ?? 0, sz(15), accuracy: 0.01, "the UI size's font: \(tag)")
                }
                XCTAssertFalse(rig.win.isVisible, "never on screen")
            }
        }
    }

    /// The sidebar's scroll offset is kept to the pixel across the changes at the same UI size.
    /// shortcut: the size change keeps the view and its point offset, not the same top row (left.txt).
    /// Red on the parent: the rebuilt ScrollView started at the top.
    @MainActor
    func testRetheme891SidebarKeepsItsScrollOffset() throws {
        try withRethemeStore {
            let probes = try rethemeProbes()
            for backing: CGFloat in [1, 2] {
                let st = store((0..<40).map { session("api-\($0)", .idle, ago: TimeInterval(60 + $0)) })
                let m = windowModel(st)
                defer { m.close() }
                _ = fakeTerminal(m)
                m.setVisible(true)
                let rig = OverlayRig(m, size: CGSize(width: 720, height: 460), backing: backing)
                defer { rig.close() }
                rethemeSettle(rig)
                let sv = try XCTUnwrap(focusViews(rig.host.view, NSScrollView.self).max {
                    ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
                }, "the sidebar's list (x\(Int(backing)))")
                XCTAssertGreaterThan(sv.documentView?.frame.height ?? 0, sv.contentView.bounds.height + 120, "the list scrolls (x\(Int(backing)))")
                sv.contentView.scroll(to: NSPoint(x: 0, y: 120))
                sv.reflectScrolledClipView(sv.contentView)
                rethemeSettle(rig)
                let y = sv.contentView.bounds.origin.y
                XCTAssertEqual(y, 120, accuracy: 0.5 / backing, "x\(Int(backing))")
                for change in rethemeChanges(probes) where !change.size {
                    let tag = "\(change.name) x\(Int(backing))"
                    change.apply()
                    rethemeSettle(rig)
                    let now = focusViews(rig.host.view, NSScrollView.self)
                    XCTAssertTrue(now.contains { $0 === sv }, "the same scroll view: \(tag)")
                    XCTAssertEqual(sv.contentView.bounds.origin.y, y, accuracy: 0.5 / backing, "the offset to the pixel: \(tag)")
                }
                ThemeStore.shared.setScale(0.85)
                rethemeSettle(rig)
                XCTAssertTrue(focusViews(rig.host.view, NSScrollView.self).contains { $0 === sv }, "a size change keeps it too (x\(Int(backing)))")
            }
        }
    }

    /// The terminal host's own rule, alone (no window, no surface): the first call records, the same generation sends
    /// nothing, a new generation with the same size sends nothing, a new size sends one action.
    @MainActor
    func testRetheme891TerminalHostSendsOneFontActionPerSizeChange() {
        let saved = (ThemeRuntime.scale, Preferences.agentWindowTerminalFontSize)
        defer { ThemeRuntime.scale = saved.0; Preferences.agentWindowTerminalFontSize = saved.1 }
        Preferences.agentWindowTerminalFontSize = nil
        ThemeRuntime.scale = 1
        let c = AgentTerminalController()
        var actions: [String] = []
        c.fontAction = { _, a in actions.append(a) }
        let v = AgentTerminalHostView(frame: .zero)
        v.owner = c
        v.retheme(10)
        v.retheme(10)
        v.retheme(11)
        XCTAssertEqual(actions, [], "a theme change at the same size: no font action")
        ThemeRuntime.scale = 0.85
        v.retheme(11)
        XCTAssertEqual(actions, [], "the same generation: nothing")
        v.retheme(12)
        XCTAssertEqual(actions, ["set_font_size:\(Float(12 * 0.85 as CGFloat))"])
        v.retheme(13)
        XCTAssertEqual(actions.count, 1, "once")
        XCTAssertEqual(v.fontShown ?? 0, Double(12 * 0.85 as CGFloat), accuracy: 0.0001)
    }
}
