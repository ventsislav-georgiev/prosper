import SwiftUI

// #1625 (dch #516, 1.113.0, README v1.113.0:2132-2158): "since you were last here". When the focused pane's session
// comes back into focus 30 min or more after it last left it (in memory, per session and per Mac; nothing persisted),
// one `dch --xray <n> --since <epoch> --json` read runs and a one-line strip over the pane's top names the chapters
// begun since and the refs mentioned. A title opens that chapter's card, as a Prompts row does; x or a keystroke into
// the terminal dismisses it. dch 1.113.0 and later only; a remote session's read goes over the warm --requests line.

/// dch's `--since` answer. Every string is outside data: drawn through OutsideText.shown (title, refsLine).
struct XrayRecap: Equatable {
    struct Chapter: Equatable {
        /// dch's `chapter` anchor (the --chapter form's argument; DchCtl.anchorOK checks it before any read).
        var anchor: String
        /// dch's `turn_title`; nil when dch sent null.
        var title: String?
        var at: Date?
    }

    struct Ref: Equatable {
        var key: String
        var shape: String
        var text: String
        /// The mentions since `since` (1 when dch sent no good count).
        var count: Int
        var lastAt: Date?
    }

    var since: Date?
    var chapters: [Chapter]
    var refs: [Ref]
    /// dch's `more` (a cap cut), or more rows than dch's caps came.
    var more: Bool
    /// dch's `partial`: the read stopped before `since`; only the newest turns are here.
    var partial: Bool

    /// dch 1.113.0 (#516) knows `--since` (XraySearch.scopeMinimum's pattern).
    static let minimumDch = [1, 113, 0]
    static func supported(_ version: [Int]?) -> Bool { version.map { DchCommand.isAtLeast($0, minimumDch) } ?? false }

    /// The gap: a session focused again this long after it last left the focus gets a recap.
    static let gap: TimeInterval = 30 * 60

    /// dch's caps (20 chapters, 30 refs) held against a host that sends more; a title as TranscriptOutline's.
    static let maxChapters = 20
    static let maxRefs = 30
    static let anchorCap = 128
    static let keyCap = 512
    static let textCap = 240
    static let shapeCap = 16
    /// The strip draws the first 3 titles and the top 3 refs.
    static let shownChapters = 3
    static let shownRefs = 3

    var isEmpty: Bool { chapters.isEmpty && refs.isEmpty }

    /// Bytes in, never throws: nil unless one object with schema 1 and both arrays. A row that is not an object, a
    /// chapter with no anchor or a ref with no key or text is skipped.
    static func parse(_ data: Data) -> XrayRecap? {
        guard data.count <= XrayChapters.maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["schema"] as? Int == 1, let cs = o["chapters"] as? [Any], let rs = o["refs"] as? [Any] else { return nil }
        func text(_ v: Any?, _ max: Int) -> String? { (v as? String).map { String($0.unicodeScalars.prefix(max)) } }
        // bounded before Date: a far time from outside stays in range
        func date(_ v: Any?) -> Date? { (v as? Double).flatMap { (0...1e10).contains($0) ? Date(timeIntervalSince1970: $0) : nil } }
        let chapterRows = cs.compactMap { $0 as? [String: Any] }, refRows = rs.compactMap { $0 as? [String: Any] }
        let chapters = chapterRows.prefix(maxChapters).compactMap { c -> Chapter? in
            guard let a = text(c["chapter"], anchorCap), !a.isEmpty else { return nil }
            return Chapter(anchor: a, title: text(c["turn_title"], TranscriptOutline.titleCap), at: date(c["at"]))
        }
        let refs = refRows.prefix(maxRefs).compactMap { r -> Ref? in
            guard let k = text(r["key"], keyCap), !k.isEmpty, let t = text(r["text"], textCap) else { return nil }
            return Ref(key: k, shape: text(r["shape"], shapeCap) ?? "", text: t, count: XrayChapters.count(r["count"]) ?? 1,
                       lastAt: date(r["last_at"]))
        }
        return XrayRecap(since: date(o["since"]), chapters: chapters, refs: refs,
                         more: XrayChapters.isTrue(o["more"]) || chapterRows.count > maxChapters || refRows.count > maxRefs,
                         partial: XrayChapters.isTrue(o["partial"]))
    }

    /// "Since you were last here: 3 chapters" ("20+" past a cap; "only the newest" when dch stopped early).
    var headline: String {
        let n = chapters.count
        return "Since you were last here: \(n)\(more ? "+" : "") chapter\(n == 1 && !more ? "" : "s")"
            + (partial ? " (only the newest)" : "")
    }

    /// A chapter's title as drawn: cleaned and cut; "Untitled turn" for none.
    static func title(_ c: Chapter) -> String {
        let t = OutsideText.shown(c.title ?? "", max: 60)
        return t.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled turn" : t
    }

    /// The top refs, cleaned: "o/r#41 \u{00D7}2, main.swift".
    var refsLine: String {
        refs.prefix(Self.shownRefs).map { OutsideText.shown($0.text, max: 40) + ($0.count > 1 ? " \u{00D7}\($0.count)" : "") }
            .joined(separator: ", ")
    }
}

extension XrayTarget {
    /// #1625: dch README v1.113.0:2132 "dch --xray <n> --since <time> --json"; the time as epoch seconds (the Mac's
    /// clock, so a remote host's own clock never moves it), floored: dch keeps what began at or after it.
    func sinceArgs(_ since: Date) -> [String] {
        let s = since.timeIntervalSince1970
        return ["--xray", name, "--since", String(Int(s.isFinite ? min(max(s, 0), 1e10) : 0)), "--json"]
    }
}

/// #1625: when each session last left the focus, in memory. `current` is the session the focused pane of the key
/// window shows (nil: none, or the app is away).
struct XrayRecapClock {
    private(set) var left: [XrayTarget: Date] = [:]
    private(set) var current: XrayTarget?
    /// Bounds `left`: past it the oldest goes.
    static let maxKept = 256

    /// The focus moves to `target`. The one that held it is stamped left now. Returns the time to read from when
    /// `target` left the focus XrayRecap.gap or more ago; nil for the same target, a first focus, a short gap, or a
    /// clock that went back.
    mutating func focus(_ target: XrayTarget?, now: Date) -> Date? {
        guard target != current else { return nil }
        if let c = current { left[c] = now }
        current = target
        if left.count > Self.maxKept, let oldest = left.min(by: { $0.value < $1.value })?.key { left[oldest] = nil }
        guard let target, let l = left[target], now.timeIntervalSince(l) >= XrayRecap.gap else { return nil }
        return l
    }
}

/// #1625: the app's one recap: the clock, the read in flight and the strip shown (one at a time: the focused pane's).
@MainActor
final class XrayRecaps: ObservableObject {
    static let shared = XrayRecaps()

    struct Shown: Equatable {
        let target: XrayTarget
        let recap: XrayRecap
    }

    @Published private(set) var shown: Shown?
    private(set) var clock = XrayRecapClock()
    private var reading: Task<Void, Never>?
    /// Reads started (rows count them).
    private(set) var reads = 0

    var now: () -> Date = Date.init
    /// Seams: the dch path (XrayTabs.gate; nil under XCTest), its probed version, the runner (a remote target's goes
    /// over the warm --requests line, XrayRequests.run; the cold runner never runs under XCTest), the chapter jump.
    var dch: @MainActor () -> String? = { XrayPanels.dch() }
    var version: @MainActor () -> [Int]? = { XrayPanels.probed?.version }
    var run: @MainActor (XrayTarget) -> XrayPanels.Run = { XrayPanels.shared.requests.run(for: $0, cold: XrayPanels.run) }
    var openChapter: @MainActor (XrayRecap.Chapter, UUID, XrayTarget) -> Void = { XrayRecaps.jump($0, pane: $1, target: $2) }

    /// The key window's focused pane shows `target`. Another target than the last: the old strip and read go; after
    /// the gap, on dch 1.113.0+, one --since read from when `target` last left the focus.
    func focus(_ target: XrayTarget) {
        guard target != clock.current else { return }
        let since = clock.focus(target, now: now())
        dismiss()
        guard let since, XrayRecap.supported(self.version()), let dch = self.dch() else { return }
        let run = self.run(target), args = target.sinceArgs(since), env = target.env
        reads += 1
        reading = Task { [weak self] in
            let r = await run(dch, args, env)
            guard !Task.isCancelled, let self else { return }   // focus moved or dismissed: the answer is not news
            self.reading = nil
            self.take(r, for: target)
        }
    }

    /// `target` left the focus (its pane went, the window or the app went away): stamped now. Another target's: nothing.
    func leave(_ target: XrayTarget) {
        guard clock.current == target else { return }
        _ = clock.focus(nil, now: now())
        dismiss()
    }

    /// Exit 0 and a non-empty parse while `target` still holds the focus: the strip. Anything else: none.
    func take(_ r: (status: Int32, out: Data), for target: XrayTarget) {
        guard clock.current == target, r.status == 0, let recap = XrayRecap.parse(r.out), !recap.isEmpty else { return }
        shown = Shown(target: target, recap: recap)
    }

    /// The x, a keystroke into the terminal, a focus move: the strip goes and a read in flight is cancelled.
    func dismiss() {
        reading?.cancel()
        reading = nil
        if shown != nil { shown = nil }
    }

    /// A title's click: that chapter's card through the pane's open panel on this session, else a new one wired to the
    /// window's presenter (XrayRefLink.panel's pattern).
    static func jump(_ c: XrayRecap.Chapter, pane: UUID, target: XrayTarget) {
        let panels = XrayPanels.shared
        if let m = panels.open[pane], m.target == target { return m.openRecapChapter(c) }
        let m = XrayPanelModel(target: target, tab: .prompts)
        (m.dch, m.run) = (XrayPanels.dch(), panels.requests.run(for: target, cold: XrayPanels.run))
        panels.wire(m, pane)
        m.openRecapChapter(c)
    }
}

extension XrayPanelModel {
    /// #1625: the ordinal a recap chapter takes when the panel's chapters do not hold it (dch's are 1 and up).
    static let recapOrdinal = -1

    /// #1625: a recap title's card: the panel's own chapter for that anchor, else one titled from the recap whose
    /// --chapter read (openChapterCard; the anchor checked there) fills it.
    func openRecapChapter(_ c: XrayRecap.Chapter) {
        if let i = chapterAnchors[c.anchor], let ch = dchChapters?.last(where: { $0.ordinal == i }) { return openChapterCard(ch) }
        chapterAnchors = chapterAnchors.filter { $0.value != Self.recapOrdinal }
        chapterAnchors[c.anchor] = Self.recapOrdinal
        openChapterCard(TranscriptOutline.Chapter(id: Self.recapOrdinal, ordinal: Self.recapOrdinal, title: c.title ?? "",
                                                  kind: .prompt, hasError: false))
    }
}

/// #1625: the strip, in the focused pane's top overlay (AgentsWindow terminalPane and the remote pane); it also tells
/// XrayRecaps when this pane's session takes and leaves the focus (the window's key state is the app's).
struct XrayRecapStrip: View {
    let pane: UUID
    let target: XrayTarget?
    @ObservedObject var recaps = XrayRecaps.shared
    @Environment(\.controlActiveState) private var active

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if let target, let s = recaps.shown, s.target == target { line(s.recap, target) }
        }
        .onAppear { sync() }
        .onChange(of: target) { old, _ in
            if let old { recaps.leave(old) }
            sync()
        }
        .onChange(of: active) { _, _ in sync() }
        .onDisappear { if let target { recaps.leave(target) } }
    }

    private func sync() {
        guard let target else { return }
        if active == .inactive { recaps.leave(target) } else { recaps.focus(target) }
    }

    private func line(_ r: XrayRecap, _ target: XrayTarget) -> some View {
        HStack(spacing: sz(8)) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Neon.blue).accessibilityHidden(true)
            Text(verbatim: r.headline).foregroundStyle(Neon.textPrimary).lineLimit(1).layoutPriority(1)
            ForEach(Array(r.chapters.prefix(XrayRecap.shownChapters).enumerated()), id: \.offset) { _, c in
                Button { recaps.openChapter(c, pane, target) } label: { Text(verbatim: XrayRecap.title(c)).lineLimit(1) }
                    .buttonStyle(.plain).foregroundStyle(Neon.blue)
                    .accessibilityLabel("Open chapter " + XrayRecap.title(c))
            }
            if !r.refs.isEmpty {
                Text(verbatim: r.refsLine).foregroundStyle(Neon.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { recaps.dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Neon.textSecondary)
                .help("Dismiss").accessibilityLabel("Dismiss the recap")
        }
        .font(Neon.font(11))
        .padding(.horizontal, sz(12)).padding(.vertical, sz(5))
        .background(Neon.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Neon.stroke).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}
