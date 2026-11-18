import AppKit
import SwiftUI

/// #1417 (#1356 step 3, design 3.10, spec 5.6): a Refs row's card, shown through the window's XrayCardPresenter. The
/// header comes from the row at once; the four tabs fill from the --ref read (XrayPanels.runRef) as it lands. Plain
/// text only (every string is outside data, cleaned by the parses), never Markdown. Esc closes; the card's close
/// cancels the read (XrayPanelModel.openRef).
struct XrayRefPopover: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    enum Tab: String, CaseIterable { case definition = "Definition", mentions = "Mentions", tasks = "Tasks", memory = "Memory" }

    @ObservedObject var panel: XrayPanelModel
    let entry: XrayRefs.Entry
    let complete: Bool
    /// The pasteboard Copy writes (Pasteboard.swift's; rows hand a scratch one).
    var pasteboard: NSPasteboard = Pasteboard.general
    @State var tab: Tab = .definition
    /// #1560: the Mentions tab's Other projects row, collapsed until clicked.
    @State var othersOpen = false
    /// #1565 (X-T b): the grid's hover that opened this card unpinned (Pin, the pointer on the card); nil: today's card.
    var hover: XrayHover? = nil
    /// #1569 (X7 c): an extension ref's card: the handler block in place of the tabs; nil: a dch ref's card.
    var ext: XrayExtensionCard? = nil

    /// #1565: the context as this card may show it: unpinned, XrayRefContext.guarded's (no other session's line; a shell's
    /// titles and counts alone); today's card all of it.
    var context: XrayRefContext? {
        panel.refContext.map { c in hover.map { c.guarded(pinned: false, shell: $0.shell) } ?? c }
    }

    /// #1565: Pin: the light read is killed and today's full card opens (XrayHover.pin).
    func pin() { hover?.pin() }

    /// OQ-164 not ruled: the memory card's 380x360, scaled.
    static var size: CGSize { CGSize(width: sz(380), height: sz(360)) }

    /// The header lines, from the row before any --ref line: "Issue #831", its title, "2 mentions".
    static func header(_ e: XrayRefs.Entry, complete: Bool, home: String, cwd: String?) -> [String] {
        let row = XrayRefRow(e, complete: complete, home: home, cwd: cwd)
        return [XrayRefRow.kind(e.shape) + " " + row.text, row.title, "\(row.count) mention\(e.count == 1 ? "" : "s")"]
            .filter { !$0.isEmpty }
    }

    /// The Tasks tab's rows: the context's, which match the ref (XrayRefContext), never the panel's whole list.
    static func tasks(_ p: XrayPanelModel) -> [XrayTasks.Task] { p.refContext?.tasks ?? [] }

    /// A tab's count; nil before the read lands.
    static func count(_ t: Tab, _ p: XrayPanelModel) -> Int? {
        guard let c = p.refContext else { return nil }
        switch t {
        case .definition: return c.definitions.count
        case .mentions: return c.groups.reduce(0) { $0 + $1.mentions.count }   // at most dch's 4 MiB of lines
        case .tasks: return tasks(p).count
        case .memory: return c.memory.count
        }
    }

    static func title(_ t: Tab, _ p: XrayPanelModel) -> String { count(t, p).map { "\(t.rawValue) \($0)" } ?? t.rawValue }
    static func spoken(_ t: Tab, _ p: XrayPanelModel) -> String { count(t, p).map { "\(t.rawValue), \($0)" } ?? t.rawValue }

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

    /// Search: only when the panel has a Search tab and dch would take the text.
    static func canSearch(_ p: XrayPanelModel, _ e: XrayRefs.Entry) -> Bool { p.searchable && DchCtl.searchOK(e.text) }

    func openLink() { if let u = Self.openURL(entry) { panel.openURL(u) } }

    func copy() {
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    /// The card closes and the panel lands on Search with the ref as the query (XrayPanelModel.searchRef).
    func search() { panel.searchRef(entry.text) }

    func escape() { panel.dismiss() }

    var body: some View {
        if let ext {
            XrayExtensionBlock(card: ext, panel: panel, entry: entry, hover: hover, pasteboard: pasteboard)
        } else {
            refBody
        }
    }

    @ViewBuilder var refBody: some View {
        let lines = Self.header(entry, complete: complete, home: panel.home, cwd: panel.cwd())
        VStack(alignment: .leading, spacing: sz(8)) {
            VStack(alignment: .leading, spacing: sz(2)) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    Text(verbatim: l).font(i == 0 ? Neon.font(12, weight: .semibold) : Neon.font(10.5))
                        .foregroundStyle(i == 0 ? Neon.textPrimary : Neon.textSecondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(XrayRefRow(entry, complete: complete, home: panel.home, cwd: panel.cwd()).spoken)
            strip
            ScrollView {
                VStack(alignment: .leading, spacing: sz(6)) { tabBody }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let c = context { footerRow(c) }
            if let n = panel.refNote { faint(n) }
            HStack(spacing: sz(8)) {
                if Self.openURL(entry) != nil { Button("Open", action: openLink).accessibilityLabel("Open \(entry.text)") }
                Button("Copy", action: copy).accessibilityLabel("Copy \(entry.text)")
                if Self.canSearch(panel, entry) {
                    Button("Search", action: search).accessibilityLabel("Search this session for \(entry.text)")
                }
                if hover != nil { Button("Pin", action: pin).accessibilityLabel("Pin the card for \(entry.text)") }
            }
            .font(Neon.font(11))
        }
        .padding(sz(12))
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .onExitCommand(perform: escape)
        .onHover { inside in hover?.onCard(inside) }   // #1565: the pointer on the card keeps it open
    }

    static let searching = "searching more\u{2026}"
    static let clickForAll = "click for all"

    /// #1567 (spec 5.6, dch README v1.99.0:1678-1683, :1744-1747): the footer slots. "N on screen" (the grid's marks of
    /// this ref: a hover card's, XrayHover.onScreen), the session's count, the other sessions' ("9 in 3 others": dch's
    /// project count, its project_sessions; none at 0 sessions, README :1683), "searching more…" while no done line
    /// came, and a light read that ended partial "≥N · click for all" (N: this session's and the others'). "≥" while partial.
    static func footer(_ c: XrayRefContext, onScreen: Int) -> [String] {
        let ge = c.partial ? "\u{2265}" : ""
        var out = onScreen > 0 ? ["\(onScreen) on screen"] : []
        if let n = c.rawCounts {
            out.append("\(ge)\(n.session) session")
            if n.projectSessions > 0 { out.append("\(ge)\(n.project) in \(n.projectSessions) others") }
        }
        if !c.done {
            out.append(searching)
        } else if c.light, c.partial, let n = c.rawCounts {   // the parse bounds each count to Int32.max: no overflow
            out.append("\u{2265}\(n.session + n.project) \u{00B7} \(clickForAll)")
        }
        return out
    }

    /// #1567: the footer in one faint line; a hover card's "click for all" pins it (today's full card).
    @ViewBuilder func footerRow(_ c: XrayRefContext) -> some View {
        let slots = Self.footer(c, onScreen: hover.map { $0.onScreen(entry.key) } ?? 0)
        HStack(spacing: sz(8)) {
            ForEach(slots, id: \.self) { s in
                if hover != nil, s.hasSuffix(Self.clickForAll) {
                    Button(action: pin) { Text(verbatim: s).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.blue) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pin the card for \(entry.text): \(s)")
                } else {
                    faint(s)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The #821 capsule strip, as the panel's: a tab group for VoiceOver, the shown tab selected.
    var strip: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Text(verbatim: Self.title(t, panel))
                        .font(Neon.font(10.5, weight: .medium))
                        .foregroundStyle(t == tab ? Neon.textPrimary : Neon.textSecondary)
                        .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
                        .background(Capsule().fill(t == tab ? Neon.blue.opacity(0.2) : .clear))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.spoken(t, panel))
                .accessibilityAddTraits(t == tab ? .isSelected : [])
            }
        }
        .padding(sz(2))
        .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
        .fixedSize()
        .modifier(AgentPaneProbe(kind: "xrayRefTabs"))   // tests only (nil probe: nothing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ref tabs")
    }

    @ViewBuilder var tabBody: some View {
        if let c = context {
            switch tab {
            case .definition: definition(c)
            case .mentions: mentions(c)
            case .tasks:
                if Self.tasks(panel).isEmpty { faint(Self.empty(.tasks, ref: entry.text)) }
                ForEach(Array(Self.tasks(panel).enumerated()), id: \.offset) { _, t in
                    field(t.id, t.title)
                }
            case .memory:
                if c.memory.isEmpty { faint(Self.empty(.memory, ref: entry.text)) }
                ForEach(Array(c.memory.enumerated()), id: \.offset) { _, m in
                    field(m.kindWord ?? "memory", m.title)
                }
            }
        } else if panel.refNote == nil {
            faint("Reading\u{2026}")
        }
    }

    @ViewBuilder func definition(_ c: XrayRefContext) -> some View {
        faint(c.heading)
        if let r = c.resolved { field(r.kind, Self.resolvedText(r)) }
        ForEach(Array(c.definitions.enumerated()), id: \.offset) { _, d in
            field(Self.label(d) + (d.mark.map { " \u{00B7} " + $0 } ?? ""),
                  ([d.passage] + [d.url, d.status].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        if let m = c.firstMention { field("First mention", m.line) }
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

    @ViewBuilder func mentions(_ c: XrayRefContext) -> some View {
        ForEach(c.counts, id: \.self) { faint($0) }
        if c.groups.isEmpty { faint(Self.empty(.mentions, ref: entry.text)) }
        if let turns = c.turns {
            ForEach(Array(turns.enumerated()), id: \.offset) { _, t in
                let head = Self.turnHeader(t, chapters: panel.chapters, now: panel.now())
                Button { panel.jumpTurn(t, in: c) } label: {
                    Text(verbatim: head).font(Neon.font(10, weight: .semibold)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(head)
                ForEach(Array(t.mentions.enumerated()), id: \.offset) { _, m in
                    Button { panel.jumpRef(m, in: c) } label: {
                        Self.sentenceText(m).font(Neon.font(11)).foregroundStyle(Neon.textPrimary).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.spokenRow(m))
                }
            }
        } else {
            flatMentions(c.groups, c)
        }
        if hover == nil, let title = Self.othersTitle(panel) { others(title, c) }   // #1565: unpinned, no other project
    }

    /// #1560: the collapsed row; opening it runs the one `--scope all` read (XrayPanelModel.openOthers), then lists the
    /// sessions it added under its All projects line.
    @ViewBuilder func others(_ title: String, _ c: XrayRefContext) -> some View {
        Button {
            othersOpen.toggle()
            if othersOpen { panel.openOthers() }
        } label: {
            Text(verbatim: (othersOpen ? "\u{25BE} " : "\u{25B8} ") + title).font(Neon.font(10, weight: .semibold))
                .foregroundStyle(Neon.textSecondary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(othersOpen ? "expanded" : "collapsed")
        if othersOpen {
            if let o = c.others {
                if let n = c.othersCount { faint(n) }
                flatMentions(o, c)
            } else if panel.refNote == nil {
                faint("Reading\u{2026}")
            }
        }
    }

    /// #1528: a turn block's header: "p3 · Fix login · 5m" (title from the chapters read, time of its newest mention);
    /// the trailing block "Earlier".
    static func turnHeader(_ t: XrayRefContext.Turn, chapters: [TranscriptOutline.Chapter], now: Date) -> String {
        guard let n = t.turn else { return "Earlier" }
        let title = chapters.last { $0.ordinal == n }?.title ?? ""
        let age = XrayTaskRow.age(t.mentions.compactMap(\.at).max(), now: now)?.short ?? ""
        return ["p\(n)", OutsideText.shown(title, max: XrayRefs.titleCap), age].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
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
        let lead = Text(verbatim: speaker(m).map { $0 + "  " } ?? "").foregroundColor(Neon.textSecondary)
        guard let s = m.sentence else { return lead + Text(verbatim: m.line) }
        return lead + Text(verbatim: s.before) + Text(verbatim: s.hit).fontWeight(.semibold).foregroundColor(Neon.blue)
            + Text(verbatim: s.after)
    }

    static func spokenRow(_ m: XrayRefStream.Mention) -> String {
        let said = m.sentence.map { $0.before + $0.hit + $0.after } ?? m.line
        return (speaker(m).map { $0 + ": " } ?? "Mention: ") + said
    }

    /// Today's list (a dch before 1.100.0): per session, each mention's line.
    @ViewBuilder func flatMentions(_ groups: [XrayRefContext.Group], _ c: XrayRefContext) -> some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
            faint(Self.groupTitle(g.session, own: c.session, target: panel.target)).accessibilityAddTraits(.isHeader)
            ForEach(Array(g.mentions.enumerated()), id: \.offset) { _, m in
                // Return or a click: this session's mention jumps (jumpRef); another session's does nothing
                Button { panel.jumpRef(m, in: c) } label: {
                    Text(verbatim: m.line).font(Neon.font(11)).foregroundStyle(Neon.textPrimary).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mention: \(m.line)")
            }
        }
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
        VStack(alignment: .leading, spacing: sz(1)) {
            Text(verbatim: label).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary).lineLimit(1)
            Text(verbatim: value).font(Neon.font(11)).foregroundStyle(Neon.textPrimary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    func faint(_ s: String) -> some View {
        Text(verbatim: s).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary).lineLimit(2)
    }
}

/// #1569 (X7 c, spec 5.6): an extension ref's card: the rule's label and the text, "Extension ref · not indexed" where a
/// dch ref's counts go, then the handler's block (title, subtitle, body) and its actions, which the host runs (open an
/// http(s) url, copy a text). No tab, no count, no dch read. Esc closes; on a hover card the pointer keeps it, Pin pins it.
struct XrayExtensionBlock: View {
    @ObservedObject var liveTheme = ThemeStore.shared
    @ObservedObject var card: XrayExtensionCard
    let panel: XrayPanelModel
    let entry: XrayRefs.Entry
    let hover: XrayHover?
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
                        .foregroundStyle(i == 0 ? Neon.textPrimary : Neon.textSecondary).lineLimit(1).truncationMode(.middle)
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
                if let hover { Button("Pin", action: hover.pin).accessibilityLabel("Pin the card for \(entry.text)") }
            }
            .font(Neon.font(11))
        }
        .padding(sz(12))
        .frame(width: XrayRefPopover.size.width, height: XrayRefPopover.size.height, alignment: .topLeading)
        .onExitCommand(perform: panel.dismiss)
        .onHover { inside in hover?.onCard(inside) }
    }

    @ViewBuilder var block: some View {
        if case .card(let c)? = card.outcome {
            if !c.title.isEmpty { Text(verbatim: c.title).font(Neon.font(11.5, weight: .semibold)).foregroundStyle(Neon.textPrimary) }
            if !c.subtitle.isEmpty { Text(verbatim: c.subtitle).font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary) }
            if !c.body.isEmpty {
                Text(verbatim: c.body).font(Neon.font(11)).foregroundStyle(Neon.textPrimary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        } else if let n = card.note {
            Text(verbatim: n).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary).lineLimit(3)
        }
    }
}
