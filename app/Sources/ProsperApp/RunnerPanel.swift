import AppKit
import SwiftUI

/// An NSPanel that can become key so its hosted text field accepts typing.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Floating translate panel. Captures the previously frontmost app before
/// showing so Enter can paste the chosen translation back into it.
@MainActor
final class RunnerPanel {

    private let panel: KeyablePanel
    private let model: RunnerModel
    private var previousApp: NSRunningApplication?
    /// Guards saving the origin while we move the panel programmatically (resize
    /// keeps the top edge fixed, which fires didMove).
    private var isProgrammaticMove = false
    private var moveObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    /// UserDefaults key for the remembered top-left corner of the runner.
    private static let originKey = "RunnerPanelTopLeft"

    /// The runner panel's fixed content width — used to center other panels
    /// (e.g. clipboard history) on the runner's last position.
    static let runnerWidth: CGFloat = 600

    /// The remembered runner top-left in screen coords (`x` = minX, `top` = maxY),
    /// or nil if the user has never moved the runner. Other panels read this to
    /// open centered on the runner instead of the screen.
    static func savedTopLeft() -> (x: CGFloat, top: CGFloat)? {
        guard let saved = UserDefaults.standard.dictionary(forKey: originKey),
              let x = saved["x"] as? CGFloat,
              let top = saved["y"] as? CGFloat else { return nil }
        return (x, top)
    }

    var isShown: Bool { panel.isVisible }

    init() {
        model = RunnerModel()

        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let root = RunnerView(
            model: model,
            onCommit: { [weak self] text in self?.commit(text) },
            onMeta: { [weak self] cmd in self?.performMeta(cmd) },
            onCancel: { [weak self] in self?.dismiss() },
            onResize: { [weak self] height in self?.resize(toHeight: height) },
            onLaunch: { [weak self] url in self?.launchApp(url) },
            onOpenLink: { [weak self] hit in self?.openQuicklink(hit) },
            onOpenURL: { [weak self] target in self?.openURLString(target) },
            onEditQuicklink: { [weak self] hit in self?.editQuicklink(hit) },
            onDeleteQuicklink: { [weak self] hit in self?.deleteQuicklink(hit) },
            onRunQuickdir: { [weak self] hit, query in self?.runQuickdir(hit, query: query) },
            onLaunchExtension: { [weak self] id, query in self?.launchExtension(commandID: id, query: query) },
            onFileAction: { [weak self] id, path in self?.performFileAction(id: id, path: path) }
        )
        let hosting = NSHostingView(rootView: Themed { root })
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        // Remember where the user drags the runner; restored on next present().
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // Posted on the main run loop (queue: .main) → safe to assume isolation.
            MainActor.assumeIsolated {
                guard let self, !self.isProgrammaticMove else { return }
                self.saveOrigin()
            }
        }

        // Auto-dismiss on focus loss when the input is empty: clicking away from
        // an untouched runner should just close it (Spotlight/Raycast behavior).
        // A runner with typed text stays put so the user doesn't lose their query
        // by glancing at another window.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.dismiss()
                }
            }
        }
    }

    /// Resizes the panel to the SwiftUI content height, keeping the TOP edge
    /// fixed (AppKit frames are bottom-origin, so we move origin.y up as height
    /// grows). This is what makes the runner expand downward from a single line.
    private func resize(toHeight height: CGFloat) {
        let h = max(1, height.rounded())
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        let top = f.maxY
        f.size.height = h
        f.origin.y = top - h
        isProgrammaticMove = true
        panel.setFrame(f, display: true, animate: false)
        isProgrammaticMove = false
    }

    /// Persists the panel's top-left corner (x, maxY) in screen coordinates.
    private func saveOrigin() {
        let f = panel.frame
        UserDefaults.standard.set(["x": f.minX, "y": f.maxY], forKey: Self.originKey)
    }

    /// Restores the remembered top-left corner, or centers if none saved.
    private func positionPanel() {
        let h = panel.frame.height
        if let saved = UserDefaults.standard.dictionary(forKey: Self.originKey),
           let x = saved["x"] as? CGFloat, let top = saved["y"] as? CGFloat {
            isProgrammaticMove = true
            panel.setFrameOrigin(NSPoint(x: x, y: top - h))
            isProgrammaticMove = false
        } else {
            panel.center()
        }
    }

    /// Captures the frontmost app, positions, and shows the panel focused.
    /// `mode` locks the runner to a capability (e.g. `.translate` from ⌥L) so the
    /// user types without a prefix and a mode chip is shown. `prefill` pre-seeds
    /// the input (already prefix-stripped by the caller).
    func present(mode: RunnerMode = .universal, prefill: String = "") {
        previousApp = NSWorkspace.shared.frontmostApplication
        model.reset()
        model.mode = mode
        model.input = prefill
        // Compute the initial outcome for the seeded input/mode. The view's
        // .onChange(of: input) doesn't fire for this programmatic assignment, so
        // without this an opened mode (e.g. a quickdir shortcut) shows an empty
        // list until the user types — locked ext modes list everything on an
        // empty query.
        model.inputChanged()
        positionPanel()
        DockPolicy.windowDidShow(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Drive focus on the next runloop tick: on first open the SwiftUI
        // TextField isn't mounted yet when present() runs, so a synchronous
        // focusRequested is dropped and the field opens unfocused. Toggling the
        // flag after the panel is key reliably moves first responder into it.
        model.focusRequested = false
        DispatchQueue.main.async { [weak self] in self?.model.focusRequested = true }
        // Warm the app index so the first keystroke in the launcher is instant.
        AppIndex.shared.ensureBuilt()
    }

    func dismiss() {
        panel.orderOut(nil)
        DockPolicy.windowDidHide(panel)
    }

    /// Launches the chosen app and closes the runner.
    private func launchApp(_ url: URL) {
        dismiss()
        AppLauncher.open(url)
    }

    /// Runs a built-in file action (open / reveal / quick look / copy / trash) and
    /// records frecency for engagements. Quick Look overlays the runner and keeps
    /// it open; every other action completes and dismisses (Raycast behavior).
    private func performFileAction(id: String, path: String) {
        if FileActions.dismissesRunner(id) { dismiss() }
        FileActionDispatcher.live.run(id: id, path: path)
    }

    /// Executes a `:` meta command, then hides the panel.
    private func performMeta(_ cmd: MetaCommand) {
        dismiss()
        switch cmd {
        case .quit:
            NSApp.terminate(nil)
        case .clearClipboard:
            ClipboardStore.shared.clearAll()
        case .newQuicklink:
            presentCreateQuicklink()
        }
    }

    /// Raycast-style Quicklink form: Name, Link (target), Description. Saved to the
    /// shared `QuicklinkStore` so `ql <name>` opens it afterwards. When `editing` is
    /// supplied the form is pre-filled and acts as an edit (renaming removes the old
    /// entry). Returns true when the user saved.
    @discardableResult
    private func presentCreateQuicklink(editing existing: QuicklinkHit? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Create Quicklink" : "Edit Quicklink"
        alert.informativeText = "Open it later with  ql <name>.  Use {query} in the link to substitute typed arguments."
        alert.addButton(withTitle: existing == nil ? "Create" : "Save")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 320
        let nameField = NSTextField(frame: NSRect(x: 0, y: 56, width: width, height: 24))
        nameField.placeholderString = "Name (e.g. gh)"
        let linkField = NSTextField(frame: NSRect(x: 0, y: 28, width: width, height: 24))
        linkField.placeholderString = "Link (https://github.com/{query})"
        let descField = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        descField.placeholderString = "Description (optional)"
        if let existing {
            nameField.stringValue = existing.name
            linkField.stringValue = existing.target
            descField.stringValue = existing.description
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        container.addSubview(nameField)
        container.addSubview(linkField)
        container.addSubview(descField)
        alert.accessoryView = container
        // NSAlert does not rebuild the key view loop for accessory views — wire
        // it manually or Tab never leaves the first field.
        alert.window.autorecalculatesKeyViewLoop = false
        nameField.nextKeyView = linkField
        linkField.nextKeyView = descField
        descField.nextKeyView = nameField
        alert.window.initialFirstResponder = nameField

        // Center on the active screen. NSAlert otherwise anchors near the floating
        // runner panel rather than the screen center; lay it out first so the
        // window has its final size before we reposition it.
        alert.layout()
        if let screen = panel.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let f = alert.window.frame
            alert.window.setFrameOrigin(NSPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2))
        }

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        // A rename leaves the old key behind; remove it before saving the new one.
        if let existing, existing.name != nameField.stringValue.trimmingCharacters(in: .whitespaces) {
            QuicklinkStore.remove(name: existing.name)
        }
        QuicklinkStore.save(
            name: nameField.stringValue,
            target: linkField.stringValue,
            description: descField.stringValue
        )
        return true
    }

    /// Opens a quicklink's target (URL / file path / deeplink), substituting any
    /// `{query}` with the runner's trailing argument, then dismisses the runner.
    private func openQuicklink(_ hit: QuicklinkHit) {
        let args = quicklinkArguments(for: hit.name)
        let resolved = QuicklinkStore.resolve(target: hit.target, query: args)
        dismiss()
        guard let url = Self.quicklinkURL(resolved) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens a plain URL / file-path / deeplink target (e.g. a bookmark row),
    /// then dismisses the runner. Mirrors `openQuicklink` without the
    /// quicklink-specific `{query}` substitution.
    private func openURLString(_ target: String) {
        dismiss()
        guard let url = Self.quicklinkURL(target) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Runs a quickdir's action against the selected directory (shell command or
    /// URL, with `{path}`/`{name}`/`{query}` substituted), then dismisses the runner.
    private func runQuickdir(_ hit: QuickdirHit, query: String) {
        dismiss()
        QuickdirStore.run(hit: hit, query: query)
    }

    /// Edits a quicklink in place; refreshes the list on save so the row updates.
    private func editQuicklink(_ hit: QuicklinkHit) {
        if presentCreateQuicklink(editing: hit) { model.rerun() }
    }

    /// Deletes a quicklink (after a confirm) and refreshes the list.
    private func deleteQuicklink(_ hit: QuicklinkHit) {
        let confirm = NSAlert()
        confirm.messageText = "Delete quicklink \u{201C}\(hit.name)\u{201D}?"
        confirm.informativeText = "This removes it from the runner and quicklinks.json."
        confirm.addButton(withTitle: "Delete")
        confirm.addButton(withTitle: "Cancel")
        confirm.alertStyle = .warning
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        QuicklinkStore.remove(name: hit.name)
        model.rerun()
    }

    /// Pulls the trailing argument the user typed after a quicklink name, e.g.
    /// `ql gh some/repo` or `gh some/repo` → "some/repo". Empty when none.
    private func quicklinkArguments(for name: String) -> String {
        var text = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("ql ") || text.lowercased() == "ql" {
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        guard text.lowercased().hasPrefix(name.lowercased()) else { return "" }
        return String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Builds an openable URL from a resolved quicklink target: a real URL when it
    /// has a scheme, otherwise a file URL (expanding a leading `~`).
    private static func quicklinkURL(_ target: String) -> URL? {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains("://"), let url = URL(string: t) { return url }
        let expanded = (t as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return URL(string: t)
    }

    /// Copies the chosen text, hides the panel, reactivates the prior app, and
    /// pastes via a synthesized Cmd+V.
    private func commit(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        dismiss()

        let target = previousApp
        // Give the panel a moment to resign key, then reactivate + paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            target?.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Self.pasteViaCmdV()
            }
        }
    }

    /// Invokes a window-launching extension command (manifest `launches_window`).
    /// The handler opens its own window via `host.window.open` (routed through the
    /// host's window presenter), so we just dismiss the runner and fire the handler;
    /// no inline result is rendered. Fire-and-forget — the window appears async.
    private func launchExtension(commandID: String, query: String) {
        dismiss()
        // Native coding agent: drive AgentController directly (not the registry).
        if commandID == CommandRouter.agentCommandID {
            Task { @MainActor in AgentController.shared.startFromRunner(goal: query) }
            return
        }
        Task { @MainActor in
            _ = await CommandRouter.registry?.invokeAsync(commandID: commandID, query: query)
        }
    }

    /// Synthesizes a Cmd+V keystroke via CGEvent.
    private static func pasteViaCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }
}

// MARK: - View model

/// Observable state for the command-runner UI (calc / unit / currency /
/// translate), including debounced single-flight calls.
@MainActor
final class RunnerModel: ObservableObject {
    @Published var input: String = ""
    @Published var outcome: RunnerOutcome?
    @Published var isLoading: Bool = false
    @Published var focusRequested: Bool = false
    /// The active runner mode. `.universal` is the launcher; the others lock the
    /// runner to one capability and show a mode chip.
    @Published var mode: RunnerMode = .universal
    /// Index into the flattened row list; always 0 when outcome is non-nil.
    @Published var selectedIndex: Int = 0

    private var debounceWorkItem: DispatchWorkItem?
    private var requestToken: UInt64 = 0
    private let debounceInterval: TimeInterval = 0.25
    /// Trailing single-flight state. A locked extension run is often an expensive,
    /// non-cancellable async call (LLM generation, http, shell). Debounce alone
    /// collapses fast typing, but slow back-and-forth editing (type → pause →
    /// delete → pause → retype, each pause past the debounce window) still fires a
    /// fresh request every time and stacks generations on the model's serial queue
    /// — the final, correct one queued behind several stale ones. We instead allow
    /// at most one in-flight request plus one pending: while a run is active, newer
    /// input only updates `pendingText`; the in-flight completion then runs the
    /// latest. Caps total work at 2 regardless of how much editing happened.
    private var isRunning = false
    private var pendingText: String?

    func reset() {
        input = ""
        outcome = nil
        isLoading = false
        mode = .universal
        selectedIndex = 0
        debounceWorkItem?.cancel()
        requestToken &+= 1
        pendingText = nil
    }

    /// Leaves the current locked mode back to the universal launcher (bound to
    /// Backspace on an empty field).
    func exitMode() {
        mode = .universal
        outcome = nil
        isLoading = false
        selectedIndex = 0
        debounceWorkItem?.cancel()
        requestToken &+= 1
        pendingText = nil
    }

    /// Enters a specific quickdir's browse mode (from the `qd` picker), locking the
    /// runner to that quickdir and listing its subdirectories immediately.
    func enterQuickdirMode(name: String) {
        mode = .ext(id: "quickdirs.run", title: name, icon: "folder", arg: name)
        input = ""
        outcome = nil
        selectedIndex = 0
        inputChanged()
    }

    /// Re-runs the current query immediately (no debounce). Used after a quicklink
    /// edit/delete so the list reflects the change without retyping.
    func rerun() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { outcome = nil; return }
        runQuery(trimmed)
    }

    /// Debounces typing then issues a single-flight runner request.
    func inputChanged() {
        // Auto-enter a locked mode when a trigger prefix is typed in the universal
        // launcher (e.g. "l " → translate, "! " → shell). The prefix is stripped
        // from the visible query; reassigning `input` re-enters this method.
        if mode == .universal, let (m, stripped) = ModeTrigger.resolve(input) {
            mode = m
            input = stripped
            return
        }

        debounceWorkItem?.cancel()
        selectedIndex = 0
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // A locked *view* extension (e.g. `ql `) runs even with an empty query so it
        // can list all of its entries. Quicklinks/quickdirs are manifest-declared
        // "no-view" (management verbs are side-effecting) but their locked modes
        // render native listings (CommandRouter special-cases the ids), so an empty
        // query must still run — a quickdir bound to a shortcut should list its
        // entries the moment the mode opens. A true no-view extension like
        // Translate has nothing to show for an empty field — clear it instead of
        // running the handler and leaving a stale "(done)" placeholder behind.
        let extRunsEmpty: Bool = {
            if case .ext(let id, _, _, _) = mode {
                if id == "quicklinks.run" || id == "quickdirs.run" { return true }
                let cmd = CommandRouter.registry?.command(id: id)?.command
                // A view command always runs on empty; a no-view command opts in via
                // `list_on_empty` (e.g. Bookmarks lists all, then filters on type).
                return cmd?.mode == .view || cmd?.listsOnEmpty == true
            }
            return false
        }()
        guard !trimmed.isEmpty || extRunsEmpty else {
            requestToken &+= 1
            pendingText = nil
            outcome = nil
            isLoading = false
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.runQuery(trimmed)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func runQuery(_ text: String) {
        // Trailing single-flight: while a request is in flight, only remember the
        // latest input — the in-flight completion will run it. Prevents expensive,
        // non-cancellable handlers (LLM/http/shell) from stacking under slow
        // back-and-forth editing.
        if isRunning {
            pendingText = text
            return
        }

        requestToken &+= 1
        let token = requestToken
        isRunning = true
        isLoading = true

        let activeMode = mode
        // In a locked extension mode the handler is async and often slow (an LLM
        // call, http, shell). Clear the prior result so the loading spinner shows
        // immediately instead of leaving the stale previous result on screen.
        if case .ext = activeMode { outcome = nil }

        Task { [weak self] in
            let result = await CommandRouter.run(text, mode: activeMode)
            guard let self else { return }
            self.isRunning = false
            // Newer input arrived while running → run the latest now and drop this
            // (stale) result instead of flashing it before the real one.
            if let next = self.pendingText {
                self.pendingText = nil
                if next != text { self.runQuery(next); return }
            }
            guard token == self.requestToken else { return } // ignore stale
            self.isLoading = false
            self.outcome = result
            self.selectedIndex = 0
        }
    }
}

// MARK: - Row model

/// One activatable action a result row offers (Alfred/Raycast file actions, or
/// any extension-declared action). `id` is a reserved `file.*` id the runner runs
/// natively, or a custom id dispatched back to the extension; `value` overrides
/// the row's `filePath` payload when set.
private struct RowAction: Identifiable {
    let id: String
    let title: String
    let icon: String?
    let value: String?
}

/// A flat, indexable representation of a result row shown in the list.
private struct ResultRow: Identifiable {
    let id: Int
    let icon: String          // SF Symbol name (used when iconImage is nil)
    let primary: String       // main text
    let secondary: String     // subtitle (may be empty)
    let category: String      // right-aligned label
    let copyValue: String     // what Enter commits
    let isMeta: Bool          // meta rows run instead of commit
    var appURL: URL? = nil    // when set, Enter launches this app instead of copying
    var iconImage: NSImage? = nil // real icon (e.g. app icon) shown instead of SF symbol
    var openTarget: String? = nil // when set, Enter opens this quicklink target
    var quicklink: QuicklinkHit? = nil // backing link for edit/delete actions
    var quickdir: QuickdirHit? = nil // when set, Enter runs this quickdir's action
    var quickdirMenu: QuickdirConfig? = nil // when set, Enter enters this quickdir's browse mode
    var label: String? = nil  // short category chip (e.g. translation register: formal/casual)
    var launchCommandID: String? = nil // when set, Enter invokes this extension command (opens its window)
    var launchQuery: String = ""       // raw query fed to the launched command's handler
    var actions: [RowAction] = []      // file/extension actions; when non-empty, Enter runs actions[0]
    var filePath: String? = nil        // backing file path for the row's actions (Quick Look, default payload)
}

// MARK: - Row builder

/// Rows for window-launching extension commands ("Add Quicklink", "Base64", …).
/// Enter on a row invokes the command handler, which opens the window.
private func launcherRows(_ hits: [ExtLaunchHit], startID: Int) -> [ResultRow] {
    hits.enumerated().map { i, hit in
        ResultRow(id: startID + i, icon: hit.icon ?? "macwindow", primary: hit.title,
                  secondary: hit.detail.isEmpty ? "Open \(hit.title)" : hit.detail,
                  category: "Extension", copyValue: "", isMeta: false,
                  launchCommandID: hit.commandID, launchQuery: hit.query)
    }
}

private func buildRows(from outcome: RunnerOutcome) -> [ResultRow] {
    switch outcome {
    case .calc(let expression, let value):
        return [ResultRow(id: 0, icon: "function", primary: value,
                          secondary: expression, category: "Calculator",
                          copyValue: value, isMeta: false)]

    case .unit(let title, let value, let detail):
        let sub = detail.isEmpty ? title : "\(title)  \(detail)"
        return [ResultRow(id: 0, icon: "arrow.left.arrow.right", primary: value,
                          secondary: sub, category: "Unit",
                          copyValue: value, isMeta: false)]

    case .currency(let value, let detail):
        return [ResultRow(id: 0, icon: "banknote", primary: value,
                          secondary: detail, category: "Currency",
                          copyValue: value, isMeta: false)]

    case .app(let name, let launched):
        let primary = launched ? "Launched \(name)" : "Not found: \(name)"
        let sub = launched ? "" : "No app named \u{201C}\(name)\u{201D}"
        return [ResultRow(id: 0, icon: launched ? "checkmark.circle" : "xmark.circle",
                          primary: primary, secondary: sub,
                          category: "Application", copyValue: name, isMeta: false)]

    case .apps(let apps):
        return apps.enumerated().map { i, app in
            ResultRow(id: i, icon: "app.dashed", primary: app.name, secondary: "",
                      category: "Application", copyValue: app.name, isMeta: false,
                      appURL: app.url,
                      iconImage: NSWorkspace.shared.icon(forFile: app.url.path))
        }

    case .noResults(let query):
        return [ResultRow(id: 0, icon: "magnifyingglass",
                          primary: "No results for \u{201C}\(query)\u{201D}",
                          secondary: "Type \u{201C}l \(query)\u{201D} to translate, or \u{201C}! cmd\u{201D} to run a shell command.",
                          category: "", copyValue: "", isMeta: false)]

    case .shell(let command, let output):
        return [ResultRow(id: 0, icon: "terminal", primary: output.isEmpty ? "(no output)" : output,
                          secondary: "$ \(command)", category: "Shell",
                          copyValue: output, isMeta: false)]

    case .emoji(let name, let emoji):
        return [ResultRow(id: 0, icon: "face.smiling", primary: emoji,
                          secondary: ":\(name):", category: "Emoji",
                          copyValue: emoji, isMeta: false)]

    case .meta(let cmd):
        return [ResultRow(id: 0, icon: "command", primary: cmd.label,
                          secondary: "", category: "Command",
                          copyValue: cmd.label, isMeta: true)]

    case .ext(let kind, let value, let detail):
        return [ResultRow(id: 0, icon: "puzzlepiece.extension", primary: value.isEmpty ? "(done)" : value,
                          secondary: detail, category: kind,
                          copyValue: value, isMeta: false)]

    case .extLaunch(let hits):
        return launcherRows(hits, startID: 0)

    case .quicklinks(let hits, let launchers):
        if hits.isEmpty && launchers.isEmpty {
            return [ResultRow(id: 0, icon: "link", primary: "No quicklinks",
                              secondary: "Add one with  ql add <name> <target>  or  ql new.",
                              category: "Quicklinks", copyValue: "", isMeta: false)]
        }
        let rows = hits.enumerated().map { i, hit in
            let sub = hit.description.isEmpty ? hit.target : hit.description
            return ResultRow(id: i, icon: "link", primary: hit.name, secondary: sub,
                             category: "Quicklink", copyValue: hit.name, isMeta: false,
                             openTarget: hit.target, quicklink: hit)
        }
        return rows + launcherRows(launchers, startID: rows.count)

    case .quickdirs(let hits):
        if hits.isEmpty {
            return [ResultRow(id: 0, icon: "folder", primary: "No matching directories",
                              secondary: "Nothing here \u{2014} adjust the filter or the quickdir's path.",
                              category: "Quickdir", copyValue: "", isMeta: false)]
        }
        return hits.enumerated().map { i, hit in
            ResultRow(id: i, icon: "folder", primary: hit.name, secondary: hit.path,
                      category: hit.actionLabel, copyValue: hit.path, isMeta: false,
                      quickdir: hit)
        }

    case .quickdirsMenu(let configs, let launchers):
        if configs.isEmpty && launchers.isEmpty {
            return [ResultRow(id: 0, icon: "folder.badge.plus", primary: "No quickdirs",
                              secondary: "Add one with  qd add <name> <path>  or in Settings \u{203A} Quickdirs.",
                              category: "Quickdirs", copyValue: "", isMeta: false)]
        }
        let rows = configs.enumerated().map { i, cfg in
            let prefixHint = cfg.prefix.isEmpty ? "" : "\(cfg.prefix)  \u{2022}  "
            return ResultRow(id: i, icon: "folder", primary: cfg.name,
                             secondary: "\(prefixHint)\(cfg.path)",
                             category: "Quickdir", copyValue: cfg.name, isMeta: false,
                             quickdirMenu: cfg)
        }
        return rows + launcherRows(launchers, startID: rows.count)

    case .modelPending(let status):
        return [ResultRow(id: 0, icon: "arrow.down.circle.dotted", primary: status,
                          secondary: "Downloading runs in the background — keep using calc, units, currency, apps.",
                          category: "Model", copyValue: "", isMeta: false)]

    case .extView(let node):
        // Rich declarative result rendered inline as Neon cards. We still derive
        // flat rows so keyboard selection + Enter-to-copy work over the items.
        func rows(_ title: String?, _ items: [ListItem]) -> [ResultRow] {
            items.enumerated().map { i, item in
                // A row may declare `actions` (the `files` finder: Open / Reveal /
                // Quick Look / …) — the runner runs actions[0] on Enter and surfaces
                // the rest via ⌘⏎/⌥⏎/⌘K. Otherwise a `launch` path makes Enter open
                // the target natively (the `open` launcher's app bundles), reusing
                // the native app-row activation path. An `image` path shows that
                // file's Finder icon.
                let actions = item.allActions.map {
                    RowAction(id: $0.id, title: $0.title, icon: $0.icon, value: $0.value)
                }
                // Actions win over `launch`: a file row carries `launch` only as its
                // path payload (Finder icon + Quick Look), not as an app launch.
                let appURL = actions.isEmpty ? item.launch.map { URL(fileURLWithPath: $0) } : nil
                let iconImage = item.image.map { NSWorkspace.shared.icon(forFile: $0) }
                // A `url` row (e.g. a bookmark) opens natively through the same
                // URL-open + favicon path as Quicklinks (see `openTarget`).
                // Launchable rows mirror native app results with an "Application"
                // tag; URL rows read "Bookmark"; the rest fall back to the list title.
                let category = appURL != nil ? "Application"
                    : (item.url != nil ? "Bookmark" : (title ?? "Result"))
                return ResultRow(id: i, icon: item.icon ?? "globe", primary: item.title,
                          secondary: item.subtitle ?? "", category: category,
                          copyValue: item.url ?? item.title, isMeta: false,
                          appURL: appURL, iconImage: iconImage,
                          openTarget: item.url, label: item.accessory,
                          actions: actions, filePath: item.launch)
            }
        }
        switch node {
        case .list(let n): return rows(n.title, n.items)
        case .grid(let n): return rows(n.title, n.items)
        case .detail(let n):
            return [ResultRow(id: 0, icon: "doc.plaintext", primary: n.markdown,
                              secondary: "", category: n.title ?? "Result",
                              copyValue: n.markdown, isMeta: false)]
        case .form, .loading, .converter:
            // Forms/loading/converter aren't inline-listable; converter is a
            // standalone window (host.window.open), never an inline result.
            return []
        }
    }
}

// MARK: - Action verb

private func actionVerb(for outcome: RunnerOutcome?) -> String {
    guard let outcome else { return "Run" }
    switch outcome {
    case .app:         return "Open"
    case .apps:        return "Open"
    case .quicklinks:  return "Open"
    case .quickdirs:   return "Run Action"
    case .quickdirsMenu: return "Browse"
    case .noResults:   return ""
    case .shell:       return "Run"
    case .meta:        return "Run Shortcut"
    case .emoji:       return "Copy"
    case .extView:     return "Paste Result"
    case .extLaunch:   return "Open"
    case .modelPending: return "Downloading\u{2026}"
    default:           return "Copy"
    }
}

// MARK: - SwiftUI view

/// Reports the runner's natural content height up to the AppKit panel so it can
/// collapse to a single line when empty and expand downward as results arrive.
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RunnerView: View {
    @ObservedObject var model: RunnerModel
    let onCommit: (String) -> Void
    let onMeta: (MetaCommand) -> Void
    let onCancel: () -> Void
    let onResize: (CGFloat) -> Void
    let onLaunch: (URL) -> Void
    let onOpenLink: (QuicklinkHit) -> Void
    /// Opens a plain web/deeplink URL from a `url`-bearing extension row (e.g. a
    /// bookmark), without quicklink argument substitution.
    let onOpenURL: (String) -> Void
    let onEditQuicklink: (QuicklinkHit) -> Void
    let onDeleteQuicklink: (QuicklinkHit) -> Void
    let onRunQuickdir: (QuickdirHit, String) -> Void
    let onLaunchExtension: (String, String) -> Void
    /// Runs a built-in file action (`file.*` id) against a path — open / reveal /
    /// quick look / copy / trash. Routed to `FileActions` in the controller.
    let onFileAction: (String, String) -> Void

    @FocusState private var inputFocused: Bool

    // Derived rows from current outcome.
    private var rows: [ResultRow] {
        model.outcome.map(buildRows) ?? []
    }

    private var selectedRow: ResultRow? {
        guard !rows.isEmpty,
              model.selectedIndex >= 0,
              model.selectedIndex < rows.count else { return nil }
        return rows[model.selectedIndex]
    }

    /// The Enter-key verb shown in the action bar. A row's own activation wins over
    /// the outcome default so launchable/openable extension rows (e.g. the `open`
    /// app list) read "Open" instead of the generic extView "Paste Result".
    private var commitVerb: String {
        if let row = selectedRow {
            if let primary = row.actions.first { return primary.title }
            if row.appURL != nil || row.openTarget != nil { return "Open" }
            if row.quickdir != nil { return "Run Action" }
            if row.quickdirMenu != nil { return "Browse" }
        }
        return actionVerb(for: model.outcome)
    }

    /// Builds the two-column calculator card for calc / unit / currency outcomes.
    /// Returns nil for every other outcome (rendered as a row list instead).
    private func calcCard(for outcome: RunnerOutcome) -> CalcCard? {
        let echo = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        switch outcome {
        case .calc(let expression, let value):
            return CalcCard(
                leftText: expression, leftLabel: calcOperationName(expression),
                rightText: value, rightLabel: spellOutNumber(value), subtitle: nil
            )

        case .unit(let title, let value, _):
            let (from, to) = splitArrow(title)
            return CalcCard(
                leftText: echo.isEmpty ? title : echo, leftLabel: unitLongName(from),
                rightText: value, rightLabel: unitLongName(to), subtitle: nil
            )

        case .currency(let value, _):
            let codes = currencyCodes(from: echo)
            return CalcCard(
                leftText: echo, leftLabel: codes.map { currencyName($0.0) } ?? "",
                rightText: value, rightLabel: codes.map { currencyName($0.1) } ?? "",
                subtitle: currencyUpdatedSubtitle()
            )

        default:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Search field ──────────────────────────────────────────────
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if model.mode == .universal {
                        Image(systemName: model.isLoading ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundColor(Neon.blue)
                            .symbolEffect(.pulse, isActive: model.isLoading)
                    } else {
                        ModeChip(mode: model.mode, isLoading: model.isLoading)
                    }
                }
                // Center the icon/chip against the field's first line. The field text
                // is larger (20pt) than the chip text (13pt), so baseline-alignment
                // left the pill visually high; vertical centering matches the eye.

                // Grows and wraps for long input (e.g. a paragraph to translate)
                // instead of overflowing a single line; caps at 5 lines, then the
                // field scrolls internally.
                TextField(model.mode.placeholder, text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .regular))
                    .lineLimit(1 ... 5)
                    .focused($inputFocused)
                    .onSubmit { commitSelected() }
                    .onChange(of: model.input) { _, _ in model.inputChanged() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            // ── Result list or loading (empty input → single line, nothing here)
            if model.isLoading && model.outcome == nil {
                Divider()
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else if case .extView(let node) = model.outcome {
                Divider()
                extViewInline(node: node, rows: rows)
                if !rows.isEmpty {
                    Divider()
                    actionBar(outcome: model.outcome!)
                }
            } else if let outcome = model.outcome {
                Divider()
                if let card = calcCard(for: outcome) {
                    // Calc / unit / currency: big two-column Raycast calculator card.
                    CalcCardView(card: card)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                } else {
                    // All other outcomes: Raycast-style row list.
                    resultRowList(rows: rows)
                }

                Divider()

                // ── Action bar ────────────────────────────────────────────
                actionBar(outcome: outcome)
            }
        }
        .frame(width: 600)
        .neonPanelSurface()
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(PanelHeightKey.self) { height in onResize(height) }
        // Adopt the content's ideal height instead of the panel's current
        // (initially 60pt) proposal. Without this the VStack is squeezed to the
        // panel height, the GeometryReader reports that squeezed height, and the
        // panel never grows when results or a multi-line input appear.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { inputFocused = true }
        .onChange(of: model.focusRequested) { _, requested in
            if requested {
                inputFocused = true
                model.focusRequested = false
            }
        }
        .background(
            KeyHandling(
                onCancel: {
                    // Esc in a locked mode, or with any typed text, first clears the
                    // field and drops back to the universal launcher (Raycast-style)
                    // — it does NOT close the runner. Only a second Esc, on an empty
                    // universal field, dismisses the panel.
                    if model.mode != .universal || !model.input.isEmpty {
                        model.input = ""
                        model.exitMode()
                        model.inputChanged()
                    } else {
                        onCancel()
                    }
                },
                onUp: {
                    guard !rows.isEmpty else { return }
                    model.selectedIndex = (model.selectedIndex - 1 + rows.count) % rows.count
                },
                onDown: {
                    guard !rows.isEmpty else { return }
                    model.selectedIndex = (model.selectedIndex + 1) % rows.count
                },
                onCommit: { commitSelected() },
                onDeleteWhenEmpty: {
                    // Backspace on an empty field leaves the locked mode back to
                    // the universal launcher (Raycast behavior). Otherwise let the
                    // keystroke edit the text normally.
                    guard model.input.isEmpty, model.mode != .universal else { return false }
                    model.exitMode()
                    return true
                },
                onClear: {
                    model.input = ""
                    model.inputChanged()
                },
                // Row-action accelerators (the ⌘K menu lists them all). ⌘⏎ runs the
                // selected row's secondary action (Reveal), ⌥⏎ the tertiary, ⌘Y
                // Quick Look. ⌘K itself stays a native SwiftUI Menu (ActionMenuButton).
                onSecondary: { performActionAtOffset(1) },
                onTertiary: { performActionAtOffset(2) },
                onQuickLook: { quickLookSelected() }
            )
        )
    }

    // MARK: - Result row list

    @ViewBuilder
    private func resultRowList(rows: [ResultRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Results")
                    ForEach(rows) { row in
                        ResultRowView(
                            row: row,
                            isSelected: model.selectedIndex == row.id
                        ) {
                            activateRow(row)
                        }
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            // Keep the keyboard-selected row visible while arrowing through a
            // long list (e.g. all quicklinks), which would otherwise run off-screen.
            .onChange(of: model.selectedIndex) { _, idx in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }

    // MARK: - Inline extension view (rich declarative result)

    /// Renders an extension's declarative component tree INLINE in the runner as
    /// native Neon UI — list/grid → stacked cards, detail → wrapped markdown,
    /// loading → spinner. The extension ships structure only; this is the host's
    /// pixels, so every extension shares one consistent look (ADR-002 §D7).
    @ViewBuilder
    private func extViewInline(node: ExtensionViewNode, rows: [ResultRow]) -> some View {
        switch node {
        case .loading(let n):
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                if let t = n.title {
                    Text(t).font(.system(size: 14, weight: .medium)).foregroundColor(Neon.textPrimary)
                }
                if let s = n.subtitle {
                    Text(s).font(.system(size: 12)).foregroundColor(Neon.textSecondary)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28)

        case .detail(let n):
            ScrollView {
                Text(extMarkdown(n.markdown))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .foregroundColor(Neon.textPrimary)
                    .padding(12)
            }
            .frame(maxHeight: 360)

        case .list(let n):
            // Compact launcher rows (e.g. the `open` app list) render exactly like
            // native results — icon + trailing category; cards are the default for
            // reading-focused lists (Translate).
            if n.isRowStyle { resultRowList(rows: rows) }
            else { cardList(header: n.title, accessory: n.subtitle, rows: rows) }
        case .grid(let n): cardList(header: n.title, accessory: nil, rows: rows)
        case .form:        resultRowList(rows: rows)
        case .converter:   EmptyView()  // standalone window only (host.window.open)
        }
    }

    /// Stacked reading-focused cards (full wrapped text + optional chip + note),
    /// with a section header and an optional trailing accessory (e.g. Translate's
    /// "Detected: EN"). Keyboard selection + Enter-to-paste track `selectedIndex`.
    @ViewBuilder
    private func cardList(header: String?, accessory: String?, rows: [ResultRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        sectionHeader(header ?? "Result")
                        Spacer()
                        if let a = accessory, !a.isEmpty {
                            Text(a)
                                .font(.system(size: 11))
                                .foregroundColor(Neon.blue)
                                .padding(.trailing, 12)
                        }
                    }
                    ForEach(rows) { row in
                        ExtCardRow(row: row, isSelected: model.selectedIndex == row.id) {
                            activateRow(row)
                        }
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            .onChange(of: model.selectedIndex) { _, idx in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }

    /// Native inline-markdown rendering for detail bodies (plain-text fallback).
    private func extMarkdown(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(raw)
    }

    /// Small dimmed uppercase-ish group label, Raycast "Results" style.
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundColor(Neon.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    // MARK: - Action bar

    @ViewBuilder
    private func actionBar(outcome: RunnerOutcome) -> some View {
        HStack(spacing: 10) {
            // App glyph — far left (Raycast logo position)
            Image(systemName: "command")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Neon.blue.opacity(0.8))

            Spacer()

            // Primary action — right side, with keycap
            HStack(spacing: 6) {
                Text(commitVerb)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Neon.textSecondary)
                KeyCap("\u{21A9}")
            }

            Divider().frame(height: 14)

            // Actions menu — right side (⌘K). Lists the selected row's file
            // actions when it has them (the `files` finder), then Copy / quicklink.
            ActionMenuButton(
                fileActions: selectedRow?.actions ?? [],
                runFileAction: { action in
                    if let row = selectedRow { performRowAction(action, on: row) }
                },
                quicklink: selectedRow?.quicklink,
                onCopy: {
                    if let row = selectedRow {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(row.copyValue, forType: .string)
                    }
                },
                onEdit: { hit in onEditQuicklink(hit) },
                onDelete: { hit in onDeleteQuicklink(hit) }
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Neon.bgBottom.opacity(0.55))
    }

    // MARK: - Helpers

    private func commitSelected() {
        if let row = selectedRow {
            activateRow(row)
            return
        }
        // Fallback: original logic for when no rows are built yet.
        if case .meta(let cmd) = model.outcome {
            onMeta(cmd)
            return
        }
        if let text = model.outcome?.copyText, !text.isEmpty {
            onCommit(text)
        }
    }

    private func activateRow(_ row: ResultRow) {
        if let primary = row.actions.first {
            performRowAction(primary, on: row)
            return
        }
        if let commandID = row.launchCommandID {
            onLaunchExtension(commandID, row.launchQuery)
            return
        }
        if let url = row.appURL {
            onLaunch(url)
            return
        }
        if let hit = row.quicklink {
            onOpenLink(hit)
            return
        }
        // A `url`-bearing extension row (e.g. a bookmark) with no backing
        // quicklink opens its target natively.
        if let target = row.openTarget {
            onOpenURL(target)
            return
        }
        if let hit = row.quickdir {
            onRunQuickdir(hit, model.input.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        if let cfg = row.quickdirMenu {
            model.enterQuickdirMode(name: cfg.name)
            return
        }
        if row.isMeta {
            if case .meta(let cmd) = model.outcome {
                onMeta(cmd)
            }
        } else {
            onCommit(row.copyValue)
        }
    }

    /// Runs one of a row's declared actions; the value defaults to the row's file
    /// path. The controller decides whether the action dismisses the runner (Quick
    /// Look keeps it open).
    private func performRowAction(_ action: RowAction, on row: ResultRow) {
        let value = action.value ?? row.filePath ?? row.copyValue
        onFileAction(action.id, value)
    }

    /// Runs the Nth action of the selected row, if it exists (modifier-key
    /// shortcuts: ⌘⏎ → 1, ⌥⏎ → 2).
    private func performActionAtOffset(_ offset: Int) {
        guard let row = selectedRow, row.actions.indices.contains(offset) else { return }
        performRowAction(row.actions[offset], on: row)
    }

    /// Quick Look the selected row's file (⌘Y). Dispatches the built-in
    /// `file.quicklook` action, which overlays without dismissing the runner.
    private func quickLookSelected() {
        guard let row = selectedRow, let path = row.filePath ?? row.appURL?.path else { return }
        onFileAction(FileActions.ID.quickLook, path)
    }
}

// MARK: - ModeChip

/// A pill shown in the search field when the runner is locked to a capability
/// (translate / open-app / shell / extension). Signals the active mode so the
/// user knows what their unprefixed input does; Backspace on an empty field exits.
private struct ModeChip: View {
    let mode: RunnerMode
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : mode.icon)
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.pulse, isActive: isLoading)
            Text(mode.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(Neon.blueBright)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Neon.blue.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Neon.blue.opacity(0.5), lineWidth: 1))
        )
        .shadow(color: Neon.blue.opacity(0.3), radius: 5)
        .fixedSize()
    }
}

// MARK: - ResultRowView

private struct ResultRowView: View {
    let row: ResultRow
    let isSelected: Bool
    let onActivate: () -> Void

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 12) {
                // Leading icon — a real app icon when available, the page favicon
                // for a quicklink, else a tinted rounded-square SF-symbol tile.
                if let image = row.iconImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 26, height: 26)
                } else if let host = FaviconLoader.host(for: row.openTarget ?? row.quicklink?.target) {
                    FaviconView(host: host, fallbackSymbol: row.icon)
                } else {
                    symbolTile
                }

                // Primary + secondary inline (Raycast shows subtitle in dimmed gray)
                HStack(spacing: 8) {
                    Text(row.primary)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Neon.textPrimary)
                        .lineLimit(1)

                    if !row.secondary.isEmpty {
                        Text(row.secondary)
                            .font(.system(size: 13))
                            .foregroundColor(Neon.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                // Type label — right aligned, plain dimmed text (no pill)
                Text(row.category)
                    .font(.system(size: 13))
                    .foregroundColor(Neon.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Neon.blue.opacity(0.16) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Neon.blue.opacity(isSelected ? 0.45 : 0), lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Tinted rounded-square SF-symbol tile (Raycast app-icon look), shown when
    /// no real icon or favicon is available.
    private var symbolTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Neon.blue.opacity(0.18))
            Image(systemName: row.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Neon.blue)
        }
        .frame(width: 26, height: 26)
    }
}

// MARK: - Favicon

/// Shows a webpage's favicon for a quicklink row, falling back to the tinted
/// SF-symbol tile until (or unless) the favicon loads.
private struct FaviconView: View {
    let host: String
    let fallbackSymbol: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Neon.blue.opacity(0.18))
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                .frame(width: 26, height: 26)
            }
        }
        .task(id: host) { image = await FaviconLoader.shared.icon(for: host) }
    }
}

/// Loads and caches favicons via the de-facto standard `/favicon.ico` at the
/// site root. In-memory cached by host; hosts that fail are remembered so the
/// list doesn't refetch on every keystroke.
@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()
    private let cache = NSCache<NSString, NSImage>()
    private var failed: Set<String> = []
    private var inflight: [String: Task<NSImage?, Never>] = [:]

    /// The host of a quicklink target, or nil for non-http(s) targets (file
    /// paths, custom-scheme deeplinks) which have no favicon.
    static func host(for target: String?) -> String? {
        guard let target,
              let url = URL(string: target),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    func icon(for host: String) async -> NSImage? {
        if let cached = cache.object(forKey: host as NSString) { return cached }
        if failed.contains(host) { return nil }
        if let task = inflight[host] { return await task.value }

        let task = Task<NSImage?, Never> { [host] in
            guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let img = NSImage(data: data), img.size.width > 0 else { return nil }
            return img
        }
        inflight[host] = task
        let result = await task.value
        inflight[host] = nil
        if let result { cache.setObject(result, forKey: host as NSString) }
        else { failed.insert(host) }
        return result
    }
}

// MARK: - Calculator card (Raycast-style)

/// View-model for the big two-column result card shown for calc / unit /
/// currency. Each side has a large value and a small gray label chip; an arrow
/// (with an optional subtitle) sits between them.
private struct CalcCard {
    let leftText: String
    let leftLabel: String
    let rightText: String
    let rightLabel: String
    let subtitle: String?
}

/// One inline extension-result card: full wrapped primary text (selectable for
/// reading/copy), an optional register/sense chip (`label`), and a wrapped note
/// (`secondary`). Highlights when keyboard-selected and pastes on tap — the focus
/// is *reading*, so text wraps instead of clipping to a single line.
private struct ExtCardRow: View {
    let row: ResultRow
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(row.primary)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Neon.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if (row.label?.isEmpty == false) || !row.secondary.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    if let label = row.label, !label.isEmpty {
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Neon.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Neon.blue.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    if !row.secondary.isEmpty {
                        Text(row.secondary)
                            .font(.system(size: 13))
                            .foregroundColor(Neon.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Neon.blue.opacity(0.12) : Neon.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Neon.blue.opacity(0.55) : Neon.stroke,
                              lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

private struct CalcCardView: View {
    let card: CalcCard

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Calculator")
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundColor(Neon.textSecondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 4)

            VStack(spacing: 0) {
                ZStack {
                    // Center hairline separating the two halves.
                    Rectangle()
                        .fill(Neon.stroke)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 14)

                    HStack(spacing: 0) {
                        column(text: card.leftText, label: card.leftLabel)
                        column(text: card.rightText, label: card.rightLabel)
                    }

                    // Arrow centered over the hairline.
                    Image(systemName: "arrow.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Neon.blue)
                        .shadow(color: Neon.blue.opacity(0.5), radius: 5)
                }
                .padding(.top, 22)
                .padding(.bottom, card.subtitle == nil ? 22 : 12)

                // Subtitle as a full-width footer — long values can reach the
                // card's center, so it must never share the space between the
                // columns (it used to overlap the input-side value there).
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Neon.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)
                }
            }
            .padding(.horizontal, 8)
            .neonCard()
        }
    }

    @ViewBuilder
    private func column(text: String, label: String) -> some View {
        VStack(spacing: 14) {
            Text(text)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Neon.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, 36)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Neon.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Neon.blue.opacity(0.12))
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Calculator card helpers

/// Splits a "<a> → <b>" title into its two halves (used for unit conversions).
private func splitArrow(_ title: String) -> (String, String) {
    let parts = title.components(separatedBy: " → ")
    guard parts.count == 2 else { return (title, "") }
    return (parts[0].trimmingCharacters(in: .whitespaces),
            parts[1].trimmingCharacters(in: .whitespaces))
}

/// Names the dominant arithmetic operation in an expression (Raycast labels the
/// left side "Sum", "Power", etc.). Higher-precedence operators win.
private func calcOperationName(_ expr: String) -> String {
    if expr.contains("^") { return "Power" }
    if expr.contains("%") { return "Remainder" }
    if expr.contains("*") || expr.contains("×") { return "Product" }
    if expr.contains("/") || expr.contains("÷") { return "Quotient" }
    if expr.contains("-") { return "Difference" }
    if expr.contains("+") { return "Sum" }
    return "Result"
}

/// Spells out a whole-number result ("5" → "Five"), matching Raycast's right-
/// side chip. Empty for non-integers or large magnitudes.
private func spellOutNumber(_ s: String) -> String {
    guard let d = Double(s), d == d.rounded(), abs(d) < 1_000_000 else { return "" }
    let f = NumberFormatter()
    f.numberStyle = .spellOut
    guard let words = f.string(from: NSNumber(value: Int(d))) else { return "" }
    return words.prefix(1).uppercased() + words.dropFirst()
}

/// Maps a unit display symbol to its human-readable plural name for the chip.
private func unitLongName(_ symbol: String) -> String {
    let map: [String: String] = [
        "mm": "Millimeters", "cm": "Centimeters", "m": "Meters", "km": "Kilometers",
        "in": "Inches", "ft": "Feet", "yd": "Yards", "mi": "Miles", "nmi": "Nautical Miles",
        "mg": "Milligrams", "g": "Grams", "kg": "Kilograms", "t": "Tonnes",
        "oz": "Ounces", "lb": "Pounds", "st": "Stones",
        "ns": "Nanoseconds", "µs": "Microseconds", "ms": "Milliseconds",
        "seconds": "Seconds", "minutes": "Minutes", "hours": "Hours",
        "days": "Days", "weeks": "Weeks", "months": "Months", "years": "Years",
        "bit": "Bits", "B": "Bytes", "KB": "Kilobytes", "MB": "Megabytes",
        "GB": "Gigabytes", "TB": "Terabytes", "KiB": "Kibibytes", "MiB": "Mebibytes",
        "GiB": "Gibibytes",
        "°C": "Celsius", "°F": "Fahrenheit", "K": "Kelvin",
        "m/s": "Meters / Second", "km/h": "Kilometers / Hour", "mph": "Miles / Hour",
        "kn": "Knots",
        "m²": "Square Meters", "km²": "Square Kilometers", "ft²": "Square Feet",
        "acres": "Acres", "ha": "Hectares",
        "mL": "Milliliters", "L": "Liters", "gal": "Gallons", "pt": "Pints", "cups": "Cups",
    ]
    return map[symbol] ?? symbol.capitalized
}

/// Full localized currency name for a 3-letter code ("USD" → "US Dollar").
private func currencyName(_ code: String) -> String {
    Locale.current.localizedString(forCurrencyCode: code) ?? code
}

/// Extracts the (from, to) 3-letter currency codes from the user's query
/// ("3 usd to bgn" → ("USD", "BGN")).
private func currencyCodes(from echo: String) -> (String, String)? {
    let lower = echo.lowercased()
    for sep in [" to ", " in ", "->", " → "] {
        guard let r = lower.range(of: sep) else { continue }
        let lhs = String(lower[..<r.lowerBound])
        let rhs = String(lower[r.upperBound...])
        let from = lhs.split(whereSeparator: { !$0.isLetter }).last.map { String($0).uppercased() } ?? ""
        let to = rhs.split(whereSeparator: { !$0.isLetter }).first.map { String($0).uppercased() } ?? ""
        if from.count == 3, to.count == 3 { return (from, to) }
    }
    return nil
}

/// "Updated N ago" subtitle from the FX rate fetch timestamp, or nil if rates
/// were never fetched on this machine. Two engines can fetch rates — the
/// native `CurrencyService` (stores a `Date`) and the currency system
/// extension (stores epoch seconds via `host.prefs`); whichever fetched most
/// recently is the truth about how fresh the rate table is.
private func currencyUpdatedSubtitle() -> String? {
    let defaults = UserDefaults.standard
    var dates: [Date] = []
    if let d = defaults.object(forKey: "fxRatesFetchedAt") as? Date { dates.append(d) }
    if let s = defaults.string(forKey: "ext.com.prosper.currency.fetchedAt"),
       let epoch = Double(s) {
        dates.append(Date(timeIntervalSince1970: epoch))
    }
    guard let date = dates.max() else { return nil }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return "Updated " + f.localizedString(for: date, relativeTo: Date())
}

// MARK: - Actions menu button

private struct ActionMenuButton: View {
    /// The selected row's declared actions (e.g. the `files` finder's Open / Reveal
    /// / Quick Look / Copy Path / …); listed first when present.
    var fileActions: [RowAction] = []
    var runFileAction: (RowAction) -> Void = { _ in }
    let quicklink: QuicklinkHit?
    let onCopy: () -> Void
    let onEdit: (QuicklinkHit) -> Void
    let onDelete: (QuicklinkHit) -> Void

    var body: some View {
        Menu {
            ForEach(fileActions) { action in
                Button { runFileAction(action) } label: {
                    if let icon = action.icon { Label(action.title, systemImage: icon) }
                    else { Text(action.title) }
                }
            }
            if !fileActions.isEmpty { Divider() }
            Button("Copy") { onCopy() }
            if let hit = quicklink {
                Divider()
                Button("Edit Quicklink\u{2026}") { onEdit(hit) }
                Button("Delete Quicklink", role: .destructive) { onDelete(hit) }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Actions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Neon.textSecondary)
                KeyCap("\u{2318}K")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .keyboardShortcut("k", modifiers: .command)
        // ⌘E edits the selected quicklink directly (Raycast parity).
        .background(
            Button("") { if let hit = quicklink { onEdit(hit) } }
                .keyboardShortcut("e", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Keycap

/// Small rounded key-cap chip used in the action bar (Raycast footer style).
private struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Neon.blue)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Neon.blue.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Neon.blue.opacity(0.3), lineWidth: 0.5))
            )
    }
}

// MARK: - Key handling

/// Bridges Esc, Up, Down, and Return to SwiftUI closures while keeping the text
/// field focused throughout.
///
/// Uses a window-scoped local `NSEvent` monitor rather than `NSView.keyDown`:
/// the input `TextField` is always first responder, so a background view never
/// receives key events. The monitor intercepts navigation/commit keys (returns
/// nil to consume) and lets typing fall through. Scoped to this panel's window.
private struct KeyHandling: NSViewRepresentable {
    let onCancel: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void
    let onCommit: () -> Void
    /// Returns true if Backspace was handled (consumed) — used to leave a locked
    /// mode when the field is empty; false lets the keystroke edit text normally.
    let onDeleteWhenEmpty: () -> Bool
    /// Clears the input field (⌃C).
    let onClear: () -> Void
    /// ⌘⏎ — run the selected row's secondary action (e.g. Reveal in Finder).
    let onSecondary: () -> Void
    /// ⌥⏎ — run the selected row's tertiary action (e.g. Quick Look).
    let onTertiary: () -> Void
    /// ⌘Y — Quick Look the selected row's file.
    let onQuickLook: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.handlers = handlers
        context.coordinator.start()
        DispatchQueue.main.async { [weak v] in context.coordinator.window = v?.window }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handlers = handlers
        if context.coordinator.window == nil { context.coordinator.window = nsView.window }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private var handlers: Coordinator.Handlers {
        .init(cancel: onCancel, up: onUp, down: onDown, commit: onCommit,
              deleteWhenEmpty: onDeleteWhenEmpty, clear: onClear,
              secondary: onSecondary, tertiary: onTertiary, quickLook: onQuickLook)
    }

    final class Coordinator {
        struct Handlers {
            let cancel: () -> Void
            let up: () -> Void
            let down: () -> Void
            let commit: () -> Void
            let deleteWhenEmpty: () -> Bool
            let clear: () -> Void
            let secondary: () -> Void
            let tertiary: () -> Void
            let quickLook: () -> Void
        }
        var handlers: Handlers?
        weak var window: NSWindow?
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ e: NSEvent) -> NSEvent? {
            guard let h = handlers else { return e }
            guard let w = window, e.window === w else { return e }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Standard Edit-menu shortcuts (⌘A/⌘C/⌘V/⌘X). A borderless,
            // non-activating panel has no menu, so AppKit never dispatches these
            // key equivalents to the field editor on its own — we route each to
            // the first responder explicitly. Returning nil consumes the event
            // once handled; an unmapped ⌘ combo falls through to edit normally.
            if mods == .command {
                let action: Selector?
                switch e.keyCode {
                case 0: action = #selector(NSText.selectAll(_:))  // A
                case 8: action = #selector(NSText.copy(_:))       // C
                case 9: action = #selector(NSText.paste(_:))      // V
                case 7: action = #selector(NSText.cut(_:))        // X
                default: action = nil
                }
                if let action {
                    NSApp.sendAction(action, to: nil, from: nil)
                    return nil
                }
            }
            // ⌃C → clear the input (expected "wipe the field" gesture here).
            if mods == .control, e.keyCode == 8 {  // C
                h.clear(); return nil
            }
            // Row-action accelerators (Alfred/Raycast file actions). ⌘⏎ / ⌥⏎ run
            // the selected row's secondary / tertiary action; ⌘Y Quick Looks it.
            // Consumed so they never edit the field. (⌘K — the full actions menu —
            // is a native SwiftUI Menu in the action bar, handled there, not here.)
            if mods == .command, e.keyCode == 36 || e.keyCode == 76 {  // ⌘Return
                h.secondary(); return nil
            }
            if mods == .option, e.keyCode == 36 || e.keyCode == 76 {   // ⌥Return
                h.tertiary(); return nil
            }
            if mods == .command, e.keyCode == 16 {  // ⌘Y (system Quick Look)
                h.quickLook(); return nil
            }
            switch e.keyCode {
            case 53: h.cancel(); return nil       // Esc
            case 125: h.down(); return nil        // ↓
            case 126: h.up(); return nil          // ↑
            case 36, 76: h.commit(); return nil   // Return / keypad Enter
            case 51: return h.deleteWhenEmpty() ? nil : e  // ⌫ exits a locked mode
            default: return e
            }
        }

        deinit { stop() }
    }
}
