import SwiftUI

// #2024 (design work/xa2024a/design.md sections 1.3, 2.3, 3, 4; P3): the Questions tab answers an Open question. The
// operator types a ruling or picks a suggested answer (a chip), Send runs `dch --xray <n> --answer <qid> - --json
// --notify <target>` with the ruling on stdin (dch 1.189.0), dch tells the asking session itself (OQ-214/215: no retry,
// no Prosper --say) and the tab re-reads --questions at once. Only from a click: no ctl command (design 4.1).

extension XrayTarget {
    /// dch 1.189.0: `--answer <qid> -` reads the ruling from stdin, local and host:name alike; `--notify` tells `notify`.
    func answerArgs(_ qid: String, notify: String) -> [String] {
        ["--xray", name, "--answer", qid, "-", "--json", "--notify", notify]
    }
}

extension XrayPanels {
    /// #2024: the live session names next to `target`: a local drawer's socket dir (the island's sessions), a remote
    /// drawer's host (the window's remote rows). Compared with a row's asker only.
    static func liveNames(_ pane: UUID, _ target: XrayTarget) -> Set<String> {
        guard let m = model(pane) else { return [] }
        if let dir = target.dir { return Set((m.store?.sessions ?? []).filter { $0.key.dir == dir }.map(\.name)) }
        guard let host = XrayPanelModel.host(of: target) else { return [] }
        return Set(m.remoteSessions.filter { $0.host == host }.map(\.name))
    }
}

/// dch's one result line for `--answer` (design 1.1, as released in 1.189.0). Every string is outside data.
struct XrayAnswerResult: Decodable, Equatable {
    struct Told: Decodable, Equatable {
        let session: String?
        let via: String?
        let ok: Bool?
        let why: String?
    }
    let answered: Bool?
    let why: String?
    let detail: String?
    let told: Told?

    /// The first line, at most 64 KB; nil: none, or not this shape.
    static func parse(_ out: Data) -> XrayAnswerResult? {
        guard let line = out.prefix(64 * 1024).split(separator: 0x0A, omittingEmptySubsequences: true).first else { return nil }
        return try? JSONDecoder().decode(Self.self, from: line)
    }
}

/// One suggested answer as a chip: the recommendation first, then the options in order (a repeat of it left out).
struct XrayAnswerChip: Identifiable, Equatable {
    let id: Int
    let text: String
    let recommended: Bool
    var shown: String { OutsideText.shown(text, max: 60) }

    static func of(_ t: XrayTasks.Task) -> [XrayAnswerChip] {
        let all = (t.recommended.map { [($0, true)] } ?? []) + t.options.filter { $0 != t.recommended }.map { ($0, false) }
        return all.enumerated().map { XrayAnswerChip(id: $0.offset, text: $0.element.0, recommended: $0.element.1) }
    }
}

extension XrayPanelModel {
    /// The answer verb's dch (1.189.0); the header's "answer":true says the reading machine has an answer_command.
    static let answerDch = [1, 189, 0]
    static let answerMax = 4000
    static let answerLineLife: TimeInterval = 6

    /// The Answer button shows only when both say so: this Mac's dch knows the verb and the header offers it.
    var answerShown: Bool {
        questions?.answerable == true && XrayPanels.probed.map { DchCommand.isAtLeast($0.version, Self.answerDch) } == true
    }

    static func isOpen(_ t: XrayTasks.Task) -> Bool { t.status == .active || t.status == .pending }

    /// "host" of a remote drawer's "host:name"; nil for a local one.
    static func host(of t: XrayTarget) -> String? {
        guard t.dir == nil, let i = t.name.firstIndex(of: ":"), i != t.name.startIndex else { return nil }
        return String(t.name[..<i])
    }

    /// Design 3 "Who": the asker when it is exactly a live session's name next to the drawer (as host:asker on a remote
    /// drawer's host), else the drawer's own session. The asker is ledger data: compared only, never a path or a flag.
    static func notifyTarget(asker: String?, drawer: XrayTarget, live: Set<String>) -> String {
        guard let a = asker, !a.isEmpty, !a.hasPrefix("-"), live.contains(a) else { return drawer.name }
        if drawer.dir != nil { return a }
        return host(of: drawer).map { "\($0):\(a)" } ?? drawer.name
    }

    /// Design 4: a qid dch takes: 1 to 32 of [A-Za-z0-9._-], not starting with "-".
    static func qidOK(_ q: String) -> Bool {
        (1...32).contains(q.utf8.count) && !q.hasPrefix("-")
            && q.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// Design 4's field check on the trimmed text: nil sendable; "" empty (Send off, no line); else the line.
    static func answerCheck(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        let n = t.utf8.count
        if n > answerMax { return "The answer is \(n) bytes: at most \(answerMax)" }
        // LF and tab stay (a pasted ruling keeps its lines); any other unseen scalar, NUL included, is refused, never cleaned
        if t.unicodeScalars.contains(where: { $0 != "\n" && $0 != "\t" && OutsideText.isUnseen($0) }) { return "The answer has a hidden character" }
        return nil
    }

    /// The editor's row as it is now (it may have moved to Answered, or gone).
    var answerRow: XrayTasks.Task? { answerQuestion.flatMap { q in questions?.tasks.first { $0.id == q.id } } }

    var canSend: Bool {
        !sending && answerShown && answerRow.map(Self.isOpen) == true && Self.answerCheck(answerText) == nil
            && answerQuestion.map { Self.qidOK($0.id) } == true
    }

    /// The editor's one line: what dch said, else the field's own check (a count near the limit).
    var answerStatus: String? {
        if let l = answerLine { return l }
        guard answerQuestion != nil, let c = Self.answerCheck(answerText) else {
            let n = answerText.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
            return answerQuestion != nil && n > Self.answerMax - 400 ? "\(n) of \(Self.answerMax) bytes" : nil
        }
        return c.isEmpty ? nil : c
    }

    func openAnswer(_ t: XrayTasks.Task) {
        guard answerShown, Self.isOpen(t) else { return }
        if answerQuestion?.id != t.id { answerText = "" }
        answerQuestion = t
        (answerLine, answerLineUntil) = (nil, nil)
    }

    func cancelAnswer() {
        answerQuestion = nil
        answerText = ""
        (answerLine, answerLineUntil) = (nil, nil)
    }

    /// A chip replaces the field's text with its whole text.
    func pick(_ c: XrayAnswerChip) { answerText = c.text; answerLine = nil }

    /// One dch process, off main (XrayPanels.run); its own task, so a poll's cancel never SIGTERMs a write.
    func sendAnswer() {
        guard canSend, let q = answerQuestion, let dch, let run else { return }
        let notify = Self.notifyTarget(asker: answerRow?.asker ?? q.asker, drawer: target, live: liveNames())
        let a = target.answerArgs(q.id, notify: notify), env = target.env
        let input = Data(answerText.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        sending = true
        (answerLine, answerLineUntil) = ("Sending\u{2026}", nil)
        answerTask = Task { [weak self] in
            let r = await XrayPanels.stdin.withValue(input) { await run(dch, a, env) }
            guard let self else { return }
            self.sending = false
            self.tookAnswer(r, notify: notify)
        }
    }

    /// Design 1.3's table; the editor keeps its text on every failure.
    func tookAnswer(_ r: (status: Int32, out: Data), notify: String) {
        let res = XrayAnswerResult.parse(r.out), host = Self.host(of: target)
        func say(_ l: String) { (answerLine, answerLineUntil) = (l, nil) }
        if unreached(r.status) { return say("Host unreachable: not answered") }
        switch r.status {
        case 0:
            (answerQuestion, answerText) = (nil, "")
            (answerLine, answerLineUntil) = (Self.toldLine(res?.told, notify: notify), now().addingTimeInterval(Self.answerLineLife))
            rereadQuestions()
        case 5:
            say(res?.why == "no_question" ? "No such question any more" : "Already answered elsewhere: not sent")
            rereadQuestions()
        case 1 where res?.why == "no_command" || host != nil:
            say(res?.why == "no_command" ? "Answering is off: no answer_command on \(host ?? "this Mac")"
                : "The host's dch cannot answer (too old or --allow-answer off)")
            questions?.answerable = false   // the Answer buttons go until a header says answer:true again
        case 3:
            say("Not answered: " + OutsideText.shown(res?.detail.flatMap { $0.isEmpty ? nil : $0 } ?? "the answer command failed", max: 160))
        case 2: say("Not answered: dch refused the text")
        case 1: say("Not answered: dch found no such session")
        default: say("Not answered: dch did not answer")
        }
    }

    static func toldLine(_ t: XrayAnswerResult.Told?, notify: String) -> String {
        let who = OutsideText.shown(t?.session.flatMap { $0.isEmpty ? nil : $0 } ?? notify, max: 64)
        if t?.ok == true { return "Told \(who)" }
        let why = OutsideText.shown(t?.why.flatMap { $0.isEmpty ? nil : $0 } ?? (t == nil ? "dch said nothing" : "no reason given"), max: 60)
        return "Ruled; \(who) not told (\(why)): it reads the ledger on its next heartbeat"
    }

    /// The re-read after an answer, at once; it moves lastRead, so it stands in for the next 30 s poll (design 3 Cost).
    func rereadQuestions() {
        guard !stopped, questions != nil, let dch, let run else { return }
        cancel()
        readQuestions(dch, run)
    }
}

/// The editor under the Questions rows: the chips, the field, Send and Cancel, and the one status line in its own slot.
/// With the editor closed, a status line (the 6 s "Told") keeps the same slot alone.
struct XrayAnswerEditor: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var panel: XrayPanelModel

    var body: some View {
        if let q = panel.answerQuestion {
            VStack(alignment: .leading, spacing: sz(4)) {
                Text(verbatim: "Answer \(q.id): \(q.title)").font(Neon.font(XrayText.small, weight: .semibold)).lineLimit(1)
                let chips = XrayAnswerChip.of(q)
                if !chips.isEmpty {
                    XrayChipFlow(spacing: sz(4)) {
                        ForEach(chips) { c in XrayAnswerChipView(chip: c) { panel.pick(c) } }
                    }
                }
                TextField("Your ruling", text: $panel.answerText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(Neon.font(XrayText.row))
                    .lineLimit(3, reservesSpace: true)   // a fixed height: typing never moves the line under it
                    .accessibilityLabel("Answer to question \(q.id)")
                HStack(spacing: sz(6)) {
                    status
                    Spacer(minLength: sz(4))
                    Button("Cancel") { panel.cancelAnswer() }
                    Button("Send") { panel.sendAnswer() }.disabled(!panel.canSend)
                }
                .font(Neon.font(XrayText.small, weight: .medium))
            }
            .padding(sz(6))
            .background(RoundedRectangle(cornerRadius: sz(6)).fill(Neon.stroke.opacity(0.35)))
            .padding(.top, sz(4))
        } else if panel.answerLine != nil {
            status.padding(.top, sz(4))
        }
    }

    var status: some View {
        let s = panel.answerStatus
        return Text(verbatim: s ?? " ")
            .font(Neon.font(XrayText.small, weight: .medium)).foregroundStyle(Neon.textSecondary)
            .lineLimit(1).truncationMode(.tail)
            .frame(height: sz(XrayText.rowHeight))   // the fixed slot: a new line never moves a neighbour
            .help(s ?? "")
            .accessibilityLabel(s ?? "")
            .accessibilityHidden(s == nil)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// One suggested answer: 60 visible characters, the whole text in its help tag and accessibility value.
struct XrayAnswerChipView: View {
    let chip: XrayAnswerChip
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: sz(4)) {
                if chip.recommended { Text(verbatim: "Recommended").font(Neon.font(XrayText.small - 1, weight: .semibold)) }
                Text(verbatim: chip.shown).font(Neon.font(XrayText.small, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Neon.textPrimary)
            .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
            .background(Capsule().fill(chip.recommended ? Neon.blue.opacity(0.2) : .clear))
            .overlay(Capsule().stroke(chip.recommended ? Neon.blue.opacity(0.6) : Neon.stroke, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(chip.text)
        .accessibilityLabel(chip.recommended ? "Recommended answer" : "Suggested answer")
        .accessibilityValue(chip.text)
    }
}

/// The chips' one wrapping row: left to right, a new line when the next chip does not fit.
struct XrayChipFlow: Layout {
    var spacing: CGFloat

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(CGPoint, CGSize)] {
        var out: [(CGPoint, CGSize)] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { (x, y, line) = (0, y + line + spacing, 0) }
            out.append((CGPoint(x: x, y: y), s))
            x += s.width + spacing
            line = max(line, s.height)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity, r = rows(w, subviews)
        return CGSize(width: proposal.width ?? r.map { $0.0.x + $0.1.width }.max() ?? 0,
                      height: r.map { $0.0.y + $0.1.height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, p) in zip(subviews, rows(bounds.width, subviews)) {
            v.place(at: CGPoint(x: bounds.minX + p.0.x, y: bounds.minY + p.0.y), proposal: ProposedViewSize(p.1))
        }
    }
}
