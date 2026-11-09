import SwiftUI

// #829 Phase 1: the window's live-session lifecycle (Restart agent, Stop, Kill) and the island's
// results shown in the window. Every action is the island controller's own method (its gates,
// runner keys, busy refusal and row texts); the window adds the asking and nothing else.

enum AgentWindowVerb: Equatable {
    case restart, stop, kill
}

/// The confirm strip's question: what, on which session (by key; re-resolved at the answer).
struct AgentWindowConfirm: Equatable {
    let verb: AgentWindowVerb
    let key: AgentSessionKey
}

enum AgentWindowMenuEntry: Equatable {
    case item(String, enabled: Bool, verb: AgentWindowVerb)
    case divider
    /// A disabled line: the gate's reason ("Controls <refusal>").
    case note(String)
}

enum AgentWindowControls {
    /// The header "⋯" and row context menu for a live session: the island row menu's items,
    /// gates and titles (AgentIslandView.Drawn). An item that asks gets an ellipsis; a disabled
    /// one reads the island's title, its reason included. A name dch would read as a flag gets
    /// no item (#627).
    @MainActor
    static func menu(_ s: AgentSession, store: AgentIslandStore) -> [AgentWindowMenuEntry] {
        let d = AgentIslandView.Drawn(session: s, card: nil, open: {}, answer: { _, _ in }, refused: store.resumeGate.refusal,
                                      canStop: AgentIsland.canStop(s), needs: store.restartNeeds)
        var out: [AgentWindowMenuEntry] = []
        if d.controls {
            out.append(.item(d.restartEnabled ? AgentIsland.restartLabel + "…" : d.restartTitle, enabled: d.restartEnabled,
                             verb: .restart))
            out.append(.item(d.stopEnabled ? AgentIsland.stopLabel + "…" : d.stopTitle, enabled: d.stopEnabled, verb: .stop))
            out.append(.divider)
            out.append(.item(AgentIsland.killLabel, enabled: d.killEnabled, verb: .kill))
        }
        if let why = d.refused { out.append(.note("Controls \(why)")) }
        return out
    }

    static let blockedSentence = " It's waiting on a prompt: answer it first."

    /// The strip's line, naming the session by title.
    static func question(_ v: AgentWindowVerb, _ s: AgentSession) -> String {
        let blocked = s.state == .blocked ? blockedSentence : ""
        switch v {
        case .restart:
            return "Restart \(s.title)? Claude Code is paused, then relaunched on the same conversation. This can take minutes."
                + blocked
        case .stop:
            return "Stop \(s.title)? Claude Code is paused and the session ends. Resume it later from History." + blocked
        case .kill:
            return AgentIsland.killQuestion(s.title)
        }
    }

    static func confirmTitle(_ v: AgentWindowVerb) -> String {
        switch v {
        case .restart: "Restart"
        case .stop: "Stop"
        case .kill: "Kill"
        }
    }

    /// Spec 3.5: a row text that is a running text ("Restarting…", "Pausing…", "Stopping…"):
    /// dch is typing into Claude's composer, so the window's input waits. nil: no lock.
    static func lock(_ action: String?) -> String? {
        action.flatMap { AgentIsland.runningTexts.contains($0) ? $0 : nil }
    }

    /// "Restarting: wait for it to finish": the running text without its ellipsis.
    static func lockPlaceholder(_ running: String) -> String {
        "\(running.hasSuffix("…") ? String(running.dropLast()) : running): wait for it to finish"
    }

    /// G0: the island row's own rule: a notice ("Attach command copied") wins over the row's
    /// action text ("Stopping…", "Restarted", a failure).
    @MainActor
    static func notice(_ store: AgentIslandStore, _ key: AgentSessionKey) -> String? {
        store.notices[key] ?? store.actions[key]
    }

    /// The dir strip's fixed height (shown or not, the sidebar's list reserves it).
    static var stripHeight: CGFloat { sz(24) }
}

// MARK: - Menus

/// The menu's items, for a SwiftUI Menu or a context menu. Observes the store, so a gate
/// that changes while the menu's row is drawn is read afresh.
struct AgentSessionMenuItems: View {
    @ObservedObject var store: AgentIslandStore
    let session: AgentSession
    let ask: (AgentWindowVerb) -> Void

    var body: some View {
        ForEach(Array(AgentWindowControls.menu(session, store: store).enumerated()), id: \.offset) { _, e in
            switch e {
            case .item(let title, let enabled, let verb):
                Button(title) { ask(verb) }.disabled(!enabled)
            case .divider:
                Divider()
            case .note(let text):
                Text(verbatim: text)
            }
        }
    }
}

/// The header's "⋯": always there, one fixed size, the title line's last control. Off when
/// there is nothing to offer (no store, or a name dch would read as a flag and no refusal).
struct AgentSessionMenuButton: View {
    let store: AgentIslandStore?
    let session: AgentSession
    let ask: (AgentWindowVerb) -> Void

    var body: some View {
        Menu {
            if let store { AgentSessionMenuItems(store: store, session: session, ask: ask) }
        } label: {
            Image(systemName: "ellipsis").font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        // A borderless Menu's own minimum is 20 pt at every UI scale; framed, it scales with the
        // header and leaves the narrowest title line its room (#822's pill included).
        .frame(width: sz(18), height: sz(18))
        .disabled(store.map { AgentWindowControls.menu(session, store: $0).isEmpty } ?? true)
        .help("Restart, stop or kill this session")
        .accessibilityLabel("Session actions")
    }
}

// MARK: - Strips

/// R5: the inline question at the top of the detail pane. Drawn over the conversation's top,
/// so it never moves the header, the transcript or the input box. The question wraps whole on
/// its own lines and the buttons sit under it: nothing is squeezed at the narrowest pane.
struct AgentConfirmStrip: View {
    let text: String
    let action: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: sz(6)) {
            HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
                Image(systemName: "exclamationmark.triangle.fill").font(Neon.font(11)).foregroundStyle(AgentState.blocked.color)
                Text(text).font(Neon.font(11.5)).foregroundStyle(Neon.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: sz(8)) {
                AgentPillButton(title: "Cancel", icon: "xmark", tint: Neon.textSecondary, action: cancel)
                    .keyboardShortcut(.cancelAction)
                AgentPillButton(title: action, icon: "exclamationmark.octagon", tint: Neon.magenta, action: confirm)
                    .accessibilityLabel(text)
            }
        }
        .padding(.horizontal, sz(16)).padding(.vertical, sz(8))
        // minWidth 0: the strip is the pane's width exactly; a wrapped Text's fraction of a
        // point over (seen at 0.7) stays inside the padding, never past the window.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(Neon.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Neon.stroke).frame(height: 1) }
    }
}

/// G0: every dir's last dir-wide line (Restart all, Stop all, Kill all tallies, edit failures,
/// a failed New session) at the bottom of the sidebar; nothing while there is none. One line of
/// a fixed height, drawn over the list's reserved bottom, so it never moves a row.
struct AgentDirStatusStrip: View {
    @ObservedObject var store: AgentIslandStore

    var body: some View {
        let text = store.dirStatus
        if !text.isEmpty {
            HStack(spacing: sz(6)) {
                Image(systemName: "info.circle").foregroundStyle(Neon.blue)
                Text(text).foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(Neon.font(10.5))
            .padding(.horizontal, sz(14))
            .frame(height: AgentWindowControls.stripHeight)
            .frame(maxWidth: .infinity)
            .background(Neon.sidebar)
            .overlay(alignment: .top) { Rectangle().fill(Neon.stroke).frame(height: 1) }
            .help(text)
        }
    }
}

/// Spec 3.5: the input box under the store's eye: while a Restart or Stop's running text shows
/// on the session, Send, Interrupt and the prompt's answers are off and the box says why.
struct AgentLockedInteraction: View {
    @ObservedObject var store: AgentIslandStore
    let model: AgentWindowInteraction
    let session: AgentSession
    let open: () -> Void

    var body: some View {
        AgentInteractionPane(model: model, session: session, open: open,
                             lock: AgentWindowControls.lock(store.actions[session.key]))
    }
}
