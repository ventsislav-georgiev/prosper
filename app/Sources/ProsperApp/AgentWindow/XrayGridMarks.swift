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
// Output takes off at once only the marks whose cells no longer hold their text (#1628: a spinner or status-line redraw
// elsewhere used to flip every mark off and on); a one-shot settle item, re-armed by each output, places them again.
// A resize takes them all off. Never a timer.
// #1565 (X-T b, plan 905 phase B): the overlay's own tracking area (no hitTest needed: AppKit sends a tracking area's
// moves to its owner) keeps the pointer for #1724's link underline. Moves, entries and exits stop here (never passed on:
// the terminal's own tracking area already has them). #1926/#1931: no hover card; a mark's card opens on a Command-click.
// #1568 (X-R a, plan 905 phase G): a remote pane too, its follow keyed "host:name".
// #1569 (X7 c, 5.1 exception): a live extension rule with a handler marks its spans too when one key has 2 or more on the
// grid; its card calls the handler on the extension's lane (XrayExtensionCalls), never dch.
// #1655: place() only snapshots on main (lines, refs, rules); marks() and extMarks() run on a serial utility queue
// through a per-line memo (XrayMarksMemo, the refs prepared once per refs change) and the result is applied on main only
// if no output, refs change or newer place() came in meanwhile (`generation`). A focus switch costs the snapshot.
// #1952: a command block ("! cmd" / "$ cmd", XrayGridMarksView.commandBlock) under the pointer shows a Copy pill pinned to
// the pane's right edge on the block's first row, only while the grid is settled (`settle` nil); output, a scroll, a resize,
// a focus change and the pointer leaving hide it at once, and the next move after the settle shows it again. One viewport
// read per row the pointer enters (`commandReads`), never per move. Only the pill's rect takes clicks (hitTest).

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
    /// #1628: the viewport lines the marks were placed on (each mark's text is its span here).
    private var placedOn: [String] = []
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
            if follow == nil { take(nil); hover.close() }   // #1565: blur (another pane's focus) closes any card
            hideCommand()   // #1952: a focus change
        }
    }
    private(set) var refs: XrayRefs?
    private var sink: AnyCancellable?
    /// #1569: the live xref rules (ExtensionRegistry.xrefRules; rows answer).
    var rules: @MainActor () -> [XrayExtensionRule] = { SettingsHooks.shared.extensionRegistry?.xrefRules ?? [] }
    /// #1569: each extension mark's match, by key.
    private(set) var extMatches: [String: XrayExtensionRefs.Match] = [:]

    /// #1655: the compute's queue, and its memo (touched only inside `hop`'s work).
    nonisolated static let queue = DispatchQueue(label: "eu.illegible.prosper.xray-marks", qos: .utility)
    let memo = XrayMarksMemo()
    /// #1655: bumped by output, a refs change and each place; a result of an older one is dropped.
    private(set) var generation = 0
    /// #1655: bumped by each refs change; the memo prepares the refs again and drops its lines when it moves.
    private var refsVersion = 0
    struct Placed: Sendable {
        let dch: [Mark]
        let ext: [(mark: Mark, match: XrayExtensionRefs.Match)]
    }
    /// #1655: runs `work` on `queue`, then `apply` with its result on main (rows run both inline, or keep them).
    var hop: (@escaping @Sendable () -> Placed, @escaping @MainActor @Sendable (Placed) -> Void) -> Void = { work, apply in
        XrayGridMarksView.queue.async {
            let p = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { apply(p) } }
        }
    }

    /// #1565: the marks' card (a Command-click's); its panel hoverPanel.
    let hover = XrayHover()
    /// #1565: the window shows a card (Esc closes it only then).
    var cardShown: @MainActor (NSWindow?) -> Bool = { ($0 as? AgentsNSWindow)?.cards.isShown == true }
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        // #1565: active in the app, not the key window only: a shown popover may take key and the pointer still moves here
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
        hover.ext = { [weak self] k in self?.extMatches[k] }   // #1569
        hover.calls = { [weak self] in XrayExtensionCalls.of(self?.window) }
        hover.panel = { [weak self] in
            guard let self, let key = host?.owner?.key else { return nil }
            return XrayRefLink.hoverPanel(window as? AgentsNSWindow, key: key)
        }
        pill.copy.target = self   // #1952
        pill.copy.action = #selector(copyCommand)
        addSubview(pill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    /// Clicks, drags and the wheel go to the terminal under it; #1952: but those in the shown command pill's rect.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !pill.isHidden, pill.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    /// The pty wrote: a mark whose cells changed (or moved: a scroll) goes now, the rest stay; all are placed again once
    /// output rests. `resized`: the grid's cells changed, every mark goes.
    func output(resized: Bool = false) {
        hideCommand()   // #1952: shown only while the grid is settled
        // #1724: the text under a Command hover may have changed: one re-read per drain, only while one is on the grid
        if link != nil || linkCell != nil { linkCell = nil; linkHover(pointer) }
        // #1628: one viewport read per drain, only while marks are drawn (drains are coalesced, one per main-loop turn)
        let lines = resized || marks.isEmpty || !shown() ? [] : (host?.viewportText() ?? "").components(separatedBy: "\n")
        let kept = marks.filter { m in
            guard m.row < lines.count, m.row < placedOn.count, let was = Self.span(placedOn[m.row], m) else { return false }
            return Self.span(lines[m.row], m) == was
        }
        if kept != marks { marks = kept; needsDisplay = true }
        extMatches = extMatches.filter { k, _ in kept.contains { $0.key == k } }
        generation += 1   // #1655: a compute in flight read the old text
        settle?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.place() } }
        settle = item
        after(Self.settleDelay, item)
    }

    /// The follow's refs changed (a snapshot, a `ref` delta): placed now unless output is still settling.
    private func take(_ r: XrayRefs?) {
        refs = r
        refsVersion += 1
        generation += 1   // #1655: a compute in flight read the old refs
        if settle == nil { place() }
    }

    /// The marks for the viewport as it is now; none unless the pane shows them (`shown`).
    /// #1655: on main only the snapshot; the spans are found on `queue` and applied if still the newest request.
    func place() {
        settle = nil
        generation += 1
        let g = generation
        let rows = host?.gridMetrics.map { Int($0.rows) } ?? 0
        let lines = shown() ? (host?.viewportText() ?? "").components(separatedBy: "\n") : []
        guard !lines.isEmpty else { return apply(Placed(dch: [], ext: []), lines) }   // not shown: none, at once
        let (entries, version, rules, memo) = (refs?.entries ?? [], refsVersion, self.rules(), self.memo)
        hop({
            let dch = memo.marks(lines, entries, version: version, rows: rows)
            return Placed(dch: dch, ext: XrayGridMarksView.extMarks(lines, rules, rows: rows, taken: dch))   // #1569
        }, { [weak self] p in
            guard let self, g == self.generation else { return }   // a newer output, refs change or place came in
            self.apply(p, lines)
        })
    }

    private func apply(_ p: Placed, _ lines: [String]) {
        extMatches = Dictionary(p.ext.map { ($0.mark.key, $0.match) }, uniquingKeysWith: { a, _ in a })
        let now = p.dch + p.ext.map(\.mark)
        placedOn = lines
        if now != marks { marks = now; needsDisplay = true }
    }

    /// Gate B on, a live session in the window's focused pane (#1568: a remote one too), the pane and its window on screen.
    func shown() -> Bool {
        guard XrayRefLink.decorate(), let host, let owner = host.owner, owner.phase == .live,
              owner.paneFocused(), !host.isHiddenOrHasHiddenAncestor else { return false }
        return windowShown(host.window)
    }

    /// Each underlined, non-url, non-file ref's spans in the first `rows` viewport lines, in cells. Pure.
    /// #1655: through a fresh XrayMarksMemo (place() keeps one).
    nonisolated static func marks(_ lines: [String], _ refs: [XrayRefs.Entry], rows: Int) -> [Mark] {
        XrayMarksMemo().marks(lines, refs, version: 0, rows: rows)
    }

    /// #1628: the text in cells `m.col ..< m.col + m.cells` of a line; nil when the line is shorter or a wide character
    /// straddles either edge. Pure.
    static func span(_ line: String, _ m: Mark) -> Substring? {
        var (n, i, lo) = (0, line.startIndex, String.Index?.none)
        while true {
            if n == m.col { lo = i }
            if n == m.col + m.cells { return lo.map { line[$0..<i] } }
            guard i < line.endIndex, n < m.col + m.cells else { return nil }
            n += XrayRefSpans.cells(line[i...i])
            i = line.index(after: i)
        }
    }

    /// #1569 (5.1 exception): each handler rule's spans in the first `rows` lines, in rule order. A span over a dch mark
    /// or over a span an earlier rule kept is dropped (first rule wins); then a key with fewer than 2 spans is. Pure.
    nonisolated static func extMarks(_ lines: [String], _ rules: [XrayExtensionRule], rows: Int,
                         taken: [Mark]) -> [(mark: Mark, match: XrayExtensionRefs.Match)] {
        guard rows > 0 else { return [] }
        var out: [(mark: Mark, match: XrayExtensionRefs.Match)] = []
        for rule in rules where rule.handler != nil {
            var mine: [(mark: Mark, match: XrayExtensionRefs.Match)] = []
            for (row, line) in lines.prefix(rows).enumerated() {
                for m in XrayExtensionRefs.matches(of: rule, in: line) {
                    let mark = Mark(row: row, col: XrayRefSpans.cells(line[..<m.range.lowerBound]), cells: XrayRefSpans.cells(line[m.range]),
                                    key: XrayExtensionRefs.key(m))
                    let over = (taken + out.map(\.mark)).contains {
                        $0.row == row && $0.col < mark.col + mark.cells && mark.col < $0.col + $0.cells
                    }
                    if !over { mine.append((mark, m)) }
                }
            }
            let n = Dictionary(mine.map { ($0.mark.key, 1) }, uniquingKeysWith: +)
            out += mine.filter { n[$0.mark.key, default: 0] >= 2 }
        }
        return out
    }

    /// #1565: the mark under a top-left point of this view, nil off the grid or off every mark.
    func mark(at p: CGPoint) -> Mark? {
        guard let c = host?.gridCell(at: p) else { return nil }   // #1701: the cell rule Cmd-click uses (#1682)
        return marks.first { $0.row == c.row && c.col >= $0.col && c.col < $0.col + $0.cells }
    }

    // #1565: the pointer, from this view's tracking area only; never passed on (a plain click is never taken: hitTest nil)
    // #1926 (operator 2026-11-24): no hover card: a mark's card opens on a Command-click only (AgentTerminalHostView.mouseDown);
    // the pointer is kept for #1724's link underline, drawn only while Command is held
    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        command(event.modifierFlags.contains(.command))
        commandHover(pointer)
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        pointer = nil
        linkHover(nil)
        hideCommand()
    }

    /// #1701: the pointer's last point over this view (top-left); nil once it left.
    private(set) var pointer: CGPoint?

    /// Command is down (the move's flags, or the host's flagsChanged): the link under the pointer is underlined (#1724),
    /// nothing else (#1926: no card opens on a hold).
    func command(_ down: Bool) {
        linkHover(down ? pointer : nil)
    }

    /// #1724: the link under the Command pointer while the program reports the mouse (AgentTerminalHostView.capturedLink),
    /// drawn with a solid underline; nil: none.
    private(set) var link: Mark?
    /// The cell `link` was read for: a move inside the same cell reads no viewport text.
    private var linkCell: (col: Int, row: Int)?

    private func linkHover(_ p: CGPoint?) {
        let c = p.flatMap { host?.gridCell(at: $0) }
        if let c, let l = linkCell, c == l { return }
        linkCell = c
        let now = p.flatMap { host?.capturedLink(at: $0) }.map { Mark(row: c?.row ?? 0, col: $0.col, cells: $0.cells, key: $0.text) }
        if now != link { link = now; needsDisplay = true }
    }

    /// #1565: Esc in the terminal closes the card and kills its read. #1568: AgentTerminalHostView.keyDown calls it; false
    /// (no card of the marks' panel up) leaves the Esc to the pty.
    @discardableResult
    func escape() -> Bool {
        guard hover.model != nil && cardShown(window) else { return false }
        hover.close()
        return true
    }

    /// #1565: pane hide closes any card.
    override func viewDidHide() {
        super.viewDidHide()
        hover.close()
        hideCommand()
    }

    /// #1565: window hide (miniaturize, close, ordered out) and focus loss (the window resigns main) close any card.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        guard let w = window else { return hover.close() }
        let gone: [Notification.Name] = [NSWindow.didResignMainNotification, NSWindow.didMiniaturizeNotification,
                                         NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification]
        observers = gone.map { name in
            let occlusion = name == NSWindow.didChangeOcclusionStateNotification
            return NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !occlusion || !self.windowShown(self.window) else { return }
                    self.hover.close()
                    self.hideCommand()   // #1952
                }
            }
        }
    }

    // MARK: #1952: the command pill

    /// A command block: its first row and its text as one line, without the "! " / "$ "; #1954: its last row and the
    /// head's "!"/"$" column (the pointer corridor's rows and left edge).
    struct HoverCommand: Equatable {
        let row: Int
        let text: String
        let last: Int
        let col: Int
    }
    /// The block under the pointer while its pill shows; nil: none.
    private(set) var hoveredCommand: HoverCommand?
    /// The row `hoveredCommand` was read for: a move inside the same row reads no viewport text.
    private var commandRow: Int?
    /// Rows count the work: viewport reads for the pill (one per row the pointer enters while settled).
    private(set) var commandReads = 0
    /// #1954: while the pill shows, a move inside this rect (the block's rows plus one above and one below, from its left
    /// column to the right edge) keeps it and reads nothing; .null: none.
    private(set) var commandCorridor = CGRect.null
    let pill = XrayCommandPill()

    /// A live local session in the window's focused pane, the pane and its window on screen (Gate B plays no part).
    func commandsShown() -> Bool {
        guard let host, let owner = host.owner, owner.phase == .live, owner.remoteHost == nil, owner.paneFocused(),
              !host.isHiddenOrHasHiddenAncestor else { return false }
        return windowShown(host.window)
    }

    /// The pointer moved to top-left point `p`: the pill for the block under it, read once per row entered.
    func commandHover(_ p: CGPoint?) {
        if let p, !pill.isHidden, pill.frame.contains(p) { return }   // on the pill: keep it (it may sit past the grid)
        if let p, !pill.isHidden, commandCorridor.contains(p), settle == nil, commandsShown() { return }   // #1954: on the way
        guard settle == nil, let p, commandsShown(), let g = host?.gridMetrics, let c = host?.gridCell(at: p) else {
            return hideCommand()
        }
        if c.row == commandRow { return }
        commandRow = c.row
        commandReads += 1
        let lines = (host?.viewportText() ?? "").components(separatedBy: "\n")
        hoveredCommand = Self.commandBlock(lines, at: c.row, cols: Int(g.columns))
        guard let cmd = hoveredCommand, g.cellHeightPixels > 0 else {
            pill.isHidden = true
            return
        }
        let scale = max(window?.backingScaleFactor ?? 2, 1), h = CGFloat(g.cellHeightPixels) / scale
        let o = AgentTerminalHostView.gridOrigin, head = o.y + CGFloat(cmd.row) * h
        // #1954: 2 pt above and below the head row, kept inside the overlay
        let ph = min(h + 4, bounds.height), w = max(2 * ph, 24)
        pill.frame = CGRect(x: bounds.width - w - 4, y: min(max(head - 2, 0), bounds.height - ph), width: w, height: ph)
        let left = o.x + CGFloat(cmd.col) * CGFloat(g.cellWidthPixels) / scale
        // a slack row that is itself another command's row stays out (QA R1954 f1: Copy would write the wrong one)
        let cols = Int(g.columns)
        let above = Self.commandBlock(lines, at: cmd.row - 1, cols: cols) == nil ? 1 : 0
        let below = Self.commandBlock(lines, at: cmd.last + 1, cols: cols) == nil ? 1 : 0
        commandCorridor = CGRect(x: left, y: head - CGFloat(above) * h, width: bounds.width - left,
                                 height: CGFloat(cmd.last - cmd.row + 1 + above + below) * h)
        pill.isHidden = false
    }

    /// The pill goes and the next move reads again.
    func hideCommand() {
        commandRow = nil
        hoveredCommand = nil
        commandCorridor = .null
        if !pill.isHidden { pill.isHidden = true }
    }

    /// Copy: the command on the host's pasteboard (tests hand a private one), then "Copied" in the pane.
    @objc func copyCommand() {
        guard let text = hoveredCommand?.text, let host else { return }
        let pb = host.pasteboard()
        pb.clearContents()
        pb.setString(text, forType: .string)
        host.owner?.show(Self.copiedText)
    }
    static let copiedText = "Copied"

    /// The command block row `row` is in: a head row whose text (after its indent and a Claude Code ⏺/● marker) starts
    /// with "! " or "$ ", then the rows under it indented at least as far and not at column 0 (Claude Code's hard wrap),
    /// up to a blank, marker or other head row; joined as one line (`joined`) without the "! " / "$ ". Nil for any other
    /// row, or past `cap` rows above it. Reads only the rows from the head to the block's end. Pure.
    /// shortcut: a column-0 head takes no continuation (a shell's output follows it), and output indented under an
    /// indented "$ " joins it; upgrade to the wrap width (the phone's oneLine fill rule) if that copies too much.
    nonisolated static func commandBlock(_ lines: [String], at row: Int, cols: Int, cap: Int = 12) -> HoverCommand? {
        func indent(_ i: Int) -> Int { lines[i].prefix(while: \.isWhitespace).count }
        func body(_ i: Int) -> Substring { lines[i].drop(while: \.isWhitespace) }
        func cont(_ i: Int) -> Bool { body(i).first.map { !"⏺●⎿│╭╰".contains($0) } ?? false }
        /// The head's "!"/"$" column, its marker dropped; nil: not a head.
        func head(_ i: Int) -> Int? {
            var b = body(i), col = indent(i)
            if let f = b.first, "⏺●".contains(f) { b = b.dropFirst(); col += 1 + b.prefix(while: { $0 == " " }).count; b = b.drop(while: { $0 == " " }) }
            guard b.hasPrefix("! ") || b.hasPrefix("$ "), b.dropFirst(2).contains(where: { !$0.isWhitespace }) else { return nil }
            return col
        }
        guard lines.indices.contains(row) else { return nil }
        var top = row
        while head(top) == nil {
            guard top > 0, row - top < cap, cont(top) else { return nil }
            top -= 1
        }
        guard let col = head(top) else { return nil }
        var bottom = top
        while col > 0, bottom + 1 < lines.count, bottom - top < cap, cont(bottom + 1), head(bottom + 1) == nil,
              indent(bottom + 1) >= col {
            bottom += 1
        }
        guard row <= bottom else { return nil }
        // the head's marker and "! " turn into spaces, so a full head row still counts as full (the phone's rule)
        var first = lines[top]
        first = String(repeating: " ", count: col + 2) + first.dropFirst(col + 2)
        let text = joined([first] + lines[(top + 1)..<(bottom + 1)], cols: cols)
        return text.isEmpty ? nil : HoverCommand(row: top, text: text, last: bottom, col: col)
    }

    /// Wrapped rows as the one line they were (prosper-ios TerminalMath.oneLine, cols only): each row trimmed, joined with
    /// " "; with "" when the row above filled `cols` and its last token plus this row's first would not fit its wrap box
    /// (a long token split mid-way); a trailing " \\" drops the backslash. Pure.
    nonisolated static func joined(_ rows: [String], cols: Int) -> String {
        var out = "", full: (tail: Int, box: Int)?
        for row in rows {
            let right = String(row.reversed().drop(while: \.isWhitespace).reversed()), line = right.drop(while: \.isWhitespace)
            guard !line.isEmpty else { continue }
            if !out.isEmpty {
                let head = line.prefix(while: { !$0.isWhitespace }).count
                out += full.map { $0.tail + head > $0.box } == true ? "" : " "
            }
            out += line
            full = nil
            if right.hasSuffix(" \\") {
                out.removeLast()
                while out.last?.isWhitespace == true { out.removeLast() }
                continue
            }
            if cols > 0, right.count % cols == 0 {
                full = (right.reversed().prefix(while: { !$0.isWhitespace }).count, cols - (right.count - line.count))
            }
        }
        return out
    }

    /// The text colour, faded as the Transcript's marks.
    static var color: NSColor { NSColor(Neon.textPrimary).withAlphaComponent(0.6) }

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty || link != nil, let g = host?.gridMetrics, g.cellWidthPixels > 0, g.cellHeightPixels > 0 else { return }
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
        if let l = link {   // #1724: solid, as libghostty's own link underline
            let y = o.y + CGFloat(l.row + 1) * h - 1.5
            NSBezierPath.strokeLine(from: CGPoint(x: o.x + CGFloat(l.col) * w, y: y), to: CGPoint(x: o.x + CGFloat(l.col + l.cells) * w, y: y))
        }
    }
}

/// #1655: the grid marks' memo, touched only on XrayGridMarksView.queue (rows: inline on main): the refs prepared once
/// for the refs version it was built for, and each line's spans in cells. Bounded: past twice the rows it starts over.
final class XrayMarksMemo: @unchecked Sendable {
    struct Cut {
        let col: Int
        let cells: Int
        let key: String
    }
    private var version: Int?
    private var linked: [XrayRefs.Entry] = []
    private var prepared = XrayRefSpans.Prepared(refs: [])
    private var lines: [String: [Cut]] = [:]
    /// Rows count the work: refs prepared, lines found in the memo, lines scanned, and range(of:) scans.
    private(set) var prepares = 0
    private(set) var hits = 0
    private(set) var misses = 0
    private(set) var scans = 0

    /// Each underlined, non-url, non-file ref's spans in the first `rows` lines, in cells; `version` moves when refs do.
    func marks(_ lines: [String], _ refs: [XrayRefs.Entry], version v: Int, rows: Int) -> [XrayGridMarksView.Mark] {
        if v != version {
            (version, linked, self.lines) = (v, refs.filter { $0.shape != .url && $0.shape != .file }, [:])
            prepare()
        }
        guard !prepared.refs.isEmpty, rows > 0 else { return [] }
        return lines.prefix(rows).enumerated().flatMap { row, line in
            cuts(line, cap: 2 * rows).map { XrayGridMarksView.Mark(row: row, col: $0.col, cells: $0.cells, key: $0.key) }
        }
    }

    private func prepare() {
        prepared = XrayRefSpans.prepare(linked)
        prepares += 1
    }

    /// One line's spans, from the memo or found now and kept.
    private func cuts(_ line: String, cap: Int) -> [Cut] {
        if let c = lines[line] {
            hits += 1
            return c
        }
        misses += 1
        let found = XrayRefSpans.find(line, prepared, scans: &scans)
        // #1701: a list's bare numbers after a prefixed ref (walked from each found span only, once per new line)
        let c = (found + XrayRefSpans.continued(line, after: found)).sorted { $0.range.lowerBound < $1.range.lowerBound }.map {
            Cut(col: XrayRefSpans.cells(line[..<$0.range.lowerBound]), cells: XrayRefSpans.cells(line[$0.range]), key: $0.key)
        }
        // shortcut: a full memo starts over rather than evicting the oldest; an LRU if scrolling long output thrashes it
        if lines.count >= cap { lines = [:] }
        lines[line] = c
        return c
    }
}

/// #1565, #1701: the card over the grid's marks. #1926/#1931 (operator 2026-11-24: "leave only the clicks"): no hover,
/// dwell or unpinned card; a Command-click on a mark opens today's full card (openRef, an extension's extRef) at once.
@MainActor
final class XrayHover {
    /// The panel the card shows in and the pane's refs (XrayRefLink.hoverPanel); nil: no card.
    var panel: @MainActor () -> (panel: XrayPanelModel, refs: XrayRefs)? = { nil }
    /// #1569: an extension mark's match (XrayGridMarksView.extMatches); nil: a dch ref.
    var ext: @MainActor (String) -> XrayExtensionRefs.Match? = { _ in nil }
    /// #1569: the window's handler calls (XrayExtensionCalls.of); nil: the card says unavailable.
    var calls: @MainActor () -> XrayExtensionCalls? = { nil }

    /// The panel of the last card (Esc, blur and hide close its card).
    private(set) weak var model: XrayPanelModel?

    /// #1701: a Command-click on mark `key`: its card, pinned. False: no card for it.
    func click(_ key: String) -> Bool {
        let x = ext(key)   // #1569
        guard let p = panel(), let e = x.map(XrayExtensionRefs.entry) ?? p.refs.entries.first(where: { $0.key == key })
                ?? XrayRefSpans.listed(key, in: p.refs.entries) else { return false }   // #1701: a list number's
        model = p.panel
        if let x { p.panel.extRef(e, x, calls: calls()) } else { p.panel.openRef(e) }
        return true
    }

    /// Closes the card of the panel (its close kills its read).
    func close() { model?.dismiss() }
}

/// #1952: the command pill: one small opaque capsule (the window's card fill and stroke) holding the Copy button.
final class XrayCommandPill: NSView {
    let copy = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy command")
        copy.imagePosition = .imageOnly
        copy.isBordered = false
        copy.toolTip = "Copy command"
        copy.setAccessibilityLabel("Copy command")
        addSubview(copy)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        copy.frame = bounds
        copy.symbolConfiguration = .init(pointSize: max(bounds.height * 0.5, 8), weight: .medium)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2, path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r)
        NSColor(Neon.card).setFill()
        path.fill()
        NSColor(Neon.stroke).setStroke()
        path.stroke()
        copy.contentTintColor = NSColor(Neon.textSecondary)
    }
}
