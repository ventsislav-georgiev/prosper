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

    /// The text column of a row `width` wide: padding 10 each side, the glyph slot 14, its gap 8; #1345: less the chip's
    /// column and its gap 8.
    @MainActor
    func column(_ width: CGFloat) -> CGFloat {
        width - 2 * sz(10) - sz(14) - sz(8) - sz(8) - ideal(AgentSidebarRowView.digitColumn).width
    }

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
            // #1345: the badges' line is line one (was detailLine(modelSlot: true)).
            let lines = claude.map { ideal(AgentSidebarRowView(row: $0, selected: false, number: 4).titleLine(badges: true)) }
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
            // #1268: the pair as two badges (was one text at font 10).
            for (m, e) in [("Fable 9.2", "medium"), ("Fable 9.2", "xhigh"), ("Opus 9.9", "medium"),
                           (AgentSidebarRowView.modelWidest, AgentSidebarRowView.effortWidest)] {
                let pair = HStack(spacing: sz(3)) {
                    AgentSidebarRowView.badge(m, AgentSidebarRowView.neutralLook)
                    AgentSidebarRowView.badge(e, AgentSidebarRowView.effortLook(e))
                }
                XCTAssertLessThanOrEqual(ideal(pair).width, slots[0].width + 0.01, "\(m) \(e) fits the slot whole (\(scale))")
            }
            for r in none {
                let v = AgentSidebarRowView(row: r, selected: false)
                XCTAssertEqual(ideal(v.titleLine(badges: true)).width, ideal(v.titleLine(badges: false)).width, accuracy: 0.01,
                               "\(r.title): no slot (\(scale))")
            }
            let v = AgentSidebarRowView(row: claude[2], selected: false)
            XCTAssertGreaterThanOrEqual(ideal(v.titleLine(badges: true)).width,
                                        ideal(v.titleLine(badges: false)).width + slots[0].width, "a Claude row has the slot (\(scale))")
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

    /// #1268: the ink's end is the right side of the last lit pixel column; nothing lit (0) is an edge near 0 that fails the bounds.
    private func inkEnd(lastLit: Int, k: CGFloat) -> CGFloat { CGFloat(lastLit + 1) / k }

    func testInkEndIsTheRightSideOfTheLastLitPixel() {
        // CI, backing 1: the old left-edge readings were 138.554 / 168.391 / 200.0 (k = 1 up to the 0.7 / 0.85 rounding).
        XCTAssertEqual(inkEnd(lastLit: 200, k: 1), 201.0)
        XCTAssertEqual(inkEnd(lastLit: 168, k: 1), 169.0)
        // Local, backing 2: the old reading was 169.27 (= 338.54 / 2); one pixel column is half a point.
        XCTAssertEqual(inkEnd(lastLit: 338, k: 2), 169.5)
        XCTAssertEqual(inkEnd(lastLit: 0, k: 2), 0.5)
    }

    /// The second line as the row draws it, at the sidebar's width: the state text starts at the same x with a value,
    /// without one and on a row with no slot (nothing is added to the stack's spacing); the value is drawn whole, the
    /// last badge's fill at the same trailing edge with and without an effort (#1268); at a narrow row the last variant keeps the state text whole, no slot.
    @MainActor
    func testModelEffortSecondLineKeepsItsStartAndTheNarrowVariant() {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let rows = [row(session("api", model: "claude-fable-9-2-20991231", effort: "high")),
                    row(session("api", model: "claude-fable-9-2")),
                    row(session("api")),
                    row(session("api", path: nil))]
        atScales { scale in
            var starts: [CGFloat] = [], ends: [CGFloat] = []
            for r in rows {
                let width = column(sz(274))
                // #1268: the last badge (the effort's, else the model's) is the value's trailing text (was modelText).
                let last = r.effort ?? r.model ?? ""
                // #1345: both lines as the row stacks them (the badges are on line one, was detailVariants alone).
                let v = AgentSidebarRowView(row: r, selected: false, number: 4)
                let t = tree(VStack(alignment: .leading, spacing: sz(3)) { v.titleLine; v.detailVariants }
                    .frame(width: width, alignment: .leading), CGSize(width: width, height: sz(40))) { t in
                    t.contains { $0.label == "Idle" } && (last.isEmpty || t.contains { $0.label == last })
                }
                guard let state = t.first(where: { $0.label == "Idle" }) else {
                    XCTFail("state text (\(scale)) in \(t.map(\.label).filter { !$0.isEmpty })"); continue
                }
                XCTAssertGreaterThan(state.frame.width, 0)
                starts.append(state.frame.minX)
                guard !last.isEmpty else { continue }
                guard let value = t.first(where: { $0.label == last }) else {
                    XCTFail("\(last) drawn at the sidebar's width (\(scale))"); continue
                }
                XCTAssertGreaterThanOrEqual(value.frame.width + pixel, ideal(Text(last).font(Neon.font(8.5, weight: .medium))).width - pixel,
                                            "\(last) whole (\(scale))")
                XCTAssertGreaterThan(value.frame.minX, state.frame.maxX, "trailing (\(scale))")
                ends.append(value.frame.maxX)
            }
            XCTAssertEqual(starts.count, rows.count)
            for x in starts { XCTAssertEqual(x, starts.first ?? -1, accuracy: 0.5, "the line starts at the same x: \(starts) (\(scale))") }
            XCTAssertEqual(ends.count, 2)
            // #1268: the LAST badge's BACKGROUND ends at the slot's end on a model-and-effort row and on a model-only row,
            // so the badges' edge lines up down the sidebar (was: the texts' accessibility frames, which are the Text
            // without its sz(3) padding; they are printed beside it). Read by pixels: the rightmost drawn pixel left of
            // the age slot, over a black canvas, at the column's width. slotEnd uses the age slot's fittingSize (whole
            // points, rounded up), so the real end R is in [slotEnd, slotEnd + 1); the last pixel the badge's fill
            // touches is within one backing pixel (1 pt at 1x) before R, the edge is the RIGHT side of that pixel,
            // (last + 1) / k (the left side, last / k, read a whole point short on the CI runner at backing 1, #1268), and a pixel the edge covers under about a tenth
            // can read blank: so [slotEnd - 1.5, slotEnd + 1], and the two rows within 1 pt of each other. A badge edge
            // sz(3) apart (2.1 pt at 0.7) fails the second at every scale.
            // #1345: the badges end line ONE (was: before the age slot on line two), so slotEnd is the line's end and the
            // scan is the title's band only (the age ends line two at the same x).
            let lineWidth = column(sz(274))
            let slotEnd = lineWidth
            let band = ideal(Text("api").font(Neon.font(12.5, weight: .medium))).height
            var badgeEnds: [CGFloat] = []
            for r in rows.prefix(2) {
                let root = ZStack(alignment: .topLeading) {
                    Color.black
                    AgentSidebarRowView(row: r, selected: false, number: 4).titleLine
                        .frame(width: lineWidth, height: band, alignment: .leading)
                }
                .frame(width: lineWidth + 24, height: sz(30) + 24, alignment: .topLeading)
                .environment(\.colorScheme, .dark)
                let h = NSHostingView(rootView: root)
                h.frame = CGRect(x: 0, y: 0, width: lineWidth + 24, height: sz(30) + 24)
                h.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                h.layoutSubtreeIfNeeded()
                guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { XCTFail("no bitmap (\(scale))"); continue }
                h.cacheDisplay(in: h.bounds, to: rep)
                let k = CGFloat(rep.pixelsWide) / (lineWidth + 24)
                var last = 0
                for y in 0..<Int(band * k) {
                    for x in Int((slotEnd - sz(20)) * k)..<Int((slotEnd + sz(5) - 0.5) * k) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if c.redComponent + c.greenComponent + c.blueComponent > 0.003 { last = max(last, x) }
                    }
                }
                badgeEnds.append(inkEnd(lastLit: last, k: k))
                // #1268 (R8): on the model-and-effort row the two badges draw different fills, as drawn: the model's
                // neutral grey wash and the effort's ("high") accent wash, each over the black canvas.
                if r.effort != nil {
                    var grey = 0, accent = 0
                    for y in 0..<Int(band * k) {
                        for x in Int((slotEnd - sz(120)) * k)..<Int(slotEnd * k) {
                            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                            let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
                            if hi > 0.02 && hi < 0.08 && c.blueComponent - c.redComponent < 0.02 { grey += 1 }
                            if c.blueComponent - c.redComponent > 0.1 && hi < 0.4 { accent += 1 }
                        }
                    }
                    let least = Int(sz(40) * k * k)
                    XCTAssertTrue(grey > least && accent > least, "model and effort fills differ: grey \(grey), accent \(accent) px (\(scale))")
                }
            }
            print("BADGE1268B-EDGE scale \(scale) slotEnd \(slotEnd) badge fill ends \(badgeEnds) (effort row, model-only row); "
                  + "text frame ends \(ends)")
            XCTAssertEqual(badgeEnds.count, 2)
            for x in badgeEnds {
                XCTAssertTrue(x <= slotEnd + 1 && x >= slotEnd - 1.5, "badge edge \(x) at the slot's end \(slotEnd): \(badgeEnds) (\(scale))")
            }
            XCTAssertEqual(badgeEnds.first ?? -1, badgeEnds.last ?? -9, accuracy: 1, "one badge edge on both rows: \(badgeEnds) (\(scale))")

            // Narrow: the last variant, no slot, the state text whole. #1268: sz(150) (was sz(120)): the last variant now
            // carries the age slot too (the sidebar itself is a fixed sz(290)). #1345: sz(190): line two no longer runs
            // under the chip, so the same line is a row the chip's column and its gap (36.5 pt at 1.0) wider.
            let narrow = row(session("api", .blocked, model: "claude-fable-9-2", effort: "high"))
            let width = column(sz(190))
            let t = tree(AgentSidebarRowView(row: narrow, selected: false, number: 4).detailVariants
                .frame(width: width, alignment: .leading), CGSize(width: width, height: sz(30))) { t in
                t.contains { $0.label == "Needs input" }
            }
            let state = t.first { $0.label == "Needs input" }
            // 1 pt: the ideal is a fittingSize (whole points, rounded up); the AX frame is not (0.7 read 44.0 for 45).
            // A cut text is far narrower: the slot variant leaves it under half its width here.
            XCTAssertGreaterThanOrEqual((state?.frame.width ?? 0) + 1, ideal(Text("Needs input").font(Neon.font(10.5))).width,
                                        "the state text whole at a narrow row (\(scale))")
            // #1345: line two never carries the badges (was: no slot at a narrow row; line one's give-way is (d)).
            XCTAssertFalse(t.contains { $0.label.contains("Fable") }, "no badges on line two at a narrow row (\(scale))")
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
            // #1345: the three variants (chips, count, none); the badges are on line one (was four, two with badges).
            let widths = [ideal(v.detailLine(r.prs)).width,
                          ideal(v.detailLine([], open: r.prCount)).width,
                          ideal(v.detailLine([])).width]
            XCTAssertEqual(widths.count, 3)
            // As row widths: the variant is taken from this row width up (until one before it fits).
            let rowWidths = widths.map { ($0 + 2 * sz(10) + sz(14) + sz(8)).rounded(.up) }
            print("MODEL1203-WIDTHS scale \(scale) sidebarRow \(sz(274)) column \(column(sz(274))) "
                  + "variantIdeal \(widths.map { ($0 * 10).rounded() / 10 }) fromRowWidth \(rowWidths)")
            for (a, b) in [(0, 1), (1, 2)] {
                XCTAssertGreaterThan(widths[a], widths[b], "the variants in their order: \(a + 1) > \(b + 1) (\(scale))")
            }
            // #1345 round 2, facts for the report (no assertion): the row as drawn at the sidebar's width, 1x and 2x: line
            // two's real width (the block probe) and whether its accent ink (the open count or the chips; the state text
            // is amber, the counts and the age quiet) is drawn on line two.
            for px: CGFloat in [1, 2] {
                let h = hosted1345(r, number: 4, width: sz(274), backing: px)
                guard let block = h.frames["block"], let t = h.frames["title"], let rep = h.rep else { continue }
                let k = CGFloat(rep.pixelsWide) / sz(274).rounded(.up)
                var accent = 0
                let y0 = Int((t.maxY + 1) * k), y1 = min(rep.pixelsHigh, Int(block.maxY * k))
                let x0 = Int(block.minX * k), x1 = min(rep.pixelsWide, Int(block.maxX * k))
                for y in y0..<max(y0, y1) {
                    for x in x0..<max(x0, x1) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if c.blueComponent - c.redComponent > 0.25 { accent += 1 }
                    }
                }
                let box = ExactIdeal1345.Box()
                _ = NSHostingView(rootView: ExactIdeal1345(box: box) { v.detailLine([], open: r.prCount) }).fittingSize
                print("ROW1345-BUSY scale \(scale) \(Int(px))x line \(block.width) countIdealUnrounded \(box.width) "
                      + "accentPixelsOnLineTwo \(accent)")
            }
            XCTAssertLessThanOrEqual(ideal(AgentSidebarRowView(row: busy(false), selected: false, number: 4)
                .titleLine(badges: true)).width, column(sz(274)),
                                     "a plain row keeps the badges at the sidebar's width (\(scale))")
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
                        // #1345: both lines (the badges are on line one).
                        let v = AgentSidebarRowView(row: r, selected: false, number: 4)
                        return tree(VStack(alignment: .leading, spacing: sz(3)) { v.titleLine; v.detailVariants }
                            .frame(width: column(width), alignment: .leading), CGSize(width: column(width), height: sz(40))) { t in
                            t.contains { $0.label == "Needs input" } && (!withPRs || t.contains { $0.label == "3 agents" })
                        }
                    }
                    let claude = line(busy(withPRs)), today = line(busy(withPRs, claude: false))
                    let tag = "\(withPRs ? "busy" : "plain") at \(w) (\(scale))"
                    // #1268: two badges (was one "Fable 9.2 · high" text); the PR chips give way to their count before
                    // the badges go (item 3), so the badges may stand beside the count where today's row keeps chips.
                    let badges: Set = ["Fable 9.2", "high"]
                    let slotShown = claude.contains { $0.label == "Fable 9.2" }
                    func labels(_ t: [AX]) -> Set<String> { Set(t.map(\.label).filter { !$0.isEmpty && !badges.contains($0) }) }
                    XCTAssertTrue(labels(claude).subtracting(labels(today)).isSubset(of: ["2 open pull requests"]),
                                  "the slot takes nothing but the chips (to their count) away: \(tag)")
                    XCTAssertTrue(labels(claude).contains("Needs input"), "the state text stays: \(tag)")
                    // #1345 round 2 (operator, "Cut the name first"): both badges, the effort's alone, or none; never the
                    // model's alone (was: both or none).
                    XCTAssertFalse(slotShown && !claude.contains { $0.label == "high" }, "never the model's badge alone: \(tag)")
                    XCTAssertFalse(today.contains { $0.label.contains("Fable") }, "no slot without modelSlot: \(tag)")
                    let x = [claude, today].map { $0.first { $0.label == "Needs input" }?.frame.minX ?? -100 }
                    XCTAssertEqual(x.first ?? -1, x.last ?? -2, accuracy: 0.5, "state text at the same x: \(tag)")
                    print("MODEL1203-TAKEN \(tag) slot \(slotShown) labels \(labels(claude).sorted())")
                    if w == 274 && !withPRs { XCTAssertTrue(slotShown, "a plain row shows the badges at the sidebar's width: \(tag)") }
                    // #1268: the ⌘4 chip is on the first line at every width (was: only where line two had room).
                    if w == 274 || w == 110 {
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

    /// #1345 (c), was #1267/#1268's edge on line two: the FULL row at the sidebar's width, every scale, 1x and 2x, by
    /// the row's probes: with no number, the widest digit's and 1, the badges end at one x, the age ends at one x right
    /// under them (within 1 pt), the chip's column keeps one width (the widest chip's) and the title starts at one x.
    @MainActor
    func testModelTextEndsAtTheSameEdgeWithAndWithoutAChip() {
        let r = row(session("api", model: "claude-fable-9-2-20991231", effort: "high"))
        atScales { scale in
            let wide = widestDigit()
            for px: CGFloat in [1, 2] {
                var badges: [CGFloat] = [], ages: [CGFloat] = [], starts: [CGFloat] = [], columns: [CGFloat] = []
                for number in [nil, wide, 1] as [Int?] {
                    let tag = "number \(number.map(String.init) ?? "none") (\(scale), \(Int(px))x)"
                    let h = hosted1345(r, number: number, width: sz(274), backing: px)
                    let f = h.frames
                    guard let b = f["badges"], let a = f["age"], let t = f["title"], let c = f["chipColumn"] else {
                        XCTFail("badges, age, title and column probed: \(f.keys.sorted()) \(tag)"); continue
                    }
                    XCTAssertEqual(b.maxX, a.maxX, accuracy: 1, "the age's right edge under the badges': \(tag)")
                    // Round 2: the column's frame against the widest chip as DRAWN in it at the same backing (its ink,
                    // (last + 1) / k), within one device pixel (was: >= a rounded fittingSize - 1, red at 0.7/0.85 2x).
                    if number == wide {
                        let ink = h.rep.flatMap { rep in
                            ink1345(rep, k: CGFloat(rep.pixelsWide) / sz(274).rounded(.up),
                                    in: CGRect(x: c.minX - sz(2), y: 0, width: c.width + sz(4), height: h.height))
                        }
                        print("ROW1345-COLUMN \(tag) column \(c.width) chipInk \(String(describing: ink))")
                        XCTAssertEqual(c.width, ink?.width ?? -9, accuracy: 1 / px + 0.01, "the column is the drawn widest chip's: \(tag)")
                    }
                    badges.append(b.maxX); ages.append(a.maxX); starts.append(t.minX); columns.append(c.width)
                }
                let tag = "\(scale), \(Int(px))x: badges \(badges) ages \(ages) columns \(columns)"
                print("ROW1345-C \(tag)")
                XCTAssertEqual(badges.count, 3, tag)
                for x in badges { XCTAssertEqual(x, badges.first ?? -1, accuracy: 0.5 / px + 0.01, "same badge edge: \(tag)") }
                for x in ages { XCTAssertEqual(x, ages.first ?? -1, accuracy: 0.5 / px + 0.01, "same age edge: \(tag)") }
                for x in starts { XCTAssertEqual(x, starts.first ?? -1, accuracy: 0.5 / px + 0.01, "title x: \(tag)") }
                for x in columns { XCTAssertEqual(x, columns.first ?? -1, accuracy: 0.01, "one column width: \(tag)") }
            }
        }
    }

    /// #1345 (was #1267/#1268's chipless room on line one): the chip's room is the row's own column on EVERY row (a
    /// number or not, Claude or not, live or History): line one and line two are the same width with any number, and a
    /// row with no slot (Codex or shell, History) adds none on line one.
    @MainActor
    func testChiplessRoomOnlyBesideTheModelSlot() {
        let claude = row(session("api", model: "claude-fable-9-2", effort: "high"))
        let none = [row(session("api", model: "claude-fable-9-2", effort: "high", path: nil)), history("api")]
        atScales { scale in
            let wide = widestDigit()
            for r in [claude] + none {
                let chipless = AgentSidebarRowView(row: r, selected: false)
                let numbered = AgentSidebarRowView(row: r, selected: false, number: wide)
                XCTAssertEqual(ideal(chipless.titleLine).width, ideal(numbered.titleLine).width, accuracy: 0.01,
                               "\(r.title): line one the same with no number (\(scale))")
                // Was: the room on line one (title + sz(6) + sz(4) + the widest chip); now the row's column, as wide.
                // Round 2: the column's frame against the widest chip as drawn in it at the same backing (2x), within one
                // device pixel (was: >= a rounded fittingSize - 1). The column is the same with no number ((c)).
                let h = hosted1345(r, number: wide, width: sz(274), backing: 2)
                let col = h.frames["chipColumn"] ?? .zero
                let ink = h.rep.flatMap { rep in
                    ink1345(rep, k: CGFloat(rep.pixelsWide) / sz(274).rounded(.up),
                            in: CGRect(x: col.minX - sz(2), y: 0, width: col.width + sz(4), height: h.height))
                }
                XCTAssertGreaterThan(col.width, 0, "\(r.title): the column probed (\(scale))")
                XCTAssertEqual(col.width, ink?.width ?? -9, accuracy: 0.5 + 0.01, "\(r.title): the room is the widest chip's (\(scale))")
                XCTAssertEqual(ideal(chipless.detailLine([])).width, ideal(numbered.detailLine([])).width, accuracy: 0.01,
                               "\(r.title): line two does not carry the chip (\(scale))")
            }
            for r in none {
                let v = AgentSidebarRowView(row: r, selected: false)
                XCTAssertEqual(ideal(v.titleLine(badges: true)).width, ideal(v.titleLine(badges: false)).width, accuracy: 0.01,
                               "\(r.title): no slot (\(scale))")
            }
        }
    }
}

// MARK: - #1345: badges on line one, the age under them, the chip centred to the right of both lines

extension AgentRowModelEffortTests {
    /// A full row hosted in a never-shown window whose backing is pinned: the row's probe frames by kind (row space;
    /// the row is at the host's origin) and the row drawn over black into an in-memory bitmap of `backing` pixels per
    /// point (no file). The probe is put back after.
    @MainActor
    func hosted1345(_ r: AgentSidebar.Row, number: Int?, width: CGFloat, backing: CGFloat)
        -> (frames: [String: CGRect], rep: NSBitmapImageRep?, height: CGFloat) {
        final class Box { var seen: [String: CGRect] = [:] }
        let box = Box()
        AgentSidebarRowView.probe = { kind, _, rect in box.seen[kind] = rect }
        defer { AgentSidebarRowView.probe = nil }
        let view = AgentSidebarRowView(row: r, selected: false, number: number).frame(width: width)
        let height = NSHostingView(rootView: view).fittingSize.height
        // Whole points, so the bitmap's pixels per point is exactly `backing` (sz(274) at 0.7 is 191.8).
        let size = CGSize(width: width.rounded(.up), height: height.rounded(.up))
        let win = ModelRowFixedBackingWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                             backing: .buffered, defer: true)
        win.fixedBacking = backing
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        let host = NSHostingView(rootView: ZStack(alignment: .topLeading) { Color.black; view }
            .frame(width: size.width, height: size.height, alignment: .topLeading).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while (box.seen["block"] == nil || box.seen["chipColumn"] == nil || box.seen["title"] == nil) && Date() < deadline
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(win.isVisible, "never shown")
        XCTAssertEqual(win.backingScaleFactor, backing)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * backing),
                                   pixelsHigh: Int(size.height * backing), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let rep {
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return (box.seen, rep, height)
    }

    /// The lit pixels' bounds (points) inside `rect`: x from the first lit column's left side to the last's right side
    /// ((last + 1) / k, inkEnd), y likewise; nil when nothing is lit.
    func ink1345(_ rep: NSBitmapImageRep, k: CGFloat, in rect: CGRect) -> CGRect? {
        var x0 = Int.max, x1 = -1, y0 = Int.max, y1 = -1
        for y in max(0, Int(rect.minY * k))..<min(rep.pixelsHigh, Int(rect.maxY * k)) {
            for x in max(0, Int(rect.minX * k))..<min(rep.pixelsWide, Int(rect.maxX * k)) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.redComponent + c.greenComponent + c.blueComponent > 0.05 else { continue }
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= 0 else { return nil }
        return CGRect(x: CGFloat(x0) / k, y: CGFloat(y0) / k, width: inkEnd(lastLit: x1, k: k) - CGFloat(x0) / k,
                      height: CGFloat(y1 + 1 - y0) / k)
    }

    /// (a) and (b), at the sidebar's width, every scale, 1x and 2x: the badges sit on line one (their midY inside the
    /// title's band) and end within 1 pt of the age's right edge on line two, by the probes and by the pixels (the badge
    /// fill's ink end in the title's band); the ⌘4 chip's ink is centred within 1 pt on the two-line block and starts
    /// right of both the badges and the age. A row with no number draws nothing in the column.
    @MainActor
    func testBadgesOnLineOneAgeUnderThemChipCentredRightOfBoth() {
        let r = row(session("api", model: "claude-fable-9-2-20991231", effort: "high"))
        atScales { scale in
            for px: CGFloat in [1, 2] {
                let tag = "(\(scale), \(Int(px))x)"
                let h = hosted1345(r, number: 4, width: sz(274), backing: px)
                guard let b = h.frames["badges"], let a = h.frames["age"], let t = h.frames["title"],
                      let block = h.frames["block"], let col = h.frames["chipColumn"], let rep = h.rep else {
                    XCTFail("probed and drawn: \(h.frames.keys.sorted()) \(tag)"); continue
                }
                let k = CGFloat(rep.pixelsWide) / sz(274).rounded(.up)
                XCTAssertEqual(k, px, accuracy: 0.001, "bitmap at the pinned backing \(tag)")
                // (a)
                XCTAssertTrue(b.midY >= t.minY && b.midY <= t.maxY, "badges on line one: \(b) in title \(t) \(tag)")
                XCTAssertGreaterThan(a.minY, t.maxY, "the age on line two: \(a) \(tag)")
                XCTAssertEqual(b.maxX, a.maxX, accuracy: 1, "badge edge \(b.maxX) over age edge \(a.maxX) \(tag)")
                let badgeInk = ink1345(rep, k: k, in: CGRect(x: b.maxX - sz(20), y: t.minY, width: sz(20) + sz(4), height: t.height))
                let end = badgeInk?.maxX ?? 0
                XCTAssertTrue(end <= a.maxX + 1 && end >= a.maxX - 1.5, "badge ink ends \(end) at the age's edge \(a.maxX) \(tag)")
                // (b)
                let chipInk = ink1345(rep, k: k, in: CGRect(x: col.minX - sz(2), y: 0, width: col.width + sz(4), height: h.height))
                guard let c = chipInk else { XCTFail("the chip drawn \(tag)"); continue }
                print("ROW1345-AB \(tag) title \(t) badges \(b) badgeInkEnd \(end) age \(a) block \(block) column \(col) chipInk \(c)")
                XCTAssertEqual(c.midY, block.midY, accuracy: 1, "the chip centred on the two lines \(tag)")
                XCTAssertGreaterThan(c.minX, max(b.maxX, a.maxX), "the chip right of the badges and the age \(tag)")
                let empty = hosted1345(r, number: nil, width: sz(274), backing: px)
                if let e = empty.rep {
                    XCTAssertTrue(ink1345(e, k: k, in: CGRect(x: col.minX - sz(2), y: 0, width: col.width + sz(4), height: h.height)) == nil,
                                  "no number: the column is empty \(tag)")
                }
            }
        }
    }

    /// A live Claude row named `title` with both badges (no PRs, no counts).
    func named1345(_ title: String) -> AgentSidebar.Row {
        AgentSidebar.Row(id: .live(AgentSessionKey(dir: Self.dir, name: "api")), title: title, state: .idle,
                         detail: "Idle", age: "4m", prs: [], prCount: 0, agents: 0, merged: 0,
                         modelSlot: true, model: "Fable 9.2", effort: "high")
    }

    @MainActor
    func titleWidth1345(_ s: String) -> CGFloat { ideal(Text(s).font(Neon.font(12.5, weight: .medium))).width }

    /// The room line one gives the title (probes): from the title's start to the badges' (`kind`), less line one's gaps
    /// (sz(6) either side of the Spacer's least sz(4), and the "in view" slot with its gap when the gate is on). A cut
    /// Text's own frame is its visible glyphs' width, up to a glyph short of that room, so the room is what is read.
    @MainActor
    func titleRoom1345(_ f: [String: CGRect], _ kind: String) -> CGFloat {
        guard let t = f["title"], let b = f[kind] else { return 0 }
        return b.minX - t.minX - 2 * sz(6) - sz(4) - (AgentPaneLayout.splitsEnabled ? sz(6) + sz(14) : 0)
    }

    /// (d) Operator 2026-11-16, "Cut the name first": at the sidebar's width (sz(274)), every scale, 1x and 2x, by the
    /// probes: the operator's "session-tokens" shows both badges; a long name keeps both and is cut ("…", narrower than
    /// its ideal), not dropped; and at the narrowest row where both still fit, the long name is cut down to the floor
    /// (`badgeTitleFloor`, the literal "abcdefgh…" in the title's font) and no further. Was (round 1): a name over about
    /// 11 characters dropped the badges whole.
    @MainActor
    func testLongTitleIsCutToItsFloorBeforeTheBadgesGo() {
        let long = "api-" + String(repeating: "session-tokens-", count: 4)
        atScales { scale in
            let floor = AgentSidebarRowView.badgeTitleFloor
            // 1 pt: the Text's width is a fittingSize (whole points, rounded up).
            XCTAssertEqual(floor, titleWidth1345("abcdefgh\u{2026}"), accuracy: 1, "the floor is the literal in the title's font (\(scale))")
            for title in ["session-tokens", long] {
                for px: CGFloat in [1, 2] {
                    let f = hosted1345(named1345(title), number: 4, width: sz(274), backing: px).frames
                    let tag = "\(title.count) chars, ideal \(titleWidth1345(title)), floor \(floor) (\(scale), \(Int(px))x)"
                    print("ROW1345-FLOOR \(tag) title \(String(describing: f["title"])) keys \(f.keys.sorted())")
                    XCTAssertTrue(f["badges"] != nil && f["effort"] == nil, "both badges at the sidebar's width: \(tag)")
                    XCTAssertGreaterThanOrEqual(titleRoom1345(f, "badges") + 1, min(floor, titleWidth1345(title)), "not under the floor: \(tag)")
                    if title == long {
                        XCTAssertLessThan(f["title"]?.width ?? .infinity, titleWidth1345(long) - sz(20), "the long name is cut: \(tag)")
                    }
                }
            }
            // Down to the floor: the row just wide enough for the floor, the gaps and both badges (line one's ideal with
            // the badges is exactly that for a long name; +1 pt for its fittingSize rounding).
            let v = AgentSidebarRowView(row: named1345(long), selected: false, number: 4)
            let width = (ideal(v.titleLine(badges: true)).width + 1 + sz(274) - column(sz(274))).rounded(.up)
            XCTAssertLessThan(width, sz(274), "premise: narrower than the sidebar (\(scale))")
            for px: CGFloat in [1, 2] {
                let f = hosted1345(named1345(long), number: 4, width: width, backing: px).frames
                let tag = "row \(width), floor \(floor) (\(scale), \(Int(px))x)"
                print("ROW1345-FLOOR-MIN \(tag) title \(String(describing: f["title"])) keys \(f.keys.sorted())")
                XCTAssertTrue(f["badges"] != nil, "both badges kept at the floor: \(tag)")
                // Up to 5 pt over: line one's ideal and the chip column in `column` are fittingSizes (each up to 1.3 pt
                // over the frame), the +1 and the row's rounding up.
                let w = titleRoom1345(f, "badges")
                XCTAssertTrue(w >= floor - 1 && w <= floor + 5, "the title's room cut to about the floor, \(w): \(tag)")
            }
        }
    }

    /// (d2) Below the floor, at literal row widths, every scale, 1x and 2x: at sz(220) the model's badge goes and the
    /// effort's stays (the title keeps its floor), at sz(170) neither (the title alone); the premises are asserted from
    /// line one's own ideals (1 pt over or under for the fittingSize rounding, 2 pt for the column's). The row's
    /// VoiceOver words are the same at all three widths.
    @MainActor
    func testBelowTheTitleFloorTheEffortBadgeAloneThenNone() {
        let r = named1345("api-" + String(repeating: "session-tokens-", count: 4))
        atScales { scale in
            let v = AgentSidebarRowView(row: r, selected: false, number: 4)
            let both = ideal(v.titleLine(badges: true)).width, effort = ideal(v.titleLine(badges: true, effortOnly: true)).width
            let mid = column(sz(220)), narrow = column(sz(170))
            let premise = "both \(both), effort \(effort), lines \(mid) / \(narrow) (\(scale))"
            print("ROW1345-STEPS \(premise) floor \(AgentSidebarRowView.badgeTitleFloor)")
            XCTAssertGreaterThan(both, mid + 2, "premise: both badges do not fit at sz(220): \(premise)")
            XCTAssertLessThanOrEqual(effort + 1, mid, "premise: the effort's alone fits at sz(220): \(premise)")
            XCTAssertGreaterThan(effort, narrow + 2, "premise: not even the effort's at sz(170): \(premise)")
            for px: CGFloat in [1, 2] {
                let m = hosted1345(r, number: 4, width: sz(220), backing: px).frames
                XCTAssertTrue(m["badges"] == nil && m["effort"] != nil, "sz(220): the effort's badge alone: \(m.keys.sorted()) \(premise)")
                XCTAssertGreaterThanOrEqual(titleRoom1345(m, "effort") + 1, AgentSidebarRowView.badgeTitleFloor, "sz(220): the floor kept: \(premise)")
                let n = hosted1345(r, number: 4, width: sz(170), backing: px).frames
                XCTAssertTrue(n["badges"] == nil && n["effort"] == nil && n["title"] != nil, "sz(170): the title alone: \(n.keys.sorted()) \(premise)")
            }
            for width in [sz(274), sz(220), sz(170)] {
                let t = AXTreeSupport.tree(AgentSidebarRowView(row: r, selected: false, number: 4).frame(width: width),
                                           CGSize(width: width, height: sz(60))) { t in t.contains { $0.label.hasPrefix("api-") } }
                XCTAssertEqual(t.first(where: { $0.label.hasPrefix("api-") })?.label,"\(r.title), Idle, model Fable 9.2, effort high, 4m ago",
                               "the row's words at \(width) (\(scale))")
            }
        }
    }

    /// #1365 (R1345-s1): a remote Claude row (host "host-a", a carried label) at the sidebar's width, every scale, 1x and
    /// 2x, by the probes: both badges on line one (no "effort" alone), the title keeps its floor. The hidden host slot
    /// gives way first (was: the badges plus it did not fit, so no badge at all). Prints the widths behind it.
    @MainActor
    func testRemoteRowKeepsBothBadgesAtTheSidebarWidth() {
        var r = named1345("session-tokens")
        r.remote = AgentSidebar.Remote(host: "host-a", name: "api", alias: "", stale: false, cwd: nil)
        atScales { scale in
            let v = AgentSidebarRowView(row: r, selected: false, number: 4)
            print("ROW1365-WIDTHS (\(scale)) floor \(AgentSidebarRowView.badgeTitleFloor) badges \(ideal(v.modelSlotView).width)"
                  + " host \(ideal(AgentSidebarRowView.hostSlot("host-a")).width) line \(column(sz(274)))"
                  + " withHost \(ideal(v.titleLine(badges: true)).width) noHost \(ideal(v.titleLine(badges: true, hostSlot: false)).width)")
            for px: CGFloat in [1, 2] {
                let tag = "(\(scale), \(Int(px))x)"
                let f = hosted1345(r, number: 4, width: sz(274), backing: px).frames
                print("ROW1365-A \(tag) \(f.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })")
                guard let b = f["badges"], let t = f["title"] else { XCTFail("both badges probed: \(f.keys.sorted()) \(tag)"); continue }
                XCTAssertTrue(f["effort"] == nil, "not the effort's alone: \(tag)")
                XCTAssertTrue(b.midY >= t.minY && b.midY <= t.maxY, "badges on line one: \(b) in title \(t) \(tag)")
                XCTAssertGreaterThanOrEqual(titleRoom1345(f, "badges") + 1, AgentSidebarRowView.badgeTitleFloor, "the floor kept: \(tag)")
            }
        }
    }

    /// (e) The row's height is TIP's at 0.7, 0.85 and 1.0, with and without a number, with a model, without one and on
    /// History: literal heights measured at TIP (204f78a9, the scratch run ROW1345-TIP in ticket1.log: 31, 39, 45 for
    /// all six rows at each scale).
    @MainActor
    func testRowHeightIsTipsAtEveryScale() {
        let tip: [CGFloat: CGFloat] = [0.7: 31, 0.85: 39, 1.0: 45]
        var remote = named1345("session-tokens")   // #1365: a remote Claude row on the new step, same height
        remote.remote = AgentSidebar.Remote(host: "host-a", name: "api", alias: "", stale: false, cwd: nil)
        let rows = [row(session("api", model: "claude-fable-9-2-20991231", effort: "high")),
                    row(session("api", path: nil)), history("api-old"), remote]
        atScales { scale in
            for r in rows {
                for number in [nil, 4] as [Int?] {
                    let h = NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false, number: number)
                        .frame(width: sz(274))).fittingSize.height
                    print("ROW1345-E scale \(scale) \(r.title) number \(number.map(String.init) ?? "none") height \(h)")
                    XCTAssertEqual(h, tip[scale] ?? -1, accuracy: 0.01, "\(r.title) number \(String(describing: number)) (\(scale))")
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
