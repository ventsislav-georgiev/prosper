import Carbon
import Foundation

// Phase 4 §D — declarative per-app key remapping evaluated inside the single shared
// CGEvent tap (AutocompleteEngine). The matcher (`KeyRuleEngine`) is pure and
// nonisolated so it unit-tests with no AppKit / no real keyboard; the live manager
// (`ExtensionKeyRules`) holds the registered rules + double-tap timing and is driven
// from the tap. NO Lua runs in the keystroke path — extensions register a declarative
// JSON rule set (from their `on_launch` handler) and the host evaluates it natively.

/// A pressed key + its four modifier states, in CGEvent-flag space (the form the tap
/// produces). Comparison is exact: a rule for `cmd+i` does not fire on `cmd+shift+i`.
struct KeyChord: Equatable, Sendable, Hashable {
    var keyCode: Int64
    var cmd: Bool
    var alt: Bool
    var ctrl: Bool
    var shift: Bool
    /// Set for an INCOMING media/system key (NX_KEYTYPE_* code) rather than a regular
    /// keyboard key. Media keys arrive on the systemDefined tap with no modifiers, so a
    /// media chord ignores the four flags and matches purely on this code. nil = a
    /// normal keyboard chord. (Media codes overlap real keyCodes — SOUND_UP=0 vs `a`=0 —
    /// so they MUST live in a separate namespace, never the keyCode field.)
    var mediaCode: Int?

    init(keyCode: Int64, cmd: Bool = false, alt: Bool = false, ctrl: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.cmd = cmd
        self.alt = alt
        self.ctrl = ctrl
        self.shift = shift
        self.mediaCode = nil
    }

    /// A media/system-key chord (PLAY, SOUND_UP, …). keyCode is unused (-1).
    init(mediaCode: Int) {
        self.keyCode = -1
        self.cmd = false; self.alt = false; self.ctrl = false; self.shift = false
        self.mediaCode = mediaCode
    }

    /// Build from a Carbon keyCode + modifier mask (kVK_* / cmdKey|optionKey|…),
    /// so a native `GlobalHotKey`'s chord can be compared against tap chords.
    init(carbonKeyCode: UInt32, carbonModifiers: UInt32) {
        self.init(keyCode: Int64(carbonKeyCode),
                  cmd: carbonModifiers & UInt32(cmdKey) != 0,
                  alt: carbonModifiers & UInt32(optionKey) != 0,
                  ctrl: carbonModifiers & UInt32(controlKey) != 0,
                  shift: carbonModifiers & UInt32(shiftKey) != 0)
    }

    /// Parse a combo string ("cmd+shift+i", "f8", "alt+down") via `KeyCombo.parse`,
    /// then split the Carbon modifier mask into the four booleans the tap compares.
    /// A `media:NAME` spec (or a bare media-key name) yields a media chord instead.
    init?(spec: String) {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        let mediaName = trimmed.lowercased().hasPrefix("media:")
            ? String(trimmed.dropFirst("media:".count)) : trimmed
        if let code = MediaKey.code(forName: mediaName) {
            self.init(mediaCode: code)
            return
        }
        guard let combo = KeyCombo.parse(spec) else { return nil }
        let m = combo.carbonModifiers
        self.init(
            keyCode: Int64(combo.keyCode),
            cmd: m & UInt32(cmdKey) != 0,
            alt: m & UInt32(optionKey) != 0,
            ctrl: m & UInt32(controlKey) != 0,
            shift: m & UInt32(shiftKey) != 0
        )
    }
}

/// What a matched rule does to the keystroke.
enum KeyRuleAction: Equatable, Sendable {
    /// Eat the original and inject this combo instead (devtools/tab-nav remaps).
    case remap(KeyChord)
    /// Eat the original and post a system/media key (PLAY, SOUND_UP, …).
    case system(String)
    /// Eat the original and launch / activate an app (bundle id or .app path).
    case launchApp(String)
    /// Eat the original, do nothing (disable a shortcut).
    case swallow
    /// First press is swallowed; a second press of the same chord within
    /// `doubleTapWindow` injects `target` (⌘Q-to-really-quit parity).
    case doubleTap(KeyChord)
    /// Eat the original and re-invoke a named Lua handler with `arg` on the owning
    /// extension's async lane (stateless, like a timer/event delivery). The escape
    /// hatch for a hotkey whose action is arbitrary Lua, not a chord/media rewrite —
    /// powers hammerspoon-compat's `hs.hotkey.bind` (the callback is real Lua code).
    /// NO Lua runs in the keystroke path itself: the tap only swallows + dispatches.
    case invoke(handler: String, arg: String)
}

/// One declarative remap rule. `apps`/`notApps` are bundle-id allow/deny filters
/// (nil = applies everywhere).
struct KeyRule: Equatable, Sendable {
    var chord: KeyChord
    var action: KeyRuleAction
    var apps: Set<String>?
    var notApps: Set<String>?
    /// Owning extension, stamped in `setRules`. Only consulted for `.invoke` (so the
    /// dispatch reaches the right extension's lane); nil for plain remap/swallow.
    var extensionID: String?

    /// True when this rule applies to a frontmost app with `bundleID` (nil = unknown
    /// frontmost app; an allow-list rule then does not apply).
    func applies(toBundleID bundleID: String?) -> Bool {
        if let apps {
            guard let bundleID, apps.contains(bundleID) else { return false }
        }
        if let notApps, let bundleID, notApps.contains(bundleID) { return false }
        return true
    }
}

/// The directive the tap acts on after consulting the rule set.
enum KeyRuleResolution: Equatable, Sendable {
    case passThrough          // no rule — let the key through untouched
    case swallow              // eat the key, inject nothing
    case inject(KeyChord)     // eat the key, inject this combo
    case system(String)       // eat the key, post this system/media key
    case launchApp(String)    // eat the key, launch / activate this app
    case invoke(extensionID: String, handler: String, arg: String)  // eat, dispatch Lua
}

/// Pure rule decoding + matching. No state, no side effects → fully unit-testable.
enum KeyRuleEngine {

    /// Decode a JSON array of rule objects. Unknown / malformed entries are skipped
    /// (an extension with one bad rule still gets its good ones). Shapes:
    ///   { "from": "cmd+shift+i", "to": "cmd+alt+i" }        → remap
    ///   { "from": "f8", "system": "PLAY" }                  → system key
    ///   { "from": "f5", "swallow": true }                   → swallow
    ///   { "from": "cmd+q", "double_tap": "cmd+q" }          → double-tap passthrough
    ///   { "from": "f1", "invoke": "hs_dispatch", "arg": "3" } → re-invoke a Lua handler
    /// optional on any: "apps": ["com.apple.Safari"], "not_apps": [...]
    static func decode(json: String) -> [KeyRule] {
        guard let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }

        return arr.compactMap { obj -> KeyRule? in
            guard let from = obj["from"] as? String, let chord = KeyChord(spec: from) else { return nil }
            let action: KeyRuleAction
            if let to = obj["to"] as? String, let target = KeyChord(spec: to) {
                // Remapping TO a media key posts a system key, not a keystroke.
                if let mc = target.mediaCode, let name = MediaKey.name(forCode: mc) {
                    action = .system(name)
                } else {
                    action = .remap(target)
                }
            } else if let app = obj["launch"] as? String, !app.isEmpty {
                action = .launchApp(app)
            } else if let sys = obj["system"] as? String, !sys.isEmpty {
                action = .system(sys.uppercased())
            } else if let dt = obj["double_tap"] as? String, let target = KeyChord(spec: dt) {
                action = .doubleTap(target)
            } else if let handler = obj["invoke"] as? String, !handler.isEmpty {
                let arg = (obj["arg"] as? String) ?? ""
                action = .invoke(handler: handler, arg: arg)
            } else if obj["swallow"] as? Bool == true {
                action = .swallow
            } else {
                return nil
            }
            let apps = (obj["apps"] as? [String]).map(Set.init)
            let notApps = (obj["not_apps"] as? [String]).map(Set.init)
            return KeyRule(chord: chord, action: action, apps: apps, notApps: notApps)
        }
    }

    /// First rule (in registration order) whose chord and app filter match.
    static func match(rules: [KeyRule], chord: KeyChord, bundleID: String?) -> KeyRule? {
        rules.first { $0.chord == chord && $0.applies(toBundleID: bundleID) }
    }
}

/// Live registry of extension key rules, consulted by the shared tap on every
/// keyDown. Rules are kept per-extension (so disabling one extension drops only its
/// rules) and flattened into a single ordered array for matching. MainActor-bound:
/// it is touched only from the tap callback (main run loop) and the host bridge.
@MainActor
final class ExtensionKeyRules {
    static let shared = ExtensionKeyRules()

    /// A second press of a double-tap chord within this window triggers the action.
    /// 0.5s matches the macOS double-click default and the de-facto Hammerspoon
    /// ⌘Q-to-quit snippet (`delay = 0.5`); a tighter window silently fails for a
    /// natural-cadence double-tap (the 2nd press lands late → re-swallowed forever).
    static let doubleTapWindow: TimeInterval = 0.5

    private var byExtension: [String: [KeyRule]] = [:]
    /// Rules bucketed by `keyCode` so the keystroke path only scans rules bound to the
    /// pressed key (typically 0–2), not the whole set — O(1) lookup + tiny scan.
    private var byKeyCode: [Int64: [KeyRule]] = [:]
    /// Media-key rules, bucketed by NX_KEYTYPE code. Kept apart from `byKeyCode` so the
    /// systemDefined tap can early-out via `hasMediaRules` and never touch media keys
    /// (volume HUD etc.) unless the user actually mapped one.
    private var byMediaCode: [Int: [KeyRule]] = [:]
    private var ruleCount = 0
    /// True when at least one rule triggers on an incoming media key — the only case
    /// where the systemDefined tap should inspect (and possibly swallow) media events.
    private(set) var hasMediaRules = false
    private var pendingDoubleTap: [KeyChord: UInt64] = [:]

    /// Chords claimed by native global hotkeys (`GlobalHotKey` / Carbon, incl. the
    /// app's own shortcuts and `[[contributes.keybindings]]`). An extension key rule
    /// on one of these PASSES THROUGH so the dedicated Carbon handler wins — the
    /// shared CGEvent tap fires before Carbon dispatch, so without this a shim
    /// `.invoke` rule for e.g. cmd+alt+ctrl+l (openlid) would swallow the chord and
    /// starve openlid's own hotkey (→ no toggle, no toast). Set by AppDelegate after
    /// hotkey registration; read in the hot path.
    private var reservedChords: Set<KeyChord> = []
    func setReservedChords(_ chords: Set<KeyChord>) {
        reservedChords = chords
        NSLog("prosper: ExtensionKeyRules reserved %d native-hotkey chord(s)", chords.count)
    }

    /// Replace one extension's rule set (called from its `on_launch`). Empty/!valid
    /// JSON clears that extension's rules.
    func setRules(extensionID: String, json: String) {
        var rules = KeyRuleEngine.decode(json: json)
        // Stamp the owner so an `.invoke` resolution can be dispatched to the right lane.
        for i in rules.indices { rules[i].extensionID = extensionID }
        if rules.isEmpty { byExtension[extensionID] = nil } else { byExtension[extensionID] = rules }
        rebuild()
        NSLog("prosper: ExtensionKeyRules.setRules ext=%@ decoded=%d total=%d", extensionID, rules.count, ruleCount)
        onRulesChanged?()
    }

    /// Re-invoke a named Lua handler with an arg on the owning extension's lane —
    /// set by the app to `ExtensionRegistry.deliverEvent`. (extensionID, handler, arg)
    var invoke: ((String, String, String) -> Void)?

    /// Fired (on the mutating thread) after the rule set changes, so the app can
    /// reconcile the shared keystroke tap's lifecycle: extension key rules need the
    /// tap running even when inline autocomplete is off (they share one tap).
    var onRulesChanged: (() -> Void)?

    func removeRules(extensionID: String) {
        guard byExtension[extensionID] != nil else { return }
        byExtension[extensionID] = nil
        rebuild()
        onRulesChanged?()
    }

    var isEmpty: Bool { ruleCount == 0 }

    private func rebuild() {
        // Stable concatenation in sorted extension order → deterministic match
        // precedence, then group by keyCode (Dictionary(grouping:) preserves order
        // within each bucket).
        let flat = byExtension.keys.sorted().flatMap { byExtension[$0] ?? [] }
        ruleCount = flat.count
        let media = flat.filter { $0.chord.mediaCode != nil }
        let keyboard = flat.filter { $0.chord.mediaCode == nil }
        byKeyCode = Dictionary(grouping: keyboard, by: { $0.chord.keyCode })
        byMediaCode = Dictionary(grouping: media, by: { $0.chord.mediaCode! })
        hasMediaRules = !media.isEmpty
    }

    /// Resolve an INCOMING media key (off the systemDefined tap). Returns `.passThrough`
    /// when no rule matches so the system's own handling (volume HUD, playback) is
    /// untouched. `.system`/`.inject`/`.launchApp`/`.swallow` mirror the keyboard path.
    func evaluateMedia(code: Int, bundleID: String?) -> KeyRuleResolution {
        guard let bucket = byMediaCode[code],
              let rule = bucket.first(where: { $0.applies(toBundleID: bundleID) }) else {
            return .passThrough
        }
        switch rule.action {
        case .remap(let target): return .inject(target)
        case .system(let name): return .system(name)
        case .launchApp(let app): return .launchApp(app)
        case .swallow: return .swallow
        case .doubleTap(let target): return .inject(target) // double-tap on media: treat as direct
        case .invoke(let handler, let arg):
            return .invoke(extensionID: rule.extensionID ?? "", handler: handler, arg: arg)
        }
    }

    /// Resolve a keystroke against the registered rules. `nowNanos` is injectable for
    /// tests; production passes the monotonic clock. `isRepeat` is set for an OS
    /// key-autorepeat event (a held key), which must NOT drive double-tap bookkeeping.
    /// Performs double-tap bookkeeping.
    func evaluate(chord: KeyChord, bundleID: String?, isRepeat: Bool = false,
                  nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) -> KeyRuleResolution {
        // A chord owned by a native global hotkey wins: pass through untouched so the
        // Carbon handler (which fires after this tap) gets it. Cheap when empty.
        if !reservedChords.isEmpty, reservedChords.contains(chord) {
            return .passThrough
        }
        guard ruleCount > 0, let bucket = byKeyCode[chord.keyCode],
              let rule = KeyRuleEngine.match(rules: bucket, chord: chord, bundleID: bundleID) else {
            return .passThrough
        }
        switch rule.action {
        case .remap(let target):
            return .inject(target)
        case .system(let name):
            return .system(name)
        case .launchApp(let app):
            return .launchApp(app)
        case .swallow:
            return .swallow
        case .doubleTap(let target):
            // Eat OS key-autorepeats of a HELD key: they arrive at ~the initial
            // repeat delay (~0.5s), i.e. inside the double-tap window, and would
            // otherwise consume/reset `pendingDoubleTap` so the real second press
            // looks like a fresh first — the user had to mash the key ~4x. Swallow
            // them without touching pending. (Only doubleTap cares; remap/swallow
            // intentionally still act on repeats so a held key keeps repeating.)
            if isRepeat { return .swallow }
            let windowNanos = UInt64(Self.doubleTapWindow * 1_000_000_000)
            if let first = pendingDoubleTap[chord], nowNanos &- first <= windowNanos {
                pendingDoubleTap[chord] = nil
                // Same chord as pressed (the ⌘Q-to-quit case): let the REAL key
                // through untouched rather than swallowing it and re-injecting a
                // synthetic copy — some apps ignore synthetic events for menu
                // shortcuts (so ⌘Q never actually quit). Only a DIFFERENT target
                // needs a synthetic injection.
                return target == chord ? .passThrough : .inject(target)
            }
            pendingDoubleTap[chord] = nowNanos
            return .swallow
        case .invoke(let handler, let arg):
            return .invoke(extensionID: rule.extensionID ?? "", handler: handler, arg: arg)
        }
    }
}
