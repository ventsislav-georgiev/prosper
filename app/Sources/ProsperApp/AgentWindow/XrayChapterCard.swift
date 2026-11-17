import SwiftUI

// #1472: a Prompts or Responses row's card for a pane with no transcript to jump in (Terminal mode, a remote row): the
// prompt and its response from dch's chapters, shaped as the memory card (plain text that scrolls, the same presenter,
// so Esc and a click outside close it the same way). With gate B on, the refs in the response link to the ref card.

struct XrayChapterCard: View {
    let chapter: TranscriptOutline.Chapter
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

    /// Everything the card says, in order (VoiceOver and the rows).
    static func text(_ c: TranscriptOutline.Chapter) -> String {
        [heading(c), prompt(c), tools(c).map { "Tools: " + $0 }, "Response", response(c) ?? noResponse]
            .compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        let answer = Self.response(chapter)
        VStack(alignment: .leading, spacing: sz(8)) {
            Text(verbatim: Self.heading(chapter)).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
            ScrollView {
                VStack(alignment: .leading, spacing: sz(8)) {
                    Text(verbatim: Self.prompt(chapter)).font(Neon.font(12, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .accessibilityLabel("Prompt: \(Self.prompt(chapter))")
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
                }
            }
        }
        .padding(sz(12))
        .environment(\.openURL, OpenURLAction { url in
            let outcome = MainActor.assumeIsolated { link(url) }   // SwiftUI calls the action on main (as XrayRefScope)
            return switch outcome { case .handled: .handled; case .system: .systemAction; case .discarded: .discarded }
        })
    }
}
