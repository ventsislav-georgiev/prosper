import AppKit
import SwiftUI

// #1106 (design #1105 D9): one themed window per text file, in Read mode. Built on open and torn
// down on close, with AgentsWindow's build / present / dismissed seams, so tests run it with no
// window on screen. A Markdown file shows as its plain source until the renderer (P1b) lands.

/// What the header's Open With menu and the refusal's button do. A seam: tests never reach
/// NSWorkspace.
@MainActor
struct TextViewerActions {
    var defaultApp: (URL) -> URL?
    var openWith: (URL, URL) -> Void
    var reveal: (URL) -> Void

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
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
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
    @Published private(set) var state: Result<TextViewerDocument, TextViewerDocument.Refusal>
    /// The shown text view, for the window's find keys.
    weak var textView: TextViewerTextView?
    private(set) lazy var defaultApp: URL? = actions.defaultApp(url)

    init(url: URL, resolved: URL, actions: TextViewerActions) {
        self.url = url
        self.resolved = resolved
        self.actions = actions
        isMarkdown = TextViewerRouting.isMarkdown(url)
        state = TextViewerDocument.load(url)
    }

    var name: String { url.lastPathComponent }
    var document: TextViewerDocument? { try? state.get() }

    /// The first load found a regular file (shown, or refused for its size or bytes): worth
    /// watching. A missing file, a folder or a FIFO is not watched.
    var isRegularFile: Bool {
        switch state {
        case .success, .failure(.tooLarge), .failure(.binary): true
        default: false
        }
    }

    func reload() {
        let next = TextViewerDocument.load(url)
        if next != state { state = next }
    }

    func copyText() { if let text = document?.text { put(text) } }   // P1b: the rendered text
    func copySource() { if let text = document?.text { put(text) } }
    func copyPath() { put(url.path) }

    private func put(_ s: String) {
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    func openInDefaultApp() { if let app = defaultApp { actions.openWith(url, app) } }
    func reveal() { actions.reveal(url) }
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

    /// Opens `url` in its own window, or focuses the one already showing that file: the same path
    /// through symlinks, or the same file resource id (another case of the name, a hard link).
    func open(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        let fileID = (try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        if let open = entries.first(where: {
            $0.model.resolved.path == resolved.path || (fileID != nil && $0.fileID?.isEqual(fileID) == true)
        }) { return present(open.window) }

        let model = TextViewerModel(url: url, resolved: resolved, actions: actions())
        let win = build(model)
        if let last = entries.last?.window {   // cascade from the newest window
            win.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + sz(24), y: last.frame.maxY - sz(24)))
        }
        let entry = Entry(model: model, window: win, fileID: fileID)
        if model.isRegularFile {
            entry.watcher = FileWatcher(url: resolved) { [weak model] in
                MainActor.assumeIsolated { model?.reload() }
            }
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
        win.title = model.name   // the Window list; the header shows the name
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

    private func teardown(_ win: NSWindow) {
        guard let i = entries.firstIndex(where: { $0.window === win }) else { return }
        let entry = entries.remove(at: i)
        entry.watcher?.stop()
        if let o = entry.observer { NotificationCenter.default.removeObserver(o) }
        dismissed(win)
        DispatchQueue.main.async { win.contentViewController = nil }
    }
}

/// D9 keys, routed by the window itself (the global main menu does not change): ⌘W closes;
/// ⌘F, ⌘G, ⇧⌘G drive the find bar; ⌘E puts the selection on the find pasteboard seam (R1).
/// ⌘T stays unrouted until Edit exists (P3).
final class TextViewerNSWindow: NSWindow {
    weak var model: TextViewerModel?

    enum KeyRoute: Equatable { case close, find(NSTextFinder.Action), useSelectionForFind, pass }

    static func route(_ event: NSEvent) -> KeyRoute {
        guard event.type == .keyDown else { return .pass }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = AgentsNSWindow.chordLetter(event)
        if mods.contains(.command), key == "w" { return .close }
        if mods == [.command, .shift], key == "g" { return .find(.previousMatch) }
        guard mods == [.command] else { return .pass }
        switch key {
        case "f": return .find(.showFindInterface)
        case "g": return .find(.nextMatch)
        case "e": return .useSelectionForFind
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
            switch model.state {
            case .success(let doc):
                if doc.readOnly { banner("Not UTF-8: shown read-only") }
                TextViewerTextRepresentable(text: doc.text, model: model)
            case .failure(let refusal):
                refused(refusal)
            }
        }
        .background(SettingsBackground())
    }

    func banner(_ text: String) -> some View {
        Text(text)
            .font(Neon.font(11, weight: .medium))
            .foregroundStyle(Neon.textSecondary)
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

/// The header row, left to right: [Read | Edit], the file name, Copy ▾, Open With ▾.
struct TextViewerHeader: View {
    @ObservedObject var model: TextViewerModel

    var body: some View {
        HStack(spacing: sz(10)) {
            TextViewerModeSwitch()
            Text(model.name)
                .font(Neon.font(13, weight: .semibold))
                .foregroundStyle(Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: sz(8))
            Menu {
                Button("Copy Text") { model.copyText() }
                if model.isMarkdown { Button("Copy Markdown Source") { model.copySource() } }
                Button("Copy Path") { model.copyPath() }
            } label: {
                Label("Copy", systemImage: "doc.on.doc").font(Neon.font(11, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(model.document == nil)
            Menu {
                if let app = model.defaultApp {
                    Button("Open in \(FileManager.default.displayName(atPath: app.path))") { model.openInDefaultApp() }
                }
                Button("Reveal in Finder") { model.reveal() }
            } label: {
                Label("Open With", systemImage: "arrow.up.forward.app").font(Neon.font(11, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, sz(14))
        .padding(.vertical, sz(8))
    }
}

/// Read | Edit, drawn like AgentVerbosityPicker's labels style. Read is first (left) and is the
/// only mode; Edit is drawn disabled until the built-in editor lands (P3).
struct TextViewerModeSwitch: View {
    struct Segment: Hashable { let title: String; let enabled: Bool }
    static let segments = [Segment(title: "Read", enabled: true), Segment(title: "Edit", enabled: false)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.segments, id: \.title) { seg in
                let on = seg.title == "Read"
                Button {} label: {
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
                .help(seg.enabled ? "Read" : "Editing comes in a later version")
                .accessibilityLabel("\(seg.title) mode")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(sz(2))
        .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
        .fixedSize()
    }
}

/// The TextKit 1 view inside SwiftUI. A theme or UI-size change rebuilds it through Themed's id.
struct TextViewerTextRepresentable: NSViewRepresentable {
    let text: String
    let model: TextViewerModel

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = TextViewerTextView.makeScrollable()
        model.textView = view
        update(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? TextViewerTextView { update(view) }
    }

    private func update(_ view: TextViewerTextView) {
        view.show(text, font: .monospacedSystemFont(ofSize: 13 * ThemeRuntime.scale, weight: .regular),
                  color: NSColor(Neon.textPrimary))
    }
}
