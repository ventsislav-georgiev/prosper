import AppKit
import Combine
import SwiftUI

// #1319 (#832 X1 step B, spec v2.1 8.3): the Command-L Jump to Chapter list. A filter field over the pane's chapters
// (step A's TranscriptOutline), one fixed 360x308*s surface, keys handled by the field, a Return jumps through the
// pane's TranscriptJumper (never the window model's focus or selection) and closes.

@MainActor
final class TranscriptChapterListModel: ObservableObject {
    enum Row: Hashable { case load, chapter(Int) }

    static let rowsShown = 9

    /// What the field holds: every word must be in a title (case-insensitive).
    @Published var query = "" { didSet { refiltered() } }
    @Published private(set) var selected: Row?
    /// The first row drawn (the list scrolls by rows, keeping the selection in view).
    @Published private(set) var top = 0

    let jumper: TranscriptJumper
    // Seams (the pane's transcript by default): the chapters, whether an earlier page can be loaded, and its load.
    var chapters: () -> [TranscriptOutline.Chapter]
    var older: () -> Bool
    var loadEarlier: () -> Void
    /// Closes the surface (the window's presenter).
    var close: () -> Void = {}
    private var watch: AnyCancellable?

    init(chapters: @escaping () -> [TranscriptOutline.Chapter], older: @escaping () -> Bool,
         loadEarlier: @escaping () -> Void, jumper: TranscriptJumper) {
        self.chapters = chapters
        self.older = older
        self.loadEarlier = loadEarlier
        self.jumper = jumper
        // Spec 8.3: on the chapter of this pane's last jump, else the last chapter.
        let all = chapters()
        let last = jumper.request?.block.flatMap { b in all.last { $0.id <= b } } ?? all.last
        selected = last.map { .chapter($0.id) } ?? (older() ? .load : nil)
        top = firstShown
    }

    convenience init(transcript t: AgentTranscriptModel, jumper: TranscriptJumper) {
        self.init(chapters: { [weak t] in t?.chapters ?? [] },
                  older: { [weak t] in t.map { $0.olderAvailable && !$0.atHistoryCap } ?? false },
                  loadEarlier: { [weak t] in t?.loadEarlier() }, jumper: jumper)
        // A poll or a page redraws the list (the transcript publishes on main).
        watch = t.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// The chapters whose title holds every typed word, in conversation order.
    var matches: [TranscriptOutline.Chapter] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return chapters() }
        return chapters().filter { c in words.allSatisfy { Self.title(c).range(of: $0, options: .caseInsensitive) != nil } }
    }

    var rows: [Row] { (older() ? [.load] : []) + matches.map { .chapter($0.id) } }

    /// The selected row's place. A chapter id a page merged away (step A: the old partial first turn) lands on the
    /// chapter that now holds it.
    var index: Int? {
        let r = rows
        switch selected {
        case .load?: return r.firstIndex(of: .load)
        case .chapter(let id)?:
            return r.firstIndex(of: .chapter(id)) ?? r.lastIndex { if case .chapter(let c) = $0 { c <= id } else { false } }
        case nil: return nil
        }
    }

    /// The first row drawn so the selection is in view, moving `top` as little as possible.
    var firstShown: Int {
        let n = rows.count, t = min(top, max(0, n - Self.rowsShown))
        guard let i = index else { return max(0, t) }
        return i < t ? i : (i >= t + Self.rowsShown ? i - Self.rowsShown + 1 : max(0, t))
    }

    /// R904-f1: a title is outside text, shown through the mark cap.
    static func title(_ c: TranscriptOutline.Chapter) -> String { OutsideText.shown(c.title, max: TranscriptOutline.titleCap) }

    func select(_ i: Int) {
        let r = rows
        guard !r.isEmpty else { return }
        selected = r[max(0, min(i, r.count - 1))]
        top = firstShown
    }

    /// The field's commands: up/down (no wrap), Page Up/Down by 9, Home/End, Return, Esc. True: handled.
    func command(_ s: Selector) -> Bool {
        let i = index ?? -1
        switch s {
        case #selector(NSResponder.moveUp(_:)): select(max(0, i - 1))
        case #selector(NSResponder.moveDown(_:)): select(i + 1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): select(max(0, i - Self.rowsShown))
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): select(i + Self.rowsShown)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)): select(0)
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)): select(rows.count - 1)
        case #selector(NSResponder.insertNewline(_:)): activate()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    /// Return: the load row loads the page before and keeps the list open on the chapter under it; a chapter jumps
    /// (this pane's jumper only) and closes.
    func activate() {
        guard let i = index else { return }
        let r = rows
        switch r[i] {
        case .load:
            if i + 1 < r.count { selected = r[i + 1] }
            loadEarlier()
            top = firstShown
        case .chapter(let id):
            guard let c = chapters().first(where: { $0.id == id }) else { return }
            jumper.jump(to: c)
            close()
        }
    }

    private func refiltered() {
        if let s = selected, rows.contains(s) { top = firstShown; return }
        selected = rows.first { $0 != .load } ?? rows.first
        top = 0
        top = firstShown
    }
}

/// The surface: a 32*s field, 9 rows of 28*s (blank when fewer match: it never resizes) and a 24*s footer.
struct TranscriptChapterList: View {
    @ObservedObject var list: TranscriptChapterListModel

    static var size: CGSize { CGSize(width: sz(360), height: sz(308)) }

    var body: some View {
        let rows = list.rows, chapters = Dictionary(list.chapters().map { ($0.id, $0) }) { a, _ in a }
        let top = list.firstShown, at = list.index
        VStack(spacing: 0) {
            ChapterListField(list: list)
                .padding(.horizontal, sz(8))
                .frame(width: sz(360), height: sz(32))
                .overlay(alignment: .bottom) { Rectangle().fill(Neon.stroke).frame(height: 1) }
            ForEach(0..<TranscriptChapterListModel.rowsShown, id: \.self) { slot in
                let i = top + slot
                Group {
                    if i < rows.count {
                        switch rows[i] {
                        case .load:
                            ChapterLoadRow()
                        case .chapter(let id):
                            if let c = chapters[id] { ChapterRow(chapter: c) } else { Color.clear }
                        }
                    } else {
                        Color.clear
                    }
                }
                .frame(width: sz(360), height: sz(28))
                .background(i == at ? Neon.blue.opacity(0.22) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { if i < rows.count { list.select(i); list.activate() } }
            }
            Text(verbatim: "\u{2191}\u{2193} to move, Return to jump, Esc to close")
                .font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
                .lineLimit(1)
                .frame(width: sz(360), height: sz(24))
        }
        .frame(width: sz(360))
    }
}

/// "Earlier chapters not loaded - Load earlier".
struct ChapterLoadRow: View {
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "arrow.up").frame(width: sz(28))
            Text(verbatim: "Earlier chapters not loaded \u{00B7} Load earlier").lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(Neon.font(11)).foregroundStyle(Neon.blue)
    }
}

/// One chapter: the number in a fixed 28*s slot, the title (tail truncated, one line, clipped to its own bounds so piled
/// marks never ink the next row: R904-f1, the QA 1047 class) and a fixed error-mark slot. A partial turn is dimmed.
struct ChapterRow: View {
    let chapter: TranscriptOutline.Chapter

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "\(chapter.ordinal)").foregroundStyle(Neon.textSecondary)
                .lineLimit(1).frame(width: sz(28))
            ChapterTitle(text: TranscriptChapterListModel.title(chapter))
            Spacer(minLength: sz(4))
            Group {
                if chapter.hasError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Neon.magenta)
                        .accessibilityLabel("A step failed")
                }
            }
            .frame(width: sz(20))
        }
        .font(Neon.font(11))
        .opacity(chapter.kind == .partial ? 0.5 : 1)
    }
}

/// R904-f1: the title line, one line, clipped to its own bounds.
struct ChapterTitle: View {
    let text: String
    var body: some View {
        Text(verbatim: text).foregroundStyle(Neon.textPrimary)
            .lineLimit(1).truncationMode(.tail)
            .clipped()
            .layoutPriority(-1)
    }
}

/// The filter field: first responder once in a window (the list's keys go through its commands), Command-L closes.
struct ChapterListField: NSViewRepresentable {
    let list: TranscriptChapterListModel

    func makeNSView(context: Context) -> Field {
        let f = Field()
        f.list = list
        f.placeholderString = "Jump to chapter"
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = NSFont.systemFont(ofSize: sz(13))
        f.delegate = f
        return f
    }

    func updateNSView(_ f: Field, context: Context) { f.list = list }

    final class Field: NSTextField, NSTextFieldDelegate {
        weak var list: TranscriptChapterListModel?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)   // in its own window only: never ordered front or made key
        }

        func controlTextDidChange(_ n: Notification) { list?.query = stringValue }

        func control(_ c: NSControl, textView: NSTextView, doCommandBy s: Selector) -> Bool { list?.command(s) ?? false }

        /// Command-L again closes (spec 8.3), by key code as the window matches it.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if AgentsNSWindow.isChapterKey(event) { list?.close(); return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}
