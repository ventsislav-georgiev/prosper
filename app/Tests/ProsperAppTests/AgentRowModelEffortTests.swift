import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1203: the model and effort of a session's last answer on its Agent Sessions sidebar row: the row's fields, the
/// fixed slot (same size with and without a value at UI scale 0.7, 0.85 and 1.0), the narrow variant without it and
/// the row's VoiceOver label. Model ids are made up in the documented shape. Offscreen only: views are measured or
/// hosted in windows that are never shown; no event is posted.
final class AgentRowModelEffortTests: XCTestCase {

    static let now: TimeInterval = 1_800_000_000
    static let dir = "/tmp/dch-test"
    static let scales: [CGFloat] = [0.7, 0.85, 1.0]

    /// A live session; `path` nil is a Codex or shell session (dch sets the transcript path with a Claude only).
    func session(_ name: String, _ state: AgentState = .idle, model: String? = nil, effort: String? = nil,
                 path: String? = "/Users/example/t/api.jsonl", ago: TimeInterval = 240) -> AgentSession {
        var s = AgentSession(key: AgentSessionKey(dir: Self.dir, name: name), alias: "", activity: Self.now - ago,
                             state: state, agents: 0, transcriptPath: path)
        s.model = model
        s.effort = effort
        return s
    }

    func row(_ s: AgentSession) -> AgentSidebar.Row { AgentSidebar.row(s, details: .all, now: Self.now) }

    func history(_ name: String) -> AgentSidebar.Row {
        var r = DchHistoryRecord(key: AgentSessionKey(dir: Self.dir, name: name))
        r.cwd = "/Users/example/\(name)"
        r.ended = Self.now - 7200
        r.updated = Self.now - 7200
        r.end = "exit 0"
        return AgentSidebar.row(r, now: Self.now)
    }

    /// The scale through the test's own seam, put back after.
    @MainActor
    func atScales(_ body: (CGFloat) throws -> Void) rethrows {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale in Self.scales {
            ThemeRuntime.scale = scale
            try body(scale)
        }
    }

    @MainActor
    func ideal<V: View>(_ v: V) -> CGSize { NSHostingView(rootView: v.fixedSize()).fittingSize }

    /// The text column of a row `width` wide: padding 10 each side, the glyph slot 14, its gap 8.
    @MainActor
    func column(_ width: CGFloat) -> CGFloat { width - 2 * sz(10) - sz(14) - sz(8) }

    // MARK: The fields

    func testModelEffortRowFieldsAndSlotText() {
        let both = row(session("api", model: "claude-fable-9-2-20991231", effort: "high"))
        XCTAssertEqual([both.model, both.effort], ["Fable 9.2", "high"])
        XCTAssertTrue(both.modelSlot)
        XCTAssertEqual(both.modelText, "Fable 9.2 · high")
        XCTAssertEqual(both.modelWords, "model Fable 9.2, effort high")

        let only = row(session("api", model: "claude-fable-9"))
        XCTAssertEqual(only.modelText, "Fable 9")
        XCTAssertEqual(only.modelWords, "model Fable 9")
        XCTAssertTrue(only.effort == nil)

        // Another shape: shown as given (the view cuts it in the middle).
        XCTAssertEqual(row(session("api", model: "claude-fixture-model", effort: "max")).modelText, "claude-fixture-model · max")

        for (tag, r) in [("unknown", row(session("api"))),
                         ("effort without a model", row(session("api", effort: "high")))] {
            XCTAssertTrue(r.modelSlot, "\(tag): a Claude row keeps the slot")
            XCTAssertTrue(r.model == nil && r.effort == nil, "\(tag): no value")
            XCTAssertEqual(r.modelText, "", tag)
            XCTAssertTrue(r.modelWords == nil, tag)
        }
        for (tag, r) in [("codex or shell", row(session("api", model: "claude-fable-9-2", effort: "high", path: nil))),
                         ("history", history("api-old"))] {
            XCTAssertFalse(r.modelSlot, "\(tag): no slot")
            XCTAssertTrue(r.model == nil && r.effort == nil, tag)
            XCTAssertEqual(r.modelText, "", tag)
        }
    }

    // MARK: The fixed slot

    /// The slot and the line keep their width, and the row its height, with and without a value, at every scale;
    /// the slot fits every value of the documented shape whole; Codex, shell and History rows have no slot.
    @MainActor
    func testModelEffortSlotKeepsItsSizeAtEveryScale() {
        let long = "claude-" + String(repeating: "w", count: 90)
        let claude = [row(session("api", model: "claude-fable-9-2-20991231", effort: "medium")),
                      row(session("api", model: "claude-fable-9-2")),
                      row(session("api")),
                      row(session("api", model: long, effort: "xhigh"))]
        let none = [row(session("api", model: "claude-fable-9-2", effort: "high", path: nil)), history("api")]
        atScales { scale in
            let slots = claude.map { ideal(AgentSidebarRowView(row: $0, selected: false).modelSlotView) }
            let lines = claude.map { ideal(AgentSidebarRowView(row: $0, selected: false, number: 4)
                .detailLine([], chipSlot: true, modelSlot: true)) }
            for (i, r) in claude.enumerated() {
                XCTAssertEqual(slots[i].width, slots[0].width, accuracy: 0.01, "slot width, \(r.modelText) (\(scale))")
                XCTAssertEqual(slots[i].height, slots[0].height, accuracy: 0.01, "slot height, \(r.modelText) (\(scale))")
                XCTAssertEqual(lines[i].width, lines[0].width, accuracy: 0.01, "line width, \(r.modelText) (\(scale))")
                for width in [sz(274), sz(110)] {
                    let h = NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false, number: 4).frame(width: width))
                        .fittingSize.height
                    let plain = NSHostingView(rootView: AgentSidebarRowView(row: none[0], selected: false, number: 4)
                        .frame(width: width)).fittingSize.height
                    XCTAssertEqual(h, plain, accuracy: 0.01, "row height, \(r.modelText) at \(width) (\(scale))")
                }
            }
            XCTAssertGreaterThan(slots[0].width, sz(40), "the slot has room (\(scale))")
            for text in ["Fable 9.2 · medium", "Fable 9.2 · xhigh", "Opus 9.9 · medium", AgentSidebarRowView.modelWidest] {
                XCTAssertLessThanOrEqual(ideal(Text(text).font(Neon.font(10))).width, slots[0].width + 0.01,
                                         "\(text) fits the slot whole (\(scale))")
            }
            for r in none {
                let v = AgentSidebarRowView(row: r, selected: false)
                XCTAssertEqual(ideal(v.detailLine([], modelSlot: true)).width, ideal(v.detailLine([])).width, accuracy: 0.01,
                               "\(r.title): no slot (\(scale))")
            }
            let v = AgentSidebarRowView(row: claude[2], selected: false)
            XCTAssertGreaterThanOrEqual(ideal(v.detailLine([], modelSlot: true)).width,
                                        ideal(v.detailLine([])).width + slots[0].width, "a Claude row has the slot (\(scale))")
        }
    }

    // MARK: Real frames and the variants, from the real accessibility tree

    /// `label` is the element's label, or its value when it has none (a static text reads its string as its value).
    struct AX { let label: String, frame: CGRect }

    @MainActor
    func axWalk(_ e: Any, _ out: inout [AX], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        let frame = o.responds(to: Selector(("accessibilityFrame")))
            ? (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero : .zero
        let label = text("accessibilityLabel")
        out.append(AX(label: label.isEmpty ? text("accessibilityValue") : label, frame: frame))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { axWalk(k, &out, depth: depth + 1) }
    }

    /// The real accessibility tree of `view` in a never-shown window (built once this process asks, as an AX client's
    /// attribute write would; both attributes are put back after), walked until `done` holds, with a ceiling.
    @MainActor
    func tree<V: View>(_ view: V, _ size: CGSize, until done: ([AX]) -> Bool) -> [AX] {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
        var out: [AX] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            out = []
            axWalk(host, &out)
        } while !done(out) && Date() < deadline
        XCTAssertFalse(win.isVisible, "never shown")
        return out
    }

    /// The second line as the row draws it, at the sidebar's width: the state text starts at the same x with a value,
    /// without one and on a row with no slot (nothing is added to the stack's spacing); the value is drawn whole, at
    /// the same trailing edge for both texts; at a narrow row the last variant keeps the state text whole, no slot.
    @MainActor
    func testModelEffortSecondLineKeepsItsStartAndTheNarrowVariant() {
        let rows = [row(session("api", model: "claude-fable-9-2-20991231", effort: "high")),
                    row(session("api", model: "claude-fable-9-2")),
                    row(session("api")),
                    row(session("api", path: nil))]
        atScales { scale in
            var starts: [CGFloat] = [], ends: [CGFloat] = []
            for r in rows {
                let width = column(sz(274))
                let t = tree(AgentSidebarRowView(row: r, selected: false, number: 4).detailVariants
                    .frame(width: width, alignment: .leading), CGSize(width: width, height: sz(30))) { t in
                    t.contains { $0.label == "Idle" } && (r.modelText.isEmpty || t.contains { $0.label == r.modelText })
                }
                guard let state = t.first(where: { $0.label == "Idle" }) else {
                    XCTFail("state text (\(scale)) in \(t.map(\.label).filter { !$0.isEmpty })"); continue
                }
                XCTAssertGreaterThan(state.frame.width, 0)
                starts.append(state.frame.minX)
                guard !r.modelText.isEmpty else { continue }
                guard let value = t.first(where: { $0.label == r.modelText }) else {
                    XCTFail("\(r.modelText) drawn at the sidebar's width (\(scale))"); continue
                }
                XCTAssertGreaterThanOrEqual(value.frame.width + 0.5, ideal(Text(r.modelText).font(Neon.font(10))).width,
                                            "\(r.modelText) whole (\(scale))")
                XCTAssertGreaterThan(value.frame.minX, state.frame.maxX, "trailing (\(scale))")
                ends.append(value.frame.maxX)
            }
            XCTAssertEqual(starts.count, rows.count)
            for x in starts { XCTAssertEqual(x, starts.first ?? -1, accuracy: 0.5, "the line starts at the same x: \(starts) (\(scale))") }
            XCTAssertEqual(ends.count, 2)
            XCTAssertEqual(ends.first ?? -1, ends.last ?? -2, accuracy: 0.5, "same trailing edge: \(ends) (\(scale))")

            // Narrow: the last variant, no slot, the state text whole. sz(120), not sz(110): at 0.7 the last variant (text +
            // its spacing before the Spacer, 48 pt) does not fit sz(110)'s 47.6 pt column and cuts the text 1 pt, today too.
            let narrow = row(session("api", .blocked, model: "claude-fable-9-2", effort: "high"))
            let width = column(sz(120))
            let t = tree(AgentSidebarRowView(row: narrow, selected: false, number: 4).detailVariants
                .frame(width: width, alignment: .leading), CGSize(width: width, height: sz(30))) { t in
                t.contains { $0.label == "Needs input" }
            }
            let state = t.first { $0.label == "Needs input" }
            // 1 pt: the ideal is a fittingSize (whole points, rounded up); the AX frame is not (0.7 read 44.0 for 45).
            // A cut text is far narrower: the slot variant leaves it under half its width here.
            XCTAssertGreaterThanOrEqual((state?.frame.width ?? 0) + 1, ideal(Text("Needs input").font(Neon.font(10.5))).width,
                                        "the state text whole at a narrow row (\(scale))")
            XCTAssertFalse(t.contains { $0.label.contains("Fable") }, "no slot at a narrow row (\(scale))")
        }
    }

    /// A blocked Claude row with two PR chips, 3 agents and 192 merged (`busy`), or none of them; `claude` false is the
    /// same row without the slot (what the row draws today).
    func busy(_ withPRs: Bool, claude: Bool = true) -> AgentSidebar.Row {
        let s = session("web", .blocked, model: "claude-fable-9-2", effort: "high")
        var r = AgentSidebar.Row(id: .live(s.key), title: s.title, state: s.state, detail: "Needs input", age: "",
                                 prs: withPRs ? ["api#1", "api#2"] : [], prCount: withPRs ? 2 : 0, agents: withPRs ? 3 : 0,
                                 merged: withPRs ? 192 : 0, session: s, modelSlot: true, model: "Fable 9.2", effort: "high")
        r.modelSlot = claude
        return r
    }

    /// Which variant a row takes at which width: the seven variants' ideal widths (the first that fits the text column
    /// is taken), printed for the report. Each with-slot variant is wider than its twin without; today's four are in
    /// their descending order. A plain row shows the slot and the ⌘ chip at the sidebar's width.
    @MainActor
    func testModelEffortVariantWidths() {
        let r = busy(true)
        atScales { scale in
            let v = AgentSidebarRowView(row: r, selected: false, number: 4)
            let widths = [ideal(v.detailLine(r.prs, chipSlot: true, modelSlot: true)).width,
                          ideal(v.detailLine(r.prs, chipSlot: true)).width,
                          ideal(v.detailLine([], open: r.prCount, chipSlot: true, modelSlot: true)).width,
                          ideal(v.detailLine([], open: r.prCount, chipSlot: true)).width,
                          ideal(v.detailLine([], chipSlot: true, modelSlot: true)).width,
                          ideal(v.detailLine([], chipSlot: true)).width,
                          ideal(v.detailLine([])).width]
            XCTAssertEqual(widths.count, 7)
            // As row widths: the variant is taken from this row width up (until one before it fits).
            let rowWidths = widths.map { ($0 + 2 * sz(10) + sz(14) + sz(8)).rounded(.up) }
            print("MODEL1203-WIDTHS scale \(scale) sidebarRow \(sz(274)) column \(column(sz(274))) "
                  + "variantIdeal \(widths.map { ($0 * 10).rounded() / 10 }) fromRowWidth \(rowWidths)")
            for i in [0, 2, 4] {
                XCTAssertGreaterThan(widths[i], widths[i + 1], "with-slot variant \(i + 1) wider than its twin (\(scale))")
            }
            for (a, b) in [(1, 3), (3, 5), (5, 6)] {
                XCTAssertGreaterThan(widths[a], widths[b], "today's variants in their order: \(a + 1) > \(b + 1) (\(scale))")
            }
            XCTAssertLessThanOrEqual(ideal(AgentSidebarRowView(row: busy(false), selected: false, number: 4)
                .detailLine([], chipSlot: true, modelSlot: true)).width, column(sz(274)),
                                     "a plain row keeps the slot and the ⌘ chip at the sidebar's width (\(scale))")
        }
    }

    /// On the real tree, at a literal list of row widths and every scale: the Claude row's second line shows every
    /// label the same row without the slot shows (the model text aside), its state text at the same x. Pinned as today:
    /// at sz(274) the busy row keeps its open-PR count and its ⌘4 chip with no model text, the plain row has both; at
    /// sz(220) the busy row keeps its ⌘4 chip (today's chip-only variant).
    @MainActor
    func testModelEffortSlotNeverDisplacesWhatTheRowShowsToday() {
        let widths: [CGFloat] = [110, 180, 220, 274, 400]
        atScales { scale in
            for w in widths {
                let width = sz(w)
                for withPRs in [true, false] {
                    @MainActor func line(_ r: AgentSidebar.Row) -> [AX] {
                        tree(AgentSidebarRowView(row: r, selected: false, number: 4).detailVariants
                            .frame(width: column(width), alignment: .leading), CGSize(width: column(width), height: sz(30))) { t in
                            t.contains { $0.label == "Needs input" } && (!withPRs || t.contains { $0.label == "3 agents" })
                        }
                    }
                    let claude = line(busy(withPRs)), today = line(busy(withPRs, claude: false))
                    let tag = "\(withPRs ? "busy" : "plain") at \(w) (\(scale))"
                    let slotShown = claude.contains { $0.label == "Fable 9.2 · high" }
                    func labels(_ t: [AX]) -> Set<String> { Set(t.map(\.label).filter { !$0.isEmpty && $0 != "Fable 9.2 · high" }) }
                    XCTAssertEqual(labels(claude), labels(today), "the slot takes nothing away: \(tag)")
                    XCTAssertFalse(today.contains { $0.label.contains("Fable") }, "no slot without modelSlot: \(tag)")
                    let x = [claude, today].map { $0.first { $0.label == "Needs input" }?.frame.minX ?? -100 }
                    XCTAssertEqual(x.first ?? -1, x.last ?? -2, accuracy: 0.5, "state text at the same x: \(tag)")
                    print("MODEL1203-TAKEN \(tag) slot \(slotShown) labels \(labels(claude).sorted())")
                    if w == 274 {
                        if withPRs {
                            XCTAssertEqual(labels(claude), ["Needs input", "3 agents", "192 merged pull requests",
                                                            "2 open pull requests"], "today's open count kept: \(tag)")
                        }
                        XCTAssertEqual(slotShown, !withPRs, "slot only where it fits beside today's variant: \(tag)")
                    }
                    if w == 220 && withPRs {
                        XCTAssertFalse(labels(claude).contains("2 open pull requests"), "today's chip-only variant: \(tag)")
                    }
                    // The ⌘4 chip on the full row, found as the DigitJump rows find it (its own element, named).
                    if w == 274 || (w == 220 && withPRs) {
                        let full = tree(AgentSidebarRowView(row: busy(withPRs), selected: false, number: 4).frame(width: width),
                                        CGSize(width: width, height: sz(60))) { t in t.contains { $0.label == "Command-4" } }
                        XCTAssertTrue(full.contains { $0.label == "Command-4" && $0.frame.width > 0 }, "⌘4 chip kept: \(tag)")
                    }
                }
            }
        }
    }


    // MARK: VoiceOver

    /// The row's label reads "model …, effort …" after the detail; the model alone when no effort; nothing when unknown,
    /// for an effort without a model, on a Codex or shell row and on History.
    @MainActor
    func testModelEffortRowAccessibilityLabel() {
        let rows = [row(session("api", model: "claude-fable-9-2-20991231", effort: "high")),
                    row(session("api-qa", .done, model: "claude-fable-9", ago: 12)),
                    row(session("api-dev")),
                    row(session("api-e", effort: "high")),
                    row(session("api-cx", model: "claude-fable-9-2", effort: "high", path: nil)),
                    history("api-old")]
        let t = tree(VStack(spacing: 0) { ForEach(rows) { AgentSidebarRowView(row: $0, selected: false) } },
                     CGSize(width: 300, height: 400)) { t in t.filter { $0.label.hasPrefix("api") }.count >= rows.count }
        XCTAssertEqual(t.map(\.label).filter { $0.hasPrefix("api") },
                       ["api, Idle, model Fable 9.2, effort high, 4m ago",
                        "api-qa, Done, model Fable 9, just now",
                        "api-dev, Idle, 4m ago",
                        "api-e, Idle, 4m ago",
                        "api-cx, Idle, 4m ago",
                        "api-old, Ended · exited, 2h ago"])
    }
}

// MARK: - #1267: the model text's trailing edge with and without a Command-digit chip, and the carried slot

extension AgentRowModelEffortTests {
    /// A label carried over a list answer with no mapping keeps the slot and the text; no carry, no path: no slot.
    func testCarriedLabelKeepsTheSlot() {
        var carried = session("api", model: "claude-fable-9-2", effort: "high", path: nil)
        carried.modelCarried = 1
        let r = row(carried)
        XCTAssertTrue(r.modelSlot)
        XCTAssertEqual(r.modelText, "Fable 9.2 · high")
        XCTAssertEqual(r.modelWords, "model Fable 9.2, effort high")
        XCTAssertFalse(row(session("api", model: "claude-fable-9-2", effort: "high", path: nil)).modelSlot)
    }

    /// The widest ⌘<digit> chip (proportional digits): the one a chipless row's hidden room is as wide as.
    @MainActor
    func widestDigit() -> Int {
        (1...9).max { ideal(AgentDigitChip(number: $0)).width < ideal(AgentDigitChip(number: $1)).width } ?? 1
    }

    /// `tree` in a never-shown window whose backing scale is pinned (1x, 2x), so the frames snap to that grid.
    @MainActor
    func tree1267<V: View>(_ view: V, _ size: CGSize, backing: CGFloat, until done: ([AX]) -> Bool) -> [AX] {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        let win = ModelRowFixedBackingWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                             backing: .buffered, defer: true)
        win.fixedBacking = backing
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
        var out: [AX] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            out = []
            axWalk(host, &out)
        } while !done(out) && Date() < deadline
        XCTAssertFalse(win.isVisible, "never shown")
        XCTAssertEqual(win.backingScaleFactor, backing)
        return out
    }

    /// At the sidebar's width, every scale, 1x and 2x: the model text of a row with no number ends where the same row's
    /// ends with the widest digit's chip (and never right of any numbered row's), the state text starts at the same x.
    @MainActor
    func testModelTextEndsAtTheSameEdgeWithAndWithoutAChip() {
        let r = row(session("api", model: "claude-fable-9-2-20991231", effort: "high"))
        atScales { scale in
            let wide = widestDigit()
            for px: CGFloat in [1, 2] {
                let width = column(sz(274))
                var ends: [CGFloat] = [], starts: [CGFloat] = []
                for number in [nil, wide, 1] as [Int?] {
                    let t = tree1267(AgentSidebarRowView(row: r, selected: false, number: number).detailVariants
                        .frame(width: width, alignment: .leading), CGSize(width: width, height: sz(30)), backing: px) { t in
                        t.contains { $0.label == "Idle" } && t.contains { $0.label == r.modelText }
                    }
                    let tag = "number \(number.map(String.init) ?? "none") (\(scale), \(Int(px))x)"
                    guard let value = t.first(where: { $0.label == r.modelText }), let state = t.first(where: { $0.label == "Idle" })
                    else { XCTFail("model and state text drawn: \(tag)"); continue }
                    ends.append(value.frame.maxX); starts.append(state.frame.minX)
                }
                let tag = "\(scale), \(Int(px))x: ends \(ends)"
                XCTAssertEqual(ends.count, 3, tag)
                XCTAssertEqual(ends.first ?? -1, ends.dropFirst().first ?? -2, accuracy: 0.5 / px + 0.01, "same trailing edge: \(tag)")
                XCTAssertLessThanOrEqual(ends.first ?? 1e9, (ends.last ?? -1) + 0.5 / px + 0.01, "never right of ⌘1's: \(tag)")
                for x in starts { XCTAssertEqual(x, starts.first ?? -1, accuracy: 0.5 / px + 0.01, "state text x: \(tag)") }
            }
        }
    }

    /// The line widths: a chipless Claude row's slot variant is as wide as the widest-digit row's; a row with no slot
    /// (Codex or shell, History) and every variant without the slot are today's (no room added).
    @MainActor
    func testChiplessRoomOnlyBesideTheModelSlot() {
        let claude = row(session("api", model: "claude-fable-9-2", effort: "high"))
        let none = [row(session("api", model: "claude-fable-9-2", effort: "high", path: nil)), history("api")]
        atScales { scale in
            let wide = widestDigit()
            let chipless = AgentSidebarRowView(row: claude, selected: false)
            let numbered = AgentSidebarRowView(row: claude, selected: false, number: wide)
            XCTAssertEqual(ideal(chipless.detailLine([], chipSlot: true, modelSlot: true)).width,
                           ideal(numbered.detailLine([], chipSlot: true, modelSlot: true)).width, accuracy: 0.01, "slot line (\(scale))")
            // Without the slot a chipless row keeps no chip room, as today.
            XCTAssertEqual(ideal(chipless.detailLine([], chipSlot: true)).width, ideal(chipless.detailLine([])).width,
                           accuracy: 0.01, "no slot, no room (\(scale))")
            for r in none {
                let v = AgentSidebarRowView(row: r, selected: false)
                let today = ideal(v.detailLine([])).width
                for (tag, w) in [("chip+slot", ideal(v.detailLine([], chipSlot: true, modelSlot: true)).width),
                                 ("chip", ideal(v.detailLine([], chipSlot: true)).width),
                                 ("variants", ideal(v.detailVariants).width)] {
                    XCTAssertEqual(w, today, accuracy: 0.01, "\(r.title) \(tag): unchanged (\(scale))")
                }
            }
        }
    }
}

/// A window whose backing scale is pinned (as AgentWindowBandTests' and KeyMappingRowLayoutTests'): SwiftUI snaps to it.
private final class ModelRowFixedBackingWindow: NSWindow {
    var fixedBacking: CGFloat?
    override var backingScaleFactor: CGFloat { fixedBacking ?? super.backingScaleFactor }
}
