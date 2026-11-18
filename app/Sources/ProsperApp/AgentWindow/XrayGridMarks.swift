import AppKit
import Combine
import GhosttyTerminal
import SwiftUI

// #1559 (X-T a, plan 905 phase A): ref marks on the Terminal grid. The window's focused, visible live local pane draws a
// dotted underline (the terminal's text colour at 0.6, spec 5.1's style) under each viewport span whose ref the
// session's follow lists with underline:true (XrayFollows.focus attaches it on pane focus; dch README v1.99.0
// "--follow": `ref` deltas turn underline on and off, count 0 removes). A url or file ref gets none: libghostty already
// links those (XrayRefSpans.key). The marks live in this overlay, a subview over the whole AgentTerminalHostView whose
// hitTest is nil: the grid, the pty size and the frame never change, every click reaches the terminal.
// Output clears the marks at once; a one-shot settle item, re-armed by each output, places them again. Never a timer.
// #1565 (X-T b, plan 905 phase B, spec 6.2): the overlay's own tracking area (no hitTest needed: AppKit sends a tracking
// area's moves to its owner) feeds XrayHover, the hover card's dwell, settle and close items. Moves, entries and exits
// stop here (never passed on: the terminal's own tracking area already has them).

@MainActor
final class XrayGridMarksView: NSView {
    struct Mark: Equatable {
        let row: Int
        let col: Int
        let cells: Int
        let key: String
    }

    /// The terminal under the overlay: its controller, grid and viewport text.
    weak var host: AgentTerminalHostView?
    private(set) var marks: [Mark] = []
    /// The pending settle; nil once it placed the marks.
    private(set) var settle: DispatchWorkItem?
    static let settleDelay: TimeInterval = 0.25
    /// Runs the settle item later (rows keep it and perform it by hand).
    var after: (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }
    /// The window is on screen, not minimized, some of it visible (rows answer for a window they never order in).
    var windowShown: @MainActor (NSWindow?) -> Bool = { w in
        w.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
    }
    /// The focused pane's follow (AgentTerminalController.followFocus); nil: no refs, no marks.
    var follow: XrayFollow? {
        didSet {
            guard follow !== oldValue else { return }
            sink = follow?.$state.sink { [weak self] s in self?.take(s?.refs) }   // @Published: the new value, now
            if follow == nil { take(nil); hover.close(all: true) }   // #1565: blur (another pane's focus) closes any card
        }
    }
    private(set) var refs: XrayRefs?
    private var sink: AnyCancellable?

    /// #1565: the hover card's state; its items run through `after`, its gate is hoverReady, its panel hoverPanel.
    let hover = XrayHover()
    /// #1565: the window is key (rows answer for a window they never make key).
    var windowKey: @MainActor (NSWindow?) -> Bool = { $0?.isKeyWindow == true }
    /// #1565: the mouse buttons down now (NSEvent.pressedMouseButtons; rows answer).
    var buttons: @MainActor () -> Int = { NSEvent.pressedMouseButtons }
    /// #1565: the window shows a card already (a pinned one, a Refs row's): no hover card over it.
    var cardShown: @MainActor (NSWindow?) -> Bool = { ($0 as? AgentsNSWindow)?.cards.isShown == true }
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        // #1565: active in the app, not the key window only: a shown popover may take key and the pointer still moves here
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
        hover.after = { [weak self] in self?.after($0, $1) }
        hover.onScreen = { [weak self] k in self?.marks.filter { $0.key == k }.count ?? 0 }   // #1567: the card's footer
        hover.ready = { [weak self] in self?.hoverReady() == true }
        hover.panel = { [weak self] in
            guard let self, let key = host?.owner?.key else { return nil }
            return XrayRefLink.hoverPanel(window as? AgentsNSWindow, key: key)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    /// Clicks, drags and the wheel go to the terminal under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The pty wrote: the text may have moved, so the marks go now and come back once output rests.
    /// #1565: output closes an unpinned hover card (a pinned one stays).
    func output() {
        hover.close(all: false)
        if !marks.isEmpty { marks = []; needsDisplay = true }
        settle?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.place() } }
        settle = item
        after(Self.settleDelay, item)
    }

    /// The follow's refs changed (a snapshot, a `ref` delta): placed now unless output is still settling.
    private func take(_ r: XrayRefs?) {
        refs = r
        if settle == nil { place() }
    }

    /// The marks for the viewport as it is now; none unless the pane shows them (`shown`).
    func place() {
        settle = nil
        let rows = host?.gridMetrics.map { Int($0.rows) } ?? 0
        let now = shown() ? Self.marks((host?.viewportText() ?? "").components(separatedBy: "\n"), refs?.entries ?? [], rows: rows) : []
        if now != marks { marks = now; needsDisplay = true }
    }

    /// Gate B on, a live local session in the window's focused pane, the pane and its window on screen.
    func shown() -> Bool {
        guard XrayRefLink.decorate(), let host, let owner = host.owner, owner.phase == .live, owner.remoteHost == nil,
              owner.paneFocused(), !host.isHiddenOrHasHiddenAncestor else { return false }
        return windowShown(host.window)
    }

    /// Each underlined, non-url, non-file ref's spans in the first `rows` viewport lines, in cells. Pure.
    static func marks(_ lines: [String], _ refs: [XrayRefs.Entry], rows: Int) -> [Mark] {
        let linked = refs.filter { $0.underline && $0.shape != .url && $0.shape != .file }
        guard !linked.isEmpty, rows > 0 else { return [] }
        return lines.prefix(rows).enumerated().flatMap { row, line in
            XrayRefSpans.find(line, linked).map {
                Mark(row: row, col: XrayRefSpans.cells(line[..<$0.range.lowerBound]), cells: XrayRefSpans.cells(line[$0.range]), key: $0.key)
            }
        }
    }

    /// #1565: the mark under a top-left point of this view, nil off the grid or off every mark.
    func mark(at p: CGPoint) -> Mark? {
        guard let g = host?.gridMetrics, let c = AgentTerminalHostView.cell(at: p, g, scale: window?.backingScaleFactor ?? 2) else { return nil }
        return marks.first { $0.row == c.row && c.col >= $0.col && c.col < $0.col + $0.cells }
    }

    /// #1565 (6.2): a dwell opens a card only on the window's focused pane (shown), its window key, no button down and
    /// no other card up.
    func hoverReady() -> Bool {
        shown() && windowKey(host?.window) && buttons() == 0 && !cardShown(host?.window)
    }

    // #1565: the pointer, from this view's tracking area only; never passed on (a plain click is never taken: hitTest nil)
    override func mouseMoved(with event: NSEvent) { hover.point(mark(at: convert(event.locationInWindow, from: nil))?.key) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hover.point(nil) }

    /// #1565: Esc in the terminal closes any card and kills its read. shortcut: AgentTerminalHostView's keyDown calls
    /// this once #1566 frees AgentTerminal.swift; until then the card's own Esc (onExitCommand) is the path.
    func escape() { hover.close(all: true) }

    /// #1565: pane hide closes any card.
    override func viewDidHide() {
        super.viewDidHide()
        hover.close(all: true)
    }

    /// #1565: window hide (miniaturize, close, ordered out) and focus loss (the window resigns main) close any card.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        guard let w = window else { return hover.close(all: true) }
        let gone: [Notification.Name] = [NSWindow.didResignMainNotification, NSWindow.didMiniaturizeNotification,
                                         NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification]
        observers = gone.map { name in
            let occlusion = name == NSWindow.didChangeOcclusionStateNotification
            return NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !occlusion || !self.windowShown(self.window) else { return }
                    self.hover.close(all: true)
                }
            }
        }
    }

    /// The text colour, faded as the Transcript's marks.
    static var color: NSColor { NSColor(Neon.textPrimary).withAlphaComponent(0.6) }

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty, let g = host?.gridMetrics, g.cellWidthPixels > 0, g.cellHeightPixels > 0 else { return }
        let scale = max(window?.backingScaleFactor ?? 2, 1)
        let w = CGFloat(g.cellWidthPixels) / scale, h = CGFloat(g.cellHeightPixels) / scale
        let o = AgentTerminalHostView.gridOrigin
        let path = NSBezierPath()
        for m in marks {
            let y = o.y + CGFloat(m.row + 1) * h - 1.5
            path.move(to: CGPoint(x: o.x + CGFloat(m.col) * w, y: y))
            path.line(to: CGPoint(x: o.x + CGFloat(m.col + m.cells) * w, y: y))
        }
        path.lineWidth = 1
        path.setLineDash([1, 2], count: 2, phase: 0)
        Self.color.setStroke()
        path.stroke()
    }
}

/// #1565 (X-T b, spec 6.2, 6.3): the hover card over the grid's marks. A 500 ms dwell on a mark opens an unpinned card
/// with the cached ref at once and one light read; a move to another mark switches at once (the old read killed, the
/// new light read after a one-shot 150 ms settle); 250 ms after the pointer left both the mark and the card it closes.
/// Pin kills the light read and opens today's full card (openRef). One-shot DispatchWorkItems through `after`, never a
/// timer; a card's close that comes after a newer card (generation `gen`) is not news.
@MainActor
final class XrayHover {
    static let dwellDelay: TimeInterval = 0.5
    static let settleDelay: TimeInterval = 0.15
    static let lingerDelay: TimeInterval = 0.25

    var after: (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }
    /// The focused pane, its key window, no button down, no other card (XrayGridMarksView.hoverReady).
    var ready: @MainActor () -> Bool = { false }
    /// The panel the card shows in and the pane's refs (XrayRefLink.hoverPanel); nil: no card.
    var panel: @MainActor () -> (panel: XrayPanelModel, refs: XrayRefs)? = { nil }
    /// #1567: the grid's marks of a ref key now (XrayGridMarksView.marks): the card's "N on screen".
    var onScreen: @MainActor (String) -> Int = { _ in 0 }

    /// The mark under the pointer.
    private(set) var over: String?
    /// The unpinned card's ref; nil: no hover card.
    private(set) var card: XrayRefs.Entry?
    /// The card's session is a live shell (XrayRefContext.shell): titles and counts only.
    private(set) var shell = false
    /// The card's light read, once started (killed by a switch, Pin, a close).
    private(set) var read: Task<Void, Never>?
    private(set) var dwell: DispatchWorkItem?
    private(set) var settle: DispatchWorkItem?
    private(set) var linger: DispatchWorkItem?
    /// The panel of the last card, pinned or not (Esc, blur and hide close its card too).
    private(set) weak var model: XrayPanelModel?
    private var onCard = false
    private var gen = 0

    private func arm(_ d: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        after(d, item)
        return item
    }

    /// The pointer is over mark `key` now (nil: no mark).
    func point(_ key: String?) {
        guard key != over else { return }
        over = key
        dwell?.cancel()
        dwell = nil
        guard let key else {
            if card != nil, !onCard, linger == nil { linger = arm(Self.lingerDelay) { [weak self] in self?.close(all: false) } }
            return
        }
        linger?.cancel()
        linger = nil
        if card != nil {
            guard key != card?.key else { return }
            show(key)   // a switch: the new card at once, its read after the settle
            settle = arm(Self.settleDelay) { [weak self] in
                guard let self, let e = self.card, e.key == key else { return }
                self.settle = nil
                self.read = self.model?.hoverRead(e)
            }
        } else {
            dwell = arm(Self.dwellDelay) { [weak self] in
                guard let self, self.over == key, self.card == nil else { return }
                self.dwell = nil
                guard self.ready() else { return }
                self.show(key)
                if let e = self.card { self.read = self.model?.hoverRead(e) }
            }
        }
    }

    /// The pointer entered (true) or left the card.
    func onCard(_ inside: Bool) {
        onCard = inside
        if inside {
            linger?.cancel()
            linger = nil
        } else if over == nil, card != nil, linger == nil {
            linger = arm(Self.lingerDelay) { [weak self] in self?.close(all: false) }
        }
    }

    /// Pin: the light read is killed (SIGTERM through the runner's cancel) and today's full card opens in its place.
    func pin() {
        guard let e = card, let m = model else { return }
        gen += 1   // the unpinned card's close, when openRef's present retires it, is not news
        m.panels?.closeRef(started: read)
        reset()
        m.openRef(e)
    }

    /// Closes the unpinned card and kills its read; `all`: any card of the panel (a pinned one too). Output: not all.
    func close(all: Bool) {
        dwell?.cancel()
        dwell = nil
        guard card != nil else {
            if all { model?.dismiss() }
            return
        }
        gen += 1
        model?.panels?.closeRef(started: read)
        reset()
        model?.dismiss()
    }

    private func show(_ key: String) {
        guard let p = panel(), let e = p.refs.entries.first(where: { $0.key == key }) else { return close(all: false) }
        model?.panels?.closeRef(started: read)   // a switch: the old card's read is killed now
        settle?.cancel()
        (settle, read) = (nil, nil)
        gen += 1
        let g = gen
        (card, model, shell) = (e, p.panel, XrayRefContext.shell(p.refs.sessionID))
        p.panel.hoverRef(e, hover: self) { [weak self] in self?.closed(g) }
    }

    /// The presenter closed card `g` (a click outside, its Esc, another card): its read goes with it.
    private func closed(_ g: Int) {
        guard g == gen else { return }
        model?.panels?.closeRef(started: read)
        reset()
    }

    private func reset() {
        for item in [settle, linger] { item?.cancel() }
        (card, read, settle, linger, onCard) = (nil, nil, nil, nil, false)
    }
}
