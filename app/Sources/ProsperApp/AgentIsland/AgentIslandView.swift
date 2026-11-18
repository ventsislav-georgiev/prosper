// Agent Island (#474) look: a black notch shape (inward top corners, rounded
// bottom) that is the hardware notch plus two ears when collapsed, and a ~480 pt
// session list when expanded — the vibe-notch / Vibe Island design, redrawn in
// Prosper's style. Open and close swap frames instantly: no spring, no bounce,
// no spinner (the standing no-new-animation rule).

import AppKit
import SwiftUI

/// The notch outline: top corners curve outward into the screen edge, bottom
/// corners round inward.
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + top, y: r.minY + top), control: CGPoint(x: r.minX + top, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + top, y: r.maxY - bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + top + bottom, y: r.maxY), control: CGPoint(x: r.minX + top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top - bottom, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - top, y: r.maxY - bottom), control: CGPoint(x: r.maxX - top, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - top, y: r.minY + top))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - top, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Where the island sits on one screen, in screen coordinates (origin bottom-left).
struct AgentIslandGeometry: Equatable {
    let screen: CGRect
    /// The hardware notch's width; 0 on a display without one.
    let notchWidth: CGFloat
    /// The notch's height, else the menu bar's.
    let barHeight: CGFloat

    static let expandedWidth: CGFloat = 480
    /// A two-line row (title, state); `prRowHeight` adds the PR line (#525).
    /// #1371: the session row is the Agent Sessions sidebar row's two lines (scaled, sz) in a card sz(40) high, never under
    /// 36 (the History row's fixed 13/11 pt lines), plus `rowGap`; the PR chips' line adds `chipLineHeight` (the chips'
    /// font is fixed). TIP: 48 and 64 at every scale (a 44 / 60 pt card and a 4 pt gap).
    static var rowHeight: CGFloat { max(sz(40), 36) + rowGap }
    static var prRowHeight: CGFloat { rowHeight + chipLineHeight }
    /// #1371: the gap between two rows (TIP: 4, the card's 2 pt padding above and below).
    static let rowGap: CGFloat = 2
    static let chipLineHeight: CGFloat = 18
    // The row's insets (AgentIslandRow): leading, glyph column, gap, trailing.
    static let rowLead: CGFloat = 8
    static let glyphWidth: CGFloat = 14
    static let glyphGap: CGFloat = 10
    static let rowTrail: CGFloat = 14
    /// The text column every line of a row lays out in; the PR line's budget.
    static let rowTextWidth = expandedWidth - 2 * listInset - rowLead - glyphWidth - glyphGap - rowTrail
    static let maxVisibleRows = 6
    static let listTop: CGFloat = 4
    static let listBottom: CGFloat = 12
    /// #571: the Sessions / Sidekicks row under the header. The two tabs do not
    /// fit beside the notch (~118 pt of text room left of a 185 pt notch, and the
    /// right side holds the state counts).
    static let tabsHeight: CGFloat = 22
    /// #578: the History list's header line (Resume interrupted, a dir status, the gate).
    static let historyHeaderHeight: CGFloat = 26
    static let closedRadii = (top: CGFloat(6), bottom: CGFloat(14))
    static let openRadii = (top: CGFloat(19), bottom: CGFloat(24))
    /// The header's side padding: lines its ends up with the row glyphs.
    static let headerPad = openRadii.top + 10

    /// The ears are square: as wide as the bar is tall.
    var earWidth: CGFloat { barHeight }

    var collapsedSize: CGSize { CGSize(width: notchWidth + 2 * earWidth, height: barHeight) }

    /// One row's height: three lines when it has a PR line (#534: after the toggles).
    static func height(of s: AgentSession, show d: AgentIslandRowDetails) -> CGFloat {
        hasChipLine(s.meta, show: d) ? prRowHeight : rowHeight
    }

    /// #1371: the third line holds the PR chips only (the merged count is on line two, as in Agent Sessions): a shown
    /// open PR with a label (`AgentIsland.hasPRLine` without the merged count).
    static func hasChipLine(_ m: DchSessionMeta?, show d: AgentIslandRowDetails) -> Bool {
        d.openPRs && (m?.openPRs.contains { $0.label != nil } ?? false)
    }

    /// The first 6 rows (`rows`, their heights in order) plus the prompt cards
    /// under blocked rows (`cards`, their summed `cardHeight`): the island grows
    /// for a card instead of clipping it, up to `maxListHeight`, then the list scrolls.
    func listHeight(rows: [CGFloat], cards: CGFloat = 0, tabs: Bool = false) -> CGFloat {
        min((rows.isEmpty ? Self.rowHeight : rows.prefix(Self.maxVisibleRows).reduce(0, +)) + cards, maxListHeight(tabs: tabs))
    }

    func listScrolls(rows: [CGFloat], cards: CGFloat = 0, tabs: Bool = false) -> Bool {
        rows.count > Self.maxVisibleRows || rows.reduce(0, +) + cards > maxListHeight(tabs: tabs)
    }

    /// `rows` two-line rows.
    func listHeight(rows: Int, cards: CGFloat = 0) -> CGFloat { listHeight(rows: Self.twoLine(rows), cards: cards) }
    func listScrolls(rows: Int, cards: CGFloat = 0) -> Bool { listScrolls(rows: Self.twoLine(rows), cards: cards) }
    private static func twoLine(_ n: Int) -> [CGFloat] { Array(repeating: rowHeight, count: max(n, 0)) }

    /// Leaves 40 pt of the screen below the island.
    var maxListHeight: CGFloat { maxListHeight(tabs: false) }
    func maxListHeight(tabs: Bool) -> CGFloat {
        max(Self.rowHeight, screen.height - barHeight - (tabs ? Self.tabsHeight : 0) - Self.listTop - Self.listBottom - 40)
    }

    /// `tabs`: the Sessions / Sidekicks row shows (#571).
    func expandedSize(rows: [CGFloat], cards: CGFloat = 0, tabs: Bool = false) -> CGSize {
        CGSize(width: min(screen.width, max(Self.expandedWidth, collapsedSize.width)),
               height: barHeight + (tabs ? Self.tabsHeight : 0) + Self.listTop
                   + listHeight(rows: rows, cards: cards, tabs: tabs) + Self.listBottom)
    }

    func expandedSize(rows: Int, cards: CGFloat = 0) -> CGSize { expandedSize(rows: Self.twoLine(rows), cards: cards) }

    // Card layout (#475): every row has a fixed height and every row's text is
    // measured to fit its width (AgentCardLayout), so this is exact.
    static let cardPad: CGFloat = 8
    static let cardGap: CGFloat = 4          // below the card, before the next row
    static let cardQuestion: CGFloat = 20    // a question or caption row
    static let cardContextLine: CGFloat = 14
    static let cardContextPad: CGFloat = 4   // inside the context block, top and bottom
    static let cardContextGap: CGFloat = 6   // below the context block
    static let cardButton: CGFloat = 26      // 22 pt button + 4 pt spacing
    static let cardLabelLine: CGFloat = 16   // a too-wide label's continuation row
    static let cardDetailLine: CGFloat = 14  // an option's detail line, inside its button

    // Card widths (W1). The view lays out with these, AgentCardLayout measures
    // against them. The island is `expandedWidth` wide (wider only if the
    // collapsed island is, narrower only on a screen under 480 pt), so a row
    // measured to fit here fits on screen.
    static let listInset: CGFloat = openRadii.top + 2   // inside the shape's straight sides
    static let contextInset: CGFloat = 6
    static let buttonInset: CGFloat = 8
    static let cardSpacing: CGFloat = 8                 // digit | label | spacer | hint
    static let cardSpacerMin: CGFloat = 4
    static let hintInset: CGFloat = 5
    static let cardInner = expandedWidth - 2 * listInset - 2 * cardPad   // question, caption rows
    static let cardContextWidth = cardInner - 2 * contextInset
    static let cardButtonInner = cardInner - 2 * buttonInset
    /// Measured width must leave this much room: SwiftUI rounds glyph runs up.
    static let fitMargin: CGFloat = 2

    // Card fonts: built once, immutable CTFonts, drawn with `Font(ctFont)` and
    // measured by `width`. Fixed sizes: nothing in the island follows
    // ThemeRuntime.scale / sz().
    //
    // Built with the NSFont factories: SF Mono has no public CoreText spelling
    // (.userFixedPitch is Menlo; the SF Mono name and design trait are private).
    // A `static let` initialises lazily on whichever thread touches it first, so
    // AgentIslandController.reload() touches `cardFonts` on main before its timer,
    // poller or any card build; queue work then only reads the stored CTFonts.
    // Never wrap this in MainActor.assumeIsolated: off main that traps (#478).
    nonisolated(unsafe) static let cardFonts = (
        question: NSFont.systemFont(ofSize: 13, weight: .medium) as CTFont,
        context: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) as CTFont,
        digit: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold) as CTFont,
        label: NSFont.systemFont(ofSize: 12, weight: .medium) as CTFont,
        hint: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular) as CTFont,
        detail: NSFont.systemFont(ofSize: 11) as CTFont,
        chip: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium) as CTFont)
    static var questionFont: CTFont { cardFonts.question }
    static var contextFont: CTFont { cardFonts.context }
    static var digitFont: CTFont { cardFonts.digit }
    static var labelFont: CTFont { cardFonts.label }
    static var hintFont: CTFont { cardFonts.hint }
    static var detailFont: CTFont { cardFonts.detail }
    /// #506: a row's PR chips and "+M", drawn and measured (AgentIsland.prChips) with it.
    static var chipFont: CTFont { cardFonts.chip }

    /// The one width function, for the card's layout on main and the warmer on
    /// the controller queue. CoreText, not NSString drawing: CoreText is
    /// documented thread-safe, the AppKit headers say nothing for sizeWithAttributes.
    static func width(_ s: String, _ f: CTFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): f]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func fits(_ s: String, _ f: CTFont, _ w: CGFloat) -> Bool { width(s, f) <= w - fitMargin }

    /// `s` hard-wrapped at character boundaries into rows that each measure as
    /// fitting `w`. Measured, never counted: CJK, emoji and combining marks
    /// take their real width; one Character is never split. Greedy: each row is
    /// the longest prefix that fits (at least one Character), found by binary
    /// search over measured prefixes, so a row costs ~log2(n) measures, not n.
    /// `words`: prose (the question) breaks at the last space that
    /// fits instead, the space dropped; a word wider than the row still splits.
    static func wrap(_ s: String, _ f: CTFont, _ w: CGFloat, words: Bool = false) -> [String] {
        let cs = Array(s)
        var rows: [String] = [], i = 0
        repeat {
            // cs[i..<lo] fits (or is the one forced Character), cs[i..<hi] does not.
            var lo = cs.count, hi = cs.count
            if !fits(String(cs[i...]), f, w) {
                lo = i + 1
                while hi - lo > 1 {
                    let m = (lo + hi) / 2
                    if fits(String(cs[i..<m]), f, w) { lo = m } else { hi = m }
                }
            }
            if words, lo < cs.count, let k = cs[(i + 1)...lo].lastIndex(of: " ") {
                rows.append(String(cs[i..<k]))
                i = k + 1
            } else {
                rows.append(String(cs[i..<lo]))
                i = lo
            }
        } while i < cs.count
        return rows
    }

    /// `cache`: a test seam (W1-perf); the app always uses `.shared`.
    static func cardHeight(_ card: AgentCard, in cache: AgentCardLayoutCache = .shared) -> CGFloat {
        func context(_ n: Int, _ line: CGFloat = cardContextLine) -> CGFloat {
            n == 0 ? 0 : CGFloat(n) * line + 2 * cardContextPad + cardContextGap
        }
        let body: CGFloat
        switch card {
        case .prompt(let p):
            let l = p.layout(in: cache)
            body = CGFloat(l.question.count + l.caption.count) * cardQuestion + context(l.context.count)
                + context(l.preview.count, l.previewLine)
                + CGFloat(p.options.count + 1) * cardButton
                + CGFloat(l.labels.reduce(0) { $0 + $1.count - 1 }) * cardLabelLine
                + CGFloat(l.details.reduce(0) { $0 + $1.count }) * cardDetailLine
        case .context(let lines):
            body = context(AgentCardLayout.contextRows(lines, words: true, in: cache).rows.count) + cardButton
        case .changed:
            body = cardQuestion + cardButton
        }
        return 2 * cardPad + body + cardGap
    }

    /// Hanging from the top edge, centred on the screen (and so on the notch).
    func frame(_ size: CGSize) -> CGRect {
        CGRect(x: (screen.midX - size.width / 2).rounded(), y: screen.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// Notched: notch width from the two auxiliary areas, height from the safe
    /// area. Otherwise a pill inside the menu bar (24 pt when it is hidden).
    static func make(frame: CGRect, visibleFrame: CGRect, topLeft: CGRect?, topRight: CGRect?,
                     safeTop: CGFloat) -> AgentIslandGeometry {
        if let l = topLeft, let r = topRight, safeTop > 0 {
            return AgentIslandGeometry(screen: frame, notchWidth: max(0, frame.width - l.width - r.width),
                                       barHeight: safeTop)
        }
        let bar = frame.maxY - visibleFrame.maxY
        return AgentIslandGeometry(screen: frame, notchWidth: 0, barHeight: bar > 0 ? bar : 24)
    }

    /// The display with a notch, else the main one.
    @MainActor static func current() -> AgentIslandGeometry? {
        guard let s = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) ?? NSScreen.main
        else { return nil }
        return make(frame: s.frame, visibleFrame: s.visibleFrame, topLeft: s.auxiliaryTopLeftArea,
                    topRight: s.auxiliaryTopRightArea, safeTop: s.safeAreaInsets.top)
    }
}

@MainActor
final class AgentIslandStore: ObservableObject {
    /// Every session, in the poller's order: the collapsed island and the
    /// header summarize these; the list draws `visible`.
    @Published var sessions: [AgentSession] = [] { didSet { resetTab(); dropStaleQuestions() } }
    @Published var expanded = false
    @Published var geometry: AgentIslandGeometry
    /// Inline row notes: "Attach command copied", "Attached in tmux/ssh …".
    @Published var notices: [AgentSessionKey: String] = [:]
    /// #475: the prompt card under a blocked row, from its last screen read.
    @Published var cards: [AgentSessionKey: AgentCard] = [:]
    /// #534: the row details shown. The controller sets it from Preferences at
    /// build and on every Settings toggle; the tests set it outright.
    @Published var details: AgentIslandRowDetails
    /// #571: the list order and the sidekick pattern ("" = tabs off), set like
    /// `details`; the chosen tab, in memory only.
    @Published var sort: AgentIslandSort
    @Published var sidekickPattern: String { didSet { resetTab(); dropStaleQuestions() } }
    @Published var sidekickTab = false { didSet { dropStaleQuestions() } }
    /// #908: the pair suffix (Settings > Pairs) the groups are read with; "" (pairing by name off) until
    /// the controller sets it, so a store a test builds outright draws no group item.
    @Published var pairSuffix = ""
    /// #578: `dch --history --json`'s records, newest first, read on open and
    /// after an action; the History tab is chosen (it wins over `sidekickTab`).
    @Published var history: [DchHistoryRecord] = [] { didSet { resetTab() } }
    @Published var historyTab = false
    /// #1536: the row the launcher command or its shortcut opened on (lit and scrolled to); nil once the island closes.
    @Published var focusKey: AgentSessionKey?
    /// The control binary (DchCommand.controlDch), probed with the history.
    @Published var controlDch: DchCommand.Binary?
    /// #719: the live sessions' Claude ids (their dch records), read with the history
    /// while the control dch is 1.28.2 or later: what its --revive --all holds.
    @Published var liveSIDs: Set<String> = []
    /// A long verb's static status in its row: "Resuming…", then the result.
    /// Keyed by row; a dir's `--revive --all` is `(dir, "")`.
    /// #579: a session row's Restart too; `(dir, "")` also holds Restart all and a failed New session.
    @Published var actions: [AgentSessionKey: String] = [:]
    /// #580: a History row's Resume status, apart from `actions`: a record and a
    /// live session can share a key (Resume as <name>-2), and each row says its own.
    @Published var historyActions: [AgentSessionKey: String] = [:]
    /// #579: the inline "Restart stale agents?" line is up (never a modal).
    @Published var confirmingRestartAll = false
    /// #700: the question up is the forced one ("Restart every agent…").
    @Published var restartAllForce = false
    /// #580: the inline "Stop N sessions?" line is up; at most one question shows.
    @Published var confirmingStopAll = false
    /// #744: the inline "Kill N sessions?" line is up.
    @Published var confirmingKillAll = false
    /// #744 (QA #572 F1, F2): what the Stop all or Kill all question named when it was asked.
    struct Asked: Equatable {
        var keys: Set<AgentSessionKey> = []
        /// The scope's rows it leaves out (an old dch, a "-" name).
        var skipped = 0
        /// #749 (QA #572 INFO-R6): of those, Stop all's for a "-" name.
        var dashed = 0
        /// The tab asked about; nil: every tab ("Stop all…", "Kill all…").
        var tab: String?
    }
    @Published var asked = Asked()
    /// #744: a row's Kill asks first: the row whose "Kill <name>?" line is up.
    @Published var confirmingKill: AgentSessionKey?
    /// #605: the History header asks "Clear N unpinned?".
    @Published var confirmingClear = false
    /// #584: the composer in the control line, its draft; nil: closed. Its rows are `asked` (tab nil: one row's
    /// Message…, else Message all in that tab). Never logged, never shown on a row.
    @Published var messageDraft: String?

    /// At most one inline question shows: every ask drops the others first.
    func dropQuestions() {
        confirmingRestartAll = false
        confirmingStopAll = false
        confirmingKillAll = false
        confirmingKill = nil
        confirmingClear = false
        messageDraft = nil
        asked = Asked()
    }

    /// QA #572 F1, F2: a Stop all or Kill all question whose rows changed goes: one
    /// ended, or the asked tab is no longer the shown one (a click, a Settings change,
    /// or one side emptying flips it by itself). So its line never counts, and its
    /// answer never reaches, rows it did not name. A row's Kill goes with its row.
    /// Runs on every change of the rows or the tab (didSet), whoever makes it.
    func dropStaleQuestions() {
        if confirmingStopAll, stopAllTargets.count != asked.keys.count { confirmingStopAll = false }
        if confirmingKillAll, killAllTargets.count != asked.keys.count { confirmingKillAll = false }
        if confirmingKill != nil, killTarget == nil { confirmingKill = nil }
        if messageDraft != nil, messageTargets.isEmpty { messageDraft = nil }   // #584: nobody left to message
    }

    init(geometry: AgentIslandGeometry, details: AgentIslandRowDetails = .all,
         sort: AgentIslandSort = .activity, sidekickPattern: String = "") {
        self.geometry = geometry
        self.details = details
        self.sort = sort
        self.sidekickPattern = sidekickPattern
    }

    /// The last sidekick gone (or the tabs off): back to Sessions, so the next
    /// sidekick to appear does not switch the list.
    private func resetTab() {
        if sidekickTab, AgentIsland.split(sessions, pattern: sidekickPattern).sidekicks.isEmpty { sidekickTab = false }
        if historyTab, history.isEmpty { historyTab = false }
    }

    /// The collapsed island and the header: every session, whichever tab shows,
    /// so a blocked sidekick still lights the ear.
    var summary: AgentIsland.Summary { AgentIsland.summary(sessions) }

    /// Sorted, then split. No sidekicks = no tabs and the whole list.
    var split: AgentIsland.Split { AgentIsland.split(AgentIsland.sorted(sessions, by: sort), pattern: sidekickPattern) }
    /// #578: sidekicks or history.
    var showsTabs: Bool { !split.sidekicks.isEmpty || !history.isEmpty }
    /// #1537 (OQ-95): the Claude plan usage line (session and weekly limit); nil: none drawn.
    @Published var planUsage: AgentPlanUsage?
    /// #1537: the tab row is drawn for the tabs or for the plan usage at its right end.
    var showsTabRow: Bool { showsTabs || planUsage != nil }
    /// #581: the collapsed island shows with a live session, or with none but
    /// history (the History tab). #579's New session lives in the open island's
    /// "⋯" menu, so with nothing live and no history it is not offered: the
    /// island stays hidden.
    var showsIsland: Bool { !sessions.isEmpty || !history.isEmpty }

    /// The session rows the list draws: the shown tab's half; none under History.
    var visible: [AgentSession] { historyTab ? [] : sessionTab.sessions }

    /// #580: the Sessions or Sidekicks tab, the one shown (under History, the
    /// one the list goes back to): its name and rows.
    var sessionTab: (label: String, sessions: [AgentSession]) {
        let s = split
        return AgentIsland.showsSidekicks(s, tab: sidekickTab) ? ("Sidekicks", s.sidekicks) : ("Sessions", s.primary)
    }

    /// #580: Stop all's rows, the session tab's (#744: or every tab's) whose master can
    /// stop, and how many it leaves out; #749: `dashed` of those for a "-" name (the rest, an old dch).
    func stopTargets(global: Bool) -> (stop: [AgentSession], skipped: Int, dashed: Int) {
        let rows = global ? sessions : sessionTab.sessions
        let stop = rows.filter { AgentIsland.canStop($0) && AgentIsland.passable($0.name) }
        return (stop, rows.count - stop.count, rows.filter { AgentIsland.canStop($0) && !AgentIsland.passable($0.name) }.count)
    }

    /// #744: Kill all's rows, the shown tab's or every tab's. Any master can be killed
    /// (dch's own SIGTERM); only a name killArgs refuses is skipped.
    func killTargets(global: Bool) -> (kill: [AgentSession], skipped: Int) {
        let rows = global ? sessions : sessionTab.sessions, kill = rows.filter { AgentIsland.killArgs($0.name) != nil }
        return (kill, rows.count - kill.count)
    }

    /// QA #572 F1, F2: the question's own rows, still live in its scope (the asked tab
    /// only while it is the shown one): all the answer acts on.
    var stopAllTargets: [AgentSession] { askedRows(stopTargets(global: asked.tab == nil).stop) }
    var killAllTargets: [AgentSession] { askedRows(killTargets(global: asked.tab == nil).kill) }
    /// #584: the composer's rows still live (Message all's only while its tab shows); asked only passable names.
    var messageTargets: [AgentSession] { askedRows(sessions) }

    /// #584: Message all's rows, the shown tab's whose name dch takes, and how many it leaves out.
    var messageAllTargets: (rows: [AgentSession], skipped: Int) {
        let rows = sessionTab.sessions, ok = rows.filter { AgentIsland.passable($0.name) }
        return (ok, rows.count - ok.count)
    }

    /// #584: the composer's name for its field: "Message api", "Message 3 sessions in Sessions".
    var messagePrompt: String {
        let rows = messageTargets
        guard let tab = asked.tab else { return "Message \(rows.first?.title ?? "")" }
        return "Message \(rows.count) session\(rows.count == 1 ? "" : "s") in \(tab)"
    }

    /// #584: what the field types, only while the composer is open: a late write from a field that is
    /// going away never opens it again.
    func typeMessage(_ text: String) { if messageDraft != nil { messageDraft = text } }

    private func askedRows(_ scope: [AgentSession]) -> [AgentSession] {
        asked.tab == nil || asked.tab == sessionTab.label ? scope.filter { asked.keys.contains($0.key) } : []
    }

    /// Records a Stop all or Kill all question's rows; the caller sets its flag.
    func ask(_ rows: [AgentSession], skipped: Int, dashed: Int = 0, global: Bool) {
        asked = Asked(keys: Set(rows.map(\.key)), skipped: skipped, dashed: dashed, tab: global ? nil : sessionTab.label)
    }

    /// The Stop all and Kill all lines, from what was asked. #749 (QA #572 INFO-R6):
    /// "every tab" only while the tabs are on.
    var stopAllQuestion: String {
        AgentIsland.stopAllQuestion(asked.keys.count, skipped: asked.skipped, dashed: asked.dashed, tab: asked.tab,
                                    tabs: !sidekickPattern.isEmpty)
    }
    var killAllQuestion: String {
        AgentIsland.killAllQuestion(asked.keys.count, skipped: asked.skipped, tab: asked.tab, tabs: !sidekickPattern.isEmpty)
    }

    /// #744: the session the row Kill question names, while it is still live.
    var killTarget: AgentSession? { confirmingKill.flatMap { k in sessions.first { $0.key == k } } }

    /// #605: pinned first, then unpinned up to the cap (the tab's count too).
    var cappedHistory: [DchHistoryRecord] { AgentIsland.cappedHistory(history, live: Set(sessions.map(\.key))) }
    /// #578: the History tab's rows, capped.
    var shownHistory: [DchHistoryRecord] { historyTab ? cappedHistory : [] }

    /// #585: the clock reviveAllTakes reads; the tests pin it.
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }

    /// #585: how many records `--revive --all` would take: every record, not
    /// just the `historyCap` shown, as dch takes them all.
    var resumableCount: Int { reviveAllTaken.count }

    /// #719 (QA #533 F1): the records --revive --all takes, by id; from dch 1.28.2
    /// the ones whose Claude id no live session or newer record holds.
    var reviveAllTaken: Set<AgentSessionKey> {
        let ended = controlDch.map { DchCommand.isAtLeast($0.version, AgentIsland.reviveEndedHoldMinimum) } ?? false
        return AgentIsland.reviveAllTaken(history, now: now(), held: reviveFileGate.isOK ? liveSIDs : nil, endedHolds: ended,
                                           live: Set(sessions.map(\.key)))   // #992 R950-1
    }

    /// Each History dir's last --all status, by dir.
    var historyStatus: String {
        Set(history.map(\.key.dir)).sorted().compactMap { actions[AgentSessionKey(dir: $0, name: "")] }.joined(separator: " · ")
    }

    /// #585: the History header's button, "Resume interrupted (n)"; nil (no
    /// button) at n == 0 or while the gate refuses (its reason shows instead).
    var resumeAllButton: String? {
        let n = resumableCount
        return resumeGate.isOK && n > 0 ? AgentIsland.resumeAllLabel(n) : nil
    }

    /// #605: every unpinned record, not just the shown ones: `--forget --all` takes them all.
    var unpinnedCount: Int { history.filter { !$0.pinned }.count }

    /// #605: "Clear unpinned" with the gate open and an unpinned record to clear.
    var clearUnpinnedButton: String? {
        historyEditGate.isOK && unpinnedCount > 0 ? AgentIsland.clearUnpinnedLabel : nil
    }

    /// #585: the line over the History rows only with something on it: the
    /// gate's refusal, the button, or a dir status.
    var showsHistoryHeader: Bool {
        historyTab && (!resumeGate.isOK || resumeAllButton != nil || clearUnpinnedButton != nil || confirmingClear
            || !historyStatus.isEmpty)
    }

    /// Every control verb's gate (Resume, #579's Restart, Restart all, New
    /// session, #580's Stop): the control binary against 1.24.0 and every live
    /// master; `.refused` carries the one-line reason.
    var resumeGate: DchCommand.Gate {
        DchCommand.gate(controlDch, masters: sessions.map(\.version), minimum: AgentIsland.controlMinimum)
    }

    /// #580 addendum 2: Restart agent, Restart all and Stop's gate, 1.24.1.
    var restartGate: DchCommand.Gate {
        DchCommand.gate(controlDch, masters: sessions.map(\.version), minimum: AgentIsland.restartMinimum)
    }

    /// Those items' "(needs dch 1.24.1)", only while the base gate passes: its
    /// refusal has its own line. With the base passing the control dch is at
    /// least every master, so this can only name `restartMinimum`.
    var restartNeeds: String? { resumeGate.isOK ? restartGate.refusal : nil }

    /// #605: the pin, X and Clear unpinned's gate, 1.25.0; refused, they do not show.
    var historyEditGate: DchCommand.Gate {
        DchCommand.gate(controlDch, masters: sessions.map(\.version), minimum: AgentIsland.historyEditMinimum)
    }

    /// #714: 1.28.1: pin, unpin and forget take `<file>.json`, one record each.
    var recordFileGate: DchCommand.Gate {
        DchCommand.gate(controlDch, masters: sessions.map(\.version), minimum: AgentIsland.recordFileMinimum)
    }

    /// #719: 1.28.2: Resume takes `<file>.json`; --revive --all holds live and newer Claude ids.
    var reviveFileGate: DchCommand.Gate {
        DchCommand.gate(controlDch, masters: sessions.map(\.version), minimum: AgentIsland.reviveFileMinimum)
    }

    /// #669: Resume (no message)'s gate, 1.27.0; refused, its controls do not show (Resume stays).
    var reviveNoMessageGate: DchCommand.Gate {
        DchCommand.gate(controlDch, masters: sessions.map(\.version), minimum: AgentIsland.reviveNoMessageMinimum)
    }

    /// Cards show under blocked rows only.
    func card(for s: AgentSession) -> AgentCard? { s.state == .blocked ? cards[s.key] : nil }

    var cardsHeight: CGFloat {
        visible.compactMap(card(for:)).reduce(0) { $0 + AgentIslandGeometry.cardHeight($1) }
    }

    /// #579: every dir's last dir-wide status (Resume interrupted, Restart all, a
    /// failed New session), by dir.
    var dirStatus: String {
        actions.filter { $0.key.name.isEmpty }.sorted { $0.key.dir < $1.key.dir }.map(\.value).joined(separator: " · ")
    }

    /// #579: the line over the rows: the Restart all question on any tab, else
    /// under Sessions the dir-wide status (History's header has its own).
    var showsControlLine: Bool {
        confirmingRestartAll || confirmingStopAll || confirmingKillAll || killTarget != nil || messageDraft != nil
            || (!historyTab && !dirStatus.isEmpty)
    }

    /// #579: the header "⋯" menu's content: recent folders for New session,
    /// and the gate's reason when its items are off.
    struct ControlsMenu: Equatable {
        let recent: [String]
        let refused: String?
    }

    var controlsMenu: ControlsMenu {
        ControlsMenu(recent: AgentIsland.recentFolders(history), refused: resumeGate.refusal)
    }

    /// #525: per row, two or three lines.
    /// #578: under History, the header line (#585: when shown), then two-line rows.
    var rowHeights: [CGFloat] {
        (showsControlLine ? [AgentIslandGeometry.historyHeaderHeight] : [])
            + (showsHistoryHeader ? [AgentIslandGeometry.historyHeaderHeight] : [])
            + (historyTab ? shownHistory.map { _ in AgentIslandGeometry.rowHeight }
                : visible.map { AgentIslandGeometry.height(of: $0, show: details) })
    }

    var size: CGSize {
        expanded ? geometry.expandedSize(rows: rowHeights, cards: cardsHeight, tabs: showsTabRow) : geometry.collapsedSize
    }
}

struct AgentIslandView: View {
    @ObservedObject var store: AgentIslandStore
    var onToggle: () -> Void = {}
    var onRow: (AgentSession) -> Void = { _ in }
    var onAnswer: (AgentSession, AgentPrompt, AgentPromptOption) -> Void = { _, _, _ in }
    /// #571: a tab click, true = Sidekicks.
    var onTab: (Bool) -> Void = { _ in }
    /// #578: the History tab, a history row's Resume, and Resume interrupted.
    var onHistory: () -> Void = {}
    var onResume: (DchHistoryRecord) -> Void = { _ in }
    var onResumeAll: () -> Void = {}
    /// #669: a History row's Resume (no message), and Resume interrupted's.
    var onResumeNoMessage: (DchHistoryRecord) -> Void = { _ in }
    var onResumeAllNoMessage: () -> Void = {}
    /// #579: a row's Restart agent, the header "⋯" (its menu is the
    /// controller's), and the inline Restart all answer.
    var onRestart: (AgentSession) -> Void = { _ in }
    var onControls: () -> Void = {}
    /// #797: the header's Agents window button.
    var onAgentsWindow: () -> Void = {}
    var onConfirmRestartAll: (Bool) -> Void = { _ in }
    /// #580: a row's Stop and the inline Stop all answer.
    var onStop: (AgentSession) -> Void = { _ in }
    /// #908: a row's Stop both / Stop all N (no question, as Stop): the row and its group's live names drawn, in group order.
    var onStopGroup: (AgentSession, [String]) -> Void = { _, _ in }
    /// #908: a History row's Resume both / Resume all N.
    var onResumeGroup: (DchHistoryRecord) -> Void = { _ in }
    var onConfirmStopAll: (Bool) -> Void = { _ in }
    /// #744: a row's Kill (it only asks), and the inline row Kill and Kill all answers.
    var onKill: (AgentSession) -> Void = { _ in }
    var onConfirmKill: (Bool) -> Void = { _ in }
    var onConfirmKillAll: (Bool) -> Void = { _ in }
    /// #605: a History row's pin toggle and X, Clear unpinned and its inline answer.
    var onPin: (DchHistoryRecord) -> Void = { _ in }
    var onRemove: (DchHistoryRecord) -> Void = { _ in }
    var onClearUnpinned: () -> Void = {}
    var onConfirmClear: (Bool) -> Void = { _ in }
    /// #584: a row's Message… (opens the composer), and the composer's Send (or Enter) and Cancel (or Esc).
    var onMessage: (AgentSession) -> Void = { _ in }
    var onSendMessage: () -> Void = {}
    var onCancelMessage: () -> Void = {}

    private var g: AgentIslandGeometry { store.geometry }
    /// #1375: a theme switch redraws the island (its inks read the palette), as NeonSelectedRowFill does.
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        let radii = store.expanded ? AgentIslandGeometry.openRadii : AgentIslandGeometry.closedRadii
        ZStack(alignment: .top) {
            NotchShape(top: radii.top, bottom: radii.bottom).fill(Color.black)
            if store.expanded { expanded } else { collapsed }
        }
        .frame(width: store.size.width, height: store.size.height)
        .environment(\.colorScheme, .dark)
        .transaction { $0.animation = nil }
    }

    // MARK: Collapsed

    private var collapsed: some View {
        let s = store.summary
        let ear = s.earCount
        return Button(action: onToggle) {
            HStack(spacing: 0) {
                Text(s.mostUrgent?.glyph ?? "")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(s.mostUrgent.map { AgentIslandInk.glyph($0) } ?? .clear)
                    .frame(width: g.earWidth)
                Color.clear.frame(width: g.notchWidth)
                Text("\(ear.value)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    // #581: nothing live (history only): a dim 0, no glyph on the left.
                    .foregroundStyle(ear.state == .blocked ? ear.state.color : (s.total == 0 ? Color.white.opacity(0.35) : Neon.faded(.white, 0.9)))
                    .frame(width: g.earWidth)
            }
            .frame(height: g.barHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AgentIsland.islandAccessibilityLabel(s, history: store.cappedHistory.count))
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            header.frame(height: g.barHeight)
            let tabs = store.showsTabRow
            if tabs { tabRow.frame(height: AgentIslandGeometry.tabsHeight) }
            Group {
                if g.listScrolls(rows: store.rowHeights, cards: store.cardsHeight, tabs: tabs) {
                    ScrollViewReader { proxy in   // #1536: the focused row is brought into view
                        ScrollView(.vertical, showsIndicators: false) { rows }
                            .onChange(of: store.focusKey, initial: true) { _, k in if let k { proxy.scrollTo(k, anchor: .top) } }
                    }
                } else {
                    rows
                }
            }
            .frame(height: g.listHeight(rows: store.rowHeights, cards: store.cardsHeight, tabs: tabs), alignment: .top)
            .padding(.top, AgentIslandGeometry.listTop)
            // Inside the shape's straight sides (the top corners curve in by `top`).
            .padding(.horizontal, AgentIslandGeometry.listInset)
            Spacer(minLength: 0)
        }
    }

    /// TimelineView: ages tick once a second, only while the list is open.
    private var rows: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 0) {
                if store.showsControlLine { controlLine }
                if store.showsHistoryHeader { historyHeader }
                ForEach(historyDrawn) { r in
                    AgentIslandHistoryRow(record: r.record, now: ctx.date.timeIntervalSince1970,
                                          status: r.status, enabled: r.enabled,
                                          action: r.resume, pin: r.pin, remove: r.remove,
                                          resumeNoMessage: r.resumeNoMessage, older: r.older,
                                          olderUnpinned: r.olderUnpinned)
                    .contextMenu { ForEach(r.menu, id: \.title) { Button($0.title, action: $0.action) } }   // #742
                }
                ForEach(drawn) { r in
                    AgentIslandRow(session: r.session, now: ctx.date.timeIntervalSince1970,
                                   notice: store.notices[r.session.key] ?? store.actions[r.session.key],
                                   show: store.details, focused: store.focusKey == r.session.key, action: r.open)
                    .id(r.session.key)
                    .contextMenu { restartItem(r) }
                    if let card = r.card {
                        AgentPromptCardView(card: card, onOption: r.answer, onJump: r.open)
                    }
                }
            }
        }
    }

    /// QA #434 I1: one drawn row and the session its click, its card's answers
    /// and its Jump carry. `rows` draws exactly these, so a test can press them.
    struct Drawn: Identifiable {
        let session: AgentSession
        let card: AgentCard?
        let open: () -> Void
        let answer: (AgentPrompt, AgentPromptOption) -> Void
        /// #579: its context menu's Restart agent, off with the gate's reason.
        var restart: () -> Void = {}
        var refused: String? = nil
        /// #580: its Stop; `canStop` false (a master under 1.24.0) is the "restart this session first" item.
        var stop: () -> Void = {}
        var canStop = false
        /// #580 addendum 2: Restart agent and Stop off, reading "(needs dch 1.24.1)".
        var needs: String? = nil
        /// #744: its Kill (asks first); any master, only the base gate and a passable name.
        var kill: () -> Void = {}
        /// #584: its Message… (opens the composer); the base gate and a passable name, any master.
        var message: () -> Void = {}
        /// #908: Stop both / Stop all N with its group's other live sessions; nil (no item) outside a group
        /// or with no other member live. `othersCanStop`: each of those passes canStop.
        var stopBoth: (() -> Void)? = nil
        var stopBothTitle = ""
        var othersCanStop = false
        var id: AgentSessionKey { session.key }
        var restartTitle: String { AgentIsland.label(AgentIsland.restartLabel, needs: needs) }
        /// One hint, never both: the dch one wins over "restart this session first".
        var stopTitle: String {
            canStop || needs != nil ? AgentIsland.label(AgentIsland.stopLabel, needs: needs) : AgentIsland.stopOldMasterLabel
        }
        /// #627: a name dch would read as a flag gets no Restart or Stop at all.
        var controls: Bool { AgentIsland.passable(session.name) }
        var restartEnabled: Bool { refused == nil && needs == nil && controls }
        var stopEnabled: Bool { restartEnabled && canStop }
        var stopBothEnabled: Bool { stopEnabled && othersCanStop }
        var killEnabled: Bool { refused == nil && AgentIsland.killArgs(session.name) != nil }
        var messageEnabled: Bool { refused == nil && controls }
    }

    var drawn: [Drawn] {
        let refused = store.resumeGate.refusal, needs = store.restartNeeds, groups = store.groups
        return store.visible.map { s in
            var d = Drawn(session: s, card: store.card(for: s), open: { onRow(s) }, answer: { onAnswer(s, $0, $1) },
                          restart: { onRestart(s) }, refused: refused, stop: { onStop(s) }, canStop: AgentIsland.canStop(s),
                          needs: needs, kill: { onKill(s) }, message: { onMessage(s) })
            let group = store.liveGroup(s, groups) ?? [], others = group.filter { $0.key != s.key }
            if !others.isEmpty {
                let names = group.map(\.name)
                d.stopBoth = { onStopGroup(s, names) }
                d.stopBothTitle = AgentIsland.groupLabel(.stop, others: others.map(\.name))
                d.othersCanStop = others.allSatisfy(AgentIsland.canStop)
            }
            return d
        }
    }

    /// #579: a row's right-click menu. Shown even where dch will skip it (a
    /// claude typed into a shell, a pending respawn): the row shows the skip line.
    /// #580: Stop next to Restart agent; off, saying why, on a master under 1.24.0.
    /// Under a 1.24.0 control dch both read "(needs dch 1.24.1)", and that hint
    /// wins over Stop's "restart this session first".
    @ViewBuilder
    private func restartItem(_ r: Drawn) -> some View {
        if r.controls {
            Button(AgentIsland.messageLabel, action: r.message).disabled(!r.messageEnabled)   // #584
            Button(r.restartTitle, action: r.restart).disabled(!r.restartEnabled)
            Button(r.stopTitle, action: r.stop).disabled(!r.stopEnabled)
            if let both = r.stopBoth { Button(r.stopBothTitle, action: both).disabled(!r.stopBothEnabled) }   // #908
            Button(AgentIsland.killLabel, action: r.kill).disabled(!r.killEnabled)   // #744
        }
        if let why = r.refused { Text(verbatim: "Controls \(why)") }
    }

    /// #579: the header "⋯": a plain button; the controller pops its menu
    /// (New session, Restart all agents) at the mouse.
    private var controlsButton: some View {
        Button(action: onControls) {
            Text(verbatim: "⋯")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Neon.faded(.white, 0.75))
                .frame(minWidth: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Session controls")
    }

    /// #797: opens the Agents window (every session and its conversation).
    private var agentsWindowButton: some View {
        Button(action: onAgentsWindow) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Neon.faded(.white, 0.75))
                .frame(minWidth: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Agent Sessions")
        .accessibilityLabel("Agent Sessions")
    }

    /// #579: the line over the rows: the inline Restart all question (Restart,
    /// Cancel; no modal, no animation), else the dir-wide statuses. Static text.
    private var controlLine: some View {
        HStack(spacing: 10) {
            if store.messageDraft != nil {
                AgentIslandComposer(store: store, onSend: onSendMessage, onCancel: onCancelMessage)
            } else if store.confirmingRestartAll {
                Text(verbatim: store.restartAllForce ? AgentIsland.restartAllForceQuestion : AgentIsland.restartAllQuestion)
                    .foregroundStyle(Neon.faded(.white, 0.8))
                Spacer(minLength: 0)
                lineButton("Restart") { onConfirmRestartAll(true) }
                lineButton("Cancel") { onConfirmRestartAll(false) }
            } else if store.confirmingStopAll {
                // #580: same line, same look. QA #572: the rows named when asked (a change drops it).
                let n = store.asked.keys.count
                Text(verbatim: store.stopAllQuestion)
                    .foregroundStyle(Neon.faded(.white, 0.8))
                Spacer(minLength: 0)
                lineButton("Stop") { onConfirmStopAll(true) }
                    .accessibilityLabel(Text(verbatim: "Stop \(n) session\(n == 1 ? "" : "s")"))
                lineButton("Cancel") { onConfirmStopAll(false) }
                    .accessibilityLabel(Text(verbatim: "Cancel Stop all"))
            } else if store.confirmingKillAll {
                // #744: like Stop all's.
                let n = store.asked.keys.count
                Text(verbatim: store.killAllQuestion)
                    .foregroundStyle(Neon.faded(.white, 0.8))
                Spacer(minLength: 0)
                lineButton("End") { onConfirmKillAll(true) }
                    .accessibilityLabel(Text(verbatim: "End \(n) session\(n == 1 ? "" : "s")"))
                lineButton("Cancel") { onConfirmKillAll(false) }
                    .accessibilityLabel(Text(verbatim: "Cancel End all"))
            } else if let s = store.killTarget {
                Text(verbatim: AgentIsland.killQuestion(s.title)).foregroundStyle(Neon.faded(.white, 0.8))
                Spacer(minLength: 0)
                lineButton("End") { onConfirmKill(true) }
                    .accessibilityLabel(Text(verbatim: "End \(s.title)"))
                lineButton("Cancel") { onConfirmKill(false) }
                    .accessibilityLabel(Text(verbatim: "Cancel End"))
            } else {
                Text(verbatim: store.dirStatus).foregroundStyle(Neon.faded(.white, 0.6))
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, AgentIslandGeometry.rowLead)
        .frame(height: AgentIslandGeometry.historyHeaderHeight)
    }

    private func lineButton(_ title: String, action: @escaping () -> Void) -> some View {
        AgentIslandView.lineButton(title, action: action)
    }

    static func lineButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Neon.faded(.white, 0.9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// #578: one drawn History row and its Resume; off while the gate refuses.
    /// #605: its pin toggle and X, nil (not drawn) under 1.25.0; a pinned row has no X.
    struct HistoryDrawn: Identifiable {
        let record: DchHistoryRecord
        let enabled: Bool
        let resume: () -> Void
        var pin: (() -> Void)? = nil
        var remove: (() -> Void)? = nil
        /// #669: Resume (no message), nil (not drawn) under 1.27.0.
        var resumeNoMessage: (() -> Void)? = nil
        /// #908: Resume both / Resume all N, nil (not drawn) unless its group has no member live in its dir.
        var resumeBoth: (() -> Void)? = nil
        var resumeBothTitle = ""
        /// #714, #743: the older records of the row's name, folded in; its pin and X act on them too.
        var older = 0
        /// #716 L-2: of those, the unpinned ones, the ones its X removes (dch keeps a pinned one).
        var olderUnpinned = 0
        /// The row's Resume status, by its record's id; #743: else its newest older record's that has one.
        var status: String? = nil
        var id: AgentSessionKey { record.id }
        /// #742: the right-click menu, only the items its gates draw: Resume (with
        /// dch's message), Resume (no message), Pin/Unpin, Remove.
        struct MenuItem { let title: String; let action: () -> Void }
        var menu: [MenuItem] {
            [enabled ? MenuItem(title: AgentIsland.resumeLabel, action: resume) : nil,
             resumeBoth.map { MenuItem(title: resumeBothTitle, action: $0) },
             resumeNoMessage.map { MenuItem(title: AgentIsland.resumeNoMessageLabel, action: $0) },
             pin.map { MenuItem(title: AgentIsland.editLabel(record.pinned ? AgentIsland.unpinLabel : AgentIsland.pinLabel,
                                                              older: older), action: $0) },
             remove.map { MenuItem(title: AgentIsland.removeEditLabel(older: older, unpinned: olderUnpinned), action: $0) },
            ].compactMap { $0 }
        }
    }

    var historyDrawn: [HistoryDrawn] {
        let on = store.resumeGate.isOK, edits = store.historyEditGate.isOK, quiet = store.reviveNoMessageGate.isOK
        let groups = store.groups
        return store.shownHistory.map { r in
            // #627: a name dch would read as a flag: no Resume, pin or X.
            let ok = AgentIsland.passable(r.name)
            // #743: the name's older records fold into its one row; its pin and X act on them too, at every gate.
            let asides = AgentIsland.older(r, in: store.history)
            var d = HistoryDrawn(record: r, enabled: on && ok, resume: { onResume(r) }, pin: edits && ok ? { onPin(r) } : nil,
                                 remove: edits && ok && !r.pinned ? { onRemove(r) } : nil,
                                 resumeNoMessage: quiet && ok ? { onResumeNoMessage(r) } : nil, older: asides.count,
                                 olderUnpinned: asides.filter { !$0.pinned }.count,
                                 // #743: statuses stay per record (--all lands on the one dch took); its own first.
                                 status: ([r] + asides).lazy.compactMap { store.historyActions[$0.id] }.first)
            // #908 (S5): offered only when no member of its group is live in its dir.
            if on && ok, let g = store.historyGroup(r, groups), g.live.isEmpty {
                d.resumeBoth = { onResumeGroup(r) }
                d.resumeBothTitle = AgentIsland.groupLabel(.resume, others: (g.mains + g.sidekicks).filter { $0.id != r.id }.map(\.name))
            }
            return d
        }
    }

    /// The line over the History rows: Resume interrupted (#585: only with a
    /// record it would take) and each dir's --all status, or the gate's reason
    /// in its place. Static text.
    private var historyHeader: some View {
        HStack(spacing: 10) {
            if case .refused(let why) = store.resumeGate {
                Text(verbatim: "Resume \(why)").foregroundStyle(Color.white.opacity(0.45))
                Spacer(minLength: 0)
            } else if store.confirmingClear {
                // #605: #580's inline question, same look; the count is live.
                let n = store.unpinnedCount
                Text(verbatim: AgentIsland.clearQuestion(n)).foregroundStyle(Neon.faded(.white, 0.8))
                Spacer(minLength: 0)
                lineButton("Clear") { onConfirmClear(true) }
                    .accessibilityLabel(Text(verbatim: "Clear \(n) unpinned"))
                lineButton("Cancel") { onConfirmClear(false) }
                    .accessibilityLabel(Text(verbatim: "Cancel Clear unpinned"))
            } else {
                if let label = store.resumeAllButton {
                    Button(action: onResumeAll) {
                        Text(verbatim: label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Neon.faded(.white, 0.9))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: AgentIsland.resumeAllHelp))
                    .accessibilityHint(Text(verbatim: AgentIsland.resumeAllHelp))
                    if store.reviveNoMessageGate.isOK {   // #669
                        Button(action: onResumeAllNoMessage) {
                            Text(verbatim: AgentIsland.resumeAllNoMessageLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(Neon.faded(.white, 0.6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(Text(verbatim: AgentIsland.resumeAllNoMessageAccessibility(store.resumableCount)))
                        .accessibilityLabel(Text(verbatim: AgentIsland.resumeAllNoMessageAccessibility(store.resumableCount)))
                    }
                }
                if let label = store.clearUnpinnedButton { lineButton(label, action: onClearUnpinned) }
                Text(verbatim: store.historyStatus).foregroundStyle(Neon.faded(.white, 0.6))
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, AgentIslandGeometry.rowLead)
        .frame(height: AgentIslandGeometry.historyHeaderHeight)
    }

    /// Count on the left of the notch, per-state counts on its right.
    private var header: some View {
        HStack(spacing: 0) {
            headerLeft
            Spacer(minLength: g.notchWidth + 8)
            headerRight
        }
        .padding(.horizontal, AgentIslandGeometry.headerPad)   // lines up with the row glyphs
    }

    /// QA #626 F1: the Agent Sessions button sits here, left of the notch: the
    /// right group has no room for it. Each group fits its half beside a 185 pt
    /// notch, (expandedWidth - notch) / 2 - headerPad (AgentIslandTests pins it).
    var headerLeft: some View {
        let total = store.summary.total
        return HStack(spacing: 8) {
            Text(total == 1 ? "1 session" : "\(total) sessions")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Neon.faded(.white, 0.9))
            agentsWindowButton   // #797
        }
    }

    var headerRight: some View {
        let s = store.summary
        // QA #626 F1: idle has no count here and the spacing is 6, else four
        // states (132 pt) overran the 118.5 pt right of a 185 pt notch.
        return HStack(spacing: 6) {
            ForEach(AgentState.allCases, id: \.self) { st in
                if st != .idle, let n = s.counts[st], n > 0 {
                    HStack(spacing: 3) {
                        Text(st.glyph).font(.system(size: 10, weight: .bold)).foregroundStyle(AgentIslandInk.glyph(st))
                        Text("\(n)").font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Neon.faded(.white, 0.7))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(n) \(st.label.lowercased())")
                }
            }
            controlsButton   // #579: at the right end, on every tab
        }
    }

    /// #571: "Sessions (n)  Sidekicks (n)", plain text buttons; the shown one bright.
    /// #578: "History (n)" after them; Sidekicks only when there are some.
    private var tabRow: some View {
        let split = store.split, history = store.historyTab
        let shows = AgentIsland.showsSidekicks(split, tab: store.sidekickTab)
        return HStack(spacing: 14) {
            if store.showsTabs {   // #1537: the row may be up for the plan usage alone
                tab("Sessions (\(split.primary.count))", on: !history && !shows) { onTab(false) }
                if !split.sidekicks.isEmpty {
                    tab("Sidekicks (\(split.sidekicks.count))", on: !history && shows) { onTab(true) }
                }
                if !store.history.isEmpty {
                    tab("History (\(store.cappedHistory.count))", on: history) { onHistory() }
                }
            }
            Spacer(minLength: 0)
            if let u = store.planUsage {   // #1537 (OQ-95): the plan's session and weekly limit, dim like the header counts
                let help = u.help()
                Text(verbatim: u.text)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Neon.faded(.white, 0.7))
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(Text(verbatim: help))
                    .help(Text(verbatim: help))
            }
        }
        .padding(.horizontal, AgentIslandGeometry.openRadii.top + 10)
    }

    private func tab(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? AgentIslandInk.selectedTab : Color.white.opacity(0.45))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// #578: one ended session. Line 1: the title (#592: alias, else the agent's
/// name, else the dch name) and how long ago it ended; line 2: the end in words
/// and the cwd, or the Resume status as static text. A click is Resume.
struct AgentIslandHistoryRow: View {
    let record: DchHistoryRecord
    let now: TimeInterval
    let status: String?
    let enabled: Bool
    let action: () -> Void
    /// #605: the pin toggle and the X (nil: not drawn); like the PR chips, buttons
    /// inside the row and, for VoiceOver, the row's actions.
    var pin: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    /// #669: Resume (no message), drawn before the pin; nil: not drawn.
    var resumeNoMessage: (() -> Void)? = nil
    /// #714, #743: the older records of this name folded into the row, its pin and X act on them too.
    var older = 0
    /// #716 L-2: the unpinned ones of `older`, the ones its X removes.
    var olderUnpinned = 0
    @State private var hover = false
    @ObservedObject private var theme = ThemeStore.shared   // #1375: a theme switch redraws the card

    /// QA #569 INFO-2: the row's tooltip and hint; "" on a refused row (the tooltip is then empty, never the Resume text).
    var helpText: String { enabled ? AgentIsland.resumeWithMessageHelp : "" }
    /// #1332 N937-c: the end text's tooltip: the whole (capped) sender command, which the label cuts at 48 characters,
    /// as outside text (OutsideText.shown); with no sender command the row's own tooltip, so the label's area keeps it.
    var endHelp: String { AgentIsland.signalSender(record.end)?.command.map { OutsideText.shown($0) } ?? helpText }
    var pinLabel: String { AgentIsland.editLabel(record.pinned ? AgentIsland.unpinLabel : AgentIsland.pinLabel, older: older) }
    var removeLabel: String { AgentIsland.removeEditLabel(older: older, unpinned: olderUnpinned) }

    var body: some View {
        let age = record.lastSeen > 0 ? AgentIsland.age(now - record.lastSeen) : ""
        let end = AgentIsland.endLabel(record.end)
        let cwd = (record.cwd as NSString).abbreviatingWithTildeInPath
        // #1375: the session row's card and the sidebar's inks (hover: its selected look and inks); #1452: off, the island's own.
        let sel = hover && enabled, ink = { (part: Part) in Self.ink(part, selected: sel) }
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: AgentIslandGeometry.glyphGap) {
                Text(verbatim: "○")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ink(.glyph))
                    .frame(width: AgentIslandGeometry.glyphWidth)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: record.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ink(.title))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(verbatim: age)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(ink(.age))
                            .fixedSize()
                        if enabled {   // #742: the row click's Resume, with dch's message, made visible
                            iconButton(AgentIsland.resumeWithMessageSymbol, ink: ink(.icon), label: AgentIsland.resumeWithMessageHelp, action: action)
                        }
                        if let resumeNoMessage {
                            iconButton(AgentIsland.resumeNoMessageSymbol, ink: ink(.icon), label: AgentIsland.resumeNoMessageLabel, action: resumeNoMessage)
                        }
                        if let pin { editControls(pin, ink: ink) }
                    }
                    HStack(spacing: 6) {
                        if let status {
                            Text(verbatim: status).foregroundStyle(ink(.status))
                        } else {
                            Text(verbatim: end)
                                // #585: only a crash is colored; "ended (signal 15)" stays neutral.
                                .foregroundStyle(ink(end.hasPrefix("crashed") ? .crash : .end))
                                // #839: a sender's program name can be long; the label truncates, cwd yields first.
                                .lineLimit(1).layoutPriority(1)
                                .help(Text(verbatim: endHelp))   // #1332 N937-c: the whole sender command
                            Text(verbatim: cwd)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(ink(.cwd))
                                .truncationMode(.middle)
                        }
                    }
                    .font(.system(size: 11))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, AgentIslandGeometry.rowLead)
            .padding(.trailing, AgentIslandGeometry.rowTrail)
            .frame(height: AgentIslandGeometry.rowHeight - AgentIslandGeometry.rowGap)
            .background(card(selected: sel))
            .contentShape(Rectangle())
            .padding(.vertical, AgentIslandGeometry.rowGap / 2)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(Text(verbatim: helpText))
        // A Resume status replaces line 2.
        .accessibilityLabel(AgentIsland.historyRowAccessibilityLabel(record, status: status, end: end, age: age, cwd: cwd))
        .accessibilityHint(helpText)
        .accessibilityActions {
            if let resumeNoMessage { Button(AgentIsland.resumeNoMessageLabel, action: resumeNoMessage) }
            if let pin { Button(pinLabel, action: pin) }
            if let remove { Button(removeLabel, action: remove) }
        }
    }

    /// The pin (filled while pinned) and the X; a pinned row keeps the X's room
    /// empty, so the pins line up. Static, in the age's ink; #1375: a pinned pin in the title's.
    private func editControls(_ pin: @escaping () -> Void, ink: (Part) -> Color) -> some View {
        HStack(spacing: 4) {
            iconButton(record.pinned ? "pin.fill" : "pin", ink: ink(record.pinned ? .pinned : .icon), label: pinLabel, action: pin)
            if let remove {
                iconButton("xmark", ink: ink(.icon), label: removeLabel, action: remove)
            } else {
                Color.clear.frame(width: Self.iconSize, height: Self.iconSize)
            }
        }
    }

    static let iconSize: CGFloat = 14

    /// #1452: the History row's parts by ink.
    enum Part: CaseIterable { case glyph, title, age, icon, pinned, status, end, crash, cwd }
    /// #1452: Follow theme on, #1375's inks (the sidebar's, hover its selected ones); off, the island's own white on black
    /// as before #1375 (hover changed only the card).
    static func ink(_ part: Part, selected sel: Bool) -> Color {
        guard AgentIslandInk.follows else {
            switch part {
            case .title: return Neon.faded(.white, 0.8)
            case .age: return Color.white.opacity(0.4)
            case .pinned: return Color.white.opacity(0.8)
            case .status: return Neon.faded(.white, 0.7)
            case .end: return Color.white.opacity(0.5)
            case .crash: return AgentState.blocked.color
            case .glyph, .icon, .cwd: return Color.white.opacity(0.35)
            }
        }
        switch part {
        case .title, .pinned: return Neon.textPrimary
        case .crash: return sel ? Neon.textPrimary : AgentIslandInk.blockedOnCard
        case .glyph, .age, .icon, .status, .end, .cwd: return AgentSidebarRowView.ink(.quiet, selected: sel)
        }
    }
    /// #1452: the card's fill when Follow theme is off (TIP before #1375: white over the island's black, brighter on hover).
    static func ownCardFill(selected: Bool) -> Color { Color.white.opacity(selected ? 0.10 : 0.05) }

    /// The card: on, #1375's session row card with the sidebar's selected fill; off, the island's own (#1452).
    @ViewBuilder private func card(selected sel: Bool) -> some View {
        if AgentIslandInk.follows {
            ZStack {
                RoundedRectangle(cornerRadius: sz(9), style: .continuous).fill(AgentIslandRow.cardFill)
                NeonSelectedRowFill(selected: sel)
            }
        } else {
            RoundedRectangle(cornerRadius: 12).fill(Self.ownCardFill(selected: sel))
        }
    }

    private func iconButton(_ symbol: String, ink: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: label))
        .accessibilityLabel(Text(verbatim: label))
    }
}

struct AgentIslandRow: View {
    let session: AgentSession
    let now: TimeInterval
    let notice: String?
    /// #534: the row details toggled on.
    var show: AgentIslandRowDetails
    /// #1536: the row the launcher command opened on; it wears the hover look until the island closes.
    var focused = false
    let action: () -> Void
    @State private var hover = false
    @ObservedObject private var theme = ThemeStore.shared   // #1375 (R1371-i2): a theme switch redraws the card

    var body: some View {
        let lit = hover || focused
        let prs = AgentIsland.prChips(session.meta, show: show)   // once per body
        let chipLine = AgentIslandGeometry.hasChipLine(session.meta, show: show)
        // #1371: the Agent Sessions sidebar row's own pieces (hover takes its selected look and inks).
        let side = AgentSidebarRowView(row: Self.sidebarRow(session, show: show, now: now, notice: notice), selected: lit,
                                       inks: Self.inks, show: show)
        Button(action: action) {
            // #1371: line 1 the state mark, the title, the model and effort badges; line 2 the state word, the agents,
            // merged and open counts, the age at the end; then the island's own PR chips. The text column stays
            // `rowTextWidth` at every scale (the chips' budget): fixed insets, the mark in the fixed glyph slot.
            HStack(alignment: .firstTextBaseline, spacing: AgentIslandGeometry.glyphGap) {
                side.stateMark
                    .frame(width: AgentIslandGeometry.glyphWidth)
                    .modifier(AgentSidebarRowProbe(kind: "mark", title: session.title))
                VStack(alignment: .leading, spacing: sz(3)) {
                    side.titleLine
                    ViewThatFits(in: .horizontal) {
                        side.detailLine([], open: side.row.prCount)
                        side.detailLine([])
                    }
                    if chipLine { prLineView(prs, selected: lit).modifier(AgentSidebarRowProbe(kind: "chips", title: session.title)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, AgentIslandGeometry.rowLead)
            .padding(.trailing, AgentIslandGeometry.rowTrail)
            .frame(height: (chipLine ? AgentIslandGeometry.prRowHeight : AgentIslandGeometry.rowHeight) - AgentIslandGeometry.rowGap)
            .coordinateSpace(.named(agentSidebarRowSpace))
            .background(NeonSelectedRowFill(selected: lit && AgentIslandInk.follows))
            .background(RoundedRectangle(cornerRadius: sz(9), style: .continuous).fill(Self.card(hover: lit)))
            .contentShape(Rectangle())
            .modifier(AgentSidebarRowProbe(kind: "card", title: session.title))
            .padding(.vertical, AgentIslandGeometry.rowGap / 2)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(Self.accessibilityLabel(session, now: now, show: show))
        .accessibilityActions {
            ForEach(Array(prs.chips.enumerated()), id: \.offset) { _, chip in
                if chip.url != nil {
                    Button { AgentIsland.open(chip) } label: { Text(verbatim: "Open \(chip.label)") }
                }
            }
        }
    }

    /// #1371: the card is the theme's sidebar surface, the one the Agent Sessions rows sit on (TIP: white at 0.05 over the
    /// island's black, 0.10 on hover). The island's black notch shape stays (#474).
    static var cardFill: Color { Neon.sidebar }
    /// #1452 b: the card drawn: on, `cardFill` (hover adds the sidebar's selected fill); off, the History row's own card.
    static func card(hover: Bool) -> Color { AgentIslandInk.follows ? cardFill : AgentIslandHistoryRow.ownCardFill(selected: hover) }
    /// #1452 b: on, nil (the sidebar's theme inks); off, the island's own, alike on every theme: the History row's off table's
    /// white (title 0.8, words, counts and age as its status 0.7, a glyph with no state 0.35), the needs-input amber, the
    /// state glyph in AgentState's colours, the open count and badges in the default (dark) palette. Hover changes only the card.
    static var inks: AgentSidebarRowView.Inks? {
        AgentIslandInk.follows ? nil
            : .init(primary: Neon.faded(.white, 0.8), quiet: Neon.faded(.white, 0.7), blue: ThemePalette.default.blue,
                    blocked: AgentState.blocked.color, mark: Neon.faded(.white, 0.35), badges: .default)
    }

    /// R1371-s1: the island's words, then what the row draws from the sidebar's Row, in its words: the model and effort
    /// (Row.modelWords) and the open count (Count.open, as Row.countWords; the agents and merged counts are spoken already).
    static func accessibilityLabel(_ s: AgentSession, now: TimeInterval, show: AgentIslandRowDetails) -> String {
        let row = AgentSidebar.row(s, details: show, now: now)
        return ([AgentIsland.rowAccessibilityLabel(s, now: now, show: show), show.modelWords(model: row.model, effort: row.effort)]
                + [row.prCount > 0 ? AgentSidebar.Count.open.words(row.prCount) : nil]).compactMap { $0 }.joined(separator: ", ")
    }

    /// #1371: the session as the Agent Sessions sidebar draws it; the island's notice ("Attach command copied", a
    /// running action) is the state word's text, as TIP drew it in place of the state.
    static func sidebarRow(_ s: AgentSession, show: AgentIslandRowDetails, now: TimeInterval, notice: String?) -> AgentSidebar.Row {
        let r = AgentSidebar.row(s, details: show, now: now)
        guard let notice else { return r }
        return AgentSidebar.Row(id: r.id, title: r.title, state: r.state, detail: notice, age: r.age, prs: r.prs,
                                prCount: r.prCount, prLinks: r.prLinks, agents: r.agents, merged: r.merged, shells: r.shells, session: r.session,
                                modelSlot: r.modelSlot, model: r.model, effort: r.effort)
    }

    /// #525: the PR line. Open PRs as "repo#12" chips in the agents capsule's
    /// style (a button when the URL passed the allowlist, else a dimmer label),
    /// "+N pending PRs" (#1371: the merged count is on line two now, in the sidebar's inks). `AgentIsland.prChips`
    /// measured it all to fit `rowTextWidth`. Static, no animation. `selected`: the row's hover, passed in, so a row
    /// can build the line with no view installed (no State read).
    func prLineView(_ prs: (chips: [AgentIsland.PRChip], more: Int), selected: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: AgentIsland.chipSpacing) {
                ForEach(Array(prs.chips.enumerated()), id: \.offset) { _, chip in
                    if chip.url != nil {
                        Button { AgentIsland.open(chip) } label: { chipText(chip.label, Self.chipInk(selected: selected), AgentSidebarRowView.prChipFill) }
                            .buttonStyle(.plain)
                            .help(Text(verbatim: chip.help))
                    } else {
                        chipText(chip.label, Self.chipInk(selected: selected), AgentSidebarRowView.prChipFill)
                            .help(Text(verbatim: chip.help))
                    }
                }
                if prs.more > 0 { chipText(AgentIsland.moreLabel(prs.more), Self.inks?.quiet ?? AgentSidebarRowView.ink(.quiet, selected: selected)) }
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    /// #1452 step 0: the island's PR chip ink. On, the chip sits on the theme's sidebar card (#1371), so the sidebar's readable
    /// amber: #FFB300 on a light theme's card reads 1.4 to 1.6:1. #1452 b: off, the card is the island's dark own, so the
    /// bright #FFB300 (AgentIslandFollowThemeTests).
    static func chipInk(selected: Bool) -> Color { inks?.blocked ?? AgentSidebarRowView.prChipInk(selected: selected) }

    private func chipText(_ s: String, _ color: Color, _ fill: Color? = nil) -> some View {
        Text(verbatim: s)
            .font(Font(AgentIslandGeometry.chipFont))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, AgentIsland.chipInset).padding(.vertical, 1)
            .background(Capsule().fill(fill ?? Neon.blue.opacity(0.12)))   // #1451: a PR chip's fill is the Needs input badge's; "+N" keeps #1371's wash
            .contentShape(Capsule())
    }
}

/// #1375: the island's inks follow the theme; its notch shape stays black (the operator's ruling, 2026-11-16). A theme
/// or state ink is drawn only where it reads on its surface (4.5:1, 3:1 for a dim cue or a mark), else the fallback: TIP's
/// white on the black shape, textPrimary on a themed card. AgentIslandThemeTests measures every ink on all 22 themes.
@MainActor
enum AgentIslandInk {
    /// #1452: Settings > Agent Island > Follow theme, off by default. The one switch: off, every ink #1375 themed is the
    /// island's own again (TIP before #1375); a change redraws the island as a theme switch does (ThemeStore publishes).
    static var follows: Bool { Preferences.agentIslandFollowsTheme }
    static func readable(_ ink: Color, on surface: Color, else fallback: Color, dim: Bool = false) -> Color {
        ThemeRuntime.contrastRatio(ink, surface) >= (dim ? 3 : 4.5) ? ink : fallback
    }
    /// The shown tab on the black shape: the theme's accent, else TIP's white.
    static var selectedTab: Color { follows ? readable(Neon.blue, on: .black, else: Neon.faded(.white, 0.9)) : Neon.faded(.white, 0.9) }
    /// A state glyph on the black shape (a mark): the Agent Sessions state colour.
    static func glyph(_ s: AgentState) -> Color { follows ? readable(agentStateColor(s), on: .black, else: .white, dim: true) : s.color }
    /// The needs-input amber on a themed card (a crashed History row, the prompt's caption), else textPrimary.
    static var blockedOnCard: Color {
        follows ? readable(agentStateColor(.blocked), on: AgentIslandRow.cardFill, else: Neon.textPrimary) : AgentState.blocked.color
    }
}

/// #1137: a count as the Agent Sessions window draws it (AgentSidebar.Count's symbol plus the capped number), in the
/// island's fixed chip font; `AgentIsland.countWidth` measures exactly this. VoiceOver and the help read the words.
/// Never cut (fixedSize).
struct AgentIslandCount: View {
    let kind: AgentSidebar.Count
    let n: Int

    var body: some View {
        HStack(spacing: AgentIsland.countGap) {
            Image(systemName: kind.symbol).frame(width: AgentIsland.symbolWidth(kind))
            Text(verbatim: AgentIsland.count(n))
        }
        .font(Font(AgentIslandGeometry.chipFont))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: kind.words(n)))
        .help(Text(verbatim: kind.words(n)))   // after the element: a help set on an ignored child never reaches AX
    }
}

/// #475 W1: the card's rows as drawn — hidden characters escaped, every row
/// measured with the card's font against its width — and the one rule for which
/// options may answer. The user may only approve what the card showed in full.
struct AgentCardLayout: Equatable {
    /// Question rows, wrapped.
    let question: [String]
    /// Context rows shown: all of them, or past `maxContext` the head plus "… N more lines".
    let context: [String]
    let isOverCap: Bool
    /// Per option: its label rows (more than one = it did not fit one row) and detail rows.
    let labels: [[String]]
    let details: [[String]]
    /// Non-deny options whose label or a detail line does not fit one row; a mode
    /// change is off anyway (`isModeChange`), so never here.
    let tooWide: Set<Int>
    let hidden: Bool
    /// #823: a plan approval (`AgentPlanForm.isPlan`): every row off, the Agents window or the
    /// terminal answers it (a digit on the feedback row is typed into it; "No, keep planning"
    /// with no feedback does nothing in Claude Code 2.1.318).
    let isPlan: Bool
    /// #526: a preview form's preview rows as drawn (hidden characters escaped,
    /// clipped with "…" below the floor, capped at `maxContext` plus "… N more
    /// lines"), all in `previewFont`, `previewLine` tall each. Empty without one.
    let preview: [String]
    let previewFont: CTFont
    let previewLine: CGFloat
    /// Why approve is off, wrapped; empty when nothing is.
    let caption: [String]

    /// The preview's font size: the context size when the widest row fits,
    /// else smaller in `previewStep` steps down to `previewFloor`.
    static let previewStep: CGFloat = 0.25
    static let previewFloor: CGFloat = 7

    static let previewCaption = "Previews are answered in the terminal"
    static let planCaption = "Plans are answered in the Agent Sessions window or the terminal"
    static let tooLongCaption = "Too long to show in full, open the terminal to approve"
    static let hiddenCaption = "Hidden characters in this prompt, open the terminal to approve"
    static let offTopCaption = "The top of this prompt is off screen, open the terminal to approve"
    static let modeCaption = "Mode changes are made in the terminal"

    private typealias G = AgentIslandGeometry

    init(_ p: AgentPrompt, cache: AgentCardLayoutCache = .shared) {
        question = G.wrap(AgentPrompt.visible(p.question), G.questionFont, G.cardInner, words: true)
        let (rows, overCap) = Self.contextRows(p.context, in: cache)
        // No dialog top found: the head may be off screen, so not shown in full either.
        (context, isOverCap) = (rows, overCap || !p.topFound)
        var labels: [[String]] = [], details: [[String]] = [], tooWide: Set<Int> = []
        for o in p.options {
            let label = AgentPrompt.visible(o.label), detail = o.detail.map(AgentPrompt.visible)
            let lw = Self.labelWidth(o), dw = Self.detailWidth(o)
            labels.append(G.wrap(label, G.labelFont, lw))
            details.append(detail.flatMap { G.wrap($0, G.detailFont, dw) })
            let fits = G.fits(label, G.labelFont, lw) && detail.allSatisfy { G.fits($0, G.detailFont, dw) }
            if !fits, o.style(first: false) != .deny, !o.isModeChange { tooWide.insert(o.digit) }
        }
        (self.labels, self.details, self.tooWide) = (labels, details, tooWide)
        hidden = p.hasHiddenCharacters
        isPlan = AgentPlanForm.isPlan(p)
        (preview, previewFont) = Self.previewRows(p.preview)
        previewLine = (CTFontGetAscent(previewFont) + CTFontGetDescent(previewFont) + CTFontGetLeading(previewFont))
            .rounded(.up)
        // Several apply: hidden characters win, then the off-screen top, then a
        // preview form, then a plan, then too long, then a mode change.
        let why = hidden ? Self.hiddenCaption : !p.topFound ? Self.offTopCaption
            : !p.preview.isEmpty ? Self.previewCaption : isPlan ? Self.planCaption
            : (isOverCap || !tooWide.isEmpty) ? Self.tooLongCaption
            : p.options.contains(where: { $0.isModeChange && $0.style(first: false) != .deny }) ? Self.modeCaption : nil
        caption = why.map { G.wrap($0, G.questionFont, G.cardInner) } ?? []
    }

    /// The one rule (W1 item 6): the card's buttons and `AgentPrompt.answer` both
    /// ask this. A "No…" option is always on, a mode change always off (OQ-45).
    /// A preview form is all off, "No…" too: there a digit only moves the focus (#526).
    /// #823: so is a plan approval. #818: "Chat about this" is always off: Claude Code draws it
    /// outside the form's numbered rows, so its digit is no answer (the Agents window walks to it).
    func isEnabled(_ o: AgentPromptOption) -> Bool {
        preview.isEmpty && !isPlan && AgentPlanForm.flat(o.label) != "Chataboutthis"
            && (o.style(first: false) == .deny || !(isOverCap || hidden || tooWide.contains(o.digit) || o.isModeChange))
    }

    /// One font for the whole preview: `contextFont` when the widest row fits
    /// the context width, else the largest `previewStep` size that fits, never
    /// under `previewFloor`; a row still too wide there ends in "…" (never
    /// wraps). A CoreText copy, so the controller queue may build it.
    static func previewRows(_ lines: [String]) -> (rows: [String], font: CTFont) {
        let rows = lines.map(AgentPrompt.visible), w = G.cardContextWidth
        let widest = rows.max { G.width($0, G.contextFont) < G.width($1, G.contextFont) } ?? ""
        var size = CTFontGetSize(G.contextFont)
        let font = { (s: CGFloat) in CTFontCreateCopyWithAttributes(G.contextFont, s, nil, nil) }
        while size > previewFloor, !G.fits(widest, font(size), w) { size -= previewStep }
        let f = size == CTFontGetSize(G.contextFont) ? G.contextFont : font(size)
        let dots = G.width("…", f)
        let clipped = rows.map { G.fits($0, f, w) ? $0 : G.wrap($0, f, w - dots)[0] + "…" }
        // #529: one row over draws in the marker's place (a preview approves
        // nothing, so no cap ruling applies), so a marker hides 2 or more.
        let cap = AgentPrompt.maxContext
        guard clipped.count > cap + 1 else { return (clipped, f) }
        return (Array(clipped.prefix(cap)) + ["… \(clipped.count - cap) more lines"], f)
    }

    /// Lines wrapped into measured rows, then capped at `maxContext` rows (cached).
    /// `words`: the context-only card (a screen tail, #574) breaks at spaces;
    /// a prompt's own context keeps the character wrap (W1: every character
    /// of what may be approved is shown where the screen has it).
    static func contextRows(_ lines: [String], words: Bool = false,
                            in cache: AgentCardLayoutCache = .shared) -> (rows: [String], overCap: Bool) {
        cache.get(words ? \.tails : \.contexts, lines) { measuredContextRows(lines, words: words) }
    }

    private static func measuredContextRows(_ lines: [String], words: Bool) -> (rows: [String], overCap: Bool) {
        let rows = lines.flatMap { G.wrap(AgentPrompt.visible($0), G.contextFont, G.cardContextWidth, words: words) }
        // The cap stays at 10 rows (OQ-46): an 11th row is over it, so deny-only.
        let cap = AgentPrompt.maxContext, n = rows.count - cap
        guard n > 0 else { return (rows, false) }
        return (Array(rows.prefix(cap)) + ["… \(n) more line\(n == 1 ? "" : "s")"], true)
    }

    /// What is left for the label beside the digit, the minimum spacer and the hint capsule.
    static func labelWidth(_ o: AgentPromptOption) -> CGFloat {
        detailWidth(o) - G.cardSpacing - G.cardSpacerMin
            - (o.hint.map { G.cardSpacing + G.width($0, G.hintFont) + 2 * G.hintInset } ?? 0)
    }

    /// The column right of the digit.
    static func detailWidth(_ o: AgentPromptOption) -> CGFloat {
        G.cardButtonInner - G.width("\(o.digit)", G.digitFont) - G.cardSpacing
    }
}

/// W1-perf: measured layouts by content. The island re-renders every second and
/// asks for a card's layout ~5 times per render; measuring costs ms, hashing µs.
/// The controller queue warms it and main reads it, so it is lock-protected.
/// Keyed on the content alone: every width and font the layout uses is a
/// compile-time constant, so nothing goes stale inside one process. A constant
/// that becomes runtime-variable (a UI scale, a user font) must join the key.
/// Bound: `bound` entries per table, then cleared whole (no LRU; a screen holds a
/// few prompts). Lookup under the lock, measure without it, store under it.
final class AgentCardLayoutCache: @unchecked Sendable {
    static let shared = AgentCardLayoutCache()
    static let bound = 32

    private let lock = NSLock()
    private var built = 0
    fileprivate var layouts: [AgentPrompt: AgentCardLayout] = [:]
    fileprivate var contexts: [[String]: (rows: [String], overCap: Bool)] = [:]
    /// Word-wrapped context rows (`contextRows(words: true)`), apart from `contexts`.
    fileprivate var tails: [[String]: (rows: [String], overCap: Bool)] = [:]

    var count: Int { lock.withLock { layouts.count + contexts.count + tails.count } }
    func removeAll() { lock.withLock { layouts.removeAll(); contexts.removeAll(); tails.removeAll() } }
    /// Layouts and context rows this instance measured (misses), for the tests.
    var builds: Int { lock.withLock { built } }

    /// Measured outside the lock: two threads missing at once both measure, same result.
    fileprivate func get<K: Hashable, V>(_ table: ReferenceWritableKeyPath<AgentCardLayoutCache, [K: V]>,
                                         _ key: K, _ make: () -> V) -> V {
        if let v = lock.withLock({ self[keyPath: table][key] }) { return v }
        let v = make()
        lock.withLock {
            if self[keyPath: table].count >= Self.bound { self[keyPath: table].removeAll() }
            self[keyPath: table][key] = v
            built += 1
        }
        return v
    }
}

extension AgentPrompt {
    var layout: AgentCardLayout { layout(in: .shared) }
    func layout(in cache: AgentCardLayoutCache) -> AgentCardLayout {
        cache.get(\.layouts, self) { AgentCardLayout(self, cache: cache) }
    }
    var isOverCap: Bool { layout.isOverCap }
    var shownContext: [String] { layout.context }
    /// The card's rule; `answer` checks it too, so a disabled option never sends.
    func isEnabled(_ o: AgentPromptOption) -> Bool { layout.isEnabled(o) }
}

/// #475: what a blocked session asks, under its row. Every row has the fixed
/// height `AgentIslandGeometry.cardHeight` counts and text measured to fit its
/// width, so the island grows by exactly the card and nothing is cut off.
struct AgentPromptCardView: View {
    let card: AgentCard
    var onOption: (AgentPrompt, AgentPromptOption) -> Void = { _, _ in }
    var onJump: () -> Void = {}

    private typealias G = AgentIslandGeometry
    @ObservedObject private var theme = ThemeStore.shared   // #1375: a theme switch redraws the card

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch card {
            case .prompt(let p):
                let l = p.layout
                rows(l.question) { line($0, Self.questionInk) }
                context(l.context)
                context(l.preview, l.previewFont, l.previewLine)
                rows(l.caption) { line($0, AgentIslandInk.blockedOnCard) }
                ForEach(Array(p.options.enumerated()), id: \.offset) { i, o in
                    option(p, o, label: l.labels[i], detail: l.details[i], enabled: l.isEnabled(o),
                           style: o.style(first: i == 0))
                }
                jump
            case .context(let lines):
                context(AgentCardLayout.contextRows(lines, words: true).rows)
                jump
            case .changed:
                line(Self.changedText, AgentIslandInk.blockedOnCard)
                jump
            }
        }
        .padding(G.cardPad)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: G.cardHeight(card) - G.cardGap, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(Self.cardFill))   // #1375: the session row's card (#1452: when on)
        .padding(.bottom, G.cardGap)
    }

    /// #1452: with Follow theme off (`AgentIslandInk.follows`) every ink below is TIP's before #1375, white on the black shape.
    static var cardFill: Color { AgentIslandInk.follows ? AgentIslandRow.cardFill : Color.white.opacity(0.05) }
    static var questionInk: Color { AgentIslandInk.follows ? Neon.textPrimary : Color.white }
    static var contextInk: Color { AgentIslandInk.follows ? Neon.textSecondary : Neon.faded(.white, 0.6) }
    static var jumpInk: Color { AgentIslandInk.follows ? Neon.textPrimary : Neon.faded(.white, 0.7) }
    /// #1452: TIP's answer colours before #1375 (the working orange, a red deny).
    static let ownAccent = AgentState.working.color
    static let ownDeny = Color(red: 0.95, green: 0.4, blue: 0.4)
    /// #1375: the answer buttons' fill, label and dim ink (digit, hint, detail) by style, from the theme: the accent fill
    /// with bgTop (the sidebar's digit chip pair), the danger tint with textPrimary, the plain wash with the sidebar inks.
    /// #1452: off, TIP's: the dim ink is the digit's (the label's at 0.7).
    static func look(_ style: AgentPromptOption.Style) -> (fill: Color, text: Color, dim: Color) {
        guard AgentIslandInk.follows else {
            let (fill, text): (Color, Color) = switch style {
            case .accent: (ownAccent, Color.white)
            case .deny: (ownDeny.opacity(0.18), ownDeny)
            case .plain: (Color.white.opacity(0.08), Neon.faded(.white, 0.9))
            }
            return (fill, text, Neon.faded(text, 0.7))
        }
        return switch style {
        case .accent: (Neon.blue, Neon.bgTop, Neon.bgTop)
        case .deny: (Neon.magenta.opacity(0.18), Neon.textPrimary, Neon.textSecondary)
        case .plain: (Self.wash, Neon.textPrimary, Neon.textSecondary)
        }
    }
    /// #1377: the detail lines are words read to choose an answer: the label's ink (4.5:1 on every theme), not dim (3:1).
    /// #1452: off, TIP's dim detail (the label's at 0.55).
    static func detailInk(_ style: AgentPromptOption.Style) -> Color {
        AgentIslandInk.follows ? look(style).text : Neon.faded(look(style).text, 0.55)
    }
    /// The hint's ink: the dim one; #1452: off, TIP's (the label's at 0.6).
    static func hintInk(_ style: AgentPromptOption.Style) -> Color {
        AgentIslandInk.follows ? look(style).dim : Neon.faded(look(style).text, 0.6)
    }
    static var wash: Color { (AgentIslandInk.follows ? Neon.textPrimary : Color.white).opacity(0.08) }
    static var contextFill: Color { (AgentIslandInk.follows ? Neon.textPrimary : Color.white).opacity(0.04) }
    static var hintFill: Color { (AgentIslandInk.follows ? Neon.textPrimary : Color.white).opacity(0.1) }

    static let changedText = "Prompt changed, open the terminal"
    static let jumpText = "Open terminal"

    private func rows<V: View>(_ rows: [String], @ViewBuilder _ row: @escaping (String) -> V) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in row(r) }
    }

    /// W1e: every Text the card draws goes through here with the CTFont its
    /// layout measured it with; `textHook` lets a test see each (text, font).
    @MainActor static var textHook: ((String, CTFont) -> Void)?

    private func cardText(_ s: String, _ f: CTFont) -> Text {
        Self.textHook?(s, f)
        return Text(s).font(Font(f))
    }

    private func line(_ text: String, _ color: Color) -> some View {
        cardText(text, G.questionFont)
            .foregroundStyle(color)
            .lineLimit(1)
            .agentCardSlot(height: G.cardQuestion, alignment: .leading)
    }

    @ViewBuilder
    private func context(_ lines: [String], _ f: CTFont = G.contextFont,
                         _ height: CGFloat = G.cardContextLine) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                rows(lines) { l in
                    cardText(l, f)
                        .foregroundStyle(Self.contextInk)
                        .lineLimit(1)
                        .agentCardSlot(height: height, alignment: .leading)
                }
            }
            .padding(.vertical, G.cardContextPad)
            .padding(.horizontal, G.contextInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Self.contextFill))
            .padding(.bottom, G.cardContextGap)
        }
    }

    private func option(_ p: AgentPrompt, _ o: AgentPromptOption, label: [String], detail: [String],
                        enabled: Bool, style: AgentPromptOption.Style) -> some View {
        let (fill, text, dim) = Self.look(style)
        let row = G.cardButton - 4
        return button(action: { onOption(p, o) }, fill: fill,
                      height: row + CGFloat(label.count - 1) * G.cardLabelLine + CGFloat(detail.count) * G.cardDetailLine) {
            HStack(alignment: .top, spacing: G.cardSpacing) {
                cardText("\(o.digit)", G.digitFont)
                    .foregroundStyle(dim)
                    .frame(height: row)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: G.cardSpacing) {
                        cardText(label[0], G.labelFont)
                            .foregroundStyle(text)
                            .lineLimit(1)
                        Spacer(minLength: G.cardSpacerMin)
                        if let hint = o.hint {
                            cardText(hint, G.hintFont)
                                .foregroundStyle(Self.hintInk(style))
                                .padding(.horizontal, G.hintInset).padding(.vertical, 1)
                                .background(Capsule().fill(Self.hintFill))
                                .fixedSize()
                        }
                    }
                    .agentCardSlot(height: row)
                    // A too-wide label's rest (the option is off), shown in full.
                    rows(Array(label.dropFirst())) { r in
                        cardText(r, G.labelFont)
                            .foregroundStyle(text)
                            .lineLimit(1)
                            .agentCardSlot(height: G.cardLabelLine, alignment: .top)
                    }
                    // Continuation or description under the label, in the label's ink (#1377).
                    rows(detail) { d in
                        cardText(d, G.detailFont)
                            .foregroundStyle(Self.detailInk(style))
                            .lineLimit(1)
                            .agentCardSlot(height: G.cardDetailLine, alignment: .top)
                    }
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel((["Answer \(o.digit), \(AgentPrompt.visible(o.label))"] + o.detail.map(AgentPrompt.visible))
            .joined(separator: " "))
    }

    private var jump: some View {
        button(action: onJump, fill: Self.wash) {
            Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
            cardText(Self.jumpText, G.labelFont)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Self.jumpInk)
    }

    private func button<L: View>(action: @escaping () -> Void, fill: Color, height: CGFloat = G.cardButton - 4,
                                 @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: G.cardSpacing) { label() }
                .padding(.horizontal, G.buttonInset)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 4)
    }
}

extension View {
    /// #1251: a permission card row in its fixed slot, clipped to it: no character's ink (a tall glyph, stacked
    /// marks) leaves its row. Clipping only bounds drawing: no frame, size or accessibility element changes.
    func agentCardSlot(height: CGFloat, alignment: Alignment = .center) -> some View {
        frame(height: height, alignment: alignment).clipped()
    }
}

/// #584: the one-line composer in the control line: the field, Send and Cancel. Enter sends, Esc
/// cancels, Send is off while the text (as sent) is empty. The panel is key while the island is open.
struct AgentIslandComposer: View {
    @ObservedObject var store: AgentIslandStore
    var onSend: () -> Void
    var onCancel: () -> Void
    @FocusState private var focused: Bool
    @ObservedObject private var theme = ThemeStore.shared   // #1375: a theme switch redraws the field

    var body: some View {
        let prompt = store.messagePrompt, empty = AgentIsland.messageText(store.messageDraft ?? "") == nil
        HStack(spacing: 10) {
            TextField(text: Binding(get: { store.messageDraft ?? "" }, set: { store.typeMessage($0) }),
                      prompt: AgentIslandInk.follows ? Text(verbatim: prompt).foregroundStyle(Neon.textSecondary) : Text(verbatim: prompt)) { Text(verbatim: prompt) }
                .textFieldStyle(.plain)
                .foregroundStyle(Self.draftInk)
                // #1375: the field is a themed card in the sidebar's inks; Send and Cancel stay on the black shape.
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Self.fieldFill))
                .focused($focused)
                .onSubmit(onSend)
                .onExitCommand(perform: onCancel)
                .accessibilityLabel(Text(verbatim: prompt))
            AgentIslandView.lineButton("Send", action: onSend)
                .disabled(empty)
                .opacity(empty ? 0.4 : 1)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: "Send message"))
            AgentIslandView.lineButton("Cancel", action: onCancel)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: "Cancel message"))
        }
        .onAppear { focused = true }
    }

    /// #1452: Follow theme on, #1375's themed field; off, TIP's white draft with no card (the placeholder in the system's ink).
    static var draftInk: Color { AgentIslandInk.follows ? Neon.textPrimary : Neon.faded(.white, 0.9) }
    static var fieldFill: Color { AgentIslandInk.follows ? AgentIslandRow.cardFill : .clear }
}
