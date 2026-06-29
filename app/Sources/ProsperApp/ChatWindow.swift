import AppKit
import SwiftUI

/// Hosts the coding-agent chat window (the "prompt a goal like Claude Code" UX).
/// Built on open, torn down on close — same discipline as `SettingsWindow` (a
/// closed-but-alive hosting view keeps rendering and burns CPU). Opening the window
/// starts the residency swap in the background (`AgentController.warmUp`) so the
/// model is loading while the user types the first goal; closing it releases the
/// agent model so inline completions resume.
@MainActor
final class ChatWindow {
    static let shared = ChatWindow()
    /// Marks the window as theme-driven so AppDelegate refreshes its opacity/size
    /// when the appearance settings change live. Distinct from Settings because the
    /// minimum content size differs.
    static let themedIdentifier = NSUserInterfaceItemIdentifier("prosper.chatWindow")

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// True while the window exists. While open, the agent model stays resident
    /// between turns (no unload/reload per prompt) — see `AgentController`.
    var isOpen: Bool { window != nil }

    /// Open the window. If `goal` is non-nil, prefill the composer with it (the
    /// RunnerPanel `goal:` entry point) — the user still presses Send.
    func show(prefill goal: String? = nil) {
        if let window {
            if let goal { ChatComposerModel.shared.draft = goal }
            DockPolicy.windowDidShow(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            AgentController.shared.warmUp()
            return
        }
        if let goal { ChatComposerModel.shared.draft = goal }

        let hosting = NSHostingController(rootView: Themed { ChatRootView() })
        let win = ChatClosableWindow(contentViewController: hosting)
        win.title = "Prosper Coding Agent"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        // NOT movable-by-background: it would steal mouse-down from the transcript so
        // text could never be selected/copied (dragging the body moved the window).
        // The transparent title bar still drags the window.
        win.isMovableByWindowBackground = false
        win.identifier = ChatWindow.themedIdentifier
        win.appearance = NSAppearance(named: .darkAqua)
        let s = ThemeRuntime.scale
        win.setContentSize(NSSize(width: 760 * s, height: 720 * s))
        // Min height keeps room above the input field for the full 8-row slash-command
        // suggestion popup (~210pt) plus the composer + header.
        win.contentMinSize = NSSize(width: 560 * s, height: 520 * s)
        // Sets backgroundColor + isOpaque from the live opacity (replaces the old
        // hardcoded opaque bgTop; identical at opacity 1.0).
        SettingsWindow.applyWindowOpacity(win)
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("ProsperChatWindow")
        if !win.setFrameUsingName("ProsperChatWindow") { win.centerOnScreen() }
        // A frame autosaved before the min was raised restores below contentMinSize
        // (which only blocks *user* resize, not a programmatic restore). Grow it back
        // so the 8-row suggestion popup always has room above the field.
        let saved = win.contentRect(forFrameRect: win.frame).size
        let min = win.contentMinSize
        if saved.width < min.width || saved.height < min.height {
            win.setContentSize(NSSize(width: max(saved.width, min.width),
                                      height: max(saved.height, min.height)))
        }
        window = win

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let obs = self.closeObserver { NotificationCenter.default.removeObserver(obs) }
                self.closeObserver = nil
                self.window = nil
                DockPolicy.windowDidHide(win)
                DispatchQueue.main.async { win.contentViewController = nil }
                AgentController.shared.chatWindowDidClose()
            }
        }
        DockPolicy.windowDidShow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        AgentController.shared.warmUp()
    }
}

private final class ChatClosableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Match ⌘W by keycode (kVK_ANSI_W = 13), layout-independent: under a non-Latin
        // layout charactersIgnoringModifiers is the layout glyph, not "w".
        if event.modifierFlags.contains(.command),
           event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Holds the composer draft so the window-opener can prefill it before the view
/// builds (e.g. from the RunnerPanel `goal:` entry).
@MainActor
final class ChatComposerModel: ObservableObject {
    static let shared = ChatComposerModel()
    @Published var draft = ""
    private init() {}
}

// MARK: - Slash-command suggestions

/// Drives the slash-command autocomplete popup attached to the chat composer.
/// Only active when the draft starts with `/` and the command token hasn't been
/// completed yet (no whitespace after it) — a `/` in the middle of text never
/// triggers it. The Coordinator computes matches as the user types; the popup view
/// observes this; selection is applied back into the text view via `apply`.
@MainActor
final class SlashSuggest: ObservableObject {
    @Published private(set) var matches: [SlashCommand] = []
    @Published var selected = 0
    /// Set by the composer's Coordinator: replaces the whole draft with `/<name> `.
    var apply: ((String) -> Void)?

    var visible: Bool { !matches.isEmpty }

    /// The character range of the recognized `/token` at the start of `text`, or nil
    /// when the leading token doesn't (prefix-)match any installed command. Used both
    /// for popup visibility and for coloring the token in the field.
    static func tokenRange(in text: String, commands: [SlashCommand]) -> (range: NSRange, query: String)? {
        guard text.hasPrefix("/") else { return nil }
        let afterSlash = text.dropFirst()
        // Token ends at the first whitespace/newline; once present, the command name is
        // "committed" and we stop suggesting.
        if let stop = afterSlash.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            // Whole token is `/name`; only keep coloring if it exactly matches a command.
            let name = String(afterSlash[afterSlash.startIndex..<stop]).lowercased()
            guard commands.contains(where: { $0.name == name }) else { return nil }
            let len = (text as NSString).range(of: "/" + name).length
            return (NSRange(location: 0, length: len), name)
        }
        let query = String(afterSlash).lowercased()
        guard commands.contains(where: { $0.name.hasPrefix(query) }) else { return nil }
        return (NSRange(location: 0, length: text.utf16.count), query)
    }

    func update(for text: String) {
        let all = CommandStore.all()
        guard text.hasPrefix("/"),
              !text.dropFirst().contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else {
            matches = []; return
        }
        let query = String(text.dropFirst()).lowercased()
        let hits = query.isEmpty ? all : all.filter { $0.name.hasPrefix(query) }
        // Cap so the upward list can't grow past the window top. Type to narrow.
        matches = Array(hits.prefix(8))
        if selected >= matches.count { selected = 0 }
    }

    /// Move the highlight, clamped. Index 0 = best match (rendered at the bottom,
    /// nearest the field); higher indices sit above it — so ↑ is +1, ↓ is −1.
    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = min(max(selected + delta, 0), matches.count - 1)
    }

    func accept() {
        guard visible, selected < matches.count else { return }
        apply?("/\(matches[selected].name) ")
        dismiss()
    }

    func acceptByClick(_ index: Int) {
        guard index < matches.count else { return }
        apply?("/\(matches[index].name) ")
        dismiss()
    }

    func dismiss() { matches = [] }
}

/// Floating, non-obstructive list of slash-command matches shown above the composer.
/// Arrow keys move `selected` (handled in the composer); clicking a row applies it.
private struct SlashSuggestPopup: View {
    @ObservedObject var suggest: SlashSuggest

    var body: some View {
        // Reversed: best match (index 0) sits at the BOTTOM, nearest the input field;
        // weaker matches stack upward. ↑ walks up the list, ↓ back down toward the field.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggest.matches.enumerated()).reversed(), id: \.element.id) { idx, cmd in
                let isSel = idx == suggest.selected
                HStack(spacing: sz(8)) {
                    Text("/\(cmd.name)")
                        .font(Neon.font(12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Neon.blue)
                    Text(preview(cmd.body))
                        .font(Neon.font(11))
                        .foregroundStyle(Neon.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, sz(10)).padding(.vertical, sz(5))
                .background(isSel ? Neon.blue.opacity(0.18) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { suggest.acceptByClick(idx) }
            }
        }
        .padding(.vertical, sz(4))
        .frame(minWidth: sz(260), maxWidth: sz(460), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.card)
            .overlay(RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke)))
        .shadow(color: .black.opacity(0.35), radius: sz(10), y: sz(4))
        .fixedSize()
    }

    /// First non-empty line of the command body, as a one-line hint.
    private func preview(_ body: String) -> String {
        body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

/// Carries the composer input field's bounds up to the root as an `Anchor` (SwiftUI
/// converts coordinates for us), so the floating suggestion overlay can pin its bottom
/// just above the field regardless of where the field actually sits.
private struct ComposerFieldAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

// MARK: - Root view

struct ChatRootView: View {
    private let controller = AgentController.shared
    @State private var atBottom = true
    // Slash-command suggestions live here (not in the composer) so the popup can float
    // as a root-level overlay ABOVE the composer's AppKit field — over the persona row
    // and chat transcript (both AppKit-backed: SwiftUI ScrollView == NSScrollView), which
    // a sibling overlay inside the composer would draw *under*. `fieldTop` is the input
    // field's Y in the root's coordinate space; the popup's bottom is pinned just above it.
    @StateObject private var suggest = SlashSuggest()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Neon.stroke)
            // Slim indeterminate activity line (Claude Code-style) — visible only while
            // the agent is actually working; gone the instant the turn stops.
            if isWorking { WorkingBar().transition(.opacity) }
            transcript
            if let approval = controller.pendingApprovals.first {
                approvalBar(approval)
            }
            // Its own view so the AppKit-backed composer isn't rebuilt on every streamed
            // token — it reads only `phase`/`workingDirectory`/`draft` (all stable during
            // streaming), so `@Observable` skips its body while `items` churns.
            ComposerBarView(suggest: suggest)
        }
        .background(ChatBackdrop())
        .foregroundStyle(Neon.textPrimary)
        .animation(.easeInOut(duration: 0.2), value: isWorking)
        // Float the suggestions above the input field without affecting layout. The
        // field publishes its bounds as an anchor; here we resolve it into this overlay's
        // coordinates and pin the popup's BOTTOM 6pt above the field's top, so it grows
        // upward over the persona row + messages and never covers the field.
        .overlayPreferenceValue(ComposerFieldAnchorKey.self) { anchor in
            if suggest.visible, let anchor {
                GeometryReader { proxy in
                    let field = proxy[anchor]
                    SlashSuggestPopup(suggest: suggest)
                        .fixedSize()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, field.minX)
                        .padding(.bottom, proxy.size.height - field.minY + 6)
                }
            }
        }
    }

    /// True only while the agent is doing async work (model load / generating). Drives
    /// the activity line — not `isActive`, which also covers `.awaitingApproval` (paused
    /// on the user, nothing running).
    private var isWorking: Bool {
        switch controller.phase { case .running, .loadingModel: return true; default: return false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: sz(8)) {
            VStack(alignment: .leading, spacing: sz(1)) {
                SessionTitleField()
                Text(AgentModelRegistry.model(for: Preferences.agentModel).label)
                    .font(Neon.font(.caption2)).foregroundStyle(Neon.textSecondary)
            }
            Spacer(minLength: sz(8))
            phaseIndicator
            // New conversation — only when the current one has content to leave behind.
            if !controller.items.isEmpty && !controller.isActive {
                Button(action: { controller.newSession() }) {
                    Label("New", systemImage: "square.and.pencil").labelStyle(.iconOnly)
                }
                .buttonStyle(.neon)
                .help("New session")
            }
            HistoryMenu()
            // Any active phase is stoppable — including the model load (stop there
            // cancels the load and unloads).
            if controller.isActive {
                Button(role: .destructive, action: { controller.stop() }) {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.neon)
                .help("Stop")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, sz(12)).padding(.vertical, sz(7))
    }

    // Running / model-loading progress now renders inline below the last message
    // (`processingRow`). The header only flags states that aren't tied to a position
    // in the transcript.
    @ViewBuilder private var phaseIndicator: some View {
        switch controller.phase {
        case .awaitingApproval:
            Text("Waiting for approval").font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
        case .error(let msg):
            Text(msg).font(Neon.font(.caption)).foregroundStyle(Neon.magenta).lineLimit(1)
        default:
            EmptyView()
        }
    }


    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: sz(10)) {
                    ForEach(controller.items) { ItemView(item: $0) }
                    // Processing indicator sits right below the last message so it's
                    // clear where we are in the round-trip.
                    processingRow
                    // Goals typed while busy, not yet sent — dimmed, recallable via ↑.
                    ForEach(controller.queued) { queuedBubble($0.text) }
                    // Scroll target for "jump to latest", and the at-bottom probe.
                    // Toggling on the lazy marker's realization is a cheap bool — no
                    // geometry, no preference. A full-content GeometryReader re-fired
                    // BottomOffsetKey on EVERY streamed token and EVERY scroll tick
                    // (content maxY never stops moving), so scrolling up mid-run stacked
                    // two layout-invalidation streams on the main thread and froze.
                    // Here the marker simply leaves the realized region when scrolled up
                    // → atBottom=false → probe goes quiet, exactly when we need it to.
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(sz(16))
            }
            // O(1) revision counter instead of diffing the whole items array each
            // token: it bumps on every mutation (incl. in-place streamed deltas).
            .onChange(of: controller.transcriptRevision) { _, _ in followBottom(proxy) }
            .onChange(of: controller.phase) { _, _ in followBottom(proxy) }
            .onChange(of: controller.queued.count) { _, _ in followBottom(proxy) }
            .overlay(alignment: .bottom) {
                if !atBottom { jumpToBottomButton(proxy) }
            }
            // Opening a window onto an existing (resumed) transcript: land at the
            // latest message, not the top. Deferred a tick so the lazy rows lay out
            // first, else scrollTo targets a not-yet-built bottom marker.
            .onAppear {
                guard !controller.items.isEmpty else { return }
                atBottom = true
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// Auto-scroll only when the user is already parked at the bottom; otherwise leave
    /// their scroll position alone (the jump button is shown instead). No animation:
    /// this fires per streamed delta, and animated scrolls at token rate stack up and
    /// rubber-band.
    private func followBottom(_ proxy: ScrollViewProxy) {
        guard atBottom else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    private func jumpToBottomButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            atBottom = true
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        } label: {
            Label("Jump to latest", systemImage: "arrow.down")
                .font(Neon.font(.caption).bold())
                .padding(.horizontal, sz(12)).padding(.vertical, sz(6))
                .background(Capsule().fill(Neon.card)
                    .overlay(Capsule().stroke(Neon.stroke)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Neon.blue)
        .padding(.bottom, sz(10))
        .shadow(radius: sz(4))
    }

    @ViewBuilder private var processingRow: some View {
        switch controller.phase {
        case .loadingModel(let p, let status):
            processingLabel(p > 0 ? "\(status) \(Int(p * 100))%" : status)
        case .running:
            // Tick once a second so the elapsed readout stays live. Only mounted while
            // running, so it adds no idle CPU (and the window detaches its content view
            // when closed, pausing the timeline entirely). Anchor `from:` to the run
            // start — a stable value — not `.now`: `.now` is re-evaluated on every body
            // rebuild, and during streaming the body rebuilds per token, so the schedule
            // churned ~50×/s and froze the window.
            TimelineView(.periodic(from: controller.runStartedAt ?? .now, by: 1)) { ctx in
                let secs = controller.runStartedAt.map { Int(ctx.date.timeIntervalSince($0)) } ?? 0
                processingLabel("Working… \(AgentController.formatDuration(max(0, secs)))")
            }
        default:
            EmptyView()
        }
    }

    private func processingLabel(_ text: String) -> some View {
        HStack(spacing: sz(8)) {
            ProgressView().controlSize(.small)
            Text(text).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            Spacer()
        }
        .padding(.vertical, sz(2))
    }

    private func queuedBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: sz(3)) {
            HStack(spacing: sz(5)) {
                Image(systemName: "clock").font(Neon.font(.caption2))
                Text("Queued — press ↑ to edit").font(Neon.font(.caption2))
            }
            .foregroundStyle(Neon.textSecondary)
            Text(text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(0.55)
    }

    // MARK: Approval

    private func approvalBar(_ req: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: sz(8)) {
            Text("Approve \(approvalNoun(req.kind))?").font(Neon.font(.subheadline).bold())
            Text(req.summary).font(Neon.font(.caption, design: .monospaced))
                .foregroundStyle(Neon.textSecondary).lineLimit(3)
            HStack {
                Button("Approve") { controller.respond(to: req, decision: .accept) }
                    .buttonStyle(.neon)
                Button("Always") { controller.respond(to: req, decision: .acceptForSession) }
                    .buttonStyle(.neon)
                Button("Deny") { controller.respond(to: req, decision: .decline) }
                    .buttonStyle(.neon)
                Spacer()
            }
        }
        .padding(sz(12))
        .background(RoundedRectangle(cornerRadius: sz(10)).fill(Neon.card).overlay(
            RoundedRectangle(cornerRadius: sz(10)).stroke(Neon.magenta.opacity(0.5))))
        .padding(.horizontal, sz(16)).padding(.bottom, sz(8))
    }

    private func approvalNoun(_ kind: ApprovalRequest.Kind) -> String {
        switch kind { case .command: return "command"; case .fileChange: return "file changes"; case .permission: return "permission" }
    }

}

// MARK: - Backdrop

/// The chat window's gradient/frost backdrop as its own view, so an opacity/frost
/// change (backdropTick) re-renders only this — not the whole chat root — and
/// without `Themed`'s `.id()` teardown. See SettingsBackground.
private struct ChatBackdrop: View {
    @ObservedObject private var theme = ThemeStore.shared
    var body: some View {
        ZStack {
            // Frost: blurred desktop behind the translucent neon gradient.
            if ThemeRuntime.frost { VisualEffectBackground() }
            LinearGradient(colors: [Neon.bgTop, Neon.bgBottom],
                           startPoint: .top, endPoint: .bottom)
                .opacity(ThemeRuntime.backdropFillOpacity)
        }
    }
}

// MARK: - Composer bar

/// Working-directory chip, persona picker, and the prompt input. Isolated from
/// `ChatRootView` so streamed-token `items` churn doesn't rebuild the AppKit-backed
/// `ChatComposer`: it reads only `phase`, `workingDirectory`, and the draft — all stable
/// while the agent streams — so `@Observable` skips its body during a run.
private struct ComposerBarView: View {
    private let controller = AgentController.shared
    @ObservedObject private var composer = ChatComposerModel.shared
    // Owned by ChatRootView so the popup can float as a root overlay (see there).
    @ObservedObject var suggest: SlashSuggest
    @State private var composerHeight: CGFloat = 22
    @State private var persona = Preferences.agentPersona
    // Cached persona list. Filesystem-backed (AgentPersonaStore scans a dir + reads
    // files), so it's loaded once on appear. Seeded with the built-ins (a pure constant,
    // no IO) so there's a label before the first appear.
    @State private var personas: [AgentPersona] = AgentPersonaStore.builtIns

    var body: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            // Working directory + persona live here, next to the prompt they scope.
            HStack(spacing: sz(8)) {
                Button(action: chooseDirectory) {
                    Label(dirLabel, systemImage: "folder")
                        .font(Neon.font(.caption2)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(Neon.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Change working directory")
                Spacer(minLength: sz(8))
                PersonaPicker(persona: $persona, personas: personas)
            }

            inputRow
        }
        .padding(sz(12))
        .onChange(of: persona) { _, _ in controller.applyAgentConfigChange() }
        .onAppear { personas = AgentPersonaStore.all() }
    }

    private var dirLabel: String {
        URL(fileURLWithPath: controller.workingDirectory).lastPathComponent
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: sz(8)) {
            ZStack(alignment: .leading) {
                if composer.draft.isEmpty {
                    Text("Describe a goal — ⏎ to send, ⇧⏎ for a new line")
                        .font(Neon.font(NSFont.systemFontSize))
                        .foregroundStyle(Neon.textSecondary)
                        .allowsHitTesting(false)
                }
                ChatComposer(text: $composer.draft, height: $composerHeight,
                             suggest: suggest, onSubmit: send, onRecall: recall)
                    .frame(height: composerHeight)
            }
            .padding(.horizontal, sz(12)).padding(.vertical, sz(6))
            .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.card)
                .overlay(RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke)))
            // Publish the field's bounds so the root overlay can float the popup above it.
            .anchorPreference(key: ComposerFieldAnchorKey.self, value: .bounds) { $0 }
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(Neon.font(.title2)) }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Neon.blue : Neon.textSecondary)
                .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        !composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && controller.phase != .awaitingApproval
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: controller.workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            controller.setWorkingDirectory(url.path)
        }
    }

    private func send() {
        var goal = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, controller.phase != .awaitingApproval else { return }
        // Slash-command expansion (F5): "/name args" → the stored template.
        if let expanded = CommandStore.expand(goal) { goal = expanded }
        composer.draft = ""
        suggest.dismiss()
        controller.submit(goal: goal)
    }

    /// ↑ in an empty composer: pull the last queued (unsent) goal back for editing.
    private func recall() {
        if let text = controller.recallLastQueued() { composer.draft = text }
    }
}

// MARK: - Activity line

/// Slim indeterminate progress bar: a neon segment that sweeps left↔right forever
/// while the agent works. Shown under the header, hidden when idle. The travel range
/// keeps the segment fully in-bounds, so no clipping needed.
private struct WorkingBar: View {
    // phaseAnimator is Core-Animation/GPU-backed (≈0 CPU per frame) and loops a phase
    // sequence forever — so unlike a one-shot `withAnimation(repeatForever)` in onAppear,
    // an interrupted animation can't strand the segment at an edge.
    private static let fill = LinearGradient(
        colors: [Neon.blue.opacity(0), Neon.blueBright, Neon.blue.opacity(0)],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        GeometryReader { geo in
            let segW = max(60, geo.size.width * 0.3)
            let travel = geo.size.width - segW
            Capsule(style: .continuous)
                .fill(Self.fill)
                .frame(width: segW)
                .phaseAnimator([false, true]) { view, atRight in
                    view.offset(x: atRight ? travel : 0)
                } animation: { _ in .easeInOut(duration: 1.0) }
        }
        .frame(height: sz(2))
        .background(Neon.blue.opacity(0.07))
    }
}

// MARK: - Session title

/// Editable session name in the header — the same label shown in History. Click to
/// edit, ⏎ commits (persists to the store via `renameSession`). Empty = a fresh
/// conversation not yet named; shows a placeholder until the first goal seeds a title.
private struct SessionTitleField: View {
    private let controller = AgentController.shared
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                // SwiftUI TextField (not an NSViewRepresentable): the header body re-runs
                // on transcript churn, and a representable's field editor resigned on that
                // relayout → controlTextDidEndEditing fired → edit mode exited instantly.
                // @FocusState survives the rebuilds; blur is detected via onChange below.
                TextField("Coding Agent", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .foregroundStyle(Neon.textPrimary)
                    // Edit mode reads as an input: subtle filled, outlined slot.
                    .padding(.horizontal, sz(6)).padding(.vertical, sz(1))
                    .background(RoundedRectangle(cornerRadius: sz(5))
                        .fill(Neon.card)
                        .overlay(RoundedRectangle(cornerRadius: sz(5)).stroke(Neon.blue.opacity(0.5))))
                    .onSubmit { commit() }
                    // Click away → commit. Ignore the initial false (focus lands a tick
                    // after appear); only a true→false transition is a real blur.
                    .onChange(of: focused) { _, f in if !f && editing { commit() } }
                    .onAppear {
                        focused = true
                        // Select the whole name so a click drops the user into a
                        // ready-to-replace field. SwiftUI has no select-all hook, so poke
                        // the window's field editor once it's first responder.
                        selectAllWhenReady()
                    }
            } else {
                Text(controller.sessionTitle.isEmpty ? "Coding Agent" : controller.sessionTitle)
                    .foregroundStyle(controller.sessionTitle.isEmpty ? Neon.textSecondary : Neon.textPrimary)
                    .onTapGesture { text = controller.sessionTitle; editing = true }
            }
        }
        .font(Neon.font(13, weight: .semibold))
        .lineLimit(1)
        .onAppear { text = controller.sessionTitle }
        .onChange(of: controller.sessionTitle) { _, new in text = new }
    }

    private func commit() {
        guard editing else { return }   // ⏎ and blur both end editing — commit once
        editing = false
        controller.renameSession(text)
    }

    /// Select the whole field once its field editor becomes first responder. The editor
    /// isn't attached on the tick `.onAppear` fires, so poll a few short ticks until the
    /// key window's first responder is the editing `NSText`, then select all.
    private func selectAllWhenReady(_ attempt: Int = 0) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSText {
            editor.selectAll(nil)
        } else if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                selectAllWhenReady(attempt + 1)
            }
        }
    }
}

// MARK: - History menu

/// Header control listing recent persisted sessions; selecting one restores its
/// transcript and arms a lazy re-attach (the Codex thread resumes on the next prompt).
/// Disabled while a run is live (one resident coding model at a time).
private struct HistoryMenu: View {
    private let controller = AgentController.shared
    @State private var sessions: [AgentSessionStore.Summary] = []
    @State private var showing = false
    @State private var query = ""

    private var filtered: [AgentSessionStore.Summary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.lowercased().contains(q)
                || URL(fileURLWithPath: $0.cwd).lastPathComponent.lowercased().contains(q)
                || $0.model.lowercased().contains(q)
        }
    }

    var body: some View {
        Button { showing.toggle() } label: {
            Label("History", systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
        }
        .buttonStyle(.neon)
        .help("History")
        .fixedSize()
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            popoverBody
        }
        .task { sessions = await controller.recentSessions() }
        .onChange(of: controller.phase) { _, _ in
            // Refresh the list when a run finishes (a new/updated session was saved) —
            // including failed runs (phase .error), which also persist a transcript.
            if !controller.isActive { Task { sessions = await controller.recentSessions() } }
        }
    }

    private var popoverBody: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: sz(8)) {
                Image(systemName: "magnifyingglass")
                    .font(Neon.font(12)).foregroundColor(Neon.blue)
                TextField("Search sessions\u{2026}", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundColor(Neon.textPrimary)
            }
            .padding(.horizontal, sz(12)).padding(.vertical, sz(9))

            Rectangle().fill(Neon.stroke).frame(height: 1)

            // Session list
            ScrollView {
                LazyVStack(spacing: sz(2)) {
                    if filtered.isEmpty {
                        Text(sessions.isEmpty ? "No saved sessions" : "No matches")
                            .font(Neon.font(.caption)).foregroundColor(Neon.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, sz(24))
                    } else {
                        ForEach(filtered) { s in
                            SessionRow(summary: s, disabled: controller.isActive,
                                isCurrent: s.id == controller.currentSessionID,
                                onSelect: {
                                    controller.resume(s)
                                    showing = false
                                },
                                onDelete: {
                                    Task {
                                        await controller.deleteSession(s)
                                        sessions.removeAll { $0.id == s.id }
                                    }
                                })
                        }
                    }
                }
                .padding(sz(6))
            }
            .frame(maxHeight: sz(360))

            Rectangle().fill(Neon.stroke).frame(height: 1)

            // Footer: session count
            HStack {
                Image(systemName: "tray.full")
                    .font(Neon.font(10)).foregroundColor(Neon.textSecondary)
                Text(footerText)
                    .font(Neon.font(11)).foregroundColor(Neon.textSecondary)
                Spacer()
            }
            .padding(.horizontal, sz(12)).padding(.vertical, sz(8))
        }
        .frame(width: sz(460))
        .background(LinearGradient(colors: [Neon.bgTop, Neon.bgBottom],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .tint(Neon.blue)
    }

    private var footerText: String {
        let total = sessions.count
        let shown = filtered.count
        let unit = total == 1 ? "session" : "sessions"
        return query.isEmpty ? "\(total) \(unit)" : "\(shown) of \(total) \(unit)"
    }
}

/// One row in the history popover: title, relative date, cwd + model badges.
private struct SessionRow: View {
    let summary: AgentSessionStore.Summary
    let disabled: Bool
    let isCurrent: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: sz(4)) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: sz(4)) {
                    HStack(alignment: .top, spacing: sz(8)) {
                        Text(summary.title)
                            .font(Neon.font(13, weight: .medium))
                            .foregroundColor(Neon.textPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.relative.localizedString(for: summary.updatedAt, relativeTo: Self.now))
                            .font(Neon.font(11))
                            .foregroundColor(Neon.textSecondary)
                            .fixedSize()
                    }
                    HStack(spacing: sz(6)) {
                        badge(systemImage: "folder", URL(fileURLWithPath: summary.cwd).lastPathComponent)
                        badge(systemImage: "cpu", summary.model)
                        if isCurrent { badge(systemImage: "dot.radiowaves.left.and.right", "open") }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())   // full-width hit/hover area
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)

            // Delete from disk. Hidden until hover; never offered for the open session.
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(Neon.font(12))
                    .foregroundColor(Neon.magenta)
            }
            .buttonStyle(.plain)
            // Always rendered (dim until hover), never `opacity 0`: hover-gated
            // visibility went stale on list reflow — after a delete the next row slid
            // under a stationary cursor, `.onHover` didn't re-fire (no mouse movement),
            // so the trash stayed hidden and the first click only re-armed hover instead
            // of deleting (the "every-other click does nothing" bug).
            .opacity(isCurrent ? 0 : (hovering ? 1 : 0.4))
            .disabled(isCurrent)
            .help(isCurrent ? "Can't delete the open session" : "Delete session")
            // Reserve a fixed slot so the row width is stable and the trailing edge
            // stays clear of the scroller (where hover used to be swallowed).
            .frame(width: sz(20))
        }
        .padding(.horizontal, sz(10)).padding(.vertical, sz(8))
        .padding(.trailing, sz(6))
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                .fill(hovering ? Neon.blue.opacity(0.12) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                    .strokeBorder(Neon.blue.opacity(hovering ? 0.4 : 0), lineWidth: 1)))
        .onHover { hovering = $0 }
    }

    private func badge(systemImage: String, _ text: String) -> some View {
        HStack(spacing: sz(3)) {
            Image(systemName: systemImage).font(Neon.font(8))
            Text(text).font(Neon.font(10)).lineLimit(1)
        }
        .foregroundColor(Neon.blueBright.opacity(0.85))
        .padding(.horizontal, sz(6)).padding(.vertical, sz(2))
        .background(Capsule().fill(Neon.blue.opacity(0.10))
            .overlay(Capsule().strokeBorder(Neon.blue.opacity(0.22), lineWidth: 0.5)))
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    // ponytail: captured once per row build — relative labels don't need live ticking.
    private static var now: Date { Date() }
}

// MARK: - Item rendering

private struct ItemView: View {
    let item: AgentItem

    var body: some View {
        switch item {
        case .user(_, let text):
            bubble(text, role: "You", color: Neon.blueBright, textColor: Neon.textPrimary)
        case .assistant(_, let text, let reasoning):
            if reasoning {
                DisclosureGroup("Reasoning") {
                    Text(text).font(Neon.font(.caption, design: .monospaced))
                        .foregroundStyle(Neon.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Neon.font(.caption)).tint(Neon.textSecondary)
            } else {
                // Agent body in robotic terminal-green — distinct from the cyan-blue
                // actor labels (You / Agent) so the machine voice reads apart at a glance.
                bubble(text, role: "Agent", color: Neon.blue, textColor: Neon.terminal)
            }
        case .toolCall(_, let name, let args, let status, let output):
            toolCard(name: name, args: args, status: status, output: output)
        case .fileDiff(_, let path, let diff, let change):
            diffCard(path: path, diff: diff, change: change)
        case .plan(_, let steps):
            planCard(steps)
        case .error(_, let message):
            Text(message).font(Neon.font(.callout)).foregroundStyle(Neon.magenta)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .note(_, let text):
            Text(text).font(Neon.font(.caption2)).foregroundStyle(Neon.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func bubble(_ text: String, role: String, color: Color, textColor: Color) -> some View {
        VStack(alignment: .leading, spacing: sz(3)) {
            Text(role).font(Neon.font(.caption2).bold()).foregroundStyle(color)
            Text(text).textSelection(.enabled)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toolCard(name: String, args: String, status: ToolCall.Status, output: String) -> some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            HStack(spacing: sz(6)) {
                Image(systemName: statusIcon(status)).foregroundStyle(statusColor(status))
                Text(name).font(Neon.font(.caption).bold())
                Text(args).font(Neon.font(.caption2, design: .monospaced))
                    .foregroundStyle(Neon.textSecondary).lineLimit(1)
            }
            if !output.isEmpty {
                Text(output).font(Neon.font(.caption2, design: .monospaced))
                    .foregroundStyle(Neon.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(sz(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.card).overlay(
            RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke)))
    }

    private func diffCard(path: String, diff: String, change: FileDiff.Change) -> some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            Text("\(changeVerb(change)) \(path)").font(Neon.font(.caption).bold())
            Text(diff).font(Neon.font(.caption2, design: .monospaced))
                .foregroundStyle(Neon.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(sz(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.card).overlay(
            RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke)))
    }

    private func planCard(_ steps: [PlanStep]) -> some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            Text("Plan").font(Neon.font(.caption).bold())
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: sz(6)) {
                    Image(systemName: planIcon(step.state)).foregroundStyle(planColor(step.state))
                    Text(step.title).font(Neon.font(.caption)).strikethrough(step.state == .done)
                }
            }
        }
        .padding(sz(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.card).overlay(
            RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke)))
    }

    private func statusIcon(_ s: ToolCall.Status) -> String {
        switch s { case .running: return "circle.dotted"; case .succeeded: return "checkmark.circle.fill"; case .failed: return "xmark.circle.fill" }
    }
    private func statusColor(_ s: ToolCall.Status) -> Color {
        switch s { case .running: return Neon.textSecondary; case .succeeded: return Neon.blue; case .failed: return Neon.magenta }
    }
    private func changeVerb(_ c: FileDiff.Change) -> String {
        switch c { case .add: return "Create"; case .modify: return "Edit"; case .delete: return "Delete" }
    }
    private func planIcon(_ s: PlanStep.State) -> String {
        switch s { case .pending: return "circle"; case .inProgress: return "circle.lefthalf.filled"; case .done: return "checkmark.circle.fill" }
    }
    private func planColor(_ s: PlanStep.State) -> Color {
        switch s { case .pending: return Neon.textSecondary; case .inProgress: return Neon.blueBright; case .done: return Neon.blue }
    }
}

// MARK: - Persona picker

/// Persona selector (F3b): picks the system-prompt preset the agent runs under.
/// Switching takes effect on the next turn (the parent watches `persona` and respawns
/// the harness config). Its own `@State` for the popover keeps presentation off the
/// parent's per-token recompute path — an open popover re-anchored every streamed token
/// froze the window. Takes only value-type inputs (Binding + Equatable array), no
/// controller observation and no closure, so SwiftUI can skip it while the agent streams.
private struct PersonaPicker: View {
    @Binding var persona: String
    let personas: [AgentPersona]
    @State private var showing = false

    var body: some View {
        let title = personas.first { $0.id == persona }?.title ?? persona
        return Button { showing.toggle() } label: {
            Label(title, systemImage: "person.crop.circle")
                .labelStyle(.titleAndIcon)
                .font(Neon.font(.caption2))
        }
        .buttonStyle(.neon)
        .controlSize(.small)
        .help("Switch persona")
        .fixedSize()
        .popover(isPresented: $showing, arrowEdge: .bottom) { popoverBody }
    }

    private var popoverBody: some View {
        let others = personas.filter { $0.id != persona }
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: sz(2)) {
                    if others.isEmpty {
                        Text("No other personas")
                            .font(Neon.font(.caption)).foregroundColor(Neon.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, sz(24))
                    } else {
                        ForEach(others) { p in
                            Button {
                                persona = p.id
                                Preferences.agentPersona = p.id
                                showing = false
                            } label: {
                                HStack(alignment: .top, spacing: sz(8)) {
                                    Image(systemName: "person.crop.circle")
                                        .font(Neon.font(13)).foregroundColor(Neon.blue)
                                    VStack(alignment: .leading, spacing: sz(2)) {
                                        Text(p.title)
                                            .font(Neon.font(13, weight: .medium))
                                            .foregroundColor(Neon.textPrimary)
                                        if p.isBuiltIn {
                                            Text("Built-in")
                                                .font(Neon.font(10))
                                                .foregroundColor(Neon.textSecondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.horizontal, sz(10)).padding(.vertical, sz(8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(sz(6))
            }
            .frame(maxHeight: sz(280))
        }
        .frame(width: sz(240))
        .background(LinearGradient(colors: [Neon.bgTop, Neon.bgBottom],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
        .tint(Neon.blue)
    }
}

// MARK: - Composer (AppKit-backed)

/// Multi-line text input that SwiftUI's `TextField` can't express: ⏎ submits, ⇧⏎
/// inserts a newline, and ↑ on an empty field recalls the last queued goal. Auto-grows
/// 1–6 lines (reports its height back through `height`), then scrolls.
private struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var suggest: SlashSuggest
    var onSubmit: () -> Void
    var onRecall: () -> Void

    private static let minHeight: CGFloat = 22
    private static let maxHeight: CGFloat = 120

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: NSFont.systemFontSize * ThemeRuntime.scale)
        tv.drawsBackground = false
        tv.textColor = NSColor(Neon.textPrimary)
        tv.insertionPointColor = NSColor(Neon.blue)
        tv.textContainerInset = NSSize(width: 0, height: 3)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        // Flush-left text so the caret/first glyph aligns with the SwiftUI placeholder
        // (which has no internal left padding); both sit at the ZStack's 12pt inset.
        tv.textContainer?.lineFragmentPadding = 0
        context.coordinator.textView = tv
        // Selecting a suggestion (arrow+⏎ or click) replaces the whole draft with
        // "/<name> " and parks the caret at the end. Routed through the coordinator so
        // it can also resync the binding, recolor the token, and recompute height.
        suggest.apply = { [weak tv, weak coord = context.coordinator] newText in
            guard let tv, let coord else { return }
            tv.string = newText
            tv.setSelectedRange(NSRange(location: (newText as NSString).length, length: 0))
            coord.parent.text = newText
            coord.recolor(tv)
            coord.recalcHeight(tv)
        }

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        // Claim first responder on open so the user can type immediately — otherwise
        // the window hands focus to the first focusable SwiftUI control (was the title).
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        context.coordinator.recolor(tv)
        context.coordinator.recalcHeight(tv)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer
        weak var textView: NSTextView?
        init(_ parent: ChatComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.suggest.update(for: tv.string)
            recolor(tv)
            recalcHeight(tv)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let suggest = parent.suggest
            // While the suggestion popup is open, the arrow keys drive the list and
            // ⏎/⇥ accept the highlighted command; Esc dismisses. Otherwise fall through
            // to the normal submit / history-recall behavior.
            if suggest.visible {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    suggest.move(1); return true       // ↑ walks up the upward list
                case #selector(NSResponder.moveDown(_:)):
                    suggest.move(-1); return true      // ↓ back toward the field
                case #selector(NSResponder.insertNewline(_:)):
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                    suggest.accept(); return true
                case #selector(NSResponder.insertTab(_:)):
                    suggest.accept(); return true
                case #selector(NSResponder.cancelOperation(_:)):
                    suggest.dismiss(); return true
                default:
                    break
                }
            }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // ⇧⏎ → newline (let the field editor handle it); plain ⏎ → submit.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveUp(_:)):
                if textView.string.isEmpty { parent.onRecall(); return true }
                return false
            default:
                return false
            }
        }

        /// Color the leading `/command` token (Neon blue) when it (prefix-)matches an
        /// installed command — a Claude-Code-style cue that the token is recognized.
        /// Uses layout-manager temporary attributes so the plain-text model is untouched.
        func recolor(_ tv: NSTextView) {
            guard let lm = tv.layoutManager else { return }
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            if let token = SlashSuggest.tokenRange(in: tv.string, commands: CommandStore.all()) {
                lm.addTemporaryAttribute(.foregroundColor, value: NSColor(Neon.blue),
                                         forCharacterRange: token.range)
            }
        }

        /// Measure laid-out text height and report it back, clamped to 1–6 lines.
        func recalcHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let clamped = min(max(used, ChatComposer.minHeight), ChatComposer.maxHeight)
            if abs(parent.height - clamped) > 0.5 {
                // Defer out of the SwiftUI update pass (recalc is also called from
                // updateNSView); main-actor isolated so no data race.
                Task { @MainActor in self.parent.height = clamped }
            }
        }
    }
}
