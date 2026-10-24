// Agent Island (#474) look: a black notch shape (inward top corners, rounded
// bottom) that is the hardware notch plus two ears when collapsed, and a ~480 pt
// session list when expanded — the vibe-notch / Vibe Island design, redrawn in
// Prosper's style. Open and close swap frames instantly: no spring, no bounce,
// no spinner (the standing no-new-animation rule).

import AppKit
import SwiftUI

/// The notch outline: top corners curve outward into the screen edge, bottom
/// corners round inward.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Where the island sits on one screen, in screen coordinates (origin bottom-left).
struct AgentIslandGeometry: Equatable {
    let screen: CGRect
    /// The hardware notch's width; 0 on a display without one.
    let notchWidth: CGFloat
    /// The notch's height, else the menu bar's.
    let barHeight: CGFloat

    static let expandedWidth: CGFloat = 480
    static let rowHeight: CGFloat = 48
    static let maxVisibleRows = 6
    static let listTop: CGFloat = 4
    static let listBottom: CGFloat = 12
    static let closedRadii = (top: CGFloat(6), bottom: CGFloat(14))
    static let openRadii = (top: CGFloat(19), bottom: CGFloat(24))

    /// The ears are square: as wide as the bar is tall.
    var earWidth: CGFloat { barHeight }

    var collapsedSize: CGSize { CGSize(width: notchWidth + 2 * earWidth, height: barHeight) }

    /// Rows (up to 6) plus the prompt cards under blocked rows (`cards`, their
    /// summed `cardHeight`): the island grows for a card instead of clipping it,
    /// up to `maxListHeight`, then the list scrolls.
    func listHeight(rows: Int, cards: CGFloat = 0) -> CGFloat {
        min(CGFloat(min(max(rows, 1), Self.maxVisibleRows)) * Self.rowHeight + cards, maxListHeight)
    }

    func listScrolls(rows: Int, cards: CGFloat = 0) -> Bool {
        rows > Self.maxVisibleRows || CGFloat(rows) * Self.rowHeight + cards > maxListHeight
    }

    /// Leaves 40 pt of the screen below the island.
    var maxListHeight: CGFloat { max(Self.rowHeight, screen.height - barHeight - Self.listTop - Self.listBottom - 40) }

    func expandedSize(rows: Int, cards: CGFloat = 0) -> CGSize {
        CGSize(width: min(screen.width, max(Self.expandedWidth, collapsedSize.width)),
               height: barHeight + Self.listTop + listHeight(rows: rows, cards: cards) + Self.listBottom)
    }

    // Card layout (#475): every row has a fixed height and every row's text is
    // measured to fit its width (AgentCardLayout), so this is exact.
    static let cardPad: CGFloat = 8
    static let cardGap: CGFloat = 4          // below the card, before the next row
    static let cardQuestion: CGFloat = 20    // a question or caption row
    static let cardContextLine: CGFloat = 14
    static let cardContextPad: CGFloat = 4   // inside the context block, top and bottom
    static let cardContextGap: CGFloat = 6   // below the context block
    static let cardButton: CGFloat = 26      // 22 pt button + 4 pt spacing
    static let cardLabelLine: CGFloat = 16   // a too-wide label's continuation row
    static let cardDetailLine: CGFloat = 14  // an option's detail line, inside its button

    // Card widths (W1). The view lays out with these, AgentCardLayout measures
    // against them. The island is `expandedWidth` wide (wider only if the
    // collapsed island is, narrower only on a screen under 480 pt), so a row
    // measured to fit here fits on screen.
    static let listInset: CGFloat = openRadii.top + 2   // inside the shape's straight sides
    static let contextInset: CGFloat = 6
    static let buttonInset: CGFloat = 8
    static let cardSpacing: CGFloat = 8                 // digit | label | spacer | hint
    static let cardSpacerMin: CGFloat = 4
    static let hintInset: CGFloat = 5
    static let cardInner = expandedWidth - 2 * listInset - 2 * cardPad   // question, caption rows
    static let cardContextWidth = cardInner - 2 * contextInset
    static let cardButtonInner = cardInner - 2 * buttonInset
    /// Measured width must leave this much room: SwiftUI rounds glyph runs up.
    static let fitMargin: CGFloat = 2

    // Card fonts: built once, immutable CTFonts, drawn with `Font(ctFont)` and
    // measured by `width`. Fixed sizes: nothing in the island follows
    // ThemeRuntime.scale / sz().
    //
    // Built with the NSFont factories: SF Mono has no public CoreText spelling
    // (.userFixedPitch is Menlo; the SF Mono name and design trait are private).
    // A `static let` initialises lazily on whichever thread touches it first, so
    // AgentIslandController.reload() touches `cardFonts` on main before its timer,
    // poller or any card build; queue work then only reads the stored CTFonts.
    // Never wrap this in MainActor.assumeIsolated: off main that traps (#478).
    nonisolated(unsafe) static let cardFonts = (
        question: NSFont.systemFont(ofSize: 13, weight: .medium) as CTFont,
        context: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) as CTFont,
        digit: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold) as CTFont,
        label: NSFont.systemFont(ofSize: 12, weight: .medium) as CTFont,
        hint: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular) as CTFont,
        detail: NSFont.systemFont(ofSize: 11) as CTFont)
    static var questionFont: CTFont { cardFonts.question }
    static var contextFont: CTFont { cardFonts.context }
    static var digitFont: CTFont { cardFonts.digit }
    static var labelFont: CTFont { cardFonts.label }
    static var hintFont: CTFont { cardFonts.hint }
    static var detailFont: CTFont { cardFonts.detail }

    /// The one width function, for the card's layout on main and the warmer on
    /// the controller queue. CoreText, not NSString drawing: CoreText is
    /// documented thread-safe, the AppKit headers say nothing for sizeWithAttributes.
    static func width(_ s: String, _ f: CTFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func fits(_ s: String, _ f: CTFont, _ w: CGFloat) -> Bool { width(s, f) <= w - fitMargin }

    /// `s` hard-wrapped at character boundaries into rows that each measure as
    /// fitting `w`. Measured, never counted: CJK, emoji and combining marks
    /// take their real width; one Character is never split. Greedy: each row is
    /// the longest prefix that fits (at least one Character), found by binary
    /// search over measured prefixes, so a row costs ~log2(n) measures, not n.
    static func wrap(_ s: String, _ f: CTFont, _ w: CGFloat) -> [String] {
        let cs = Array(s)
        var rows: [String] = [], i = 0
        repeat {
            // cs[i..<lo] fits (or is the one forced Character), cs[i..<hi] does not.
            var lo = cs.count, hi = cs.count
            if !fits(String(cs[i...]), f, w) {
                lo = i + 1
                while hi - lo > 1 {
                    let m = (lo + hi) / 2
                    if fits(String(cs[i..<m]), f, w) { lo = m } else { hi = m }
                }
            }
            rows.append(String(cs[i..<lo]))
            i = lo
        } while i < cs.count
        return rows
    }

    /// `cache`: a test seam (W1-perf); the app always uses `.shared`.
    static func cardHeight(_ card: AgentCard, in cache: AgentCardLayoutCache = .shared) -> CGFloat {
        func context(_ n: Int) -> CGFloat {
            n == 0 ? 0 : CGFloat(n) * cardContextLine + 2 * cardContextPad + cardContextGap
        }
        let body: CGFloat
        switch card {
        case .prompt(let p):
            let l = p.layout(in: cache)
            body = CGFloat(l.question.count + l.caption.count) * cardQuestion + context(l.context.count)
                + CGFloat(p.options.count + 1) * cardButton
                + CGFloat(l.labels.reduce(0) { $0 + $1.count - 1 }) * cardLabelLine
                + CGFloat(l.details.reduce(0) { $0 + $1.count }) * cardDetailLine
        case .context(let lines):
            body = context(AgentCardLayout.contextRows(lines, in: cache).rows.count) + cardButton
        case .changed:
            body = cardQuestion + cardButton
        }
        return 2 * cardPad + body + cardGap
    }

    /// Hanging from the top edge, centred on the screen (and so on the notch).
    func frame(_ size: CGSize) -> CGRect {
        CGRect(x: (screen.midX - size.width / 2).rounded(), y: screen.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// Notched: notch width from the two auxiliary areas, height from the safe
    /// area. Otherwise a pill inside the menu bar (24 pt when it is hidden).
    static func make(frame: CGRect, visibleFrame: CGRect, topLeft: CGRect?, topRight: CGRect?,
                     safeTop: CGFloat) -> AgentIslandGeometry {
        if let l = topLeft, let r = topRight, safeTop > 0 {
            return AgentIslandGeometry(screen: frame, notchWidth: max(0, frame.width - l.width - r.width),
                                       barHeight: safeTop)
        }
        let bar = frame.maxY - visibleFrame.maxY
        return AgentIslandGeometry(screen: frame, notchWidth: 0, barHeight: bar > 0 ? bar : 24)
    }

    /// The display with a notch, else the main one.
    @MainActor static func current() -> AgentIslandGeometry? {
        guard let s = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) ?? NSScreen.main
        else { return nil }
        return make(frame: s.frame, visibleFrame: s.visibleFrame, topLeft: s.auxiliaryTopLeftArea,
                    topRight: s.auxiliaryTopRightArea, safeTop: s.safeAreaInsets.top)
    }
}

@MainActor
final class AgentIslandStore: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var expanded = false
    @Published var geometry: AgentIslandGeometry
    /// Inline row notes: "Attach command copied", "Attached in tmux/ssh …".
    @Published var notices: [AgentSessionKey: String] = [:]
    /// #475: the prompt card under a blocked row, from its last screen read.
    @Published var cards: [AgentSessionKey: AgentCard] = [:]

    init(geometry: AgentIslandGeometry) { self.geometry = geometry }

    /// Cards show under blocked rows only.
    func card(for s: AgentSession) -> AgentCard? { s.state == .blocked ? cards[s.key] : nil }

    var cardsHeight: CGFloat {
        sessions.compactMap(card(for:)).reduce(0) { $0 + AgentIslandGeometry.cardHeight($1) }
    }

    var size: CGSize {
        expanded ? geometry.expandedSize(rows: sessions.count, cards: cardsHeight) : geometry.collapsedSize
    }
}

struct AgentIslandView: View {
    @ObservedObject var store: AgentIslandStore
    var onToggle: () -> Void = {}
    var onRow: (AgentSession) -> Void = { _ in }
    var onAnswer: (AgentSession, AgentPrompt, AgentPromptOption) -> Void = { _, _, _ in }

    private var g: AgentIslandGeometry { store.geometry }

    var body: some View {
        let radii = store.expanded ? AgentIslandGeometry.openRadii : AgentIslandGeometry.closedRadii
        ZStack(alignment: .top) {
            NotchShape(top: radii.top, bottom: radii.bottom).fill(Color.black)
            if store.expanded { expanded } else { collapsed }
        }
        .frame(width: store.size.width, height: store.size.height)
        .environment(\.colorScheme, .dark)
        .transaction { $0.animation = nil }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        let s = AgentIsland.summary(store.sessions)
        let ear = s.earCount
        return Button(action: onToggle) {
            HStack(spacing: 0) {
                Text(s.mostUrgent?.glyph ?? "")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(s.mostUrgent?.color ?? .clear)
                    .frame(width: g.earWidth)
                Color.clear.frame(width: g.notchWidth)
                Text("\(ear.value)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ear.state == .blocked ? ear.state.color : Color.white.opacity(0.9))
                    .frame(width: g.earWidth)
            }
            .frame(height: g.barHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AgentIsland.islandAccessibilityLabel(s))
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            header.frame(height: g.barHeight)
            Group {
                if g.listScrolls(rows: store.sessions.count, cards: store.cardsHeight) {
                    ScrollView(.vertical, showsIndicators: false) { rows }
                } else {
                    rows
                }
            }
            .frame(height: g.listHeight(rows: store.sessions.count, cards: store.cardsHeight), alignment: .top)
            .padding(.top, AgentIslandGeometry.listTop)
            // Inside the shape's straight sides (the top corners curve in by `top`).
            .padding(.horizontal, AgentIslandGeometry.listInset)
            Spacer(minLength: 0)
        }
    }

    /// TimelineView: ages tick once a second, only while the list is open.
    private var rows: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 0) {
                ForEach(store.sessions) { s in
                    AgentIslandRow(session: s, now: ctx.date.timeIntervalSince1970,
                                   notice: store.notices[s.key]) { onRow(s) }
                    if let card = store.card(for: s) {
                        AgentPromptCardView(card: card, onOption: { onAnswer(s, $0, $1) }, onJump: { onRow(s) })
                    }
                }
            }
        }
    }

    /// Count on the left of the notch, per-state counts on its right.
    private var header: some View {
        let s = AgentIsland.summary(store.sessions)
        return HStack(spacing: 0) {
            Text(s.total == 1 ? "1 session" : "\(s.total) sessions")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.9))
            Spacer(minLength: g.notchWidth + 8)
            HStack(spacing: 10) {
                ForEach(AgentState.allCases, id: \.self) { st in
                    if let n = s.counts[st], n > 0 {
                        HStack(spacing: 3) {
                            Text(st.glyph).font(.system(size: 10, weight: .bold)).foregroundStyle(st.color)
                            Text("\(n)").font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(n) \(st.label.lowercased())")
                    }
                }
            }
        }
        .padding(.horizontal, AgentIslandGeometry.openRadii.top + 10)   // lines up with the row glyphs
    }
}

struct AgentIslandRow: View {
    let session: AgentSession
    let now: TimeInterval
    let notice: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Text(session.state.glyph)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(session.state.color)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                        if session.agents > 0 {
                            Text("+\(session.agents) agent\(session.agents == 1 ? "" : "s")")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.5))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 6) {
                        if let notice {
                            Text(notice).foregroundStyle(Color.white.opacity(0.7))
                        } else {
                            Text(session.state.label).foregroundStyle(session.state.color)
                            if session.title != session.name {
                                Text(session.name)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.35))
                            }
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(AgentIsland.age(of: session, now: now))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .frame(height: AgentIslandGeometry.rowHeight - 4)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(hover ? 0.10 : 0.05)))
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(AgentIsland.rowAccessibilityLabel(session, now: now))
    }
}

/// #475 W1: the card's rows as drawn — hidden characters escaped, every row
/// measured with the card's font against its width — and the one rule for which
/// options may answer. The user may only approve what the card showed in full.
struct AgentCardLayout: Equatable {
    /// Question rows, wrapped.
    let question: [String]
    /// Context rows shown: all of them, or past `maxContext` the head plus "… N more lines".
    let context: [String]
    let isOverCap: Bool
    /// Per option: its label rows (more than one = it did not fit one row) and detail rows.
    let labels: [[String]]
    let details: [[String]]
    /// Non-deny options whose label or a detail line does not fit one row; a mode
    /// change is off anyway (`isModeChange`), so never here.
    let tooWide: Set<Int>
    let hidden: Bool
    /// Why approve is off, wrapped; empty when nothing is.
    let caption: [String]

    static let tooLongCaption = "Too long to show in full, open the terminal to approve"
    static let hiddenCaption = "Hidden characters in this prompt, open the terminal to approve"
    static let offTopCaption = "The top of this prompt is off screen, open the terminal to approve"
    static let modeCaption = "Mode changes are made in the terminal"

    private typealias G = AgentIslandGeometry

    init(_ p: AgentPrompt, cache: AgentCardLayoutCache = .shared) {
        question = G.wrap(AgentPrompt.visible(p.question), G.questionFont, G.cardInner)
        let (rows, overCap) = Self.contextRows(p.context, in: cache)
        // No dialog top found: the head may be off screen, so not shown in full either.
        (context, isOverCap) = (rows, overCap || !p.topFound)
        var labels: [[String]] = [], details: [[String]] = [], tooWide: Set<Int> = []
        for o in p.options {
            let label = AgentPrompt.visible(o.label), detail = o.detail.map(AgentPrompt.visible)
            let lw = Self.labelWidth(o), dw = Self.detailWidth(o)
            labels.append(G.wrap(label, G.labelFont, lw))
            details.append(detail.flatMap { G.wrap($0, G.detailFont, dw) })
            let fits = G.fits(label, G.labelFont, lw) && detail.allSatisfy { G.fits($0, G.detailFont, dw) }
            if !fits, o.style(first: false) != .deny, !o.isModeChange { tooWide.insert(o.digit) }
        }
        (self.labels, self.details, self.tooWide) = (labels, details, tooWide)
        hidden = p.hasHiddenCharacters
        // Several apply: hidden characters win, then the off-screen top, then too long, then a mode change.
        let why = hidden ? Self.hiddenCaption : !p.topFound ? Self.offTopCaption
            : (isOverCap || !tooWide.isEmpty) ? Self.tooLongCaption
            : p.options.contains(where: { $0.isModeChange && $0.style(first: false) != .deny }) ? Self.modeCaption : nil
        caption = why.map { G.wrap($0, G.questionFont, G.cardInner) } ?? []
    }

    /// The one rule (W1 item 6): the card's buttons and `AgentPrompt.answer` both
    /// ask this. A "No…" option is always on, a mode change always off (OQ-45).
    func isEnabled(_ o: AgentPromptOption) -> Bool {
        o.style(first: false) == .deny || !(isOverCap || hidden || tooWide.contains(o.digit) || o.isModeChange)
    }

    /// Lines wrapped into measured rows, then capped at `maxContext` rows (cached).
    static func contextRows(_ lines: [String], in cache: AgentCardLayoutCache = .shared) -> (rows: [String], overCap: Bool) {
        cache.get(\.contexts, lines) { measuredContextRows(lines) }
    }

    private static func measuredContextRows(_ lines: [String]) -> (rows: [String], overCap: Bool) {
        let rows = lines.flatMap { G.wrap(AgentPrompt.visible($0), G.contextFont, G.cardContextWidth) }
        let cap = AgentPrompt.maxContext
        guard rows.count > cap else { return (rows, false) }
        return (Array(rows.prefix(cap)) + ["… \(rows.count - cap) more lines"], true)
    }

    /// What is left for the label beside the digit, the minimum spacer and the hint capsule.
    static func labelWidth(_ o: AgentPromptOption) -> CGFloat {
        detailWidth(o) - G.cardSpacing - G.cardSpacerMin
            - (o.hint.map { G.cardSpacing + G.width($0, G.hintFont) + 2 * G.hintInset } ?? 0)
    }

    /// The column right of the digit.
    static func detailWidth(_ o: AgentPromptOption) -> CGFloat {
        G.cardButtonInner - G.width("\(o.digit)", G.digitFont) - G.cardSpacing
    }
}

/// W1-perf: measured layouts by content. The island re-renders every second and
/// asks for a card's layout ~5 times per render; measuring costs ms, hashing µs.
/// The controller queue warms it and main reads it, so it is lock-protected.
/// Keyed on the content alone: every width and font the layout uses is a
/// compile-time constant, so nothing goes stale inside one process. A constant
/// that becomes runtime-variable (a UI scale, a user font) must join the key.
/// Bound: `bound` entries per table, then cleared whole (no LRU; a screen holds a
/// few prompts). Lookup under the lock, measure without it, store under it.
final class AgentCardLayoutCache: @unchecked Sendable {
    static let shared = AgentCardLayoutCache()
    static let bound = 32

    private let lock = NSLock()
    private var built = 0
    fileprivate var layouts: [AgentPrompt: AgentCardLayout] = [:]
    fileprivate var contexts: [[String]: (rows: [String], overCap: Bool)] = [:]

    var count: Int { lock.withLock { layouts.count + contexts.count } }
    func removeAll() { lock.withLock { layouts.removeAll(); contexts.removeAll() } }
    /// Layouts and context rows this instance measured (misses), for the tests.
    var builds: Int { lock.withLock { built } }

    /// Measured outside the lock: two threads missing at once both measure, same result.
    fileprivate func get<K: Hashable, V>(_ table: ReferenceWritableKeyPath<AgentCardLayoutCache, [K: V]>,
                                         _ key: K, _ make: () -> V) -> V {
        if let v = lock.withLock({ self[keyPath: table][key] }) { return v }
        let v = make()
        lock.withLock {
            if self[keyPath: table].count >= Self.bound { self[keyPath: table].removeAll() }
            self[keyPath: table][key] = v
            built += 1
        }
        return v
    }
}

extension AgentPrompt {
    var layout: AgentCardLayout { layout(in: .shared) }
    func layout(in cache: AgentCardLayoutCache) -> AgentCardLayout {
        cache.get(\.layouts, self) { AgentCardLayout(self, cache: cache) }
    }
    var isOverCap: Bool { layout.isOverCap }
    var shownContext: [String] { layout.context }
    /// The card's rule; `answer` checks it too, so a disabled option never sends.
    func isEnabled(_ o: AgentPromptOption) -> Bool { layout.isEnabled(o) }
}

/// #475: what a blocked session asks, under its row. Every row has the fixed
/// height `AgentIslandGeometry.cardHeight` counts and text measured to fit its
/// width, so the island grows by exactly the card and nothing is cut off.
struct AgentPromptCardView: View {
    let card: AgentCard
    var onOption: (AgentPrompt, AgentPromptOption) -> Void = { _, _ in }
    var onJump: () -> Void = {}

    private typealias G = AgentIslandGeometry
    private static let accent = AgentState.working.color
    private static let deny = Color(red: 0.95, green: 0.4, blue: 0.4)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch card {
            case .prompt(let p):
                let l = p.layout
                rows(l.question) { line($0, Color.white) }
                context(l.context)
                rows(l.caption) { line($0, AgentState.blocked.color) }
                ForEach(Array(p.options.enumerated()), id: \.offset) { i, o in
                    option(p, o, label: l.labels[i], detail: l.details[i], enabled: l.isEnabled(o),
                           style: o.style(first: i == 0))
                }
                jump
            case .context(let lines):
                context(AgentCardLayout.contextRows(lines).rows)
                jump
            case .changed:
                line(Self.changedText, AgentState.blocked.color)
                jump
            }
        }
        .padding(G.cardPad)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: G.cardHeight(card) - G.cardGap, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        .padding(.bottom, G.cardGap)
    }

    static let changedText = "Prompt changed, open the terminal"
    static let jumpText = "Open terminal"

    private func rows<V: View>(_ rows: [String], @ViewBuilder _ row: @escaping (String) -> V) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in row(r) }
    }

    /// W1e: every Text the card draws goes through here with the CTFont its
    /// layout measured it with; `textHook` lets a test see each (text, font).
    @MainActor static var textHook: ((String, CTFont) -> Void)?

    private func cardText(_ s: String, _ f: CTFont) -> Text {
        Self.textHook?(s, f)
        return Text(s).font(Font(f))
    }

    private func line(_ text: String, _ color: Color) -> some View {
        cardText(text, G.questionFont)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(height: G.cardQuestion, alignment: .leading)
    }

    @ViewBuilder
    private func context(_ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                rows(lines) { l in
                    cardText(l, G.contextFont)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .frame(height: G.cardContextLine, alignment: .leading)
                }
            }
            .padding(.vertical, G.cardContextPad)
            .padding(.horizontal, G.contextInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            .padding(.bottom, G.cardContextGap)
        }
    }

    private func option(_ p: AgentPrompt, _ o: AgentPromptOption, label: [String], detail: [String],
                        enabled: Bool, style: AgentPromptOption.Style) -> some View {
        let (fill, text): (Color, Color) = switch style {
        case .accent: (Self.accent, Color.white)
        case .deny: (Self.deny.opacity(0.18), Self.deny)
        case .plain: (Color.white.opacity(0.08), Color.white.opacity(0.9))
        }
        let row = G.cardButton - 4
        return button(action: { onOption(p, o) }, fill: fill,
                      height: row + CGFloat(label.count - 1) * G.cardLabelLine + CGFloat(detail.count) * G.cardDetailLine) {
            HStack(alignment: .top, spacing: G.cardSpacing) {
                cardText("\(o.digit)", G.digitFont)
                    .foregroundStyle(text.opacity(0.7))
                    .frame(height: row)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: G.cardSpacing) {
                        cardText(label[0], G.labelFont)
                            .foregroundStyle(text)
                            .lineLimit(1)
                        Spacer(minLength: G.cardSpacerMin)
                        if let hint = o.hint {
                            cardText(hint, G.hintFont)
                                .foregroundStyle(text.opacity(0.6))
                                .padding(.horizontal, G.hintInset).padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                                .fixedSize()
                        }
                    }
                    .frame(height: row)
                    // A too-wide label's rest (the option is off), shown in full.
                    rows(Array(label.dropFirst())) { r in
                        cardText(r, G.labelFont)
                            .foregroundStyle(text)
                            .lineLimit(1)
                            .frame(height: G.cardLabelLine, alignment: .top)
                    }
                    // Continuation or description: dim, under the label.
                    rows(detail) { d in
                        cardText(d, G.detailFont)
                            .foregroundStyle(text.opacity(0.55))
                            .lineLimit(1)
                            .frame(height: G.cardDetailLine, alignment: .top)
                    }
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel((["Answer \(o.digit), \(AgentPrompt.visible(o.label))"] + o.detail.map(AgentPrompt.visible))
            .joined(separator: " "))
    }

    private var jump: some View {
        button(action: onJump, fill: Color.white.opacity(0.08)) {
            Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
            cardText(Self.jumpText, G.labelFont)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.white.opacity(0.7))
    }

    private func button<L: View>(action: @escaping () -> Void, fill: Color, height: CGFloat = G.cardButton - 4,
                                 @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: G.cardSpacing) { label() }
                .padding(.horizontal, G.buttonInset)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }
}
