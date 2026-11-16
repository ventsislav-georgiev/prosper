import AppKit
import SwiftUI

// #1318 (#832 X1 step C, spec v2.1 8.2): the chapters rail. An overlay in the transcript's leading sz(14) padding: it
// adds no width and moves no text. Ticks by ordinal (never by row pixels: rows are estimates in a LazyVStack), bucketed
// past height / sz(4). The whole strip is the hit area. A click jumps through the pane's TranscriptJumper (step A).

/// The rail's geometry for one size, pure.
struct TranscriptRail: Equatable {
    enum Hit: Equatable { case earlier, tick(Int) }
    struct Tick: Equatable {
        /// The chapter a click jumps to and the label names: the bucket's first.
        let chapter: TranscriptOutline.Chapter
        let y: CGFloat
        /// Any chapter of the bucket has an error turn.
        let error: Bool
    }

    let chapters: [TranscriptOutline.Chapter]
    /// `olderAvailable`: the "Earlier" cap shows; `atHistoryCap`: it cannot load.
    let older: Bool, cap: Bool
    let size: CGSize

    static var width: CGFloat { sz(14) }
    static var minPane: CGFloat { sz(340) }

    /// Below 340*s, with no chapters, or a size that is not finite: nothing drawn, no hover, no click.
    var shown: Bool {
        size.width.isFinite && size.height.isFinite && size.width >= Self.minPane && !chapters.isEmpty
    }
    /// The ticks' area starts under the cap.
    var top: CGFloat { older ? sz(10) : 0 }
    var height: CGFloat { max(0, size.height - top) }
    /// One tick per chapter, or `height / sz(4)` buckets when there are more chapters.
    var count: Int {
        guard shown else { return 0 }
        let fits = min(height / sz(4), CGFloat(chapters.count))   // finite (shown), at most the count: Int( cannot trap
        return max(1, Int(fits))
    }

    /// The first chapter of bucket `i` of `count`: chapter j sits in bucket j * k / n.
    private func first(_ i: Int, _ k: Int) -> Int { (i * chapters.count + k - 1) / k }

    var ticks: [Tick] {
        let k = count, n = chapters.count
        guard k > 0 else { return [] }
        return (0..<k).map { i in
            let a = first(i, k), b = i + 1 < k ? first(i + 1, k) : n
            return Tick(chapter: chapters[a], y: top + (CGFloat(i) + 0.5) * height / CGFloat(k),
                        error: chapters[a..<b].contains { $0.hasError })
        }
    }

    /// The whole strip (x 0 to sz(14)) hit-tests; y maps to the nearest tick (each tick owns a band of height / count).
    func hit(at p: CGPoint) -> Hit? {
        let k = count
        guard k > 0, p.x.isFinite, p.y.isFinite, p.x >= 0, p.x <= Self.width, p.y >= 0, p.y <= size.height else { return nil }
        if older && p.y < top { return .earlier }
        let band = Int(min(max(0, (p.y - top) / (height / CGFloat(k))), CGFloat(k - 1)))
        return .tick(band)
    }

    /// The label's two lines: "12 \u{00B7} title" (R904-f1: the title through the mark cap) and "error" when set.
    func label(_ h: Hit) -> (String, String?)? {
        switch h {
        case .earlier:
            return older ? (cap ? "Older history is in the terminal" : "Earlier chapters not loaded", nil) : nil
        case .tick(let i):
            guard let t = ticks.dropFirst(i).first else { return nil }
            return ("\(t.chapter.ordinal) \u{00B7} " + OutsideText.shown(t.chapter.title, max: TranscriptOutline.titleCap),
                    t.error ? "error" : nil)
        }
    }

    /// A click: a tick jumps to its chapter (this pane's jumper only), the cap loads the page before unless at the cap.
    /// On an unfocused pane the click never gets here: the window's 7.6 rule swallows it (AgentsNSWindow.firstClick).
    @MainActor func click(at p: CGPoint, jumper: TranscriptJumper, loadEarlier: () -> Void) {
        switch hit(at: p) {
        case .earlier?: if !cap { loadEarlier() }
        case .tick(let i)?: if let t = ticks.dropFirst(i).first { jumper.jump(to: t.chapter) }
        case nil: break
        }
    }
}

/// The hover label's state: shown after a 150 ms dwell, gone 150 ms after the pointer leaves, never while a button is
/// down. The clock and the button read are seams (tests drive `move` with no real wait and no event).
@MainActor final class TranscriptRailHover: ObservableObject {
    static let dwell: TimeInterval = 0.15

    /// What the label shows.
    @Published private(set) var shown: TranscriptRail.Hit?
    /// What the pointer is over.
    private var under: TranscriptRail.Hit?
    private var clock = 0

    var buttonDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }
    var after: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { d, f in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(d))
            f()
        }
    }

    /// The pointer is over `hit` (nil: it left the rail).
    func move(_ hit: TranscriptRail.Hit?) {
        let was = under
        under = hit
        guard let hit else {
            if was != nil { later { $0.shown = nil } }
            return
        }
        if buttonDown() {
            // A selection drag across the rail shows nothing; the dwell starts again once the button is up.
            (under, shown) = (nil, nil)
            clock += 1
            return
        }
        if shown != nil {
            clock += 1   // a pending hide is off; the label follows at once
            shown = hit
        } else if was == nil {
            later { $0.shown = $0.under }
        }
    }

    private func later(_ f: @escaping @MainActor @Sendable (TranscriptRailHover) -> Void) {
        clock += 1
        let n = clock
        after(Self.dwell) { [weak self] in
            guard let self, self.clock == n else { return }
            f(self)
        }
    }
}

/// The rail drawn over the scroll area (the overlay takes the area's size and changes no frame).
struct TranscriptRailView: View {
    @ObservedObject var model: AgentTranscriptModel
    @ObservedObject var hover: TranscriptRailHover
    let jumper: TranscriptJumper
    /// Tests only: the rail each layout pass computes, with the model it was drawn for (nil: no observer).
    static var probe: (@MainActor (AgentTranscriptModel, TranscriptRail) -> Void)?

    var body: some View {
        GeometryReader { g in
            let rail = TranscriptRail(chapters: model.chapters, older: model.olderAvailable, cap: model.atHistoryCap, size: g.size)
            ZStack(alignment: .topLeading) {
                if rail.shown { strip(rail) }
            }
            .modifier(RailProbe(model: model, rail: rail))
        }
    }

    private func strip(_ rail: TranscriptRail) -> some View {
        let dim = Neon.textSecondary.opacity(0.5), hot = Neon.magenta
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for t in rail.ticks {
                    ctx.fill(Path(CGRect(x: sz(4), y: t.y - sz(1), width: sz(6), height: sz(2))),
                             with: .color(t.error ? hot : dim))
                }
                if rail.older {
                    let cap = CGRect(x: sz(4), y: sz(2), width: sz(6), height: sz(6))
                    ctx.stroke(Path(cap), with: .color(dim), lineWidth: 1)
                    var hatch = Path()
                    for d in stride(from: CGFloat(0), through: sz(6), by: sz(2)) {
                        hatch.move(to: CGPoint(x: cap.minX + d, y: cap.maxY))
                        hatch.addLine(to: CGPoint(x: cap.minX, y: cap.maxY - d))
                    }
                    ctx.stroke(hatch, with: .color(dim), lineWidth: 1)
                }
            }
            .frame(width: TranscriptRail.width, height: rail.size.height)
            .allowsHitTesting(false)
            // The hit area is an AppKit view: SwiftUI content with a gesture over the ScrollView makes the hosting view the
            // hit view, and a wheel there never reaches the transcript's scroll view (#1318 r2).
            RailStrip(rail: rail, hover: hover) { p in rail.click(at: p, jumper: jumper, loadEarlier: { model.loadEarlier() }) }
                .frame(width: TranscriptRail.width, height: rail.size.height)
                .accessibilityHidden(true)   // Command-L is the keyboard and VoiceOver route to the same chapters
            if let h = hover.shown, let text = rail.label(h) {
                TranscriptRailLabel(line: text.0, error: text.1)
                    .offset(x: TranscriptRail.width, y: Self.labelY(h, rail))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)   // a pointer aid; Command-L reads the same titles
            }
        }
    }

    /// The label's top: centred on its tick (the cap's at the top), clamped inside the pane.
    static func labelY(_ h: TranscriptRail.Hit, _ rail: TranscriptRail) -> CGFloat {
        var y: CGFloat = 0
        if case .tick(let i) = h, let t = rail.ticks.dropFirst(i).first { y = t.y - sz(20) }
        return min(max(0, y), max(0, rail.size.height - sz(40)))
    }
}

private struct RailProbe: ViewModifier {
    let model: AgentTranscriptModel
    let rail: TranscriptRail
    @ViewBuilder func body(content: Content) -> some View {
        if TranscriptRailView.probe != nil {
            content.onChange(of: rail, initial: true) { _, r in TranscriptRailView.probe?(model, r) }
        } else {
            content
        }
    }
}

private struct RailStrip: NSViewRepresentable {
    let rail: TranscriptRail
    let hover: TranscriptRailHover
    let click: @MainActor (CGPoint) -> Void
    func makeNSView(context: Context) -> TranscriptRailStrip { TranscriptRailStrip() }
    func updateNSView(_ v: TranscriptRailStrip, context: Context) {
        v.rail = rail
        v.hover = hover
        v.click = click
    }
}

/// The rail's 14*s hit area: hover (a tracking area), a click (down and up in the strip) and the wheel, which it hands to
/// the scroll view under the pointer as if the strip were not there. Flipped: points are the rail's own (y from the top).
final class TranscriptRailStrip: NSView {
    var rail: TranscriptRail?
    weak var hover: TranscriptRailHover?
    var click: (@MainActor (CGPoint) -> Void)?
    /// Test seam: how a wheel reaches the scroll view (default: that view's own handling).
    var wheel: @MainActor (NSScrollView, NSEvent) -> Void = { $0.scrollWheel(with: $1) }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { nil }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseEntered(with e: NSEvent) { hover?.move(rail?.hit(at: point(e))) }
    override func mouseMoved(with e: NSEvent) { hover?.move(rail?.hit(at: point(e))) }
    override func mouseExited(with e: NSEvent) { hover?.move(nil) }
    /// Taken, so the up comes here: a click is a down and an up inside the strip.
    override func mouseDown(with e: NSEvent) {}
    override func mouseUp(with e: NSEvent) {
        let p = point(e)
        if bounds.contains(p) { click?(p) }
    }

    override func scrollWheel(with e: NSEvent) {
        guard let root = window?.contentView, let s = Self.scroller(at: e.locationInWindow, under: root) else {
            return super.scrollWheel(with: e)
        }
        wheel(s, e)
    }

    /// The innermost scroll view under `p` (window points): the one a wheel at `p` reaches with the strip out of the way.
    static func scroller(at p: NSPoint, under v: NSView) -> NSScrollView? {
        for s in v.subviews.reversed() where !s.isHidden && !(s is TranscriptRailStrip) && s.convert(s.bounds, to: nil).contains(p) {
            if let inner = scroller(at: p, under: s) { return inner }
            if let sv = s as? NSScrollView { return sv }
        }
        return nil
    }
}

/// The fixed 280x40*s hover label: line one (R904-f1: one line, clipped to its own 20*s, so piled marks never ink the
/// second line, the QA 1047 class), and "error" under it when the chapter's turn failed.
struct TranscriptRailLabel: View {
    let line: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChapterTitle(text: line)
                .frame(width: sz(264), height: sz(20), alignment: .leading)
                .clipped()
            // Always a view (an empty Group would take no frame and the first line would sit in the middle)
            Text(verbatim: error ?? "").foregroundStyle(Neon.magenta).lineLimit(1)
                .frame(width: sz(264), height: sz(20), alignment: .leading)
        }
        .font(Neon.font(11))
        .padding(.horizontal, sz(8))
        .frame(width: sz(280), height: sz(40), alignment: .topLeading)
        .background(Neon.bgTop)
        .overlay(Rectangle().stroke(Neon.stroke, lineWidth: 1))
    }
}
