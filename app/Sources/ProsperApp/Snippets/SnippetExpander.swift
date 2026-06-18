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
    /// The snippet needs `{argument}` input that inline expansion can't collect;
    /// the buffer is left intact so the palette path can handle it.
    case needsArguments(name: String)
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
    private var buffer = ""
    private var cachedKeywords: [(trigger: String, id: String)] = []
    private var cachedToken: Int = -1

    // e2e tracing — gated on PROSPER_E2E, no-op otherwise. The expansion suite runs
    // the app out-of-process; this is its only window into the trigger pipeline.
    private static let e2eTrace = ProcessInfo.processInfo.environment["PROSPER_E2E"] == "1"
    private static func e2elog(_ msg: @autoclosure () -> String) {
        if e2eTrace { FileHandle.standardError.write(Data("[e2e-snippet] \(msg())\n".utf8)) }
    }

    private init() {}

    // MARK: - Tap hook

    /// Called by `AutocompleteEngine.handle` for every keyDown (before its own
    /// autocomplete logic). Returns true when an expansion fired (the keyword was
    /// erased and the snippet injected).
    func handle(keyCode: Int64, typed: String, controlHeld: Bool,
                optionHeld: Bool, commandHeld: Bool, bundleId: String?) -> Bool {
        Self.e2elog("handle key=\(keyCode) typed=\"\(typed)\" ctrl=\(controlHeld) cmd=\(commandHeld)")
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
        guard Preferences.snippetsEnabled, Preferences.snippetsAutoExpand else {
            Self.e2elog("bail: snippets disabled (enabled=\(Preferences.snippetsEnabled) auto=\(Preferences.snippetsAutoExpand))")
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
              let hit = SnippetStore.byName(match.id) else {
            Self.e2elog("no match for buffer=\"\(buffer.suffix(16))\" (\(cachedKeywords.count) keywords)")
            return false
        }
        Self.e2elog("match id=\(match.id) kwLen=\(match.keywordLength) delim=\(match.consumedDelimiter)")

        let decision = Self.plan(
            buffer: buffer,
            keywords: cachedKeywords,
            lookup: { SnippetStore.byName($0) },
            context: liveContext(template: hit.text),
            wordBoundaryMode: Preferences.snippetsExpandOnWordBoundary
        )

        switch decision {
        case .none, .needsArguments:
            Self.e2elog("decision=\(decision) → no fire")
            return false
        case let .insertPlain(_, backspaces, insertText, leftArrows):
            Self.e2elog("fire plain backspaces=\(backspaces) insert=\"\(insertText)\" compat=\(Preferences.usesCompatInsertion(forBundleId: bundleId))")
            buffer = ""
            sendBackspaces(backspaces)
            insert(insertText, bundleId: bundleId)
            sendLeftArrows(leftArrows)
            return true
        case let .insertRich(name, backspaces):
            buffer = ""
            executeRich(name: name, backspaces: backspaces, bundleId: bundleId)
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

        if hit.richText {
            return .insertRich(name: hit.name, backspaces: backspaces)
        }

        // A required (default-less) argument can't be collected inline.
        let needsArg = PlaceholderEngine.arguments(in: hit.text).contains {
            $0.required && context.arguments[$0.name] == nil
        }
        if needsArg { return .needsArguments(name: hit.name) }

        // Re-append the consumed delimiter so the user's word break survives.
        let delimiter = match.consumedDelimiter ? String(buffer.last ?? " ") : ""
        let (resolved, cursorOffset) = PlaceholderEngine.render(hit.text, context)
        let insertText = resolved + delimiter
        let leftArrows = cursorOffset.map { insertText.count - $0 } ?? 0
        return .insertPlain(name: hit.name, backspaces: backspaces,
                            insertText: insertText, leftArrows: max(0, leftArrows))
    }

    // MARK: - Live placeholder context

    /// Snapshots the MainActor-isolated state (clipboard history, snippet bodies,
    /// pre-resolved custom placeholders for `template`) into plain values so the
    /// resulting context's closures stay pure — safe to call from the `nonisolated`
    /// planner without touching actor state.
    private func liveContext(template: String) -> PlaceholderContext {
        let clip = NSPasteboard.general.string(forType: .string)
        let history: [String] = ClipboardStore.shared.items
            .filter { $0.kind.isTextual }
            .compactMap { ClipboardStore.shared.text(for: $0) ?? $0.preview }
        let snippets = SnippetStore.all()
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
        ctx.snippetByKeyword = { key in
            snippets.first { $0.keyword == key || $0.name == key }?.text
        }
        ctx.custom = { _, raw in customs[raw] }
        return ctx
    }

    private func refreshKeywordsIfNeeded() {
        guard cachedToken != SnippetStore.changeToken else { return }
        cachedKeywords = SnippetStore.effectiveKeywords()
        cachedToken = SnippetStore.changeToken
    }

    // MARK: - Rich (RTF) execution

    private func executeRich(name: String, backspaces: Int, bundleId: String?) {
        guard let hit = SnippetStore.byName(name) else { return }
        // Discover/pre-resolve placeholders against the decoded plain projection
        // (tokens are brace-escaped in the RTF source itself).
        let plain = RichSnippet.plainText(rtf: hit.text)
        guard let resolved = RichSnippet.resolve(rtf: hit.text, context: liveContext(template: plain)) else {
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
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(string, forType: .string)
        postCmdV()
        restoreClipboard(previousString: previous, previousRTF: nil)
    }

    private func pasteRich(rtf: Data, plain: String) {
        let pb = NSPasteboard.general
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
            let pb = NSPasteboard.general
            pb.clearContents()
            if let previousRTF { pb.setData(previousRTF, forType: .rtf) }
            if let previousString { pb.setString(previousString, forType: .string) }
        }
    }
}
