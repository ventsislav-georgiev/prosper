import AppKit
import CoreGraphics

/// A pure expansion decision, computed off the typed buffer. Separated from the
/// CGEvent side effects so it is unit-testable without AppKit / a real keyboard.
enum SnippetExpansionDecision: Equatable {
    case none
    /// Plain-text expansion: delete `backspaces`, type `insertText`, then move the
    /// caret left `leftArrows` times (for `{cursor}`).
    case insertPlain(name: String, backspaces: Int, insertText: String, leftArrows: Int)
    /// Rich (RTF) expansion: the executor decodes + resolves the RTF on the main
    /// actor (AppKit), so the plan only carries the snippet + backspace count.
    case insertRich(name: String, backspaces: Int)
    /// #842: the snippet has `{argument}` fields (required or defaulted, nested
    /// ones included): the fill-in panel asks for them. The trigger key is let
    /// through, so the keyword stays typed while it asks; on submit `backspaces`
    /// erases it (plus the delimiter, re-appended as `delimiter`), on cancel it stays.
    case needsArguments(name: String, backspaces: Int, delimiter: String)
}

/// Watches the typed-character stream (fed by the single shared autocomplete
/// CGEvent tap) and performs Alfred/Raycast-style inline snippet expansion:
/// detect a typed keyword, backspace it, and inject the resolved snippet.
///
/// This type owns NO event tap of its own — `AutocompleteEngine.handle` forwards
/// every keystroke here first. Its synthetic events carry the same
/// `syntheticEventMagic` tag the autocomplete engine filters, so neither feature
/// re-enters on the other's injected keystrokes.
@MainActor
final class SnippetExpander {
    static let shared = SnippetExpander()

    /// Must equal `AutocompleteEngine.syntheticEventMagic` so the shared tap skips
    /// the events this expander posts (backspaces / typing / arrows).
    static let syntheticEventMagic: Int64 = 0x50_52_4F_53 // 'PROS'

    private static let kDelete: Int64 = 51
    private static let kLeftArrow: CGKeyCode = 123
    private static let caretMoveKeyCodes: Set<Int64> = [
        36, 76,             // return, keypad-enter
        48,                 // tab
        123, 124, 125, 126, // arrows
        115, 116, 119, 121, // home, page-up, end, page-down
    ]

    /// Printable characters typed since the last caret-moving key (its own rules,
    /// independent of the autocomplete shadow which is tuned for stale-AX).
    private(set) var buffer = ""
    /// #842: a fill-in panel is open. Keys typed into it reach this tap too: they
    /// must neither expand nor ask again, and they leave nothing in the buffer.
    private(set) var prompting = false
    private(set) var cachedKeywords: [(trigger: String, id: String)] = []
    private var cachedToken: Int = -1

    // e2e tracing — gated on PROSPER_E2E, no-op otherwise. The expansion suite runs
    // the app out-of-process; this is its only window into the trigger pipeline.
    private static let e2eTrace = ProcessInfo.processInfo.environment["PROSPER_E2E"] == "1"
    private static func e2elog(_ msg: @autoclosure () -> String) {
        if e2eTrace { FileHandle.standardError.write(Data("[e2e-snippet] \(msg())\n".utf8)) }
    }

    init() {}

    // MARK: - Fill-in seams (#842)

    // Tests swap these: no real panel, focus change, key event or secure-input read.
    var prompt: (_ title: String, _ fields: [ArgumentSpec],
                 _ done: @escaping @MainActor ([String: String]?) -> Void) -> Void = { title, fields, done in
        // Next tick: a typed trigger key is still in the tap and must reach the target first.
        DispatchQueue.main.async { SnippetFillInPanel.shared.present(title: title, fields: fields, done: done) }
    }
    var activateApp: (pid_t) -> Bool = { pid in
        NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
    }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var secureInputActive: () -> Bool = { SecureInput.isActive }
    /// Wait between asking the target app forward and checking it came forward.
    var focusSettle: TimeInterval = 0.15
    /// Performs a decision (backspaces, typing or paste, caret). `arguments` feed a rich body.
    lazy var execute: (SnippetExpansionDecision, [String: String], String?) -> Void = { [unowned self] in
        self.perform($0, arguments: $1, bundleId: $2)
    }

    /// Inline auto-expansion is on: the Snippets extension is live (disabling it in
    /// Settings › Extensions stops expansion, not just its Lua side) and the user's own
    /// toggles allow it. A cached Bool on the registry: this runs on every keyDown.
    /// No registry (tests; the app sets one at launch) = ungated by the extension.
    static var autoExpandActive: Bool {
        (CommandRouter.registry?.snippetsLive ?? true)
            && Preferences.snippetsEnabled && Preferences.snippetsAutoExpand
    }

    // MARK: - Tap hook

    /// Called by `AutocompleteEngine.handle` for every keyDown (before its own
    /// autocomplete logic). Returns true when an expansion fired (the keyword was
    /// erased and the snippet injected).
    func handle(keyCode: Int64, typed: String, controlHeld: Bool,
                optionHeld: Bool, commandHeld: Bool, bundleId: String?) -> Bool {
        Self.e2elog("handle key=\(keyCode) typed=\"\(typed)\" ctrl=\(controlHeld) cmd=\(commandHeld)")
        guard !prompting else { buffer = ""; return false }
        // Modifier chords are never snippet text.
        if controlHeld || commandHeld {
            return false
        }

        var didAppend = false
        if keyCode == Self.kDelete {
            buffer = String(buffer.dropLast())
        } else if Self.caretMoveKeyCodes.contains(keyCode) {
            buffer = ""
            return false
        } else if !typed.isEmpty,
                  typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            buffer += typed
            if buffer.count > 64 { buffer = String(buffer.suffix(64)) }
            didAppend = true
        }

        if didAppend { Self.e2elog("buffer=\"\(buffer.suffix(16))\" key=\(keyCode) bundle=\(bundleId ?? "nil")") }

        // Only a freshly-typed character can complete a keyword.
        guard didAppend else { return false }

        // Gating — independent of autocomplete's per-app denylist.
        guard Self.autoExpandActive else {
            Self.e2elog("bail: snippets disabled (ext=\(CommandRouter.registry?.snippetsLive ?? true) enabled=\(Preferences.snippetsEnabled) auto=\(Preferences.snippetsAutoExpand))")
            return false
        }
        if let bundleId, Preferences.snippetsIgnoredBundleIds.contains(bundleId) {
            Self.e2elog("bail: bundle ignored \(bundleId)"); return false
        }
        guard !SecureInput.isActive else { Self.e2elog("bail: secure input"); return false }

        refreshKeywordsIfNeeded()
        guard !cachedKeywords.isEmpty else { Self.e2elog("bail: no keywords cached"); return false }

        // Match first so the live context can pre-resolve any custom placeholders
        // for the specific snippet that fired (resolution touches the MainActor
        // extension registry; doing it eagerly keeps the pure planner isolation-free).
        guard let match = SnippetMatcher.match(buffer: buffer, keywords: cachedKeywords,
                                               wordBoundaryMode: Preferences.snippetsExpandOnWordBoundary),
              let hit = PhoneSnippetStore.lookup(match.id) else {
            Self.e2elog("no match for buffer=\"\(buffer.suffix(16))\" (\(cachedKeywords.count) keywords)")
            return false
        }
        Self.e2elog("match id=\(match.id) kwLen=\(match.keywordLength) delim=\(match.consumedDelimiter)")

        let context = context(for: hit)
        let decision = Self.plan(
            buffer: buffer,
            keywords: cachedKeywords,
            lookup: { PhoneSnippetStore.lookup($0) },
            context: context,
            wordBoundaryMode: Preferences.snippetsExpandOnWordBoundary
        )
        Self.e2elog("decision=\(decision)")
        return run(decision, hit: hit, context: context, bundleId: bundleId)
    }

    /// Carries out a typed keyword's decision. Returns true when the trigger key is
    /// swallowed (an expansion fired). A fill-in lets it through and asks first.
    func run(_ decision: SnippetExpansionDecision, hit: SnippetHit, context: PlaceholderContext,
             bundleId: String?) -> Bool {
        guard !prompting else { buffer = ""; return false }
        switch decision {
        case .none:
            return false
        case let .needsArguments(_, backspaces, delimiter):
            buffer = ""
            fillIn(hit, fields: Self.fillInFields(hit, snippetByKeyword: context.snippetByKeyword),
                   context: context, target: frontmostPID(), backspaces: backspaces,
                   delimiter: delimiter, bundleId: bundleId)
            return false
        case .insertPlain, .insertRich:
            buffer = ""
            execute(decision, [:], bundleId)
            return true
        }
    }

    // MARK: - Pure planning (unit-tested)

    /// Computes what to do for the current buffer. Pure: no AppKit, no side effects
    /// (rich expansion is deferred to the executor, which needs AppKit RTF decode).
    nonisolated static func plan(buffer: String,
                                 keywords: [(trigger: String, id: String)],
                                 lookup: (String) -> SnippetHit?,
                                 context: PlaceholderContext,
                                 wordBoundaryMode: Bool) -> SnippetExpansionDecision {
        guard let match = SnippetMatcher.match(buffer: buffer, keywords: keywords,
                                               wordBoundaryMode: wordBoundaryMode),
              let hit = lookup(match.id) else { return .none }

        // The trigger key that fired this is SWALLOWED by the tap (still in-flight),
        // so it was never delivered to the field. In immediate mode that final key
        // is the keyword's last char → the field holds `keywordLength - 1` chars. In
        // word-boundary mode the final key is the delimiter (not yet delivered) and
        // the whole keyword is in the field → backspace `keywordLength`.
        let backspaces = match.consumedDelimiter ? match.keywordLength : (match.keywordLength - 1)

        // Re-append the consumed delimiter so the user's word break survives.
        let delimiter = match.consumedDelimiter ? String(buffer.last ?? " ") : ""
        // #732: a Text Replacement types its phrase as written ("{date}" stays), no caret move.
        if hit.literal {
            return .insertPlain(name: hit.name, backspaces: backspaces, insertText: hit.text + delimiter, leftArrows: 0)
        }

        // #842: every field (defaulted too) is asked for unless the context already holds it.
        // The trigger key then goes through, so the field holds one more character.
        if fillInFields(hit, snippetByKeyword: context.snippetByKeyword).contains(where: { context.arguments[$0.name] == nil }) {
            return .needsArguments(name: hit.name, backspaces: backspaces + 1, delimiter: delimiter)
        }
        return expansion(hit, context, backspaces: backspaces, delimiter: delimiter)
    }

    /// The insert for `hit` rendered against `context` (its arguments filled in).
    nonisolated static func expansion(_ hit: SnippetHit, _ context: PlaceholderContext,
                                      backspaces: Int, delimiter: String) -> SnippetExpansionDecision {
        if hit.richText {
            return .insertRich(name: hit.name, backspaces: backspaces)
        }
        let (resolved, cursorOffset) = PlaceholderEngine.render(hit.text, context)
        let insertText = resolved + delimiter
        let leftArrows = cursorOffset.map { insertText.count - $0 } ?? 0
        return .insertPlain(name: hit.name, backspaces: backspaces,
                            insertText: insertText, leftArrows: max(0, leftArrows))
    }

    /// The `{argument}` fields inserting `hit` asks for: `PlaceholderEngine.arguments`
    /// order, de-duplicated by name, nested `{snippet:kw}` ones included. A rich body
    /// is read through its plain projection; a Text Replacement never asks.
    nonisolated static func fillInFields(_ hit: SnippetHit,
                                         snippetByKeyword: (String) -> String?) -> [ArgumentSpec] {
        guard !hit.literal else { return [] }
        let template = hit.richText ? RichSnippet.plainText(rtf: hit.text) : hit.text
        return PlaceholderEngine.arguments(in: template, snippetByKeyword: snippetByKeyword)
    }

    /// `{snippet:key}` lookup: the Mac store by keyword or name, then the phones' sets.
    nonisolated static func snippetLookup(_ snippets: [SnippetHit],
                                          _ phone: [(device: String, set: PhoneSnippetStore.DeviceSet)])
        -> (String) -> String? {
        { key in
            snippets.first { $0.keyword == key || $0.name == key }?.text ?? PhoneSnippetStore.text(forKey: key, in: phone)
        }
    }

    // MARK: - Live placeholder context

    /// The plan's context for `hit`. A Text Replacement inserts literally and plan() never reads
    /// its context, so it gets an empty one: no clipboard-history decrypt per expansion (#733).
    func context(for hit: SnippetHit) -> PlaceholderContext {
        hit.literal ? PlaceholderContext() : liveContext(template: hit.text)
    }

    /// Snapshots the MainActor-isolated state (clipboard history, snippet bodies,
    /// pre-resolved custom placeholders for `template`) into plain values so the
    /// resulting context's closures stay pure — safe to call from the `nonisolated`
    /// planner without touching actor state.
    private func liveContext(template: String) -> PlaceholderContext {
        let clip = Pasteboard.general.string(forType: .string)
        let history: [String] = ClipboardStore.shared.items
            .filter { $0.kind.isTextual }
            .compactMap { ClipboardStore.shared.text(for: $0) ?? $0.preview }
        let snippets = SnippetStore.all(), phone = PhoneSnippetStore.live.sets()
        // Pre-resolve extension-contributed placeholders this template uses, keyed
        // by raw token body (what PlaceholderEngine passes to `custom`).
        var customs: [String: String] = [:]
        if let registry = CommandRouter.registry {
            for token in PlaceholderEngine.customTokens(in: template) {
                if let value = registry.resolvePlaceholder(name: token.name, raw: token.raw) {
                    customs[token.raw] = value
                }
            }
        }
        var ctx = PlaceholderContext()
        ctx.clipboard = { clip }
        ctx.clipboardHistory = { n in (n >= 0 && n < history.count) ? history[n] : nil }
        ctx.snippetByKeyword = Self.snippetLookup(snippets, phone)
        ctx.custom = { _, raw in customs[raw] }
        return ctx
    }

    func refreshKeywordsIfNeeded() {
        TextReplacements.refreshIfStale()   // #733: a change bumps the token, so before the guard
        guard cachedToken != SnippetStore.changeToken else { return }
        TextReplacements.refresh()   // #732: re-read with every rebuild (a change bumps the token again)
        cachedKeywords = SnippetStore.effectiveKeywords()
        cachedToken = SnippetStore.changeToken
    }

    // MARK: - Direct insertion (bound hotkey, sn palette: no typed keyword)

    /// Inserts a snippet by name with no buffer to backspace — used by a bound
    /// Shortcuts hotkey (`ExtensionShortcuts.fire`) rather than typed keyword
    /// auto-expansion. The frontmost app is the target.
    func insertByName(_ name: String, bundleId: String?) {
        guard let hit = SnippetStore.byName(name) else { return }
        insert(hit, context: context(for: hit), target: frontmostPID(), bundleId: bundleId)
    }

    /// The hotkey's and the `sn` palette's way in: asks for `hit`'s fields first
    /// (then inserts into `target`), else inserts at once.
    func insert(_ hit: SnippetHit, context: PlaceholderContext, target: pid_t?, bundleId: String?) {
        let fields = Self.fillInFields(hit, snippetByKeyword: context.snippetByKeyword)
        guard fields.isEmpty else {
            fillIn(hit, fields: fields, context: context, target: target, backspaces: 0,
                   delimiter: "", bundleId: bundleId)
            return
        }
        execute(Self.expansion(hit, context, backspaces: 0, delimiter: ""), [:], bundleId)
    }

    // MARK: - Fill-in (#842: collect, then insert)

    /// Row action id the `sn` palette puts on a snippet that asks for arguments;
    /// the runner handles it natively (`RunnerPanel.performFileAction`).
    nonisolated static let fillInActionID = "snippets.fill"

    /// Asks for `fields`, then returns focus to `target` and inserts there, erasing
    /// `backspaces` typed characters first. Shared by all three paths. Cancel returns
    /// focus and inserts nothing (a typed keyword stays as typed); a target that is gone
    /// or not frontmost once focus returned gets nothing either. Never asks inside a
    /// secure input field, nor while another fill-in is open.
    func fillIn(_ hit: SnippetHit, fields: [ArgumentSpec], context: PlaceholderContext,
                target: pid_t?, backspaces: Int, delimiter: String, bundleId: String?) {
        guard !prompting, !secureInputActive() else { return }
        prompting = true
        prompt(Self.displayName(hit.name), fields) { [weak self] values in
            guard let self else { return }
            self.prompting = false
            self.buffer = ""
            guard let target else { return }
            // Cancel: focus goes back, the keyword stays as typed, nothing is inserted.
            guard let values else { _ = self.activateApp(target); return }
            var ctx = context
            ctx.arguments = values
            let decision = Self.expansion(hit, ctx, backspaces: backspaces, delimiter: delimiter)
            guard self.activateApp(target) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.focusSettle) {
                // Another app came forward meanwhile: its field is not the one the keyword was typed in.
                guard self.frontmostPID() == target else { return }
                self.execute(decision, values, bundleId)
            }
        }
    }

    /// A phone snippet's name is its namespaced id; the panel shows the snippet's own name.
    nonisolated static func displayName(_ name: String) -> String {
        name.split(separator: "\u{1}").last.map(String.init) ?? name
    }

    private func perform(_ decision: SnippetExpansionDecision, arguments: [String: String], bundleId: String?) {
        switch decision {
        case let .insertPlain(_, backspaces, insertText, leftArrows):
            Self.e2elog("fire plain backspaces=\(backspaces) insert=\"\(insertText)\" compat=\(Preferences.usesCompatInsertion(forBundleId: bundleId))")
            sendBackspaces(backspaces)
            insert(insertText, bundleId: bundleId)
            sendLeftArrows(leftArrows)
        case let .insertRich(name, backspaces):
            executeRich(name: name, backspaces: backspaces, bundleId: bundleId, arguments: arguments)
        case .none, .needsArguments:
            break
        }
    }

    // MARK: - Rich (RTF) execution

    private func executeRich(name: String, backspaces: Int, bundleId: String?, arguments: [String: String]) {
        guard let hit = SnippetStore.byName(name) else { return }
        // Discover/pre-resolve placeholders against the decoded plain projection
        // (tokens are brace-escaped in the RTF source itself).
        let plain = RichSnippet.plainText(rtf: hit.text)
        var context = liveContext(template: plain)
        context.arguments = arguments
        guard let resolved = RichSnippet.resolve(rtf: hit.text, context: context) else {
            return
        }
        sendBackspaces(backspaces)
        pasteRich(rtf: resolved.rtfData, plain: resolved.plain)
        sendLeftArrows(resolved.cursorOffsetFromEnd)
    }

    // MARK: - Synthetic keyboard / pasteboard

    private func insert(_ string: String, bundleId: String?) {
        if Preferences.usesCompatInsertion(forBundleId: bundleId) {
            pasteString(string)
        } else {
            typeString(string)
        }
    }

    private func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKey: CGKeyCode = 51
        for _ in 0..<count {
            postKey(source: source, key: deleteKey)
        }
    }

    private func sendLeftArrows(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            postKey(source: source, key: Self.kLeftArrow)
        }
    }

    private func postKey(source: CGEventSource?, key: CGKeyCode) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
            up.post(tap: .cgSessionEventTap)
        }
    }

    private func typeString(_ string: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(string.utf16)
        guard !utf16.isEmpty,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
        keyDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
        keyUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }

    private func pasteString(_ string: String) {
        let pb = Pasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(string, forType: .string)
        postCmdV()
        restoreClipboard(previousString: previous, previousRTF: nil)
    }

    private func pasteRich(rtf: Data, plain: String) {
        let pb = Pasteboard.general
        let previousString = pb.string(forType: .string)
        let previousRTF = pb.data(forType: .rtf)
        pb.clearContents()
        // Both RTF and a plain fallback, so non-rich targets still receive text.
        pb.setData(rtf, forType: .rtf)
        pb.setString(plain, forType: .string)
        postCmdV()
        restoreClipboard(previousString: previousString, previousRTF: previousRTF)
    }

    private func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    private func restoreClipboard(previousString: String?, previousRTF: Data?) {
        guard Preferences.snippetsRestoreClipboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let pb = Pasteboard.general
            pb.clearContents()
            if let previousRTF { pb.setData(previousRTF, forType: .rtf) }
            if let previousString { pb.setString(previousString, forType: .string) }
        }
    }
}
