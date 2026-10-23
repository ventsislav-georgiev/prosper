// Agent Island (#475): answer a blocked dch session from the island. The
// screen (`dch --read <name>`, plain) is parsed for a numbered selection
// prompt — Claude Code's permission dialog or an AskUserQuestion form — and
// each option becomes a button. A click re-reads the screen and types the
// option's digit (`dch --send <name> <digit>`, raw bytes, no Enter) only if the
// same prompt is still up and dch still says blocked. Foundation only, with
// every dch call injected, so tests (and a probe) drive it without the app.

import Foundation

struct AgentPromptOption: Equatable {
    /// 1-9: the one key a click sends.
    let digit: Int
    let label: String
    /// A key hint the option carries, "esc" from "(esc)". Shown, never sent.
    let hint: String?

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
    /// Up to `maxContext` non-blank lines above the question, inside the dialog.
    let context: [String]
    let options: [AgentPromptOption]

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
    static func parse(_ screen: String) -> AgentPrompt? {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(unframe)
        guard let last = lines.lastIndex(where: { option($0) != nil }) else { return nil }
        var found: [(digit: Int, label: String, caret: Bool)] = []
        var i = last, gap = 0
        while i >= 0, found.last?.digit != 1 {
            if let o = option(lines[i]) {
                guard o.digit == (found.last?.digit ?? o.digit + 1) - 1 else { return nil }
                found.append(o)
                gap = 0
            } else {
                gap += 1
                if gap > maxGap { return nil }
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
            question: question, context: dedent(Array(context.suffix(maxContext))),
            options: found.reversed().map { o in
                let (label, hint) = splitHint(o.label)
                return AgentPromptOption(digit: o.digit, label: label, hint: hint)
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

    /// Re-read; type `digit` only if the same question and option list are on
    /// screen and dch says blocked. One keystroke, never Enter, else nothing.
    static func answer(_ key: AgentSessionKey, digit: Int, expected: AgentPrompt,
                       io: AgentPromptIO) -> AgentPromptAnswer {
        guard (1...9).contains(digit), expected.options.contains(where: { $0.digit == digit }),
              let now = parse(io.read(key)), now.question == expected.question,
              now.options == expected.options,
              io.status(key).trimmingCharacters(in: .whitespacesAndNewlines) == "blocked"
        else { return .changed }
        io.send(key, String(digit))
        return .sent
    }
}
