import AppKit
import SwiftUI

/// #1417 (#1356 step 3, design 3.10, spec 5.6): a Refs row's card, shown through the window's XrayCardPresenter. The
/// header comes from the row at once; the four tabs fill from the --ref read (XrayPanels.runRef) as it lands. Plain
/// text only (every string is outside data, cleaned by the parses), never Markdown. Esc closes; the card's close
/// cancels the read (XrayPanelModel.openRef).
struct XrayRefPopover: View {
    enum Tab: String, CaseIterable { case definition = "Definition", mentions = "Mentions", tasks = "Tasks", memory = "Memory" }

    @ObservedObject var panel: XrayPanelModel
    let entry: XrayRefs.Entry
    let complete: Bool
    /// The pasteboard Copy writes (Pasteboard.swift's; rows hand a scratch one).
    var pasteboard: NSPasteboard = Pasteboard.general
    @State var tab: Tab = .definition

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
            if let n = panel.refNote { faint(n) }
            HStack(spacing: sz(8)) {
                if Self.openURL(entry) != nil { Button("Open", action: openLink).accessibilityLabel("Open \(entry.text)") }
                Button("Copy", action: copy).accessibilityLabel("Copy \(entry.text)")
                if Self.canSearch(panel, entry) {
                    Button("Search", action: search).accessibilityLabel("Search this session for \(entry.text)")
                }
            }
            .font(Neon.font(11))
        }
        .padding(sz(12))
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .onExitCommand(perform: escape)
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
        if let c = panel.refContext {
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
        if let r = c.resolved {
            field(r.kind, ([r.title, r.subtitle] + r.lines).filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        ForEach(Array(c.definitions.enumerated()), id: \.offset) { _, d in
            field(Self.label(d) + (d.mark.map { " \u{00B7} " + $0 } ?? ""),
                  ([d.passage] + [d.url, d.status].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        if let m = c.firstMention { field("First mention", m.line) }
    }

    /// A term's one definition is dch's first mention (rule "term"); any other keeps its title.
    static func label(_ d: XrayRefStream.Definition) -> String { d.rule == "term" ? "First mention" : d.title }

    @ViewBuilder func mentions(_ c: XrayRefContext) -> some View {
        ForEach(c.counts, id: \.self) { faint($0) }
        if c.groups.isEmpty { faint(Self.empty(.mentions, ref: entry.text)) }
        ForEach(Array(c.groups.enumerated()), id: \.offset) { _, g in
            faint(g.session).accessibilityAddTraits(.isHeader)
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
