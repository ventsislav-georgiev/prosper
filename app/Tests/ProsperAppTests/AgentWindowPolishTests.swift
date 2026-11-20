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
        m.toggleCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID))
        m.setCollapsed("History", true)
        XCTAssertEqual(Preferences.defaults.stringArray(forKey: pref), ["History", "group:sidekicks"], "written through Preferences.defaults")
        let next = windowModel(nil)
        XCTAssertTrue(next.isCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID)) && next.isCollapsed("History"), "a new window (or a relaunch) reads it back")
        XCTAssertFalse(next.isCollapsed("Sessions"))
        next.toggleCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID))
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
        m.setCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID), true)
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
        m.setCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID), true)
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
            let size = CGSize(width: AgentWindowModel.fullSidebarWidth, height: 420 * scale)
            let open = try render(AgentSidebarView(model: m).background(Neon.sidebar), size: size, dark: true)
            try save(open, "828-sidebar-open-\(scale)")
            m.setCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID), true)
            let rep = try render(AgentSidebarView(model: m).background(Neon.sidebar), size: size, dark: true)
            try save(rep, "828-sidebar-folded-\(scale)")
            XCTAssertLessThan(ink(rep), ink(open) - 40, "folding hides the two Sidekick rows at \(scale)")
            XCTAssertEqual(overflow(rep, content: size, canvas: CGSize(width: size.width + 24, height: size.height + 24)), 0)
            m.setCollapsed(AgentSidebar.groupFold(SessionGroup.sidekicksID), false)
        }
    }

    // MARK: Fixed sizes

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

    /// Review round (s7): the age sits in a fixed slot, so its ticking never changes what the
    /// title gets: the row's ideal width (title + slot) and the title's room are the same for
    /// every age. #1268 (R2): the slot ends line two; the title never depends on the age, and nothing on line two
    /// before the slot moves when the age changes.
    @MainActor
    func testAgentWindowSidebarAgeSlotKeepsTheTitleWidth() throws {
        let savedScale = ThemeRuntime.scale
        defer { ThemeRuntime.scale = savedScale }
        // #1268 (R2): a Claude row with both badges, so line two has something before the age slot that could move.
        func row(_ age: String) -> AgentSidebar.Row {
            AgentSidebar.Row(id: live("x"), title: "a long session title that truncates in the sidebar", state: .working,
                             detail: "Working", age: age, prs: [], modelSlot: true, model: "Opus 5.5", effort: "high")
        }
        let ages = ["now", "1m", "10m", "59m", "120d"]
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            var ideal: Set<Int> = [], edges: Set<Int> = [], reps: [NSBitmapImageRep] = []
            let ageSlot = NSHostingView(rootView: AgentSidebarRowView(row: row("now"), selected: false).ageSlot.fixedSize())
                .fittingSize.width
            for age in ages {
                let v = AgentSidebarRowView(row: row(age), selected: false)
                ideal.insert(Int((NSHostingView(rootView: v.fixedSize()).fittingSize.width * 2).rounded()))
                // Rendered at the sidebar's row width: the rightmost ink of the title line left of
                // the age slot is where the truncated title ends.
                let size = CGSize(width: AgentWindowModel.fullSidebarWidth - sz(16), height: sz(50))
                let rep = try render(v, size: size, dark: true)
                try save(rep, "828-row-age-\(age)-\(scale)")
                let k = CGFloat(rep.pixelsWide) / (size.width + 24)
                // #1268 (R2): line one carries no age (it ends with the chip's room), so its whole width is read (was:
                // left of a "00m" slot there).
                let limit = Int(size.width * k)
                reps.append(rep)
                var last = 0
                for y in Int(sz(8) * k)..<Int(sz(24) * k) {
                    autoreleasepool {   // #1083: colorAt's NSColors drained per row
                        for x in 0..<limit {
                            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            if c.redComponent + c.greenComponent + c.blueComponent > 1.2 { last = max(last, x) }
                        }
                    }
                }
                XCTAssertGreaterThan(last, 0, "found the title (\(age) \(scale))")
                edges.insert(last)
            }
            XCTAssertEqual(ideal.count, 1, "the row's width does not follow the age at \(scale): \(ideal)")
            XCTAssertEqual(edges.count, 1, "the title ends at the same pixel for every age at \(scale): \(edges)")
            // #1268 (R2): left of the age slot (the last thing on line two) every pixel is the same for "now" and every
            // other age, "120d" included: the badges and the state text never move. #1345: the age ends sz(10) + the chip's
            // column and its gap sz(8) inside the row's edge (was sz(10)); the column as a fittingSize is at most 1.3 pt over
            // its frame, which only moves this bound left, off the age.
            guard let first = reps.first else { return XCTFail("no render (\(scale))") }
            let column = NSHostingView(rootView: AgentSidebarRowView.digitColumn.fixedSize()).fittingSize.width
            let left = Int((AgentWindowModel.fullSidebarWidth - sz(16) - sz(10) - sz(8) - column - ageSlot - 1) * CGFloat(first.pixelsWide) / (AgentWindowModel.fullSidebarWidth - sz(16) + 24))
            for (age, rep) in zip(ages, reps).dropFirst() {
                var diff = 0
                for y in 0..<min(rep.pixelsHigh, first.pixelsHigh) {
                    autoreleasepool {   // #1083: colorAt's NSColors drained per row
                        for x in 0..<left {
                            guard let a = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                                  let b = first.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                                + abs(a.blueComponent - b.blueComponent) > 0.02 { diff += 1 }
                        }
                    }
                }
                XCTAssertEqual(diff, 0, "nothing before the age slot moves, \"now\" against \"\(age)\" at \(scale)")
            }
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
