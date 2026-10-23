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

    func listHeight(rows: Int) -> CGFloat { CGFloat(min(max(rows, 1), Self.maxVisibleRows)) * Self.rowHeight }

    func expandedSize(rows: Int) -> CGSize {
        CGSize(width: min(screen.width, max(Self.expandedWidth, collapsedSize.width)),
               height: barHeight + Self.listTop + listHeight(rows: rows) + Self.listBottom)
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

    init(geometry: AgentIslandGeometry) { self.geometry = geometry }

    var size: CGSize {
        expanded ? geometry.expandedSize(rows: sessions.count) : geometry.collapsedSize
    }
}

struct AgentIslandView: View {
    @ObservedObject var store: AgentIslandStore
    var onToggle: () -> Void = {}
    var onRow: (AgentSession) -> Void = { _ in }

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
                if store.sessions.count > AgentIslandGeometry.maxVisibleRows {
                    ScrollView(.vertical, showsIndicators: false) { rows }
                } else {
                    rows
                }
            }
            .frame(height: g.listHeight(rows: store.sessions.count), alignment: .top)
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
