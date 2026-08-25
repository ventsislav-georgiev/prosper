import AppKit
import Foundation
import IOKit
import IOKit.hidsystem

// Caps-Lock hyper key (plan #016). Caps Lock is remapped at the HID level to F18
// via `hidutil`, so the window server never sees a Caps Lock: no LED, no lock
// state, no activation delay — just an honest keyDown/keyUp pair with real
// timestamps. Holding it unions the configured modifiers onto whatever key is
// pressed next (so `hyper+H` is an ORDINARY `⌃⌥⌘⇧H` chord to the rule engine, the
// hammerspoon shim and the app). Tapping it alone runs a configurable lone action.
//
// Three layers, deliberately split so the interesting parts are testable without a
// keyboard or a live machine:
//   1. `HyperKeyState`   — pure state machine, injected nanos, no I/O.
//   2. `HyperKeyMapping` — pure `hidutil` table parse/merge/remove/serialise.
//   3. `HyperKey`        — the MainActor lifecycle that runs `hidutil` and IOKit.

// MARK: - Modifier mask

/// The hyper modifier set, stored in `UserDefaults` as a small stable bitmask of
/// our own (NOT `CGEventFlags.rawValue`, which is a platform detail we don't want
/// baked into a user's defaults plist).
enum HyperMods {
    static let cmd = 1
    static let alt = 2
    static let ctrl = 4
    static let shift = 8
    /// ⌃⌥⌘⇧ — the conventional "hyper" set, and the default.
    static let all = cmd | alt | ctrl | shift

    static func flags(_ mask: Int) -> CGEventFlags {
        var f: CGEventFlags = []
        if mask & cmd != 0 { f.insert(.maskCommand) }
        if mask & alt != 0 { f.insert(.maskAlternate) }
        if mask & ctrl != 0 { f.insert(.maskControl) }
        if mask & shift != 0 { f.insert(.maskShift) }
        return f
    }

    /// Display order matches how modifiers are conventionally written: ⌃⌥⇧⌘.
    static func glyphs(_ mask: Int) -> String {
        var s = ""
        if mask & ctrl != 0 { s += "\u{2303}" }
        if mask & alt != 0 { s += "\u{2325}" }
        if mask & shift != 0 { s += "\u{21E7}" }
        if mask & cmd != 0 { s += "\u{2318}" }
        return s
    }

    /// Toggle one modifier. Clearing the LAST remaining one is refused: a hyper key
    /// with no modifiers swallows Caps Lock and produces nothing, which reads as a
    /// broken keyboard. The UI relies on this rather than disabling checkboxes.
    static func toggled(_ mask: Int, bit: Int) -> Int {
        let next = mask ^ bit
        return next == 0 ? mask : next
    }
}

// MARK: - Lone-tap action

/// What a lone press of the hyper key does.
enum HyperSoloAction: String, CaseIterable, Sendable {
    case nothing
    case escape
    case toggleCapitals
    case inputSource

    var title: String {
        switch self {
        case .nothing: return "Nothing"
        case .escape: return "Escape"
        case .toggleCapitals: return "Toggle Capitals"
        case .inputSource: return "Switch Input Source"
        }
    }
}

/// The concrete effect the lifecycle layer performs. Distinct from the *configured*
/// action because the hold edge can override it (see `soloEffect`).
enum HyperSoloEffect: Equatable, Sendable {
    case escape
    case toggleCapitals
    case switchInputSource
}

// MARK: - Pure state machine

/// What the tap pre-pass saw. The tap knows only (type, keyCode, flags); this is
/// that, already classified, so the state machine never touches CoreGraphics.
enum HyperKeyInput: Equatable, Sendable {
    /// keyDown of the remapped trigger. `otherModifiers` = a real ⌘/⌥/⌃/⇧ was
    /// already held, which makes the press "not alone" from the very start.
    case triggerDown(isRepeat: Bool, otherModifiers: Bool)
    case triggerUp
    /// Any other key event (down or up) while the tap is live.
    case otherKey
    /// A REAL Caps Lock leaked through: `flagsChanged` with keyCode 57. Means some
    /// attached keyboard is not carrying our mapping (hot-plugged, or woke without it).
    case realCapsLock
    /// A ⌘/⌥/⌃/⇧ edge (`flagsChanged`, any other keyCode).
    case otherModifier
}

/// What the tap must do with the event it just classified.
enum HyperKeyDecision: Equatable, Sendable {
    /// Not ours — leave the event completely alone.
    case pass
    /// Drop it. The trigger key itself never reaches an app.
    case swallow
    /// Union the hyper flags into the real `CGEvent`, then carry on down the chain.
    case addModifiers
    /// The trigger was released after a lone press. Feed to `soloEffect`, then swallow.
    case solo(isHold: Bool, repeated: Bool)
    /// Re-apply the `hidutil` mapping and un-flip the lock state, then swallow.
    case repairMapping
}

struct HyperKeyState: Sendable {
    /// F18. Caps Lock (`0x700000039`) is remapped to it because F18 is in the HID
    /// standard (so the system delivers it like any other key) and no portable
    /// keyboard carries one.
    static let triggerKeyCode: Int64 = 79
    /// Real Caps Lock arrives as `flagsChanged` with this keyCode.
    static let capsLockKeyCode: Int64 = 57
    /// Lone press shorter than this is a tap; longer is a hold.
    static let holdThresholdNanos: UInt64 = 500_000_000
    /// A real Caps Lock leaking through re-applies the mapping at most this often —
    /// a keyboard that simply cannot be mapped must not spawn a `hidutil` per press.
    static let repairIntervalNanos: UInt64 = 3_000_000_000
    /// If the trigger's keyUp is never seen (tap torn down mid-hold, app suspended)
    /// every later key would silently gain the hyper flags. Any event this long
    /// after the press resets the machine instead. Cheap: one comparison, no timer.
    static let stuckHoldNanos: UInt64 = 10_000_000_000

    private var pressedAt: UInt64?
    private var alone = true
    private var repeated = false
    private var lastRepairAt: UInt64?

    var isHeld: Bool { pressedAt != nil }

    init() {}

    /// Drop all held state. Called when the feature is disabled, the tap stops, or
    /// the machine wakes — anything that could have eaten the trigger's keyUp.
    mutating func reset() {
        pressedAt = nil
        alone = true
        repeated = false
    }

    mutating func decide(_ input: HyperKeyInput, nowNanos: UInt64) -> HyperKeyDecision {
        // Stuck-modifier watchdog, ahead of everything: a press we never saw released.
        if let at = pressedAt, nowNanos &- at > Self.stuckHoldNanos, input != .triggerUp {
            reset()
        }

        switch input {
        case .realCapsLock:
            // Always swallow (the user asked for Caps Lock to be the hyper key), but
            // only pay for the repair once per interval.
            if let last = lastRepairAt, nowNanos &- last < Self.repairIntervalNanos {
                return .swallow
            }
            lastRepairAt = nowNanos
            return .repairMapping

        case let .triggerDown(isRepeat, otherModifiers):
            if isRepeat {
                // Autorepeat marks the press; it must NOT restart it, or a long hold
                // would keep looking like a fresh tap.
                repeated = true
                return .swallow
            }
            pressedAt = nowNanos
            alone = !otherModifiers
            repeated = false
            return .swallow

        case .triggerUp:
            guard let at = pressedAt else {
                // A release with no press: the tap came up mid-hold. Nothing to do.
                return .swallow
            }
            let wasAlone = alone
            let didRepeat = repeated
            reset()
            guard wasAlone else { return .swallow }
            return .solo(isHold: nowNanos &- at >= Self.holdThresholdNanos, repeated: didRepeat)

        case .otherKey:
            guard pressedAt != nil else { return .pass }
            alone = false
            return .addModifiers

        case .otherModifier:
            // A real modifier pressed while the trigger is held still means the press
            // was used, but the modifier event itself is none of our business.
            if pressedAt != nil { alone = false }
            return .pass
        }
    }

    /// Configured action × edge × autorepeat → what actually happens.
    ///
    /// - An autorepeating press was held long enough for the OS to repeat it, so the
    ///   user was using it as a modifier and just happened to press nothing: no action.
    /// - The HOLD edge always toggles capitals when anything is configured. It is the
    ///   fallback that keeps the physical key's original meaning reachable, and it is
    ///   what a later `inputSource` action (which needs a quick tap) falls back to.
    static func soloEffect(action: HyperSoloAction, isHold: Bool, repeated: Bool) -> HyperSoloEffect? {
        if repeated { return nil }
        switch action {
        case .nothing: return nil
        case .escape: return isHold ? .toggleCapitals : .escape
        case .toggleCapitals: return .toggleCapitals
        // Hold falls back to the capitals toggle: with Caps Lock remapped there is
        // no other way left to lock capitals, and a hold is a distinct gesture.
        case .inputSource: return isHold ? .toggleCapitals : .switchInputSource
        }
    }

    /// The source after `current`, wrapping. Pure — TIS hands in the enabled IDs,
    /// in the system's own order, so the cycling rule tests without a keyboard.
    /// `nil` when there is nothing to switch to.
    static func nextInputSourceID(in ids: [String], current: String?) -> String? {
        guard ids.count > 1 else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return ids.first }
        return ids[(i + 1) % ids.count]
    }
}

// MARK: - hidutil mapping table (pure)

/// Parse / merge / remove / serialise the `hidutil` `UserKeyMapping` table.
///
/// Everything here is a pure string transform, so the merge rules that decide
/// whether another tool's remaps survive are unit-testable with no `hidutil` run.
enum HyperKeyMapping {
    /// HID usage for Caps Lock (keyboard page 0x07, usage 0x39).
    static let capsLockUsage: Int64 = 0x700000039
    /// HID usage for F18 (keyboard page 0x07, usage 0x6D) — virtual keyCode 79.
    static let f18Usage: Int64 = 0x70000006D

    struct Entry: Equatable, Hashable, Sendable {
        var src: Int64
        var dst: Int64
    }

    static let ours = Entry(src: capsLockUsage, dst: f18Usage)

    /// `hidutil property --get UserKeyMapping` prints an old-style plist, and prints
    /// it once PER DEVICE when no `--matching` is given — so the same entry usually
    /// comes back several times. Both that plist and the JSON form we write use the
    /// same key names, so one tolerant scan reads either, and the result is
    /// order-preserving deduplicated.
    static func parse(_ raw: String) -> [Entry] {
        let src = numbers(in: raw, key: "HIDKeyboardModifierMappingSrc")
        let dst = numbers(in: raw, key: "HIDKeyboardModifierMappingDst")
        // A block missing one half is not a mapping; pairing by index is safe because
        // hidutil emits both keys for every entry, in a consistent order per key.
        var out: [Entry] = []
        for (s, d) in zip(src, dst) where !out.contains(Entry(src: s, dst: d)) {
            out.append(Entry(src: s, dst: d))
        }
        return out
    }

    private static func numbers(in raw: String, key: String) -> [Int64] {
        // Matches both `HIDKeyboardModifierMappingSrc = 30064771129;` (plist) and
        // `"HIDKeyboardModifierMappingSrc":30064771129` (JSON), decimal or hex.
        let pattern = "\(key)\"?\\s*[=:]\\s*(0[xX][0-9a-fA-F]+|\\d+)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = raw as NSString
        return re.matches(in: raw, range: NSRange(location: 0, length: ns.length)).compactMap {
            let text = ns.substring(with: $0.range(at: 1))
            if text.lowercased().hasPrefix("0x") {
                return Int64(text.dropFirst(2), radix: 16)
            }
            return Int64(text)
        }
    }

    /// Another tool's Caps Lock remap, if there is one pointing somewhere that is not
    /// ours. Surfaced in Settings and refused — silently clobbering a Karabiner or
    /// hand-rolled `hidutil` setup is how you lose someone's keyboard.
    static func foreignCapsLockDestination(_ table: [Entry]) -> Int64? {
        table.first { $0.src == capsLockUsage && $0.dst != f18Usage }?.dst
    }

    /// Our entry added exactly once, every foreign entry preserved verbatim.
    static func merged(into table: [Entry]) -> [Entry] {
        table.contains(ours) ? table : table + [ours]
    }

    /// Only our entry removed. A foreign Caps Lock mapping (which we would have
    /// refused to install over) is left exactly where it was.
    static func removed(from table: [Entry]) -> [Entry] {
        table.filter { $0 != ours }
    }

    /// The `--set` argument: `{"UserKeyMapping":[…]}`. An empty table serialises to
    /// an empty array, which is how `hidutil` is told "no user mappings".
    static func setJSON(_ table: [Entry]) -> String {
        let items = table.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.src),\"HIDKeyboardModifierMappingDst\":\($0.dst)}"
        }
        return "{\"UserKeyMapping\":[\(items.joined(separator: ","))]}"
    }
}

// MARK: - Lifecycle

@MainActor
final class HyperKey {
    static let shared = HyperKey()

    /// Write-ahead ownership marker. Set BEFORE `hidutil --set` and cleared only
    /// AFTER the removal succeeds, so a crash (or a kill -9) mid-anything leaves it
    /// set — and the next launch knows a mapping out there is ours to clean up.
    /// A crash between the write and the `--set` leaves a marker with no mapping,
    /// which costs one harmless no-op removal.
    static let markerKey = "hyperKeyMappingApplied"

    /// Mapping installed and the state machine live. Only ever true while the shared
    /// keystroke tap is confirmed running — a mapping with no tap is a dead Caps Lock.
    private(set) var isActive = false

    /// Non-nil when another tool already remaps Caps Lock. The feature refuses to
    /// activate; Settings shows this.
    private(set) var conflict: String?

    private var state = HyperKeyState()
    private var wakeObserver: NSObjectProtocol?

    var flags: CGEventFlags { HyperMods.flags(Preferences.hyperKeyModifiers) }

    private init() {}

    // MARK: Reconciliation

    /// The single entry point. Called at launch, whenever the preference changes, and
    /// after every `reconcileKeyTap()` — `tapRunning` is the engine's real state, so
    /// the mapping is applied only once the tap that makes it usable is up, and torn
    /// down the moment it goes away.
    func reconcile(tapRunning: Bool) {
        let want = Preferences.hyperKeyEnabled && tapRunning
        if want {
            activate()
        } else {
            // Covers launch-with-marker-but-feature-off (crash recovery) as well as a
            // plain disable: a leftover marker means a mapping of ours is still live.
            deactivate(force: UserDefaults.standard.bool(forKey: Self.markerKey))
        }
    }

    private func activate() {
        // A known conflict is sticky until the feature is toggled off and on again:
        // `reconcile` runs on every key-tap reconcile (extension rules, snippets,
        // eventtaps), and re-reading the table each time would spawn a `hidutil` per
        // unrelated settings change.
        guard !isActive, conflict == nil else { return }
        let table = HyperKeyMapping.parse(Self.hidutil(["property", "--get", "UserKeyMapping"]) ?? "")
        if let foreign = HyperKeyMapping.foreignCapsLockDestination(table) {
            let described = String(format: "0x%llX", foreign)
            conflict = described
            NSLog("prosper: hyper key refused — Caps Lock already remapped to %@ by another tool", described)
            return
        }
        applyMapping(HyperKeyMapping.merged(into: table))
        state.reset()
        isActive = true
        // Re-assert after wake: `hidutil --set` reaches only the devices attached when
        // it ran, and a sleep/wake cycle re-enumerates them.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.state.reset()
                self.applyMapping(HyperKeyMapping.merged(
                    into: HyperKeyMapping.parse(Self.hidutil(["property", "--get", "UserKeyMapping"]) ?? "")))
            }
        }
        NSLog("prosper: hyper key active (Caps Lock → F18, mods=%@)",
              HyperMods.glyphs(Preferences.hyperKeyModifiers))
    }

    private func deactivate(force: Bool) {
        conflict = nil   // cleared here so a re-enable re-reads the table and can refuse again
        guard isActive || force else { return }
        isActive = false
        state.reset()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        let table = HyperKeyMapping.parse(Self.hidutil(["property", "--get", "UserKeyMapping"]) ?? "")
        _ = Self.hidutil(["property", "--set", HyperKeyMapping.setJSON(HyperKeyMapping.removed(from: table))])
        UserDefaults.standard.removeObject(forKey: Self.markerKey)
    }

    /// Terminate path — `applicationWillTerminate`. Same as a disable; the marker
    /// clear is what tells the next launch there is nothing to recover.
    func clearMapping() {
        deactivate(force: UserDefaults.standard.bool(forKey: Self.markerKey))
    }

    private func applyMapping(_ table: [HyperKeyMapping.Entry]) {
        // Write-ahead: the marker goes down BEFORE the mapping so a crash between the
        // two can only ever over-report, never leave an orphan mapping behind.
        UserDefaults.standard.set(true, forKey: Self.markerKey)
        UserDefaults.standard.synchronize()
        _ = Self.hidutil(["property", "--set", HyperKeyMapping.setJSON(table)])
    }

    // MARK: Tap pre-pass

    /// Consulted by the shared keystroke tap BEFORE the chord is built. Returns
    /// `.pass` / `.swallow` / `.addModifiers`; the lone-tap action and the mapping
    /// repair are performed here and reported as `.swallow`, so the caller has three
    /// cases to handle and no MainActor work of its own.
    ///
    /// Hot path — one `isActive` check for every keystroke when the feature is off.
    func handleEvent(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> HyperKeyDecision {
        guard isActive else { return .pass }
        let now = DispatchTime.now().uptimeNanoseconds
        let input: HyperKeyInput
        switch type {
        case .flagsChanged:
            input = keyCode == HyperKeyState.capsLockKeyCode ? .realCapsLock : .otherModifier
        case .keyDown where keyCode == HyperKeyState.triggerKeyCode:
            let others = !flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
            input = .triggerDown(isRepeat: isRepeat, otherModifiers: others)
        case .keyUp where keyCode == HyperKeyState.triggerKeyCode:
            input = .triggerUp
        case .keyDown, .keyUp:
            input = .otherKey
        default:
            return .pass
        }

        switch state.decide(input, nowNanos: now) {
        case let .solo(isHold, repeated):
            if let effect = HyperKeyState.soloEffect(
                action: Preferences.hyperKeySoloAction, isHold: isHold, repeated: repeated) {
                perform(effect)
            }
            return .swallow
        case .repairMapping:
            // The real Caps Lock press already flipped the lock state before any
            // session tap could see it — un-flip it, then re-assert the mapping so
            // the newly-attached keyboard joins the party.
            Self.setCapsLock(false)
            applyMapping(HyperKeyMapping.merged(
                into: HyperKeyMapping.parse(Self.hidutil(["property", "--get", "UserKeyMapping"]) ?? "")))
            return .swallow
        case let other:
            return other
        }
    }

    private func perform(_ effect: HyperSoloEffect) {
        switch effect {
        case .escape:
            KeyInjector.stroke(KeyChord(keyCode: 53))  // kVK_Escape
        case .toggleCapitals:
            Self.setCapsLock(!Self.capsLockState())
        case .switchInputSource:
            Self.switchInputSource()
        }
    }

    /// Cycle to the next enabled keyboard layout. Runs SYNCHRONOUSLY inside the tap
    /// callback on purpose — the keystroke after the tap is already on its way and
    /// must be typed in the new layout.
    ///
    /// Goes through `KeyboardSource` so "which sources are selectable" keeps exactly
    /// one definition (select-capable AND enabled), and so the switch shares the
    /// re-assert that survives macOS restoring the per-app remembered source.
    private static func switchInputSource() {
        let list = (try? JSONSerialization.jsonObject(with: Data(KeyboardSource.layoutsJSON().utf8)))
            as? [[String: String]]
        let ids = list?.compactMap { $0["id"] } ?? []
        guard let next = HyperKeyState.nextInputSourceID(
            in: ids, current: KeyboardSource.currentSourceID()) else { return }
        _ = KeyboardSource.setSource(next)
    }

    // MARK: Shell / IOKit

    @discardableResult
    private static func hidutil(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            NSLog("prosper: hidutil failed to launch: %@", String(describing: error))
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func withHIDSystem<T>(_ body: (io_connect_t) -> T) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS
        else { return nil }
        defer { IOServiceClose(connect) }
        return body(connect)
    }

    static func capsLockState() -> Bool {
        withHIDSystem { connect in
            var on = false
            IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on)
            return on
        } ?? false
    }

    static func setCapsLock(_ on: Bool) {
        _ = withHIDSystem { connect in
            IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
        }
    }
}
