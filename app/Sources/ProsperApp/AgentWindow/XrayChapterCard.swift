import SwiftUI

// #1472: a Prompts or Responses row's card for a pane with no transcript to jump in (Terminal mode, a remote row): the
// prompt and its response from dch's chapters, shaped as the memory card (plain text that scrolls, the same presenter,
// so Esc and a click outside close it the same way). With gate B on, the refs in the response link to the ref card.

struct XrayChapterCard: View {
    let chapter: TranscriptOutline.Chapter
    /// #1472 b: the card's `--chapter` read (XrayPanelModel.openChapterCard); none: the capped text alone.
    @ObservedObject var read = XrayChapterRead()
    /// The panel's refs (gate B underlines them) and the link handler (XrayPanelModel.openLink).
    var refs: [XrayRefs.Entry] = []
    var link: (URL) -> XrayRefLink.Outcome = { _ in .discarded }

    static let size = XrayMemoryCard.size
    static let noResponse = "No response yet."

    /// "Prompt 3", after dch's mark when it has one (another session's message, a hand-back, an automatic prompt).
    static func heading(_ c: TranscriptOutline.Chapter) -> String {
        let row = XrayPromptRow(c)
        return [row.mark, "Prompt \(row.ordinal)"].compactMap { $0 }.joined(separator: " ")
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

    /// #1472 b: the whole prompt (the read's user text, else the title), then "cut at 6000 characters" when dch cut it.
    static func prompt(_ c: TranscriptOutline.Chapter, _ full: XrayChapterRead.Full?) -> String {
        full?.prompt ?? prompt(c)
    }

    /// #1472 b: the whole final response (the read's last assistant text, else the capped one); nil: none yet.
    static func response(_ c: TranscriptOutline.Chapter, _ full: XrayChapterRead.Full?) -> String? {
        full?.response ?? response(c)
    }

    /// Everything the card says, in order (VoiceOver and the rows); #1472 b: with the read's text and note when given.
    static func text(_ c: TranscriptOutline.Chapter, full: XrayChapterRead.Full? = nil, note: String? = nil) -> String {
        [heading(c), prompt(c, full), full?.promptCut == true ? XrayChapterRead.cutNote : nil, tools(c).map { "Tools: " + $0 },
         "Response", response(c, full) ?? noResponse, full?.responseCut == true ? XrayChapterRead.cutNote : nil, note]
            .compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        let full = read.full
        let answer = Self.response(chapter, full)
        VStack(alignment: .leading, spacing: sz(8)) {
            Text(verbatim: Self.heading(chapter)).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: sz(8)) {
                    Text(verbatim: Self.prompt(chapter, full)).font(Neon.font(12, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .accessibilityLabel("Prompt: \(Self.prompt(chapter, full))")
                    if full?.promptCut == true { faint(XrayChapterRead.cutNote) }
                    if let t = Self.tools(chapter) {
                        Text(verbatim: "Tools: " + t).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                    }
                    Text(verbatim: "Response").font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                    Group {
                        if let answer, let a = XrayRefSpans.attributed(answer, markdown: false, refs: refs, color: Neon.blue) {
                            Text(a)
                        } else {
                            Text(verbatim: answer ?? Self.noResponse)
                        }
                    }
                    .font(Neon.font(11)).foregroundStyle(answer == nil ? Neon.textSecondary : Neon.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    .accessibilityLabel("Response: \(answer ?? Self.noResponse)")
                    if full?.responseCut == true { faint(XrayChapterRead.cutNote) }
                    if let n = read.note { faint(n) }
                }
            }
        }
        .padding(sz(12))
        .environment(\.openURL, OpenURLAction { url in
            let outcome = MainActor.assumeIsolated { link(url) }   // SwiftUI calls the action on main (as XrayRefScope)
            return switch outcome { case .handled: .handled; case .system: .systemAction; case .discarded: .discarded }
        })
    }

    private func faint(_ s: String) -> some View {
        Text(verbatim: s).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
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
        var response: String?
        var responseCut = false
    }

    @Published var full: Full?
    /// Why the card keeps its capped text: an exit's note, or nothing to read.
    @Published var note: String?
    var reading: Task<Void, Never>?

    /// dch cuts each entry at 6000 Unicode scalars (dch.1 ~2020) and the object at 1 MiB (plus room here).
    static let entryCap = 6000
    static let maxBytes = 1024 * 1024 + 64 * 1024
    static let cutNote = "cut at 6000 characters"
    static let gone = "This chapter is gone or has no X-ray history"
    static let badAnchor = "dch did not take this chapter's anchor"
    static let nothing = "Nothing to read for this chapter"
    static let failed = "The chapter read failed"

    func cancel() {
        reading?.cancel()
        reading = nil
    }

    /// Exit 0: the text (or nothing to read); 1: chapter gone / no corpus; 2: bad anchor; else failed. The capped text stays.
    func take(_ r: (status: Int32, out: Data)) {
        switch r.status {
        case 0:
            full = Self.parse(r.out)
            note = full == nil ? Self.nothing : nil
        case 1: note = Self.gone
        case 2: note = Self.badAnchor
        default: note = Self.failed
        }
    }

    /// Outside data: schema 1 with an entries array whose user or last assistant entry has a string text; anything
    /// else is nil (nothing to read). Each text is cut at entryCap scalars before it is cleaned (lines kept, every
    /// unseen scalar dropped, marks capped, as OutsideText.shown); a text at the cap counts as dch's cut.
    static func parse(_ data: Data) -> Full? {
        guard data.count <= maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["schema"] as? Int == 1, let list = o["entries"] as? [Any] else { return nil }
        let entries = list.compactMap { $0 as? [String: Any] }
        func text(_ role: String, last: Bool) -> (String, Bool)? {
            let e = last ? entries.last(where: { $0["role"] as? String == role }) : entries.first(where: { $0["role"] as? String == role })
            guard let raw = e?["text"] as? String else { return nil }
            let scalars = raw.unicodeScalars
            let clean = String(scalars.prefix(entryCap)).components(separatedBy: "\n")
                .map { OutsideText.shown($0, max: Int.max) }.joined(separator: "\n")
            return clean.isEmpty ? nil : (clean, scalars.count >= entryCap)
        }
        let user = text("user", last: false), answer = text("assistant", last: true)
        guard user != nil || answer != nil else { return nil }
        return Full(prompt: user?.0, promptCut: user?.1 ?? false, response: answer?.0, responseCut: answer?.1 ?? false)
    }
}
