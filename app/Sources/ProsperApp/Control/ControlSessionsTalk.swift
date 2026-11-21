import Foundation

/// #1839: talk to a running session over the control channel: sessions.say (the window composer's send),
/// sessions.interrupt (its Esc) and sessions.prompt (the question a blocked session waits on). Say and interrupt take
/// the window's own path: its list-state check, its row lock and not-in-front refusals, then the controller's
/// human-click path (humanAction) with the window's driver, whose screen read refuses over a prompt. Answering a
/// prompt stays human-only: nothing here sends a digit or a key to one. Work runs on demand only: no observer, no poll.
@MainActor
enum ControlSessionsTalk {
    /// The controller's human-click path (AgentIslandController.humanAction); false: the session is held, nothing ran.
    static var act: @MainActor (AgentSession, @escaping @Sendable (AgentPromptIO) -> AgentWindowOutcome,
                                @escaping @MainActor @Sendable (AgentWindowOutcome) -> Void) -> Bool = { s, run, done in
        AgentIslandController.shared.humanAction(s, prompt: nil, run: run, done: done)
    }
    /// One screen read off main (dch --read through the island's IO), its text handed back on main.
    static var read: @MainActor (AgentSessionKey, @escaping @MainActor @Sendable (String) -> Void) -> Void = { key, done in
        let io = AgentIslandController.shared.io
        DispatchQueue.global(qos: .userInitiated).async {
            let text = io.read(key)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text) } }
        }
    }

    /// A message's cap: the island composer's (AgentIsland.messageCap, UTF-8 bytes).
    static let maxBytes = AgentIsland.messageCap
    /// A prompt line in a reply: at most this many characters (OutsideText.shown).
    static let maxLine = 2000

    /// sessions.prompt's screen reads: the read for a session while its activity is unchanged; `reading` while one runs.
    private(set) static var screens: [AgentSessionKey: (activity: TimeInterval, text: String)] = [:]
    private(set) static var reading: Set<AgentSessionKey> = []

    // MARK: - sessions.say

    /// An agent string with a control or unseen scalar (OutsideText.isUnseen) other than `allowing`.
    static func hasUnseen(_ raw: String, allowing: Set<Unicode.Scalar> = []) -> Bool {
        raw.unicodeScalars.contains { !allowing.contains($0) && OutsideText.isUnseen($0) }
    }

    /// Text from an agent is outside text: over the cap, or with a control character other than LF and tab (CR, ESC,
    /// DEL, C1) or another unseen scalar, or starting with / or !, it is refused whole, never cleaned and sent; then
    /// the driver's own `message` trims it. `key` names the argument (say's text; sessions.new's prompt; sessions.resume's message).
    static func text(_ args: [String: ControlJSON], key: String = "text") throws -> String {
        guard case .string(let raw)? = args[key] else { throw ControlError("argument '\(key)' is empty") }
        guard raw.utf8.count <= maxBytes else { throw ControlError("\(key) is longer than \(maxBytes) bytes") }
        if hasUnseen(raw, allowing: ["\n", "\t"]) {
            throw ControlError("\(key) has a control or hidden character: only line breaks (LF) and tabs are allowed")
        }
        // A leading / or ! would run a slash command or shell mode in the target: those stay with the person.
        if let first = raw.unicodeScalars.first(where: { !$0.properties.isWhitespace }), first == "/" || first == "!" {
            throw ControlError("a message cannot start with / or !: slash commands and shell mode stay with the person")
        }
        guard let t = AgentWindowDriver.message(raw) else { throw ControlError("argument '\(key)' is empty") }
        return t
    }

    /// The window's refusals before an action (AgentWindowModel.act): the row's running text, Claude not in front.
    static func refusal(_ s: AgentSession, in st: AgentIslandStore) -> String? {
        if let lock = AgentWindowControls.lock(st.actions[s.key]) { return AgentWindowControls.lockPlaceholder(lock) }
        return s.claudeForeground == false ? AgentWindowText.notForeground : nil
    }

    /// The composer's send: only while the list says idle or done (a blocked session's prompt is never typed into).
    /// The reply is the start; a failure the driver finds later (a prompt came up, nothing confirmed) shows as a notice.
    static func say(_ args: [String: ControlJSON], changes: ControlChanges) throws -> ControlChange {
        let st = try ControlSessions.store(), s = try ControlSessions.session(try ControlSessions.required(args, "name"), in: st)
        let message = try text(args)
        guard s.state == .idle || s.state == .done else {
            throw ControlError(s.state == .blocked ? AgentWindowText.blocked : AgentWindowText.working)
        }
        let key = s.key
        try start(s, in: st, changes: changes, what: "message") { AgentWindowDriver(key: key, io: $0).send(message) }
        return ControlChange(summary: "\(s.title): \(message)", result: .string(s.name), verb: "messaged")
    }

    // MARK: - sessions.interrupt

    /// The window's Esc: only while the list says working; the driver presses it only with no prompt on screen.
    static func interrupt(_ args: [String: ControlJSON], changes: ControlChanges) throws -> ControlChange {
        let st = try ControlSessions.store(), s = try ControlSessions.session(try ControlSessions.required(args, "name"), in: st)
        guard s.state == .working else { throw ControlError(AgentWindowText.notWorking) }
        let key = s.key
        try start(s, in: st, changes: changes, what: "interrupt") { AgentWindowDriver(key: key, io: $0).interrupt() }
        return ControlChange(summary: s.title, result: .string(s.name), verb: "interrupted")
    }

    private static func start(_ s: AgentSession, in st: AgentIslandStore, changes: ControlChanges, what: String,
                              run: @escaping @Sendable (AgentPromptIO) -> AgentWindowOutcome) throws {
        if let why = refusal(s, in: st) { throw ControlError(why) }
        let title = s.title
        let ok = act(s, run) { r in
            if case .failed(let why) = r { changes.present("Agent's \(what) to \(OutsideText.shown(title, max: 60)) failed: \(OutsideText.shown(why, max: 200))", nil) }
        }
        guard ok else { throw ControlError(AgentWindowText.busy) }
    }

    // MARK: - sessions.prompt

    /// {name, state, waiting, reading, question, context, options, lines}. Not blocked: waiting false. Blocked: the
    /// island's card when it has one, else a screen read for this session's current activity; with none yet one read
    /// starts off main and the reply says reading (ask again). Every screen string is outside text (OutsideText.shown).
    static func prompt(_ args: [String: ControlJSON]) throws -> ControlJSON {
        let st = try ControlSessions.store(), s = try ControlSessions.session(try ControlSessions.required(args, "name"), in: st)
        let live = Set(st.sessions.map(\.key))
        screens = screens.filter { live.contains($0.key) }
        var out: [String: ControlJSON] = ["name": .string(s.name), "state": .string(s.state.label), "waiting": .bool(false),
                                          "reading": .bool(false)]
        guard s.state == .blocked else { screens[s.key] = nil; return .object(out) }
        out["waiting"] = .bool(true)
        switch st.cards[s.key] {
        case .prompt(let p)?: return .object(out.merging(describe(p)) { $1 })
        case .context(let lines)?: return .object(out.merging(["lines": shown(lines)]) { $1 })
        case .changed?, nil: break
        }
        if let cached = screens[s.key], cached.activity == s.activity {
            if let p = AgentPrompt.screen(cached.text)?.prompt { return .object(out.merging(describe(p)) { $1 }) }
            return .object(out.merging(["lines": shown(AgentPrompt.tail(cached.text))]) { $1 })
        }
        out["reading"] = .bool(true)
        let key = s.key, activity = s.activity
        if reading.insert(key).inserted {
            read(key) { text in
                reading.remove(key)
                // An empty read (dch timed out) tells nothing: the next call reads again.
                if !text.isEmpty { screens[key] = (activity, text) }
            }
        }
        return .object(out)
    }

    static func describe(_ p: AgentPrompt) -> [String: ControlJSON] {
        ["question": .string(OutsideText.shown(p.question, max: maxLine)), "context": shown(p.context),
         "options": .array(p.options.map { o in
             .object(["digit": .number(Double(o.digit)), "label": .string(OutsideText.shown(o.label, max: maxLine)),
                      "detail": shown(o.detail)])
         }),
         "hidden": .bool(p.hasHiddenCharacters)]
    }

    static func shown(_ lines: [String]) -> ControlJSON { .array(lines.map { .string(OutsideText.shown($0, max: maxLine)) }) }
}

extension ControlRegistry {
    /// #1839: wired in ControlRegistry.standard().
    static func registerSessionsTalk(_ r: inout ControlRegistry) {
        let name = ControlArg(type: "string", required: true, summary: "the session's dch name or shown title")
        r.register(.change(name: "sessions.say", summary: "Send a message to an idle session, as its composer does (no undo).", args: [
            "name": name,
            "text": ControlArg(type: "string", required: true, summary: "the message; line breaks and tabs allowed, no other control characters"),
        ]) { reg, a in try ControlSessionsTalk.say(a, changes: reg.changes) })
        r.register(.change(name: "sessions.interrupt", summary: "Press Esc in a working session, as its Interrupt does (no undo).",
                           args: ["name": name]) { reg, a in try ControlSessionsTalk.interrupt(a, changes: reg.changes) })
        r.register(ControlCommand(name: "sessions.prompt",
                                  summary: "The question a blocked session waits on: question, context, options. Read only: answering stays with the person.",
                                  args: ["name": name], mutates: false) { _, a in try ControlSessionsTalk.prompt(a) })
    }
}
