import SwiftUI

// #786 Agent window, spike A: the read-only conversation view. Settings-console
// look (Neon palette, `Neon.font` / `sz` so it follows ThemeRuntime.scale). Every
// block draws a header line, so a block can simplify but never render blank.

struct AgentTranscriptView: View {
    @ObservedObject var model: AgentTranscriptModel
    /// False for offscreen evidence: a plain stack instead of a ScrollView.
    var scrolls = true
    @State private var showAnyway = false

    var body: some View {
        VStack(spacing: 0) {
            if let b = model.banner { TranscriptBanner(text: b) }
            if case .terminalFirst(let reason) = model.mode, !showAnyway {
                TerminalFirstView(reason: reason) { showAnyway = true }
            } else {
                if case .waiting(let hint) = model.mode { TranscriptHint(text: hint) }
                if scrolls {
                    ScrollView { LazyVStack(alignment: .leading, spacing: sz(10)) { rows } .padding(sz(14)) }
                        .defaultScrollAnchor(.bottom)
                } else {
                    VStack(alignment: .leading, spacing: sz(10)) { rows }.padding(sz(14))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: scrolls ? .infinity : nil, alignment: .top)
        .background(Neon.bgBottom)
        .onAppear { if scrolls { model.start() } }
        .onDisappear { if scrolls { model.stop() } }
    }

    @ViewBuilder private var rows: some View {
        if model.olderAvailable {
            Button { model.loadEarlier() } label: {
                Label("Load earlier", systemImage: "arrow.up").font(Neon.font(11, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Neon.blue)
        }
        ForEach(model.blocks) { b in
            TranscriptBlockView(block: b, expand: { model.fullText($0) })
        }
        if model.hiddenCount > 0 {
            Text("\(model.hiddenCount) internal entries hidden")
                .font(Neon.font(10)).foregroundStyle(Neon.textSecondary.opacity(0.7))
        }
    }
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
    var showConversation: () -> Void = {}
    var body: some View {
        VStack(spacing: sz(10)) {
            Image(systemName: "terminal").font(Neon.font(26)).foregroundStyle(Neon.terminal)
            Text("Opens in the terminal").font(Neon.font(14, weight: .semibold)).foregroundStyle(Neon.textPrimary)
            Text(reason).font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Show the conversation anyway", action: showConversation)
                .buttonStyle(.plain).font(Neon.font(11, weight: .medium)).foregroundStyle(Neon.blue)
        }
        .padding(sz(24))
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Blocks

struct TranscriptBlockView: View {
    let block: TranscriptBlock
    /// Initial fold state; the offscreen renders draw both.
    var expanded = false
    var expand: (Clip) -> String? = { _ in nil }

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
                    Text("\(hidden) more lines").font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
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
                    Text("\(block.droppedChildren) earlier steps not shown").font(Neon.font(10))
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

private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

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
    var expand: (Clip) -> String? = { _ in nil }
    @State private var full: String?

    var body: some View {
        VStack(alignment: .leading, spacing: sz(3)) {
            text(full ?? clip.text)
                .font(mono ? Neon.font(10.5, design: .monospaced) : Neon.font(12.5))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if clip.capped && full == nil {
                Button("Show all (\(clip.total) chars)") { full = expand(clip) ?? clip.text }
                    .buttonStyle(.plain).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.blue)
            }
        }
    }

    private func text(_ s: String) -> Text {
        guard markdown, let a = try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return Text(s) }
        return Text(a)
    }
}
