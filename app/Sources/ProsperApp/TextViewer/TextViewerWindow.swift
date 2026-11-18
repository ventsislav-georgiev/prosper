import AppKit
import SwiftUI

// #1106 (design #1105 D9): one themed window per text file, in Read mode. Built on open and torn
// down on close, with AgentsWindow's build / present / dismissed seams, so tests run it with no
// window on screen. #1118: a Markdown file is rendered (MarkdownRenderer), and the file is read and
// rendered off the main thread.

/// What the header's Open With menu, the refusal's button and a clicked link do. A seam: tests never
/// reach NSWorkspace.
@MainActor
struct TextViewerActions {
    var defaultApp: (URL) -> URL?
    var openWith: (URL, URL) -> Void
    var reveal: (URL) -> Void
    /// D6: http, https and mailto, on a click only: the user's default browser or mail app.
    var openURL: (URL) -> Void
    /// D6: a linked text document, in its own viewer window in Read mode.
    var view: (URL) -> Void

    /// The type's default app, never Prosper itself (it would open the same window again).
    static var live: TextViewerActions {
        TextViewerActions(
            defaultApp: { url in
                guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
                let id = Bundle(url: app)?.bundleIdentifier ?? ""
                return OpenedLinkRouter.selfBundleIDs.contains(id) ? nil : app
            },
            openWith: { url, app in
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            openURL: { NSWorkspace.shared.open($0) },
            view: { TextViewerWindows.shared.open($0) })
    }
}

@MainActor
final class TextViewerModel: ObservableObject {
    /// As opened (its name is the window's); `resolved` is through symlinks (the registry key and
    /// the watched path).
    let url: URL
    let resolved: URL
    let isMarkdown: Bool
    let actions: TextViewerActions
    let imageLoader: TextViewerImageLoader
    /// Nil until the first load lands (R1118-2: the file is read off the main thread).
    @Published private(set) var state: Result<TextViewerDocument, TextViewerDocument.Refusal>?
    /// What the text view shows: the rendered Markdown, or the plain text (D5). Set with `state`.
    @Published private(set) var output: MarkdownRenderer.Output?
    /// The shown text view, for the window's find keys and fragment links.
    weak var textView: TextViewerTextView?
    private(set) lazy var defaultApp: URL? = actions.defaultApp(url)
    /// Runs once, on the main thread, when the first load lands (the registry starts watching then).
    var onFirstLoad: (() -> Void)?
    /// Runs on the main thread after every later load that lands (R896-1: the registry stops
    /// watching a path that is no longer a regular file).
    var onReload: (() -> Void)?
    /// Loads applied so far, changed or not: a test waits on it instead of a timer.
    private(set) var loads = 0
    /// The newest load; a row awaits one it kept to know that load has ended.
    private(set) var job: Task<Void, Never>?
    private var generation = 0
    private var requested: MarkdownRenderer.Style?
    /// Reads the file, off the main thread. A seam: a row holds a read to order two loads.
    private let read: @Sendable (URL) -> Result<TextViewerDocument, TextViewerDocument.Refusal>
    /// #1236: the plain render's paragraph cap. A seam: a row passes a small one, so a cut needs no large file.
    private let maxParagraphUnits: Int

    init(url: URL, resolved: URL, actions: TextViewerActions, imageLoader: @escaping TextViewerImageLoader = ImagePolicy.load,
         read: @escaping @Sendable (URL) -> Result<TextViewerDocument, TextViewerDocument.Refusal> = TextViewerDocument.load,
         maxParagraphUnits: Int = MarkdownRenderer.maxParagraphUnits) {
        self.url = url
        self.resolved = resolved
        self.actions = actions
        self.imageLoader = imageLoader
        self.read = read
        self.maxParagraphUnits = maxParagraphUnits
        isMarkdown = TextViewerRouting.isMarkdown(url)
        refresh(style: .current)
    }

    var name: String { url.lastPathComponent }
    /// R1162-1: the name as the title and header show it: each direction control (LinkPolicy.bidiControls)
    /// written as \u{XXXX}, since the file is already open and cannot be refused.
    var shownName: String { Self.shown(name) }
    nonisolated static func shown(_ name: String) -> String {
        name.unicodeScalars.map { LinkPolicy.bidiControls.contains($0.value) ? "\\u{" + String($0.value, radix: 16, uppercase: true) + "}" : String($0) }.joined()
    }
    var document: TextViewerDocument? { try? state?.get() }
    /// What the latest load opened (R1108-q3): the one a save passes, never `document?.identity` (kept from an older load when
    /// that load's bytes were the same). Nil for a refusal or a load with no identity. Not published: nothing is redrawn.
    private(set) var identity: TextViewerDocument.Identity?

    /// The first load found a regular file (shown, or refused for its size or bytes) or nothing
    /// (#1147: the window fills in when the file is created): worth watching. A folder or a FIFO
    /// (.notRegular) and an unreadable path are not watched.
    var isWatched: Bool {
        switch state {
        case .success?, .failure(.tooLarge)?, .failure(.binary)?, .failure(.missing)?: true
        default: false
        }
    }

    /// A change on disk: read and render again in the current theme.
    func reload() { refresh(style: requested ?? .current) }

    /// The theme changed (the text view saw another style): render again, once per style.
    func restyle(_ style: MarkdownRenderer.Style) {
        if style != requested { refresh(style: style) }
    }

    /// Reads and renders off the main thread; the newest request wins. The closure is @Sendable and
    /// nonisolated (Task.detached): it captures only Sendable values (URLs, the style, the @Sendable
    /// loader) and calls only nonisolated functions, then hops back to the main actor to publish.
    /// The resolved path is read, the one the watcher follows (R1118-7). A load superseded before its
    /// render skips the render (the cancellation); one superseded later is dropped by apply's guard.
    private func refresh(style: MarkdownRenderer.Style) {
        job?.cancel()
        generation += 1
        requested = style
        let (gen, path, markdown, loader, reader, cap) = (generation, resolved, isMarkdown, imageLoader, self.read, maxParagraphUnits)
        job = Task.detached(priority: .userInitiated) { [weak self] in
            let next = reader(path)
            if Task.isCancelled { return }
            let output = (try? next.get()).map { doc in
                markdown ? MarkdownRenderer.render(doc.text, document: path, style: style, loader: loader)
                         : MarkdownRenderer.plain(doc.text, style: style, maxParagraphUnits: cap)
            }
            await self?.apply(next, output, generation: gen)
        }
    }

    private func apply(_ next: Result<TextViewerDocument, TextViewerDocument.Refusal>, _ out: MarkdownRenderer.Output?,
                       generation gen: Int) {
        guard gen == generation else { return }   // a newer load is on its way
        let first = state == nil
        // R1108-r5-a: what a save will check against: the latest load's, also when the shown text is kept (not published).
        identity = (try? next.get())?.identity
        // The same bytes in the same theme keep the shown text (and so the selection and scroll); == ignores the identity.
        if next != state || out?.style != output?.style || out?.note != output?.note {
            state = next
            output = out
        }
        if first { onFirstLoad?(); onFirstLoad = nil } else { onReload?() }
        loads += 1
    }

    /// D6: a clicked link. The policy is asked again at the click; only its action runs.
    func follow(_ link: URL) {
        switch LinkPolicy.action(link, document: resolved) {
        case .open(let u): actions.openURL(u)
        case .view(let u): actions.view(u)
        case .reveal(let u): actions.reveal(u)
        case .scroll(let slug):
            guard let at = output?.anchors[slug], let view = textView, at <= (view.textStorage?.length ?? 0) else { return }
            view.scrollRangeToVisible(NSRange(location: at, length: 0))
        case .none: break
        }
    }

    struct CopyItem: Equatable { let title: String; let enabled: Bool }

    /// The header's Copy items and whether each is on: a refused file still has a path (R1118-9).
    var copyItems: [CopyItem] {
        [CopyItem(title: "Copy Text", enabled: output != nil)]
            + (isMarkdown ? [CopyItem(title: "Copy Markdown Source", enabled: document != nil)] : [])
            + [CopyItem(title: "Copy Path", enabled: true)]
    }

    func copy(_ title: String) {
        switch title {
        case "Copy Text": if let text = output?.text.string { put(TextViewerTextView.plainString(text)) }   // the rendered text
        case "Copy Markdown Source": if let text = document?.text { put(text) }
        case "Copy Path": put(url.path)
        default: break
        }
    }

    func copyText() { copy("Copy Text") }
    func copySource() { copy("Copy Markdown Source") }
    func copyPath() { copy("Copy Path") }

    private func put(_ s: String) {
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    func openInDefaultApp() { if let app = defaultApp { actions.openWith(url, app) } }

    // MARK: #1109 (D13): Edit in a terminal

    enum Mode: Equatable { case read, terminal }
    /// Never persisted: a window always opens in Read.
    @Published private(set) var mode = Mode.read
    /// The editor session this window started; kept after Read (it lives on) so the window's close ends it (OQ-118 Q3).
    @Published private(set) var terminal: TextViewerTerminalEdit?
    var editor = TerminalEditorSeams.current
    /// The plan of the Edit in flight (the login shell and dch are asked off main); a row awaits it.
    private(set) var planning: Task<Void, Never>?
    private var closed = false

    /// Edit is on with Settings › Text Viewer › Edit with set to Terminal (the built-in editor is P3's).
    var canEdit: Bool { editor.settings().terminal }

    /// The Edit button or ⌘T: only here are the login shell and dch asked, and only for a file shown as text.
    func edit() {
        let settings = editor.settings()
        guard settings.terminal, mode == .read, planning == nil, !closed, document?.readOnly == false else { return }
        let path = resolved.path, io = editor.io, cache = editor.cache
        planning = Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) {
                TerminalEditor.plan(command: settings.command, path: path, io: io, cache: cache)
            }.value
            self?.planned(plan)
        }
    }

    private func planned(_ plan: TerminalEditor.Plan) {
        planning = nil
        guard !closed, mode == .read else { return }   // closed meanwhile: nothing starts for a gone window
        switch plan {
        case .refused(let why): say(why)
        case .spawn(let spawn):
            terminal?.controller.detach()
            terminal = TextViewerTerminalEdit(spawn, controller: editor.makeController()) { [weak self] in self?.editorEnded() }
            mode = .terminal
        }
    }

    /// Read while the editor runs: the client detaches, the session lives on, the disk is shown.
    func showRead() {
        guard mode == .terminal else { return }
        terminal?.controller.detach()
        mode = .read
        reload()
    }

    /// ⌘T.
    func toggleMode() { mode == .read ? edit() : showRead() }

    /// The editor quit (the controller's `.ended`): back to Read with the file read again.
    private func editorEnded() {
        guard let t = terminal, t.controller.phase == .ended else { return }
        terminal = nil
        mode = .read
        reload()
    }

    /// The window closed: its client goes, and OQ-118 Q3: its editor session ends too. An Edit in flight starts nothing.
    func closeTerminal() {
        closed = true
        planning?.cancel()
        guard let t = terminal else { return }
        terminal = nil
        t.controller.detach()
        editor.end(t.spawn)
    }
    func reveal() { actions.reveal(url) }

    /// D15 (#1107): what the last Screenshot did, shown under the header for 5 s.
    @Published private(set) var notice: String?
    /// R1107-2: which screenshot said the notice; a timer clears only its own.
    private var noticeGeneration = 0
    /// R1107-4: the notice's wait (5 s), a seam; a row replaces it and awaits the timer it kept.
    var noticeWait: @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(5)) }
    private(set) var noticeTimer: Task<Void, Never>?

    /// D15: the header's Screenshot. One PNG of the whole shown text (all of the scroll) on the clipboard
    /// through the Pasteboard.general seam, at the window's column width, appearance and backing scale.
    /// Reads the live view; never scrolls it, selects in it or lays it out.
    func screenshot() {
        guard let text = output?.text, let view = textView, let column = view.textContainer?.size.width else { return }
        let said = DocumentImage.copy(text, column: column, appearance: view.effectiveAppearance, background: DocumentImage.surface,
                                      backing: view.window?.backingScaleFactor ?? 1, to: Pasteboard.general)
        say(said)
    }

    /// Shows `text` under the header for 5 s (a newer notice is left in place, even when it says the same).
    func say(_ text: String) {
        notice = text
        noticeGeneration += 1
        let generation = noticeGeneration
        // Runs on the main actor; a newer screenshot's notice is left in place, even when it says the same.
        noticeTimer = Task { @MainActor [weak self, wait = noticeWait] in
            await wait()
            if let self, self.noticeGeneration == generation { self.notice = nil }
        }
    }
}

@MainActor
final class TextViewerWindows {
    static let shared = TextViewerWindows()
    static let themedIdentifier = NSUserInterfaceItemIdentifier("prosper.textViewer")
    static let autosaveName = "ProsperTextViewer"
    static func contentMinSize(scale: CGFloat) -> NSSize { NSSize(width: 420 * scale, height: 300 * scale) }

    final class Entry {
        let model: TextViewerModel
        let window: NSWindow
        let fileID: NSObject?
        var watcher: FileWatcher?
        var observer: NSObjectProtocol?
        init(model: TextViewerModel, window: NSWindow, fileID: NSObject?) {
            self.model = model; self.window = window; self.fileID = fileID
        }
    }

    private(set) var entries: [Entry] = []

    // Seams (as AgentsWindow's): tests build the window and never put it on screen.
    var build: (TextViewerModel) -> NSWindow = { TextViewerWindows.makeWindow($0) }
    var present: (NSWindow) -> Void = { win in
        DockPolicy.windowDidShow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
    var dismissed: (NSWindow) -> Void = { DockPolicy.windowDidHide($0) }
    var actions: () -> TextViewerActions = { .live }
    var imageLoader: TextViewerImageLoader = ImagePolicy.load
    /// #1109: the terminal editor's seams for each new window.
    var editorSeams: () -> TerminalEditorSeams = { .current }
    /// R896-1: a path on an automount or network location is looked at a bounded number of times (FileWatcher.remote).
    /// The live check reads the mount table only (FileWatcher.onAutomountOrNetwork); rows inject one.
    var isRemote: (URL) -> Bool = { FileWatcher.onAutomountOrNetwork($0.path) }
    /// The longest wait between two looks at a missing path (FileWatcher's back-off ceiling).
    static let retryCeiling: TimeInterval = 60

    /// Opens `url` in its own window, or focuses the one already showing that file: the same path
    /// through symlinks, or the same file resource id (another case of the name, a hard link).
    func open(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        let fileID = (try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        if let open = entries.first(where: {
            $0.model.resolved.path == resolved.path || (fileID != nil && $0.fileID?.isEqual(fileID) == true)
        }) { return present(open.window) }

        let model = TextViewerModel(url: url, resolved: resolved, actions: actions(), imageLoader: imageLoader)
        model.editor = editorSeams()
        let win = build(model)
        if let last = entries.last?.window {   // cascade from the newest window
            win.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + sz(24), y: last.frame.maxY - sz(24)))
        }
        let entry = Entry(model: model, window: win, fileID: fileID)
        let remote = isRemote(resolved)
        // Watched once the first (off-main) load knows what the path is. Set before that load can land:
        // it publishes on the main actor, after this function returns. Called on the main actor (apply).
        model.onFirstLoad = { [weak self, weak entry, weak model] in
            guard let entry, let model, model.isWatched else { return }
            // Created between the first load and the first arm: that arm fires (#1147).
            entry.watcher = FileWatcher(url: resolved, absent: model.state == .failure(.missing),
                                        retryCeiling: Self.retryCeiling, remote: remote) { [weak self, weak model] in
                // @Sendable, called by FileWatcher on the main queue.
                MainActor.assumeIsolated { if let model { self?.changed(model) } }
            }
        }
        // R896-1: a reload that finds a folder or a FIFO there stops the watch (a change inside a folder
        // would reload the same refusal). Called on the main actor (apply).
        model.onReload = { [weak entry] in
            guard let entry, entry.model.state == .failure(.notRegular) else { return }
            entry.watcher?.stop()
            entry.watcher = nil
        }
        entry.observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.teardown(win) }
            }
        entries.append(entry)
        present(win)
    }

    /// The window, built but not shown (tests pass a nil `autosave`: no frame is read from or
    /// written to the defaults).
    static func makeWindow(_ model: TextViewerModel, autosave: String? = autosaveName) -> TextViewerNSWindow {
        let hosting = NSHostingController(rootView: Themed { TextViewerRootView(model: model) })
        let win = TextViewerNSWindow(contentViewController: hosting)
        win.model = model
        win.title = model.shownName   // the Window list; the header shows the name
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.identifier = themedIdentifier   // AppDelegate.applyThemedWindowSizing finds it by this
        let s = ThemeRuntime.scale
        win.setContentSize(NSSize(width: 820 * s, height: 640 * s))
        win.contentMinSize = contentMinSize(scale: s)
        SettingsWindow.applyWindowOpacity(win)
        win.isReleasedWhenClosed = false
        if let autosave { win.setFrameAutosaveName(autosave) }
        if !(autosave.map { win.setFrameUsingName($0) } ?? false) { win.centerOnScreen() }
        win.clampToContentMinSize()
        return win
    }

    /// The watcher saw a change: reload, unless the window has closed (a fire already queued to main
    /// when it closed does nothing). Returns whether it reloaded.
    @discardableResult
    func changed(_ model: TextViewerModel) -> Bool {
        guard entries.contains(where: { $0.model === model }) else { return false }
        model.reload()
        return true
    }

    private func teardown(_ win: NSWindow) {
        guard let i = entries.firstIndex(where: { $0.window === win }) else { return }
        let entry = entries.remove(at: i)
        entry.watcher?.stop()
        entry.watcher = nil
        if let o = entry.observer { NotificationCenter.default.removeObserver(o) }
        entry.observer = nil
        entry.model.onFirstLoad = nil   // a load still on its way starts no watcher for a closed window
        entry.model.closeTerminal()   // #1109
        dismissed(win)
        DispatchQueue.main.async { win.contentViewController = nil }
    }
}

/// D9 keys, routed by the window itself (the global main menu does not change): ⌘W closes;
/// ⌘F, ⌘G, ⇧⌘G drive the find bar; ⌘E puts the selection on the find pasteboard seam (R1).
/// #1109: ⌘T switches Read and Edit.
final class TextViewerNSWindow: NSWindow {
    weak var model: TextViewerModel?

    enum KeyRoute: Equatable { case close, find(NSTextFinder.Action), useSelectionForFind, toggleMode, pass }

    static func route(_ event: NSEvent) -> KeyRoute {
        guard event.type == .keyDown else { return .pass }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = AgentsNSWindow.chordLetter(event)
        if mods == [.command, .shift], key == "g" { return .find(.previousMatch) }
        guard mods == [.command] else { return .pass }   // ⇧⌘W, ⌥⌘W and the rest are not ours (R1118-4)
        switch key {
        case "w": return .close
        case "f": return .find(.showFindInterface)
        case "g": return .find(.nextMatch)
        case "e": return .useSelectionForFind
        case "t": return .toggleMode
        default: return .pass
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        switch Self.route(event) {
        case .close: performClose(nil)
        case .find(let action):
            guard let view = model?.textView else { return super.performKeyEquivalent(with: event) }
            view.find(action)
        case .useSelectionForFind:
            guard let view = model?.textView else { return super.performKeyEquivalent(with: event) }
            view.useSelectionForFind()
        case .toggleMode:
            guard let model, model.canEdit else { return super.performKeyEquivalent(with: event) }
            model.toggleMode()
        case .pass: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

struct TextViewerRootView: View {
    @ObservedObject var model: TextViewerModel

    var body: some View {
        VStack(spacing: 0) {
            TextViewerHeader(model: model)
            Rectangle().fill(Neon.stroke).frame(height: 1)
            if let notice = model.notice { banner(notice) }
            if model.mode == .terminal, let t = model.terminal {
                TextViewerTerminalPane(controller: t.controller)
            } else {
            switch model.state {
            case nil:
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)   // the first load is on its way
            case .success(let doc)?:
                if doc.readOnly { banner("Not UTF-8: shown read-only") }
                if let note = model.output?.note { banner(note) }
                if let output = model.output {
                    TextViewerTextRepresentable(output: output, model: model)
                }
            case .failure(let refusal)?:
                refused(refusal)
            }
            }
        }
        .background(SettingsBackground())
    }

    func banner(_ text: String) -> some View {
        // N1236-a: one line at any width (the joined notes wrapped at the minimum width); the full text in the help and on
        // the accessibility tree (a truncated Text keeps its whole label).
        Text(text)
            .font(Neon.font(11, weight: .medium))
            .foregroundStyle(Neon.textSecondary)
            .lineLimit(1).truncationMode(.tail)
            .help(text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, sz(5))
            .background(Neon.card)
    }

    func refused(_ refusal: TextViewerDocument.Refusal) -> some View {
        VStack(spacing: sz(12)) {
            Image(systemName: "doc.text").font(Neon.font(28)).foregroundStyle(Neon.textSecondary)
            Text(refusal.message).font(Neon.font(13)).foregroundStyle(Neon.textPrimary)
            if let app = model.defaultApp {
                Button("Open in \(FileManager.default.displayName(atPath: app.path))") { model.openInDefaultApp() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The header row, left to right: [Read | Edit], the file name, Copy ▾, Open With ▾, Screenshot (#1107).
struct TextViewerHeader: View {
    @ObservedObject var model: TextViewerModel

    var body: some View {
        HStack(spacing: sz(10)) {
            TextViewerModeSwitch(model: model)
            Text(model.shownName)
                .font(Neon.font(13, weight: .semibold))
                .foregroundStyle(Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: sz(8))
            // #1107: where the titled menus and Screenshot do not fit (UI scale 0.7 at the minimum width), the
            // menus show their icons only. Laid out before the name, which truncates first.
            ViewThatFits(in: .horizontal) {
                actions(titles: true)
                actions(titles: false)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, sz(14))
        .padding(.vertical, sz(8))
    }

    private func actions(titles: Bool) -> some View {
        HStack(spacing: sz(10)) {
            Menu {
                ForEach(model.copyItems, id: \.title) { item in
                    Button(item.title) { model.copy(item.title) }.disabled(!item.enabled)
                }
            } label: {
                label("Copy", "doc.on.doc", titles: titles)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                if let app = model.defaultApp {
                    Button("Open in \(FileManager.default.displayName(atPath: app.path))") { model.openInDefaultApp() }
                }
                Button("Reveal in Finder") { model.reveal() }
            } label: {
                label("Open With", "arrow.up.forward.app", titles: titles)
            }
            .menuStyle(.borderlessButton).fixedSize()
            if model.mode == .read { TextViewerScreenshotButton(model: model) }
        }
    }

    @ViewBuilder private func label(_ title: String, _ symbol: String, titles: Bool) -> some View {
        if titles {
            Label(title, systemImage: symbol).font(Neon.font(11, weight: .medium))
        } else {
            Image(systemName: symbol).font(Neon.font(11, weight: .medium)).help(title).accessibilityLabel(title)
        }
    }
}

/// D15 (#1107): Screenshot, the whole document as one image on the clipboard. Read mode only: there is
/// no Edit mode yet; P3 (#1108) hides this button in Edit.
struct TextViewerScreenshotButton: View {
    @ObservedObject var model: TextViewerModel

    var body: some View {
        Button { model.screenshot() } label: {
            Image(systemName: "camera.viewfinder").font(Neon.font(11, weight: .medium))
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(model.output == nil)
        .help("Copy an image of the whole document")
        .accessibilityLabel("Screenshot")
    }
}

/// Read | Edit, drawn like the old Agent Sessions detail picker's labels style (gone, #1471). Read is first (left) and the
/// default. #1109: Edit opens the terminal editor when Settings › Text Viewer › Edit with is Terminal; otherwise it is
/// drawn disabled until the built-in editor lands (P3).
struct TextViewerModeSwitch: View {
    @ObservedObject var model: TextViewerModel
    struct Segment: Hashable { let title: String; let enabled: Bool }
    static func segments(canEdit: Bool) -> [Segment] { [Segment(title: "Read", enabled: true), Segment(title: "Edit", enabled: canEdit)] }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.segments(canEdit: model.canEdit), id: \.title) { seg in
                let on = (seg.title == "Read") == (model.mode == .read)
                Button { seg.title == "Read" ? model.showRead() : model.edit() } label: {
                    Text(seg.title)
                        .font(Neon.font(10.5, weight: .medium))
                        .foregroundStyle(on ? Neon.textPrimary : Neon.textSecondary)
                        .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
                        .background(Capsule().fill(on ? Neon.blue.opacity(0.2) : .clear))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .disabled(!seg.enabled)
                .opacity(seg.enabled ? 1 : 0.45)
                .help(seg.enabled ? "\(seg.title) (\u{2318}T)" : "Editing comes in a later version")
                .accessibilityLabel("\(seg.title) mode")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(sz(2))
        .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
        .fixedSize()
    }
}

/// The TextKit 1 view inside SwiftUI. A theme or UI-size change rebuilds it through Themed's id; the
/// model then renders again in the new style, off the main thread, and the old text stays until then.
struct TextViewerTextRepresentable: NSViewRepresentable {
    let output: MarkdownRenderer.Output
    let model: TextViewerModel

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = TextViewerTextView.makeScrollable()
        model.textView = view
        view.onLink = { [weak model] in model?.follow($0) }
        update(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? TextViewerTextView { update(view) }
    }

    private func update(_ view: TextViewerTextView) {
        view.show(output.text)
        model.restyle(.current)   // a no-op unless the theme moved since this text was rendered
    }
}

/// #1109: the Edit pane, the editor's dch session drawn as the Agent Sessions window draws one.
struct TextViewerTerminalPane: View {
    @ObservedObject var controller: AgentTerminalController

    var body: some View {
        AgentTerminalRepresentable(controller: controller, screen: controller.screen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if let why = Self.card(controller.phase) { Text(why).font(Neon.font(13)).foregroundStyle(Neon.textSecondary) } }
    }

    /// What the pane says over the terminal: a failed start or a client that left (Read, then Edit, attaches again).
    static func card(_ phase: AgentTerminalController.Phase) -> String? {
        switch phase {
        case .failed(let why), .detached(let why): why
        default: nil
        }
    }
}
