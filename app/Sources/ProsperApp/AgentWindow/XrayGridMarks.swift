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
            if follow == nil { take(nil) }
        }
    }
    private(set) var refs: XrayRefs?
    private var sink: AnyCancellable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    /// Clicks, drags and the wheel go to the terminal under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The pty wrote: the text may have moved, so the marks go now and come back once output rests.
    func output() {
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
