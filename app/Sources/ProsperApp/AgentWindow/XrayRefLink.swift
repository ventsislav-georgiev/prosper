import AppKit
import SwiftUI

// #1418 (#1356 step 4, spec 5.1): clickable refs in Transcript mode. dch's `--json` refs (XrayRefs) are read on pane
// focus into a per-window cache; each ref dch marks `underline` gets a dotted underline and a prosper-xray link in the
// user and assistant prose clips; a click opens the ref card (XrayRefPopover) through the window's presenter.
// Gate B (XrayRefLink.decorate) ships on (#1419); while off, no read, no underline, no link.
// #1357 (P9): Terminal mode too. The cache reads for the focused live (Terminal) pane as well; a Cmd-click on an underlined
// ref on the grid, or a prosper-xray OSC 8 link, opens the same card through the same panel (AgentTerminalHostView.refClick,
// AgentTerminalController.open).
// #1559 (X-T a): the Terminal pane's refs come from the focused pane's follow (terminalRefs), and its grid draws their
// marks (XrayGridMarks.swift); the cache below stays the Transcript prose's.

@MainActor
enum XrayRefLink {
    /// Gate B. On since #1419 (#1356 step 5); rows set `decorate` and restore it.
    static let ships = true
    static var decorate: @MainActor () -> Bool = { ships }

    nonisolated static let scheme = "prosper-xray"
    /// Tests: each prose text decorated (gate on, refs there); nil in the product.
    static var drawn: (@MainActor (String) -> Void)?

    /// RFC 3986 unreserved: every other byte of the key is percent-encoded.
    nonisolated private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// prosper-xray://ref?k=<key>: the key alone, never the text or the title.
    nonisolated static func url(_ key: String) -> URL? {
        guard let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "\(scheme)://ref?k=\(k)")
    }

    /// The key of a link this view made: scheme prosper-xray, host ref, one `k` and nothing else, and a key in `refs`
    /// (the pane's cache now). A forged or stale link is refused (nil).
    static func key(from url: URL, in refs: XrayRefs?) -> String? {
        guard url.scheme == scheme, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.host == "ref",
              c.user == nil, c.password == nil, c.port == nil, c.path.isEmpty, c.fragment == nil,
              let items = c.queryItems, items.count == 1, let item = items.first, item.name == "k",
              let k = item.value, !k.isEmpty, refs?.entries.contains(where: { $0.key == k }) == true else { return nil }
        return k
    }

    enum Outcome: Equatable { case handled, system, discarded }

    /// The transcript's OpenURLAction: prosper-xray shows the ref's card (`show`); http, https and mailto: go to the
    /// system; every other scheme (file:, ssh:, tel:, javascript:, the app's own prosper:...), a missing scheme and a
    /// refused prosper-xray link are dropped (allowlist: transcript prose is untrusted, #1419).
    static func open(_ url: URL, refs: XrayRefs?, show: (XrayRefs.Entry) -> Void) -> Outcome {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto": return .system
        case scheme:
            guard let k = key(from: url, in: refs), let e = refs?.entries.first(where: { $0.key == k }) else { return .discarded }
            show(e)
            return .handled
        default: return .discarded
        }
    }

    /// The panel whose card a click opens: the pane's open X-ray panel on this session, else a new one wired to the
    /// window's presenter (anchored on the pane's XrayCardAnchor) that runs the card's --ref read.
    static func panel(_ pane: UUID, _ target: XrayTarget, _ refs: XrayRefs) -> XrayPanelModel {
        if let m = XrayPanels.shared.open[pane], m.target == target { return m }
        let m = XrayPanelModel(target: target, tab: .refs)
        (m.dch, m.run, m.refs) = (XrayPanels.dch(), XrayPanels.run, refs)
        XrayPanels.shared.wire(m, pane)
        return m
    }

    /// #1357 (P9): the refs for `key` when it is the window's focused pane's session (a Cmd-click reaches only the
    /// focused pane: the window's first-click rule takes a focusing down), its target and that pane. #1559: from the
    /// follow that pane's focus attached (XrayFollows.focus), not the transcript, so a shell or Codex pane has them too.
    /// Nil: gate B off, no window, another session, a remote row (never focused into a follow), or no snapshot yet.
    static func terminalRefs(_ w: AgentsNSWindow?, _ key: AgentSessionKey?) -> (refs: XrayRefs, target: XrayTarget, pane: UUID)? {
        guard decorate(), let w, let key, let m = w.model, let f = XrayPanels.shared.follows.focused(in: ObjectIdentifier(w)),
              f.target == XrayTarget(name: key.name, dir: key.dir), let refs = f.state?.refs else { return nil }
        return (refs, f.target, m.layout.focused)
    }

    /// #1357: a Cmd-click on grid column `column` of the viewport line `line`: the ref there opens its card. False: none.
    static func openOnGrid(_ w: AgentsNSWindow?, key: AgentSessionKey, line: String, column: Int) -> Bool {
        guard let r = terminalRefs(w, key), let k = XrayRefSpans.key(atColumn: column, in: line, refs: r.refs.entries),
              let e = r.refs.entries.first(where: { $0.key == k }) else { return false }
        panel(r.pane, r.target, r.refs).openRef(e)
        return true
    }

    /// #1565 (X-T b): the panel a hover card shows in and the focused pane's refs (terminalRefs' rules: the window's
    /// focused pane, this session, gate B on). Nil: no card.
    static func hoverPanel(_ w: AgentsNSWindow?, key: AgentSessionKey?) -> (panel: XrayPanelModel, refs: XrayRefs)? {
        guard let r = terminalRefs(w, key) else { return nil }
        return (panel(r.pane, r.target, r.refs), r.refs)
    }

    /// #1357: a prosper-xray link a program printed (OSC 8) in a Terminal pane: the Transcript's allowlist and key check
    /// (open), so only a key in this session's refs opens a card; anything else is dropped.
    static func openTerminalLink(_ url: URL, _ w: AgentsNSWindow?, key: AgentSessionKey?) {
        guard let r = terminalRefs(w, key) else { return }
        _ = open(url, refs: r.refs) { panel(r.pane, r.target, r.refs).openRef($0) }
    }
}

extension XrayPanelModel {
    /// #1565 (X-T b, 6.2): the hover card, unpinned: the ref's header at once from the cached row (kind, text, title,
    /// count), no read yet (XrayHover starts the light one). `closed` runs once when it goes, whoever closed it.
    func hoverRef(_ e: XrayRefs.Entry, hover: XrayHover, closed: @escaping @MainActor () -> Void) {
        (refContext, refNote) = (nil, nil)
        presentRef(AnyView(XrayRefPopover(panel: self, entry: e, complete: refs?.complete ?? true, hover: hover)),
                   XrayRefPopover.size, closed)
    }

    /// #1565 (6.2, 6.3): the hover card's one light read (XrayPanels.budget()); a refused text says why as openRef's
    /// does. The read in flight, nil when none ran.
    @discardableResult
    func hoverRead(_ e: XrayRefs.Entry) -> Task<Void, Never>? {
        let sent = e.shape == .term ? (e.text.contains("`") ? "" : "`" + e.text + "`") : e.text   // as openRef sends it
        guard panels?.runRef(sent, shown: e.text, budget: XrayPanels.budget(), for: self) == true else {
            refNote = panels?.refTooLong(sent, for: self) == true ? Self.refTooLong : Self.refNotARef
            return nil
        }
        return panels?.refReading
    }
}

/// XrayRefSpans.find: where the underlined refs occur in one prose text. Pure.
enum XrayRefSpans {
    struct Span: Equatable {
        let range: Range<String.Index>
        let key: String
    }

    /// Each `underline` ref's literal text, bounded by a non-word character (Unicode letters, digits, marks and "_" are
    /// word characters, so "#831\u{E9}" is no match), never inside a backtick code span; a longer ref wins an overlap.
    static func find(_ text: String, _ refs: [XrayRefs.Entry]) -> [Span] {
        let code = codeSpans(text)
        var out: [Span] = []
        // shortcut: one range(of:) scan per ref and clip; a memo per text if 2000-ref sessions draw slowly
        for e in refs.filter(\.underline).sorted(by: { $0.text.count > $1.text.count }) where !e.text.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: e.text, range: from..<text.endIndex), !r.isEmpty {
                from = r.upperBound
                guard !word(text[..<r.lowerBound].last), !word(text[r.upperBound...].first),
                      !code.contains(where: { $0.overlaps(r) }), !out.contains(where: { $0.range.overlaps(r) }) else { continue }
                out.append(Span(range: r, key: e.key))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// #1357 (P9): the key of the underlined ref covering grid column `col` of one viewport line, or nil. Columns are cells:
    /// a wide character takes two. A url or file ref is skipped: libghostty already makes those Cmd-click links, which go to
    /// the browser or the Text Viewer as before (no second action on one click).
    static func key(atColumn col: Int, in line: String, refs: [XrayRefs.Entry]) -> String? {
        guard col >= 0 else { return nil }
        for sp in find(line, refs.filter { $0.shape != .url && $0.shape != .file }) {
            let lo = cells(line[..<sp.range.lowerBound])
            if col >= lo, col < lo + cells(line[sp.range]) { return sp.key }
        }
        return nil
    }

    /// Terminal cells of a text: two for an East Asian wide or emoji-presentation character, else one.
    /// shortcut: a fixed range list, not wcwidth; a rare wide script outside it shifts a click by a cell.
    static func cells(_ s: Substring) -> Int {
        s.reduce(0) { n, ch in
            guard let v = ch.unicodeScalars.first else { return n }
            let wide = v.properties.isEmojiPresentation || [0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
                0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD].contains { $0.contains(v.value) }
            return n + (wide ? 2 : 1)
        }
    }

    static func word(_ c: Character?) -> Bool {
        guard let c else { return false }
        if c.isLetter || c.isNumber || c == "_" { return true }
        // a mark alone: the match split a character (e + U+0301)
        return c.unicodeScalars.first.map { [.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory) } == true
    }

    /// Markdown inline code in raw text: from a backtick to the next one.
    /// shortcut: single backticks pair up; a ``double`` run is read as two empty spans, fine for refs.
    static func codeSpans(_ t: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = [], open: String.Index?
        for i in t.indices where t[i] == "`" {
            if let o = open { out.append(o..<t.index(after: i)); open = nil } else { open = i }
        }
        return out
    }

    /// The clip's text with each span linked (prosper-xray, the key only) and underlined dotted at 0.6 in `color`;
    /// nothing else changes (font, runs). Markdown code runs and existing links are left alone. nil: gate B off or no
    /// refs, so the caller draws as before.
    @MainActor static func attributed(_ s: String, markdown: Bool, refs: [XrayRefs.Entry], color: Color) -> AttributedString? {
        guard XrayRefLink.decorate(), !refs.isEmpty else { return nil }
        XrayRefLink.drawn?(s)
        var a = markdown ? transcriptMarkdown(s) ?? AttributedString(s) : AttributedString(s)
        decorate(&a, refs: refs, color: color)
        return a
    }

    @discardableResult
    static func decorate(_ a: inout AttributedString, refs: [XrayRefs.Entry], color: Color) -> Bool {
        // scalar offsets, not indices: an index is not carried across a mutation
        var marks: [(lo: Int, n: Int, url: URL)] = []
        for run in a.runs where run.link == nil && run.inlinePresentationIntent?.contains(.code) != true {
            let t = String(a[run.range].characters)
            let base = a.unicodeScalars.distance(from: a.startIndex, to: run.range.lowerBound)
            for sp in find(t, refs) {
                guard let url = XrayRefLink.url(sp.key) else { continue }
                marks.append((base + t.unicodeScalars.distance(from: t.startIndex, to: sp.range.lowerBound),
                              t.unicodeScalars.distance(from: sp.range.lowerBound, to: sp.range.upperBound), url))
            }
        }
        for (lo, n, url) in marks {
            let start = a.unicodeScalars.index(a.startIndex, offsetBy: lo)
            let r = start..<a.unicodeScalars.index(start, offsetBy: n)
            a[r].link = url
            a[r][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = Text.LineStyle(pattern: .dot, color: color.opacity(0.6))
        }
        return !marks.isEmpty
    }
}

/// The per-window refs cache, keyed by session (dir, name) with dch's session_id. One `--json` read when the window
/// is key and visible and its focused pane shows a local session in Transcript mode; again only after the transcript
/// grew and 30 s passed; none while blurred or hidden; another session_id drops the entry; window close empties it.
/// Replaces spec 5.8's --follow stream for P8 (Q2).
@MainActor
final class XrayRefCache: ObservableObject {
    /// The focused Transcript pane: its session, conversation id and the last block's id; `active`: its window is key
    /// and visible (false: blurred or hidden, no read).
    struct Focus: Equatable {
        let active: Bool
        let target: XrayTarget
        let key: AgentSessionKey
        let sessionID: String
        let mark: Int
    }

    struct Entry {
        let sessionID: String
        var refs: XrayRefs?
        var mark: Int
        var readAt: Date
    }

    static let reread: TimeInterval = 30

    @Published private(set) var entries: [AgentSessionKey: Entry] = [:]
    var focus: @MainActor () -> Focus? = { nil }
    var now: () -> Date = Date.init
    var dch: @MainActor () -> String? = { XrayPanels.dch() }
    var run: XrayPanels.Run = XrayPanels.run
    private(set) var reading: Task<Void, Never>?
    private var stopTicker: (() -> Void)?
    private var observer: NSObjectProtocol?

    /// The window's cache, made on first use (gate B on only): ticks each second; the window's close empties it.
    private static var caches: [ObjectIdentifier: XrayRefCache] = [:]

    static func of(_ w: NSWindow, focus: @escaping @MainActor () -> Focus?) -> XrayRefCache {
        if let c = caches[ObjectIdentifier(w)] { return c }
        let c = XrayRefCache()
        c.focus = focus
        caches[ObjectIdentifier(w)] = c
        c.stopTicker = XrayPanels.ticker { [weak c] in c?.tick() }
        let id = ObjectIdentifier(w)
        c.observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                c.clear()
                caches[id] = nil
            }
        }
        return c
    }

    /// The window's cache with the product's focus.
    static func of(_ w: AgentsNSWindow) -> XrayRefCache { of(w) { [weak w] in w.flatMap { focused(in: $0) } } }

    /// The product's focus: the window's focused pane on a local session whose transcript is this session's: a History row
    /// or an ended session's held row (#1471), and since #1357 (P9) a live session's Terminal pane too.
    static func focused(in w: AgentsNSWindow) -> Focus? {
        guard let m = w.model,
              let t = XrayTarget.of(m.selectedRow), let dir = t.dir, let tr = m.focusedRuntime?.transcript,
              let id = tr.source?.sessionId, tr.source?.key == AgentSessionKey(dir: dir, name: t.name) else { return nil }
        return Focus(active: w.isKeyWindow && m.visible, target: t, key: AgentSessionKey(dir: dir, name: t.name), sessionID: id, mark: tr.blocks.last?.id ?? -1)
    }

    /// The refs for this session's conversation, if read.
    func refs(_ key: AgentSessionKey, sessionID: String?) -> XrayRefs? {
        entries[key].flatMap { $0.sessionID == sessionID ? $0.refs : nil }
    }

    func tick() {
        guard reading == nil, let f = focus(), f.active, let dch = dch() else { return }
        if let e = entries[f.key] {
            if e.sessionID != f.sessionID { entries[f.key] = nil }   // /clear or resume: the old refs are not this one's
            else if f.mark == e.mark || now().timeIntervalSince(e.readAt) < Self.reread { return }
        }
        let started = now(), args = f.target.chaptersArgs, env = f.target.env, runner = run
        reading = Task { [weak self] in
            let r = await runner(dch, args, env)
            guard !Task.isCancelled, let self else { return }
            self.reading = nil
            var refs = r.status == 0 ? XrayRefs.parse(r.out) : nil
            if let id = refs?.sessionID, id != f.sessionID { refs = nil }   // dch read another conversation: none drawn
            self.entries[f.key] = Entry(sessionID: f.sessionID, refs: refs, mark: f.mark, readAt: started)
        }
    }

    func clear() {
        reading?.cancel()
        reading = nil
        entries = [:]
        stopTicker?()
        stopTicker = nil
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
    }
}

private struct XrayRefEntriesKey: EnvironmentKey { static let defaultValue: [XrayRefs.Entry] = [] }

extension EnvironmentValues {
    /// #1418: the underlined refs of the transcript's session (empty: gate B off, none read).
    var xrayRefEntries: [XrayRefs.Entry] {
        get { self[XrayRefEntriesKey.self] }
        set { self[XrayRefEntriesKey.self] = newValue }
    }
}

/// On the transcript view: with gate B on, the session's underlined refs for its prose clips and the link handler.
struct XrayRefScope: ViewModifier {
    @ObservedObject var transcript: AgentTranscriptModel
    @Environment(\.agentPaneID) private var pane

    func body(content: Content) -> some View {
        if XrayRefLink.decorate(), let w = window, let m = w.model {
            content.modifier(Linked(cache: XrayRefCache.of(w), transcript: transcript, pane: pane ?? m.layout.focused))
        } else {
            content
        }
    }

    /// The pane's window (the single pane with the split gate off registers its anchor under nil).
    private var window: AgentsNSWindow? {
        pane.flatMap { XrayPanels.window($0) } ?? XrayCardAnchor.views[nil]?.view?.window as? AgentsNSWindow
    }

    private struct Linked: ViewModifier {
        @ObservedObject var cache: XrayRefCache
        let transcript: AgentTranscriptModel
        let pane: UUID

        func body(content: Content) -> some View {
            let key = transcript.source?.key
            let refs = key.flatMap { cache.refs($0, sessionID: transcript.source?.sessionId) }
            content
                .environment(\.xrayRefEntries, refs?.entries.filter(\.underline) ?? [])
                .environment(\.openURL, OpenURLAction { url in
                    let outcome = MainActor.assumeIsolated {   // SwiftUI calls the action on main
                        XrayRefLink.open(url, refs: refs) { e in
                            guard let key, let refs else { return }
                            XrayRefLink.panel(pane, XrayTarget(name: key.name, dir: key.dir), refs).openRef(e)
                        }
                    }
                    return switch outcome { case .handled: .handled; case .system: .systemAction; case .discarded: .discarded }
                })
        }
    }
}
