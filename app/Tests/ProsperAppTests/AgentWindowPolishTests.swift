import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #828: folding sidebar sections (remembered per Mac), a fixed Send/Interrupt column and the
/// other state-driven size changes, and pasted_content wrappers in user turns. Offscreen only:
/// nothing is shown, key events go to a never-shown window, no event is posted.
extension AgentWindowD1Tests {

    // MARK: Folded sections

    func live(_ name: String) -> AgentSidebar.RowID { .live(AgentSessionKey(dir: "/tmp/dch-test", name: name)) }

    @MainActor
    func foldStore() -> AgentIslandStore {
        store([session("a", .working, ago: 10), session("b", .idle, ago: 20),
               session("qa-1", .working, ago: 30), session("qa-2", .idle, ago: 40)],
              history: [record("old", ago: 7200)], pattern: "qa-")
    }

    @MainActor
    func testAgentWindowFoldedSectionsPersistPerMac() {
        let pref = "agentWindowCollapsedSections"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        Preferences.defaults.removeObject(forKey: pref)
        XCTAssertEqual(windowModel(nil).collapsed, [], "unset: nothing folded")
        let m = windowModel(nil)
        m.toggleCollapsed("Sidekicks")
        m.setCollapsed("History", true)
        XCTAssertEqual(Preferences.defaults.stringArray(forKey: pref), ["History", "Sidekicks"], "written through Preferences.defaults")
        let next = windowModel(nil)
        XCTAssertTrue(next.isCollapsed("Sidekicks") && next.isCollapsed("History"), "a new window (or a relaunch) reads it back")
        XCTAssertFalse(next.isCollapsed("Sessions"))
        next.toggleCollapsed("Sidekicks")
        XCTAssertEqual(windowModel(nil).collapsed, ["History"], "unfolding is remembered too")
        m.setCollapsed(AgentSidebar.needsYouTitle, true)
        XCTAssertFalse(windowModel(nil).isCollapsed(AgentSidebar.needsYouTitle), "Needs you never folds")
        Preferences.defaults.set([AgentSidebar.needsYouTitle], forKey: pref)
        XCTAssertFalse(windowModel(nil).isCollapsed(AgentSidebar.needsYouTitle), "not even from a stored value")
        XCTAssertFalse(SyncedKeys.isSynced(pref), "per Mac, not synced")
    }

    @MainActor
    func testAgentWindowFoldedSectionKeepsTheSelectionAndArrowsSkipIt() {
        let pref = "agentWindowCollapsedSections"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        Preferences.defaults.removeObject(forKey: pref)
        let m = windowModel(foldStore())
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(m.sections.map(\.title), ["Sessions", "Sidekicks", "History"])
        m.select(live("qa-1"))
        m.setCollapsed("Sidekicks", true)
        XCTAssertEqual(m.selection, live("qa-1"), "folding its section keeps the selection")
        XCTAssertEqual(m.selectedRow?.session?.key.name, "qa-1", "and its conversation")
        XCTAssertEqual(m.sections.first { $0.title == "Sidekicks" }?.rows.count, 2, "the count stays")
        m.refresh()
        XCTAssertEqual(m.selection, live("qa-1"), "a sidebar rebuild keeps it too")
        m.move(1)
        XCTAssertEqual(m.selection, .history(AgentSessionKey(dir: "/tmp/dch-test", name: "old")),
                       "down from a folded selection goes to the next shown row, not qa-2")
        m.move(-1)
        XCTAssertEqual(m.selection, live("b"), "up from below never lands in a folded section")
        // Left / right fold and unfold the selection's section, through the window's keys.
        let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.model = m
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: win.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: code)!
        }
        XCTAssertTrue(AgentsNSWindow.handle(key(123), m))
        XCTAssertTrue(m.isCollapsed("Sessions"), "left folds")
        XCTAssertEqual(m.selection, live("b"))
        XCTAssertFalse(AgentsNSWindow.handle(key(124, .command), m), "a modified arrow passes through")
        XCTAssertTrue(m.isCollapsed("Sessions"))
        XCTAssertTrue(AgentsNSWindow.handle(key(124), m))
        XCTAssertFalse(m.isCollapsed("Sessions"), "right unfolds")
        XCTAssertFalse(win.isVisible, "never shown")
        // The selection ending while folded: nothing selected, no crash.
        m.setCollapsed("Sidekicks", true)
        m.select(live("qa-2"))
        m.store?.sessions.removeAll { $0.key.name == "qa-2" }
        XCTAssertNil(m.selection)
    }

    @MainActor
    func testAgentWindowFirstFillPicksTheFirstShownRow() {
        let pref = "agentWindowCollapsedSections"
        let saved = Preferences.defaults.object(forKey: pref)
        defer { Preferences.defaults.set(saved, forKey: pref) }
        Preferences.defaults.set(["Sessions"], forKey: pref)
        let m = windowModel(foldStore())
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(m.selection, live("qa-1"), "Sessions folded: the first Sidekick")
        Preferences.defaults.set(["Sessions", "Sidekicks", "History"], forKey: pref)
        let all = windowModel(foldStore())
        all.setVisible(true)
        defer { all.close() }
        XCTAssertNil(all.selection, "everything folded: the hint, never a hidden row")
        all.move(1)
        XCTAssertNil(all.selection, "nothing shown to move to")
    }

    @MainActor
    func testAgentWindowRendersFoldedSidebarOffscreen() throws {
        let pref = "agentWindowCollapsedSections"
        let saved = Preferences.defaults.object(forKey: pref)
        let savedScale = ThemeRuntime.scale
        defer { Preferences.defaults.set(saved, forKey: pref); ThemeRuntime.scale = savedScale }
        Preferences.defaults.removeObject(forKey: pref)
        let m = windowModel(foldStore())
        m.setVisible(true)
        defer { m.close() }
        m.select(live("qa-1"))
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            let size = CGSize(width: sz(290), height: 420 * scale)
            let open = try render(AgentSidebarView(model: m).background(Neon.sidebar), size: size, dark: true)
            try save(open, "828-sidebar-open-\(scale)")
            m.setCollapsed("Sidekicks", true)
            let rep = try render(AgentSidebarView(model: m).background(Neon.sidebar), size: size, dark: true)
            try save(rep, "828-sidebar-folded-\(scale)")
            XCTAssertLessThan(ink(rep), ink(open) - 40, "folding hides the two Sidekick rows at \(scale)")
            XCTAssertEqual(overflow(rep, content: size, canvas: CGSize(width: size.width + 24, height: size.height + 24)), 0)
            m.setCollapsed("Sidekicks", false)
        }
    }

    // MARK: Fixed sizes

    @MainActor
    func testAgentWindowInputColumnAndFieldKeepTheirWidthAcrossStates() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        let key = AgentSessionKey(dir: "/tmp/dch-test", name: "a")
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            let width = 640 * scale - sz(290) - 1
            var edges: [AgentState: Int] = [:]
            for state in AgentState.allCases {
                let i = AgentWindowInteraction()
                let s = AgentSession(key: key, alias: "", activity: 1, state: state, agents: 0)
                i.follow(s)
                i.draft = "Run the suite"   // same text in every state: the placeholder never differs
                let pane = AgentInteractionPane(model: i, session: s, open: {})
                let h = NSHostingView(rootView: pane.frame(width: width)).fittingSize.height
                let rep = try render(pane, size: CGSize(width: width, height: h), dark: true)
                try save(rep, "828-input-\(state)-\(scale)")
                // The field's right edge: scanning a row inside the field below its text.
                let sx = CGFloat(rep.pixelsWide) / (width + 24), y = Int((h - sz(10) - sz(8)) * sx)
                let x0 = Int((sz(16) + sz(12)) * sx)
                let inside = try XCTUnwrap(rep.colorAt(x: x0, y: y)?.usingColorSpace(.sRGB))
                var x = x0
                while x < rep.pixelsWide, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      abs(c.redComponent - inside.redComponent) + abs(c.greenComponent - inside.greenComponent)
                          + abs(c.blueComponent - inside.blueComponent) < 0.05 { x += 1 }
                XCTAssertLessThan(x, rep.pixelsWide, "found the field's edge (\(state) \(scale))")
                edges[state] = x
                // And the column takes only its own width: the field ends one spacing before it.
                let column = NSHostingView(rootView: AgentSendColumn(canInterrupt: true, canSend: true, interrupt: {}, send: {})
                    .fixedSize()).fittingSize.width
                XCTAssertEqual(CGFloat(x) / sx, width - sz(16) - column - sz(8), accuracy: 2,
                               "the field fills all but the button column (\(state) \(scale))")
            }
            XCTAssertEqual(Set(edges.values).count, 1, "the field's width is the same working and idle at \(scale): \(edges)")
        }
    }

    /// The leftmost and rightmost drawn pixel of row `y` (points) of `rep`, on a black canvas.
    func extent(_ rep: NSBitmapImageRep, y: CGFloat, canvasWidth: CGFloat) -> ClosedRange<Int>? {
        let k = CGFloat(rep.pixelsWide) / canvasWidth, row = Int(y * k)
        let xs = (0..<rep.pixelsWide).filter { x in
            guard let c = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent + c.greenComponent + c.blueComponent > 0.12
        }
        guard let a = xs.first, let b = xs.last else { return nil }
        return a...b
    }

    @MainActor
    func testAgentWindowSendAndInterruptAreOneFixedEqualColumn() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            func size<V: View>(_ v: V) -> CGSize { NSHostingView(rootView: v.fixedSize()).fittingSize }
            let send = AgentPillButton(title: "Send", icon: "arrow.up", tint: Neon.blue) {}
            let stop = AgentPillButton(title: "Interrupt", icon: "stop.fill", tint: Neon.magenta) {}
            XCTAssertLessThan(size(send).width, size(stop).width, "the labels differ, so equal slots are a layout choice")
            var widths: Set<Int> = []
            for (i, on) in [(true, false), (false, true), (false, false), (true, true)].enumerated() {
                let col = AgentSendColumn(canInterrupt: on.0, canSend: on.1, interrupt: {}, send: {})
                let c = size(col)
                widths.insert(Int((c.width * 2).rounded()))
                XCTAssertEqual(c.width, size(stop).width, accuracy: 0.5, "the column is the wider button's width at \(scale)")
                let rep = try render(col, size: c, dark: true)
                try save(rep, "828-send-column-\(i)-\(scale)")
                // Both capsules span the same pixels: one quarter down is Interrupt, three quarters Send.
                let top = try XCTUnwrap(extent(rep, y: c.height / 4, canvasWidth: c.width + 24))
                let bottom = try XCTUnwrap(extent(rep, y: c.height * 3 / 4, canvasWidth: c.width + 24))
                XCTAssertLessThanOrEqual(abs(top.lowerBound - bottom.lowerBound) + abs(top.upperBound - bottom.upperBound), 1,
                                         "Interrupt and Send are the same width (\(on) at \(scale)): \(top) \(bottom)")
            }
            XCTAssertEqual(widths.count, 1, "no state changes the column at \(scale)")
            // The state chip's slot is the widest state's, whichever state it shows.
            let chips = AgentState.allCases.map { size(AgentStateChip(state: $0)).width }
            XCTAssertEqual(Set(chips.map { Int(($0 * 2).rounded()) }).count, 1, "state chip slot fixed at \(scale): \(chips)")
        }
    }

    /// Review round (s7): the age sits in a fixed slot, so its ticking never changes what the
    /// title gets: the row's ideal width (title + slot) and the title's room are the same for
    /// every age.
    @MainActor
    func testAgentWindowSidebarAgeSlotKeepsTheTitleWidth() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        func row(_ age: String) -> AgentSidebar.Row {
            AgentSidebar.Row(id: live("x"), title: "a long session title that truncates in the sidebar", state: .working,
                             detail: "Working", age: age, prs: [])
        }
        let ages = ["now", "1m", "10m", "59m"]
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            var ideal: Set<Int> = [], edges: Set<Int> = []
            for age in ages {
                let v = AgentSidebarRowView(row: row(age), selected: false)
                ideal.insert(Int((NSHostingView(rootView: v.fixedSize()).fittingSize.width * 2).rounded()))
                // Rendered at the sidebar's row width: the rightmost ink of the title line left of
                // the age slot is where the truncated title ends.
                let size = CGSize(width: sz(290) - sz(16), height: sz(50))
                let rep = try render(v, size: size, dark: true)
                try save(rep, "828-row-age-\(age)-\(scale)")
                let k = CGFloat(rep.pixelsWide) / (size.width + 24)
                let slot = NSHostingView(rootView: Text("00m").font(Neon.font(10).monospacedDigit()).fixedSize()).fittingSize.width
                let limit = Int((size.width - sz(10) - slot - sz(2)) * k)
                var last = 0
                for y in Int(sz(8) * k)..<Int(sz(24) * k) {
                    for x in 0..<limit {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if c.redComponent + c.greenComponent + c.blueComponent > 1.2 { last = max(last, x) }
                    }
                }
                XCTAssertGreaterThan(last, 0, "found the title (\(age) \(scale))")
                edges.insert(last)
            }
            XCTAssertEqual(ideal.count, 1, "the row's width does not follow the age at \(scale): \(ideal)")
            XCTAssertEqual(edges.count, 1, "the title ends at the same pixel for every age at \(scale): \(edges)")
        }
    }

    // MARK: pasted_content

    func pasted(_ id: String, _ body: String) -> String {
        "<pasted_content id=\"\(id)\">\n\(body)\n</pasted_content id=\"\(id)\">"
    }

    func userText(_ content: Any, cap: Int = 100_000) -> String? {
        let e = TranscriptDecoder.decode(line: line(entry("user", ["message": ["role": "user", "content": content]])), cap: cap)
        for item in e.items { if case .block(.user(let c), _) = item { return c.text } }
        return nil
    }

    func testAgentWindowUserTurnDropsPastedContentWrappers() {
        let two = "Look at this:\n" + pasted("k3x9", "line one\nline two") + "\nand this " + pasted("Q7_z", "$1 \\1 <b>") + " thanks"
        let want = "Look at this:\nline one\nline two\nand this $1 \\1 <b> thanks"
        XCTAssertEqual(userText(two), want, "string content: both pastes, text around them kept, no tags")
        XCTAssertEqual(userText([["type": "text", "text": two]]), want, "text parts too")
        XCTAssertEqual(userText(pasted("ab12", "only a paste")), "only a paste")
        for s in [userText(two) ?? "", userText([["type": "text", "text": two]]) ?? ""] {
            XCTAssertFalse(s.contains("pasted_content") || s.contains("k3x9") || s.contains("Q7_z"), "never the tag or its id: \(s)")
        }
        // A prompt typed while the agent worked (queued_command) is the user's too.
        let queued = entry("attachment", ["attachment": ["type": "queued_command", "prompt": pasted("zz01", "queued paste")]])
        let q = TranscriptDecoder.decode(line: line(queued)).items.compactMap { item -> String? in
            if case .block(.user(let c), _) = item { return c.text } else { return nil }
        }
        XCTAssertEqual(q, ["queued paste"])
        // Lazy expand re-reads the line: the clipped text is a prefix of the unwrapped whole.
        let long = pasted("lz01", String(repeating: "x", count: 50))
        let l = line(entry("user", ["message": ["role": "user", "content": long]]))
        guard case .block(.user(let clip), _)? = TranscriptDecoder.decode(line: l, cap: 10).items.first else {
            return XCTFail("no user block")
        }
        XCTAssertEqual(clip.text, String(repeating: "x", count: 10))
        XCTAssertEqual(TranscriptDecoder.fullText(line: l, clip: clip), String(repeating: "x", count: 50))
    }

    func testAgentWindowUnknownPastedShapesStayAsWritten() {
        let shapes = [
            "<pasted_content id=\"ab12\">\nno closer",
            "<pasted_content id=\"ab12\">\nbody\n</pasted_content id=\"cd34\">",
            "<pasted_content id=\"ab12\" kind=\"x\">\nbody\n</pasted_content id=\"ab12\">",
            "<pasted_content>\nbody\n</pasted_content>",
            "Mentions <pasted_content id=\"…\"> in prose",
        ]
        for s in shapes { XCTAssertEqual(userText(s), s, "fail open: \(s)") }
        XCTAssertEqual(TranscriptDecoder.unwrapPasted("plain text"), "plain text")
    }
}
