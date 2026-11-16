import AppKit
import SwiftUI

// #1351 (#1346 P3a, design 3.1-3.9): the X-ray panel, a drawer over one pane (both modes; it overlays, so the terminal
// keeps its grid) with a tab strip in dch's order. Tasks is the first working tab; Memory shows its label and count
// (its content is P4). Read when the panel opens; #1368's poller (XrayPoller.swift) re-reads Tasks while it is shown.

/// The tabs in dch's order (xview.c xv_ord); later phases put Prompts, Responses, Refs and Search before these.
enum XrayTab: String, CaseIterable { case tasks = "Tasks", memory = "Memory" }

/// The session a read names: a local one by name in its socket dir, a remote one as "host:name" (design 3.5).
struct XrayTarget: Equatable {
    let name: String
    /// The local session's socket dir; nil for a remote row (the default dir's dch dials the host).
    let dir: String?

    /// The selected row's session; nil for History, the empty pane, or a name dch would read as a flag.
    static func of(_ row: AgentSidebar.Row?) -> XrayTarget? {
        let t = row?.session.map { XrayTarget(name: $0.key.name, dir: $0.key.dir) }
            ?? row?.remote.map { XrayTarget(name: "\($0.host):\($0.name)", dir: nil) }
        guard let t, !t.name.isEmpty, !t.name.hasPrefix("-") else { return nil }
        return t
    }

    func args(_ form: String) -> [String] { ["--xray", name, "--\(form)", "--json"] }
    var env: [String: String] { AgentIsland.listEnv(dir: dir ?? DchCommand.defaultSocketDir) }
}

/// The open panels, by pane; the gate and the process seams.
@MainActor
final class XrayPanels: ObservableObject {
    static let shared = XrayPanels()
    @Published var open: [UUID: XrayPanelModel] = [:] {
        didSet {   // #1368: a panel that leaves stops polling and SIGTERMs its read; one that comes reads its pane's state
            for (k, m) in oldValue where open[k] !== m { m.stop() }
            for (k, m) in open where oldValue[k] !== m { m.paneState = { Self.paneState(k) } }
        }
    }

    func close(_ pane: UUID) { open[pane] = nil }

    /// One dch run: (path, argv, env) -> (exit status, stdout); -1 when it never ran or timed out.
    typealias Run = @Sendable (_ path: String, _ args: [String], _ env: [String: String]) async -> (status: Int32, out: Data)

    /// The product's: the shared runCapturingBoth, bounded like a Remote Terminal call. Never under XCTest (rows put a
    /// fake here; no row runs a real dch).
    static var run: Run = { path, args, env in
        guard NSClassFromString("XCTestCase") == nil else { return (-1, Data()) }
        let child = XrayChild()   // #1368: a cancelled read (panel closed, session switched) SIGTERMs its dch
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async {
                    let r = DchCommand.bounded(DchCommand.remoteTimeout) { onPid in
                        defer { child.reaped() }
                        return DchCommand.runCapturingBoth(args: args, env: env, path: path, onPid: { onPid($0); child.started($0) })
                    }
                    let v: (status: Int32, out: Data) = r.map { ($0.status, $0.out) } ?? (-1, Data())
                    c.resume(returning: v)
                }
            }
        } onCancel: { child.cancel() }
    }

    /// The dch path X-ray runs, when it passes XrayTabs.gate (1.78.0); nil below it: no item, no route, no process.
    static var dch: @MainActor () -> String? = { if case .ok(let path) = XrayTabs.gate(probed) { path } else { nil } }

    /// The bundled (else installed) dch's version, probed off main by `warm`; nil until then and under XCTest.
    private static var probed: DchCommand.Binary?

    /// shortcut: probed once per window open, so a dch upgrade shows on the next open; re-probe per toggle if needed.
    static func warm() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let path = DchCommand.dchPath
            let b = DchCommand.probedVersion(path).map { DchCommand.Binary(path: path, version: $0) }
            Task { @MainActor in probed = b }
        }
    }
}

/// One pane's panel: what the read found, the shown tab and the filter.
@MainActor
final class XrayPanelModel: ObservableObject {
    let target: XrayTarget
    /// nil: no Tasks tab (design 3.9: exit not 0, a schema other than 1, an empty list, a shell).
    @Published var tasks: XrayTasks?   // set here and by the poller (XrayPoller.swift)
    /// nil: no Memory tab (exit not 0, no row).
    @Published private(set) var memory: XrayMemory?
    @Published private(set) var loaded = false
    @Published var tab: XrayTab
    @Published var filter = ""
    @Published var filterFocused = false
    /// The task whose card was asked for last (the presenter shows it).
    @Published private(set) var card: XrayTasks.Task?
    var reading: Task<Void, Never>?   // the open read or a poll (XrayPoller.swift)
    /// #1368: the poller's state (XrayPoller.swift): the read's dch and runner, when the last read started, the dch
    /// path's mtime after a failed read (no retry until it moves), exit 4/7's "host unreachable", the ticker's stop.
    var dch: String?
    var run: XrayPanels.Run?
    var lastRead = Date.distantPast
    var failed = false
    var failedMtime: Date?
    @Published var unreachable = false
    var stopTicker: (() -> Void)?
    var stopped = false
    /// #1368: the pane's window visible and its session live; XrayPanels.open wires it (default: hidden, no poll).
    var paneState: () -> (visible: Bool, live: Bool) = { (false, false) }
    /// #1368: the dch path's modification date (design 3.9's retry key).
    var mtime: (String) -> Date? = { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }

    var now: () -> Date = Date.init
    var close: () -> Void = {}
    var presentCard: (XrayTasks.Task) -> Void = { _ in }
    /// The Todos chip's: run instead of keeping the panel when the read finds no Tasks tab (Q3).
    var fallback: (() -> Void)?
    /// R1351-i1: true while this panel is still the pane's open one and the pane still shows `target`; the fallback runs
    /// only then (chosen over cancelling the read: a panel hidden by a selection change stays open, so close never fires).
    var isCurrent: () -> Bool = { true }

    init(target: XrayTarget, tab: XrayTab) {
        self.target = target
        self.tab = tab
    }

    /// The one read on open: both forms, so the strip knows which tabs exist.
    func read(dch: String, run: @escaping XrayPanels.Run) {
        (self.dch, self.run) = (dch, run)
        if stopTicker == nil { stopTicker = XrayPanels.ticker { [weak self] in self?.tick() } }
        readBoth()
    }

    /// Both forms; again from the poller when a cancel left the panel unread (#1368).
    func readBoth() {
        guard let dch, let run else { return }
        lastRead = now()
        let env = target.env, a = target.args("tasks"), b = target.args("memory")
        reading = Task { [weak self] in
            async let t = run(dch, a, env)
            async let m = run(dch, b, env)
            let (tr, mr) = await (t, m)
            guard !Task.isCancelled else { return }   // #1368: closed or switched away: the SIGTERMed answer is not news
            self?.reading = nil
            self?.apply(tasks: tr, memory: mr)
        }
    }

    func apply(tasks tr: (status: Int32, out: Data), memory mr: (status: Int32, out: Data)) {
        take(tr)
        memory = mr.status == 0 ? XrayMemory.parse(mr.out) : nil
        if memory?.count == 0 { memory = nil }
        loaded = true
        if let fallback, tasks == nil {
            if isCurrent() { close(); fallback() }   // another session now shown: the list never opens over it
            return
        }
        if !tabs.contains(tab), let first = tabs.first { tab = first }
    }

    /// Design 3.9 and QA R1349-i2: a Tasks tab only for exit 0, header schema 1 and at least one task.
    static func tasksTab(_ r: (status: Int32, out: Data)) -> XrayTasks? {
        guard r.status == 0 else { return nil }
        let t = XrayTasks.parse(r.out)
        return t.schema == 1 && !t.tasks.isEmpty ? t : nil
    }

    var tabs: [XrayTab] { XrayTab.allCases.filter { $0 == .tasks ? tasks != nil : memory != nil } }

    func count(_ tab: XrayTab) -> Int { tab == .tasks ? tasks?.open ?? 0 : memory?.count ?? 0 }
    /// "Tasks 3" (open tasks), "Memory 2" (every row).
    func title(_ tab: XrayTab) -> String { "\(tab.rawValue) \(count(tab))" }
    /// VoiceOver: "Tasks, 3 open"; "Memory, 2".
    func spoken(_ tab: XrayTab) -> String { tab == .tasks ? "Tasks, \(count(tab)) open" : "Memory, \(count(tab))" }

    /// Design 3.2: case-insensitive, over id, title, note and label.
    static func matches(_ t: XrayTasks.Task, _ filter: String) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || [t.id, t.title, t.note ?? "", t.label].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// The groups with the filter applied; under a filter an emptied group goes.
    var shownGroups: [XrayTasks.Group] {
        guard let tasks else { return [] }
        let q = filter.trimmingCharacters(in: .whitespaces)
        return tasks.groups.map { XrayTasks.Group(title: $0.title, tasks: $0.tasks.filter { Self.matches($0, q) }) }
            .filter { q.isEmpty || !$0.tasks.isEmpty }
    }

    /// "Tasks \u{00B7} <title>" for a command list; nil otherwise.
    var listTitle: String? {
        guard tasks?.source == "command", let t = tasks?.sessionTitle, !t.isEmpty else { return nil }
        return "Tasks \u{00B7} \(t)"
    }

    /// The faint footer: the warnings, "partial", "N not shown".
    var footer: [String] {
        guard let tasks else { return [] }
        var out = [tasks.headerWarn, tasks.doneWarn].compactMap { $0 }.filter { !$0.isEmpty }
        if tasks.partial { out.append("partial") }
        if tasks.droppedCount > 0 { out.append("\(tasks.droppedCount) not shown") }
        if unreachable { out.append("host unreachable") }   // #1368, design 3.5: exit 4/7 kept the rows
        return out
    }

    /// Esc: clears the filter, then closes.
    func escape() {
        if filter.isEmpty { close() } else { filter = "" }
    }

    /// Command-F, or "/" outside the field, puts the keys in the filter.
    func key(_ chars: String, command: Bool) -> Bool {
        guard command ? chars.lowercased() == "f" : chars == "/" && !filterFocused else { return false }
        filterFocused = true
        return true
    }

    /// Return or a click on a row: the card (chapter jumps are P4).
    func openCard(_ t: XrayTasks.Task) {
        card = t
        presentCard(t)
    }
}

/// One task row as drawn and spoken (design 3.2, 3.8).
struct XrayTaskRow: Equatable {
    let mark: String
    let id: String
    let title: String
    let label: String?
    let blocked: String?
    let age: String?
    let spoken: String

    /// R1351-i2: the ids the row names; the card keeps the full list.
    static let blockedShown = 3

    static func statusName(_ s: XrayTasks.Status) -> String {
        switch s {
        case .active: "In progress"
        case .pending: "Pending"
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }

    static func mark(_ s: XrayTasks.Status) -> String {
        switch s {
        case .active: "circle.dotted"
        case .pending: "circle"
        case .done: "checkmark.circle"
        case .dropped: "xmark.circle"
        }
    }

    /// The words that say no more than the status (dch shows a label only when it says more: a ledger's PARKED).
    static let statusWords: Set<String> = ["", "active", "in_progress", "pending", "done", "completed", "dropped", "deleted"]

    static func label(_ t: XrayTasks.Task) -> String? { statusWords.contains(t.label.lowercased()) ? nil : t.label }

    /// "5m", "3h", "2d" and "5 minutes ago"; from `updated`, else `created`.
    static func age(_ d: Date?, now: Date) -> (short: String, spoken: String)? {
        guard let d else { return nil }
        let s = max(0, min(now.timeIntervalSince(d), 1e10))   // bounded before Int: a far date from outside stays in range
        let m = Int(s / 60), h = m / 60, days = h / 24
        func say(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        if h == 0 { return ("\(max(1, m))m", say(max(1, m), "minute")) }
        if days == 0 { return ("\(h)h", say(h, "hour")) }
        return ("\(days)d", say(days, "day"))
    }

    init(_ t: XrayTasks.Task, now: Date) {
        mark = Self.mark(t.status)
        id = t.id
        title = t.status == .active ? (t.active.flatMap { $0.isEmpty ? nil : $0 } ?? t.title) : t.title
        label = Self.label(t)
        blocked = t.blockedBy.isEmpty ? nil : "blocked by \(t.blockedBy.prefix(Self.blockedShown).joined(separator: ", "))"
            + (t.blockedBy.count > Self.blockedShown ? " +\(t.blockedBy.count - Self.blockedShown)" : "")
        let a = Self.age(t.updated ?? t.created, now: now)
        age = a?.short
        let blockedAll = t.blockedBy.isEmpty ? nil : "blocked by \(t.blockedBy.joined(separator: ", "))"
        spoken = (["\(Self.statusName(t.status)) task \(t.id)", title, label, blockedAll, a?.spoken].compactMap { $0 })
            .joined(separator: ", ")
    }
}

// MARK: - Views

/// The drawer over `pane`, drawn only while its panel is open for the session the pane shows.
struct XrayDrawer: View {
    @ObservedObject var panels = XrayPanels.shared
    let pane: UUID
    let target: XrayTarget?

    var body: some View {
        if let p = panels.open[pane], p.target == target {
            XrayPanelView(panel: p)
                .frame(maxWidth: sz(340))   // R1351-n1: min(340, the pane's width): the overlay is offered the pane's width
                .frame(maxHeight: .infinity)
                .modifier(AgentPaneProbe(kind: "xray"))   // tests only (nil probe: nothing)
                .background(Neon.card)
                .overlay(alignment: .leading) { Rectangle().fill(Neon.stroke).frame(width: 1) }
        }
    }
}

struct XrayPanelView: View {
    @ObservedObject var panel: XrayPanelModel
    @FocusState private var filterFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: sz(6)) {
                // Narrow: the counts go first, then the names scroll (design 3.1); capsule buttons ignore no UI scale.
                ViewThatFits(in: .horizontal) {
                    XrayTabStrip(panel: panel, counts: true)
                    XrayTabStrip(panel: panel, counts: false)
                    ScrollView(.horizontal, showsIndicators: false) { XrayTabStrip(panel: panel, counts: false) }
                }
                Spacer(minLength: 0)
                Button { panel.close() } label: {
                    Image(systemName: "xmark").font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                }
                .buttonStyle(.plain).fixedSize()
                .help("Close X-Ray (Shift-Command-X)")
                .accessibilityLabel("Close X-Ray")
            }
            .padding(.horizontal, sz(10)).padding(.vertical, sz(6))
            Rectangle().fill(Neon.stroke).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .focusable()
        .focusEffectDisabled()
        .onExitCommand { panel.escape() }
        .onKeyPress { k in panel.key(k.characters, command: k.modifiers.contains(.command)) ? .handled : .ignored }
        .onChange(of: panel.filterFocused) { _, v in filterFocus = v }
        .onChange(of: filterFocus) { _, v in panel.filterFocused = v }
    }

    @ViewBuilder var content: some View {
        if !panel.loaded {
            faint("Reading\u{2026}").padding(sz(10))
        } else if panel.tabs.isEmpty {
            faint("No tasks or memory for this session").padding(sz(10))
        } else if panel.tab == .memory {
            faint("\(panel.count(.memory)) memories and instruction files").padding(sz(10))
        } else {
            tasksTab
        }
    }

    var tasksTab: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Filter", text: $panel.filter)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(11))
                .focused($filterFocus)
                .accessibilityLabel("Filter tasks")
            if let t = panel.listTitle { Text(verbatim: t).font(Neon.font(11, weight: .semibold)).lineLimit(1) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(panel.shownGroups.enumerated()), id: \.offset) { _, g in
                        faint("\(g.title) \(g.tasks.count)").padding(.top, sz(6)).accessibilityAddTraits(.isHeader)
                        ForEach(Array(g.tasks.enumerated()), id: \.offset) { _, t in
                            XrayTaskRowView(row: XrayTaskRow(t, now: panel.now())) { panel.openCard(t) }
                        }
                    }
                }
            }
            ForEach(panel.footer, id: \.self) { faint($0) }
        }
        .padding(sz(10))
    }

    func faint(_ s: String) -> some View {
        Text(verbatim: s).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary).lineLimit(1)
    }
}

/// The #821 capsule-button strip: only the tabs that exist, "Name N".
struct XrayTabStrip: View {
    @ObservedObject var panel: XrayPanelModel
    let counts: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(panel.tabs, id: \.self) { t in
                Button { panel.tab = t } label: {
                    Text(verbatim: counts ? panel.title(t) : t.rawValue)
                        .font(Neon.font(10.5, weight: .medium))
                        .foregroundStyle(t == panel.tab ? Neon.textPrimary : Neon.textSecondary)
                        .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
                        .background(Capsule().fill(t == panel.tab ? Neon.blue.opacity(0.2) : .clear))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(panel.spoken(t))
                .accessibilityAddTraits(t == panel.tab ? .isSelected : [])
            }
        }
        .padding(sz(2))
        .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("X-Ray tabs")
    }
}

struct XrayTaskRowView: View {
    let row: XrayTaskRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: sz(6)) {
                Image(systemName: row.mark).foregroundStyle(Neon.textSecondary)
                Text(verbatim: row.id).foregroundStyle(Neon.textSecondary).fixedSize()
                Text(verbatim: row.title).foregroundStyle(Neon.textPrimary).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1).modifier(AgentPaneProbe(kind: "xrayTitle"))   // tests only (nil probe: nothing)
                Spacer(minLength: sz(4))
                ForEach([row.label, row.age].compactMap { $0 }, id: \.self) {
                    Text(verbatim: $0).foregroundStyle(Neon.textSecondary).lineLimit(1).fixedSize()
                }
                // truncates under its own cap: a long id list never pushes the title out
                if let b = row.blocked {
                    Text(verbatim: b).foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: sz(120), alignment: .trailing)
                }
            }
            .font(Neon.font(11))
            .padding(.vertical, sz(2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.spoken)
    }
}

/// The task card (design 3.2): title in full, status and label, doing, note, times, blocked by, group, URL; Open
/// (http/https only, the raw url, and only when it is the shown one) and Copy (Pasteboard.swift).
struct XrayTaskCard: View {
    let task: XrayTasks.Task
    let now: Date
    let open: (URL) -> Void

    static let size = CGSize(width: 360, height: 320)

    /// The labelled fields, in order; a field with no value is left out.
    static func fields(_ t: XrayTasks.Task, now: Date) -> [(label: String, value: String)] {
        let status = XrayTaskRow.statusName(t.status) + (XrayTaskRow.label(t).map { " (\($0))" } ?? "")
        let pairs: [(String, String?)] = [
            ("Title", t.title), ("Status", status), ("Doing", t.status == .active ? t.active : nil), ("Note", t.note),
            ("Created", XrayTaskRow.age(t.created, now: now)?.spoken), ("Updated", XrayTaskRow.age(t.updated, now: now)?.spoken),
            ("Blocked by", t.blockedBy.isEmpty ? nil : t.blockedBy.joined(separator: ", ")), ("Group", t.group), ("URL", t.url),
        ]
        return pairs.compactMap { p -> (label: String, value: String)? in
            guard let v = p.1, !v.isEmpty else { return nil }
            return (p.0, v)
        }
    }

    /// The raw url, re-checked: http or https with a host, else nil (shown as text only).
    static func openable(_ raw: String?) -> URL? {
        guard let raw, let u = URL(string: raw), let s = u.scheme?.lowercased(), s == "http" || s == "https",
              u.host?.isEmpty == false else { return nil }
        return u
    }

    static func copyText(_ t: XrayTasks.Task, now: Date) -> String {
        fields(t, now: now).map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    /// R1351-s1: Open only when the shown url is the raw one (cleaning dropped nothing and capped nothing); else text only.
    static func openURL(_ t: XrayTasks.Task) -> URL? { t.url == t.rawURL ? openable(t.rawURL) : nil }

    func openLink() { if let u = Self.openURL(task) { open(u) } }

    func copy() {
        Pasteboard.general.clearContents()
        Pasteboard.general.setString(Self.copyText(task, now: now), forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(8)) {
            ScrollView {
                VStack(alignment: .leading, spacing: sz(6)) {
                    ForEach(Array(Self.fields(task, now: now).enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: sz(1)) {
                            Text(verbatim: f.label).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                            Text(verbatim: f.value).font(Neon.font(11.5)).foregroundStyle(Neon.textPrimary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(f.label): \(f.value)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: sz(8)) {
                if Self.openURL(task) != nil {
                    Button("Open", action: openLink).accessibilityLabel("Open the task's link")
                }
                Button("Copy", action: copy).accessibilityLabel("Copy the task")
            }
        }
        .padding(sz(12))
    }
}
