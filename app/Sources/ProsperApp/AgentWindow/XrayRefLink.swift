import AppKit
import SwiftUI

// #1418 (#1356 step 4, spec 5.1): clickable refs. Each ref dch marks `underline` gets a dotted underline and a
// prosper-xray link (the chapter card's answer text); a click opens the ref card (XrayRefPopover) through the window's presenter.
// Gate B (XrayRefLink.decorate) ships on (#1419); while off, no underline, no link.
// #1357 (P9): a Cmd-click on an underlined ref on the grid, or a prosper-xray OSC 8 link, opens the same card through the
// same panel (AgentTerminalHostView.refClick, AgentTerminalController.open).
// #1559 (X-T a): the Terminal pane's refs come from the focused pane's follow (terminalRefs), and its grid draws their
// marks (XrayGridMarks.swift). #1600: the Transcript view's cache, scope and markdown path went with the view (#1471).

@MainActor
enum XrayRefLink {
    /// Gate B. On since #1419 (#1356 step 5); rows set `decorate` and restore it.
    static let ships = true
    static var decorate: @MainActor () -> Bool = { ships }

    nonisolated static let scheme = "prosper-xray"

    /// RFC 3986 unreserved: every other byte of the key is percent-encoded.
    nonisolated private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// prosper-xray://ref?k=<key>: the key alone, never the text or the title.
    nonisolated static func url(_ key: String) -> URL? {
        guard let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "\(scheme)://ref?k=\(k)")
    }

    /// The key of a link this view made: scheme prosper-xray, host ref, one `k` and nothing else, and a key in `refs`
    /// (the pane's follow). A forged or stale link is refused (nil).
    static func key(from url: URL, in refs: XrayRefs?) -> String? {
        guard url.scheme == scheme, let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.host == "ref",
              c.user == nil, c.password == nil, c.port == nil, c.path.isEmpty, c.fragment == nil,
              let items = c.queryItems, items.count == 1, let item = items.first, item.name == "k",
              let k = item.value, !k.isEmpty, refs?.entries.contains(where: { $0.key == k }) == true else { return nil }
        return k
    }

    enum Outcome: Equatable { case handled, system, discarded }

    /// The OpenURLAction rule (chapter card, OSC 8 links): prosper-xray shows the ref's card (`show`); http, https and mailto: go to the
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
        // #1568: a remote target's --ref goes over the warm host:name connection (XrayRequests; cold when busy or failed)
        (m.dch, m.run, m.refs) = (XrayPanels.dch(), XrayPanels.shared.requests.run(for: target, cold: XrayPanels.run), refs)
        XrayPanels.shared.wire(m, pane)
        return m
    }

    /// #1357 (P9): the refs for `key` when it is the window's focused pane's session (a Cmd-click reaches only the
    /// focused pane: the window's first-click rule takes a focusing down), its target and that pane. #1559: from the
    /// follow that pane's focus attached (XrayFollows.focus), not the transcript, so a shell or Codex pane has them too.
    /// Nil: gate B off, no window, another session, or no snapshot yet. #1568: a remote row's follow is "host:name".
    static func terminalRefs(_ w: AgentsNSWindow?, _ key: AgentSessionKey?) -> (refs: XrayRefs, target: XrayTarget, pane: UUID)? {
        guard decorate(), let w, let key, let m = w.model, let f = XrayPanels.shared.follows.focused(in: ObjectIdentifier(w)),
              f.target == target(key), let refs = f.state?.refs else { return nil }
        return (refs, f.target, m.layout.focused)
    }

    /// #1568 (X-R a): a terminal session's X-ray target: a remote row's "host:name" with no dir (dch dials the host), a
    /// local one's name and socket dir. Nil: no name, or a host or name dch would read as a flag (XrayTarget.of's rule).
    static func target(_ key: AgentSessionKey) -> XrayTarget? {
        guard !key.name.isEmpty, !key.name.hasPrefix("-") else { return nil }
        guard let host = AgentTerminalSpawn.remoteHost(key) else { return XrayTarget(name: key.name, dir: key.dir) }
        return host.isEmpty || host.hasPrefix("-") ? nil : XrayTarget(name: "\(host):\(key.name)", dir: nil)
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
    /// #1568 (K4.1): a remote target's hover runs nothing: the window's cached answer (XrayRefResults, a full one first)
    /// when there is one, and "Pin for passages" (Pin runs the full read).
    @discardableResult
    func hoverRead(_ e: XrayRefs.Entry) -> Task<Void, Never>? {
        if target.dir == nil {
            if let hit = refResults()?.get(XrayRefResults.Key(target: target, ref: e.text, light: true, scope: "project")) {
                takeRef((0, hit.out), text: e.text, light: hit.light, cached: true)
            }
            refNote = Self.pinForPassages
            return nil
        }
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
    static func find(_ text: String, _ refs: [XrayRefs.Entry]) -> [Span] { find(text, prepare(refs)) }

    /// #1655: the refs find() scans, filtered (underline, a text) and sorted (a longer ref first, stable) once per refs
    /// change, not once per line; each with its text's canonical (NFD) scalars as an ASCII bitmap for the pre-check.
    struct Prepared: Sendable {
        struct Ref: Sendable {
            let text: String
            let key: String
            /// The NFD scalars: all ASCII, their count and their 128-bit bitmap (lo: 0-63, hi: 64-127).
            let ascii: Bool
            let n: Int
            let lo: UInt64
            let hi: UInt64
        }
        let refs: [Ref]
    }

    static func prepare(_ refs: [XrayRefs.Entry]) -> Prepared {
        let kept = refs.filter { $0.underline && !$0.text.isEmpty }.map { ($0, $0.text.count) }.sorted { $0.1 > $1.1 }.map { $0.0 }
        return Prepared(refs: kept.map { e in
            let s = Array(e.text.decomposedStringWithCanonicalMapping.unicodeScalars)
            let m = mask(s)
            return .init(text: e.text, key: e.key, ascii: s.allSatisfy(\.isASCII), n: s.count, lo: m.lo, hi: m.hi)
        })
    }

    /// The ASCII scalars of `s` as a 128-bit bitmap; other scalars set nothing.
    static func mask<S: Sequence>(_ s: S) -> (lo: UInt64, hi: UInt64) where S.Element == Unicode.Scalar {
        var (lo, hi) = (UInt64(0), UInt64(0))
        for c in s where c.isASCII {
            if c.value < 64 { lo |= 1 << UInt64(c.value) } else { hi |= 1 << UInt64(c.value - 64) }
        }
        return (lo, hi)
    }

    static func find(_ text: String, _ prepared: Prepared) -> [Span] {
        var scans = 0
        return find(text, prepared, scans: &scans)
    }

    /// `scans`: plus one per ref range(of:) looked for (#1655's rows count the pre-check's savings).
    static func find(_ text: String, _ prepared: Prepared, scans: inout Int) -> [Span] {
        let code = codeSpans(text)
        var out: [Span] = []
        // #1655: an ASCII line is its own NFD, so a match there is the ref's NFD scalars: a ref with a non-ASCII one, a
        // scalar the line lacks, or more scalars than the line cannot occur and skips range(of:). Other lines scan all.
        let ascii = text.utf8.allSatisfy { $0 < 0x80 }
        let (n, m) = ascii ? (text.utf8.count, mask(text.unicodeScalars)) : (0, (lo: UInt64(0), hi: UInt64(0)))
        for e in prepared.refs {
            if ascii, !e.ascii || e.n > n || e.lo & ~m.lo != 0 || e.hi & ~m.hi != 0 { continue }
            scans += 1
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

    /// The text with each span linked (prosper-xray, the key only) and underlined dotted at 0.6 in `color`; nothing else
    /// changes. nil: gate B off or no refs, so the caller draws as before.
    @MainActor static func attributed(_ s: String, refs: [XrayRefs.Entry], color: Color) -> AttributedString? {
        guard XrayRefLink.decorate(), !refs.isEmpty else { return nil }
        var a = AttributedString(s)
        decorate(&a, refs: refs, color: color)
        return a
    }

    @discardableResult
    static func decorate(_ a: inout AttributedString, refs: [XrayRefs.Entry], color: Color) -> Bool {
        // scalar offsets, not indices: an index is not carried across a mutation
        var marks: [(lo: Int, n: Int, url: URL)] = []
        for run in a.runs {
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
