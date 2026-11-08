import AppKit
import SwiftUI

// #797 Agent window D1: the "Agents" window. A sidebar of every dch session (fed by
// Agent Island's store, no new fork or poll) and the selected session's read-only
// conversation (spike A). Built on open and torn down on close, like
// MarketplaceWindow: a closed window leaves no view, model, timer or watch behind.

@MainActor
final class AgentsWindow {
    static let shared = AgentsWindow()

    private(set) var window: NSWindow?
    private(set) var model: AgentWindowModel?
    private var observers: [NSObjectProtocol] = []
    var isOpen: Bool { window != nil }

    func show() {
        if let window {
            DockPolicy.windowDidShow(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let island = AgentIslandController.shared
        let model = AgentWindowModel()
        model.bind(island.store)
        island.onStoreChanged = { [weak model, weak island] in model?.bind(island?.store) }
        let win = Self.makeWindow(model)
        window = win
        self.model = model

        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.teardown(win) }
            },
            // Miniaturized, behind other windows fully, on another Space, the app hidden:
            // the transcript stops and the age clock with it (design "Energy").
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: win, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.setVisible(win.occlusionState.contains(.visible)) }
            },
        ]
        DockPolicy.windowDidShow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        model.setVisible(win.occlusionState.contains(.visible))
    }

    /// The window, built but not shown (tests render it offscreen from here).
    static func makeWindow(_ model: AgentWindowModel) -> AgentsNSWindow {
        let hosting = NSHostingController(rootView: Themed { AgentWindowRootView(model: model) })
        let win = AgentsNSWindow(contentViewController: hosting)
        win.model = model
        win.title = "Agents"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.titlebarAppearsTransparent = true
        win.identifier = NSUserInterfaceItemIdentifier("prosper.agentsWindow")
        let s = ThemeRuntime.scale
        win.setContentSize(NSSize(width: 1000 * s, height: 680 * s))
        win.contentMinSize = NSSize(width: 640 * s, height: 420 * s)
        SettingsWindow.applyWindowOpacity(win)
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("ProsperAgentsWindow")
        if !win.setFrameUsingName("ProsperAgentsWindow") { win.centerOnScreen() }
        win.clampToContentMinSize()
        return win
    }

    private func teardown(_ win: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        model?.close()
        model = nil
        window = nil
        AgentIslandController.shared.onStoreChanged = nil
        DockPolicy.windowDidHide(win)
        DispatchQueue.main.async { win.contentViewController = nil }
    }
}

/// ⌘W closes; up/down move the selection and Return opens it in the terminal, from
/// anywhere in the window (D1 has no text input to steal them from).
final class AgentsNSWindow: NSWindow {
    weak var model: AgentWindowModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let model, Self.handle(event, model) { return }
        super.sendEvent(event)
    }

    /// Plain up, down and Return only; anything with a modifier passes through.
    @MainActor static func handle(_ event: NSEvent, _ model: AgentWindowModel) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 126: model.move(-1)                   // up
        case 125: model.move(1)                    // down
        case 36, 76: model.openSelected()          // Return, keypad Enter
        default: return false
        }
        return true
    }
}

// MARK: - Views

/// The state colors of the island; idle reads in the theme's secondary text (the
/// island's dim white disappears on a light theme).
func agentStateColor(_ s: AgentState?) -> Color {
    guard let s, s != .idle else { return Neon.textSecondary }
    return s.color
}

struct AgentWindowRootView: View {
    @ObservedObject var model: AgentWindowModel
    /// False for offscreen evidence only (the transcript without its ScrollView).
    var scrolls = true

    var body: some View {
        HStack(spacing: 0) {
            AgentSidebarView(model: model)
                .frame(width: sz(290))
                .background(Neon.sidebar)
            Rectangle().fill(Neon.stroke).frame(width: 1)
            AgentDetailView(model: model, transcript: model.transcript, scrolls: scrolls)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Neon.bgBottom)
    }
}

struct AgentSidebarView: View {
    @ObservedObject var model: AgentWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: sz(6)) {
                Text("Agents").font(Neon.font(13, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                Spacer(minLength: 0)
                let n = model.sections.filter { $0.title != "History" }.reduce(0) { $0 + $1.rows.count }
                if n > 0 {
                    Text(n == 1 ? "1 session" : "\(n) sessions").font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
                }
            }
            .padding(.horizontal, sz(14)).padding(.top, sz(30)).padding(.bottom, sz(8))
            if !model.hasStore {
                AgentEmptyState(icon: "rectangle.dashed", title: "Agent Island is off",
                                detail: "Turn on Agent Island in Settings › Extensions to list your dch sessions here.")
            } else if model.sections.isEmpty {
                AgentEmptyState(icon: "terminal", title: "No agent sessions",
                                detail: "Sessions started with dch show up here.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: sz(2)) {
                            ForEach(model.sections) { section in
                                AgentSectionHeader(title: section.title, count: section.rows.count)
                                ForEach(section.rows) { row in
                                    Button { model.select(row.id) } label: {
                                        AgentSidebarRowView(row: row, selected: model.selection == row.id)
                                    }
                                    .buttonStyle(.plain)
                                    .id(row.id)
                                }
                            }
                        }
                        .padding(.horizontal, sz(8)).padding(.bottom, sz(12))
                    }
                    .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct AgentSectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: sz(5)) {
            if title == AgentSidebar.needsYouTitle {
                Circle().fill(AgentState.blocked.color).frame(width: sz(5), height: sz(5))
            }
            Text(title.uppercased()).font(Neon.font(9.5, weight: .bold)).tracking(0.8)
                .foregroundStyle(title == AgentSidebar.needsYouTitle ? AgentState.blocked.color : Neon.textSecondary)
            Text("\(count)").font(Neon.font(9.5, weight: .medium).monospacedDigit()).foregroundStyle(Neon.textSecondary.opacity(0.8))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, sz(8)).padding(.top, sz(12)).padding(.bottom, sz(4))
    }
}

struct AgentSidebarRowView: View {
    let row: AgentSidebar.Row
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
            Text(row.state?.glyph ?? "○")
                .font(Neon.font(11, weight: .bold))
                .foregroundStyle(row.state == nil ? Neon.textSecondary.opacity(0.6) : agentStateColor(row.state))
                .frame(width: sz(14))
            VStack(alignment: .leading, spacing: sz(3)) {
                HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
                    Text(row.title).font(Neon.font(12.5, weight: .medium))
                        .foregroundStyle(row.state == nil ? Neon.textSecondary : Neon.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: sz(4))
                    if !row.age.isEmpty {
                        Text(row.age).font(Neon.font(10).monospacedDigit()).foregroundStyle(Neon.textSecondary)
                    }
                }
                // The PR chips whole, else their count, else none: never a cut-off chip.
                ViewThatFits(in: .horizontal) {
                    detailLine(row.prs)
                    if !row.prs.isEmpty { detailLine([row.prCount == 1 ? "1 PR" : "\(row.prCount) PRs"]) }
                    detailLine([])
                }
            }
        }
        .padding(.horizontal, sz(10)).padding(.vertical, sz(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: sz(7)).fill(selected ? Neon.cardHi : Color.clear))
        .overlay(alignment: .leading) {
            if selected { RoundedRectangle(cornerRadius: 1).fill(Neon.blue).frame(width: 2).padding(.vertical, sz(7)) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.title, row.detail, row.age.isEmpty ? nil : "\(row.age) ago"].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension AgentSidebarRowView {
    func detailLine(_ chips: [String]) -> some View {
        HStack(spacing: sz(5)) {
            Text(row.detail).font(Neon.font(10.5))
                .foregroundStyle(row.state == .blocked ? agentStateColor(.blocked) : Neon.textSecondary)
                .lineLimit(1)
            ForEach(chips, id: \.self) { pr in
                Text(pr).font(Neon.font(9.5, weight: .medium, design: .monospaced)).foregroundStyle(Neon.blue)
                    .padding(.horizontal, sz(4)).padding(.vertical, sz(1))
                    .background(RoundedRectangle(cornerRadius: sz(3)).fill(Neon.blue.opacity(0.12)))
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }
}

struct AgentEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: sz(8)) {
            Image(systemName: icon).font(Neon.font(22)).foregroundStyle(Neon.textSecondary)
            Text(title).font(Neon.font(13, weight: .semibold)).foregroundStyle(Neon.textPrimary)
            Text(detail).font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(sz(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentDetailView: View {
    @ObservedObject var model: AgentWindowModel
    @ObservedObject var transcript: AgentTranscriptModel
    /// False for offscreen evidence (no ScrollView).
    var scrolls = true

    var body: some View {
        if let row = model.selectedRow, let s = row.session {
            VStack(spacing: 0) {
                AgentSessionHeader(row: row, session: s, cwd: transcript.cwd, open: { model.openSelected() })
                if let store = model.store { AgentNoticeLine(store: store, key: s.key) }
                Rectangle().fill(Neon.stroke).frame(height: 1)
                AgentTranscriptView(model: transcript, scrolls: scrolls, openTerminal: { model.openSelected() },
                                    ownsLifecycle: false)
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .clipped()
            }
        } else if let row = model.selectedRow, let r = row.record {
            AgentHistoryDetail(row: row, record: r, store: model.store, resume: { model.resumeSelected() })
        } else {
            AgentEmptyState(icon: "sidebar.left", title: "Select a session",
                            detail: "Up and down move through the list; Return opens it in the terminal.")
        }
    }
}

struct AgentSessionHeader: View {
    let row: AgentSidebar.Row
    let session: AgentSession
    let cwd: String?
    let open: () -> Void

    var project: String {
        if let cwd { return (cwd as NSString).abbreviatingWithTildeInPath }
        return session.key.dir == DchCommand.defaultSocketDir ? "dch \(session.name)" : "dch \(session.name) in \(session.key.dir)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            // The whole title and the labelled button when they fit, else the icon button.
            ViewThatFits(in: .horizontal) {
                titleLine(compact: false)
                titleLine(compact: true)
            }
            HStack(spacing: sz(6)) {
                Image(systemName: "folder").font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
                Text(project).font(Neon.font(11, design: .monospaced)).foregroundStyle(Neon.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                let extra = [row.detail.split(separator: " · ").dropFirst().joined(separator: " · "),
                             row.age.isEmpty ? "" : "\(row.age) ago"].filter { !$0.isEmpty }
                if !extra.isEmpty {
                    Text("· " + extra.joined(separator: " · ")).font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
                        .lineLimit(1).layoutPriority(-1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, sz(16)).padding(.top, sz(30)).padding(.bottom, sz(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Neon.card)
    }

    func titleLine(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: sz(8)) {
            Text(row.title).font(Neon.font(15, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            AgentStateChip(state: session.state)
            Spacer(minLength: sz(8))
            OpenInTerminalButton(action: open, compact: compact)
        }
    }
}

struct AgentStateChip: View {
    let state: AgentState
    var body: some View {
        HStack(spacing: sz(4)) {
            Text(state.glyph).font(Neon.font(9, weight: .bold))
            Text(state.label).font(Neon.font(10, weight: .semibold))
        }
        .foregroundStyle(agentStateColor(state))
        .padding(.horizontal, sz(7)).padding(.vertical, sz(2))
        .background(Capsule().fill(agentStateColor(state).opacity(0.14)))
        .fixedSize()
    }
}

/// The island's inline note for the row ("Attach command copied", "Attached in tmux/ssh…").
struct AgentNoticeLine: View {
    @ObservedObject var store: AgentIslandStore
    let key: AgentSessionKey
    var body: some View {
        if let text = store.notices[key] {
            HStack(spacing: sz(6)) {
                Image(systemName: "info.circle").foregroundStyle(Neon.blue)
                Text(text).foregroundStyle(Neon.textSecondary)
                Spacer(minLength: 0)
            }
            .font(Neon.font(11))
            .padding(.horizontal, sz(16)).padding(.vertical, sz(6))
            .background(Neon.card)
        }
    }
}

struct AgentHistoryDetail: View {
    let row: AgentSidebar.Row
    let record: DchHistoryRecord
    let store: AgentIslandStore?
    let resume: () -> Void

    var body: some View {
        VStack(spacing: sz(10)) {
            Image(systemName: "clock.arrow.circlepath").font(Neon.font(26)).foregroundStyle(Neon.indigo)
            Text(row.title).font(Neon.font(15, weight: .semibold)).foregroundStyle(Neon.textPrimary).lineLimit(1)
            Text([row.detail, row.age.isEmpty ? nil : "\(row.age) ago"].compactMap { $0 }.joined(separator: " · "))
                .font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
            if !record.cwd.isEmpty {
                Text((record.cwd as NSString).abbreviatingWithTildeInPath).font(Neon.font(11, design: .monospaced))
                    .foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            if let store { AgentResumeButton(store: store, record: record, resume: resume) }
        }
        .padding(sz(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Resume through the island (its gate, its status line).
struct AgentResumeButton: View {
    @ObservedObject var store: AgentIslandStore
    let record: DchHistoryRecord
    let resume: () -> Void
    var body: some View {
        VStack(spacing: sz(6)) {
            Button(action: resume) {
                Label("Resume", systemImage: "play.fill").font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.blue)
                    .padding(.horizontal, sz(12)).padding(.vertical, sz(5))
                    .background(Capsule().fill(Neon.blue.opacity(0.12)))
                    .overlay(Capsule().stroke(Neon.blue.opacity(0.45), lineWidth: 1))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(!store.resumeGate.isOK)
            if let status = store.historyActions[record.id] {
                Text(status).font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
            }
        }
    }
}
