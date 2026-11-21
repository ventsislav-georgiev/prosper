import SwiftUI

// #1472: a Prompts or Responses row's card for a pane with no transcript to jump in (Terminal mode, a remote row): the
// prompt and its response from dch's chapters, shaped as the memory card (plain text that scrolls, the same presenter,
// so Esc and a click outside close it the same way). With gate B on, the refs in the response link to the ref card.

struct XrayChapterCard: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let chapter: TranscriptOutline.Chapter
    /// #1472 b: the card's `--chapter` read (XrayPanelModel.openChapterCard); none: the capped text alone.
    @ObservedObject var read = XrayChapterRead()
    /// The panel's refs (gate B underlines them) and the link handler (XrayPanelModel.openLink).
    var refs: [XrayRefs.Entry] = []
    var link: (URL) -> XrayRefLink.Outcome = { _ in .discarded }
    /// #1814: the drawer's filter when the card opened; highlighted in the prompt and the response.
    var match = ""

    static let size = XrayMemoryCard.size
    static let noResponse = "No response yet."

    /// "Prompt 3", after dch's mark when it has one (another session's message, a hand-back, an automatic prompt).
    /// #1764: a recap title's card the panel's prompts do not hold (XrayPanelModel.recapOrdinal) is "Earlier prompt".
    static func heading(_ c: TranscriptOutline.Chapter) -> String {
        let row = XrayPromptRow(c)
        let name = c.ordinal == XrayPanelModel.recapOrdinal ? "Earlier prompt" : "Prompt \(row.ordinal)"
        return [row.mark, name].compactMap { $0 }.joined(separator: " ")
    }

    /// The prompt as dch gives it (its title, dch's 120-scalar cap), cleaned as the row's.
    static func prompt(_ c: TranscriptOutline.Chapter) -> String { XrayPromptRow(c).title }

    /// The whole response dch gives (at most 2048 bytes), its line breaks kept, cleaned as a memory body; nil: none yet.
    static func response(_ c: TranscriptOutline.Chapter) -> String? {
        c.response.map { OutsideText.capMarks(XrayMemory.cleanBody($0).text) }
    }

    static func tools(_ c: TranscriptOutline.Chapter) -> String? {
        c.tools.map { OutsideText.shown($0, max: 160) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// #1487: a text as drawn: the head, a quiet note where dch cut (or after the text: the old rule, or no marker found),
    /// the tail.
    struct Parts: Equatable {
        var head: String
        var note: String?
        var tail: String?
    }

    /// #1472 b: the whole prompt (the read's user text, else the title), then "cut at 6000 characters" when dch cut it.
    /// #1487: dch 1.93.0 cuts by its `cut` count (head, note, tail).
    static func promptParts(_ c: TranscriptOutline.Chapter, _ full: XrayChapterRead.Full?) -> Parts {
        guard let f = full, let p = f.prompt else { return Parts(head: prompt(c)) }
        return Parts(head: p, note: f.promptCutChars.map(XrayChapters.cutLine) ?? (f.promptCut ? XrayChapterRead.cutNote : nil), tail: f.promptTail)
    }

    /// #1472 b: the whole final response (the read's last assistant text, else the capped one); nil: none yet.
    /// #1487: the chapter's own response with dch's `response_cut_chars` is split at its "\u{2026}" line.
    static func responseParts(_ c: TranscriptOutline.Chapter, _ full: XrayChapterRead.Full?) -> Parts? {
        if let f = full, let r = f.response {
            return Parts(head: r, note: f.responseCutChars.map(XrayChapters.cutLine) ?? (f.responseCut ? XrayChapterRead.cutNote : nil), tail: f.responseTail)
        }
        guard let raw = c.response else { return nil }
        func clean(_ s: String) -> String { OutsideText.capMarks(XrayMemory.cleanBody(s).text) }
        guard let n = c.responseCutChars else { return Parts(head: clean(raw)) }
        guard let s = XrayChapters.split(raw, line: "\u{2026}") else { return Parts(head: clean(raw), note: XrayChapters.cutLine(n)) }
        return Parts(head: clean(s.head), note: XrayChapters.cutLine(n), tail: clean(s.tail))
    }

    static func prompt(_ c: TranscriptOutline.Chapter, _ full: XrayChapterRead.Full?) -> String { promptParts(c, full).head }

    /// The head of the final response (see responseParts); nil: none yet.
    static func response(_ c: TranscriptOutline.Chapter, _ full: XrayChapterRead.Full?) -> String? { responseParts(c, full)?.head }

    /// Everything the card says, in order (VoiceOver and the rows); #1472 b: with the read's text and note when given.
    static func text(_ c: TranscriptOutline.Chapter, full: XrayChapterRead.Full? = nil, note: String? = nil) -> String {
        let p = promptParts(c, full), r = responseParts(c, full)
        return [heading(c), p.head, p.note, p.tail, tools(c).map { "Tools: " + $0 },
                "Response", r?.head ?? noResponse, r?.note, r?.tail, note]
            .compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        let full = read.full
        let pp = Self.promptParts(chapter, full), rp = Self.responseParts(chapter, full)
        VStack(alignment: .leading, spacing: sz(8)) {
            Text(verbatim: Self.heading(chapter)).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: sz(8)) {
                    XrayRichBlock(text: pp.head, size: 12, strong: true, match: match)
                        .accessibilityLabel("Prompt: \(pp.head)")
                    if let n = pp.note { faint(n) }
                    if let t = pp.tail { XrayRichBlock(text: t, size: 12, strong: true, match: match) }
                    if let t = Self.tools(chapter) {
                        Text(verbatim: "Tools: " + t).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                    }
                    Text(verbatim: "Response").font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                    answerText(rp?.head, empty: Self.noResponse)
                        .accessibilityLabel("Response: \(rp?.head ?? Self.noResponse)")
                    if let n = rp?.note { faint(n) }
                    if let t = rp?.tail { answerText(t, empty: "") }
                    if let n = read.note { faint(n) }
                }
            }
        }
        .padding(sz(12))
        .environment(\.openURL, OpenURLAction { url in
            let outcome = MainActor.assumeIsolated { link(url) }   // SwiftUI calls the action on main (as the terminal link)
            return switch outcome { case .handled: .handled; case .system: .systemAction; case .discarded: .discarded }
        })
    }

    private func answerText(_ answer: String?, empty: String) -> some View {
        Group {
            if let answer {
                XrayRichBlock(text: answer, size: 11, match: match, refs: refs)
            } else {
                Text(verbatim: empty).font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }
    }

    private func faint(_ s: String) -> some View {
        Text(verbatim: s).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
    }
}

/// #1814: a card's text (the chapter card's prompt and response, the memory card's title and body) drawn with
/// XrayRich, the ref card's renderer: bold, italics, inline code, links and lists inline; headings bold; fenced code in
/// the mono face. The drawer's filter `match` is highlighted as the ref card's filter is. Parsed off main once per text
/// (`.task(id:)`: a card's open, the --chapter read's arrival), never in a body; until then the plain text shows.
struct XrayRichBlock: View {
    let text: String
    var size: CGFloat = 11
    /// Every run semibold (the prompt, the memory title), as the plain text drew it.
    var strong = false
    var match = ""
    /// The panel's refs: linked as XrayRefSpans.attributed links them (gate B).
    var refs: [XrayRefs.Entry] = []
    @State private var parsed: (text: String, runs: [XrayRich.Run])?

    /// Inputs are capped upstream (memory 16 KB, a --chapter entry 6000 + 3000 scalars); this is a backstop.
    nonisolated static let cap = 32 * 1024
    /// Rows count the work, not time: one per document parsed. shortcut: unsynchronised (a test counter), atomics if read live.
    nonisolated(unsafe) static var parses = 0

    var body: some View {
        Group {
            if let p = parsed, p.text == text {
                Text(Self.attributed(p.runs, size: size, strong: strong, match: match, refs: refs))
            } else {
                Text(verbatim: text).font(Neon.font(size, weight: strong ? .semibold : .regular)).foregroundStyle(Neon.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        .task(id: text) {
            let t = text
            let runs = await Self.parse(t)
            if !Task.isCancelled { parsed = (t, runs) }
        }
    }

    /// The parse, off main.
    nonisolated static func parse(_ text: String) async -> [XrayRich.Run] {
        await Task.detached(priority: .userInitiated) { runs(text) }.value
    }

    /// A document as runs: line by line, a fence line gone and the lines between it and the next fence code (never
    /// parsed), a heading's text bold, a list item's indent kept, every other line XrayRich's inline parse (lists to
    /// bullets, quotes unmarked); then XrayRich.clean over the whole (unseen scalars, marks, the cap).
    nonisolated static func runs(_ text: String) -> [XrayRich.Run] {
        parses += 1
        var out: [XrayRich.Run] = [], fence = false
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if n > 0 { out.append(XrayRich.Run(text: "\n")) }
            let t = line.drop { $0 == " " }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { fence.toggle(); continue }
            if fence { out.append(XrayRich.Run(text: String(line), style: .code)); continue }
            let hashes = t.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), t.dropFirst(hashes).first == " " {
                out += XrayRich.runs(String(t.dropFirst(hashes + 1)), max: cap).map { XrayRich.Run(text: $0.text, style: $0.style.union(.bold)) }
                continue
            }
            if t.count < line.count, ["- ", "* ", "+ "].contains(where: { t.hasPrefix($0) }) {
                out.append(XrayRich.Run(text: String(line.prefix(line.count - t.count))))
            }
            out += XrayRich.runs(String(line), max: cap)
        }
        return XrayRich.clean(out, max: cap)
    }

    /// The runs drawn by XrayRich.attributed (the filter's hits highlighted), every run semibold when `strong`, then
    /// the refs linked when gate B is on.
    @MainActor static func attributed(_ runs: [XrayRich.Run], size: CGFloat, strong: Bool = false, match: String = "",
                                      refs: [XrayRefs.Entry] = []) -> AttributedString {
        let shown = strong ? runs.map { XrayRich.Run(text: $0.text, style: $0.style.union(.bold)) } : runs
        var a = XrayRich.attributed(shown, size: size, match: match.trimmingCharacters(in: .whitespaces))
        if XrayRefLink.decorate(), !refs.isEmpty { XrayRefSpans.decorate(&a, refs: refs, color: Neon.blue) }
        return a
    }
}

/// #1472 b: one chapter card's `dch --xray <n> --chapter <anchor> --json` read (XrayPanelModel.openChapterCard runs it,
/// the card's close cancels it). dch's object {schema 1, entries [{role, text, ...}], truncated}: the `user` entry is the
/// whole prompt, the last `assistant` entry the whole final response; tool and output entries are never shown.
@MainActor
final class XrayChapterRead: ObservableObject {
    struct Full: Equatable {
        var prompt: String?
        var promptCut = false
        /// #1487 (dch 1.93.0 `cut`): the scalars left out between `prompt` (the head) and `promptTail`; nil: no count.
        var promptTail: String?
        var promptCutChars: Int?
        var response: String?
        var responseCut = false
        var responseTail: String?
        var responseCutChars: Int?
    }

    @Published var full: Full?
    /// Why the card keeps its capped text: an exit's note, or nothing to read.
    @Published var note: String?
    var reading: Task<Void, Never>?

    /// dch cuts each entry at 6000 Unicode scalars (dch.1 ~2020) and the object at 1 MiB (plus room here).
    static let entryCap = 6000
    /// dch #451 (1.93.0): a cut entry keeps its first 6000 (entryCap) and last 3000 scalars; an entry is cut only past 9000.
    static let tailCap = 3000
    static let uncutCap = entryCap + tailCap
    static let maxBytes = 1024 * 1024 + 64 * 1024
    /// dch #451 (1.93.0): an entry is cut as head + tail and carries `cut`; older dch cut a prefix at entryCap.
    static let cutFieldsDch = [1, 93, 0]
    static let cutNote = "cut at 6000 characters"
    static let gone = "This prompt is gone or has no X-ray history"
    static let badAnchor = "dch did not take this prompt's anchor"
    static let nothing = "Nothing to read for this prompt"
    static let failed = "Reading this prompt failed"

    func cancel() {
        reading?.cancel()
        reading = nil
    }

    /// Exit 0: the text (or nothing to read); 1: chapter gone / no corpus; 2: bad anchor; else failed. The capped text stays.
    func take(_ r: (status: Int32, out: Data)) {
        switch r.status {
        case 0:
            full = Self.parse(r.out, cutFields: XrayPanels.probed.map { DchCommand.isAtLeast($0.version, Self.cutFieldsDch) } ?? false)
            note = full == nil ? Self.nothing : nil
        case 1: note = Self.gone
        case 2: note = Self.badAnchor
        default: note = Self.failed
        }
    }

    /// Outside data: schema 1 with an entries array whose user or last assistant entry has a string text; anything
    /// else is nil (nothing to read). Each text is cut at entryCap scalars before it is cleaned (lines kept, every
    /// unseen scalar dropped, marks capped, as OutsideText.shown); a text at the cap counts as dch's cut.
    /// #1487: `cutFields` (dch >= cutFieldsDch): an entry is cut when it has a `cut` count (1...10_000_000), by that count
    /// and its marker line, never by its length; else the length rule above.
    static func parse(_ data: Data, cutFields: Bool = false) -> Full? {
        guard data.count <= maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["schema"] as? Int == 1, let list = o["entries"] as? [Any] else { return nil }
        let entries = list.compactMap { $0 as? [String: Any] }
        func clean(_ s: String, _ cap: Int) -> String {
            String(s.unicodeScalars.prefix(cap)).components(separatedBy: "\n").map { OutsideText.shown($0, max: Int.max) }.joined(separator: "\n")
        }
        func text(_ role: String, last: Bool) -> (head: String, old: Bool, tail: String?, chars: Int?)? {
            let e = last ? entries.last(where: { $0["role"] as? String == role }) : entries.first(where: { $0["role"] as? String == role })
            guard let raw = e?["text"] as? String else { return nil }
            if cutFields {
                let n = XrayChapters.count(e?["cut"])
                let s = n.flatMap { XrayChapters.split(raw, line: XrayChapters.cutLine($0)) }
                let head = clean(s?.head ?? raw, s == nil ? uncutCap : entryCap)
                let tail = s.map { clean($0.tail, tailCap) }
                return head.isEmpty ? nil : (head, false, tail.flatMap { $0.isEmpty ? nil : $0 }, n)
            }
            let c = clean(raw, entryCap)
            return c.isEmpty ? nil : (c, raw.unicodeScalars.count >= entryCap, nil, nil)
        }
        let user = text("user", last: false), answer = text("assistant", last: true)
        guard user != nil || answer != nil else { return nil }
        return Full(prompt: user?.head, promptCut: user?.old ?? false, promptTail: user?.tail, promptCutChars: user?.chars,
                    response: answer?.head, responseCut: answer?.old ?? false, responseTail: answer?.tail, responseCutChars: answer?.chars)
    }
}
