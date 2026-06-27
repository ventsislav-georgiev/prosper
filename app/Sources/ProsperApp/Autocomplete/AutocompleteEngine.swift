import AppKit
import CoreGraphics

/// Orchestrates inline autocomplete: a CGEventTap watches keystrokes, debounces,
/// reads caret context via AX, requests a completion, and renders a ghost
/// suggestion. Tab accepts one word at a time; RightArrow accepts the whole
/// suggestion (the key is swallowed in both cases).
///
/// The event tap is added to the main run loop, so its callback fires on the
/// main thread; the engine is `@MainActor`-isolated accordingly.
@MainActor
final class AutocompleteEngine {

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activationObserver: NSObjectProtocol?

    private let suggestionWindow = SuggestionWindow()
    private let mirrorWindow = MirrorOverlayWindow()
    private let accessoryButton = AccessoryButton()
    private var debounceTimer: Timer?

    /// Invoked when the floating accessory button is clicked (set by AppDelegate).
    var onAccessoryClicked: (() -> Void)? {
        get { accessoryButton.onClick }
        set { accessoryButton.onClick = newValue }
    }

    // Current suggestion state (main thread only).
    private var currentSuggestion: String?
    private var currentCaretRect: CGRect?
    private var currentFieldRect: CGRect?
    // When > 0, accepting first deletes this many trailing chars (an emoji
    // `:shortcode` trigger, or a misspelled word being replaced by a fix).
    private var replaceLength: Int = 0
    // True when the current suggestion is a typo fix (rendered struck-through).
    private var isFix: Bool = false
    // Bundle id captured when the suggestion was requested (for per-app rules).
    private var requestBundleId: String?
    // WS6: text before the caret captured when an LLM suggestion was requested,
    // used as the `prompt` of the recorded (prompt, completion) training pair.
    // nil for non-LLM suggestions (emoji shortcodes, typo fixes), which are not
    // recorded as LoRA training samples.
    private var requestBefore: String?

    // WS6 A/B: true once the currently-shown LLM completion has been counted as
    // accepted, so word-by-word accepts (and re-renders) don't double-count it.
    // Reset to false each time a fresh completion is shown.
    private var abAcceptedForCurrent = false

    // Single-flight token: increments on each new request; stale results ignored.
    private var requestToken: UInt64 = 0

    // Backing task of the in-flight completion request. Cancelled on every new
    // keystroke so a superseded generation stops prefill/decode immediately
    // instead of running to completion on the serialized MLX actor.
    private var completionTask: Task<Void, Never>?

    /// Shadow of the printable characters typed since the last caret-moving
    /// event (click, arrow/Tab/Return, app switch). Electron apps (Slack) update
    /// their AX value lazily, so a text read taken right after typing can MISS
    /// the trailing chars we watched the user type — a prompt built from that
    /// stale text produces a suggestion that duplicates them. The AX text is
    /// only trusted when it ends with this shadow. Synthetic inserts (accepts)
    /// append to it; synthetic backspaces shrink it.
    private var typedShadow = ""
    private var staleAXRetries = 0
    /// Keys that move the caret or focus — the shadow no longer describes the
    /// text at the caret after one of these.
    private static let caretMoveKeyCodes: Set<Int64> = [
        36, 76,             // return, keypad-enter
        48,                 // tab
        123, 124, 125, 126, // arrows
        115, 116, 119, 121, // home, page-up, end, page-down
    ]
    private static let kDelete: Int64 = 51

    // Adaptive debounce (P1.1). Starts at 120ms — short enough to feel immediate,
    // long enough to coalesce a fast burst — then tracks the model's measured
    // round-trip latency (EMA, success samples only) clamped to [min,max]: a slow
    // model debounces longer so we stop spamming it; a fast one stays snappy.
    // Type-through absorbs most mid-suggestion keystrokes, so the debounce only
    // gates fresh requests.
    private var debounceInterval: TimeInterval = 0.12
    private var latencyEMA: TimeInterval = 0.12
    nonisolated static let debounceMin: TimeInterval = 0.08
    nonisolated static let debounceMax: TimeInterval = 0.6
    private func updateDebounce(_ elapsed: TimeInterval) {
        let next = Self.nextDebounce(ema: latencyEMA, elapsed: elapsed)
        latencyEMA = next.ema
        debounceInterval = next.interval
    }

    /// Pure debounce step (P1.1) — `nonisolated static` so the clamp/bounds are
    /// unit-testable off the actor. EMA tracks measured round-trip latency; the
    /// interval is 0.6× the EMA clamped to `[debounceMin, debounceMax]`. The
    /// sample is capped at 1s: a cold model load is folded into the first
    /// request's elapsed time (P0.4) and an empty-ladder reprompt can run long —
    /// either would otherwise pin the EMA at `debounceMax` for the session.
    nonisolated static func nextDebounce(
        ema: TimeInterval, elapsed: TimeInterval
    ) -> (ema: TimeInterval, interval: TimeInterval) {
        let sample = min(elapsed, 1.0)
        let newEMA = ema * 0.7 + sample * 0.3
        let interval = min(max(newEMA * 0.6, debounceMin), debounceMax)
        return (newEMA, interval)
    }

    /// Diagnostics (P2.1): why a keystroke produced no ghost. VSCode tags every
    /// non-show with a reason; we do the same so "sometimes nothing shows" is
    /// traceable. Counts are surfaced through the e2e log (gated) and queryable
    /// in tests via `noShowCounts`.
    enum NoShowReason: String, CaseIterable {
        case frontmostSelf, suppressesCompletion, domainDisabled, noCaret
        case escSuppressed, addressBar, textBeforeEmpty, staleAX, midlineDisabled
        case secureInput, suppressOnTypo, staleResponseToken, staleNoContext
        case diverged, midWord, modelEmpty, agentPaused, acceptDiverged
    }
    private(set) var noShowCounts: [NoShowReason: Int] = [:]
    private func recordNoShow(_ reason: NoShowReason) {
        noShowCounts[reason, default: 0] += 1
        Self.e2elog("no-show: \(reason.rawValue) [\(noShowCounts[reason]!)]")
    }

    // Keycodes.
    private static let kTab: Int64 = 48
    private static let kRightArrow: Int64 = 124 // kVK_RightArrow (123 is Left!)
    private static let kEscape: Int64 = 53
    private static let kBacktick: Int64 = 50 // kVK_ANSI_Grave — Ctrl+` force-activate
    private static let kPeriod: Int64 = 47 // kVK_ANSI_Period — ⌥. retrigger

    // e2e tracing — gated on PROSPER_E2E, no-op otherwise. Lets the out-of-process
    // autocomplete suite see WHERE the request pipeline bails (the app runs in a
    // separate process, so a breakpoint/print is the only window into it).
    private static let e2eTrace = ProcessInfo.processInfo.environment["PROSPER_E2E"] == "1"
    private static func e2elog(_ msg: @autoclosure () -> String) {
        // Two sinks, one message: the PROSPER_E2E stderr stream the e2e harness
        // scrapes for `[e2e-engine]` markers, and the user-facing verbose trace
        // (About → Troubleshooting). The latter lets a user reproduce "sometimes
        // no ghost" and hand back the no-show reason that fired — the whole
        // diagnosability point of P2.1. Built once, only when a sink is live.
        guard e2eTrace || TraceLog.on else { return }
        let s = msg()
        if e2eTrace { FileHandle.standardError.write(Data("[e2e-engine] \(s)\n".utf8)) }
        TraceLog.emit("autocomplete: \(s)")
    }

    // Esc pressed with a live suggestion: suppress completions in THIS field until
    // focus moves elsewhere (Cotypist's Esc semantics — "not here, not now").
    // Keyed on the field rect (fuzzy-compared); cleared on app switch or when a
    // different field produces a context.
    private var escSuppressedFieldRect: CGRect?
    // Ctrl+` pressed: override the idle heuristics (small field / too little
    // context) for THIS field until focus moves elsewhere.
    private var forceActivatedFieldRect: CGRect?
    // Text before the caret at the time the current suggestion was rendered.
    // Drives type-through: the next keystroke's expected prefix comes from here
    // without an AX read on the hot path.
    private var lastRenderedBefore: String?

    // Stamped onto the `.eventSourceUserData` field of every CGEvent we synthesize
    // (accept insertion / backspaces). The tap callback ignores events carrying it
    // so our own typing never re-enters the engine — which would otherwise clear
    // the just-re-rendered word-accept remainder (Tab would make it vanish).
    private static let syntheticEventMagic: Int64 = 0x50_52_4F_53 // 'PROS'

    private(set) var isRunning = false

    // MARK: - Lifecycle

    /// Starts the engine. Returns false if Accessibility is not trusted or the
    /// event tap cannot be created; degrades gracefully (no crash).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        guard PermissionsManager.isAccessibilityTrusted() else {
            NSLog("prosper: autocomplete not started — Accessibility not trusted")
            return false
        }

        // systemDefined (14) carries media/aux keys (PLAY, SOUND_UP, …). We watch it
        // so user shortcut rules can remap/swallow INCOMING media keys; with no media
        // rule registered the callback returns the event untouched (volume HUD intact).
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << 14 /* NX_SYSDEFINED / CGEventType.systemDefined */)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                // Skip events we synthesized ourselves (accept insertion / backspaces)
                // so they don't clear the live suggestion or trigger a fresh request.
                if event.getIntegerValueField(.eventSourceUserData) == AutocompleteEngine.syntheticEventMagic {
                    return Unmanaged.passUnretained(event)
                }
                let engine = Unmanaged<AutocompleteEngine>.fromOpaque(userInfo).takeUnretainedValue()
                // Left click: the focus/caret is about to move, so the ghost and
                // the accessory indicator are stale — hide them NOW instead of
                // letting them linger until the next keystroke. Never swallowed.
                if type == .leftMouseDown {
                    MainActor.assumeIsolated { engine.handleMouseDown() }
                    return Unmanaged.passUnretained(event)
                }
                // systemDefined (14): incoming media/aux key. Decode NX_KEYTYPE from
                // the NSEvent and let user rules remap/swallow it. Untouched (passed
                // through) unless a media rule matches — keeps the system volume HUD
                // and playback working by default.
                if type.rawValue == 14 {
                    guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                        return Unmanaged.passUnretained(event)
                    }
                    let data1 = ns.data1
                    let mediaCode = (data1 & 0xFFFF0000) >> 16
                    let down = ((data1 & 0xFF00) >> 8) == 0xA
                    let flags = event.flags
                    let swallow = MainActor.assumeIsolated {
                        engine.handleMediaEvent(
                            code: mediaCode, down: down,
                            cmd: flags.contains(.maskCommand), alt: flags.contains(.maskAlternate),
                            ctrl: flags.contains(.maskControl), shift: flags.contains(.maskShift),
                            fn: flags.contains(.maskSecondaryFn))
                    }
                    return swallow ? nil : Unmanaged.passUnretained(event)
                }
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                // OS key-autorepeat flag (held key). Double-tap rules must ignore
                // these so a repeat doesn't masquerade as the second press.
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let optionHeld = event.flags.contains(.maskAlternate)
                let controlHeld = event.flags.contains(.maskControl)
                let commandHeld = event.flags.contains(.maskCommand)
                let shiftHeld = event.flags.contains(.maskShift)
                let fnHeld = event.flags.contains(.maskSecondaryFn)
                // The typed character(s), for type-through matching against the
                // live ghost. Empty for non-printing keys.
                var typed = ""
                if type == .keyDown, !controlHeld, !commandHeld {
                    var length = 0
                    var buffer = [UniChar](repeating: 0, count: 8)
                    event.keyboardGetUnicodeString(
                        maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer
                    )
                    if length > 0 {
                        typed = String(utf16CodeUnits: buffer, count: length)
                    }
                }
                // The tap is installed on the main run loop, so this fires on the
                // main thread; safe to assume MainActor isolation. We pass only
                // Sendable scalars across the boundary and return a swallow flag.
                let swallow = MainActor.assumeIsolated {
                    engine.handle(
                        type: type, keyCode: keyCode, optionHeld: optionHeld,
                        controlHeld: controlHeld, commandHeld: commandHeld,
                        shiftHeld: shiftHeld, fnHeld: fnHeld, typed: typed,
                        isRepeat: isRepeat
                    )
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            NSLog("prosper: failed to create event tap for autocomplete")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("prosper: keystroke tap started (autocomplete=%d extRules=%d)",
              Preferences.autocompleteEnabled, !ExtensionKeyRules.shared.isEmpty)

        // Dismiss the indicator/ghost whenever the frontmost app changes. The
        // overlays are pinned to a text field in another process; once that app
        // is no longer focused they would otherwise float over unrelated UI (or
        // over Prosper's own windows). Any activation change tears them down —
        // the next keystroke in a real field re-creates them.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Per-field Esc suppression and Ctrl+` force-activation are scoped
                // to the focused field; an app switch invalidates both.
                self?.escSuppressedFieldRect = nil
                self?.forceActivatedFieldRect = nil
                self?.typedShadow = ""
                self?.dismissOverlays()
            }
        }

        isRunning = true
        return true
    }

    /// Left mouse click anywhere on screen: the click is about to move focus or
    /// the caret, so the ghost and the accessory indicator are stale. Hide them
    /// immediately — the next keystroke in a text field re-creates both. Clicks
    /// on the accessory button itself are exempt (the button must receive its
    /// action, which re-triggers a suggestion anyway).
    func handleMouseDown() {
        typedShadow = "" // the click moves the caret/focus, regardless of the pref
        guard Preferences.dismissOverlaysOnClick else { return }
        if accessoryButton.isVisible,
           accessoryButton.screenFrame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) {
            return
        }
        dismissOverlays()
    }

    /// Hides the ghost suggestion and the leading indicator, clearing state. Also
    /// drops cached screen context so the next field's completion captures fresh
    /// surroundings rather than reusing the previous app's OCR/color.
    private func dismissOverlays() {
        // TODO WS6: this fires for many non-reject reasons (focus change, new
        // keystroke superseding a request, app switch), so there is no clean
        // "user rejected this suggestion" signal here. Recording every dismissal
        // as a rejected sample would poison the A/B accounting, so we deliberately
        // record only accepted pairs (at the accept sites) for now.
        clearSuggestion()
        accessoryButton.hide()
        ScreenContextCache.shared.invalidate()
    }

    func stop() {
        guard isRunning else { return }
        debounceTimer?.invalidate()
        debounceTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        clearSuggestion()
        accessoryButton.hide()
        ScreenContextCache.shared.invalidate() // drop cached OCR text + sampled color
        isRunning = false
        NSLog("prosper: keystroke tap stopped")
    }

    // Note: owners must call stop() explicitly before releasing the engine to
    // tear down the event tap. A nonisolated deinit cannot touch the
    // MainActor-isolated, non-Sendable tap state under Swift 6.

    // MARK: - Media keys (§D, incoming)

    /// Resolve an incoming media/aux key against user shortcut rules. Returns true to
    /// swallow it. Fast no-op when no media rule is registered.
    func handleMedia(code: Int) -> Bool {
        guard ExtensionKeyRules.shared.hasMediaRules else { return false }
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        switch ExtensionKeyRules.shared.evaluateMedia(code: code, bundleID: bundleId) {
        case .passThrough:
            return false
        case .swallow:
            return true
        case .inject(let target):
            KeyInjector.stroke(target)
            return true
        case .system(let name):
            KeyInjector.system(name)
            return true
        case .launchApp(let app):
            AutocompleteEngine.launchApp(app)
            return true
        case .invoke(let extID, let handler, let arg):
            ExtensionKeyRules.shared.invoke?(extID, handler, arg)
            return true
        }
    }

    /// Incoming media/aux key → native rules first (press only, existing behavior),
    /// then the opt-in resident-VM eventtap (sees both press AND release so a Lua
    /// callback can branch on `:systemKey().down`). Returns true to swallow.
    func handleMediaEvent(code: Int, down: Bool,
                          cmd: Bool, alt: Bool, ctrl: Bool, shift: Bool, fn: Bool) -> Bool {
        if down, handleMedia(code: code) { return true }
        if EventTapHost.shared.wantsSystemDefined, let name = MediaKey.name(forCode: code) {
            return EventTapHost.shared.handleSystemDefined(
                key: name, down: down, cmd: cmd, alt: alt, ctrl: ctrl, shift: shift, fn: fn)
        }
        return false
    }

    /// Launch or activate an app by bundle id (`com.apple.Safari`) or `.app` path.
    static func launchApp(_ app: String) {
        let ws = NSWorkspace.shared
        let cfg = NSWorkspace.OpenConfiguration()
        if app.hasSuffix(".app") || app.hasPrefix("/") {
            ws.openApplication(at: URL(fileURLWithPath: app), configuration: cfg)
        } else if let url = ws.urlForApplication(withBundleIdentifier: app) {
            ws.openApplication(at: url, configuration: cfg)
        } else {
            NSLog("prosper: shortcut launchApp — app not found: %@", app)
        }
    }

    // MARK: - Tap callback

    /// Handles a tap event on the main actor. Returns true to swallow the key.
    private func handle(
        type: CGEventType, keyCode: Int64, optionHeld: Bool,
        controlHeld: Bool, commandHeld: Bool, shiftHeld: Bool, fnHeld: Bool, typed: String,
        isRepeat: Bool = false
    ) -> Bool {
        // Re-enable if the system disabled the tap (timeout / user input).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        // Modifier-only change: do NOT clear the suggestion. Holding Option to
        // perform a single-word accept (⌥→) must keep the suggestion alive.
        if type == .flagsChanged {
            return false
        }

        guard type == .keyDown else {
            return false
        }

        // Per-app rules: resolve the frontmost app's bundle id.
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // §D extension key remaps run FIRST (ahead of snippets/autocomplete) so a
        // remapped chord is transformed at the source. Skipped instantly when no
        // extension has registered rules. Injected events are tagged synthetic, so
        // they bypass this tap (no remap loop).
        // ponytail: remaps require the autocomplete tap to be running (it owns the
        // single shared tap); acceptable while the engine is the multiplexer — move
        // the tap to a standalone owner if autocomplete is ever disabled independently.
        if !ExtensionKeyRules.shared.isEmpty {
            let chord = KeyChord(
                keyCode: keyCode, cmd: commandHeld, alt: optionHeld,
                ctrl: controlHeld, shift: shiftHeld
            )
            switch ExtensionKeyRules.shared.evaluate(chord: chord, bundleID: bundleId, isRepeat: isRepeat) {
            case .passThrough:
                break
            case .swallow:
                return true
            case .inject(let target):
                KeyInjector.stroke(target)
                return true
            case .system(let name):
                KeyInjector.system(name)
                return true
            case .launchApp(let app):
                AutocompleteEngine.launchApp(app)
                return true
            case .invoke(let extID, let handler, let arg):
                // Swallow here (native, in the hot path); the handler runs off-main
                // on the extension's lane via the app-wired invoke hook.
                ExtensionKeyRules.shared.invoke?(extID, handler, arg)
                return true
            }
        }

        // Opt-in resident-VM eventtap (e.g. hammerspoon-compat raw keyDown taps).
        // Runs AFTER native declarative rules so those keep priority, and is gated to
        // a single Bool when no tap is registered — zero cost in the default product.
        if EventTapHost.shared.wantsKeyDown,
           EventTapHost.shared.handleKeyDown(
                keyCode: keyCode, cmd: commandHeld, alt: optionHeld,
                ctrl: controlHeld, shift: shiftHeld, fn: fnHeld) {
            return true
        }

        // Inline snippet expansion shares this single tap. Forward the keystroke to
        // the expander first; it maintains its own trigger buffer and performs its
        // own backspace+inject (events tagged with the same magic this tap skips).
        // It runs ahead of autocomplete's per-app denylist/accept logic — and ahead
        // of the autocomplete-enabled gate below — so snippets expand even when
        // inline autocomplete is switched off (the expander has its own
        // snippetsEnabled/snippetsAutoExpand gating). When it fires we SWALLOW the
        // trigger key (it is still in-flight to the app; the expander backspaces
        // only the already-delivered keyword chars and injects the snippet),
        // exactly like the accept-key path.
        if SnippetExpander.shared.handle(
            keyCode: keyCode, typed: typed, controlHeld: controlHeld,
            optionHeld: optionHeld, commandHeld: commandHeld, bundleId: bundleId
        ) {
            // The field's text just changed under us; drop any live ghost so it
            // doesn't linger against stale context.
            dismissOverlays()
            return true
        }

        // The tap may be running SOLELY for extension key rules / snippets (handled
        // above) while inline autocomplete is switched off. In that case do no
        // suggestion work — just pass the key through untouched.
        guard Preferences.autocompleteEnabled else { return false }

        // Ctrl+`: force-activate. Overrides the idle heuristics (small field, too
        // little context) and any Esc suppression for the current field, then
        // requests immediately (no debounce — this is an explicit ask).
        if keyCode == Self.kBacktick, controlHeld {
            refreshSuggestion()
            return true
        }

        // ⌥. : explicit retrigger — drop the current ghost (if any) and request a
        // fresh completion immediately. Swallowed so the app never receives the
        // "…" the keystroke would otherwise type.
        if keyCode == Self.kPeriod, optionHeld, !controlHeld {
            refreshSuggestion()
            return true
        }

        // Esc with a live suggestion: dismiss it AND stay quiet in this field
        // until focus moves elsewhere (Cotypist's Esc semantics). The key still
        // passes through — apps use Esc for their own dismissals.
        if keyCode == Self.kEscape {
            if currentSuggestion != nil {
                escSuppressedFieldRect = currentFieldRect ?? .infinite
                dismissOverlays()
            }
            return false
        }

        // Accept keys.
        if keyCode == Self.kTab || keyCode == Self.kRightArrow {
            if let suggestion = currentSuggestion, !suggestion.isEmpty {
                // ⌥Tab: bypass — deliver a literal Tab even while a suggestion
                // shows (form navigation must stay reachable).
                if keyCode == Self.kTab, optionHeld {
                    typedShadow = "" // the Tab moves focus/caret
                    clearSuggestion()
                    return false
                }
                // Disable-Tab: never swallow Tab in apps where Tab is critical
                // (IDEs, etc.); → still accepts. Other apps: Tab accepts + swallows.
                if keyCode == Self.kTab, AppOverrideResolver.isTabDisabled(forBundleId: bundleId) {
                    typedShadow = "" // the app receives the Tab (indent/focus)
                    return false
                }
                // Tab accepts one word at a time (press repeatedly to walk the
                // suggestion word by word). RightArrow accepts the whole
                // suggestion; ⌥→ accepts a single word.
                if keyCode == Self.kTab || optionHeld {
                    acceptFirstWord()
                } else {
                    acceptCurrentSuggestion()
                }
                return true // swallow the key
            }
            // No suggestion: let the key pass and hide. Tab/→ move focus/caret.
            typedShadow = ""
            clearSuggestion()
            return false
        }

        // Denylist: suppress suggestions entirely for excluded apps (password
        // managers, editors, system surfaces). Never schedule a request there.
        if AppOverrideResolver.isAutocompleteDisabled(forBundleId: bundleId) {
            clearSuggestion()
            return false
        }

        // Maintain the typed shadow (stale-AX detection — see requestSuggestion).
        // This point is only reached by ordinary typing: every swallowed shortcut
        // (Ctrl+`, ⌥., accepts) returned above, so their key chars never leak in.
        if keyCode == Self.kDelete {
            typedShadow = String(typedShadow.dropLast())
        } else if Self.caretMoveKeyCodes.contains(keyCode) {
            typedShadow = ""
        } else if !typed.isEmpty,
                  typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            typedShadow += typed
            if typedShadow.count > 64 { typedShadow = String(typedShadow.suffix(64)) }
        }

        // Type-through: the user typed exactly what the ghost predicted next —
        // consume it from the ghost locally instead of killing the suggestion and
        // paying a full LLM round trip. The ghost visually "absorbs" the
        // keystroke; a silent background refresh is still scheduled so the model
        // can extend/correct, and it replaces the ghost seamlessly when it lands.
        if typeThrough(typed: typed) {
            scheduleSuggestion() // refresh WITHOUT clearing the visible ghost
            return false
        }

        // Any other keystroke: hide current suggestion and (re)schedule a request.
        clearSuggestion()
        scheduleSuggestion()
        return false
    }

    /// Attempts to consume `typed` from the front of the live suggestion.
    /// Returns true when the ghost absorbed the keystroke (suggestion remains
    /// visible, advanced past the typed text). On a first-character mismatch,
    /// tries an instant lexicon "snap": re-predict the current word from the
    /// bundled dictionary so the ghost follows the user's actual word within a
    /// letter or two, without waiting for the LLM.
    private func typeThrough(typed: String) -> Bool {
        guard let suggestion = currentSuggestion, !suggestion.isEmpty,
              !isFix, replaceLength == 0,
              !typed.isEmpty,
              // Only printable text participates; control chars (backspace,
              // arrows, return) always fall through to the clear+reschedule path.
              typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return false }

        if suggestion.hasPrefix(typed) {
            let remainder = String(suggestion.dropFirst(typed.count))
            lastRenderedBefore = (lastRenderedBefore ?? "") + typed
            requestBefore = requestBefore.map { $0 + typed }
            guard !remainder.isEmpty, remainder.trimmingCharacters(in: .whitespaces).isEmpty == false else {
                // Fully typed out — nothing left to show.
                clearSuggestion()
                return false
            }
            currentSuggestion = remainder
            advanceGhost(by: typed, remainder: remainder)
            return true
        }

        // Mismatch: instant lexicon snap. Only mid-word (the user is steering the
        // current word somewhere else); boundary mismatches mean a genuinely new
        // direction — let the LLM handle those.
        guard let before = lastRenderedBefore else { return false }
        let newBefore = before + typed
        let fragment = CompletionCandidates.trailingWord(newBefore)
        guard !fragment.isEmpty else { return false }
        let candidates = CompletionCandidates.derive(
            before: newBefore, after: "", lexicon: Lexicon.shared
        )
        guard let snap = candidates.words.first(where: { $0.hasPrefix(fragment) && $0 != fragment }) else {
            return false
        }
        let remainder = String(snap.dropFirst(fragment.count))
        lastRenderedBefore = newBefore
        requestBefore = nil // lexicon snap is not an LLM training pair
        currentSuggestion = remainder
        advanceGhost(by: typed, remainder: remainder)
        return true
    }

    /// Shifts the ghost right by the rendered width of `text` and re-renders
    /// `remainder` there. Width is measured with the ghost's current font (which
    /// mirrors the field's font), so drift across a few characters is negligible;
    /// every full refresh (debounced LLM response) re-anchors from a fresh AX read.
    private func advanceGhost(by text: String, remainder: String) {
        if var rect = currentCaretRect {
            let font = suggestionWindow.currentFont
            let width = (text as NSString).size(withAttributes: [.font: font]).width
            rect.origin.x += width
            currentCaretRect = rect
        }
        let useMirror = Self.shouldUseMirror(
            caret: currentCaretRect, field: currentFieldRect, bundleId: requestBundleId
        )
        renderSuggestion(
            text: remainder, caret: currentCaretRect, field: currentFieldRect, useMirror: useMirror
        )
    }

    // MARK: - Suggestion flow (main thread)

    private func scheduleSuggestion() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: debounceInterval,
            repeats: false
        ) { [weak self] _ in
            // Timer fires on the main run loop → safe to assume MainActor.
            MainActor.assumeIsolated { self?.requestSuggestion() }
        }
    }

    /// Explicit retrigger (Ctrl+`, ⌥., or an accessory-button click): lifts any
    /// Esc suppression, force-activates the focused field, drops the visible
    /// ghost, and requests a fresh completion immediately (no debounce — this is
    /// an explicit ask).
    func refreshSuggestion() {
        escSuppressedFieldRect = nil
        forceActivatedFieldRect = AXCaret.currentContext()?.fieldScreenRect ?? .infinite
        debounceTimer?.invalidate()
        clearSuggestion()
        requestSuggestion()
    }

    private func requestSuggestion() {
        // Never autocomplete inside Prosper's own UI (command runner, translate
        // panel, settings). The indicator/ghost must not appear over our own
        // windows, so bail when we are the frontmost app.
        // Compare only when WE have a real bundle id: in a bare `swift run` dev/e2e
        // build both Bundle.main and a bare frontmost app report nil, and `nil == nil`
        // would treat every bare app as "Prosper's own UI" and never complete.
        if let mainId = Bundle.main.bundleIdentifier,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == mainId {
            Self.e2elog("bail: frontmost is self (\(mainId))")
            recordNoShow(.frontmostSelf)
            dismissOverlays()
            return
        }

        // Credential managers (1Password, Apple Passwords, …): never complete —
        // it leaks secrets and fights the app's own secure fields.
        let appProfile = AppProfile.current()
        if appProfile.suppressesCompletion {
            recordNoShow(.suppressesCompletion)
            dismissOverlays()
            return
        }

        // Per-domain scoping: suppress in browser tabs whose host is denylisted.
        // Done here (debounced path) rather than per-keystroke to limit AX cost.
        // Real browsers expose the host via AX (`BrowserURL`); Electron/Chromium
        // apps don't, so we fall back to the read-only Chromium source-url
        // pasteboard flavor there (`ChromiumPasteboard`). Only for Electron apps,
        // since that flavor is shared/stale global state.
        if !Preferences.disabledDomains.isEmpty {
            let host = BrowserURL.currentHost()
                ?? (AppProfile.current().isElectron ? ChromiumPasteboard.sourceHost() : nil)
            if Preferences.isDomainDisabled(host) {
                recordNoShow(.domainDisabled)
                return
            }
        }

        // Per-app force-enable of AXEnhancedUserInterface / AXManualAccessibility,
        // BEFORE caret resolution so the unlock can take effect on this read. Opt-in
        // per app (`forceEnhancedUI == true`); idempotent and cached per pid.
        let frontApp = NSWorkspace.shared.frontmostApplication
        if AppOverrideResolver.forceEnhancedUI(forBundleId: frontApp?.bundleIdentifier) == true {
            AXEnhancedUI.enableIfNeeded(for: frontApp)
        }

        guard let context = AXCaret.currentContext() else {
            // No focused text element (focus moved to a non-text control): tear
            // down the overlays instead of letting the indicator linger on the
            // previous field.
            Self.e2elog("bail: AXCaret.currentContext() nil")
            recordNoShow(.noCaret)
            dismissOverlays()
            return
        }
        let fieldRect = context.fieldScreenRect

        // Esc suppression: the user dismissed a suggestion here with Esc — stay
        // quiet in this field until focus moves to a different one (or app switch).
        if let suppressed = escSuppressedFieldRect {
            if Self.sameField(suppressed, fieldRect) {
                recordNoShow(.escSuppressed)
                accessoryButton.setState(.idle)
                return
            }
            escSuppressedFieldRect = nil
        }
        // Force-activation is likewise scoped to the field it was invoked in.
        if let forced = forceActivatedFieldRect, !Self.sameField(forced, fieldRect) {
            forceActivatedFieldRect = nil
        }

        // Browser address bar (omnibox): suppress. The browser owns URL/search
        // suggestions there; ghost text would fight its autocomplete. Only applied
        // inside known browsers so a false positive elsewhere can't suppress.
        if context.isAddressBarLike,
           let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           BrowserURL.browserBundleIds.contains(bid) {
            recordNoShow(.addressBar)
            dismissOverlays()
            return
        }

        // Match the ghost font to the field's text so it reads as inline.
        suggestionWindow.applyFont(context.caretFont)

        let before = context.textBefore
        Self.e2elog("context ok: before=\"\(before.suffix(24))\" after=\"\(context.textAfter.prefix(12))\"")
        guard !before.isEmpty else { Self.e2elog("bail: textBefore empty"); recordNoShow(.textBeforeEmpty); return }

        // Electron AX-lag guard (Slack): the AX value can lag the keyboard, so a
        // read taken right after typing may MISS the trailing chars we watched
        // the user type — a prompt built from that stale text yields a suggestion
        // that duplicates them ("по всяко" ghost after "по всяко" was typed).
        // Trust the read only when it ends with the typed shadow; otherwise wait
        // a debounce tick for AX to catch up. Bounded: apps that legitimately
        // rewrite text (autocorrect, markdown transforms) proceed after a few
        // retries with the shadow reset.
        if !typedShadow.isEmpty, !before.hasSuffix(typedShadow) {
            if staleAXRetries < 3 {
                staleAXRetries += 1
                recordNoShow(.staleAX)
                scheduleSuggestion()
                return
            }
            typedShadow = "" // the app rewrote the text — trust the AX read
        }
        staleAXRetries = 0

        // Mid-line completions: when disabled, only suggest at end-of-field.
        if !Preferences.midlineCompletionsEnabled,
           !context.textAfter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordNoShow(.midlineDisabled)
            return
        }

        requestToken &+= 1
        let token = requestToken
        let caretRect = Self.effectiveCaretRect(context.caretScreenRect, field: fieldRect)
        currentFieldRect = fieldRect
        let bundleId = frontApp?.bundleIdentifier
        requestBundleId = bundleId

        // 4a feedback: did forcing enhanced UI yield a real caret for this app?
        // Records a latching per-bundleId "helped" flag (no-op for apps we never
        // tried to unlock). Uses the *real* caret, not the synthetic field rect.
        AXEnhancedUI.recordCaretOutcome(
            bundleId: bundleId,
            caretResolved: Self.hasUsableCaret(context.caretScreenRect)
        )

        // 4b: when no usable caret exists (only a field rect) and text mirroring is
        // opted-in for this app, the suggestion is shown in the mirror bubble above
        // the field instead of relying on the accessory button alone.
        let useMirror = Self.shouldUseMirror(
            caret: context.caretScreenRect, field: fieldRect, bundleId: bundleId
        )

        // Cotypist-style indicator: pin a small icon to the leading edge of the
        // focused field so the user knows Prosper can complete here. This is the
        // opt-in accessory — it must stay hidden unless the user enabled it in
        // Settings ("Show accessory button near the active text field"); inline
        // ghost text is the default, icon-free affordance.
        if Preferences.showAccessoryButton {
            if let fieldRect {
                accessoryButton.showIndicator(atField: fieldRect, caretRect: caretRect)
            } else if let rect = caretRect {
                accessoryButton.show(at: rect)
            } else {
                accessoryButton.hide()
            }
        } else {
            accessoryButton.hide()
        }

        // macOS Secure Event Input (password fields, password managers holding the
        // keyboard): completions are impossible AND the context may be a secret.
        // Show the lock state and bail before anything is read into a prompt.
        if SecureInput.isActive {
            recordNoShow(.secureInput)
            accessoryButton.setState(.blocked)
            clearSuggestion()
            return
        }

        // NOTE: the old idle heuristics (small single-line fields, <2-word context)
        // were removed deliberately: Prosper must ALWAYS attempt a continuation of
        // the user's text. Whether the text is "enough" is the user's call, never
        // ours. The only remaining suppressions are user-initiated (Esc) or
        // security states (Secure Input, credential managers).

        // Emoji shortcode: `:partial` at the caret resolves locally (no LLM).
        if Preferences.emojiSuggestionsEnabled,
           let (triggerLen, emoji) = Self.emojiTrigger(before) {
            currentSuggestion = emoji
            replaceLength = triggerLen
            isFix = false
            requestBefore = nil  // WS6: emoji shortcodes are not training samples
            currentCaretRect = caretRect
            renderSuggestion(text: emoji, caret: caretRect, field: fieldRect, useMirror: useMirror)
            return
        }

        // Misspelled trailing word: either suggest a fix (if enabled) or suppress
        // a completion that would extend a likely typo.
        if Self.lastWordLooksMisspelled(before) {
            if Preferences.showSuggestedFixes,
               let (wordLen, original, fix) = Self.spellingFix(before) {
                currentSuggestion = fix
                replaceLength = wordLen
                isFix = true
                requestBefore = nil  // WS6: typo fixes are not training samples
                currentCaretRect = caretRect
                if useMirror, let fieldRect {
                    // No usable caret to strike through inline — mirror the proposed
                    // correction text into the bubble above the field instead.
                    mirrorWindow.show(text: fix, fieldRect: fieldRect)
                } else if let rect = caretRect {
                    suggestionWindow.showFix(strikethrough: original, fix: fix, at: rect, fieldRect: fieldRect)
                }
                return
            }
            if Preferences.suppressOnTypo { recordNoShow(.suppressOnTypo); return }
        }

        applyAppearance(for: caretRect)

        // LLM request in flight: pulse the indicator so the user can see Prosper
        // is thinking (vs. having decided to stay quiet).
        accessoryButton.setState(.thinking)

        let requestStart = Date()
        completionTask = CoreBridge.complete(
            before: before, after: context.textAfter,
            bundleId: bundleId, caretScreenRect: caretRect
        ) { [weak self] suggestion in
            guard let self else { return }
            // Single-flight: ignore stale responses.
            guard token == self.requestToken else { self.recordNoShow(.staleResponseToken); return }
            guard let suggestion, !suggestion.isEmpty else {
                // Model produced nothing even after CoreBridge's retry/reprompt
                // ladder. Distinguish the causes (P2.2): when the agent owns the
                // GPU the inline model is intentionally unloaded — show a PAUSED
                // state, not an error. Otherwise surface an ERROR so the user
                // knows no ghost is coming — unless a still-valid ghost is already
                // on screen (P1.2), in which case keep it rather than flash error.
                Self.e2elog("model returned empty suggestion")
                if ModelResidencyCoordinator.isAgentActive {
                    self.recordNoShow(.agentPaused)
                    self.accessoryButton.setState(.paused)
                } else if self.currentSuggestion == nil {
                    self.recordNoShow(.modelEmpty)
                    self.accessoryButton.setState(.error)
                }
                return
            }
            // Adaptive debounce (P1.1): sample latency on the success path only —
            // empty results ran the full 6-rung ladder and would inflate the EMA.
            self.updateDebounce(Date().timeIntervalSince(requestStart))
            Self.e2elog("model suggestion=\"\(suggestion.prefix(32))\"")
            guard let fresh = AXCaret.currentContext() else { self.recordNoShow(.staleNoContext); return }
            let liveBefore = fresh.textBefore
            // Electron AX-lag pre-guard (Slack): trust the read only when it ends
            // with the typed shadow we watched the user type; otherwise wait a
            // debounce tick for AX to catch up (else a prompt built from stale
            // text duplicates words — "по всяко" + ghost "по всяко").
            if !self.typedShadow.isEmpty, !liveBefore.hasSuffix(self.typedShadow) {
                self.recordNoShow(.staleAX)
                Self.e2elog("stale-AX reschedule: live=\"\(liveBefore.suffix(24))\" shadow=\"\(self.typedShadow.suffix(12))\"")
                self.scheduleSuggestion()
                return
            }
            // P0.2 reconcile (was a binary drop). The suggestion continues `before`
            // (the request-time text). If the user typed forward INTO it since,
            // TRIM the consumed prefix and show the remainder — this is what keeps
            // the ghost alive through fast typing instead of dropping every drifted
            // response. Only a genuine divergence reschedules.
            let shown: String
            switch Self.reconcile(suggestion: suggestion, anchor: before, live: liveBefore) {
            case .show(let s): shown = s
            case .reschedule:
                self.recordNoShow(.diverged)
                Self.e2elog("reconcile reschedule: live=\"\(liveBefore.suffix(24))\" req=\"\(before.suffix(24))\"")
                self.scheduleSuggestion()
                return
            }

            // Prefer render-time geometry: the caret may have moved — or only
            // now become resolvable (Electron caret rects often lag the text) —
            // since the request was issued. Only when the fresh caret is REAL,
            // though: a degenerate fresh read must not replace a usable
            // request-time caret with the synthetic field-left rect (Slack's
            // fresh reads often degenerate → the ghost jumped to the field's
            // leading edge, overlapping the user's text).
            let liveField = fresh.fieldScreenRect ?? fieldRect
            let liveCaret = Self.hasUsableCaret(fresh.caretScreenRect)
                ? fresh.caretScreenRect
                : caretRect
            let liveMirror = Self.shouldUseMirror(
                caret: fresh.caretScreenRect, field: liveField, bundleId: bundleId
            )
            self.currentFieldRect = liveField

            // Insert a separating space when the model begins a NEW word but the
            // user's text ends flush against a finished word (no trailing space),
            // so "brown" + "fox" renders/inserts as "brown fox" not "brownfox".
            let spaced = Self.applyWordBoundary(before: liveBefore, suggestion: shown)
            // Mid-word guard (P0.3): the caret sits against an unfinished word but
            // the model started a NEW word ("wri" + " recording"). Inserting it
            // would orphan the fragment. Don't error+clear (that destroys a kept
            // ghost and flashes a scary badge for a routine case) — just decline
            // this new-word suggestion and re-request; the accept-guard protects
            // any ghost left on screen.
            // ponytail: skipped the lexicon "try-align" remedy — the snap already
            // runs on the hot path in typeThrough(); add it here only if mid-word
            // misses prove common.
            if Self.startsNewWordAgainstUnfinishedFragment(before: liveBefore, spaced: spaced) {
                Self.e2elog("suppress: new word against unfinished fragment \"\(liveBefore.suffix(12))\"")
                self.recordNoShow(.midWord)
                if self.currentSuggestion == nil { self.accessoryButton.setState(.idle) }
                // Do NOT reschedule: `liveBefore` is unchanged, so a fresh request
                // hits the deterministic first rung and returns the same new-word
                // suggestion → another midWord → spin loop burning the GPU while the
                // user is idle. The next real keystroke re-triggers naturally.
                return
            }
            // Success: ghost text is about to render at the caret.
            self.accessoryButton.setState(.ready)
            self.currentSuggestion = spaced
            self.replaceLength = 0
            self.isFix = false
            self.requestBefore = liveBefore  // WS6: prompt for the training pair
            // WS6 A/B: count this LLM completion as SHOWN under the session arm, and
            // arm the accept flag so the matching accept (whole or first word) is
            // counted exactly once.
            self.abAcceptedForCurrent = false
            LoRAEvaluator.recordShown(adapterActive: LoRAEvaluator.sessionServesAdapter)
            self.currentCaretRect = liveCaret
            self.lastRenderedBefore = liveBefore // arms type-through for this ghost
            Self.e2elog("render ghost=\"\(spaced.prefix(32))\"")
            self.renderSuggestion(text: spaced, caret: liveCaret, field: liveField, useMirror: liveMirror)
        }
    }

    /// Renders a plain suggestion through the appropriate overlay: the mirror bubble
    /// above the field when 4b mirroring is active (no usable caret + opted-in app),
    /// else the inline caret-anchored ghost. Centralizes the choice so every
    /// suggestion source (emoji, completion) routes the same way; the inline ghost
    /// remains the default whenever a caret is available or mirroring is off.
    private func renderSuggestion(text: String, caret: CGRect?, field: CGRect?, useMirror: Bool) {
        if useMirror, let field {
            mirrorWindow.show(text: text, fieldRect: field)
        } else if let caret {
            suggestionWindow.show(text: text, at: caret, fieldRect: field)
        }
    }

    /// Adapts the ghost overlay color to the caret-region background when the
    /// "improve appearance" option is on (no-op otherwise). Reads through the
    /// throttled `ScreenContextCache`, so it reuses a recent color sample instead
    /// of capturing a screenshot on every keystroke; the cache refreshes the color
    /// in the background. A slightly late color adapt is harmless — it only tints
    /// the ghost overlay.
    private func applyAppearance(for caretRect: CGRect?) {
        guard Preferences.improveAppearanceFromScreenshot, let caretRect else { return }
        if let bg = ScreenContextCache.shared.backgroundColor(around: caretRect) {
            suggestionWindow.adaptColor(toBackground: bg)
        }
    }

    private func clearSuggestion() {
        requestToken &+= 1 // invalidate any in-flight request
        completionTask?.cancel() // stop a superseded generation mid-flight
        completionTask = nil
        currentSuggestion = nil
        currentCaretRect = nil
        currentFieldRect = nil
        replaceLength = 0
        isFix = false
        lastRenderedBefore = nil
        suggestionWindow.hide()
        mirrorWindow.hide()
        // Ghost gone → drop a stale success/error badge back to the neutral
        // glyph. Leave .blocked/.thinking alone: blocked is set right before
        // some clears (Secure Input) and must survive them.
        if accessoryButton.state == .ready || accessoryButton.state == .error {
            accessoryButton.setState(.idle)
        }
    }

    /// Fuzzy same-field test for the per-field Esc-suppression / force-activation
    /// scopes. `.infinite` (recorded when no field rect was known) matches any
    /// field — the scope then lasts until the app switches. Centers compared with
    /// tolerance because some apps re-report a focused field with ±1pt jitter.
    private static func sameField(_ a: CGRect, _ b: CGRect?) -> Bool {
        if a == .infinite { return true }
        guard let b else { return false }
        return abs(a.midX - b.midX) < 8 && abs(a.midY - b.midY) < 8
    }

    /// Accept-safety guard (P0.1b). A continuation ghost can sit on screen across
    /// keystrokes (type-through keeps it alive while the user types into it), so at
    /// accept time the visible ghost may trail the live field by a few chars — or,
    /// worse, the field may have diverged (caret jump, paste, AX lag). Re-read the
    /// field and reconcile against `lastRenderedBefore` (the text the ghost is glued
    /// to): on `.show`, return the suggestion trimmed to what still continues the
    /// live text; on `.reschedule`, return nil so the caller swallows the accept and
    /// refreshes — NEVER type divergent text into a third-party app.
    ///
    /// Emoji/typo-fix ghosts (`isFix`/`replaceLength>0`) are anchored to a
    /// just-typed trigger and accepted immediately, so they bypass the guard. If AX
    /// is momentarily unreadable, fall back to the current suggestion (today's
    /// behavior) rather than blocking the accept.
    private func reconciledGhostForAccept() -> String? {
        guard let suggestion = currentSuggestion, !suggestion.isEmpty else { return nil }
        if isFix || replaceLength > 0 { return suggestion }
        guard let anchor = lastRenderedBefore,
              let live = AXCaret.currentContext()?.textBefore else { return suggestion }
        switch Self.reconcile(suggestion: suggestion, anchor: anchor, live: live) {
        case .show(let s): return s
        case .reschedule: return nil
        }
    }

    /// Inserts the current suggestion by synthesizing keyboard input, then clears.
    /// For emoji shortcodes / typo fixes, first deletes the replaced trailing chars.
    private func acceptCurrentSuggestion() {
        guard let suggestion = reconciledGhostForAccept() else {
            Self.e2elog("accept: ghost diverged from live text — swallow + refresh")
            recordNoShow(.acceptDiverged)
            clearSuggestion()
            scheduleSuggestion()
            return
        }
        Self.e2elog("accept inject=\"\(suggestion.prefix(32))\"")
        let replaceLen = replaceLength
        let wasFix = isFix
        let bundleId = requestBundleId
        clearSuggestion()
        CompletionStats.recordAccept(suggestion)
        if replaceLen == 0 {
            // Don't store emoji-shortcode replacements / typo fixes in history.
            Task { await TypingHistoryStore.shared.record(suggestion, bundleId: bundleId) }
            // WS6: record the accepted (prompt, completion) pair for LoRA training.
            // Only LLM completions carry a captured prompt (`requestBefore`).
            if let prompt = requestBefore {
                Task {
                    await TypingHistoryStore.shared.recordTrainingSample(
                        prompt: prompt, completion: suggestion, accepted: true, bundleId: bundleId
                    )
                }
                // WS6 A/B: count the accept once per shown completion + run the
                // auto-disable check.
                if !abAcceptedForCurrent {
                    abAcceptedForCurrent = true
                    LoRAEvaluator.recordAccepted(adapterActive: LoRAEvaluator.sessionServesAdapter)
                }
            }
        } else {
            typedShadow = String(typedShadow.dropLast(replaceLen)) // mirror synthetic deletes
            sendBackspaces(replaceLen)
        }
        _ = wasFix
        insert(suggestion, bundleId: bundleId)
    }

    /// Inserts text via the per-app insertion path: synthesized unicode typing,
    /// or a clipboard-paste fallback for apps flagged "improve compatibility".
    private func insert(_ string: String, bundleId: String?) {
        // Synthetic insertion extends the field's text exactly like typing would,
        // but the tap skips our own events — mirror it into the typed shadow so
        // the stale-AX check keeps matching after an accept.
        typedShadow += string
        if typedShadow.count > 64 { typedShadow = String(typedShadow.suffix(64)) }
        if Preferences.usesCompatInsertion(forBundleId: bundleId) {
            pasteString(string)
        } else {
            typeString(string)
        }
        // ponytail: temporary e2e verdict — did our own injection actually mutate
        // the focused field? Re-read AX shortly after; gated on PROSPER_E2E.
        if Self.e2eTrace {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let after = AXCaret.currentContext()?.textBefore ?? "<nil>"
                Self.e2elog("post-insert AX textBefore=\(after.count)ch tail=\"\(String(after.suffix(24)))\"")
            }
        }
    }

    /// Detects an emoji shortcode trigger (`:partial`) at the end of `before`.
    /// Returns (triggerLength incl. the colon, emoji) or nil.
    nonisolated static func emojiTrigger(_ before: String) -> (length: Int, emoji: String)? {
        guard let colon = before.lastIndex(of: ":") else { return nil }
        let partial = before[before.index(after: colon)...]
        guard !partial.isEmpty, partial.count <= 32 else { return nil }
        // Shortcode chars only: letters, digits, _, +, -.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-")
        guard partial.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let match = Emoji.best(forPrefix: String(partial)) else { return nil }
        return (partial.count + 1, match.emoji) // +1 for the colon
    }

    /// Returns a usable caret rect for placing overlays. Some apps (notably
    /// Electron, e.g. Slack) report a fully-degenerate caret `(0,0,0,0)` from the
    /// bounds-for-range AX query; placing the ghost there collapses it to the
    /// screen corner (off-screen). When that happens, synthesize a caret anchored
    /// to the focused field's leading edge so the ghost stays on-screen and
    /// vertically centered in the field. A caret with a real origin (even if its
    /// width is 0, as Telegram reports) is returned unchanged.
    static func effectiveCaretRect(_ caret: CGRect?, field: CGRect?) -> CGRect? {
        if let caret, !(caret.origin == .zero && caret.width == 0 && caret.height == 0) {
            return caret
        }
        guard let field, field.width > 1, field.height > 1 else { return caret }
        // `SuggestionWindow` derives the glyph line center as `minY - height/2`,
        // so a synthetic caret whose minY sits a half-field-height above the field
        // top lands the ghost centered within the field.
        return CGRect(x: field.minX, y: field.maxY, width: 0, height: field.height)
    }

    /// The screen-Y of the text line's center for a caret rect, robust across
    /// toolkits. AppKit text views (NSTextView/TextEdit) report the caret box
    /// ~half a line-height ABOVE the rendered glyphs, so the line center is
    /// `minY - height/2`. Chromium/Electron and web form fields report the TRUE
    /// glyph box, where the line center is simply `midY` — applying the AppKit
    /// correction there drops the ghost a full line below the field. The rect
    /// alone doesn't say which toolkit produced it, but the field bounds do:
    /// prefer the AppKit-corrected center (native behavior, unchanged), fall
    /// back to the true-box center when the corrected one lands outside the
    /// field, and clamp to the field's vertical center when both miss.
    static func ghostLineCenterY(caret: CGRect, field: CGRect?) -> CGFloat {
        let appKitCenter = caret.minY - caret.height / 2
        guard let field, field.height > 1 else { return appKitCenter }
        func inField(_ y: CGFloat) -> Bool { y >= field.minY && y <= field.maxY }
        if inField(appKitCenter) { return appKitCenter }
        let trueCenter = caret.midY
        if inField(trueCenter) { return trueCenter }
        return field.midY
    }

    /// Whether the app reported a *real* caret rect (not the degenerate
    /// `(0,0,0,0)` that `effectiveCaretRect` rewrites into a synthetic field-anchored
    /// rect). Used as the 4a feedback signal — "did forcing enhanced UI yield genuine
    /// caret geometry?" — and as the 4b trigger ("no real caret ⇒ consider mirroring").
    /// A caret with a real origin but zero width (as Telegram reports) still counts as
    /// usable; only the fully-degenerate origin-and-size-zero rect does not.
    static func hasUsableCaret(_ caret: CGRect?) -> Bool {
        guard let caret else { return false }
        return !(caret.origin == .zero && caret.width == 0 && caret.height == 0)
    }

    /// The 4b decision, as a pure function: show the mirror bubble (instead of relying
    /// on the bare accessory button) when there is **no usable caret** but a usable
    /// field rect exists AND the app has opted into text mirroring
    /// (`AppOverrideResolver.textMirroring == true`). When a real caret exists the
    /// inline ghost handles it; when mirroring is nil/false the legacy
    /// accessory-button behavior is preserved unchanged.
    static func shouldUseMirror(caret: CGRect?, field: CGRect?, bundleId: String?) -> Bool {
        guard AppOverrideResolver.textMirroring(forBundleId: bundleId) == true else { return false }
        guard !hasUsableCaret(caret) else { return false }
        guard let field, field.width > 1, field.height > 1 else { return false }
        return true
    }

    /// Inserts a leading space when the completion starts a NEW word but the
    /// user's text ends flush against a finished word with no trailing space —
    /// preventing "brown" + "fox" from gluing into "brownfox". The completion is
    /// left unchanged when it already begins with whitespace/punctuation, when the
    /// boundary chars can't glue, or when the trailing word is an incomplete /
    /// misspelled fragment (in which case the model is continuing that word).
    /// Outcome of reconciling an arrived (or about-to-be-accepted) suggestion
    /// against the live text. `.show` carries the text that validly continues the
    /// caret right now (possibly trimmed); `.reschedule` means the context
    /// diverged and a fresh request is needed.
    enum ReconcileOutcome: Equatable {
        case show(String)
        case reschedule
    }

    /// Reconcile a `suggestion` — which was computed as a continuation of `anchor`
    /// — against the current `live` text before the caret (VSCode's
    /// `computeGhostText`/`cachingDiff` ported to plain text). This is what keeps
    /// the ghost alive while the user types instead of dropping every drifted
    /// response. Pure + `nonisolated` so it is unit-testable off the actor.
    ///
    /// Four cases:
    /// - (a) `live == anchor`            → show unchanged.
    /// - (b) `live` extends `anchor` AND the suggestion starts with the typed
    ///       delta → user typed forward INTO the suggestion: trim the delta, show
    ///       the remainder (empty remainder ⇒ reschedule, nothing left to show).
    /// - (c) `anchor` extends `live` (backspace/deletion) → reschedule.
    /// - (d) anything else (genuine divergence, paste, caret jump, script switch)
    ///       → reschedule.
    nonisolated static func reconcile(suggestion: String, anchor: String, live: String) -> ReconcileOutcome {
        if live == anchor { return .show(suggestion) }
        if live.hasPrefix(anchor) {
            let delta = String(live.dropFirst(anchor.count))
            guard !delta.isEmpty, suggestion.hasPrefix(delta) else { return .reschedule }
            let remainder = String(suggestion.dropFirst(delta.count))
            return remainder.isEmpty ? .reschedule : .show(remainder)
        }
        return .reschedule
    }

    static func applyWordBoundary(before: String, suggestion: String) -> String {
        guard let lastBefore = before.last, let firstSug = suggestion.first else { return suggestion }
        // The user's text already ends at a word boundary: drop any leading space
        // the model added so insertion doesn't produce a double space.
        if lastBefore.isWhitespace {
            return firstSug.isWhitespace ? String(suggestion.drop(while: { $0 == " " })) : suggestion
        }
        // Model already separated with a space/newline — keep as-is.
        if firstSug.isWhitespace { return suggestion }

        // Clause/sentence punctuation boundary: the user's text ends with
        // punctuation and the model began the next word flush against it
        // ("fox." + "The" → "fox.The", "wait," + "and" → "wait,and"). Insert
        // the separating space. Number-leading suggestions stay glued so
        // decimals and thousands survive ("3." + "14", "1," + "000"); after a
        // period only an UPPERCASE start gets the space, so domains and file
        // extensions stay glued ("example." + "com", "main." + "swift").
        if firstSug.isLetter {
            if lastBefore == "." {
                if firstSug.isUppercase { return " " + suggestion }
            } else if ",;:!?)]}".contains(lastBefore) {
                return " " + suggestion
            }
        }

        guard lastBefore.isLetter || lastBefore.isNumber,
              firstSug.isLetter || firstSug.isNumber else { return suggestion }

        // Trailing run of letters in `before` (the word the caret sits against)
        // and the leading run of letters in the suggestion. If gluing them yields
        // a real word ("brow" + "n" -> "brown"), the model is continuing that word
        // and no space is wanted. Otherwise it began a new word and dropped the
        // separator ("brown" + "fox" -> "brownfox"), so insert a space.
        let trailing = String(before.reversed().prefix { $0.isLetter }.reversed())
        let leading = String(suggestion.prefix { $0.isLetter })
        guard !trailing.isEmpty, !leading.isEmpty else { return suggestion }
        let glued = trailing + leading
        // language: nil + automatic identification — the bare two-arg
        // `checkSpelling` judges against the user's primary language only, so a
        // Cyrillic glue ("пак"+"всяко") was never flagged on an English system
        // and the separating space was silently dropped.
        let checker = NSSpellChecker.shared
        checker.automaticallyIdentifiesLanguages = true
        let gluedIsWord = checker.checkSpelling(
            of: glued, startingAt: 0, language: nil, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
        return gluedIsWord ? suggestion : " " + suggestion
    }

    /// True when the caret sits against an UNFINISHED word (its trailing letters
    /// don't form a real word yet) but the spaced completion begins a NEW word —
    /// inserting it would orphan the fragment: "wri" + " recording" → "wri
    /// recording", or a case-mismatched repeat "websit" + " Website here". The
    /// model failed to continue the in-progress word, so show nothing and let the
    /// next keystroke re-request once there's more to go on.
    ///
    /// Deliberately narrow. Three things must all hold: the caret is mid-letter
    /// (no separator), the boundary logic decided to INSERT a space (a genuinely
    /// new word, not a continuation like "thre" + "e blind"), and the trailing
    /// fragment isn't a real word. A finished word the user simply hasn't spaced
    /// yet ("brown" + " fox") passes the spell check and is left alone — that
    /// spacing is wanted.
    static func startsNewWordAgainstUnfinishedFragment(before: String, spaced: String) -> Bool {
        guard let last = before.last, last.isLetter else { return false }
        guard spaced.first == " " else { return false }
        return lastWordLooksMisspelled(before)
    }

    /// Whether the trailing word of `before` is flagged misspelled by the system
    /// spell checker. Returns false when the caret is not mid-word (ends in space
    /// or punctuation), so completions at word boundaries are unaffected.
    static func lastWordLooksMisspelled(_ before: String) -> Bool {
        // Extract the trailing run of letters.
        var word = ""
        for ch in before.reversed() {
            if ch.isLetter { word.append(ch) } else { break }
        }
        let trailing = String(word.reversed())
        guard trailing.count >= 3 else { return false } // too short to judge
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: trailing, startingAt: 0)
        // location == NSNotFound means no misspelling found.
        return range.location != NSNotFound
    }

    /// For a misspelled trailing word, returns (wordLength, original, bestFix) or
    /// nil if no confident correction exists. Used by "Show suggested fixes".
    static func spellingFix(_ before: String) -> (length: Int, original: String, fix: String)? {
        var word = ""
        for ch in before.reversed() {
            if ch.isLetter { word.append(ch) } else { break }
        }
        let original = String(word.reversed())
        guard original.count >= 3 else { return nil }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (original as NSString).length)
        guard let guesses = checker.guesses(
            forWordRange: range, in: original, language: nil, inSpellDocumentWithTag: 0
        ), let best = guesses.first, best.lowercased() != original.lowercased() else {
            return nil
        }
        return (original.count, original, best)
    }

    /// Synthesizes `count` backspace (delete) key presses.
    private func sendBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let deleteKey: CGKeyCode = 51 // kVK_Delete
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true) {
                down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
                down.post(tap: .cgSessionEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false) {
                up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Accepts only the first word (plus its trailing whitespace) of the current
    /// suggestion, keeping the remainder visible as a fresh suggestion (⌥→).
    private func acceptFirstWord() {
        // Emoji replacements / typo fixes are atomic — accept the whole thing.
        if replaceLength > 0 { acceptCurrentSuggestion(); return }
        // Accept-safety guard (P0.1b): same reconcile as the whole-line accept, so a
        // word-accept on a drifted ghost trims to the live text or refreshes instead
        // of typing a stale word.
        guard let suggestion = reconciledGhostForAccept(), !suggestion.isEmpty else {
            Self.e2elog("accept-word: ghost diverged from live text — swallow + refresh")
            recordNoShow(.acceptDiverged)
            clearSuggestion()
            scheduleSuggestion()
            return
        }
        let bundleId = requestBundleId
        let (head, tail) = Self.splitFirstWord(suggestion)
        guard !head.isEmpty else { acceptCurrentSuggestion(); return }

        CompletionStats.recordAccept(head)
        Task { await TypingHistoryStore.shared.record(head, bundleId: bundleId) }
        // WS6: record the accepted word as a (prompt, completion) training pair, then
        // grow the prompt by the accepted word so the next word-accept records its own
        // pair against the updated context (incremental positive SFT).
        if let prompt = requestBefore {
            Task {
                await TypingHistoryStore.shared.recordTrainingSample(
                    prompt: prompt, completion: head, accepted: true, bundleId: bundleId
                )
            }
            // WS6 A/B: a word-accept counts the shown completion as accepted once.
            if !abAcceptedForCurrent {
                abAcceptedForCurrent = true
                LoRAEvaluator.recordAccepted(adapterActive: LoRAEvaluator.sessionServesAdapter)
            }
            requestBefore = prompt + head
        }
        let remainder = tail
        // Trailing space after the FINAL word-accept (opt-in): the next sentence
        // continues without the user reaching for the spacebar. Mid-suggestion
        // accepts already carry their separator via splitFirstWord.
        var toInsert = head
        if remainder.isEmpty, Preferences.trailingSpaceAfterWordAccept,
           !(head.last?.isWhitespace ?? false) {
            toInsert += " "
        }
        insert(toInsert, bundleId: bundleId)
        lastRenderedBefore = lastRenderedBefore.map { $0 + toInsert }

        requestToken &+= 1 // invalidate any in-flight request
        if remainder.isEmpty {
            currentSuggestion = nil
            suggestionWindow.hide()
            mirrorWindow.hide()
            return
        }
        currentSuggestion = remainder
        // Render at the current caret immediately so the remainder never blinks out,
        // then reposition once the synthesized typing has landed (the caret has
        // advanced past the inserted word, so the old rect is now a word too far
        // left). The synthetic events are tagged and ignored by our tap, so they
        // won't clear this suggestion.
        renderRemainder(remainder, bundleId: bundleId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.currentSuggestion == remainder else { return }
                guard let ctx = AXCaret.currentContext() else { return }
                self.currentCaretRect = Self.effectiveCaretRect(ctx.caretScreenRect, field: ctx.fieldScreenRect)
                self.currentFieldRect = ctx.fieldScreenRect
                self.suggestionWindow.applyFont(ctx.caretFont)
                self.renderRemainder(remainder, bundleId: bundleId)
            }
        }
    }

    /// Re-renders `remainder` through the same overlay it started in: a mirrored
    /// suggestion (no usable caret + opted-in app) stays in the bubble; everything
    /// else stays inline at the caret.
    private func renderRemainder(_ remainder: String, bundleId: String?) {
        let useMirror = Self.shouldUseMirror(
            caret: currentCaretRect, field: currentFieldRect, bundleId: bundleId
        )
        renderSuggestion(
            text: remainder, caret: currentCaretRect, field: currentFieldRect, useMirror: useMirror
        )
    }

    /// Splits a string into (first word + trailing run of whitespace, remainder).
    /// e.g. "quick brown" -> ("quick ", "brown"); " lead" -> (" lead", "").
    static func splitFirstWord(_ string: String) -> (head: String, tail: String) {
        let chars = Array(string)
        var i = 0
        // Leading whitespace stays with the head.
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        // The word itself.
        while i < chars.count, !chars[i].isWhitespace { i += 1 }
        // Trailing whitespace after the word stays with the head.
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        let head = String(chars[0..<i])
        let tail = String(chars[i...])
        return (head, tail)
    }

    /// Synthesizes typing of a string via CGEvent unicode keyboard events.
    private func typeString(_ string: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(string.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
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

    /// Alternate insertion path for apps that mishandle synthesized unicode
    /// typing ("improve compatibility"): stash the text on the pasteboard and
    /// synthesize ⌘V, restoring the previous clipboard afterward.
    private func pasteString(_ string: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(string, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)

        // Restore the prior clipboard shortly after the paste lands.
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
    }
}
