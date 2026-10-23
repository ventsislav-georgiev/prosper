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

struct AgentPromptOption: Equatable {
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

struct AgentPrompt: Equatable {
    /// The line right above option 1: "Do you want to proceed?", the question text.
    let question: String
    /// Every non-blank line above the question, inside the dialog, untruncated:
    /// the click guard compares all of it (a long command can differ in its head).
    let context: [String]
    let options: [AgentPromptOption]

    /// Any hidden or reordering character anywhere the card shows (Trojan
    /// Source): only a "No…" option answers such a dialog.
    var hasHiddenCharacters: Bool {
        ([question] + context + options.flatMap { [$0.label] + $0.detail })
            .contains { $0.unicodeScalars.contains(where: Self.isHidden) }
    }

    /// What the card renders literally: every printable character, wide glyphs
    /// (CJK, emoji), combining marks, variation selectors. Escaped as ⟨U+XXXX⟩:
    /// C0 controls (tab included), DEL, C1 controls, the bidi embeddings and
    /// overrides U+202A-202E, the isolates U+2066-2069, the marks U+200E/200F
    /// and U+061C, zero-width U+200B-200D (ZWJ too, so a ZWJ emoji shows split),
    /// word joiner U+2060, invisible operators U+2061-2064, soft hyphen U+00AD
    /// and U+FEFF. Display only: the compared identity stays the raw text.
    static func isHidden(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x00...0x1F, 0x7F...0x9F, 0xAD, 0x61C, 0x200B...0x200F, 0x202A...0x202E,
             0x2060...0x2064, 0x2066...0x2069, 0xFEFF: true
        default: false
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
    static func parse(_ screen: String) -> AgentPrompt? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(unframe)
        guard let last = lines.lastIndex(where: { option($0) != nil }) else { return nil }
        var found: [(digit: Int, label: String, caret: Bool, detail: [String])] = []
        // Lines below the option the walk reaches next: the last option's tail first.
        var below = Array(lines[(last + 1)...].prefix(while: { !isBlankOrRule($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) })
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
        while i >= 0, isBlankOrRule(lines[i]) { i -= 1 }
        guard i >= 0 else { return nil }
        let question = lines[i].trimmingCharacters(in: .whitespaces)
        var context: [String] = []
        var j = i - 1
        // Up to the dialog's top rule; a rule right under the question (Edit's
        // dashed diff frame) is skipped.
        while j >= 0, !(isRule(lines[j]) && !context.isEmpty) {
            if !isBlankOrRule(lines[j]) { context.insert(lines[j], at: 0) }
            j -= 1
        }
        return AgentPrompt(
            question: question, context: dedent(context),
            options: found.reversed().map { o in
                let (label, hint) = splitHint(o.label)
                return AgentPromptOption(digit: o.digit, label: label, hint: hint, detail: o.detail)
            })
    }

    /// The last `maxContext` non-blank, non-rule lines.
    static func tail(_ screen: String) -> [String] {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(unframe)
        return dedent(Array(lines.filter { !isBlankOrRule($0) }.suffix(maxContext)))
    }

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

    /// One screen line without an old-style box frame ("│ … │") or trailing blanks;
    /// leading indent stays for the context block.
    static func unframe(_ raw: Substring) -> String {
        var s = String(raw)
        while let c = s.last, c.isWhitespace || c == "│" { s.removeLast() }
        if let bar = s.firstIndex(of: "│"), s[..<bar].allSatisfy(\.isWhitespace) {
            s = String(s[s.index(after: bar)...])
            if s.first == " " { s.removeFirst() }
        }
        return s
    }

    static func isRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { "─━═╌┄╭╮╰╯┌┐└┘".contains($0) }
    }

    static func isBlankOrRule(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty || isRule(line)
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

    /// Drop the indent every line shares, keep the rest (code, diff gutters).
    static func dedent(_ lines: [String]) -> [String] {
        let n = lines.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
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
