import Foundation

// #798 Agent window B: talk to the selected session from the window. A message
// (`dch --say`), an interrupt (Esc) and native answers to its prompt. Every dch
// call goes through the island controller's IO and its human-click path; every
// key is sent only after a fresh read shows the state it was planned against, and
// anything Prosper cannot read or confirm ends in "Open in terminal" with why.

/// The AskUserQuestion call Claude Code is waiting on, from the transcript's tool_use
/// input: what a question form on screen is cross-checked against. Tolerant: a shape
/// it does not know parses to nil (and the new key sequences then stay off).
struct AgentAskInput: Equatable, Sendable {
    static let toolName = "AskUserQuestion"

    struct Option: Equatable, Sendable {
        let label: String
        let description: String
    }

    struct Question: Equatable, Sendable {
        let question: String
        let header: String
        let options: [Option]
        let multiSelect: Bool
    }

    let id: String
    let questions: [Question]

    static func parse(_ input: [String: Any], id: String) -> AgentAskInput? {
        guard let qs = input["questions"] as? [[String: Any]], !qs.isEmpty else { return nil }
        var out: [Question] = []
        for q in qs {
            guard let text = q["question"] as? String, let os = q["options"] as? [[String: Any]] else { return nil }
            let options = os.compactMap { o in
                (o["label"] as? String).map { Option(label: $0, description: o["description"] as? String ?? "") }
            }
            guard !options.isEmpty, options.count == os.count else { return nil }
            out.append(Question(question: text, header: q["header"] as? String ?? "", options: options,
                                multiSelect: q["multiSelect"] as? Bool ?? false))
        }
        return AgentAskInput(id: id, questions: out)
    }

    /// The rows Claude Code adds to a question form after the asked options.
    static let extraRows: Set<String> = ["Typesomething.", "Typesomething", "Chataboutthis"]

    /// The screen's form is one of these questions: the same question text, its options
    /// first, in order (label and description, or the label alone when no description is
    /// drawn), then only Claude Code's own rows, and checkboxes exactly when multiSelect.
    /// Compared with all whitespace removed (a narrow pty wraps anywhere).
    func matches(_ s: AgentPromptScreen) -> Bool {
        let p = s.prompt, flat = { (t: String) in t.filter { !$0.isWhitespace } }
        guard let q = questions.first(where: { flat($0.question) == flat(p.question) }),
              q.multiSelect == (s.checked != nil), p.options.count >= q.options.count else { return false }
        for (o, t) in zip(p.options, q.options) {
            let shown = flat(([o.label] + o.detail).joined())
            guard shown == flat(t.label + t.description) || (o.detail.isEmpty && flat(o.label) == flat(t.label)) else {
                return false
            }
        }
        return p.options.dropFirst(q.options.count).allSatisfy { Self.extraRows.contains(flat($0.label)) && $0.detail.isEmpty }
    }

    /// How many of the form's options are the asked ones (the rest are Claude Code's).
    func asked(_ s: AgentPromptScreen) -> Int {
        let flat = { (t: String) in t.filter { !$0.isWhitespace } }
        return questions.first { flat($0.question) == flat(s.prompt.question) }?.options.count ?? 0
    }
}

/// #802: the ExitPlanMode call Claude Code is waiting on: the plan a plan approval on screen is
/// checked against. Its tool_use input's "plan" when it carries one; Claude Code 2.1.318 sends
/// `{}` and keeps the plan in ~/.claude/plans/<slug>.md, named by the transcript's newest
/// main-thread plan_mode attachment (`file`), read at every check (`text(footer:)`).
struct AgentPlanInput: Equatable, Sendable {
    static let toolName = "ExitPlanMode"
    let id: String
    /// The call's own "plan"; nil when it carries none (then `file` is the plan).
    let plan: String?
    var file: String?
    /// The home whose .claude/plans a plan file must be in. Seam: tests pass a temp dir.
    var home: String = NSHomeDirectory()
    /// A plan file over this is not read (Claude Code's plans are a few KiB).
    static let maxFileBytes = 256 * 1024

    static func parse(_ input: [String: Any], id: String, file: String? = nil) -> AgentPlanInput? {
        if let plan = input["plan"] as? String, !plan.isEmpty { return AgentPlanInput(id: id, plan: plan) }
        return file.map { AgentPlanInput(id: id, plan: nil, file: $0) }
    }

    /// The plan to compare with the screen: the call's own, or the plan file read now, only when
    /// it is the one the dialog's last line names ("ctrl+g to edit in <editor> · <path>"). nil
    /// when the footer is missing or names another file, or the file fails `read`.
    func text(footer: String?) -> String? {
        if let plan { return plan }
        guard let file, let path = Self.clean(file), let shown = footer.flatMap(AgentPrompt.planFooterPath),
              Self.clean(shown.hasPrefix("~/") ? home + shown.dropFirst() : shown) == path else { return nil }
        return Self.read(path, root: home + "/.claude/plans")
    }

    /// An absolute path with "." and empty components dropped; nil when relative or holding "..".
    static func clean(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/").filter { $0 != "." }
        guard !parts.contains("..") else { return nil }
        return "/" + parts.joined(separator: "/")
    }

    /// The plan file's text: `path` strictly under `root`, no symlink at any component from "/"
    /// (lstat), a regular file of at most `maxFileBytes`, valid UTF-8, the file opened being the
    /// one checked (O_NOFOLLOW, same device and inode). nil on any miss.
    static func read(_ path: String, root: String) -> String? {
        guard let path = clean(path), let root = clean(root), path.hasPrefix(root + "/") else { return nil }
        var st = stat(), prefix = ""
        for c in path.split(separator: "/") {
            prefix += "/" + c
            guard lstat(prefix, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return nil }
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxFileBytes else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var ft = stat()
        guard fstat(fd, &ft) == 0, ft.st_dev == st.st_dev, ft.st_ino == st.st_ino, (ft.st_mode & S_IFMT) == S_IFREG
        else { return nil }
        var data = Data(), buf = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maxFileBytes {
            let n = Darwin.read(fd, &buf, buf.count)
            guard n >= 0 else { return nil }
            if n == 0 { break }
            data.append(buf, count: n)
        }
        guard data.count <= maxFileBytes, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    /// The plan as compared with the screen, which shows it rendered as markdown: code fence
    /// lines go (the renderer draws no fence), then every whitespace, markdown markup character
    /// and renderer glyph (bullets, box drawing, block elements), the same on both sides.
    /// Every letter, digit and other punctuation is compared, in order.
    /// ponytail: a link, a table alignment row or HTML the renderer redraws reads as a mismatch,
    /// which fails closed (Open in terminal); add renderer rules from a live capture if they bite.
    static func flat(_ lines: [String]) -> String {
        let kept = lines.flatMap { $0.components(separatedBy: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return String(String.UnicodeScalarView(kept.joined().unicodeScalars.filter { u in
            !(u.properties.isWhitespace || markup.contains(u) || (0x2500...0x259F).contains(u.value))
        }))
    }

    private static let markup = Set("#*_`>|-~[]\\•◦▪▫‣·".unicodeScalars)
}

/// #802: Claude Code's plan approval ("Ready to code?", 2.1.318). The window approves only from
/// rows it knows by their on-screen label, only after the plan on screen matched the transcript's.
enum AgentPlanForm {
    static let title = "Ready to code?"
    static let lead = "Here is Claude's plan:"
    static let question = "Claude has written up a plan and is ready to execute. Would you like to proceed?"
    /// The approve rows the window offers: each keeps the conversation and leaves plan mode for
    /// a mode the human picks by its name.
    static let approve = ["Yes, auto-accept edits", "Yes, manually approve edits", "Yes, and use auto mode"]
    /// Known rows left to the terminal: clearing the context, bypass permissions ("Yes, and switch to …").
    static let terminal = ["Yes, clear context", "Yes, and switch to"]
    /// Known "No" rows: the feedback row (its label or its placeholder, with or without its hint) and Ultraplan.
    static let no = ["No, keep planning", "Tell Claude what to change", "No, refine with Ultraplan in a cloud session"]
    static let feedbackHint = "shift+tab to approve with this feedback"

    enum Row: Equatable { case approve, terminal, no, unknown }

    static func flat(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    /// A row by its label and detail lines, all whitespace dropped (a narrow pty wraps anywhere).
    static func row(_ o: AgentPromptOption) -> Row {
        let t = flat(([o.label] + o.detail).joined())
        if o.hint == nil, approve.map(flat).contains(t) { return .approve }
        if terminal.map(flat).contains(where: t.hasPrefix) { return .terminal }
        let hint = flat(feedbackHint)
        if no.map(flat).contains(where: { t == $0 || t == $0 + hint }) { return .no }
        return .unknown
    }

    struct Verdict: Equatable {
        /// The approve rows' digits; empty when any check failed.
        var approve: Set<Int> = []
        /// Why nothing is approved from the window.
        var why: String?
        /// The transcript's plan, shown in the window, when the rows are offered.
        var plan: String?
    }

    /// nil: not a plan approval (none of its title, lead line, question or approve rows).
    /// Else the approve rows, or no rows and why: the transcript's plan is missing; the title,
    /// lead or question is not Claude Code's; a hidden character or the top off the screen; a
    /// row Prosper does not know; the plan file unreadable or not the one the footer names; the
    /// plan on screen is not the transcript's (or only its head);
    /// the caret on a row a digit would type into (the feedback row).
    static func check(_ s: AgentPromptScreen, plan: AgentPlanInput?) -> Verdict? {
        let p = s.prompt
        let lead = p.context.firstIndex { flat($0) == flat(Self.lead) }
        // Any one of them makes it a plan approval: a renamed part then fails a check below.
        guard lead != nil || p.context.contains(where: { flat($0) == flat(title) }) || flat(p.question) == flat(question)
                || p.options.contains(where: { row($0) == .approve }) else { return nil }
        func no(_ why: String) -> Verdict { Verdict(why: why) }
        guard let plan else { return no(AgentWindowText.planUnchecked) }
        guard let lead, flat(p.context[..<lead].joined()) == flat(title), flat(p.question) == flat(question) else {
            return no(AgentWindowText.planLayout)
        }
        guard !p.hasHiddenCharacters, p.topFound else { return no(AgentWindowText.planUnsafe) }
        guard !p.options.contains(where: { row($0) == .unknown }) else { return no(AgentWindowText.planRow) }
        // Read now, never kept: the file is what Claude Code runs; its dialog must name it.
        guard let text = plan.text(footer: s.footer) else { return no(AgentWindowText.planFile) }
        let shown = AgentPlanInput.flat(Array(p.context[(lead + 1)...])), want = AgentPlanInput.flat([text])
        guard shown == want else {
            return no(!shown.isEmpty && want.hasPrefix(shown) ? AgentWindowText.planCut : AgentWindowText.planMismatch)
        }
        // A digit on the feedback row (an input row) is typed into it, never an answer.
        guard let c = s.caret, let on = p.options.first(where: { $0.digit == c }), [.approve, .terminal].contains(row(on)) else {
            return no(AgentWindowText.planCaret)
        }
        let rows = Set(p.options.filter { row($0) == .approve }.map(\.digit))
        return rows.isEmpty ? no(AgentWindowText.planRow) : Verdict(approve: rows, plan: text)
    }
}

/// What the window says when it cannot act. Every one leaves the text where it was.
enum AgentWindowText {
    static let changed = "The prompt changed. Open in terminal"
    static let unconfirmed = "Couldn't confirm. Open in terminal"
    static let working = "Claude is working. Send when it's done, or interrupt it"
    static let blocked = "A prompt is waiting. Answer it first"
    static let noStatus = "dch didn't say what the session is doing. Open in terminal"
    static let draft = "Claude's input already holds a draft. Open in terminal"
    static let noScreen = "This dch can't confirm a message. Open in terminal"
    static let notClaude = "Claude isn't running in this session. Open in terminal"
    static let notSubmitted = "The message is in Claude's input but wasn't sent. Open in terminal"
    static let notWorking = "Claude isn't working, so there's nothing to interrupt"
    static let busy = "Another answer is in flight. Try again in a moment"
    static let unreadable = "Prosper can't read this prompt. Open in terminal"
    static let mismatch = "The prompt on screen doesn't match the conversation. Open in terminal"
    static let unchecked = "Prosper can't check this form against the conversation. Open in terminal"
    /// QA #629 INFO-6: one text for every hold (an island click, an Always allow check or answer, dch's own).
    static let held = "This prompt is being answered or checked elsewhere…"
    static let oneLine = "Your own answer must be one line of plain text"
    /// #810: Claude Code shows "Type something." on the empty Other row, so that answer never shows as typed.
    static let placeholder = "Your own answer can't be Claude Code's \"Type something.\" placeholder"
    // #802: why a plan approval has no approve rows in the window.
    static let planUnchecked = "Prosper can't check this plan against the conversation. Open in terminal to approve"
    static let planLayout = "Prosper doesn't know this plan prompt's layout. Open in terminal to approve"
    static let planUnsafe = "This plan has hidden characters or its top is off the screen. Open in terminal to approve"
    static let planRow = "This plan prompt has a choice Prosper doesn't know. Open in terminal to approve"
    static let planMismatch = "The plan on screen doesn't match the conversation. Open in terminal to approve"
    static let planFile = "Prosper can't read this plan's file, or the prompt names another one. Open in terminal to approve"
    static let planCut = "Only part of the plan fits on screen. Open in terminal to approve"
    static let planCaret = "Claude's selection is on the feedback row. Open in terminal to approve"
    /// The plan rows the window never answers, shown under the rows.
    static let planTerminal = "Clearing the context and bypass permissions are chosen in the terminal"
}

enum AgentWindowOutcome: Equatable, Sendable {
    case done
    /// Nothing more was sent (or what was sent is not confirmed): the reason, shown with Open in terminal.
    case failed(String)
}

/// The dch steps of each action, off main, against the island's IO. Pure apart from `io`
/// and `pause`, so tests drive every path with a fake.
struct AgentWindowDriver: Sendable {
    let key: AgentSessionKey
    let io: AgentPromptIO
    var pause: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// After a key: this many reads, `step` apart, for the screen to show it (about 2 s).
    var reads = 12
    var step: TimeInterval = 0.15
    /// After a message or Esc: this many status/screen reads, `confirmStep` apart (about 6 s).
    var confirmReads = 12
    var confirmStep: TimeInterval = 0.5

    func status() -> String { io.status(key).trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Message

    /// The message as sent: CRLF and CR to LF, every other control character (C0 with ESC,
    /// DEL, C1) dropped but LF and tab, which a bracketed paste keeps as text; trimmed; nil when
    /// nothing is left. QA #629 INFO-1: an ESC[201~ would end dch's paste early and type the rest as keys.
    static func message(_ text: String) -> String? {
        let t = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let kept = String(String.UnicodeScalarView(t.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.isEmpty ? nil : kept
    }

    /// One message, only while dch says idle or done: `--say` types it as one bracketed paste
    /// and presses Enter once Claude's composer shows it. Confirmed by a read: Claude started
    /// working (or asks something), or the message's head shows on screen more often than before.
    func send(_ text: String) -> AgentWindowOutcome {
        let st = status()
        guard st == "idle" || st == "done" else {
            return .failed(st == "working" ? AgentWindowText.working
                           : st == "blocked" ? AgentWindowText.blocked : AgentWindowText.noStatus)
        }
        let head = Self.head(text), before = Self.count(head, in: io.read(key))
        let reply = Self.sayReply(io.say(key, text))
        switch (reply?.result, reply?.reason) {
        case ("ok"?, _): break
        case (nil, _): return .failed(AgentWindowText.unconfirmed)
        case ("skipped"?, "prompt"?): return .failed(AgentWindowText.blocked)
        case ("skipped"?, "draft"?): return .failed(AgentWindowText.draft)
        case ("skipped"?, "no_screen"?): return .failed(AgentWindowText.noScreen)
        case ("skipped"?, "not_claude"?): return .failed(AgentWindowText.notClaude)
        case ("failed"?, "not_submitted"?): return .failed(AgentWindowText.notSubmitted)
        case (let r?, let why): return .failed("dch didn't send it (\(why ?? r)). Open in terminal")
        }
        for _ in 0..<confirmReads {
            pause(confirmStep)
            let st = status()
            if st == "working" || st == "blocked" { return .done }
            if Self.count(head, in: io.read(key)) > before { return .done }
        }
        return .failed(AgentWindowText.unconfirmed)
    }

    /// dch's `--say --json` line for the session: (result, reason); nil for no answer or
    /// anything that is not one.
    static func sayReply(_ out: String) -> (result: String, reason: String?)? {
        for line in out.split(whereSeparator: \.isNewline).reversed() {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let r = o["result"] as? String else { continue }
            let why = (o["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (r, why)
        }
        return nil
    }

    /// The first 24 non-space characters: what the screen shows of a sent message, however wrapped.
    static func head(_ text: String) -> String { String(text.filter { !$0.isWhitespace }.prefix(24)) }

    static func count(_ needle: String, in screen: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return screen.filter { !$0.isWhitespace }.components(separatedBy: needle).count - 1
    }

    // MARK: Interrupt

    /// Esc while dch says working; confirmed by dch leaving working or a new "Interrupted" on screen.
    /// QA #629 INFO-2: the status is asked last, right before the key: a prompt raised during
    /// the read is blocked, and an Esc there would answer it "No".
    func interrupt() -> AgentWindowOutcome {
        let before = Self.count("Interrupted", in: io.read(key))
        guard status() == "working" else { return .failed(AgentWindowText.notWorking) }
        io.keys(key, ["esc"])
        for _ in 0..<confirmReads {
            pause(confirmStep)
            let st = status()
            if !st.isEmpty, st != "working" { return .done }
            if Self.count("Interrupted", in: io.read(key)) > before { return .done }
        }
        return .failed(AgentWindowText.unconfirmed)
    }

    // MARK: Prompt key sequences

    enum Step: Equatable { case done, changed, unconfirmed }

    /// One key. Before it: a fresh read must parse and pass `ready` (the dialog's identity and
    /// the exact state the key was planned for) and dch must say blocked, else nothing is sent.
    /// After it: reads until `after` says done (true) or something else (false); nil waits.
    /// An empty read (timed out) tells nothing.
    func key(ready: (AgentPromptScreen) -> Bool, send: () -> Void, after: (AgentPromptScreen?) -> Bool?) -> Step {
        guard let s = AgentPrompt.screen(io.read(key)), ready(s), status() == "blocked" else { return .changed }
        send()
        for _ in 0..<reads {
            pause(step)
            let text = io.read(key)
            if text.isEmpty { continue }
            switch after(AgentPrompt.screen(text)) {
            case true?: return .done
            case false?: return .changed
            case nil: continue
            }
        }
        return .unconfirmed
    }

    /// The form's identity for a key sequence: the dialog as `sameDialog` compares it, less what
    /// the sequence itself changes (a preview follows the caret; the Other row shows typed text).
    static func same(_ a: AgentPrompt, _ b: AgentPrompt, other: Int? = nil) -> Bool {
        func strip(_ p: AgentPrompt) -> AgentPrompt {
            let opts = p.options.map { o in
                o.digit == other ? AgentPromptOption(digit: o.digit, label: "", hint: nil, detail: []) : o
            }
            return AgentPrompt(question: p.question, context: p.context, options: opts, preview: [], notes: p.notes,
                               topFound: p.topFound)
        }
        return strip(a).sameDialog(strip(b))
    }

    /// After Enter: the form is gone (another prompt, or none); the same form still up waits.
    static func left(_ e: AgentPrompt, other: Int? = nil) -> (AgentPromptScreen?) -> Bool? {
        { s in s.map { same($0.prompt, e, other: other) ? nil : true } ?? true }
    }

    static func outcome(_ s: Step) -> AgentWindowOutcome {
        switch s {
        case .done: .done
        case .changed: .failed(AgentWindowText.changed)
        case .unconfirmed: .failed(AgentWindowText.unconfirmed)
        }
    }

    /// The rows the arrows move through, top to bottom: a multi-select's boxes, its Submit row
    /// (nil), then its unboxed rows ("Chat about this"); every other form's options in order.
    static func order(_ s: AgentPromptScreen) -> [Int?] {
        let digits = s.prompt.options.map(\.digit)
        guard let n = s.checked?.count else { return digits }
        return digits.prefix(n).map { $0 } + [nil] + digits.dropFirst(n).map { $0 }
    }

    /// #802: arrows from `from` to `to` along `order`, one at a time. Before each: the form `holds`
    /// with the caret where planned; after it: the caret on the next row (the same row waits).
    func walk(_ from: Int?, to: Int?, order: [Int?], holds: @escaping (AgentPromptScreen) -> Bool) -> Step {
        guard var i = order.firstIndex(of: from), let t = order.firstIndex(of: to) else { return .unconfirmed }
        while i != t {
            let c = order[i], down = i < t, next = order[down ? i + 1 : i - 1]
            let r = key(ready: { holds($0) && $0.caret == c },
                        send: { io.keys(key, [down ? "down" : "up"]) },
                        after: { s in
                            guard let s else { return nil }
                            guard holds(s) else { return false }
                            return s.caret == next ? true : s.caret == c ? nil : false
                        })
            guard r == .done else { return r }
            i += down ? 1 : -1
        }
        return .done
    }

    /// Multi-select: each box whose state differs from `picks` gets its digit (a digit toggles),
    /// the caret walks to the Submit row, then Enter. Each key verified before and after.
    /// #802: `other`, the Other row's typed answer: after the toggles the caret walks to that row,
    /// the text is typed only into the empty row (its "Type something" placeholder) and must show
    /// there with the row's box ticked (Claude Code ticks it on typing), then Submit. A digit is
    /// never sent while the caret is on the Other row: Claude Code types it there as text.
    func multi(_ e: AgentPromptScreen, picks: Set<Int>, other: (digit: Int, text: String)? = nil) -> AgentWindowOutcome {
        guard var checked = e.checked else { return .failed(AgentWindowText.changed) }
        // #810's rule here too: the placeholder as the answer never confirms and stays in the row.
        if let o = other, Self.isPlaceholder(o.text) { return .failed(AgentWindowText.placeholder) }
        let n = checked.count, p = e.prompt, k = other?.digit, order = Self.order(e)
        let input = p.options.first { Self.isPlaceholder($0.label) }?.digit
        let (empty, shows) = Self.otherRow(k ?? 0, text: other?.text ?? "")
        var caret = e.caret
        let toggles = (1...n).filter { $0 != k && checked[$0 - 1] != picks.contains($0) }
        // Off the Other row first, one row up, when a digit must be sent.
        if !toggles.isEmpty, let i = input, caret == i, let at = order.firstIndex(of: i), at > 0 {
            let now = checked, up = order[at - 1]
            let r = walk(i, to: up, order: order, holds: { Self.same($0.prompt, p) && $0.checked == now })
            guard r == .done else { return Self.outcome(r) }
            caret = up
        }
        for d in toggles {
            var want = checked
            want[d - 1].toggle()
            let now = checked
            let r = key(ready: { Self.same($0.prompt, p) && $0.checked == now && ($0.caret != input || input == nil) },
                        send: { io.send(key, String(d)) },
                        after: { s in
                            guard let s else { return nil }
                            guard Self.same(s.prompt, p) else { return false }
                            if s.checked == want { caret = s.caret; return true }
                            return s.checked == now ? nil : false
                        })
            guard r == .done else { return Self.outcome(r) }
            checked = want
        }
        if let o = other {
            let now = checked
            var ticked = now
            ticked[o.digit - 1] = true
            let w = walk(caret, to: o.digit, order: order, holds: { Self.same($0.prompt, p, other: k) && $0.checked == now })
            guard w == .done else { return Self.outcome(w) }
            let typed = key(ready: { Self.same($0.prompt, p, other: k) && $0.checked == now && $0.caret == o.digit && empty($0) },
                            send: { io.send(key, o.text) },
                            after: { s in
                                guard let s else { return nil }
                                guard Self.same(s.prompt, p, other: k), s.caret == o.digit else { return false }
                                return shows(s) && s.checked == ticked ? true : nil
                            })
            guard typed == .done else { return Self.outcome(typed) }
            checked = ticked
            caret = o.digit
        }
        let final = checked
        let holds = { (s: AgentPromptScreen) in Self.same(s.prompt, p, other: k) && s.checked == final && (k == nil || shows(s)) }
        let w = walk(caret, to: nil, order: order, holds: holds)
        guard w == .done else { return Self.outcome(w) }
        return Self.outcome(key(ready: { holds($0) && $0.caret == nil }, send: { io.keys(key, ["enter"]) },
                                after: Self.left(p, other: k)))
    }

    /// #802: "Chat about this" (a single or multi-select question form): the caret walks to the
    /// row (Claude Code draws it under a rule, outside the options, reached by "down" from the
    /// last one), each arrow verified with the form and its boxes as planned, then Enter.
    func chat(_ e: AgentPromptScreen, digit c: Int) -> AgentWindowOutcome {
        let p = e.prompt, boxes = e.checked
        let holds = { (s: AgentPromptScreen) in Self.same(s.prompt, p) && s.checked == boxes }
        let w = walk(e.caret, to: c, order: Self.order(e), holds: holds)
        guard w == .done else { return Self.outcome(w) }
        return Self.outcome(key(ready: { holds($0) && $0.caret == c }, send: { io.keys(key, ["enter"]) }, after: Self.left(p)))
    }

    /// #802: a plan approval's approve row (AgentPlanForm): its digit, only while the whole dialog
    /// (the plan included) is the one checked against the transcript and the caret is where it
    /// was planned (on a Yes row: a digit on the feedback row is typed into it). After: the
    /// dialog is gone.
    func approve(_ e: AgentPromptScreen, digit d: Int) -> AgentWindowOutcome {
        let p = e.prompt, c = e.caret
        return Self.outcome(key(ready: { $0.prompt.sameDialog(p) && $0.checked == nil && $0.caret == c && $0.footer == e.footer },
                                send: { io.send(key, String(d)) }, after: Self.left(p)))
    }

    /// Preview form (#526): the digit moves the focus (and the preview), Enter answers.
    func preview(_ e: AgentPromptScreen, digit d: Int) -> AgentWindowOutcome {
        let p = e.prompt
        if e.caret != d {
            let c = e.caret
            let r = key(ready: { Self.same($0.prompt, p) && $0.checked == nil && $0.caret == c },
                        send: { io.send(key, String(d)) },
                        after: { s in
                            guard let s else { return nil }
                            guard Self.same(s.prompt, p) else { return false }
                            return s.caret == d ? true : s.caret == c ? nil : false
                        })
            guard r == .done else { return Self.outcome(r) }
        }
        return Self.outcome(key(ready: { Self.same($0.prompt, p) && $0.checked == nil && $0.caret == d },
                                send: { io.keys(key, ["enter"]) }, after: Self.left(p)))
    }

    /// The Other row of a single-select form ("Type something."): the caret walks to it, the
    /// one-line text is typed (the row must then show it), then Enter. QA #629 INFO-5: typed only
    /// into the empty row (its "Type something." placeholder), never after text already there.
    /// #805: Claude Code 2.1.318 keeps that placeholder (dimmed) on the focused empty row, before
    /// any typing and after deleting back to empty (live capture), so the gate is the placeholder.
    /// The row shows the text only once it is no longer the placeholder: "some" or "Type" is in
    /// "Typesomething." before the row redraws.
    func other(_ e: AgentPromptScreen, digit k: Int, text: String) -> AgentWindowOutcome {
        let p = e.prompt
        let (empty, shows) = Self.otherRow(k, text: text)
        // #810: the placeholder as the answer would be typed but never confirmed, and stay in the row.
        guard !Self.isPlaceholder(text) else { return .failed(AgentWindowText.placeholder) }
        var caret = e.caret
        for _ in 0..<(p.options.count + 1) {
            guard let c = caret, c != k else { break }
            let down = c < k, next = down ? c + 1 : c - 1
            let r = key(ready: { Self.same($0.prompt, p, other: k) && $0.checked == nil && $0.caret == c },
                        send: { io.keys(key, [down ? "down" : "up"]) },
                        after: { s in
                            guard let s else { return nil }
                            guard Self.same(s.prompt, p, other: k) else { return false }
                            if s.caret == next { caret = next; return true }
                            return s.caret == c ? nil : false
                        })
            guard r == .done else { return Self.outcome(r) }
        }
        guard caret == k else { return .failed(AgentWindowText.unconfirmed) }
        let typed = key(ready: { Self.same($0.prompt, p, other: k) && $0.checked == nil && $0.caret == k && empty($0) },
                        send: { io.send(key, text) },
                        after: { s in
                            guard let s else { return nil }
                            guard Self.same(s.prompt, p, other: k), s.caret == k else { return false }
                            return shows(s) ? true : nil
                        })
        guard typed == .done else { return Self.outcome(typed) }
        return Self.outcome(key(ready: { Self.same($0.prompt, p, other: k) && $0.caret == k && shows($0) },
                                send: { io.keys(key, ["enter"]) }, after: Self.left(p, other: k)))
    }

    /// The Other row `k`: empty (its placeholder, any whitespace), and showing `text` (once it is no
    /// longer the placeholder: "some" or "Type" is in "Typesomething." before the row redraws).
    static func otherRow(_ k: Int, text: String)
        -> (empty: @Sendable (AgentPromptScreen) -> Bool, shows: @Sendable (AgentPromptScreen) -> Bool) {
        let flat = { @Sendable (t: String) in t.filter { !$0.isWhitespace } }
        let row = { @Sendable (s: AgentPromptScreen) in
            s.prompt.options.first { $0.digit == k }.map { flat(([$0.label] + $0.detail).joined()) }
        }
        let empty = { @Sendable (s: AgentPromptScreen) -> Bool in row(s).map(isPlaceholder) ?? false }
        return (empty, { s in !empty(s) && (row(s)?.contains(flat(text)) ?? false) })
    }

    /// Other text the window types: one line, printable, at most 500 characters.
    static func otherText(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 500, !t.unicodeScalars.contains(where: AgentPrompt.isHidden), !isPlaceholder(t) else { return nil }
        return t
    }

    /// Claude Code's empty Other row text, whitespace dropped as the screen read may split it.
    static func isPlaceholder(_ text: String) -> Bool {
        ["Typesomething.", "Typesomething"].contains(text.filter { !$0.isWhitespace })
    }
}

// MARK: - The panel

/// What the detail pane shows above the input box for the selected session.
enum AgentWindowPanel: Equatable {
    case none
    /// Blocked, the screen not read yet.
    case reading
    /// Always allow (or an island click) holds the prompt: no buttons, as the island shows no card.
    case held
    /// Nothing Prosper may answer: why, and the screen's last lines.
    case terminal(String, [String])
    case prompt(AgentWindowPrompt)

    /// The panel for a blocked session's screen. `ask`: the transcript's pending
    /// AskUserQuestion. A question form (header chips) that does not match it shows no
    /// buttons. Without it, a single-select form keeps the island card's digit answers
    /// and the new key sequences (multi-select, preview, Other, Chat about this) stay off.
    /// #802 `plan`: the transcript's pending ExitPlanMode; a plan approval offers its approve
    /// rows only when AgentPlanForm.check passes, else shows why.
    @MainActor
    static func classify(_ screen: String, ask: AgentAskInput?, plan: AgentPlanInput? = nil) -> AgentWindowPanel {
        guard let s = AgentPrompt.screen(screen) else { return .terminal(AgentWindowText.unreadable, AgentPrompt.tail(screen)) }
        let p = s.prompt, tail = AgentPrompt.tail(screen)
        let question = p.context.last.map(AgentPrompt.isChipLine) ?? false
        // Claude Code's last step of a multi-question form, after the asked questions.
        let review = p.options.map(\.label) == ["Submit answers", "Cancel"]
        if question, !review, let ask, !ask.matches(s) { return .terminal(AgentWindowText.mismatch, tail) }
        let safe = !p.hasHiddenCharacters && p.topFound
        // #802: the rows a matched, safe question form answers by key sequences: its empty Other
        // row (typed text) and "Chat about this" (a walk and Enter), both after the asked options.
        let asked = ask.map { $0.asked(s) } ?? 0
        let checked = question && !review && ask != nil && safe
        let other = checked ? p.options.first { $0.digit > asked && AgentWindowDriver.isPlaceholder($0.label) } : nil
        let chat = checked
            ? p.options.first { $0.digit > asked && $0.detail.isEmpty && AgentPlanForm.flat($0.label) == "Chataboutthis" } : nil
        if s.checked != nil || !p.preview.isEmpty {
            guard ask != nil, question else { return .terminal(AgentWindowText.unchecked, tail) }
            let rows = p.options.filter { $0.digit <= asked }
            let multi = s.checked != nil
            return .prompt(AgentWindowPrompt(kind: multi ? .multi : .preview, screen: s, buttons: rows,
                                             enabled: safe ? Set(rows.map(\.digit)) : [], caption: safe ? [] : p.layout.caption,
                                             other: multi ? other : nil, chat: multi ? chat : nil))
        }
        // A single choice: the island card's own rule decides each button (AgentPrompt.answer asks it again).
        let rows = p.options.filter { $0.digit != other?.digit && $0.digit != chat?.digit }
        let enabled = Set(rows.filter { p.isEnabled($0) }.map(\.digit))
        // #802: a plan approval offers only its checked approve rows. The island rule's own rows stay
        // off: "No, keep planning" is an input row (feedback is typed in the terminal), and a row the
        // rule enables by its label alone may be one Prosper doesn't know.
        if !question, let v = AgentPlanForm.check(s, plan: plan) {
            let terminal = p.options.contains { AgentPlanForm.row($0) == .terminal }
            return .prompt(AgentWindowPrompt(kind: .choose, screen: s, buttons: rows, enabled: v.approve,
                                             caption: !v.approve.isEmpty && terminal ? [AgentWindowText.planTerminal] : [],
                                             other: nil, approve: v.approve, plan: v.plan, why: v.why))
        }
        return .prompt(AgentWindowPrompt(kind: .choose, screen: s, buttons: rows, enabled: enabled,
                                         caption: p.layout.caption, other: other, chat: chat))
    }
}

struct AgentWindowPrompt: Equatable {
    enum Kind: Equatable { case choose, preview, multi }
    let kind: Kind
    let screen: AgentPromptScreen
    /// One button (or checkbox) per option shown.
    let buttons: [AgentPromptOption]
    let enabled: Set<Int>
    /// Why some buttons are off (the island card's caption).
    let caption: [String]
    /// The Other row a typed answer goes to, when offered.
    let other: AgentPromptOption?
    /// #802: the "Chat about this" row, answered by a walk and Enter, when offered.
    var chat: AgentPromptOption?
    /// #802: a plan approval's approve rows (AgentWindowDriver.approve), the transcript's plan
    /// shown above them, and why none is offered.
    var approve: Set<Int> = []
    var plan: String?
    var why: String?
}

// MARK: - The window's interaction model

/// The input box, interrupt and prompt panel of the selected live session. Reads only on a
/// transition (the selection lands on a blocked session, the session re-enters blocked, a hold
/// ends, after its own action), never on a timer, never while the window is hidden.
@MainActor
final class AgentWindowInteraction: ObservableObject {
    @Published private(set) var panel: AgentWindowPanel = .none
    @Published private(set) var notice: String?
    @Published private(set) var busy = false
    /// Multi-select: the boxes the human ticked (digits), seeded from the screen.
    @Published var picks: Set<Int> = []
    @Published var otherText = ""
    /// The input box's text per session, kept across selections while the window is open.
    @Published private var drafts: [AgentSessionKey: String] = [:]

    private(set) var session: AgentSession?
    private var screen: String?
    private var held = false
    private var readGen = 0
    private var reading = false
    /// The read after the window's own answer: a screen with no prompt then is Claude at
    /// work before the list says so, not a prompt Prosper can't read.
    private var afterAction = false
    /// Reads started (tests: no poll).
    private(set) var reads = 0
    /// The pending AskUserQuestion of the selected session's transcript.
    var ask: AgentAskInput? {
        didSet { if ask != oldValue { reclassify() } }
    }
    /// #802: the pending ExitPlanMode of the selected session's transcript.
    var plan: AgentPlanInput? {
        didSet { if plan != oldValue { reclassify() } }
    }

    // Seams.
    /// Set by AgentsWindow.show; nil (tests of the D1 sidebar, the island off): nothing is read or sent.
    var controller: AgentIslandController?
    var pause: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var readQueue: (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }

    var draft: String {
        get { session.flatMap { drafts[$0.key] } ?? "" }
        set { if let k = session?.key { drafts[k] = newValue.isEmpty ? nil : newValue } }
    }

    /// The selection (nil: none, hidden or closed). Cheap: called on every sidebar rebuild.
    func follow(_ s: AgentSession?) {
        let was = session
        session = s
        guard let s, controller != nil else {
            readGen += 1
            reading = false
            screen = nil
            held = false
            setPanel(.none)
            if s == nil { notice = nil }
            return
        }
        if was?.key != s.key {
            notice = nil
            otherText = ""
            screen = nil
            readGen += 1
            reading = false
        }
        guard s.state == .blocked else {
            screen = nil
            held = false
            afterAction = false
            setPanel(.none)
            return
        }
        if controller?.heldByAutoAllow(s.key) == true {
            if !busy { held = true; screen = nil; setPanel(.held) }
            return
        }
        if held || was?.key != s.key || was?.state != .blocked || screen == nil && !reading {
            if was?.state != .blocked || was?.key != s.key { afterAction = false }
            held = false
            read()
        }
    }

    /// The controller published (a hold may have ended).
    func holdChanged() { follow(session) }

    private func read() {
        guard let s = session, let io = controller?.io else { return }
        readGen += 1
        let gen = readGen, key = s.key
        reads += 1
        reading = true
        if case .prompt = panel {} else { setPanel(.reading) }
        readQueue { [weak self] in
            let text = io.read(key)
            AgentTranscriptModel.onMain { self?.landed(text, gen) }
        }
    }

    private func landed(_ text: String, _ gen: Int) {
        guard gen == readGen else { return }
        reading = false
        guard session?.state == .blocked else { return }
        screen = text
        reclassify()
    }

    private func reclassify() {
        guard let screen, session?.state == .blocked, !held else { return }
        var p = AgentWindowPanel.classify(screen, ask: ask, plan: plan)
        if afterAction, p == .terminal(AgentWindowText.unreadable, AgentPrompt.tail(screen)) { p = .none }
        if case .prompt(let w) = p, w.kind == .multi, let c = w.screen.checked {
            picks = Set(c.indices.filter { c[$0] }.map { $0 + 1 })
        }
        setPanel(p)
    }

    private func setPanel(_ p: AgentWindowPanel) { if panel != p { panel = p } }

    // MARK: Actions

    /// A single choice: the island click's own guard (re-read, sameDialog, blocked, one digit).
    func answer(_ o: AgentPromptOption) {
        guard case .prompt(let w) = panel, w.kind == .choose, w.enabled.contains(o.digit), let s = session else { return }
        // #802: a plan's approve row: the driver's checked digit, not the island rule (which keeps mode changes off).
        if w.approve.contains(o.digit) {
            let d = driver(s), e = w.screen
            return act(s, prompt: e.prompt) { io in d(io).approve(e, digit: o.digit) }
        }
        let key = s.key, p = w.screen.prompt
        act(s, prompt: p) { io in
            AgentPrompt.answer(key, digit: o.digit, expected: p, io: io) == .sent ? .done : .failed(AgentWindowText.changed)
        }
    }

    /// A preview form's option: its digit, then Enter.
    func choosePreview(_ o: AgentPromptOption) {
        guard case .prompt(let w) = panel, w.kind == .preview, w.enabled.contains(o.digit), let s = session else { return }
        let d = driver(s), e = w.screen
        act(s, prompt: e.prompt) { io in d(io).preview(e, digit: o.digit) }
    }

    /// A multi-select form: the ticked boxes, then Submit.
    func submitPicks() {
        // A form the island rule must not answer (hidden characters, no top rule) has
        // every box off; Submit there would untick the screen's boxes and send an empty answer.
        guard case .prompt(let w) = panel, w.kind == .multi, !w.enabled.isEmpty, let s = session else { return }
        // #802: the Other row's text, when typed: the same one-line rules as a single choice's.
        var other: (digit: Int, text: String)?
        if let o = w.other, !otherText.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let text = AgentWindowDriver.otherText(otherText) else {
                notice = AgentWindowDriver.isPlaceholder(otherText) ? AgentWindowText.placeholder : AgentWindowText.oneLine
                return
            }
            other = (o.digit, text)
        }
        let picks = picks.intersection(w.enabled), d = driver(s), e = w.screen, typed = other
        act(s, prompt: e.prompt) { io in d(io).multi(e, picks: picks, other: typed) }
    }

    /// #802: "Chat about this".
    func chat() {
        guard case .prompt(let w) = panel, let c = w.chat, let s = session else { return }
        let d = driver(s), e = w.screen
        act(s, prompt: e.prompt) { io in d(io).chat(e, digit: c.digit) }
    }

    /// The Other row of a single choice: the typed answer.
    func sendOther() {
        guard case .prompt(let w) = panel, w.kind == .choose, let o = w.other, let s = session else { return }
        guard let text = AgentWindowDriver.otherText(otherText) else {
            notice = AgentWindowDriver.isPlaceholder(otherText) ? AgentWindowText.placeholder : AgentWindowText.oneLine
            return
        }
        let d = driver(s), e = w.screen
        act(s, prompt: e.prompt) { io in d(io).other(e, digit: o.digit, text: text) }
    }

    /// The input box: one message while the session is idle or done. Kept unless confirmed.
    func send() {
        guard let s = session, let text = AgentWindowDriver.message(draft) else { return }
        // The list's state first: a blocked session's prompt must never be marked the human's by a message.
        guard s.state == .idle || s.state == .done else {
            notice = s.state == .blocked ? AgentWindowText.blocked : AgentWindowText.working
            return
        }
        let key = s.key, typed = draft, d = driver(s)
        act(s, prompt: nil, run: { io in d(io).send(text) }) { [weak self] in
            if self?.drafts[key] == typed { self?.drafts[key] = nil }
        }
    }

    /// Esc while working.
    func interrupt() {
        guard let s = session, s.state == .working else { return }
        let d = driver(s)
        act(s, prompt: nil) { io in d(io).interrupt() }
    }

    /// The driver for `s` over the IO the controller hands the action.
    private func driver(_ s: AgentSession) -> @Sendable (AgentPromptIO) -> AgentWindowDriver {
        let key = s.key, pause = pause
        return { AgentWindowDriver(key: key, io: $0, pause: pause) }
    }

    /// Through the controller's human-click path; on a result, one fresh read refreshes the panel.
    private func act(_ s: AgentSession, prompt: AgentPrompt?, run: @escaping @Sendable (AgentPromptIO) -> AgentWindowOutcome,
                     sent: (@MainActor () -> Void)? = nil) {
        guard let controller, !busy else { return }
        notice = nil
        busy = true
        let key = s.key
        let ok = controller.humanAction(s, prompt: prompt, run: run) { [weak self] r in
            guard let self else { return }
            self.busy = false
            // QA #629 INFO-3: a confirmed send clears its own session's draft, selected or not.
            if r == .done { sent?() }
            guard self.session?.key == key else { return }
            if case .failed(let why) = r { self.notice = why }
            if prompt != nil {
                self.screen = nil
                self.afterAction = true
                if self.session?.state == .blocked { self.read() }
            }
        }
        if !ok {
            busy = false
            notice = AgentWindowText.busy
        }
    }
}
