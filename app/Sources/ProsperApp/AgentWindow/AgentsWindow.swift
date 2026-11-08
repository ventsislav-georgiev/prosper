import AppKit
import SwiftUI

// #797 Agent window D1: the "Agent Sessions" window. A sidebar of every dch session (fed by
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
    static let title = "Agent Sessions"

    // Seams (QA #626 INFO-7: show and teardown run in tests with a window never put on screen).
    var island: () -> AgentIslandController = { .shared }
    var build: (AgentWindowModel) -> NSWindow = { AgentsWindow.makeWindow($0) }
    var present: (NSWindow) -> Void = { win in
        DockPolicy.windowDidShow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
    var dismissed: (NSWindow) -> Void = { DockPolicy.windowDidHide($0) }

    func show() {
        if let window { return present(window) }
        let island = island()
        let model = AgentWindowModel()
        model.interaction.controller = island
        model.bind(island.store)
        island.onStoreChanged = { [weak model, weak island] in model?.bind(island?.store) }
        island.onHoldChanged = { [weak model] in model?.interaction.holdChanged() }
        let win = build(model)
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
        present(win)
        model.setVisible(win.occlusionState.contains(.visible))
    }

    /// The window, built but not shown (tests render it offscreen from here).
    static func makeWindow(_ model: AgentWindowModel) -> AgentsNSWindow {
        let hosting = NSHostingController(rootView: Themed { AgentWindowRootView(model: model) })
        let win = AgentsNSWindow(contentViewController: hosting)
        win.model = model
        win.title = title
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
        let island = island()
        island.onStoreChanged = nil
        island.onHoldChanged = nil
        dismissed(win)
        DispatchQueue.main.async { win.contentViewController = nil }
    }
}

/// ⌘W closes; up/down move the selection and Return opens it in the terminal while
/// the sidebar has the focus (QA #626 INFO-2): the last click landed in it and Tab has
/// not moved on since. A text field or the input box keeps every key.
final class AgentsNSWindow: NSWindow {
    weak var model: AgentWindowModel?
    /// The last click was in the sidebar (where the window starts).
    var sidebarFocused = true

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { sidebarFocused = event.locationInWindow.x < sz(290) }
        if event.type == .keyDown, event.keyCode == 48 { sidebarFocused = false }   // Tab: focus moves on
        if event.type == .keyDown, sidebarFocused, !(firstResponder is NSText), let model, Self.handle(event, model) { return }
        super.sendEvent(event)
    }

    /// Plain up, down and Return only; anything with a modifier passes through.
    @MainActor static func handle(_ event: NSEvent, _ model: AgentWindowModel) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 126: model.move(-1)                   // up
        case 125: model.move(1)                    // down
        case 36, 76: return model.openSelected()   // Return, keypad Enter; a History row passes on
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
        // QA #626 INFO-6: the island off is the window's only message.
        if !model.hasStore {
            AgentEmptyState(icon: "rectangle.dashed", title: "Agent Island is off",
                            detail: "Turn on Agent Island in Settings › Extensions to list your dch sessions here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Neon.bgBottom)
        } else {
            split
        }
    }

    var split: some View {
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
                Text(AgentsWindow.title).font(Neon.font(13, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                    .lineLimit(1)
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
                Rectangle().fill(Neon.stroke).frame(height: 1)
                // #798: the prompt pinned at the bottom, the input box under it.
                AgentInteractionPane(model: model.interaction, session: s, open: { model.openSelected() })
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

// MARK: - #798: the input box, interrupt and prompt answers

/// Under the conversation: the prompt panel (pinned), the last action's notice, the input box.
struct AgentInteractionPane: View {
    @ObservedObject var model: AgentWindowInteraction
    let session: AgentSession
    let open: () -> Void

    var canSend: Bool {
        (session.state == .idle || session.state == .done) && !model.busy && AgentWindowDriver.message(model.draft) != nil
    }

    var placeholder: String {
        switch session.state {
        case .blocked: "Answer the prompt above first"
        case .working: "Claude is working. Type now, send when it's done"
        case .idle, .done: "Message Claude. Return sends, Shift-Return adds a line"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(8)) {
            AgentPromptPanel(model: model, open: open)
            if let n = model.notice { AgentActionNotice(text: n, open: open) }
            HStack(alignment: .bottom, spacing: sz(8)) {
                ZStack(alignment: .topLeading) {
                    AgentComposerField(text: $model.draft, onSubmit: { if canSend { model.send() } })
                    if model.draft.isEmpty {
                        Text(placeholder).font(Neon.font(12)).foregroundStyle(Neon.textSecondary)
                            .lineLimit(1).padding(.horizontal, sz(9)).padding(.vertical, sz(7))
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: sz(60))
                .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.bgBottom))
                .overlay(RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke, lineWidth: 1))
                VStack(spacing: sz(6)) {
                    if session.state == .working {
                        AgentPillButton(title: "Interrupt", icon: "stop.fill", tint: Neon.magenta, enabled: !model.busy) {
                            model.interrupt()
                        }
                        .help("Press Esc in the session")
                    }
                    AgentPillButton(title: "Send", icon: "arrow.up", tint: Neon.blue, enabled: canSend) { model.send() }
                }
            }
        }
        .padding(.horizontal, sz(16)).padding(.vertical, sz(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Neon.card)
    }
}

struct AgentPillButton: View {
    let title: String
    let icon: String
    let tint: Color
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(Neon.font(11, weight: .semibold)).foregroundStyle(tint)
                .padding(.horizontal, sz(10)).padding(.vertical, sz(5))
                .background(Capsule().fill(tint.opacity(0.12)))
                .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// Why the window did not (or could not confirm it did) act, with the way out.
struct AgentActionNotice: View {
    let text: String
    let open: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: sz(8)) {
            Image(systemName: "exclamationmark.triangle.fill").font(Neon.font(11)).foregroundStyle(AgentState.blocked.color)
            Text(text).font(Neon.font(11.5)).foregroundStyle(Neon.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: sz(4))
            OpenInTerminalButton(action: open, compact: true)
        }
    }
}

struct AgentPromptPanel: View {
    @ObservedObject var model: AgentWindowInteraction
    let open: () -> Void

    var body: some View {
        switch model.panel {
        case .none:
            EmptyView()
        case .reading:
            status("ellipsis.circle", "Reading the prompt…")
        case .held:
            status("checkmark.shield", AgentWindowText.held)
        case .terminal(let why, let tail):
            VStack(alignment: .leading, spacing: sz(6)) {
                AgentActionNotice(text: why, open: open)
                screenLines(Array(tail.suffix(4)))
            }
        case .prompt(let w):
            prompt(w)
        }
    }

    func status(_ icon: String, _ text: String) -> some View {
        HStack(spacing: sz(6)) {
            Image(systemName: icon).foregroundStyle(Neon.textSecondary)
            Text(text).foregroundStyle(Neon.textSecondary)
            Spacer(minLength: 0)
        }
        .font(Neon.font(11.5))
    }

    func screenLines(_ lines: [String]) -> some View {
        Text(lines.map(AgentPrompt.visible).joined(separator: "\n"))
            .font(Neon.font(10.5, design: .monospaced)).foregroundStyle(Neon.textSecondary)
            .lineLimit(Self.contextLines).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let contextLines = 8

    func prompt(_ w: AgentWindowPrompt) -> some View {
        let p = w.screen.prompt
        let context = p.context.filter { !AgentPrompt.isChipLine($0) }
        return VStack(alignment: .leading, spacing: sz(6)) {
            if !context.isEmpty { screenLines(context) }
            Text(AgentPrompt.visible(p.question)).font(Neon.font(12.5, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if w.kind == .preview, !p.preview.isEmpty { screenLines(p.preview) }
            ForEach(w.buttons, id: \.digit) { o in option(w, o) }
            if let other = w.other {
                HStack(spacing: sz(8)) {
                    Text("\(other.digit).").font(Neon.font(11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Neon.textSecondary)
                    TextField("Your own answer", text: $model.otherText)
                        .textFieldStyle(.roundedBorder).font(Neon.font(12))
                        .onSubmit { model.sendOther() }
                    AgentPillButton(title: "Answer", icon: "arrow.up", tint: Neon.blue,
                                    enabled: !model.busy && AgentWindowDriver.otherText(model.otherText) != nil) {
                        model.sendOther()
                    }
                }
            }
            if w.kind == .multi {
                HStack {
                    Spacer(minLength: 0)
                    AgentPillButton(title: "Submit", icon: "checkmark", tint: Neon.blue,
                                    enabled: !model.busy && !w.enabled.isEmpty) {
                        model.submitPicks()
                    }
                }
            }
            if !w.caption.isEmpty {
                Text(w.caption.joined(separator: " ")).font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func option(_ w: AgentWindowPrompt, _ o: AgentPromptOption) -> some View {
        let on = w.enabled.contains(o.digit) && !model.busy
        let ticked = model.picks.contains(o.digit)
        return Button {
            switch w.kind {
            case .choose: model.answer(o)
            case .preview: model.choosePreview(o)
            case .multi: if ticked { model.picks.remove(o.digit) } else { model.picks.insert(o.digit) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
                if w.kind == .multi {
                    Image(systemName: ticked ? "checkmark.square.fill" : "square")
                        .font(Neon.font(12)).foregroundStyle(ticked ? Neon.blue : Neon.textSecondary)
                } else {
                    Text("\(o.digit).").font(Neon.font(11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Neon.textSecondary)
                }
                VStack(alignment: .leading, spacing: sz(2)) {
                    Text(AgentPrompt.visible(o.label)).font(Neon.font(12, weight: .medium))
                        .foregroundStyle(o.style(first: o.digit == 1) == .deny ? Neon.magenta : Neon.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !o.detail.isEmpty {
                        Text(o.detail.map(AgentPrompt.visible).joined(separator: " ")).font(Neon.font(10.5))
                            .foregroundStyle(Neon.textSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if w.kind == .preview, w.screen.caret == o.digit {
                    Text("previewed").font(Neon.font(9.5)).foregroundStyle(Neon.textSecondary)
                }
            }
            .padding(.horizontal, sz(10)).padding(.vertical, sz(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: sz(7)).fill(Neon.cardHi))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .opacity(on ? 1 : 0.45)
    }
}

/// The input box: an NSTextView, so Return sends and Shift-Return adds a line, and the
/// window's sidebar keys never reach it (`firstResponder is NSText`).
struct AgentComposerField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = AgentComposerTextView(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: sz(4), height: sz(6))
        tv.delegate = context.coordinator
        tv.setAccessibilityLabel("Message Claude")
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? AgentComposerTextView else { return }
        if tv.string != text { tv.string = text }
        tv.font = .systemFont(ofSize: sz(12))
        tv.textColor = NSColor(Neon.textPrimary)
        tv.insertionPointColor = NSColor(Neon.textPrimary)
        tv.onSubmit = { context.coordinator.parent.onSubmit() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentComposerField
        init(_ parent: AgentComposerField) { self.parent = parent }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

final class AgentComposerTextView: NSTextView {
    var onSubmit: () -> Void = {}

    /// Return or keypad Enter alone sends; Shift-Return adds a line; an IME's marked text keeps Return.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
            if mods.isEmpty { return onSubmit() }
            if mods == .shift { return insertNewlineIgnoringFieldEditor(nil) }
        }
        super.keyDown(with: event)
    }
}
