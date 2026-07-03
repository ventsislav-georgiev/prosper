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
    private var scrollMonitor: Any?

    private let suggestionWindow = SuggestionWindow()
    private let mirrorWindow = MirrorOverlayWindow()
    private let accessoryButton = AccessoryButton()
    private var debounceTimer: Timer?
    /// Throttle for the instant-ghost fresh caret read (bounds heavy AX cost).
    private var lastInstantCaretRead = Date.distantPast

    /// Invoked when the floating accessory button is clicked (set by AppDelegate).
    var onAccessoryClicked: (() -> Void)? {
        get { accessoryButton.onClick }
        set { accessoryButton.onClick = newValue }
    }

    // Current suggestion state (main thread only).
    private var currentSuggestion: String?
    private var currentCaretRect: CGRect?
    private var currentFieldRect: CGRect?
    // B2 n-best: the runners-up from the last pause-fire, keyed by anchor text, so a
    // keystroke that diverges from the shown ghost can swap to an alternate with no
    // model round trip. Nil unless `Preferences.nBestCandidates > 1`.
    private var candidateBuffer: CandidateBuffer?
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

    // One-shot carry-over of a typo fix's gray continuation across the Tab
    // word-accept: the user was already reading it, so the re-suggest after the
    // corrected word renders IT instantly instead of asking the model for a
    // fresh (different) answer. `expectSuffix` is the text the accept injected;
    // the next request only serves the carry-over if the live text still ends
    // with it (anything else means the user typed on and it's stale).
    private var pendingFixContinuation:
        (expectSuffix: String, text: String, bundleId: String?, at: Date)?

    // Prompt of the last ghost-extension request fired (live text + remaining
    // ghost), so consuming several keystrokes near the ghost's end fires ONE
    // extension per ghost state instead of one per keystroke.
    private var ghostExtensionPrompt: String?

    // Single-flight token: increments on each new request; stale results ignored.
    private var requestToken: UInt64 = 0

    // Backing task of the in-flight completion request. Cancelled on every new
    // keystroke so a superseded generation stops prefill/decode immediately
    // instead of running to completion on the serialized MLX actor.
    private var completionTask: Task<Void, Never>?
    // Pipelined single-flight (see requestSuggestion): the `before` text of the
    // request currently in flight, and whether a fresh request should fire as
    // soon as it lands. Replaces the old cancel-on-every-fire, which meant that
    // during continuous typing every response was cancelled before it could
    // land — so no ghost ever appeared until the user paused.
    private var inFlightAnchor: String?
    private var inFlightSince: Date = .distantPast
    private var pendingRefire = false
    /// Last keystroke that scheduled a suggestion — used at refire time to pick
    /// burst (still typing) vs full ladder (paused).
    private var lastTypedAt: Date = .distantPast

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
    private var debounceInterval: TimeInterval = 0.10
    private var latencyEMA: TimeInterval = 0.12
    nonisolated static let debounceMin: TimeInterval = 0.06
    // Cap the trailing debounce well below the old 0.6s: warm-cache inline gen is
    // ~120ms, so a pause longer than ~250ms already felt like "waiting". The maxWait
    // throttle below handles continuous typing; this only bounds the pause case.
    nonisolated static let debounceMax: TimeInterval = 0.25
    // Force a model request at least this often during a continuous typing burst
    // (see scheduleSuggestion) so the ghost updates WHILE typing, not only on pause.
    nonisolated static let debounceMaxWait: TimeInterval = 0.22
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

    /// Pure model of the schedule (see `scheduleSuggestion`) — `nonisolated static`
    /// so the emergent "does the ghost update WHILE typing?" behavior is testable
    /// off the actor. Given the keystroke timestamps (seconds), returns the times a
    /// model request fires: immediately when ≥ `maxWait` since the last fire (the
    /// throttle that lets the ghost keep up during a continuous burst), otherwise a
    /// trailing debounce reset per keystroke. A PURE trailing debounce (maxWait = ∞)
    /// collapses to a single fire after the burst — the bug this fixes.
    nonisolated static func plannedFires(
        keystrokes: [TimeInterval], debounce: TimeInterval, maxWait: TimeInterval
    ) -> [TimeInterval] {
        var fires: [TimeInterval] = []
        var lastFired: TimeInterval = -1e9   // finite (models `.distantPast`): a finite
                                             // maxWait fires on the first keystroke, an
                                             // infinite one (pure trailing) never does.
        var pendingTrailing: TimeInterval? = nil
        for t in keystrokes {
            // A trailing timer armed by an earlier keystroke elapses before this one.
            if let p = pendingTrailing, p <= t { fires.append(p); lastFired = p; pendingTrailing = nil }
            if t - lastFired >= maxWait {
                fires.append(t); lastFired = t; pendingTrailing = nil    // immediate (throttle)
            } else {
                pendingTrailing = t + debounce                          // reset trailing debounce
            }
        }
        if let p = pendingTrailing { fires.append(p) }                  // trailing fire after the burst
        return fires
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
        case liveEcho, ghostStable
    }
    private(set) var noShowCounts: [NoShowReason: Int] = [:]
    private func recordNoShow(_ reason: NoShowReason) {
        let count = noShowCounts[reason, default: 0] + 1
        noShowCounts[reason] = count
        Self.e2elog("no-show: \(reason.rawValue) [\(count)]")
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
    // focus moves elsewhere (the reference app's Esc semantics — "not here, not now").
    // Keyed on the field rect (fuzzy-compared); cleared on app switch or when a
    // different field produces a context.
    private var escSuppressedFieldRect: CGRect?
    /// When the Esc suppression was recorded. Only consulted for the fieldless
    /// `.infinite` fallback (Electron/degenerate-caret hosts): that sentinel
    /// matches EVERY field, so left unbounded one Esc would silence autocomplete
    /// everywhere until an app switch — time-box it instead.
    private var escSuppressedAt = Date.distantPast
    // Ctrl+` pressed: override the idle heuristics (small field / too little
    // context) for THIS field until focus moves elsewhere.
    private var forceActivatedFieldRect: CGRect?
    // Text before the caret at the time the current suggestion was rendered.
    // Drives type-through: the next keystroke's expected prefix comes from here
    // without an AX read on the hot path.
    private var lastRenderedBefore: String?

    // When `currentCaretRect` last came from a REAL AX read (vs the width-shift
    // arithmetic in advanceGhost). Lets advanceGhost re-anchor from AX once the
    // cached anchor ages, bounding ghost drift during long type-through runs.
    private var caretAnchoredAt = Date.distantPast

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

        // Scrolling moves the text (and the caret's field) under the ghost, and
        // nothing else re-anchors until the next keystroke — the ghost floats
        // over unrelated content. Dismiss on scroll like on click. A PASSIVE
        // NSEvent global monitor, never the CGEvent tap: an active tap would put
        // this process on the latency path of every scroll tick systemwide.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.suggestionWindow.isVisible || self.mirrorWindow.isVisible else { return }
                self.dismissOverlays()
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
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
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
        // until focus moves elsewhere (the reference app's Esc semantics). The key still
        // passes through — apps use Esc for their own dismissals.
        if keyCode == Self.kEscape {
            if currentSuggestion != nil {
                escSuppressedFieldRect = currentFieldRect ?? .infinite
                escSuppressedAt = Date()
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

        // Ghost work is DEFERRED off the tap callback. This closure runs inside
        // the CGEventTap callback, and the OS delays delivering the keystroke to
        // the frontmost app until we return — so anything slow here is felt as
        // system-wide typing lag (observed in Safari). typeThrough does AX caret
        // reads and overlay window renders; none of them affect the swallow
        // decision (this path always passes the key through), so hop them onto
        // the next main-runloop tick. main.async is FIFO, so per-keystroke
        // ordering is preserved.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Type-through: the user typed exactly what the ghost predicted
                // next — consume it from the ghost locally instead of killing the
                // suggestion and paying a full LLM round trip. A silent background
                // refresh is still scheduled so the model can extend/correct.
                if self.typeThrough(typed: typed) {
                    // Ghost-stability contract (reference parity): a keystroke the
                    // ghost absorbed keeps the SAME ghost. Scheduling a refresh here
                    // swapped it for a different temp-1.0 sample every ~200ms while
                    // the user was following it — pure flicker (live trace + user
                    // report). Provisional ghosts (requestBefore == nil) keep the
                    // model refresh so the LLM can replace them; a healthy LLM
                    // ghost running LOW gets EXTENDED in place instead — the model
                    // continues past the ghost's end and the words attach on the
                    // right, so the suggestion never runs dry and never swaps.
                    if self.requestBefore == nil {
                        self.scheduleSuggestion()
                    } else {
                        self.lastTypedAt = Date()
                        self.debounceTimer?.invalidate()
                        self.extendGhostIfRunningLow()
                    }
                    return
                }
                // Reverse type-through: a plain backspace restores the deleted
                // character onto the FRONT of the ghost, in place — deleting
                // must never trigger a different suggestion or flicker, only a
                // genuine mismatch may (user directive). ⌥/⌘/⌃-deletes remove
                // more than one char, so they fall through to the clear path.
                if keyCode == Self.kDelete, !optionHeld, !commandHeld, !controlHeld,
                   self.regrowGhostOnDelete() {
                    self.lastTypedAt = Date()
                    self.debounceTimer?.invalidate()
                    return
                }
                // Otherwise: hide the ghost and (re)schedule the model. Pure-LLM
                // ghosts — the instant lexicon guess was removed (reference-style):
                // its frequency-word output read as junk next to model completions,
                // and with the frozen-context prompt the burst ghost lands fast
                // enough to not need a placeholder. clearGhost, NOT clearSuggestion:
                // the in-flight burst usually anchors a prefix of the live text and
                // must be allowed to land + reconcile (see clearGhost). Deletes get
                // NO immediate burst: firing one re-rendered essentially the same
                // ghost the user was deleting away from ~300ms later ("old ghost
                // keeps coming back" — live report). While erasing, only the
                // debounced pause-snap runs, so the ghost returns once the user
                // settles.
                // Deletes get no burst (the just-deleted ghost would come right
                // back) — EXCEPT over a typo fix: the user is deleting toward
                // the typo, and the recomputed fix is local (spell checker, no
                // LLM wait), so make it reappear immediately instead of after
                // the debounce pause.
                let wasFix = self.isFix
                self.clearGhost()
                self.scheduleSuggestion(allowBurst: keyCode != Self.kDelete || wasFix)
            }
        }
        return false
    }

    /// True when only whitespace sits between the caret and the end of its
    /// line — the ONLY caret position where a ghost may render. Empty tail and
    /// trailing spaces count; any letter/punctuation before the newline is
    /// mid-sentence. `nonisolated` + pure for unit tests.
    nonisolated static func caretAtLineEnd(after: String) -> Bool {
        for ch in after {
            if ch.isNewline { return true }
            if !ch.isWhitespace { return false }
        }
        return true
    }

    /// reference parity: as the user types toward the END of a healthy ghost,
    /// ask the model to continue PAST it (prompt = live text + remaining ghost —
    /// a warm KV prefix, so this is cheap) and append the words to the same
    /// ghost. The suggestion stays long instead of running dry and being
    /// swapped for a fresh (different) answer at the worst moment. One request
    /// per ghost state; capped so an accepted-word walk can't grow the ghost
    /// without bound.
    private func extendGhostIfRunningLow() {
        guard let ghost = currentSuggestion, !ghost.isEmpty,
              !isFix, replaceLength == 0,
              let anchor = requestBefore,
              // Single-flight: a live request (recall-ghost refresh, typo-fix
              // carry-over) already owns `requestToken`/`completionTask` — firing
              // an extension under the SAME token would leak that task uncancelled
              // and let two callbacks land for one token. Let it finish; the next
              // type-through re-attempts the extension.
              inFlightAnchor == nil,
              ghost.count < 160 else { return }
        let remainingWords = ghost.split(whereSeparator: { $0.isWhitespace }).count
        guard remainingWords < 4 else { return }
        let prompt = anchor + ghost
        guard prompt != ghostExtensionPrompt else { return }
        ghostExtensionPrompt = prompt
        let token = requestToken
        completionTask = CoreBridge.complete(
            before: prompt, after: "",
            bundleId: requestBundleId, caretScreenRect: currentCaretRect,
            burst: true
        ) { [weak self] cont in
            // The append stays valid even if more of the ghost was typed through
            // meanwhile (the extension continues past the ghost's END) — it is
            // only stale once the ghost was replaced or cleared.
            guard let self, token == self.requestToken,
                  let cont, !cont.isEmpty,
                  let current = self.currentSuggestion, !current.isEmpty,
                  !self.isFix, ghost.hasSuffix(current) else { return }
            let spaced = Self.applyWordBoundary(before: prompt, suggestion: cont)
            guard !spaced.isEmpty else { return }
            self.currentSuggestion = current + spaced
            Self.e2elog("extend ghost +=\"\(spaced.prefix(24))\"")
            if self.mirrorWindow.isVisible, let field = self.currentFieldRect {
                self.mirrorWindow.show(text: current + spaced, fieldRect: field)
            } else {
                self.suggestionWindow.extendGhost(appending: spaced)
            }
        }
    }

    /// Attempts to consume `typed` from the front of the live suggestion.
    /// Returns true when the ghost absorbed the keystroke (suggestion remains
    /// visible, advanced past the typed text). On a mismatch it returns false —
    /// the caller clears and reschedules. (An instant lexicon "snap" used to
    /// re-predict the word here; it was removed with the rest of the lexicon
    /// ghosts.)
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
            // Anchored ghost: the typed prefix goes transparent IN PLACE — no
            // AX read, no width arithmetic, nothing on screen moves. (Mirror
            // bubbles re-render; they live above the field, not on the line.)
            if mirrorWindow.isVisible, let field = currentFieldRect {
                mirrorWindow.show(text: remainder, fieldRect: field)
            } else {
                suggestionWindow.consumeGhost(by: typed.count)
            }
            return true
        }

        // Mismatch: fall through to clear + reschedule. (The lexicon "snap" that
        // used to re-predict the word here was removed with the rest of the
        // lexicon ghosts — pure-LLM, reference-style; the mismatch burst refresh
        // is the replacement.)
        return false
    }

    /// Reverse of typeThrough: a plain backspace prepends the just-deleted
    /// character back onto the ghost and shifts it left — the ghost regrows in
    /// place instead of vanishing and being replaced by a fresh (flickering)
    /// suggestion. Returns false when there is no healthy anchored LLM ghost to
    /// regrow, or the restored character would not render inline (newline).
    private func regrowGhostOnDelete() -> Bool {
        guard let suggestion = currentSuggestion, !suggestion.isEmpty,
              !isFix, replaceLength == 0,
              requestBefore != nil, // LLM ghost with a known anchor
              let anchor = lastRenderedBefore,
              let restored = anchor.last,
              !restored.isNewline
        else { return false }
        lastRenderedBefore = String(anchor.dropLast())
        requestBefore = requestBefore.map { String($0.dropLast()) }
        let grown = String(restored) + suggestion
        currentSuggestion = grown
        if mirrorWindow.isVisible, let field = currentFieldRect {
            mirrorWindow.show(text: grown, fieldRect: field)
        } else if !suggestionWindow.unconsumeGhost() {
            // Deleting past the ghost's birth point: the anchored panel has no
            // consumed prefix left to reveal, so re-anchor one character to the
            // left. Width arithmetic is acceptable here — this is the rare tail
            // of a delete-run, and the next response re-anchors from live AX.
            if var rect = currentCaretRect {
                let width = (String(restored) as NSString)
                    .size(withAttributes: [.font: suggestionWindow.currentFont]).width
                rect.origin.x -= width
                currentCaretRect = rect
                suggestionWindow.show(text: grown, at: rect, fieldRect: currentFieldRect)
            }
        }
        return true
    }

    // MARK: - Suggestion flow (main thread)

    private func scheduleSuggestion(allowBurst: Bool = true) {
        lastTypedAt = Date()
        debounceTimer?.invalidate()
        // B2 instant swap (opt-in): if the just-typed text diverges from the shown
        // ghost into a buffered alternate, show that alternate NOW — no model round
        // trip. Rendered provisional (requestBefore=nil) so the debounced model pass
        // below still refreshes/reconciles. No-op unless n-best populated the buffer.
        tryCandidateSwap()
        // Zero built-in waiting: the user must NEVER have to pause typing for a
        // ghost to appear. When no request is in flight, fire the fast burst rung
        // IMMEDIATELY on the keystroke — the first ghost costs pure model latency,
        // no debounce. While one is in flight, the single-flight gate inside
        // requestSuggestion queues a refire that chains the moment it lands, so
        // continuous typing gets a fresh completion every ~gen-latency with at
        // most one generation on the GPU at a time. (`allowBurst: false` on
        // deletes — see the keystroke handler.)
        if allowBurst, inFlightAnchor == nil || Date().timeIntervalSince(inFlightSince) >= 3.0 {
            requestSuggestion(burst: true)
        }
        // Pause snap: once typing stops for a debounce gap, run the FULL retry
        // ladder for a quality pass (bursts run only the fast first rung). If the
        // burst is still in flight when this fires, the gate converts it into a
        // queued refire; the refire itself picks burst-vs-full by how recently
        // the user typed (see completion callback).
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

    private func requestSuggestion(burst: Bool = false) {
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
        // The fieldless `.infinite` fallback matches every field, so it expires
        // after a short window instead of silencing everything until an app switch.
        if let suppressed = escSuppressedFieldRect {
            if suppressed == .infinite, Date().timeIntervalSince(escSuppressedAt) > 10 {
                escSuppressedFieldRect = nil
            } else if Self.sameField(suppressed, fieldRect) {
                recordNoShow(.escSuppressed)
                accessoryButton.setState(.idle)
                return
            } else {
                escSuppressedFieldRect = nil
            }
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
        if !typedShadow.isEmpty,
           !Self.spaceNormalized(before).hasSuffix(Self.spaceNormalized(typedShadow)) {
            if staleAXRetries < 3 {
                staleAXRetries += 1
                recordNoShow(.staleAX)
                scheduleSuggestion()
                return
            }
            typedShadow = "" // the app rewrote the text — trust the AX read
        }
        staleAXRetries = 0

        // End-of-line only (user directive: NEVER mid-sentence). A ghost in the
        // middle of existing text draws over it, and Right-arrow — an accept
        // key — is how people move the caret through a sentence. Anything other
        // than whitespace between the caret and the next newline suppresses;
        // text on LATER lines is fine (end of the current line is a valid spot).
        if !Self.caretAtLineEnd(after: context.textAfter) {
            recordNoShow(.midlineDisabled)
            return
        }
        // Mid-line completions preference keeps its stricter meaning: when
        // disabled, only suggest at end-of-FIELD (nothing but whitespace after).
        if !Preferences.midlineCompletionsEnabled,
           !context.textAfter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordNoShow(.midlineDisabled)
            return
        }

        // Pipelined single-flight: when a request is already in flight and the
        // user has only typed FORWARD since it fired, let it land — reconcile()
        // trims the consumed prefix, so the response is still showable. The old
        // cancel-on-every-fire meant continuous typing cancelled every response
        // before it arrived (ghosts only appeared on pause). A fresh request is
        // queued to fire the moment the in-flight one completes. The age bound
        // covers lost completions (cancelled tasks return without calling back).
        if let anchor = inFlightAnchor,
           Date().timeIntervalSince(inFlightSince) < 3.0,
           before.hasPrefix(anchor) {
            pendingRefire = before != anchor
            return
        }

        requestToken &+= 1
        // Past the single-flight gate: any in-flight request is now superseded.
        // Reset the pipeline state here so early-return branches below (emoji,
        // spelling-fix, typo-suppress) can't strand a stale anchor — the stale
        // callback hits the token guard before the anchor cleanup and would
        // otherwise leave the gate skip-firing with no task running.
        inFlightAnchor = nil
        pendingRefire = false
        completionTask?.cancel()
        let token = requestToken
        let bundleId = frontApp?.bundleIdentifier
        // Tier 3 (A1): when AX gives no usable caret but the app opts into text
        // mirroring, measure the caret glyph off-screen so the ghost anchors inline
        // instead of at the field's leading edge. Falls through to the synthetic
        // field-anchored caret (tier 2→field) when the mirror can't measure.
        var caretRect = Self.effectiveCaretRect(context.caretScreenRect, field: fieldRect)
        var usedGlyphMirror = false
        if !Self.hasUsableCaret(context.caretScreenRect),
           AppOverrideResolver.textMirroring(forBundleId: bundleId) == true,
           let field = fieldRect, let font = context.caretFont,
           let mirrored = GlyphMirror.caretRect(
               lineBefore: GlyphMirror.currentLine(of: context.textBefore),
               font: font, fieldRect: field) {
            caretRect = mirrored
            usedGlyphMirror = true
        }
        // Tier 4 (A3, opt-in): OCR caret anchoring when tiers 1-3 all failed
        // (terminals/TUIs). Async — captures + OCRs off the keystroke path, then
        // repositions the ghost at the OCR'd glyph box (like position-heal). Gated on
        // `ocrCaretAnchoring`; no-op by default. Only fires when there is still no
        // usable caret after the glyph mirror.
        if !usedGlyphMirror, !Self.hasUsableCaret(context.caretScreenRect),
           Preferences.ocrCaretAnchoring, let field = fieldRect {
            let line = GlyphMirror.currentLine(of: context.textBefore)
            let column = line.count
            Task { [weak self] in
                guard let anchor = await VisionContext.caretAnchor(
                    around: field, targetLine: line, column: column) else { return }
                await MainActor.run {
                    guard let self, token == self.requestToken else { return }
                    self.currentCaretRect = anchor
                    if let ghost = self.currentSuggestion, !ghost.isEmpty {
                        self.renderSuggestion(text: ghost, caret: anchor, field: field, useMirror: false)
                    }
                }
            }
        }
        currentFieldRect = fieldRect
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
        // The inline glyph mirror (tier 3) supersedes the bubble: when it produced a
        // real inline caret, the ghost renders in place, so don't also float a bubble.
        let useMirror = !usedGlyphMirror && Self.shouldUseMirror(
            caret: context.caretScreenRect, field: fieldRect, bundleId: bundleId
        )

        // reference-style indicator: pin a small icon to the leading edge of the
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
        // a completion that would extend a likely typo. BUT never treat a word the
        // user is mid-typing as a typo when it's a valid prefix of real words
        // ("conv" → conversation) — that was suppressing all mid-word completions.
        if Self.lastWordLooksSuspicious(before), !Self.lastWordIsCompletablePrefix(before) {
            if Preferences.showSuggestedFixes,
               let (_, original, fix) = Self.spellingFix(before) {
                // Per-letter diff (reference-style): a red line strikes only the
                // typed letters that will be retyped (from the first divergent
                // character), the replacement letters render green at the caret.
                // Accept mechanics follow the same split — backspace just the
                // divergent tail, not the whole word.
                let split = Self.typoFixSplit(original: original, fix: fix)
                // Gray continuation after the green correction (reference-style:
                // the fix flows into the rest of the sentence). Source order:
                // the recall buffer on the CORRECTED text (instant, the user's
                // own recent phrasing), else a chained LLM request below.
                let corrected = String(before.dropLast(original.count)) + fix
                let recallCont = RecentSentences.shared.continuation(
                    for: corrected, bundleId: bundleId)
                let continuation = recallCont.map {
                    Self.applyWordBoundary(before: corrected, suggestion: $0)
                } ?? ""
                currentSuggestion = split.replacement + continuation
                replaceLength = split.replaceLength
                isFix = true
                requestBefore = nil  // WS6: typo fixes are not training samples
                currentCaretRect = caretRect
                if useMirror, let fieldRect {
                    // No usable caret to strike through inline — mirror the proposed
                    // correction text into the bubble above the field instead.
                    mirrorWindow.show(text: fix + continuation, fieldRect: fieldRect)
                } else if let rect = caretRect {
                    suggestionWindow.showFix(
                        strike: split.strike, replacement: split.replacement,
                        continuation: continuation, at: rect, fieldRect: fieldRect
                    )
                }
                // No recall hit: chain the model on the corrected text so the
                // ghost continues the FIXED word ("brw"→"own" + " fox jumped…").
                // Guarded by the request token; rendered only while the same
                // typo is still on screen.
                if continuation.isEmpty {
                    let token = requestToken
                    completionTask = CoreBridge.complete(
                        before: corrected, after: context.textAfter,
                        bundleId: bundleId, caretScreenRect: caretRect,
                        fieldLabel: context.fieldLabel, windowTitle: context.windowTitle,
                        burst: true
                    ) { [weak self] cont in
                        guard let self, token == self.requestToken, self.isFix,
                              let cont, !cont.isEmpty,
                              let live = AXCaret.currentContext()?.textBefore,
                              live.hasSuffix(original) else { return }
                        let spaced = Self.applyWordBoundary(before: corrected, suggestion: cont)
                        self.currentSuggestion = split.replacement + spaced
                        if let rect = self.currentCaretRect {
                            self.suggestionWindow.showFix(
                                strike: split.strike, replacement: split.replacement,
                                continuation: spaced, at: rect, fieldRect: fieldRect
                            )
                        }
                    }
                }
                return
            }
            if Preferences.suppressOnTypo { recordNoShow(.suppressOnTypo); return }
        }

        applyAppearance(for: caretRect)

        // Carry-over from a typo-fix Tab (one-shot): the corrected word was just
        // injected and the gray continuation the user was reading becomes the
        // ghost immediately — no model round-trip, no surprise swap. The LLM
        // refresh still runs underneath; the stability guard (requestBefore set)
        // lets it only EXTEND this ghost, never replace it.
        if currentSuggestion == nil, let pending = pendingFixContinuation {
            // Scope + TTL: the carry-over belongs to the injection that armed it.
            // A bail path between arm and consume must not let it graft onto an
            // unrelated later word/field ("own " matching "brown "). Kept while
            // fresh and unmatched — one lagged AX read must not discard it.
            // NBSP-insertion hosts (per-app knobs) write the boundary space as
            // \u{00A0}; normalize before the suffix test or the chain silently
            // breaks in exactly the composers the fix targets.
            let normBefore = before.replacingOccurrences(of: "\u{00A0}", with: " ")
            let matches = normBefore.hasSuffix(pending.expectSuffix)
                || normBefore.hasSuffix(pending.expectSuffix.trimmingCharacters(in: .whitespaces))
            if Date().timeIntervalSince(pending.at) > 5 || pending.bundleId != requestBundleId {
                pendingFixContinuation = nil
            } else if matches {
                pendingFixContinuation = nil
                let spaced = Self.applyWordBoundary(before: before, suggestion: pending.text)
                currentSuggestion = spaced
                replaceLength = 0
                isFix = false
                requestBefore = before
                currentCaretRect = caretRect
                caretAnchoredAt = Date()
                lastRenderedBefore = before
                accessoryButton.setState(.ready)
                Self.e2elog("fix-carryover ghost=\"\(spaced.prefix(32))\"")
                renderSuggestion(text: spaced, caret: caretRect, field: fieldRect, useMirror: useMirror)
            }
        }

        // Recall (highest-priority source): people retype recently written
        // sentences — to a second person, or rewriting a line they deleted.
        // When the current fragment prefixes a recently written sentence, its
        // remainder is the user's OWN phrasing: render it INSTANTLY (no model
        // wait) and let the LLM refresh run underneath — the ghost-stability
        // guard keeps this ghost unless the model EXTENDS it.
        RecentSentences.shared.ingest(before: before, bundleId: bundleId)
        if currentSuggestion == nil,
           let recall = RecentSentences.shared.continuation(for: before, bundleId: bundleId) {
            let spaced = Self.applyWordBoundary(before: before, suggestion: recall)
            currentSuggestion = spaced
            replaceLength = 0
            isFix = false
            requestBefore = before // full-fledged ghost: model must not swap it
            currentCaretRect = caretRect
            caretAnchoredAt = Date()
            lastRenderedBefore = before
            accessoryButton.setState(.ready)
            Self.e2elog("recall ghost=\"\(spaced.prefix(32))\"")
            renderSuggestion(text: spaced, caret: caretRect, field: fieldRect, useMirror: useMirror)
        }

        // Word-finish rung (reference parity, live report 2026-07-03): the model
        // reliably fumbles long rare Cyrillic fragments ("прахосму" → restarts
        // with a fresh word), but the spelling dictionary knows the finish
        // ("качка"). Render the word remainder INSTANTLY; the LLM refresh
        // underneath may extend it but not swap it. Cyrillic-only: the model
        // finishes Latin fragments fine, and the old lexicon ghosts (removed)
        // read as junk precisely because they GUESSED — this only finishes the
        // word being typed. ponytail: first dictionary candidate wins; rank by
        // personalization n-grams if the pick quality bites.
        if currentSuggestion == nil,
           let remainder = Self.dictionaryWordFinish(before: before) {
            let spaced = Self.applyWordBoundary(before: before, suggestion: remainder)
            currentSuggestion = spaced
            replaceLength = 0
            isFix = false
            requestBefore = before // full-fledged ghost: model must not swap it
            currentCaretRect = caretRect
            caretAnchoredAt = Date()
            lastRenderedBefore = before
            accessoryButton.setState(.ready)
            Self.e2elog("word-finish ghost=\"\(spaced.prefix(32))\"")
            renderSuggestion(text: spaced, caret: caretRect, field: fieldRect, useMirror: useMirror)
        }

        // LLM request in flight: pulse the indicator so the user can see Prosper
        // is thinking (vs. having decided to stay quiet).
        if currentSuggestion == nil { accessoryButton.setState(.thinking) }

        let requestStart = Date()
        // Any diverged in-flight generation was already cancelled at the token
        // bump above (CoreBridge.complete checks Task.isCancelled + cancels the
        // server-side generation, so the stale one stops prefill/decode at once).
        inFlightAnchor = before
        inFlightSince = requestStart
        pendingRefire = false
        completionTask = CoreBridge.complete(
            before: before, after: context.textAfter,
            bundleId: bundleId, caretScreenRect: caretRect,
            fieldLabel: context.fieldLabel, windowTitle: context.windowTitle,
            burst: burst,
            onCandidates: { [weak self] buffer in self?.candidateBuffer = buffer }
        ) { [weak self] suggestion in
            guard let self else { return }
            // Single-flight: ignore stale responses.
            guard token == self.requestToken else { self.recordNoShow(.staleResponseToken); return }
            // This request is no longer in flight; if forward typing queued a
            // refresh while it ran, fire that refresh after this response is
            // processed (whether or not it produced a showable ghost).
            self.inFlightAnchor = nil
            let refire = self.pendingRefire
            self.pendingRefire = false
            // Closure-level defer: runs on EVERY exit path below, after the
            // response is fully processed, so the queued refresh never races the
            // state mutations of this one. Burst while the user is still typing
            // (fast rung, chains the pipeline); full ladder once they paused
            // (quality pass). Direct requestSuggestion — scheduleSuggestion would
            // stamp lastTypedAt and misread the refire as a keystroke.
            defer {
                if refire {
                    let stillTyping = Date().timeIntervalSince(self.lastTypedAt) < Self.debounceMaxWait
                    self.requestSuggestion(burst: stillTyping)
                }
            }
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
                    // "Nothing to suggest" is a normal outcome, not a failure —
                    // never surface the orange error badge for it. The counter
                    // above keeps the telemetry; the badge stays quiet.
                    self.accessoryButton.setState(.idle)
                } else {
                    // A still-valid ghost is on screen: drop the .thinking spinner
                    // back to .ready instead of leaving it stuck until next fire.
                    self.accessoryButton.setState(.ready)
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
            if !self.typedShadow.isEmpty,
               !Self.spaceNormalized(liveBefore).hasSuffix(Self.spaceNormalized(self.typedShadow)) {
                self.recordNoShow(.staleAX)
                Self.e2elog("stale-AX reschedule: live=\"\(liveBefore.suffix(24))\" shadow=\"\(self.typedShadow.suffix(12))\"")
                // Same quiet-reschedule rule as reconcile-.reschedule below: a
                // visible ghost stays; no burst (the causing keystroke burst).
                if self.currentSuggestion == nil {
                    self.scheduleSuggestion(allowBurst: false)
                }
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
                // A stale response must never SWAP a live ghost, and its
                // reschedule must not burst: the keystroke that caused the
                // divergence already fired its own burst, and during a
                // delete-run (regrow keeps the ghost, anchor extends live →
                // reschedule) an immediate burst here replaced the regrown
                // ghost with an unrelated suggestion mid-erase (live report:
                // retyping the ghost's own next char after deleting swapped
                // the whole ghost). Healthy visible ghost → just stay quiet.
                if self.currentSuggestion == nil {
                    self.scheduleSuggestion(allowBurst: false)
                }
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
            // Live-echo guard: sanitizeCompletion's echo guards compared against
            // the REQUEST-time text; when AX lagged the keyboard, the words the
            // user typed last were missing from it, so a suggestion that echoes
            // exactly those words sails through and renders the user's own text
            // as a ghost (observed live in Bulgarian). Re-run the echo checks
            // against the RENDER-time text. Decline without rescheduling (same
            // reasoning as midWord: the text is unchanged, a refire would loop).
            if CoreBridge.echoesLiveContext(spaced, liveBefore: liveBefore) {
                Self.e2elog("suppress: echoes live text \"\(spaced.prefix(24))\"")
                self.recordNoShow(.liveEcho)
                if self.currentSuggestion == nil { self.accessoryButton.setState(.idle) }
                return
            }
            // Mid-word guard (P0.3): the caret sits against an unfinished word but
            // the model started a NEW word ("wri" + " recording"). Inserting it
            // would orphan the fragment. Don't error+clear (that destroys a kept
            // ghost and flashes a scary badge for a routine case) — just decline
            // this new-word suggestion and re-request; the accept-guard protects
            // any ghost left on screen.
            // ponytail: skipped the lexicon "try-align" remedy — the snap already
            // runs on the hot path in typeThrough(); add it here only if mid-word
            // misses prove common.
            // Typo-tolerant conversion BEFORE the suppression below: when the
            // new word the model wants to start is a close edit of the broken
            // trailing token ("fx" + " fox jumps…"), it isn't junk to hide —
            // it is the correction, shown as strike + green + gray.
            if let conv = Self.typoFixFromSuggestion(before: liveBefore, spaced: spaced) {
                Self.e2elog("typo-convert: \"\(liveBefore.suffix(8))\" → \(conv.fixWord)")
                self.currentSuggestion = conv.replacement + conv.continuation
                self.replaceLength = conv.replaceLength
                self.isFix = true
                self.requestBefore = nil // fixes are not training samples
                self.currentCaretRect = liveCaret
                self.caretAnchoredAt = Date()
                self.lastRenderedBefore = liveBefore
                self.accessoryButton.setState(.ready)
                if liveMirror, let field = liveField {
                    self.mirrorWindow.show(text: conv.fixWord + conv.continuation, fieldRect: field)
                } else if let rect = liveCaret {
                    self.suggestionWindow.showFix(
                        strike: conv.strike, replacement: conv.replacement,
                        continuation: conv.continuation, at: rect, fieldRect: liveField
                    )
                }
                return
            }
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
            // Ghost-stability contract, response side: while the user is actively
            // consuming a healthy LLM ghost (type-through keeps lastRenderedBefore
            // anchored at the live text), an in-flight refresh landing now must
            // NOT swap it for a different sample — that mid-flight text swap is
            // the flicker users notice. Lexicon ghosts (requestBefore == nil) stay
            // replaceable: they are provisional guesses awaiting the model.
            // An EXTENSION of the visible ghost falls through to render: the
            // prefix on screen stays put and new characters appear on the
            // right — an in-place update, not a swap, so no flicker.
            // NO nearly-exhausted escape: it let a landing response swap any
            // short (<2-word) anchored ghost — exactly the BG word-finish /
            // recall ghosts — ~1s after the keystroke with the user idle
            // ("first suggestion looked better", live report). Run-dry is
            // handled by extendGhostIfRunningLow appending in place; a swap
            // is never the right refresh for a ghost the text still matches.
            if let ghost = self.currentSuggestion, !ghost.isEmpty,
               self.requestBefore != nil, spaced != ghost,
               !spaced.hasPrefix(ghost),
               self.lastRenderedBefore.map(Self.spaceNormalized) == Self.spaceNormalized(liveBefore) {
                Self.e2elog("keep ghost: \"\(ghost.prefix(24))\" over \"\(spaced.prefix(24))\"")
                self.recordNoShow(.ghostStable)
                // The kept ghost is live — leaving the button in .thinking would
                // pulse forever since this response is the one that would clear it.
                self.accessoryButton.setState(.ready)
                // POSITION HEAL: the guard keeps the ghost's TEXT, but the panel
                // may sit on a bad anchor (a degenerate re-anchor once parked the
                // ghost 20 lines below and this early-return preserved it for
                // seconds). When the live caret disagrees materially with the
                // cached anchor, re-render the SAME text at the live caret —
                // content is unchanged, so this cannot flicker, only relocate.
                if let live = liveCaret, Self.hasUsableCaret(live),
                   let cached = self.currentCaretRect,
                   abs(live.maxX - cached.maxX) > 4 || abs(live.midY - cached.midY) > max(cached.height, 1) * 0.6 {
                    self.currentCaretRect = live
                    self.currentFieldRect = liveField
                    self.caretAnchoredAt = Date()
                    self.renderSuggestion(text: ghost, caret: live, field: liveField, useMirror: liveMirror)
                }
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
            self.caretAnchoredAt = Date() // fresh AX anchor (see advanceGhost)
            self.lastRenderedBefore = liveBefore // arms type-through for this ghost
            Self.e2elog("render ghost=\"\(spaced.prefix(32))\"")
            self.renderSuggestion(text: spaced, caret: liveCaret, field: liveField, useMirror: liveMirror)
        }
    }

    /// B2 instant swap: when the buffered n-best set holds an alternate that still
    /// validly continues the live text, render it immediately as a provisional ghost
    /// (no model round trip). Provisional means `requestBefore == nil`, so the
    /// debounced model pass may replace it and the ghost-stability contract treats it
    /// as a replaceable guess. No-op when the buffer is empty (n-best off), when
    /// nothing matches, or when the alternate is already what's shown.
    private func tryCandidateSwap() {
        guard let buffer = candidateBuffer,
              let context = AXCaret.currentContext() else { return }
        let before = context.textBefore
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Yield to the higher-priority sources (fix-carryover, recall): both are
        // nil-guarded on `currentSuggestion` in `requestSuggestion`, which runs
        // AFTER this — a provisional candidate landing first would block the
        // user's own phrasing for the keystroke and churn when the LLM swaps it.
        guard pendingFixContinuation == nil,
              RecentSentences.shared.continuation(for: before, bundleId: bundleId) == nil
        else { return }
        guard let swap = buffer.bestMatching(currentBefore: before), !swap.isEmpty,
              swap != currentSuggestion else { return }
        let field = context.fieldScreenRect
        let caret = Self.effectiveCaretRect(context.caretScreenRect, field: field)
        let useMirror = Self.shouldUseMirror(
            caret: context.caretScreenRect, field: field,
            bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        currentSuggestion = swap
        requestBefore = nil          // provisional — replaceable by the model pass
        replaceLength = 0
        isFix = false
        lastRenderedBefore = before
        currentCaretRect = caret
        currentFieldRect = field
        caretAnchoredAt = Date()
        accessoryButton.setState(.ready)
        Self.e2elog("candidate swap → \"\(swap.prefix(24))\"")
        renderSuggestion(text: swap, caret: caret, field: field, useMirror: useMirror)
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
        inFlightAnchor = nil     // cancelled tasks never call back; unblock the next fire
        pendingRefire = false
        candidateBuffer = nil    // B2: hard-invalidate the n-best swap buffer
        clearGhost()
    }

    /// Hide the ghost and reset render state WITHOUT cancelling the request
    /// pipeline. Ordinary typing with no (or a mismatching) ghost lands here:
    /// the in-flight completion usually anchors a PREFIX of the live text, so
    /// hard-cancelling it (the old clearSuggestion on this path) killed every
    /// burst mid-prefill during continuous typing — the first ghost could only
    /// appear after the user stopped. Left alive, the response reconciles
    /// against the live text (trims the typed delta) and shows mid-typing;
    /// a genuinely diverged response reconciles to `.reschedule` and renders
    /// nothing (so deletes still never resurrect a stale ghost).
    private func clearGhost() {
        currentSuggestion = nil
        currentCaretRect = nil
        currentFieldRect = nil
        replaceLength = 0
        isFix = false
        // Every fresh ghost gets its own A/B accept credit — recall/carryover/
        // candidate ghosts re-enter through here, and without the reset a prior
        // accepted LLM ghost swallowed their accepts (under-counted telemetry).
        abAcceptedForCurrent = false
        lastRenderedBefore = nil
        ghostExtensionPrompt = nil
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
        candidateBuffer = nil    // B2: the accepted text changes context; drop alternates
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
        insert(suggestion, bundleId: bundleId)
        // Accepting a typo fix leaves the caret after the corrected word with no
        // ghost — chain straight into a completion so the continuation appears
        // immediately (reference-style: correction flows into the next words).
        if wasFix { scheduleSuggestion() }
    }

    /// Inserts text via the per-app insertion path: synthesized unicode typing,
    /// or a clipboard-paste fallback for apps flagged "improve compatibility".
    private func insert(_ string: String, bundleId: String?) {
        // Synthetic insertion extends the field's text exactly like typing would,
        // but the tap skips our own events — mirror it into the typed shadow so
        // the stale-AX check keeps matching after an accept.
        typedShadow += string
        if typedShadow.count > 64 { typedShadow = String(typedShadow.suffix(64)) }

        // A2 insertion workarounds (chat/web composers). Non-breaking-space
        // substitution happens up front so both paths carry it; the remaining
        // knobs branch inside the two insertion paths.
        let knobs = AppOverrideResolver.insertionKnobs(forBundleId: bundleId)
        var toInsert = string
        if knobs.nonBreakingSpace {
            toInsert = toInsert.replacingOccurrences(of: " ", with: "\u{00A0}")
        }
        // Lone-space accept in a mention-picker field: a real Space keypress is the
        // only thing that advances it (a pasted/unicode space is swallowed).
        if knobs.spaceKeyEvent, string == " " {
            sendSpaceKey()
            return
        }
        if Preferences.usesCompatInsertion(forBundleId: bundleId) {
            pasteString(toInsert, knobs: knobs)
        } else {
            typeString(toInsert, chunkSize: knobs.injectionChunkSize)
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
    /// Whether a fresh AX caret read is consistent with the keystroke that just
    /// happened: the caret must have moved at least ~40% of the typed width in
    /// the key's direction (real advances land near 100%; a stale pre-key read
    /// sits at ~0 ± a pt of jitter), or jumped lines (wrap / newline). Pure +
    /// `nonisolated` so it is unit-testable off the actor.
    nonisolated static func caretMovedWithKey(from old: CGRect?, to fresh: CGRect, shift: CGFloat) -> Bool {
        guard let old else { return true } // no baseline to distrust against
        let dy = abs(fresh.midY - old.midY)
        let lineH = max(old.height, 1)
        if dy > lineH * 0.6 {
            // A single keystroke can wrap at most a line or two. A caret that
            // "jumped" much farther is a degenerate AX read (live: a delete
            // re-anchored the ghost 20 lines below the text and it stuck).
            return dy <= lineH * 2.5
        }
        let moved = fresh.maxX - old.maxX
        return shift >= 0 ? moved >= shift * 0.4 : moved <= shift * 0.4
    }

    /// Hosts don't always store the exact space character we typed or injected:
    /// contenteditable editors keep word separators as NBSP, and the A2
    /// `nonBreakingSpace` insertion knob types one on purpose — so an AX re-read
    /// can differ from our bookkeeping by space KIND alone (live Telegram: every
    /// Tab after the first accept swallowed forever, "…е\u{00A0}" ≠ "…е ").
    /// Space kind is never a real divergence — normalize before COMPARING only,
    /// never before rendering or inserting.
    nonisolated static func spaceNormalized(_ s: String) -> String {
        s.contains("\u{00A0}") ? s.replacingOccurrences(of: "\u{00A0}", with: " ") : s
    }

    nonisolated static func reconcile(suggestion: String, anchor rawAnchor: String, live rawLive: String) -> ReconcileOutcome {
        // NBSP↔space is 1:1, so the normalized delta count still indexes `suggestion`.
        let anchor = spaceNormalized(rawAnchor), live = spaceNormalized(rawLive)
        if live == anchor { return .show(suggestion) }
        if live.hasPrefix(anchor) {
            let delta = String(live.dropFirst(anchor.count))
            guard !delta.isEmpty, spaceNormalized(suggestion).hasPrefix(delta) else { return .reschedule }
            let remainder = String(suggestion.dropFirst(delta.count))
            return remainder.isEmpty ? .reschedule : .show(remainder)
        }
        return .reschedule
    }

    /// Splits a typo correction at the first divergent character. `strike` is the
    /// tail of what the user actually typed (gets the red strike line and the
    /// synthetic backspaces), `replacement` is the corrected tail (rendered green,
    /// typed on accept). Keeping the common prefix minimizes both the visual
    /// noise and the number of synthetic key events. Pure + `nonisolated` for
    /// unit tests.
    nonisolated static func typoFixSplit(
        original: String, fix: String
    ) -> (strike: String, replacement: String, replaceLength: Int) {
        let o = Array(original), f = Array(fix)
        var p = 0
        while p < o.count, p < f.count, o[p] == f[p] { p += 1 }
        // Pure tail deletion ("cattt" → "cat") would leave an empty replacement,
        // which downstream reads as "no suggestion" — back off one shared char so
        // the accept still has something to type.
        if p > 0, p == f.count { p -= 1 }
        let strike = String(o[p...])
        return (strike, String(f[p...]), strike.count)
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
        // Two-tier glue check. ASCII glue on a non-latinica context is judged
        // by the lexicon + the user's PRIMARY language: the auto-identifying
        // checker matches the token against every installed dictionary and
        // tolerated "bro"+"is" = "brois" (a word somewhere), gluing a new word
        // onto the previous one (live report: Tab after a typo fix wrote
        // "the quick brois "). Non-ASCII / latinica glue keeps auto-ID — the
        // primary-language path is what silently swallowed the space in
        // Cyrillic glue ("пак"+"всяко") on an English system.
        let checker = NSSpellChecker.shared
        let gluedIsWord: Bool
        if glued.allSatisfy({ $0.isASCII }), !CoreBridge.looksLikeTransliteratedBulgarian(before) {
            checker.automaticallyIdentifiesLanguages = false
            gluedIsWord = Lexicon.shared.isKnownWord(glued) || checker.checkSpelling(
                of: glued, startingAt: 0, language: nil, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        } else {
            checker.automaticallyIdentifiesLanguages = true
            gluedIsWord = checker.checkSpelling(
                of: glued, startingAt: 0, language: nil, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
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
        if lastWordLooksSuspicious(before) { return true }
        // A trailing token that is neither a known word nor a completable
        // prefix is broken even when it is too short for the typo machinery
        // ("tt" — under the 3-char floor, and the checker tolerates it). A
        // ghost that starts a NEW word after it endorses the junk
        // ("attached tt" + " test file"). Real short words (to/is/of) are
        // lexicon-known; latinica is exempt as everywhere else.
        var word = ""
        for ch in before.reversed() { if ch.isLetter { word.append(ch) } else { break } }
        let trailing = String(word.reversed())
        // Cyrillic fragment: an unfinished (unknown-bg) word followed by a NEW
        // spaced word orphans the fragment ("прахосму" + " работува" — live
        // report 2026-07-03). The dictionary word-finish rung supplies the good
        // ghost; suppress the model's new-word junk. Fails open without the bg
        // dictionary, like the sister-language gates.
        if trailing.count >= 4,
           trailing.unicodeScalars.allSatisfy({ (0x0400...0x04FF).contains($0.value) }),
           NSSpellChecker.shared.availableLanguages.contains("bg") {
            return NSSpellChecker.shared.checkSpelling(
                of: trailing.lowercased(), startingAt: 0, language: "bg", wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location != NSNotFound
        }
        guard trailing.count >= 2, trailing.allSatisfy({ $0.isASCII && $0.isLowercase }),
              !Lexicon.shared.isKnownWord(trailing),
              !CoreBridge.looksLikeTransliteratedBulgarian(before)
        else { return false }
        return !lastWordIsCompletablePrefix(before)
    }

    /// Typo-tolerant conversion (reference parity). The model often re-emits the
    /// word the user MEANT as a fresh word after a broken trailing token —
    /// "fx" + " fox jumps over…", "tt" + " test file". Rendered as-is that
    /// endorses the typo; suppressed it wastes a correct prediction. When the
    /// suggestion's first word is a close edit of the broken token, convert the
    /// whole thing into an inline correction: strike the divergent typed tail,
    /// green the corrected letters, gray the rest of the suggestion.
    static func typoFixFromSuggestion(
        before: String, spaced: String
    ) -> (strike: String, replacement: String, replaceLength: Int, continuation: String, fixWord: String)? {
        guard spaced.first == " " else { return nil }
        var word = ""
        for ch in before.reversed() { if ch.isLetter { word.append(ch) } else { break } }
        let trailing = String(word.reversed())
        guard trailing.count >= 2, trailing.count <= 12,
              trailing.allSatisfy({ $0.isASCII && $0.isLetter }),
              // Capitalized token = proper-noun signal (a name, a brand the
              // lexicon doesn't know) — never strike the user's deliberate word
              // red because the model emitted a near-spelling.
              trailing.first?.isUppercase != true,
              !Lexicon.shared.isKnownWord(trailing),
              !CoreBridge.looksLikeTransliteratedBulgarian(before) else { return nil }
        let rest = String(spaced.dropFirst())
        let (head, tail) = splitFirstWord(rest)
        let fixWord = head.trimmingCharacters(in: .whitespaces)
        guard fixWord.count >= trailing.count, fixWord.count <= trailing.count + 4,
              fixWord.allSatisfy({ $0.isLetter }),
              fixWord.first?.lowercased() == trailing.first?.lowercased(),
              editDistance(trailing.lowercased(), fixWord.lowercased()) <= 2,
              trailing.lowercased() != fixWord.lowercased() else { return nil }
        let split = typoFixSplit(original: trailing, fix: fixWord)
        guard !split.replacement.isEmpty else { return nil }
        let continuation = String(head.dropFirst(fixWord.count)) + tail
        return (split.strike, split.replacement, split.replaceLength, continuation, fixWord)
    }

    /// Plain Levenshtein, inputs already length-capped by the caller.
    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = x[i - 1] == y[j - 1]
                    ? prev[j - 1]
                    : Swift.min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// The trailing word deserves typo treatment: flagged by the system spell
    /// checker, OR a short all-ASCII lowercase token the checker tolerates as a
    /// known abbreviation ("tte" = transesophageal echo) but our lexicon doesn't
    /// know — provided the checker can propose a real-word correction, so
    /// intentional tokens (identifiers, nicknames) stay untouched. Transliterated
    /// Bulgarian is exempt: latinica words are all lexicon-unknown by nature.
    /// Live report driving this: "tte" showed no correction AND got a spaced
    /// garbage continuation — both gates keyed off the too-lenient checker.
    static func lastWordLooksSuspicious(_ before: String) -> Bool {
        if lastWordLooksMisspelled(before) { return true }
        var word = ""
        for ch in before.reversed() { if ch.isLetter { word.append(ch) } else { break } }
        let trailing = String(word.reversed())
        guard trailing.count >= 3, trailing.count <= 6,
              trailing.allSatisfy({ $0.isASCII && $0.isLowercase }),
              !Lexicon.shared.isKnownWord(trailing),
              // Session vocabulary: a token the user has already written in a
              // completed sentence ("dto", "impl", "repo") is their word, not a
              // typo — the checker-tolerated-junk branch must not strike it.
              !RecentSentences.shared.hasRecentWord(trailing),
              !CoreBridge.looksLikeTransliteratedBulgarian(before)
        else { return false }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (trailing as NSString).length)
        let guesses = checker.guesses(
            forWordRange: range, in: trailing, language: nil, inSpellDocumentWithTag: 0
        ) ?? []
        return guesses.contains { Lexicon.shared.isKnownWord($0.lowercased()) }
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

    /// True when the trailing fragment is a valid PREFIX of real words (the user is
    /// mid-typing a word, e.g. "conv" → conversation/convert), as opposed to a genuine
    /// typo ("teh"). Used to keep typo-suppression from silencing completions on the
    /// word the user is actively typing — the spell checker flags any incomplete word
    /// as "misspelled", which was suppressing every mid-word completion.
    /// Remainder that finishes the unfinished Cyrillic word at the caret via the
    /// Bulgarian spelling dictionary ("прахосму" → "качка"), or nil. Fires only
    /// on fragments long enough to be unambiguous typing (≥5 letters) that are
    /// not already a word themselves.
    static func dictionaryWordFinish(before: String) -> String? {
        let fragment = String(before.reversed().prefix(while: { $0.isLetter }).reversed())
        guard fragment.count >= 5,
              fragment.unicodeScalars.allSatisfy({ (0x0400...0x04FF).contains($0.value) })
        else { return nil }
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains("bg") else { return nil }
        func isWord(_ w: String) -> Bool {
            checker.checkSpelling(
                of: w, startingAt: 0, language: "bg", wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
        // A complete word needs no finishing — ghosting "та" after every full
        // word would be noise, not help.
        guard !isWord(fragment.lowercased()) else { return nil }
        let range = NSRange(location: 0, length: (fragment as NSString).length)
        let completions = checker.completions(
            forPartialWordRange: range, in: fragment, language: "bg",
            inSpellDocumentWithTag: 0
        ) ?? []
        let lower = fragment.lowercased()
        guard let word = completions.first(where: {
            $0.count > fragment.count && $0.lowercased().hasPrefix(lower)
        }) else { return nil }
        return String(word.dropFirst(fragment.count))
    }

    static func lastWordIsCompletablePrefix(_ before: String) -> Bool {
        var word = ""
        for ch in before.reversed() { if ch.isLetter { word.append(ch) } else { break } }
        let frag = String(word.reversed())
        guard frag.count >= 2 else { return false }
        // Use the SAME sources that actually produce completions (bundled lexicon +
        // OS spell checker), so this agrees with the lexicon snap. NSSpellChecker
        // alone misses common prefixes like "conv"; the bundled Lexicon has them.
        let fl = frag.lowercased()
        let lex = CompletionCandidates.derive(before: frag, after: "", lexicon: Lexicon.shared)
        if lex.words.contains(where: { $0.count > frag.count && $0.lowercased().hasPrefix(fl) }) {
            return true
        }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (frag as NSString).length)
        let completions = checker.completions(
            forPartialWordRange: range, in: frag, language: nil, inSpellDocumentWithTag: 0
        ) ?? []
        return completions.contains { $0.count > frag.count && $0.lowercased().hasPrefix(fl) }
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
        ) else { return nil }
        // Prefer a correction the lexicon knows as a common word ("tte" guesses
        // may lead with an abbreviation; the user almost always meant "the").
        let best = guesses.first { Lexicon.shared.isKnownWord($0.lowercased()) }
            ?? guesses.first
        guard let best, best.lowercased() != original.lowercased() else { return nil }
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
        if replaceLength > 0 {
            // Typo fix: Tab accepts ONLY the corrected word (live report: the
            // whole ghost including the gray continuation was injected).
            // Backspace the divergent typed tail, type the corrected word, then
            // re-suggest — the recall buffer usually re-serves the same
            // continuation instantly as a normal word-walkable ghost.
            if isFix, let suggestion = currentSuggestion, !suggestion.isEmpty {
                let (head, tail) = Self.splitFirstWord(suggestion)
                let replaceLen = replaceLength
                let bundleId = requestBundleId
                clearSuggestion()
                typedShadow = String(typedShadow.dropLast(replaceLen))
                sendBackspaces(replaceLen)
                CompletionStats.recordAccept(head)
                insert(head, bundleId: bundleId)
                if !tail.isEmpty {
                    pendingFixContinuation =
                        (expectSuffix: head, text: tail, bundleId: bundleId, at: Date())
                    scheduleSuggestion()
                }
                return
            }
            // Emoji replacements stay atomic — accept the whole thing.
            acceptCurrentSuggestion(); return
        }
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
           !(head.last?.isWhitespace ?? false),
           // A pure-punctuation final token (".") must not become ". " — the
           // trailing space is for continuing prose after a word.
           head.contains(where: { $0.isLetter || $0.isNumber }) {
            toInsert += " "
        }
        insert(toInsert, bundleId: bundleId)
        lastRenderedBefore = lastRenderedBefore.map { $0 + toInsert }

        requestToken &+= 1 // invalidate any in-flight request
        // A Tab-accept is not new input: a debounce timer still pending from the
        // last real keystroke would fire a full re-request right after the accept
        // and change the ghost the user is walking down (live report). Kill it —
        // post-accept the ghost may only shrink (consume) or grow (extend below).
        debounceTimer?.invalidate()
        pendingRefire = false
        if remainder.isEmpty {
            // The token bump already orphans any in-flight extend request; cancel
            // it too so the abandoned generation stops burning the GPU.
            completionTask?.cancel()
            currentSuggestion = nil
            suggestionWindow.hide()
            mirrorWindow.hide()
            return
        }
        currentSuggestion = remainder
        // Anchored ghost: the accepted word goes transparent IN PLACE and the
        // injected text fills the gap underneath — the remainder's glyphs never
        // move, so a Tab-walk down the suggestion is visually static (the old
        // render-then-reposition dance smeared and jiggled — live recordings).
        if mirrorWindow.isVisible, let field = currentFieldRect {
            mirrorWindow.show(text: remainder, fieldRect: field)
        } else {
            suggestionWindow.consumeGhost(by: head.count)
        }
        // A word-walk drains the ghost fast — top it up in place too.
        extendGhostIfRunningLow()
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

    /// Synthesizes typing of a string via CGEvent unicode keyboard events. The
    /// `chunkSize` knob mirrors the reference app's recovered string-injection override
    /// (A2/A4): `0` = post the whole string at once; `>1` = that many UTF-16 units
    /// per event (Qt/Telegram composers silently drop one large injection); `-1` =
    /// inject only the first word (+ its trailing whitespace) — for fields that choke
    /// on multi-word insertion and re-fetch a fresh suggestion each accept.
    private func typeString(_ string: String, chunkSize: Int = 0) {
        if chunkSize < 0 {
            postUnicode(Array(Self.splitFirstWord(string).head.utf16))
            return
        }
        let utf16 = Array(string.utf16)
        guard chunkSize > 0, utf16.count > chunkSize else {
            postUnicode(utf16)
            return
        }
        var i = 0
        while i < utf16.count {
            let end = min(i + chunkSize, utf16.count)
            postUnicode(Array(utf16[i..<end]))
            i = end
        }
    }

    /// Posts one keyDown/keyUp pair carrying `utf16` as its unicode payload, stamped
    /// with the self-marker so our own tap ignores it.
    private func postUnicode(_ utf16: [UInt16]) {
        guard !utf16.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
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

    /// Emits a real Space key CGEvent (A2 `spaceKeyEvent`): mention-picker fields
    /// only advance on a genuine keypress, not on a pasted/unicode space.
    private func sendSpaceKey() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let space: CGKeyCode = 49 // kVK_Space
        let down = CGEvent(keyboardEventSource: source, virtualKey: space, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: space, keyDown: false)
        down?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Custom pasteboard type stamped on our own writes so a clipboard-watching host
    /// (or our own restore) can tell our paste apart from user-copied text — the
    /// self-marker the reference app writes as `writeTextToPasteboardWithSelfMarker`.
    private static let selfMarkerPasteboardType =
        NSPasteboard.PasteboardType("com.prosper.autocomplete.self")

    /// Alternate insertion path for apps that mishandle synthesized unicode
    /// typing ("improve compatibility"): stash the text on the pasteboard and
    /// synthesize ⌘V (or ⌘⇧V for paste-and-match-style), restoring the previous
    /// clipboard afterward. Honors the A2 `pasteAndMatchStyle`/`backspaceAfterPaste`
    /// knobs and stamps a self-marker onto the pasteboard write.
    private func pasteString(_ string: String, knobs: AppOverrideResolver.InsertionKnobs = .init()) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(string, forType: .string)
        // Self-marker: our own bundle id under a private type. A host that watches
        // the clipboard can skip echoing text it can see we injected.
        pb.setString(Bundle.main.bundleIdentifier ?? "com.prosper.app",
                     forType: Self.selfMarkerPasteboardType)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        let flags: CGEventFlags = knobs.pasteAndMatchStyle
            ? [.maskCommand, .maskShift] : .maskCommand
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = flags
        down?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMagic)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)

        // Some editors append a stray char (newline/space) on programmatic paste —
        // clip it right back off.
        if knobs.backspaceAfterPaste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.sendBackspaces(1) }
            }
        }

        // Restore the prior clipboard shortly after the paste lands.
        if let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
    }
}
