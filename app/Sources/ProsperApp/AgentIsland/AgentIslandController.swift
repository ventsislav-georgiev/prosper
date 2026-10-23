// Owns Agent Island (#474) end to end: the borderless non-activating panel over
// the notch, the 1 s stat poll on a utility queue (dch is forked only when the
// gate in AgentIslandModel says so), expand/collapse, and the row-click jump.
// Gated by the com.prosper.agentisland system extension (ships default-disabled)
// exactly like CalendarBarController: AppDelegate sets `extLive` at launch and
// on every extension toggle, and `reload()` builds or tears everything down — a
// disabled install has no panel, no timer and never forks dch.

import AppKit
import SwiftUI

/// Key only while expanded (Escape needs it); collapsed it never takes focus.
final class AgentIslandPanel: NSPanel {
    var keyable = false
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// The app is never active behind the island, so the first click must count.
private final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AgentIslandController {
    static let shared = AgentIslandController()

    /// Whether the extension is enabled + trusted. Set by AppDelegate.
    var extLive = false

    private var store: AgentIslandStore?
    private var panel: AgentIslandPanel?
    private var timer: DispatchSourceTimer?
    private var outsideClick: Any?
    private var screenObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "eu.illegible.prosper.agentisland", qos: .utility)

    private init() {}

    /// Idempotent — launch and every extension toggle.
    func reload() {
        guard extLive else { teardown(); return }
        guard timer == nil, let geometry = AgentIslandGeometry.current() else { return }
        store = AgentIslandStore(geometry: geometry)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        let poller = AgentIslandPoller()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in
            guard let sessions = poller.tick() else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(sessions) } }
        }
        t.resume()
        timer = t
    }

    private func apply(_ sessions: [AgentSession]) {
        guard timer != nil, let store else { return }   // a tick that raced teardown
        store.sessions = sessions
        let live = Set(sessions.map(\.key))
        store.notices = store.notices.filter { live.contains($0.key) }
        if sessions.isEmpty { setExpanded(false) }
        layout()
    }

    /// Size the panel to the island so nothing outside it eats clicks; hide it
    /// with no sessions.
    private func layout() {
        guard let store else { return }
        if let g = AgentIslandGeometry.current(), g != store.geometry { store.geometry = g }
        guard !store.sessions.isEmpty else { panel?.orderOut(nil); return }
        let panel = self.panel ?? makePanel(store)
        panel.setFrame(store.geometry.frame(store.size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel(_ store: AgentIslandStore) -> AgentIslandPanel {
        let p = AgentIslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        // Above the menu bar (24) and status items, below menus (101).
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.onEscape = { [weak self] in self?.setExpanded(false) }
        let host = FirstClickHostingView(rootView: AgentIslandView(
            store: store,
            onToggle: { [weak self] in self?.setExpanded(!(self?.store?.expanded ?? true)) },
            onRow: { [weak self] in self?.jump($0) }))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    private func setExpanded(_ on: Bool) {
        guard let store, let panel, store.expanded != on else { return }
        store.expanded = on
        if !on { store.notices = [:] }
        panel.keyable = on
        layout()
        if on {
            panel.makeKey()
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    // macOS 27 reports clicks on our own windows here too: keep those.
                    guard let self, let f = self.panel?.frame, !f.contains(NSEvent.mouseLocation) else { return }
                    self.setExpanded(false)
                }
            }
        } else {
            if let m = outsideClick { NSEvent.removeMonitor(m) }
            outsideClick = nil
            // Hand key focus back: out and straight back in, no animation.
            if panel.isKeyWindow { panel.orderOut(nil); layout() }
        }
    }

    // MARK: - Jump

    private func jump(_ s: AgentSession) {
        guard let store else { return }
        let target = AgentIsland.jumpTarget(
            clients: AgentIsland.clientPIDs(s.key), info: AgentIsland.procInfo,
            isRegularApp: { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular },
            ourPID: getpid())
        switch target {
        case .app(let pid):
            setExpanded(false)
            raiseWindow(pid: pid, matching: [s.title, s.name])
            activate(pid)
        case .attachedElsewhere where store.notices[s.key] == nil:
            // Not jumpable; say so instead of silently copying. A second click copies.
            store.notices[s.key] = "Attached in tmux/ssh, click to copy attach command"
        case .attachedElsewhere, .notAttached:
            let pb = Pasteboard.general
            pb.clearContents()
            pb.setString(AgentIsland.attachCommand(s.key, defaultDir: DchCommand.defaultSocketDir), forType: .string)
            store.notices[s.key] = "Attach command copied"
        }
    }

    /// A non-activating panel's app is never active, and macOS 14+ cooperative
    /// activation ignores `activate()` from it; a Launch Services open does not.
    private func activate(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard let url = app.bundleURL else { app.activate(); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            if error != nil { DispatchQueue.main.async { app.activate() } }
        }
    }

    /// Best effort: terminals title windows after the program (Claude sets
    /// "✳ <task>"), so a miss just leaves the app's front window.
    private func raiseWindow(pid: pid_t, matching needles: [String]) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return }
        let lowered = needles.filter { !$0.isEmpty }.map { $0.lowercased() }
        for w in windows {
            var t: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success,
                  let title = (t as? String)?.lowercased(),
                  lowered.contains(where: title.contains) else { continue }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            return
        }
    }

    private func teardown() {
        timer?.cancel(); timer = nil
        if let m = outsideClick { NSEvent.removeMonitor(m) }
        outsideClick = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
        screenObserver = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        store = nil
    }
}
