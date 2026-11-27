import AppKit
import SwiftUI

/// #1417 (#1356 step 3, design 3.10, spec 5.6): a Refs row's card, shown through the window's XrayCardPresenter. The
/// header comes from the row at once; the four tabs fill from the --ref read (XrayPanels.runRef) as it lands.
/// #1760: snippets as inline Markdown (XrayRich: parsed once with the data, cleaned after the parse), selectable (drag,
/// Command-C copies the plain text); Mentions first; an inline filter under the tabs (Esc clears it, a second Esc closes
/// the card; the card's close cancels the read, XrayPanelModel.openRef). No Copy or Search button.
struct XrayRefPopover: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    enum Tab: String, CaseIterable { case mentions = "Mentions", definition = "Definition", tasks = "Tasks", memory = "Memory" }

    @ObservedObject var panel: XrayPanelModel
    let entry: XrayRefs.Entry
    let complete: Bool
    /// The pasteboard an extension card's Copy writes (Pasteboard.swift's; rows hand a scratch one).
    var pasteboard: NSPasteboard = Pasteboard.general
    /// #1760: Mentions first (it holds the most); an opener may pass another.
    @State var tab: Tab = .mentions
    /// #1760: the inline filter over the shown tab's rows (cached folds: nothing parsed per keystroke).
    @State var filter = ""
    @FocusState var filterFocused: Bool
    /// #1560: the Mentions tab's Other projects row, collapsed until clicked.
    @State var othersOpen = false
    /// #1569 (X7 c): an extension ref's card: the handler block in place of the tabs; nil: a dch ref's card.
    var ext: XrayExtensionCard? = nil
    @Environment(\.xrayCardBack) var back

    /// The context the card shows (#1931: always all of it; the unpinned guard went with the hover card).
    var context: XrayRefContext? { panel.refContext }

    /// #1760: 460x520, scaled (was 380x360): more rows at once; the presenter clamps it to the screen (XrayCardPanelPresenter.frame).
    static var size: CGSize { CGSize(width: sz(460), height: sz(520)) }

    /// The header lines, from the row before any --ref line: "Issue #831", its title, "2 mentions".
    static func header(_ e: XrayRefs.Entry, complete: Bool, home: String, cwd: String?) -> [String] {
        let row = XrayRefRow(e, complete: complete, home: home, cwd: cwd)
        return [XrayRefRow.kind(e.shape) + " " + row.text, row.title, "\(row.count) mention\(e.count == 1 ? "" : "s")"]
            .filter { !$0.isEmpty }
    }

    /// The Tasks tab's rows: the context's, which match the ref (XrayRefContext), never the panel's whole list.
    static func tasks(_ p: XrayPanelModel) -> [XrayTasks.Task] { p.refContext?.tasks ?? [] }

    /// A tab's count; nil before the read lands. #1760: `q` (a folded filter, query()): the rows that match it.
    static func count(_ t: Tab, _ p: XrayPanelModel, _ q: String = "") -> Int? {
        guard let c = p.refContext else { return nil }
        switch t {
        case .definition: return definitions(c, q).count
        case .mentions: return filtered(c.groups, q).reduce(0) { $0 + $1.mentions.count }   // at most dch's 4 MiB of lines
        case .tasks: return q.isEmpty ? tasks(p).count : taskRows(c, q).count
        case .memory: return memoryRows(c, q).count
        }
    }

    /// #1760: while filtering, each chip reads "Mentions 3/19" (matches of all).
    static func title(_ t: Tab, _ p: XrayPanelModel, _ q: String = "") -> String {
        guard let n = count(t, p) else { return t.rawValue }
        return q.isEmpty ? "\(t.rawValue) \(n)" : "\(t.rawValue) \(count(t, p, q) ?? 0)/\(n)"
    }
    static func spoken(_ t: Tab, _ p: XrayPanelModel, _ q: String = "") -> String {
        guard let n = count(t, p) else { return t.rawValue }
        return q.isEmpty ? "\(t.rawValue), \(n)" : "\(t.rawValue), \(count(t, p, q) ?? 0) of \(n)"
    }

    /// #1760: the filter as typed, folded once per keystroke (lowercased, outer spaces dropped).
    static func query(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }

    /// #1760: a mention matches on its snippet's cached fold (after Markdown and OutsideText), its session or its speaker.
    static func matches(_ m: XrayRefStream.Mention, _ q: String) -> Bool {
        q.isEmpty || m.fold.contains(q) || m.session.lowercased().contains(q) || speaker(m)?.lowercased().contains(q) == true
    }

    static func filtered(_ groups: [XrayRefContext.Group], _ q: String) -> [XrayRefContext.Group] {
        q.isEmpty ? groups : groups.compactMap { g in
            let ms = g.mentions.filter { matches($0, q) }
            return ms.isEmpty ? nil : XrayRefContext.Group(session: g.session, mentions: ms)
        }
    }

    /// The turn blocks that keep a match; a session's header moves to its first kept block.
    static func filtered(_ turns: [XrayRefContext.Turn], _ q: String) -> [XrayRefContext.Turn] {
        guard !q.isEmpty else { return turns }
        var out: [XrayRefContext.Turn] = []
        for var t in turns {
            t.mentions = t.mentions.filter { matches($0, q) }
            guard !t.mentions.isEmpty else { continue }
            t.opens = t.session != nil && out.last?.session != t.session
            out.append(t)
        }
        return out
    }

    static func definitions(_ c: XrayRefContext, _ q: String) -> [XrayRefStream.Definition] {
        q.isEmpty ? c.definitions : c.definitions.filter { [$0.title, $0.passage, $0.session].contains { $0.lowercased().contains(q) } }
    }

    /// #1760: each row with its runs ([] past XrayRefContext.richCap: drawn plain, matched on its title).
    static func taskRows(_ c: XrayRefContext, _ q: String) -> [(XrayTasks.Task, [XrayRich.Run])] {
        c.tasks.enumerated().map { ($0.element, $0.offset < c.taskRich.count ? c.taskRich[$0.offset] : []) }
            .filter { q.isEmpty || $0.0.id.lowercased().contains(q) || text($0.1, $0.0.title).contains(q) }
    }

    static func memoryRows(_ c: XrayRefContext, _ q: String) -> [(XrayMemory.Item, [XrayRich.Run])] {
        c.memory.enumerated().map { ($0.element, $0.offset < c.memoryRich.count ? c.memoryRich[$0.offset] : []) }
            .filter { q.isEmpty || ($0.0.kindWord ?? "memory").lowercased().contains(q) || text($0.1, $0.0.title).contains(q) }
    }

    static func text(_ runs: [XrayRich.Run], _ plain: String) -> String { runs.isEmpty ? plain.lowercased() : XrayRich.fold(runs) }

    /// #1760: Esc clears a filter first; on an empty one it closes the card.
    static func escape(_ filter: inout String, close: () -> Void) {
        if filter.isEmpty { close() } else { filter = "" }
    }

    /// What an empty tab reads.
    static func empty(_ t: Tab, ref: String) -> String {
        switch t {
        case .definition: XrayRefContext.noDefinition
        case .mentions: "No mentions of \(ref)"
        case .tasks: "No tasks mention \(ref)"
        case .memory: "No memories mention \(ref)"
        }
    }

    /// Open: a url ref re-checked as http/https with a host (OQ-164: a file ref gets Copy only).
    static func openURL(_ e: XrayRefs.Entry) -> URL? { XrayRefContext.openable(e.text, shape: e.shape) }

    func openLink() { if let u = Self.openURL(entry) { panel.openURL(u) } }

    /// #1944: a card opened from another card goes back to it; the first card closes.
    func escape() { Self.escape(&filter, close: back ?? panel.dismiss) }

    var body: some View {
        if let ext {
            XrayExtensionBlock(card: ext, panel: panel, entry: entry, pasteboard: pasteboard)
        } else {
            refBody
        }
    }

    @ViewBuilder var refBody: some View {
        let lines = Self.header(entry, complete: complete, home: panel.home, cwd: panel.cwd())
        let q = Self.query(filter)
        VStack(alignment: .leading, spacing: sz(10)) {
            HStack(alignment: .top, spacing: sz(4)) {
                XrayCardBackButton()   // #1944: opened from another card
                VStack(alignment: .leading, spacing: sz(3)) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(verbatim: l).font(i == 0 ? Neon.font(14, weight: .semibold) : Neon.font(11))
                            .foregroundStyle(i == 0 ? XrayInk.textPrimary : XrayInk.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(XrayRefRow(entry, complete: complete, home: panel.home, cwd: panel.cwd()).spoken)
            }
            strip
            filterField
            ScrollView {
                // #1760: lazy, so opening builds the rows on screen only (120 mentions: 150 ms eager at the first build)
                LazyVStack(alignment: .leading, spacing: sz(8)) { tabBody(q) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .modifier(AgentPaneProbe(kind: "xrayRefScroll"))   // tests only (#1816: the visible rect)
            hairline
            HStack(spacing: sz(8)) {
                if let c = context { footerRow(c) }
                Spacer(minLength: 0)
                if Self.openURL(entry) != nil {
                    Button("Open", action: openLink).buttonStyle(.neon).accessibilityLabel("Open \(entry.text)")
                }
            }
            if let n = panel.refNote { faint(n) }
        }
        .padding(sz(14))
        .frame(maxWidth: Self.size.width, maxHeight: Self.size.height, alignment: .topLeading)
        .onExitCommand(perform: escape)
        .onAppear { filterFocused = true }   // #1760: opened by a click or Return: type to filter
    }

    /// #1760: the inline filter; typing narrows the shown tab and never closes the card; Esc clears it first.
    var filterField: some View {
        HStack(spacing: sz(6)) {
            Image(systemName: "line.3.horizontal.decrease").font(Neon.font(10.5)).foregroundStyle(XrayInk.textSecondary)
                .accessibilityHidden(true)
            TextField("Filter", text: $filter).textFieldStyle(.plain).font(Neon.font(12)).foregroundStyle(XrayInk.textPrimary)
                .focused($filterFocused)
                .onKeyPress(.escape) { escape(); return .handled }
                .accessibilityLabel("Filter this card")
        }
        .padding(.horizontal, sz(8)).padding(.vertical, sz(5))
        .background(RoundedRectangle(cornerRadius: sz(7), style: .continuous).fill(XrayInk.card))   // #2041: the island's inner card
        .overlay(RoundedRectangle(cornerRadius: sz(7), style: .continuous).strokeBorder(XrayInk.stroke, lineWidth: 1))
    }

    var hairline: some View { Rectangle().fill(XrayInk.stroke).frame(height: 1).accessibilityHidden(true) }

    static let searching = "searching more\u{2026}"
    static let clickForAll = "click for all"

    /// #1567 (spec 5.6, dch README v1.99.0:1678-1683, :1744-1747): the footer slots. The session's count, the other sessions' ("9 in 3 others": dch's
    /// project count, its project_sessions; none at 0 sessions, README :1683), "searching more…" while no done line
    /// came, and a light read that ended partial "≥N · click for all" (N: this session's and the others'). "≥" while partial.
    static func footer(_ c: XrayRefContext) -> [String] {
        let ge = c.partial ? "\u{2265}" : ""
        var out: [String] = []
        if let n = c.rawCounts {
            out.append("This session \(ge)\(n.session)")   // #1641: a label, not "≥9 session"
            if n.projectSessions > 0 { out.append("\(ge)\(n.project) in \(n.projectSessions) others") }
        }
        if !c.done || c.more {   // #1824: a light answer while the full read runs
            out.append(searching)
        } else if c.light, c.partial, let n = c.rawCounts {   // the parse bounds each count to Int32.max: no overflow
            out.append("\u{2265}\(n.session + n.project) \u{00B7} \(clickForAll)")
        }
        return out
    }

    /// #1567: the footer in one faint line.
    @ViewBuilder func footerRow(_ c: XrayRefContext) -> some View {
        HStack(spacing: sz(8)) {
            ForEach(Self.footer(c), id: \.self) { s in faint(s) }
        }
        .accessibilityElement(children: .contain)
    }

    /// The #821 capsule strip, as the panel's: a tab group for VoiceOver, the shown tab selected.
    var strip: some View {
        let q = Self.query(filter)
        return HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Text(verbatim: Self.title(t, panel, q))
                        .font(Neon.font(11, weight: .medium))
                        .foregroundStyle(t == tab ? XrayInk.textPrimary : XrayInk.textSecondary)
                        .padding(.horizontal, sz(9)).padding(.vertical, sz(4))
                        .background(Capsule().fill(t == tab ? XrayInk.accentRing.opacity(0.2) : .clear))   // #2049: the card panel's XrayInk.surface
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.spoken(t, panel, q))
                .accessibilityAddTraits(t == tab ? .isSelected : [])
            }
        }
        .padding(sz(2))
        .overlay(Capsule().stroke(XrayInk.stroke, lineWidth: 1))
        .fixedSize()
        .modifier(AgentPaneProbe(kind: "xrayRefTabs"))   // tests only (nil probe: nothing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ref tabs")
    }

    @ViewBuilder func tabBody(_ q: String) -> some View {
        if let c = context {
            switch tab {
            case .definition: definition(c, q)
            case .mentions: mentions(c, q)
            case .tasks:
                let rows = Self.taskRows(c, q)
                if rows.isEmpty { faint(q.isEmpty ? Self.empty(.tasks, ref: entry.text) : Self.noMatch) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in richField(r.0.id, r.1, plain: r.0.title, q) }
            case .memory:
                let rows = Self.memoryRows(c, q)
                if rows.isEmpty { faint(q.isEmpty ? Self.empty(.memory, ref: entry.text) : Self.noMatch) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in richField(r.0.kindWord ?? "memory", r.1, plain: r.0.title, q) }
            }
        } else if panel.refNote == nil {
            faint("Reading\u{2026}")
        }
    }

    static let noMatch = "Nothing matches the filter"

    @ViewBuilder func definition(_ c: XrayRefContext, _ q: String) -> some View {
        faint(c.heading)
        if q.isEmpty, let r = c.resolved { field(r.kind, Self.resolvedText(r)) }
        ForEach(Array(Self.definitions(c, q).enumerated()), id: \.offset) { _, d in
            field(Self.label(d) + (d.mark.map { " \u{00B7} " + $0 } ?? ""),
                  ([d.passage] + [d.url, d.status].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        if let m = c.firstMention, Self.matches(m, q) {
            // the sentence's runs when the sentence is what #1641 shows, else the line plain
            if m.sentence != nil, Self.firstMentionText(m) != m.line {
                richField("First mention", m.rich, plain: Self.firstMentionText(m), q)
            } else {
                field("First mention", Self.firstMentionText(m))
            }
        }
    }

    /// #1560: the resolver block: `ok`'s title, subtitle and lines as before; any other state its one plain line alone
    /// (an ended session ran no git: nothing of git's is drawn).
    static func resolvedText(_ r: XrayRefStream.Resolved) -> String {
        XrayRefContext.stateLine(r) ?? ([r.title, r.subtitle] + r.lines).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// #1560: "Other projects (N)" from the snapshot's other_projects; nil (no row) at 0.
    static func othersTitle(_ p: XrayPanelModel) -> String? {
        (p.refs?.otherProjects ?? 0) > 0 ? "Other projects (\(p.refs?.otherProjects ?? 0))" : nil
    }

    /// A term's one definition is dch's first mention (rule "term"); any other keeps its title.
    static func label(_ d: XrayRefStream.Definition) -> String { d.rule == "term" ? "First mention" : d.title }

    @ViewBuilder func mentions(_ c: XrayRefContext, _ q: String) -> some View {
        // #1760: the session's and project's counts are the footer's; only the All projects line stays here
        ForEach(c.counts.filter { $0.hasPrefix(XrayRefContext.othersCountPrefix) }, id: \.self) { faint($0) }
        if c.groups.isEmpty { faint(Self.empty(.mentions, ref: entry.text)) }
        if let turns = c.turns {
            let shown = Self.filtered(turns, q)
            if shown.isEmpty, !c.groups.isEmpty { faint(Self.noMatch) }
            ForEach(Self.keyed(shown, part: 0), id: \.id) { r in
                let (i, t) = (r.id.row, r.e)
                if i > 0 { hairline.padding(.vertical, sz(2)) }
                if let s = Self.sessionHeader(t, now: panel.now()) {   // #1589: another session of this project
                    Text(verbatim: s).font(Neon.font(11, weight: .semibold)).foregroundStyle(XrayInk.textPrimary).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                }
                let head = Self.turnHeader(t, chapters: panel.chapters, now: panel.now())
                let label = Text(verbatim: head).font(Neon.font(10.5, weight: .semibold)).foregroundStyle(XrayInk.textSecondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if panel.turnChapter(t) != nil {   // #1900: a header with no chapter is plain text, never a no-op button
                    Button { panel.jumpTurn(t, in: c) } label: { label.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .help(Self.openChapter)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel(head)
                        .accessibilityHint(Self.openChapter)
                } else {
                    label.accessibilityAddTraits(.isHeader).accessibilityLabel(head)
                }
                ForEach(Self.keyed(t.mentions, part: 0, block: i), id: \.id) { mentionRow($0.e, c, q) }
            }
        } else {
            flatMentions(Self.filtered(c.groups, q), c, q, part: 1)
        }
        if q.isEmpty, let title = Self.othersTitle(panel) { others(title, c) }
    }

    /// #1900: the arrow's and the turn header's help and spoken hint.
    static let openChapter = "Open its chapter"

    /// #1760: a mention: the speaker as a small label, the snippet's runs at body size (selectable: drag, Command-C),
    /// and (#1900) an arrow only when the mention has a chapter to open (XrayPanelModel.mentionChapter): this session's,
    /// by its anchor or its turn. Another session's mention, or one with no chapter read yet, has no arrow.
    @ViewBuilder func mentionRow(_ m: XrayRefStream.Mention, _ c: XrayRefContext, _ q: String) -> some View {
        let opens = panel.mentionChapter(m, in: c) != nil
        HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
            if let s = Self.speaker(m) {
                Text(verbatim: s).font(Neon.font(9.5, weight: .semibold)).foregroundStyle(XrayInk.textSecondary)
                    .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
                    .background(Capsule().fill(XrayInk.textSecondary.opacity(0.12))).fixedSize()
                    .accessibilityHidden(Self.speakerHidden(opens: opens))
            }
            snippet(m.rich.isEmpty ? [XrayRich.Run(text: m.line)] : m.rich, q)
            if opens {
                Button { panel.jumpRef(m, in: c) } label: {
                    Image(systemName: "arrow.turn.down.right").font(Neon.font(10)).foregroundStyle(XrayInk.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.openChapter)
                .accessibilityLabel(Self.spokenRow(m))
                .accessibilityHint(Self.openChapter)
            }
        }
        .modifier(AgentPaneProbe(kind: "xrayRefRow:" + m.line))   // tests only (#1816: which rows are realized)
    }

    /// #1760: the house selectable snippet: the cached runs drawn, selection on (Command-C copies the plain text).
    static let selectable = true

    func snippet(_ runs: [XrayRich.Run], _ q: String) -> some View {
        Text(XrayRich.attributed(runs, size: 12, match: q))
            .lineSpacing(sz(2)).lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// #1560: the collapsed row; opening it runs the one `--scope all` read (XrayPanelModel.openOthers), then lists the
    /// sessions it added under its All projects line.
    @ViewBuilder func others(_ title: String, _ c: XrayRefContext) -> some View {
        Button {
            othersOpen.toggle()
            if othersOpen { panel.openOthers() }
        } label: {
            Text(verbatim: (othersOpen ? "\u{25BE} " : "\u{25B8} ") + title).font(Neon.font(10, weight: .semibold))
                .foregroundStyle(XrayInk.textSecondary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(othersOpen ? "expanded" : "collapsed")
        if othersOpen {
            if let o = c.others {
                if let n = c.othersCount { faint(n) }
                flatMentions(o, c, part: 2)
            } else if panel.refNote == nil {
                faint("Reading\u{2026}")
            }
        }
    }

    /// #1528: a turn block's header: "p3 · Fix login · 5m" (title from the chapters read, time of its newest mention);
    /// the trailing block "Earlier".
    /// #1589: another session's turn takes dch's turn_title, never this session's chapters.
    static func turnHeader(_ t: XrayRefContext.Turn, chapters: [TranscriptOutline.Chapter], now: Date) -> String {
        guard let n = t.turn else { return "Earlier" }
        let title = t.session == nil ? (chapters.last(where: { $0.ordinal == n })?.title ?? "") : (t.title ?? "")
        let age = XrayTaskRow.age(t.mentions.compactMap(\.at).max(), now: now)?.short ?? ""
        return ["p\(n)", OutsideText.shown(title, max: XrayRefs.titleCap), age].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// #1589 (dch #479): the header over another same-project session's block, "also discussed in api-qa, 2h" (its
    /// last_active, else its newest mention, as the turn headers' age); nil on every other turn.
    static func sessionHeader(_ t: XrayRefContext.Turn, now: Date) -> String? {
        guard t.opens, let name = t.session else { return nil }
        return XraySearch.alsoDiscussed(name, at: t.lastActive ?? t.mentions.compactMap(\.at).max(), now: now)
    }

    /// #1528: who said it, dch's words to the card's (README "--ref": You, Reply or the tool); nil from an older dch.
    static func speaker(_ m: XrayRefStream.Mention) -> String? {
        switch m.who {
        case "user": "You"
        case "assistant": "Reply"
        case "tool": m.tool.flatMap { $0.isEmpty ? nil : $0 } ?? "Tool"
        default: nil
        }
    }

    /// #1528: the row: speaker, then the sentence with the ref standing out; the line when dch sent no sentence.
    static func sentenceText(_ m: XrayRefStream.Mention) -> Text {
        let lead = Text(verbatim: speaker(m).map { $0 + "  " } ?? "").foregroundColor(XrayInk.textSecondary)
        guard let s = m.sentence else { return lead + Text(verbatim: m.line) }
        return lead + Text(verbatim: s.before) + Text(verbatim: s.hit).fontWeight(.semibold).foregroundColor(XrayInk.accentInk)
            + Text(verbatim: s.after)
    }

    /// #1641: the first mention's text: dch's sentence when it holds more than the line (the line is cut at lineCap,
    /// the sentence at 400 bytes), else the line. dch bounds the sentence at the line's ends, so a heading line
    /// ("Decision for you (OQ-185):") shows only itself: nothing past it is sent, and nothing is made up here.
    static func firstMentionText(_ m: XrayRefStream.Mention) -> String {
        let said = m.sentence.map { $0.before + $0.hit + $0.after } ?? ""
        return said.count > m.line.count ? said : m.line
    }

    /// #1905: the arrow's label already speaks the speaker (spokenRow); a row with no arrow lets the capsule speak it.
    static func speakerHidden(opens: Bool) -> Bool { opens }

    static func spokenRow(_ m: XrayRefStream.Mention) -> String {
        let said = m.sentence.map { $0.before + $0.hit + $0.after } ?? m.line
        return (speaker(m).map { $0 + ": " } ?? "Mention: ") + said
    }

    /// Today's list (a dch before 1.100.0): per session, its header, a hairline between sessions, each mention's line.
    @ViewBuilder func flatMentions(_ groups: [XrayRefContext.Group], _ c: XrayRefContext, _ q: String = "", part: Int) -> some View {
        ForEach(Self.keyed(groups, part: part), id: \.id) { r in
            let (i, g) = (r.id.row, r.e)
            if i > 0 { hairline.padding(.vertical, sz(2)) }
            Text(verbatim: Self.groupTitle(g.session, own: c.session, target: panel.target)).font(Neon.font(10.5, weight: .semibold))
                .foregroundStyle(XrayInk.textSecondary).lineLimit(1).accessibilityAddTraits(.isHeader)
            ForEach(Self.keyed(g.mentions, part: part, block: i), id: \.id) { mentionRow($0.e, c, q) }
        }
    }

    /// #1816: a lazy row's id, unique in the whole stack (part: turns 0, flat groups 1, other projects 2; block -1 for a
    /// block itself). The LazyVStack keyed a nested ForEach's row by its own offset alone, so every block's row 0 shared
    /// one view: only the first drew, the rest stayed blank (their height kept) until the first scrolled away.
    struct RowID: Hashable { let part: Int, block: Int, row: Int }

    static func keyed<E>(_ xs: [E], part: Int, block: Int = -1) -> [(id: RowID, e: E)] {
        xs.enumerated().map { (RowID(part: part, block: block, row: $0.offset), $0.element) }
    }

    /// #1568 (4.5): a remote card's other-session group names its host ("example-host:api-qa"): those sessions are the
    /// host's, not this Mac's. A local card's, and the card's own session's, as dch sent it.
    /// shortcut: the host is the target name before its first ":"; a host holding ":" (IPv6) shows cut, key it by row if seen.
    static func groupTitle(_ session: String, own: String?, target: XrayTarget) -> String {
        guard target.dir == nil, session != own, let i = target.name.firstIndex(of: ":") else { return session }
        return OutsideText.shown(String(target.name[..<i])) + ":" + session
    }

    /// A labelled field: the label faint, the value plain text.
    func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: sz(2)) {
            Text(verbatim: label).font(Neon.font(10, weight: .medium)).foregroundStyle(XrayInk.textSecondary).lineLimit(1)
            Text(verbatim: value).font(Neon.font(12)).foregroundStyle(XrayInk.textPrimary).lineSpacing(sz(2))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    /// #1760: a labelled field whose value is cached Markdown runs.
    func richField(_ label: String, _ runs: [XrayRich.Run], plain: String, _ q: String) -> some View {
        VStack(alignment: .leading, spacing: sz(2)) {
            Text(verbatim: label).font(Neon.font(10, weight: .medium)).foregroundStyle(XrayInk.textSecondary).lineLimit(1)
            snippet(runs.isEmpty ? [XrayRich.Run(text: plain)] : runs, q)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(runs.isEmpty ? plain : runs.map(\.text).joined())")
    }

    func faint(_ s: String) -> some View {
        Text(verbatim: s).font(Neon.font(10, weight: .medium)).foregroundStyle(XrayInk.textSecondary).lineLimit(2)
    }
}

/// #1569 (X7 c, spec 5.6): an extension ref's card: the rule's label and the text, "Extension ref · not indexed" where a
/// dch ref's counts go, then the handler's block (title, subtitle, body) and its actions, which the host runs (open an
/// http(s) url, copy a text). No tab, no count, no dch read. Esc closes.
struct XrayExtensionBlock: View {
    @ObservedObject var liveTheme = ThemeStore.shared
    @ObservedObject var card: XrayExtensionCard
    let panel: XrayPanelModel
    let entry: XrayRefs.Entry
    let pasteboard: NSPasteboard

    static func header(_ e: XrayRefs.Entry) -> [String] { [e.title + " " + e.text, XrayExtensionRefs.notIndexed] }

    func run(_ a: XrayExtensionRefs.Action) {
        if let u = a.url { return panel.openURL(u) }
        if let c = a.copy {
            pasteboard.clearContents()
            pasteboard.setString(c, forType: .string)
        }
    }

    func copy() {
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    var body: some View {
        let lines = Self.header(entry)
        VStack(alignment: .leading, spacing: sz(8)) {
            VStack(alignment: .leading, spacing: sz(2)) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    Text(verbatim: l).font(i == 0 ? Neon.font(12, weight: .semibold) : Neon.font(10.5))
                        .foregroundStyle(i == 0 ? XrayInk.textPrimary : XrayInk.textSecondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(lines.joined(separator: ", "))
            ScrollView {
                VStack(alignment: .leading, spacing: sz(6)) { block }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: sz(8)) {
                if case .card(let c)? = card.outcome {
                    ForEach(Array(c.actions.enumerated()), id: \.offset) { _, a in
                        Button(a.label) { run(a) }.accessibilityLabel(a.label)
                    }
                }
                Button("Copy", action: copy).accessibilityLabel("Copy \(entry.text)")
            }
            .font(Neon.font(11))
        }
        .padding(sz(12))
        .frame(width: XrayRefPopover.size.width, height: XrayRefPopover.size.height, alignment: .topLeading)
        .onExitCommand(perform: panel.dismiss)
    }

    @ViewBuilder var block: some View {
        if case .card(let c)? = card.outcome {
            if !c.title.isEmpty { Text(verbatim: c.title).font(Neon.font(11.5, weight: .semibold)).foregroundStyle(XrayInk.textPrimary) }
            if !c.subtitle.isEmpty { Text(verbatim: c.subtitle).font(Neon.font(10.5)).foregroundStyle(XrayInk.textSecondary) }
            if !c.body.isEmpty {
                Text(verbatim: c.body).font(Neon.font(11)).foregroundStyle(XrayInk.textPrimary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        } else if let n = card.note {
            Text(verbatim: n).font(Neon.font(10, weight: .medium)).foregroundStyle(XrayInk.textSecondary).lineLimit(3)
        }
    }
}
