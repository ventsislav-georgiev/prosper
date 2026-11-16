import AppKit
import SwiftUI

// #786 Agent window, spike A: the read-only conversation view. Settings-console
// look (Neon palette, `Neon.font` / `sz` so it follows ThemeRuntime.scale). Every
// block draws a header line, so a block can simplify but never render blank.

struct AgentTranscriptView: View {
    @ObservedObject var model: AgentTranscriptModel
    /// False for offscreen evidence: a plain stack instead of a ScrollView.
    var scrolls = true
    /// #797: the terminal-first state's "Open in terminal" (the island's own open path).
    var openTerminal: (() -> Void)?
    /// Standalone, the view starts and stops the model on appear and disappear. The
    /// Agents window passes false: it owns start/stop (selection, close, hide).
    var ownsLifecycle = true
    /// #821: how much of each turn shows (the window passes its one global level).
    var level: AgentVerbosity = .default
    /// QA #668 INFO-2: the session ended (the window's held row): Open in terminal is off, in its slot.
    var ended = false
    /// QA #657 INFO-6 (macOS 15+): the reader's top turn as SwiftUI reports it, with the list it belongs to (block ids
    /// restart per file: another session or generation never takes this place); nil at the end.
    @State var kept: (list: AgentTranscriptModel.ViewIdentity, turn: Int)? = nil
    @State var atEnd = true
    /// Test seam: a row moves the place through the binding SwiftUI writes (SwiftUI never sees an AppKit clip scroll).
    var position: Binding<Int?>?
    /// #904 (spec 8.4): this pane's jumps. Each pane passes its own, so a jump scrolls only that pane; the jumper never
    /// reaches the window model (focus, selection) or a row's fold. Standalone views share the idle one nobody jumps.
    @ObservedObject var jumper: TranscriptJumper = .idle
    /// Where the marked row's top sits in the viewport (its overlay reports it while drawn); nil while undrawn.
    @State var landedTop: CGFloat?
    /// The 1 pt sentinel at the bottom of the padded rows: "back to latest" scrolls to it with anchor .bottom (P0 run3: the last
    /// row's own id stops sz(14) short of the end, and from there new rows are not followed).
    static let bottomID = "bottom"
    static let space = "transcript-viewport"

    var body: some View {
        VStack(spacing: 0) {
            if let b = model.banner { TranscriptBanner(text: b) }
            if case .terminalFirst(let reason) = model.mode, !model.showAnyway {
                TerminalFirstView(reason: reason, openTerminal: openTerminal, ended: ended) { model.showAnyway = true }
            } else {
                if case .waiting(let hint) = model.mode { TranscriptHint(text: hint) }
                // QA #626 INFO-1: block ids restart at 0 per file, so the list's view state
                // (folds, "Show all") is keyed by the session and the model's generation too.
                // #821: and by the level, so a switch starts every fold as that level draws it.
                let identity: [AnyHashable] = [model.viewIdentity, level]
                if scrolls {
                    if #available(macOS 15, *) {
                        keepsPlace
                    } else {
                        // macOS 14: no scroll geometry to tell the end from a place; a switch lands at the end, as before.
                        ScrollViewReader { proxy in
                            jumps(ScrollView { withSentinel(LazyVStack(alignment: .leading, spacing: sz(10)) { rows } .padding(sz(14))) }
                                .defaultScrollAnchor(.bottom), proxy)
                        }
                        .id(identity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: sz(10)) { rows }.padding(sz(14))
                        .id(identity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: scrolls ? .infinity : nil, alignment: .top)
        // #860: no fill of its own; the window's SettingsBackground shows through at the live opacity.
        .onAppear { if scrolls && ownsLifecycle { model.start() } }
        .onDisappear { if scrolls && ownsLifecycle { model.stop() } }
    }

    /// QA #657 INFO-6: one ScrollView across a level switch (the level is in each row's id, not the ScrollView's), so the
    /// reader's top turn stays on top. At the end the place is nil and the bottom anchor follows new lines, as before.
    /// The binding and the geometry closures run on the main actor, in SwiftUI's update.
    @available(macOS 15, *)
    private var keepsPlace: some View {
        let list = model.viewIdentity
        let place = position ?? Binding(get: { kept?.list == list ? kept?.turn : nil },
                                        set: { t in kept = t.map { (list, $0) } })
        return ScrollViewReader { proxy in jumps(ScrollView { withSentinel(LazyVStack(alignment: .leading, spacing: sz(10)) { rows }.scrollTargetLayout().padding(sz(14))) }
            // A new place SwiftUI reports at the end is no place: the end keeps following. Its echo of a place just set
            // (it writes back the id it scrolled to, before the geometry leaves the end) is kept.
            .scrollPosition(id: Binding(get: { place.wrappedValue },
                                        set: { place.wrappedValue = atEnd && $0 != place.wrappedValue ? nil : $0 }), anchor: .top)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY >= $0.contentSize.height - 2 } action: { _, end in
                atEnd = end
                if end { place.wrappedValue = nil }
            }
            // SwiftUI keeps the place's id across a switch but not its offset (the turns above change height): the held
            // turn is put back on top once the new level's rows are in the graph (main actor, in SwiftUI's update).
            // #904: a reader at the end stays at the end: the sentinel, the true bottom (the turns above change height).
            .onChange(of: level) {
                if let t = place.wrappedValue { proxy.scrollTo(t, anchor: .top) } else if atEnd { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }, proxy)
            .id(list)
        }
    }

    @ViewBuilder private var rows: some View {
        if model.olderAvailable && model.atHistoryCap {
            Text("Older history is in the terminal").font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
        } else if model.olderAvailable {
            Button { model.loadEarlier() } label: {
                Label("Load earlier", systemImage: "arrow.up").font(Neon.font(11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Neon.blue)
        }
        let working = Self.turnWorking(state: model.source?.dchState, toolPending: model.toolPending, ended: ended)
        let turns = TranscriptVerbosity.turns(model.blocks)
        // One stack per turn, keyed by its first block (the same at every level): the scroll target. A row's id holds
        // the level, so a switch starts every fold as that level draws it.
        ForEach(turns, id: \.[0].id) { t in
            VStack(alignment: .leading, spacing: sz(10)) {
                ForEach(TranscriptVerbosity.project(t, level: level, working: working && t[0].id == turns.last?[0].id)) { r in
                    TranscriptRowView(row: r, level: level, expand: { await model.fullText($0) }).id(level)
                        .overlay(alignment: .leading) { if jumper.marked == r.id { mark } }
                        .id(r.id)
                }
            }
        }
        if level == .verbose && model.hiddenCount > 0 {
            Text(plural(model.hiddenCount, "internal entry", "internal entries") + " hidden")
                .font(Neon.font(10)).foregroundStyle(Neon.textSecondary.opacity(0.7))
        }
    }

    /// The sentinel overlays the padded rows' last point: no layout of its own (a VStack around the LazyVStack plus
    /// the per-row ids lost the end across a level switch, #904 r1).
    private func withSentinel(_ rows: some View) -> some View {
        rows.overlay(alignment: .bottom) { Color.clear.frame(height: 1).id(Self.bottomID) }
    }

    /// The scroll view with this pane's jumps: rows report their place in `space`, a request scrolls.
    private func jumps(_ scroll: some View, _ proxy: ScrollViewProxy) -> some View {
        scroll.coordinateSpace(.named(Self.space))
            .onChange(of: jumper.request) { _, r in if let r { land(r, proxy) } }
    }

    /// The mark: a bar over the row's leading edge (an overlay: the row does not move). It reports the row's top.
    private var mark: some View {
        Rectangle().fill(Neon.blue).frame(width: sz(3))
            .transition(.opacity)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { landedTop = $0 }
    }

    /// Spec 8.4, no animation. The turn first: the LazyVStack knows its turns' ids even undrawn, not the rows inside an
    /// undrawn turn. On the next runloop the row is put on top once more unless it is drawn within the top sz(40).
    /// Never opens or closes a fold: a block inside a folded step lands on the fold's row.
    private func land(_ r: TranscriptJumper.Request, _ proxy: ScrollViewProxy) {
        var t = Transaction()
        t.disablesAnimations = true
        guard let block = r.block else {
            withTransaction(t) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            return
        }
        guard let target = TranscriptOutline.target(block, in: model.blocks, level: level) else { return }
        landedTop = nil
        jumper.mark(target.row)
        withTransaction(t) { proxy.scrollTo(target.turn, anchor: .top) }
        let landed = $landedTop, row = target.row
        DispatchQueue.main.async {
            if let top = landed.wrappedValue, top > -1, top <= sz(40) { return }
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(row, anchor: .top) }
        }
    }

    /// QA #657 INFO-3a: Focused's last turn reads "Working" while dch says the session works (the state the window
    /// already handed the model) or a tool call is open; an unknown state (nil, "") is the tool call alone.
    /// R1269-q1: never on an ended pane (its model gets no update() again: the state and the open call are the last seen).
    static func turnWorking(state: String?, toolPending: Bool, ended: Bool = false) -> Bool {
        !ended && (toolPending || state == "working")
    }
}

/// #904 (spec 8.4): one pane's jump requests and its mark. Step B (the list) and step C (the rail) call it.
@MainActor final class TranscriptJumper: ObservableObject {
    /// `block` nil: back to latest (the sentinel). `serial` makes a repeated jump to the same block a new request.
    struct Request: Equatable { let serial: Int; let block: Int? }
    /// For a view nobody jumps (standalone transcripts): never asked to jump.
    static let idle = TranscriptJumper()
    static let markDuration: TimeInterval = 1.2

    @Published private(set) var request: Request?
    /// The row the last jump landed on, while its mark shows.
    @Published private(set) var marked: String?
    private var serial = 0, marks = 0

    // Seams: Reduce Motion, and the clock that removes the mark.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var after: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { d, f in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(d))
            f()
        }
    }

    func jump(to chapter: TranscriptOutline.Chapter) { jump(toBlock: chapter.id) }
    func jump(toBlock id: Int) { send(id) }
    func jumpToLatest() { send(nil) }

    private func send(_ block: Int?) {
        serial += 1
        request = Request(serial: serial, block: block)
    }

    /// Shows the mark on `row` and removes it after `markDuration`, unless a later jump marked another row.
    func mark(_ row: String) {
        marked = row
        marks += 1
        let n = marks
        after(Self.markDuration) { [weak self] in
            guard let self, self.marks == n else { return }
            withAnimation(Self.removal(reduceMotion: self.reduceMotion())) { self.marked = nil }
        }
    }

    /// Reduce Motion: a plain removal, no fade.
    static func removal(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .easeOut(duration: 0.2) }
}

struct TranscriptBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: sz(6)) {
            Image(systemName: "sparkles").foregroundStyle(Neon.indigo)
            Text(text).foregroundStyle(Neon.textSecondary)
            Spacer(minLength: 0)
        }
        .font(Neon.font(11))
        .padding(.horizontal, sz(14)).padding(.vertical, sz(6))
        .background(Neon.indigo.opacity(0.12))
    }
}

struct TranscriptHint: View {
    let text: String
    var body: some View {
        HStack(spacing: sz(6)) {
            Image(systemName: "hourglass").foregroundStyle(Neon.blue)
            Text(text).foregroundStyle(Neon.textSecondary)
            Spacer(minLength: 0)
        }
        .font(Neon.font(11))
        .padding(.horizontal, sz(14)).padding(.vertical, sz(6))
        .background(Neon.card)
    }
}

struct TerminalFirstView: View {
    let reason: String
    var openTerminal: (() -> Void)?
    /// QA #668 INFO-2: an ended session: the button stays, dimmed and off, as the header's.
    var ended = false
    var openEnabled: Bool { !ended }
    var showConversation: () -> Void = {}
    var body: some View {
        VStack(spacing: sz(10)) {
            Image(systemName: "terminal").font(Neon.font(26)).foregroundStyle(Neon.terminal)
            Text("Opens in the terminal").font(Neon.font(14, weight: .semibold)).foregroundStyle(Neon.textPrimary)
            Text(reason).font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let openTerminal { OpenInTerminalButton(action: openTerminal, ended: !openEnabled) }
            Button("Show the conversation anyway", action: showConversation)
                .buttonStyle(.plain).font(Neon.font(11, weight: .medium)).foregroundStyle(Neon.blue)
        }
        .padding(sz(24))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - #821 rows

/// A projected row: a block as today, one line that opens today's card, a subagent's tail,
/// or a Focused turn's summary.
struct TranscriptRowView: View {
    let row: TranscriptRow
    let level: AgentVerbosity
    var expand: (Clip) async -> String? = { _ in nil }
    @State private var open = false

    var body: some View {
        switch row.kind {
        case .block(let b):
            TranscriptBlockView(block: b, expanded: level == .verbose, expand: expand)
        case .line(let b):
            let l = TranscriptVerbosity.lineSummary(b)
            VStack(alignment: .leading, spacing: sz(6)) {
                Button { open.toggle() } label: { TranscriptLineLabel(line: l, open: open) }
                    .buttonStyle(.plain).disabled(!l.expandable)
                if open { TranscriptBlockView(block: b, expand: expand) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .thread(let b, let earlier, let children):
            VStack(alignment: .leading, spacing: sz(6)) {
                if case .thread(_, let title) = b.body {
                    ToolHeader(icon: "person.2", title: "Subagent", detail: title == "Subagent" ? nil : title)
                }
                if earlier > 0 {
                    Text(plural(earlier, "earlier step") + " not shown").font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
                }
                ForEach(children) { AnyView(TranscriptRowView(row: $0, level: level, expand: expand)) }
            }
            .padding(.leading, sz(10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) { Rectangle().fill(Neon.indigo.opacity(0.6)).frame(width: 2) }
        case .summary(let s, let children, let errors):
            VStack(alignment: .leading, spacing: sz(6)) {
                Button { open.toggle() } label: {
                    TranscriptLineLabel(line: .init(icon: s.working ? "hourglass" : "list.bullet", title: s.label), open: open)
                }
                .buttonStyle(.plain)
                ForEach(open ? children : errors) { AnyView(TranscriptRowView(row: $0, level: level, expand: expand)) }
                    .padding(.leading, sz(14))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TranscriptLineLabel: View {
    let line: TranscriptVerbosity.Line
    let open: Bool
    var body: some View {
        let tint = line.error ? Neon.magenta : Neon.textSecondary
        HStack(spacing: sz(6)) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(Neon.font(8, weight: .bold))
                .foregroundStyle(Neon.textSecondary).opacity(line.expandable ? 1 : 0)
            Image(systemName: line.icon).foregroundStyle(line.error ? Neon.magenta : Neon.blue)
            Text(line.title).font(Neon.font(11, weight: .semibold))
                .foregroundStyle(line.error ? Neon.magenta : Neon.textPrimary).lineLimit(1)
            if let d = line.detail, !d.isEmpty {
                Text(d).font(Neon.font(10.5, design: .monospaced)).foregroundStyle(Neon.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let st = line.status { Text(st).font(Neon.font(10)).foregroundStyle(tint).lineLimit(1).layoutPriority(1) }
        }
        .font(Neon.font(11))
        .contentShape(Rectangle())
    }
}

// MARK: - Blocks

struct TranscriptBlockView: View {
    let block: TranscriptBlock
    /// Initial fold state; the offscreen renders draw both.
    var expanded = false
    var expand: (Clip) async -> String? = { _ in nil }

    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch block.body {
        case .user(let c):
            HStack(alignment: .top, spacing: sz(8)) {
                RoundedRectangle(cornerRadius: 1).fill(Neon.blue).frame(width: 2)
                VStack(alignment: .leading, spacing: sz(3)) {
                    Text("You").font(Neon.font(10, weight: .semibold)).foregroundStyle(Neon.blue)
                    ClipText(clip: c, expand: expand)
                }
            }
            .padding(sz(8))
            .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.cardHi))
        case .assistant(let c):
            ClipText(clip: c, markdown: true, expand: expand)
        case .thinking(let c):
            Fold(icon: "brain", title: "Thinking", detail: c.text.isEmpty ? "not recorded" : nil,
                 open: expanded && !c.text.isEmpty) {
                ClipText(clip: c, color: Neon.textSecondary, expand: expand).italic()
            }
        case .command(let name, let args):
            HStack(spacing: sz(5)) {
                Image(systemName: "chevron.right.square").foregroundStyle(Neon.indigo)
                Text(name).font(Neon.font(11, weight: .semibold, design: .monospaced)).foregroundStyle(Neon.textPrimary)
                if let args {
                    Text(args).font(Neon.font(11, design: .monospaced)).foregroundStyle(Neon.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .font(Neon.font(11))
            .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
            .background(Capsule().fill(Neon.indigo.opacity(0.14)))
            .overlay(Capsule().stroke(Neon.indigo.opacity(0.35), lineWidth: 1))
            .fixedSize(horizontal: false, vertical: true)
        case .image:
            Label("Image", systemImage: "photo").font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
        case .bash(let cmd, let desc, let out, let err):
            Card(error: err) {
                HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
                    Text("$").font(Neon.font(12, weight: .bold, design: .monospaced)).foregroundStyle(Neon.terminal)
                    Text(cmd).font(Neon.font(11.5, design: .monospaced)).foregroundStyle(Neon.textPrimary)
                        .lineLimit(expanded ? nil : 3)
                }
                if let desc, !desc.isBlank {
                    Text(desc).font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                }
                if let out {
                    Fold(icon: err ? "xmark.octagon" : "text.alignleft",
                         title: out.text.isEmpty ? "No output" : "Output",
                         detail: out.text.isEmpty ? nil : out.capped ? "\(out.total) chars" : plural(out.lineCount, "line"),
                         open: expanded && !out.text.isEmpty) {
                        ClipText(clip: out, mono: true, color: err ? Neon.magenta : Neon.textSecondary, expand: expand)
                    }
                } else {
                    Text("Running…").font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary.opacity(0.8))
                }
            }
        case .diff(let tool, let path, let lines, let more, let err):
            Card(error: err) {
                ToolHeader(icon: tool == "Write" ? "doc.badge.plus" : "pencil", title: tool, detail: path)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.prefix(expanded ? lines.count : 12).enumerated()), id: \.offset) { _, l in
                        DiffRow(line: l)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: sz(4)))
                let hidden = more + (expanded ? 0 : max(0, lines.count - 12))
                if hidden > 0 {
                    Text(plural(hidden, "more line")).font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
                }
            }
        case .read(let path, let detail):
            HStack(spacing: sz(6)) {
                Image(systemName: "doc.text").foregroundStyle(Neon.blue)
                Text("Read").font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                Text(path).font(Neon.font(11, design: .monospaced)).foregroundStyle(Neon.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(Neon.font(10)).foregroundStyle(Neon.textSecondary).lineLimit(1) }
            }
            .padding(.horizontal, sz(8)).padding(.vertical, sz(4))
            .background(Capsule().fill(Neon.card))
            .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
        case .search(let tool, let pattern, let scope, let results, let more):
            Card(error: false) {
                ToolHeader(icon: "magnifyingglass", title: tool, detail: pattern + (scope.map { "  in \($0)" } ?? ""))
                Fold(icon: "list.bullet", title: results.isEmpty ? "No matches" : plural(results.count + more, "result"),
                     detail: nil, open: expanded && !results.isEmpty) {
                    VStack(alignment: .leading, spacing: sz(1)) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                            Text(r).font(Neon.font(10.5, design: .monospaced)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                        }
                        if more > 0 { Text("\(more) more").font(Neon.font(10)).foregroundStyle(Neon.textSecondary) }
                    }
                }
            }
        case .compaction(let trigger, let pre, let summary):
            VStack(alignment: .leading, spacing: sz(4)) {
                HStack(spacing: sz(8)) {
                    Rectangle().fill(Neon.indigo.opacity(0.5)).frame(height: 1)
                    Text(["Conversation compacted", trigger, pre.map { "\($0 / 1000)k tokens" }].compactMap { $0 }
                        .joined(separator: " · "))
                        .font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.indigo).fixedSize()
                    Rectangle().fill(Neon.indigo.opacity(0.5)).frame(height: 1)
                }
                if let summary {
                    Fold(icon: "text.quote", title: "Summary", detail: nil, open: expanded) {
                        ClipText(clip: summary, color: Neon.textSecondary, expand: expand)
                    }
                }
            }
        case .notice(let text):
            Label { Text(text).lineLimit(expanded ? nil : 3) } icon: { Image(systemName: "info.circle") }
                .font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
        case .thread(_, let title):
            VStack(alignment: .leading, spacing: sz(8)) {
                ToolHeader(icon: "person.2", title: "Subagent", detail: title == "Subagent" ? nil : title)
                if block.droppedChildren > 0 {
                    Text(plural(block.droppedChildren, "earlier step") + " not shown").font(Neon.font(10))
                        .foregroundStyle(Neon.textSecondary)
                }
                ForEach(block.children) { c in
                    AnyView(TranscriptBlockView(block: c, expanded: expanded, expand: expand))
                }
            }
            .padding(.leading, sz(10))
            .overlay(alignment: .leading) { Rectangle().fill(Neon.indigo.opacity(0.6)).frame(width: 2) }
        case .card(let title, let fields, let body, let raw, let err):
            Card(error: err) {
                ToolHeader(icon: raw == nil ? "wrench.and.screwdriver" : "questionmark.square.dashed", title: title, detail: nil)
                if !fields.isEmpty {
                    VStack(alignment: .leading, spacing: sz(2)) {
                        ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                            HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
                                Text(f.key).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                                Text(f.value).font(Neon.font(10.5, design: .monospaced)).foregroundStyle(Neon.textPrimary)
                                    .lineLimit(expanded ? nil : 2)
                            }
                        }
                    }
                }
                if let body {
                    Fold(icon: "text.alignleft", title: body.text.isEmpty ? "No output" : "Result", detail: nil,
                         open: expanded && !body.text.isEmpty) {
                        ClipText(clip: body, mono: true, color: err ? Neon.magenta : Neon.textSecondary, expand: expand)
                    }
                }
                if let raw {
                    Fold(icon: "curlybraces", title: "Raw entry", detail: nil, open: expanded) {
                        ClipText(clip: raw, mono: true, color: Neon.textSecondary, expand: expand)
                    }
                }
            }
        case .failed(let reason, let raw):
            Card(error: true) {
                ToolHeader(icon: "exclamationmark.triangle", title: reason, detail: nil)
                if let raw, !raw.text.isEmpty {
                    Fold(icon: "curlybraces", title: "Raw line", detail: nil, open: expanded) {
                        ClipText(clip: raw, mono: true, color: Neon.textSecondary, expand: expand)
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

/// #797: the one "Open in terminal" look (the terminal-first state, the failed-attach card, a notice that names it;
/// #1103: the header's moved into its "⋯" menu, AgentWindowControls.sessionMenu).
struct OpenInTerminalButton: View {
    let action: () -> Void
    /// Icon only (beside a notice or a card's other button).
    var compact = false
    /// QA #668 F1: the session ended: off and dimmed in its slot; QA #672 #4: its help says why.
    var ended = false
    static let help = "Open this session in the terminal app"
    var help: String { ended ? AgentPaneModeToggle.endedReason : Self.help }
    var body: some View {
        Button(action: action) {
            Label(AgentWindowControls.openLabel, systemImage: "terminal")
                .labelStyle(OpenInTerminalLabelStyle(compact: compact))
                .font(Neon.font(11, weight: .semibold))
                .foregroundStyle(Neon.terminal)
                .padding(.horizontal, sz(10)).padding(.vertical, sz(5))
                .background(Capsule().fill(Neon.terminal.opacity(0.12)))
                .overlay(Capsule().stroke(Neon.terminal.opacity(0.45), lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(ended).opacity(ended ? 0.45 : 1)
        .help(help)
        .accessibilityLabel(AgentWindowControls.openLabel)
    }
}

private struct OpenInTerminalLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon } else { Label(configuration) }
    }
}

/// Inline Markdown for model text, with links only for http/https. Model output is
/// untrusted: any other scheme (prosper://sleep, file://, javascript:, mailto:, other
/// apps' schemes) is reduced to plain text, so it is neither drawn as a link nor clickable.
func transcriptMarkdown(_ s: String) -> AttributedString? {
    guard var a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else { return nil }
    let unsafe = a.runs.filter { r in
        r.imageURL != nil || r.link.map { !["http", "https"].contains($0.scheme?.lowercased() ?? "") } == true
    }.map(\.range)
    for r in unsafe {
        a[r].link = nil
        a[r].imageURL = nil
    }
    return a
}

private struct Card<Content: View>: View {
    let error: Bool
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: sz(6)) { content }
            .padding(sz(9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.card))
            .overlay(RoundedRectangle(cornerRadius: sz(8))
                .stroke(error ? Neon.magenta.opacity(0.55) : Neon.stroke, lineWidth: 1))
    }
}

private struct ToolHeader: View {
    let icon: String
    let title: String
    let detail: String?
    var body: some View {
        HStack(spacing: sz(6)) {
            Image(systemName: icon).foregroundStyle(Neon.blue)
            Text(title).font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textPrimary).lineLimit(1)
            if let detail {
                Text(detail).font(Neon.font(10.5, design: .monospaced)).foregroundStyle(Neon.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .font(Neon.font(11))
    }
}

private struct DiffRow: View {
    let line: DiffLine
    var body: some View {
        let (mark, tint): (String, Color) = switch line.kind {
        case .added: ("+", Neon.terminal)
        case .removed: ("-", Neon.magenta)
        case .context: (" ", Neon.textSecondary)
        }
        HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
            Text(mark).foregroundStyle(tint)
            Text(line.text.isEmpty ? " " : line.text).foregroundStyle(line.kind == .context ? Neon.textSecondary : Neon.textPrimary)
                .lineLimit(1)
        }
        .font(Neon.font(10.5, design: .monospaced))
        .padding(.horizontal, sz(6)).padding(.vertical, sz(0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .context ? Color.clear : tint.opacity(0.12))
    }
}

private struct Fold<Content: View>: View {
    let icon: String
    let title: String
    let detail: String?
    @State var open: Bool
    @ViewBuilder let content: Content

    init(icon: String, title: String, detail: String?, open: Bool, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.detail = detail
        _open = State(initialValue: open)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            Button { open.toggle() } label: {
                HStack(spacing: sz(5)) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(Neon.font(8, weight: .bold))
                    Image(systemName: icon)
                    Text(title).font(Neon.font(10.5, weight: .medium))
                    if let detail { Text(detail).font(Neon.font(10)).opacity(0.75) }
                }
                .foregroundStyle(Neon.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content.padding(.leading, sz(14)) }
        }
    }
}

/// Capped text with a lazy "Show all": the full text is re-read from the file
/// only when asked. Markdown falls back to plain text when it does not parse.
private struct ClipText: View {
    let clip: Clip
    var mono = false
    var markdown = false
    var color: Color = Neon.textPrimary
    var expand: (Clip) async -> String? = { _ in nil }
    @State private var full: String?

    var body: some View {
        VStack(alignment: .leading, spacing: sz(3)) {
            text(full ?? clip.text)
                .font(mono ? Neon.font(10.5, design: .monospaced) : Neon.font(12.5))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if clip.capped && full == nil {
                Button("Show all (\(clip.total) chars)") { Task { full = await expand(clip) ?? clip.text } }
                    .buttonStyle(.plain).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.blue)
            }
        }
    }

    private func text(_ s: String) -> Text {
        guard markdown, let a = transcriptMarkdown(s) else { return Text(s) }
        return Text(a)
    }
}
