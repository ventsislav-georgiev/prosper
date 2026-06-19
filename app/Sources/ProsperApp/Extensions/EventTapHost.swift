import AppKit

/// Resident-VM bridge for synchronous `hs.eventtap`-style per-event callbacks.
///
/// Prosper's extension model is stateless and forbids Lua on the keystroke path.
/// A raw eventtap is the one idiom that can't honor that: its callback inspects a
/// live event (incl. the `fn` modifier the native rule engine doesn't model) and
/// decides swallow/pass SYNCHRONOUSLY, every keystroke. The only way to run it is a
/// resident VM kept warm so dispatch is one `callGlobal` — no per-event reparse.
///
/// This is strictly **opt-in and lazy**, so the default product pays nothing:
/// - Only extensions declaring `[extension.host] event_taps = true` are considered.
/// - The VM is built only after a probe confirms the loaded config registered a
///   *running* tap; a config with no eventtap (or a disabled ext) keeps no VM and
///   the runtime is evicted to free memory.
/// - When inactive, the hot path is a single `Bool` check (`wantsKeyDown` /
///   `wantsSystemDefined`) — zero Lua, zero allocation.
/// - Any error / instruction-budget overrun fails OPEN (event passes), so a wedged
///   callback can never block typing.
@MainActor
final class EventTapHost {
    static let shared = EventTapHost()
    private init() {}

    /// Set once at launch. Weak: the registry owns us indirectly via this ref.
    weak var registry: ExtensionRegistry?

    /// Hot-path gates. False ⇒ the tap never calls into Lua for that event type.
    private(set) var wantsKeyDown = false
    private(set) var wantsSystemDefined = false
    /// The single extension whose VM is currently serving taps (nil when inactive).
    private var activeID: String?

    /// True when at least one event type is being served — i.e. the shared CGEvent
    /// tap must be RUNNING for these callbacks to ever fire. A pure-`hs.eventtap`
    /// config registers no `ExtensionKeyRules`, so this is the only signal that keeps
    /// the tap alive when inline autocomplete is off.
    var isActive: Bool { wantsKeyDown || wantsSystemDefined }

    /// Fired after `refresh()` flips `isActive`, so the app can reconcile the shared
    /// keystroke tap's lifecycle (wired to `reconcileKeyTap`). Without this an
    /// eventtap that activates *after* the launch-time tap check would never run —
    /// the tap that calls back into it was never installed.
    var onActiveChanged: (() -> Void)?

    /// Instruction ceiling for a keystroke-time dispatch. The call runs synchronously
    /// on the main thread inside the CGEvent tap, so a heavy/wedged callback adds
    /// latency to EVERY keystroke and can trip the OS tap timeout. This is ~20× below
    /// the VM default (10M): generous for a real swallow/remap decision (thousands of
    /// instructions, measured ~10µs), but bounds a pathological callback to a few ms
    /// before it fails open. ponytail: a fixed ceiling; make it a pref if a legit
    /// callback ever needs more headroom than this.
    nonisolated static let dispatchInstructionBudget: Int32 = 500_000

    /// Re-probe after an extension (re)installs its key rules — the moment its
    /// config (and thus its eventtap set) may have changed: launch, enable, disable,
    /// reload. Cheap no-op unless the extension opted in. Called from keysSetRules.
    func refreshIfDeclares(extensionID: String) {
        guard registry?.manifestDeclaresEventTaps(extensionID) == true else { return }
        refresh()
    }

    /// (Re)run each opted-in extension's config and record which event types have a
    /// running tap. First extension with any wins (realistically only one exists).
    /// No running tap anywhere ⇒ drop the gates and evict the VM.
    ///
    /// ponytail: single resident event-tap VM, reused — `activeID` names the one
    /// extension being driven, and a previously-active different one is evicted so we
    /// never hold two. If two extensions ever need *simultaneous* taps, multiplex the
    /// dispatch loop here over all `eventTapExtensionIDs()`; today only the
    /// hammerspoon-compat shim opts in, so one is enough.
    func refresh() {
        guard let reg = registry else { return }
        let wasActive = isActive
        defer { if isActive != wasActive { onActiveChanged?() } }
        for id in reg.eventTapExtensionIDs() {
            guard let types = reg.callExtensionString(
                extensionID: id, function: "hs_eventtap_probe", arg: ""), !types.isEmpty
            else { continue }
            let kd = types.contains("keyDown")
            let sd = types.contains("systemDefined")
            guard kd || sd else { continue }
            // A different ext was active before — let its VM go.
            if let old = activeID, old != id { reg.deactivateRuntime(old) }
            wantsKeyDown = kd; wantsSystemDefined = sd; activeID = id
            return
        }
        if let old = activeID { reg.deactivateRuntime(old) }
        wantsKeyDown = false; wantsSystemDefined = false; activeID = nil
    }

    /// Dispatch a keyDown to the resident tap. Returns true to swallow the keystroke.
    /// Guarded by `wantsKeyDown` (checked by the caller too); fail-open on any error.
    func handleKeyDown(keyCode: Int64, cmd: Bool, alt: Bool, ctrl: Bool, shift: Bool, fn: Bool) -> Bool {
        guard wantsKeyDown, let id = activeID, let reg = registry else { return false }
        let json = """
        {"type":"keyDown","keyCode":\(keyCode),\
        "flags":{"cmd":\(cmd),"alt":\(alt),"ctrl":\(ctrl),"shift":\(shift),"fn":\(fn)}}
        """
        return reg.callExtensionString(extensionID: id, function: "hs_eventtap_dispatch",
                                       arg: json, budget: Self.dispatchInstructionBudget) == "true"
    }

    /// Dispatch a media/aux (systemDefined) key to the resident tap. `key` is the
    /// NX_KEYTYPE name (PLAY/FAST/…). Fires on both press and release so the Lua
    /// callback can branch on `:systemKey().down`. Fail-open on any error.
    func handleSystemDefined(key: String, down: Bool, cmd: Bool, alt: Bool, ctrl: Bool, shift: Bool, fn: Bool) -> Bool {
        guard wantsSystemDefined, let id = activeID, let reg = registry else { return false }
        let json = """
        {"type":"systemDefined","sys":{"key":"\(key)","down":\(down)},\
        "flags":{"cmd":\(cmd),"alt":\(alt),"ctrl":\(ctrl),"shift":\(shift),"fn":\(fn)}}
        """
        return reg.callExtensionString(extensionID: id, function: "hs_eventtap_dispatch",
                                       arg: json, budget: Self.dispatchInstructionBudget) == "true"
    }
}
