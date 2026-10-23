// Agent Island (#475): answer a blocked dch session from the island. The
// screen (`dch --read <name>`, plain) is parsed for a numbered selection
// prompt — Claude Code's permission dialog or an AskUserQuestion form — and
// each option becomes a button. A click re-reads the screen and types the
// option's digit (`dch --send <name> <digit>`, raw bytes, no Enter) only if the
// whole dialog (question, full context block, options) is unchanged and dch
// still says blocked. Foundation only (the measured enable rule, `isEnabled`,
// lives in AgentIslandView.swift), with
// every dch call injected, so tests (and a probe) drive it without the app.

import Foundation

struct AgentPromptOption: Hashable {
    /// 1-9: the one key a click sends.
    let digit: Int
    let label: String
    /// A key hint the option carries, "esc" from "(esc)". Shown, never sent.
    let hint: String?
    /// The option's other lines, trimmed: a wrapped label's continuation or an
    /// AskUserQuestion description (not told apart). Part of the compared
    /// identity, shown dim under the label.
    var detail: [String] = []

    enum Style { case accent, deny, plain }

    /// First option = accent, a "No…" option = deny (deny wins).
    func style(first: Bool) -> Style {
        if label == "No" || label.hasPrefix("No,") || label.hasPrefix("No ") { return .deny }
        return first ? .accent : .plain
    }
}

struct AgentPrompt: Hashable {
    /// The line right above option 1: "Do you want to proceed?", the question text.
    let question: String
    /// Every line between the dialog's top rule and the question, untruncated:
    /// title, description, command or diff (dashed frames left out), a Bash
    /// dialog's reason line. The click guard compares all of it (a long command
    /// can differ in its head). Blank
    /// lines are dropped except inside a command (between two lines at column 2
    /// or more), where they are kept as "" (a heredoc body can depend on one).
    let context: [String]
    let options: [AgentPromptOption]
    /// False when the context walk ran off the screen top: every Claude Code
    /// dialog and question form has a top rule, so not seeing it means the head
    /// may be above the screen. Only a "No…" option answers such a dialog.
    var topFound = true

    /// Any hidden or reordering character anywhere the card shows (Trojan
    /// Source): only a "No…" option answers such a dialog.
    var hasHiddenCharacters: Bool {
        ([question] + context + options.flatMap { [$0.label] + $0.detail })
            .contains { $0.unicodeScalars.contains(where: Self.isHidden) }
    }

    /// What the card renders literally: every printable character, wide glyphs
    /// (CJK, emoji), combining marks, the variation selectors U+FE00-FE0F (an
    /// emoji's U+FE0F stays approvable). Escaped as ⟨U+XXXX⟩, by Unicode property
    /// rather than a hand list: every Default_Ignorable_Code_Point (zero-width
    /// and joiners, ZWJ too so a ZWJ emoji shows split, bidi marks, Hangul
    /// fillers, tag characters, U+034F, unassigned ones like U+2065) and every
    /// control, format, line or paragraph separator (C0/C1 with tab and CR,
    /// U+2028/2029, which break a one-line row and cut what follows; U+FFF9-FFFB,
    /// U+1D173-1D17A). Display only: the compared identity stays the raw text.
    static func isHidden(_ u: Unicode.Scalar) -> Bool {
        let p = u.properties
        if p.isDefaultIgnorableCodePoint, !(0xFE00...0xFE0F).contains(u.value) { return true }
        switch p.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// `s` with every hidden character escaped as ⟨U+202E⟩.
    static func visible(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isHidden) else { return s }
        var out = ""
        for u in s.unicodeScalars {
            if isHidden(u) { out += "⟨U+\(String(format: "%04X", u.value))⟩" } else { out.unicodeScalars.append(u) }
        }
        return out
    }

    /// Context rows the card shows (measured rows, after wrapping); also the
    /// screen lines a context-only card takes (`tail`).
    static let maxContext = 8
    /// Non-option lines allowed between two options (descriptions, a rule).
    static let maxGap = 4
}

/// What a blocked row shows under it.
enum AgentCard: Equatable {
    case prompt(AgentPrompt)
    /// Blocked with no numbered options (codex, cursor, opencode, multi-select):
    /// the screen's last lines and Jump only — no guessed keys.
    case context([String])
    /// A click found a different prompt (or none) and sent nothing.
    case changed
}

/// dch for one session. Live: DCH_SOCKET_DIR = key.dir (AgentIslandController).
struct AgentPromptIO: Sendable {
    var read: @Sendable (AgentSessionKey) -> String
    var status: @Sendable (AgentSessionKey) -> String
    var send: @Sendable (AgentSessionKey, String) -> Void
}

enum AgentPromptAnswer: Equatable { case sent, changed }

extension AgentPrompt {
    // MARK: - Parse

    static func card(screen: String) -> AgentCard {
        parse(screen).map(AgentCard.prompt) ?? .context(tail(screen))
    }

    /// A numbered prompt, or nil. Rules: the bottom-most option line, walked up
    /// through 1 with consecutive digits (at most `maxGap` other lines between
    /// two options); at least two options; exactly one carries Claude's "❯"
    /// caret (ordinary numbered output never does); no checkboxes (a digit there
    /// toggles, it does not answer); a non-blank question line above option 1.
    /// Every non-blank, non-rule line below an option, up to the next option (or,
    /// after the last one, the first blank or rule line), is that option's detail.
    /// The dialog must be the last thing on the screen (a static copy printed
    /// above a shell prompt is not a live dialog): below the last option and its
    /// detail only blank lines, rules and, last, one footer line ("Esc to
    /// cancel …"); a last option with detail lines needs that rule or footer
    /// under it (else the detail could be a shell prompt).
    static func parse(_ screen: String) -> AgentPrompt? {
        let raw = screen.split(separator: "\n", omittingEmptySubsequences: false), lines = unframe(raw)
        guard let last = lines.lastIndex(where: { option($0) != nil }) else { return nil }
        var found: [(digit: Int, label: String, caret: Bool, detail: [String])] = []
        // Lines below the option the walk reaches next: the last option's tail first.
        var below = Array(lines[(last + 1)...].prefix(while: { !isBlankOrRule($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) })
        let after = lines[(last + 1 + below.count)...].filter { !isBlank($0) }
        guard after.dropLast().allSatisfy(isRule),
              after.last.map({ isRule($0) || isFooter($0) }) ?? below.isEmpty else { return nil }
        var i = last, gap = 0
        while i >= 0, found.last?.digit != 1 {
            if let o = option(lines[i]) {
                guard o.digit == (found.last?.digit ?? o.digit + 1) - 1 else { return nil }
                found.append((o.digit, o.label, o.caret, below))
                below = []
                gap = 0
            } else {
                gap += 1
                if gap > maxGap { return nil }
                if !isBlankOrRule(lines[i]) { below.insert(lines[i].trimmingCharacters(in: .whitespaces), at: 0) }
            }
            i -= 1
        }
        guard found.last?.digit == 1, found.count >= 2, found.filter(\.caret).count == 1,
              !found.contains(where: { isCheckbox($0.label) }) else { return nil }
        // i is now the line above option 1.
        // A frame: Claude Code draws its frames (top rule, dashed command or diff
        // frame, 1.x box) at screen column 0 or 1, everything they frame from
        // column 2, and full screen width. So a rule further in (a heredoc,
        // printed output) or a short one (an autowrap tail, a CR overprint) is
        // the dialog's own text. Columns count on the raw line, box bars
        // included. Width: the rule's raw extent (where it ends) against the
        // widest rule anywhere on the screen, any column (the top frame is the
        // screen width; any other rule can only widen it, which fails safe);
        // `frameSlack` cells short still count. The whole screen, not only above
        // option 1 (QA #310 F1): an Ask form whose top rule scrolled off still
        // has its full-width rule above "Chat about this", so a short rule in
        // its question is never the widest. Not the widest line: screen lines in
        // the fixtures run past their frames.
        let extent = { (r: Substring) in r.reversed().drop(while: \.isWhitespace).count }
        let width = raw.indices.filter { isRule(lines[$0]) }.map { extent(raw[$0]) }.max() ?? 0
        func isFrame(_ k: Int) -> Bool {
            isRule(lines[k]) && raw[k].prefix(while: { $0.isWhitespace || $0 == "│" }).count <= 1
                && extent(raw[k]) + frameSlack >= width
        }
        while i >= 0, isBlank(lines[i]) || isFrame(i) { i -= 1 }
        guard i >= 0 else { return nil }
        let question = lines[i].trimmingCharacters(in: .whitespaces)
        var context: [String] = []
        var j = i - 1
        // Up to the dialog's top: the first solid frame (top rule, 1.x box
        // corner) with a non-blank line under it. Dashed frames ("╌": Claude
        // Code's command, diff and file-content frames) are inner frames, passed
        // and not kept. Claude Code 2.1.309 draws "This command requires
        // approval" under a Bash dialog's lower dashed frame, so stopping at the
        // first frame of any kind kept only that line: no command shown, none
        // compared (QA #310 F0). Everything from the top rule down (title, tip,
        // description, command rows with their gutter, a Write's path and
        // content, the reason line) is the dialog, so all of it is compared.
        while j >= 0 {
            if isFrame(j) {
                if !isDashed(lines[j]), context.contains(where: { !isBlank($0) }) { break }
            } else {
                context.insert(lines[j], at: 0)
            }
            j -= 1
        }
        // Blank lines: kept inside a command (both neighbours at column 2 or
        // more: command, diff and box content), dropped between the dialog's
        // own sections (header, description, question at column 0 or 1).
        let indent = { (s: String) in s.prefix(while: { $0 == " " }).count }
        let kept = context.indices.compactMap { k -> String? in
            guard isBlank(context[k]) else { return context[k] }
            guard let up = context[..<k].last(where: { !isBlank($0) }),
                  let down = context[(k + 1)...].first(where: { !isBlank($0) }),
                  indent(up) >= 2, indent(down) >= 2 else { return nil }
            return ""
        }
        return AgentPrompt(
            question: question, context: dedent(kept),
            options: found.reversed().map { o in
                let (label, hint) = splitHint(o.label)
                return AgentPromptOption(digit: o.digit, label: label, hint: hint, detail: o.detail)
            },
            // Off the screen top: the dialog's own top rule is not on screen.
            topFound: j >= 0)
    }

    /// The last `maxContext` non-blank, non-rule lines.
    static func tail(_ screen: String) -> [String] {
        let lines = unframe(screen.split(separator: "\n", omittingEmptySubsequences: false))
        return dedent(Array(lines.filter { !isBlankOrRule($0) }.suffix(maxContext)))
    }

    /// A frame rule may end this many cells before the widest rule above
    /// option 1. Every fixture and QA probe frame ends at the same column
    /// (top rule 90 at column 0, dashed frames 89 at column 1; 48 in the narrow
    /// fixtures); 2 leaves one cell for a frame drawn one short. A
    /// width-disagreement autowrap tail is at most ~40 cells on a 90-cell screen.
    static let frameSlack = 2

    /// "  ❯ 2. Yes, and …" -> (2, "Yes, and …", caret). Single digit 1-9 only.
    static func option(_ line: String) -> (digit: Int, label: String, caret: Bool)? {
        var s = Substring(line).drop(while: \.isWhitespace)
        var caret = false
        if s.first == "❯" { caret = true; s = s.dropFirst().drop(while: \.isWhitespace) }
        guard let d = s.first, d.isASCII, let digit = d.wholeNumberValue, digit >= 1,
              s.dropFirst().first == "." else { return nil }
        let rest = s.dropFirst(2)
        guard rest.first?.isWhitespace == true else { return nil }
        let label = rest.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : (digit, label, caret)
    }

    /// Screen lines without an old-style box frame ("│ … │") or trailing blanks;
    /// leading indent stays for the context block. A line loses its bars only
    /// when it is a box row: its left bar sits at the column (0 or 1) of a box
    /// corner rule ("╭──╮", "╰──╯") on the screen and it ends in a right bar.
    /// Any other "│" (a command that starts or ends with one) is text.
    static func unframe(_ raw: [Substring]) -> [String] {
        let edges = Set(raw.compactMap { r -> Int? in
            let col = r.prefix(while: \.isWhitespace).count
            guard col <= 1, let c = r.dropFirst(col).first, "╭╰┌└".contains(c), isRule(String(r)) else { return nil }
            return col
        })
        return raw.map { r in
            var s = trimmedEnd(String(r))
            let col = s.prefix(while: { $0 == " " }).count
            if edges.contains(col), s.dropFirst(col).first == "│", s.count > col + 1, s.last == "│" {
                s = trimmedEnd(String(s.dropFirst(col + 1).dropLast()))
                if s.first == " " { s.removeFirst() }
            }
            return s
        }
    }

    /// Trailing blanks off; a hidden one (CR, a line separator, tab) stays, so
    /// the card shows it and goes deny-only.
    private static func trimmedEnd(_ s: String) -> String {
        var s = s
        while let c = s.last, c.isWhitespace, !c.unicodeScalars.contains(where: isHidden) { s.removeLast() }
        return s
    }

    static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { "─━═╌┄╭╮╰╯┌┐└┘".contains($0) }
    }

    /// A dashed rule ("╌╌╌"): an inner frame, never the dialog's top.
    static func isDashed(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { "╌┄".contains($0) }
    }

    static func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

    static func isBlankOrRule(_ line: String) -> Bool { isBlank(line) || isRule(line) }

    /// Claude Code's dialog footer: "Esc to cancel · Tab to amend", "Enter to
    /// select · ↑/↓ to navigate · Esc to cancel". A short line, like dch's rule.
    static func isFooter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count <= 64 && t.lowercased().contains("esc to cancel")
    }

    /// "[ ] Staging", "[✔] Prod", "☐ Local": a multi-select row.
    static func isCheckbox(_ label: String) -> Bool {
        if let f = label.first, "☐☑☒".contains(f) { return true }
        let c = Array(label.prefix(3))
        return c.count == 3 && c[0] == "[" && c[2] == "]"
    }

    /// "No, and tell Claude what to do differently (esc)" -> label + "esc".
    /// Only key-like hints: esc, tab, enter, or modifier+key ("shift+tab").
    static func splitHint(_ label: String) -> (String, String?) {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return (label, nil) }
        let inner = String(label[label.index(after: open)..<label.index(before: label.endIndex)])
        let parts = inner.lowercased().split(separator: "+", omittingEmptySubsequences: false)
        let mods: Set<Substring> = ["ctrl", "shift", "alt", "cmd", "option"]
        let keyish = (parts.count == 1 && ["esc", "tab", "enter"].contains(parts[0]))
            || (parts.count == 2 && mods.contains(parts[0]) && (1...5).contains(parts[1].count)
                && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        guard keyish else { return (label, nil) }
        return (label[..<open].trimmingCharacters(in: .whitespaces), inner)
    }

    /// Drop the indent every non-blank line shares, keep the rest (code, diff gutters).
    static func dedent(_ lines: [String]) -> [String] {
        let n = lines.filter { !isBlank($0) }.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        return lines.map { String($0.dropFirst(n)) }
    }

    // MARK: - Answer

    /// Re-read; type `digit` only if the whole dialog is unchanged — question,
    /// full context block (Claude asks the same question with the same options
    /// for every Bash command) and options with their detail lines; the caret
    /// position does not count —
    /// and dch says blocked. One keystroke, never Enter, else nothing.
    /// `isEnabled` is the card's own rule (AgentIslandView.swift, it measures
    /// with AppKit): a button drawn disabled can never send from here either.
    static func answer(_ key: AgentSessionKey, digit: Int, expected: AgentPrompt,
                       io: AgentPromptIO) -> AgentPromptAnswer {
        guard (1...9).contains(digit),
              expected.options.contains(where: { $0.digit == digit && expected.isEnabled($0) }),
              let now = parse(io.read(key)), now == expected,
              io.status(key).trimmingCharacters(in: .whitespacesAndNewlines) == "blocked"
        else { return .changed }
        io.send(key, String(digit))
        return .sent
    }
}
