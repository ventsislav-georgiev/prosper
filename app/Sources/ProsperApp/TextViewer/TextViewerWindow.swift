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
        // #1544 (D11): Read while edited renders the buffer, a live preview; the file is still read (its state and identity).
        let source = isDirty ? buffer : nil
        let (gen, path, markdown, loader, reader, cap) = (generation, resolved, isMarkdown, imageLoader, self.read, maxParagraphUnits)
        job = Task.detached(priority: .userInitiated) { [weak self] in
            let next = reader(path)
            if Task.isCancelled { return }
            let output = (try? next.get()).map { doc in
                let text = source ?? doc.text
                return markdown ? MarkdownRenderer.render(text, document: path, style: style, loader: loader)
                                : MarkdownRenderer.plain(text, style: style, maxParagraphUnits: cap)
            }
            await self?.apply(next, output, generation: gen, preview: source != nil)
        }
    }

    /// The shown output is a render of the buffer, not of the file.
    private var previewed = false

    private func apply(_ next: Result<TextViewerDocument, TextViewerDocument.Refusal>, _ out: MarkdownRenderer.Output?,
                       generation gen: Int, preview: Bool = false) {
        guard gen == generation else { return }   // a newer load is on its way
        let first = state == nil
        // R1108-r5-a: what a save will check against: the latest load's, also when the shown text is kept (not published).
        identity = (try? next.get())?.identity
        // The same bytes in the same theme keep the shown text (and so the selection and scroll); == ignores the identity.
        // A preview, or the first render after one, is always shown: the file's bytes did not change, the shown text did.
        if next != state || out?.style != output?.style || out?.note != output?.note || preview || previewed {
            state = next
            output = out
            previewed = preview
        }
        // D12, not dirty: an edited file that changed on disk takes the new text, the caret clamped. Dirty: kept, and #1545's
        // banner asks (a load of the bytes last loaded, saved or kept says nothing: a restyle, Read, a touch).
        if buffer != nil, !isDirty {
            diskChange = nil
            keptHash = nil
            if let doc = try? next.get(), doc.text != base || doc.encoding != encoding {
                adopt(doc)
                editorView?.replaceText(doc.text)
            }
        } else if buffer != nil {
            switch next {
            case .failure(.missing):
                diskChange = .deleted
                keptHash = nil   // nothing to overwrite: Save creates the file
            case .success(let doc):
                let hash = Self.hash(doc)
                if hash == baseHash {   // the bytes the buffer started from (also put back after a delete): no question
                    diskChange = nil
                    keptHash = nil
                } else if hash != keptHash {   // a change not yet kept: asked (again, after an older Keep Mine)
                    diskChange = .changed
                    keptHash = nil
                }
            default: break   // shortcut: a refusal on disk (binary, too large) has no banner, the save says why; upgrade if asked
            }
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

    // MARK: #1109 (D13): Edit in a terminal; #1544 (D11): the built-in editor

    enum Mode: Equatable { case read, edit, terminal }
    /// Never persisted: a window always opens in Read.
    @Published private(set) var mode = Mode.read
    /// The editor session this window started; kept after Read (it lives on) so the window's close ends it (OQ-118 Q3).
    /// #1599: a live session holds Quit and an update as a dirty buffer does (its editor's buffer is not seen, so live
    /// may be dirty). The new one reports before the old one goes, so a swap never lets a held update through.
    @Published private(set) var terminal: TextViewerTerminalEdit? {
        didSet {
            guard oldValue !== terminal else { return }
            if let t = terminal { dirtyRegistry.report(t, dirty: true) { [weak self] in self?.say($0) } }
            if let t = oldValue { dirtyRegistry.report(t, dirty: false) }
        }
    }
    var editor = TerminalEditorSeams.current
    /// The plan of the Edit in flight (the login shell and dch are asked off main); a row awaits it.
    private(set) var planning: Task<Void, Never>?
    private var closed = false

    /// Why Edit is off, or nil: a file shown as text that is not lossy (D1). A dirty buffer can always be edited again.
    var editOff: String? {
        if isDirty { return nil }
        guard let doc = document else { return "Only a text file can be edited" }
        return doc.readOnly ? "Not UTF-8: shown read-only" : nil
    }
    var canEdit: Bool { editOff == nil }

    /// The Edit button or ⌘T. The built-in editor, or with Settings › Text Viewer › Edit with set to Terminal the terminal
    /// editor: only then are the login shell and dch asked. A dirty buffer stays in the built-in editor.
    func edit() {
        guard mode == .read, planning == nil, !closed, canEdit else { return }
        let settings = editor.settings()
        guard settings.terminal, !isDirty else { return openEditor() }
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
        case .refused(let why):   // D13: the built-in editor opens instead, and says why
            say(why)
            openEditor()
        case .spawn(let spawn):
            terminal?.controller.detach()
            terminal = TextViewerTerminalEdit(spawn, controller: editor.makeController()) { [weak self] in self?.editorEnded() }
            mode = .terminal
        }
    }

    /// Read. From the terminal editor: the client detaches, the session lives on, the disk is shown. From the built-in one:
    /// the buffer is kept and, while dirty, rendered (D11).
    func showRead() {
        guard mode != .read else { return }
        if mode == .terminal { terminal?.controller.detach() }
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
    /// `done` is entered until the session's end is done (Quit waits on it; a close does not).
    func closeTerminal(_ done: DispatchGroup = DispatchGroup()) {
        closed = true
        planning?.cancel()
        guard let t = terminal else { return }
        terminal = nil
        t.controller.detach()
        editor.end(t.spawn, done)
    }

    /// The editor's text from the first Edit on, nil before; kept through Read (the preview renders it).
    private(set) var buffer: String?
    /// D11: the buffer differs from the text last loaded or saved; undoing back to it is clean. Each change is reported.
    @Published private(set) var isDirty = false
    /// The text last loaded into or saved from the buffer, its encoding, and the hash of its bytes (the save's check).
    private var base = ""
    private var encoding = TextViewerDocument.Encoding.utf8
    private var baseHash: TextFileWriter.Fingerprint = []
    /// Why the last save failed: shown under the header until a save succeeds or the edits are dropped.
    @Published private(set) var saveError: String?
    /// The save in flight (off main); a row awaits it.
    private(set) var saving: Task<Void, Never>?
    /// Where dirty is reported: Quit and an update wait on it (P3c). A seam: rows hand in their own.
    var dirtyRegistry = TextViewerDirty.shared
    /// D11: the close sheet. A seam: the live one answers Cancel under XCTest and shows nothing.
    var askToClose: @MainActor (NSWindow?, String, @escaping @MainActor (TextViewerEditor.CloseAnswer) -> Void) -> Void
        = TextViewerEditor.liveCloseSheet
    /// The editor's view, made on the first Edit and kept with the buffer, so the window's undo history keeps its target
    /// across Read and Edit.
    private(set) var editorScroll: NSScrollView?
    var editorView: TextViewerTextView? { editorScroll?.documentView as? TextViewerTextView }

    private func openEditor() {
        if buffer == nil, let doc = document { adopt(doc) }
        guard buffer != nil else { return }
        _ = makeEditor()
        mode = .edit
    }

    func makeEditor() -> NSScrollView {
        if let scroll = editorScroll { return scroll }
        let (scroll, view) = TextViewerEditor.makeEditor(buffer ?? "")
        view.onEdit = { [weak self] in self?.edited($0) }
        editorScroll = scroll
        return scroll
    }

    /// The buffer and its base become the loaded text: clean.
    private func adopt(_ doc: TextViewerDocument) {
        buffer = doc.text
        base = doc.text
        encoding = doc.encoding
        baseHash = Self.hash(doc)
    }

    /// The hash of a loaded file's bytes: decode is strict, so the text encodes back to the bytes read.
    private static func hash(_ doc: TextViewerDocument) -> TextFileWriter.Fingerprint {
        TextFileWriter.encode(doc.text, encoding: doc.encoding).map(TextFileWriter.digest) ?? []
    }

    /// The editor's text changed: typing, paste, undo.
    func edited(_ text: String) {
        guard buffer != nil else { return }
        buffer = text
        setDirty(text != base)
        // Undone back to the base while the disk differs: D12's clean case, the disk's text is taken.
        if !isDirty, diskChange != nil || keptHash != nil { reload() }
    }

    // MARK: #1545 (D12): a change on disk while dirty

    enum DiskChange: Equatable { case changed, deleted }
    /// The banner under the header: "Changed on disk" with Reload and Keep Mine, or "Deleted on disk". Only while dirty.
    @Published private(set) var diskChange: DiskChange?
    /// After Keep Mine: the hash of the disk's bytes the user chose to write over. The next save asks first, then checks the
    /// disk against this one, so a newer write still refuses the save.
    private var keptHash: TextFileWriter.Fingerprint?
    /// D12: "Overwrite the newer file on disk?". A seam: the live one answers no under XCTest and shows nothing.
    var askToOverwrite: @MainActor (NSWindow?, String, @escaping @MainActor (Bool) -> Void) -> Void
        = TextViewerEditor.liveOverwriteSheet

    /// Reload: the disk's text replaces the buffer, the edits are dropped, the window reports clean.
    func reloadFromDisk() {
        guard diskChange == .changed, let doc = document else { return }
        adopt(doc)
        editorView?.replaceText(doc.text)
        diskChange = nil
        keptHash = nil
        saveError = nil
        setDirty(false)
        if mode == .read { reload() }   // the shown preview was the buffer's
    }

    /// Keep Mine: the buffer stays dirty; the next save asks, then writes over the disk version seen here.
    func keepMine() {
        guard diskChange == .changed, let doc = document else { return }
        keptHash = Self.hash(doc)
        diskChange = nil
    }

    private func setDirty(_ dirty: Bool) {
        guard dirty != isDirty else { return }
        isDirty = dirty
        dirtyRegistry.report(self, dirty: dirty) { [weak self] in self?.say($0) }
    }

    /// D11: ⌘S or Save. The buffer in the file's own encoding, to the opened path resolved, checked against the bytes last
    /// read or saved; off main. `done` gets whether it was written. Text typed meanwhile stays dirty.
    /// After Keep Mine (D12) it asks "Overwrite the newer file on disk?" first.
    func save(then done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard saving == nil, isDirty, buffer != nil else { return done(false) }
        guard let kept = keptHash else { return write(expected: baseHash, then: done) }
        askToOverwrite(editorView?.window ?? textView?.window, shownName) { [weak self] yes in
            guard yes, let self, self.keptHash == kept else { return done(false) }
            self.write(expected: kept, then: done)
        }
    }

    private func write(expected: TextFileWriter.Fingerprint, then done: @escaping @MainActor (Bool) -> Void) {
        guard saving == nil else { return done(false) }
        guard isDirty, let text = buffer else { return done(false) }
        // #1601: the path the load reads (refresh), so the identity's path matches through a linked folder or a ../ link.
        let (url, identity, encoding) = (self.resolved, self.identity, self.encoding)
        saving = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                TextFileWriter.save(text, encoding: encoding, to: url, expected: expected, identity: identity)
            }.value
            guard let self else { return }
            self.saving = nil
            switch result {
            case .success(let hash):
                self.base = text
                self.baseHash = hash
                self.saveError = nil
                self.diskChange = nil
                self.keptHash = nil
                self.setDirty(self.buffer != text)
                done(true)
            case .failure(let failure):
                self.saveError = TextViewerEditor.message(failure)
                done(false)
            }
        }
    }

    /// Don't Save, or the window goes away: the edits are dropped and the window reports clean.
    func discard() {
        buffer = nil
        editorScroll = nil
        saveError = nil
        diskChange = nil
        keptHash = nil
        setDirty(false)
    }

    /// D11: the window's close. Clean: closes. Dirty: the sheet. Save closes once written, Don't Save drops the edits,
    /// Cancel keeps the window.
    func closeRequested(_ window: NSWindow?, close: @escaping @MainActor () -> Void) {
        guard isDirty else { return close() }
        askToClose(window, shownName) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .cancel: break
            case .discard:
                self.discard()
                close()
            case .save:
                self.save { [weak self] saved in if saved, self?.isDirty == false { close() } }
            }
        }
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
    /// #1544: where each new window reports dirty; rows hand in their own, so the app's Quit never waits on a test.
    var dirty: () -> TextViewerDirty = { .shared }
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
        model.dirtyRegistry = dirty()
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
        win.tabbingMode = .disallowed   // #1601: a window tab's close would skip performClose's dirty check
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

    /// Quit: every edit session a window started ends through the window close's path (OQ-118 Q3); the windows stay.
    /// #1604: returns once every `dch -k` has ended, or after `wait` (the app must not exit before the sessions end).
    func endEditSessions(wait: TimeInterval = TerminalEditor.quitWait) {
        let done = DispatchGroup()
        for entry in entries { entry.model.closeTerminal(done) }
        _ = done.wait(timeout: .now() + wait)
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
        entry.model.discard()   // #1544: reports clean before the window goes (a dirty close was asked first)
        dismissed(win)
        DispatchQueue.main.async { win.contentViewController = nil }
    }
}

/// D9 keys, routed by the window itself (the global main menu does not change): ⌘W closes;
/// ⌘F, ⌘G, ⇧⌘G drive the find bar; ⌘E puts the selection on the find pasteboard seam (R1).
/// #1109: ⌘T switches Read and Edit. #1544: ⌘S saves the built-in editor's buffer.
final class TextViewerNSWindow: NSWindow {
    weak var model: TextViewerModel?

    enum KeyRoute: Equatable { case close, find(NSTextFinder.Action), useSelectionForFind, toggleMode, save, pass }

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
        case "s": return .save
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
            guard let model, model.canEdit || model.mode != .read else { return super.performKeyEquivalent(with: event) }
            model.toggleMode()
        case .save:
            guard let model, model.mode == .edit || model.isDirty else { return super.performKeyEquivalent(with: event) }
            model.save()
        case .pass: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// #1544 (D11): the close button and ⌘W. A dirty buffer asks first (the sheet seam); `close()` itself never asks.
    override func performClose(_ sender: Any?) {
        guard let model, model.isDirty else { return super.performClose(sender) }
        model.closeRequested(self) { [weak self] in self?.close() }
    }
}

struct TextViewerRootView: View {
    @ObservedObject var model: TextViewerModel

    var body: some View {
        VStack(spacing: 0) {
            TextViewerHeader(model: model)
            Rectangle().fill(Neon.stroke).frame(height: 1)
            if let notice = model.notice { banner(notice) }
            if let error = model.saveError { banner(error) }
            if let change = model.diskChange { diskBanner(change) }
            if model.mode == .terminal, let t = model.terminal {
                TextViewerTerminalPane(controller: t.controller)
            } else if model.mode == .edit {
                TextViewerEditorRepresentable(model: model)
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

    /// #1545 (D12): "Changed on disk" with [Reload] (drops the edits) and [Keep Mine]; "Deleted on disk" alone (Save
    /// writes the file anew).
    func diskBanner(_ change: TextViewerModel.DiskChange) -> some View {
        HStack(spacing: sz(10)) {
            Text(TextViewerEditor.banner(change))
                .font(Neon.font(11, weight: .medium))
                .foregroundStyle(Neon.textSecondary)
                .lineLimit(1)
            if change == .changed {
                Button("Reload") { model.reloadFromDisk() }.buttonStyle(.borderless).fixedSize()
                    .help("Take the file on disk and drop your edits")
                Button("Keep Mine") { model.keepMine() }.buttonStyle(.borderless).fixedSize()
                    .help("Keep your edits; Save asks before writing over the file on disk")
            }
        }
        .font(Neon.font(11, weight: .medium))
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
            if model.isDirty {   // D11: the edited dot
                Circle().fill(Neon.textSecondary).frame(width: sz(6), height: sz(6))
                    .help("Edited").accessibilityLabel("Edited")
            }
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
            if model.isDirty {
                Button { model.save() } label: { label("Save", "square.and.arrow.down", titles: titles) }
                    .buttonStyle(.borderless).fixedSize()
                    .help("Save (\u{2318}S)")
            }
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
            if Self.showsScreenshot(model.mode) { TextViewerScreenshotButton(model: model) }
        }
    }

    /// Rider from #1107: Screenshot copies the rendered document, so it shows in Read only (never in Edit or the terminal).
    static func showsScreenshot(_ mode: TextViewerModel.Mode) -> Bool { mode == .read }

    @ViewBuilder private func label(_ title: String, _ symbol: String, titles: Bool) -> some View {
        if titles {
            Label(title, systemImage: symbol).font(Neon.font(11, weight: .medium))
        } else {
            Image(systemName: symbol).font(Neon.font(11, weight: .medium)).help(title).accessibilityLabel(title)
        }
    }
}

/// D15 (#1107): Screenshot, the whole document as one image on the clipboard. Read mode only
/// (TextViewerHeader.showsScreenshot).
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

/// Read | Edit (D10): the CapsuleSwitch, Read first (left) and the default. Off, with its reason as the help, when the
/// file cannot be edited; never off outside Read, so the way back is always there.
struct TextViewerModeSwitch: View {
    @ObservedObject var model: TextViewerModel

    /// The selected segment: Read, or Edit for either editor.
    static func selected(_ mode: TextViewerModel.Mode) -> Int { mode == .read ? TextViewerMode.read.rawValue : TextViewerMode.edit.rawValue }

    var body: some View {
        let off = model.mode == .read ? model.editOff : nil
        CapsuleSwitch(titles: TextViewerMode.allCases.map(\.title), selected: Self.selected(model.mode),
                      set: { $0 == TextViewerMode.read.rawValue ? model.showRead() : model.edit() },
                      help: CapsuleSwitch.textViewerHelp, off: off)
            .disabled(off != nil)
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
