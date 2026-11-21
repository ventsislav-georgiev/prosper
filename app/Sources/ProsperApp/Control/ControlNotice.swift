import AppKit
import Foundation

/// What a state-changing command did: the line the notice and the log show, the reply's result, and how to put it back.
struct ControlChange {
    var summary: String
    var result: ControlJSON = .bool(true)
    var undo: @MainActor () -> Void
}

extension ControlCommand {
    /// #1808: the one helper every state-changing command goes through. It runs the change, records its inverse,
    /// shows the "Agent changed" notice with Undo and appends one line to the bounded log. The Settings switch is
    /// checked before `run` in ControlRegistry.reply (it covers every `mutates` command).
    static func change(name: String, summary: String, args: [String: ControlArg] = [:],
                       apply: @escaping @MainActor @Sendable (_ registry: ControlRegistry, _ args: [String: ControlJSON]) throws -> ControlChange) -> ControlCommand {
        ControlCommand(name: name, summary: summary, args: args, mutates: true) { reg, a in
            let c = try apply(reg, a)
            reg.changes.record(command: name, summary: c.summary, undo: c.undo)
            return c.result
        }
    }
}

/// #1808: the agent-change log (last `capacity` changes, in memory) and their pending undos.
/// shortcut: the log does not survive a relaunch, persist it if `ctl log` ever needs history across launches.
@MainActor
final class ControlChanges {
    nonisolated static let shared = ControlChanges()
    nonisolated init() {}

    static let capacity = 100
    static let offError = "agent control is off in Settings"

    struct Entry: Equatable {
        let id: Int
        let date: Date
        let command: String
        let summary: String
        var undone = false
    }

    private(set) var entries: [Entry] = []
    private var undos: [Int: @MainActor () -> Void] = [:]
    private var nextID = 0

    /// Seam: shows the notice (text, undo). The real panel, never under XCTest; rows swap in a recorder.
    var present: @MainActor (_ text: String, _ undo: @escaping @MainActor () -> Void) -> Void = { text, undo in
        guard NSClassFromString("XCTestCase") == nil else { return }
        ControlNotice.shared.show(text, undo: undo)
    }

    static func noticeText(_ summary: String) -> String { "Agent changed: \(summary)" }

    @discardableResult
    func record(command: String, summary: String, undo: @escaping @MainActor () -> Void) -> Entry {
        nextID += 1
        let e = Entry(id: nextID, date: Date(), command: command, summary: summary)
        entries.append(e)
        undos[e.id] = undo
        if entries.count > Self.capacity {
            for old in entries.prefix(entries.count - Self.capacity) { undos[old.id] = nil }
            entries.removeFirst(entries.count - Self.capacity)
        }
        let id = e.id
        present(Self.noticeText(summary)) { [weak self] in _ = self?.undo(id) }
        return e
    }

    /// Run the inverse of change `id` once. False when it already ran or fell out of the log.
    @discardableResult
    func undo(_ id: Int) -> Bool {
        guard let u = undos.removeValue(forKey: id) else { return false }
        u()
        if let i = entries.lastIndex(where: { $0.id == id }) { entries[i].undone = true }
        return true
    }

    /// `ctl log`: {"changes": [{id, time, command, summary, undone}, ...]}, oldest first.
    var logJSON: ControlJSON {
        let f = ISO8601DateFormatter()
        return .object(["changes": .array(entries.map {
            .object(["id": .number(Double($0.id)), "time": .string(f.string(from: $0.date)), "command": .string($0.command),
                     "summary": .string($0.summary), "undone": .bool($0.undone)])
        })])
    }
}

/// #1808: the small "Agent changed: ..." notice with an Undo button. A borderless non-activating panel that can never
/// become key or main, so it never takes focus; it hides itself after `visibleSeconds`. One notice at a time.
@MainActor
final class ControlNotice: NSObject {
    static let shared = ControlNotice()
    static let visibleSeconds: TimeInterval = 6

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hide: DispatchWorkItem?
    private var pendingUndo: (@MainActor () -> Void)?

    func show(_ text: String, undo: @escaping @MainActor () -> Void) {
        let p = panel ?? makePanel()
        panel = p
        pendingUndo = undo
        label?.stringValue = text
        let w: CGFloat = 360, h: CGFloat = 48
        if let f = NSScreen.main?.visibleFrame {
            p.setFrame(NSRect(x: f.maxX - w - 16, y: f.maxY - h - 16, width: w, height: h), display: true)
        }
        p.orderFrontRegardless()
        hide?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleSeconds, execute: item)
    }

    @objc private func undoClicked() {
        let u = pendingUndo
        dismiss()
        u?()
    }

    private func dismiss() {
        hide?.cancel()
        hide = nil
        pendingUndo = nil
        panel?.orderOut(nil)
    }

    /// Built, never shown, by the row that checks the panel cannot take focus.
    func makePanel() -> NSPanel {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 48),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isExcludedFromWindowsMenu = true
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        let bg = NSVisualEffectView(frame: p.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.textColor = .white
        text.frame = NSRect(x: 14, y: 14, width: 260, height: 20)
        text.autoresizingMask = [.width]
        let button = NSButton(title: "Undo", target: self, action: #selector(undoClicked))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 280, y: 10, width: 68, height: 28)
        button.autoresizingMask = [.minXMargin]
        bg.addSubview(text)
        bg.addSubview(button)
        p.contentView?.addSubview(bg)
        label = text
        return p
    }
}
