import AppKit
import Foundation

/// What a state-changing command did: the line the notice and the log show, the reply's result, and how to put it back.
struct ControlChange {
    var summary: String
    var result: ControlJSON = .bool(true)
    /// The notice reads "Agent <verb>: <summary>"; "changed" unless a change says otherwise (actions.run says "ran").
    var verb = "changed"
    /// nil = no known inverse: the notice has no Undo button and the log marks the entry not undoable.
    var undo: (@MainActor () -> Void)? = nil
    /// #2047: a message's session and the whole message (sessions.say, sessions.new's prompt, sessions.resume's message):
    /// the notice titles "<sender> → <target> (<verb>)" and shows the message below. nil: the one-line notice.
    var target: String? = nil
    var body: String? = nil
}

extension ControlCommand {
    /// #1808: the one helper every state-changing command goes through. It runs the change, records its inverse,
    /// shows the "Agent changed" notice with Undo and appends one line to the bounded log. The Settings switch is
    /// checked before `run` in ControlRegistry.reply (it covers every `mutates` command).
    static func change(name: String, summary: String, args: [String: ControlArg] = [:],
                       apply: @escaping @MainActor @Sendable (_ registry: ControlRegistry, _ args: [String: ControlJSON]) throws -> ControlChange) -> ControlCommand {
        ControlCommand(name: name, summary: summary, args: args, mutates: true) { reg, a in
            let c = try apply(reg, a)
            reg.changes.record(command: name, change: c, sender: reg.sender)
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
    static let summaryMax = 200
    /// #2047: a message in the notice: at most `bodyLines` lines (then "…") and `bodyMax` characters, each line cleaned.
    static let bodyMax = 1000
    static let bodyLines = 8
    static let offError = "agent control is off in Settings"

    struct Entry: Equatable {
        let id: Int
        let date: Date
        let command: String
        let summary: String
        /// #2047: the calling session's shown title (ControlSessions.sender); nil when not known.
        var sender: String? = nil
        var undone = false
        var undoable = true
    }

    private(set) var entries: [Entry] = []
    private var undos: [Int: @MainActor () -> Void] = [:]
    private var nextID = 0

    /// Seam: shows the notice (text, undo). The real panel, never under XCTest; rows swap in a recorder.
    var present: @MainActor (_ text: String, _ undo: (@MainActor () -> Void)?) -> Void = { text, undo in
        guard NSClassFromString("XCTestCase") == nil else { return }
        ControlNotice.shared.show(text, undo: undo)
    }

    /// "Agent <verb>: <summary>"; #2047: the sender's title in place of "Agent" when known.
    static func noticeText(_ summary: String, verb: String = "changed", sender: String? = nil) -> String {
        "\(sender ?? "Agent") \(verb): \(summary)"
    }

    /// #2047: "<sender> → <target> (<verb>)", then the message: every line cleaned of unseen scalars, at most `bodyLines`
    /// lines (a longer one ends with a "…" line) and `bodyMax` characters. `sender` and `target` come cleaned.
    static func messageText(_ body: String, target: String, verb: String, sender: String?) -> String {
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var shown = lines.prefix(bodyLines).map { OutsideText.shown(String($0), max: bodyMax) }.joined(separator: "\n")
        if lines.count > bodyLines { shown += "\n…" }
        if shown.count > bodyMax { shown = String(shown.prefix(bodyMax - 1)) + "…" }
        return "\(sender ?? "Agent") → \(target) (\(verb))\n\(shown)"
    }

    /// #2047: a change as made, with its message for the notice and the calling session's title.
    @discardableResult
    func record(command: String, change c: ControlChange, sender: String?) -> Entry {
        record(command: command, summary: c.summary, verb: c.verb, undo: c.undo, sender: sender, target: c.target, body: c.body)
    }

    @discardableResult
    func record(command: String, summary: String, verb: String = "changed", undo: (@MainActor () -> Void)? = nil,
                sender: String? = nil, target: String? = nil, body: String? = nil) -> Entry {
        nextID += 1
        // QA n123: a summary can carry agent text; clean it once here so the notice and `ctl log` never show bidi or control
        // characters or a line that pushes the real action out of view.
        let summary = OutsideText.shown(summary, max: Self.summaryMax)
        let sender = sender.map { OutsideText.shown($0, max: 64) }
        let e = Entry(id: nextID, date: Date(), command: command, summary: summary, sender: sender, undoable: undo != nil)
        entries.append(e)
        undos[e.id] = undo
        if entries.count > Self.capacity {
            for old in entries.prefix(entries.count - Self.capacity) { undos[old.id] = nil }
            entries.removeFirst(entries.count - Self.capacity)
        }
        let id = e.id
        var click: (@MainActor () -> Void)?
        if undo != nil { click = { [weak self] in _ = self?.undo(id) } }
        if let body, let target, !body.isEmpty {
            present(Self.messageText(body, target: OutsideText.shown(target, max: 64), verb: verb, sender: sender), click)
        } else {
            present(Self.noticeText(summary, verb: verb, sender: sender), click)
        }
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

    /// `ctl log`: {"changes": [{id, time, command, summary, sender?, undone, undoable}, ...]}, oldest first.
    var logJSON: ControlJSON {
        let f = ISO8601DateFormatter()
        return .object(["changes": .array(entries.map {
            var o: [String: ControlJSON] = ["id": .number(Double($0.id)), "time": .string(f.string(from: $0.date)),
                                            "command": .string($0.command), "summary": .string($0.summary),
                                            "undone": .bool($0.undone), "undoable": .bool($0.undoable)]
            if let s = $0.sender { o["sender"] = .string(s) }
            return .object(o)
        })])
    }
}

/// #1808: the small "Agent changed: ..." notice with an Undo button. A borderless non-activating panel that can never
/// become key or main, so it never takes focus; it hides itself after `seconds(for:)` (#2047: the pointer over it holds
/// it). One notice at a time.
@MainActor
final class ControlNotice: NSObject {
    static let shared = ControlNotice()
    static let visibleSeconds: TimeInterval = 6
    /// #2047: a longer notice stays up longer, `charsPerSecond` of reading time, never past `maxSeconds`.
    static let maxSeconds: TimeInterval = 12
    static let charsPerSecond = 20.0

    static func seconds(for text: String) -> TimeInterval {
        min(maxSeconds, max(visibleSeconds, Double(text.count) / charsPerSecond))
    }

    /// #2057: draws only inside its own bounds (a combining mark can rise above the line box).
    private final class ClippedField: NSTextField {
        override func draw(_ dirtyRect: NSRect) {
            bounds.clip()
            super.draw(dirtyRect)
        }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var panel: NSPanel?
    private var label: NSTextField?
    private var body: NSTextField?
    private var undoButton: NSButton?
    private var hide: DispatchWorkItem?
    private var pendingUndo: (@MainActor () -> Void)?
    private var shownFor = ControlNotice.visibleSeconds
    private var hovered = false

    func show(_ text: String, undo: (@MainActor () -> Void)?) {
        let p = panel ?? makePanel()
        panel = p
        pendingUndo = undo
        undoButton?.isHidden = undo == nil
        let size = layout(text)
        if let f = NSScreen.main?.visibleFrame {
            p.setFrame(NSRect(x: f.maxX - size.width - 16, y: f.maxY - size.height - 16, width: size.width, height: size.height), display: false)
        }
        p.orderFrontRegardless()
        shownFor = Self.seconds(for: text)
        if !hovered { scheduleHide() }
    }

    /// #2057: the title is its own one-line field above the message's field, which clips to its own bounds, so a combining
    /// mark rising above the message's first line never draws over the title. Sets both fields' text and frames;
    /// returns the panel's size. A one-line notice is the title field alone.
    @discardableResult
    func layout(_ text: String) -> NSSize {
        // #2047: a message notice (a title line, then the message) is wider and as tall as its wrapped text.
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let multi = parts.count > 1
        label?.stringValue = multi ? String(parts[0]) : text
        body?.stringValue = multi ? String(parts[1]) : ""
        body?.isHidden = !multi
        let w: CGFloat = multi ? 420 : 360, textW = w - 14 - 88
        let lineH = ceil(label?.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 16)
        // Wrapped, at most `bodyLines` and the "…" line high; past that the last shown line ends in "…".
        let lines = ControlChanges.bodyLines + 1
        body?.maximumNumberOfLines = lines
        let fit = body?.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 2000)).height ?? 20
        let bodyH = multi ? ceil(min(fit, lineH * CGFloat(lines))) : 0
        let titleH = multi ? lineH : 20
        let h = max(48, titleH + bodyH + 28)
        label?.frame = NSRect(x: 14, y: 14 + bodyH, width: textW, height: titleH)
        body?.frame = NSRect(x: 14, y: 14, width: textW, height: bodyH)
        return NSSize(width: w, height: h)
    }

    /// The title field's frame in the panel's content (the row pins the title rect by it).
    var titleFrame: NSRect { label?.frame ?? .zero }

    private func scheduleHide() {
        hide?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + shownFor, execute: item)
    }

    /// #2047: the pointer over the notice holds it; leaving starts its time again. The panel's tracking area calls these.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        hovered = true
        hide?.cancel()
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        hovered = false
        if panel?.isVisible == true { scheduleHide() }
    }

    @objc private func undoClicked() {
        let u = pendingUndo
        dismiss()
        u?()
    }

    private func dismiss() {
        hide?.cancel()
        hide = nil
        hovered = false
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
        bg.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self, userInfo: nil))
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.textColor = .white
        text.frame = NSRect(x: 14, y: 14, width: 260, height: 20)
        let msg = ClippedField(labelWithString: "")
        msg.lineBreakMode = .byWordWrapping
        msg.cell?.truncatesLastVisibleLine = true   // #2047: a wrapped message past its lines ends in "…"
        msg.textColor = .white
        msg.isHidden = true
        let button = NSButton(title: "Undo", target: self, action: #selector(undoClicked))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 280, y: 10, width: 68, height: 28)
        button.autoresizingMask = [.minXMargin]
        bg.addSubview(text)
        bg.addSubview(msg)
        bg.addSubview(button)
        p.contentView?.addSubview(bg)
        label = text
        body = msg
        undoButton = button
        return p
    }
}
