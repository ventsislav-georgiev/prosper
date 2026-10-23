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

    // Card layout (#475): every part has a fixed height, so this is exact.
    static let cardPad: CGFloat = 8
    static let cardGap: CGFloat = 4          // below the card, before the next row
    static let cardQuestion: CGFloat = 20
    static let cardContextLine: CGFloat = 14
    static let cardContextPad: CGFloat = 4   // inside the context block, top and bottom
    static let cardContextGap: CGFloat = 6   // below the context block
    static let cardButton: CGFloat = 26      // 22 pt button + 4 pt spacing
    static let cardDetailLine: CGFloat = 14  // an option's detail line, inside its button

    static func cardHeight(_ card: AgentCard) -> CGFloat {
        func context(_ n: Int) -> CGFloat {
            n == 0 ? 0 : CGFloat(n) * cardContextLine + 2 * cardContextPad + cardContextGap
        }
        let body: CGFloat
        switch card {
        case .prompt(let p):
            body = cardQuestion + context(p.shownContext.count) + (p.isOverCap ? cardQuestion : 0)
                + CGFloat(p.options.count + 1) * cardButton
                + CGFloat(p.options.reduce(0) { $0 + $1.detail.count }) * cardDetailLine
        case .context(let lines):
            body = context(lines.count) + cardButton
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
            .padding(.horizontal, AgentIslandGeometry.openRadii.top + 2)
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

/// #475: what a blocked session asks, under its row. Every part has the fixed
/// height `AgentIslandGeometry.cardHeight` counts, so the island grows by
/// exactly the card.
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
                line(p.question, Color.white)
                context(p.shownContext)
                if p.isOverCap { line(AgentPrompt.overCapCaption, AgentState.blocked.color) }
                ForEach(Array(p.options.enumerated()), id: \.offset) { i, o in
                    option(p, o, style: o.style(first: i == 0))
                }
                jump
            case .context(let lines):
                context(lines)
                jump
            case .changed:
                line("Prompt changed, open the terminal", AgentState.blocked.color)
                jump
            }
        }
        .padding(G.cardPad)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: G.cardHeight(card) - G.cardGap, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        .padding(.bottom, G.cardGap)
    }

    private func line(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(height: G.cardQuestion, alignment: .leading)
    }

    @ViewBuilder
    private func context(_ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .frame(height: G.cardContextLine, alignment: .leading)
                }
            }
            .padding(.vertical, G.cardContextPad)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            .padding(.bottom, G.cardContextGap)
        }
    }

    private func option(_ p: AgentPrompt, _ o: AgentPromptOption, style: AgentPromptOption.Style) -> some View {
        let (fill, text): (Color, Color) = switch style {
        case .accent: (Self.accent, Color.white)
        case .deny: (Self.deny.opacity(0.18), Self.deny)
        case .plain: (Color.white.opacity(0.08), Color.white.opacity(0.9))
        }
        let enabled = p.isEnabled(o)
        let row = G.cardButton - 4
        return button(action: { onOption(p, o) }, fill: fill,
                      height: row + CGFloat(o.detail.count) * G.cardDetailLine) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(o.digit)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(text.opacity(0.7))
                    .frame(height: row)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(o.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let hint = o.hint {
                            Text(hint)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(text.opacity(0.6))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                                .fixedSize()
                        }
                    }
                    .frame(height: row)
                    // Continuation or description: dim, under the label.
                    ForEach(Array(o.detail.enumerated()), id: \.offset) { _, d in
                        Text(d)
                            .font(.system(size: 11))
                            .foregroundStyle(text.opacity(0.55))
                            .lineLimit(1)
                            .frame(height: G.cardDetailLine, alignment: .top)
                    }
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel((["Answer \(o.digit), \(o.label)"] + o.detail).joined(separator: " "))
    }

    private var jump: some View {
        button(action: onJump, fill: Color.white.opacity(0.08)) {
            Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
            Text("Open terminal").font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.white.opacity(0.7))
    }

    private func button<L: View>(action: @escaping () -> Void, fill: Color, height: CGFloat = G.cardButton - 4,
                                 @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { label() }
                .padding(.horizontal, 8)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }
}
