import AppKit
import ApplicationServices
import Carbon
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import notify
import SystemConfiguration
import os

/// Native backings for the "ambient system" host APIs an extension uses to rebuild
/// the user's Hammerspoon openlid/sleep/power behaviour: power assertions
/// (caffeinate), battery, network reachability, and screen/lid state — plus the
/// per-extension resource registry that keeps those native resources alive WITHOUT
/// a resident Lua VM and resets them on disable/quit/crash.
///
/// See .omc/plans/hammerspoon-parity-host-api.md §H/§I/§J/§K and §2.3. All state
/// here is process-global host state; extensions stay stateless and reach it
/// through `host.caffeinate` / `host.battery` / `host.network` / `host.screen`.

// MARK: - Per-extension native resource registry (§2.3)

/// Tracks live native resources (power assertions, the pmset lid override) keyed by
/// extension id, so the host can keep them alive with no VM and tear them ALL down
/// when an extension is disabled, reset, or the app quits — a wedged "disable sleep"
/// can never outlive its owner. Thread-safe (lock-guarded).
final class ExtensionResources: @unchecked Sendable {

    static let shared = ExtensionResources()

    private let lock = NSLock()
    /// IOPMAssertion ids keyed by "extID\u{1}assertionKey".
    private var assertions: [String: IOPMAssertionID] = [:]
    /// Extensions that currently hold the pmset disable-lid-sleep override.
    private var lidSleepDisabledBy: Set<String> = []
    private let log = Logger(subsystem: "com.prosper.app", category: "ext-resources")

    private static func key(_ extID: String, _ name: String) -> String { "\(extID)\u{1}\(name)" }

    // MARK: Power assertions (IOPMAssertionCreateWithName)

    /// Create or release a named idle-sleep assertion for an extension. `kind` is
    /// "display" (PreventUserIdleDisplaySleep) or "system"
    /// (PreventUserIdleSystemSleep). Idempotent per (extID, kind).
    func setAssertion(extID: String, kind: String, on: Bool) {
        let assertionType = (kind == "system"
            ? kIOPMAssertionTypePreventUserIdleSystemSleep
            : kIOPMAssertionTypePreventUserIdleDisplaySleep) as CFString
        let k = Self.key(extID, "assert.\(kind)")
        lock.lock(); defer { lock.unlock() }
        if on {
            guard assertions[k] == nil else { return }
            var id: IOPMAssertionID = 0
            let reason = "Prosper extension \(extID)" as CFString
            let r = IOPMAssertionCreateWithName(assertionType, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
            if r == kIOReturnSuccess { assertions[k] = id }
            else { log.error("IOPMAssertionCreateWithName failed (\(r)) for \(extID, privacy: .public)") }
        } else {
            if let id = assertions[k] { IOPMAssertionRelease(id); assertions[k] = nil }
        }
    }

    // MARK: pmset lid-sleep override (tracked so it always gets reset)

    /// Record/clear that an extension holds the pmset disable-lid-sleep override.
    /// The actual `pmset -a disablesleep` shell call is done by the caller (it needs
    /// the privileged shell lane); this only tracks ownership for teardown.
    func setLidSleepDisabled(extID: String, on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on { lidSleepDisabledBy.insert(extID) } else { lidSleepDisabledBy.remove(extID) }
    }

    func holdsLidSleepDisabled(extID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lidSleepDisabledBy.contains(extID)
    }

    // MARK: Teardown

    /// Release every resource owned by one extension. Returns whether the pmset lid
    /// override was held (so the caller can run the `pmset -a disablesleep 0` reset).
    @discardableResult
    func releaseAll(extID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        for (k, id) in assertions where k.hasPrefix("\(extID)\u{1}") {
            IOPMAssertionRelease(id); assertions[k] = nil
        }
        let hadLid = lidSleepDisabledBy.remove(extID) != nil
        return hadLid
    }
}

// MARK: - System reads (battery / network / screen / lid)

enum SystemInfo {

    /// "AC Power" | "Battery Power" | "" (desktop / unknown).
    static func powerSource() -> String {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return "" }
        let raw = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        switch raw {
        case kIOPMACPowerKey: return "AC Power"
        case kIOPMBatteryPowerKey: return "Battery Power"
        default: return raw ?? ""
        }
    }

    /// Battery charge 0–100, or nil when there is no battery.
    static func batteryPercentage() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Int((Double(cur) / Double(max) * 100).rounded())
        }
        return nil
    }

    /// One-shot read of (source, percentage) from a SINGLE IOPS blob copy. The
    /// battery hot path (fireBattery) uses this instead of powerSource() +
    /// batteryPercentage(), which would copy the IOPS info blob twice per
    /// notification. pct is -1 when there is no battery (desktop / AC-only).
    static func powerSnapshot() -> (source: String, pct: Int) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return ("", -1) }
        let raw = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        let source: String
        switch raw {
        case kIOPMACPowerKey: source = "AC Power"
        case kIOPMBatteryPowerKey: source = "Battery Power"
        default: source = raw ?? ""
        }
        var pct = -1
        if let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for src in sources {
                guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                      let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                      let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
                else { continue }
                pct = Int((Double(cur) / Double(max) * 100).rounded())
                break
            }
        }
        return (source, pct)
    }

    /// All screens as top-left global frames; `main` flags the primary.
    static func screensJSON() -> String {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let arr = NSScreen.screens.map { s -> [String: Any] in
            let f = s.frame
            return [
                "x": Double(f.origin.x),
                "y": Double(primaryHeight - f.origin.y - f.height),
                "w": Double(f.width), "h": Double(f.height),
                "main": s == NSScreen.main,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Clamshell (lid) closed? Reads IOKit `AppleClamshellState`. nil when the key
    /// is unavailable (desktops). Cheap enough to poll, but the watcher below makes
    /// polling unnecessary.
    static func lidClosed() -> Bool? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(
            entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return (prop.takeRetainedValue() as? Bool)
    }
}

// MARK: - App control (§G) / scripting (§P) / keyboard input source (§F)

/// Running-app control + frontmost/window reads via NSWorkspace + Accessibility.
@MainActor
enum AppControl {

    private static func match(_ s: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        return apps.first { $0.bundleIdentifier == s }
            ?? apps.first { $0.localizedName?.caseInsensitiveCompare(s) == .orderedSame }
    }

    /// Launch the app if not running, else activate it. Accepts a bundle id or a
    /// localized name (path / .app name fall back to `open`).
    ///
    /// Always routes through `NSWorkspace.openApplication` (LaunchServices), even
    /// for a running app, instead of `NSRunningApplication.activate`. Reason:
    /// `activate` is ignored when WE (Prosper) are a background app and a third
    /// app is frontmost — macOS's focus-stealing guard — so a hotkey-triggered
    /// `launchOrFocus("Ghostty")` did NOTHING unless Prosper itself was frontmost.
    /// LaunchServices performs the activation on our behalf and is not subject to
    /// that restriction, so it focuses a running instance from the background too.
    static func launchOrFocus(_ nameOrBundleID: String) {
        let ws = NSWorkspace.shared
        // Resolve to a file URL: running instance's bundle, else by bundle id, else path.
        var url: URL? = match(nameOrBundleID)?.bundleURL
        if url == nil, nameOrBundleID.contains(".") {
            url = ws.urlForApplication(withBundleIdentifier: nameOrBundleID)
        }
        if url == nil {
            let p = (nameOrBundleID as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: p) { url = URL(fileURLWithPath: p) }
        }
        guard let url else {
            _ = ws.launchApplication(nameOrBundleID) // last resort: resolve by name
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true // launch if needed AND bring frontmost (works from background)
        ws.openApplication(at: url, configuration: cfg)
    }

    static func frontmostJSON() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "{}" }
        return json([
            "name": app.localizedName ?? "",
            "bundleID": app.bundleIdentifier ?? "",
            "pid": Int(app.processIdentifier),
        ])
    }

    static func hide(bundleID: String) { match(bundleID)?.hide() }

    /// AX window count for the app. Requires Accessibility; 0 when unavailable.
    /// Bounds the cross-process AX call to 0.25s: the default timeout is ~6s, and a
    /// hung target app would otherwise stall the caller that long — fatal if a config
    /// ever calls this from an eventtap (synchronous, on the CGEvent-tap main thread).
    // ponytail: kAXWindowsAttribute counts standard windows incl. minimized ones, so
    // hideAppIfNoWindows treats a minimize-to-Dock like an open window. Matches the
    // common Hammerspoon idiom; filter on AXMinimized per-window if that distinction
    // ever matters.
    static func windowCount(bundleID: String) -> Int {
        guard let app = match(bundleID) else { return 0 }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return 0 }
        return windows.count
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// AppleScript / JXA execution (§P). Privileged — same trust domain as host.shell.
enum Scripting {
    /// Run an AppleScript source string. Returns JSON { ok, output, error }.
    static func runAppleScript(_ source: String) -> String {
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&errorInfo)
        let obj: [String: Any]
        if let err = errorInfo {
            obj = ["ok": false, "output": "", "error": (err[NSAppleScript.errorMessage] as? String) ?? "script error"]
        } else {
            obj = ["ok": true, "output": result?.stringValue ?? "", "error": ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return #"{"ok":false}"# }
        return s
    }
}

/// Keyboard input source via Carbon TIS (§F). Reads are open; set is privileged.
enum KeyboardSource {
    static func currentSourceID() -> String {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
        return id(of: src) ?? ""
    }

    static func layoutsJSON() -> String {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return "[]" }
        // Only selectable sources: TISCreateInputSourceList(_, false) returns ALL
        // installed sources incl. ones disabled in System Settings. Offering an
        // unselectable source in the picker makes setSource fail forever — the
        // hot path then retries the failing select on every focus change.
        let arr = list.compactMap { src -> [String: String]? in
            guard isSelectable(src), let i = id(of: src) else { return nil }
            return ["id": i, "name": name(of: src) ?? i]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    static func setSource(_ wantedID: String) -> Bool {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return false }
        for src in list where id(of: src) == wantedID {
            return TISSelectInputSource(src) == noErr
        }
        return false
    }

    // TISSelectInputSource succeeds only when the source is BOTH select-capable
    // (type allows it — input-mode parents etc. are not) AND enabled in System
    // Settings. Filtering on only one lets a disabled source into the picker, which
    // then fails to select forever on the hot path. Require both.
    private static func isSelectable(_ src: TISInputSource) -> Bool {
        boolProp(src, kTISPropertyInputSourceIsSelectCapable) && boolProp(src, kTISPropertyInputSourceIsEnabled)
    }
    private static func boolProp(_ src: TISInputSource, _ key: CFString) -> Bool {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue() == kCFBooleanTrue
    }
    private static func id(of src: TISInputSource) -> String? {
        property(src, kTISPropertyInputSourceID)
    }
    private static func name(of src: TISInputSource) -> String? {
        property(src, kTISPropertyLocalizedName)
    }
    private static func property(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

/// URL handling + default-browser control (§O). Reads open; open/set privileged.
enum URLServices {
    /// Open a URL, optionally in a specific browser (bundle id). Returns false on a
    /// malformed URL or when the target app can't be resolved.
    @discardableResult
    static func open(_ urlString: String, bundleID: String?) -> Bool {
        guard let url = URL(string: normalizeScheme(urlString)) else { return false }
        let ws = NSWorkspace.shared
        if let bundleID, let appURL = ws.urlForApplication(withBundleIdentifier: bundleID) {
            ws.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return ws.open(url)
    }

    /// A scheme-less link (e.g. "github.com") parses into a URL with `scheme == nil`,
    /// which NSWorkspace silently refuses to open. Prepend https:// so bare domains
    /// behave like every browser's address bar.
    /// ponytail: only the no-scheme case is rewritten; "localhost:3000" parses
    /// "localhost" AS a scheme and is left as-is. Widen if that bites someone.
    static func normalizeScheme(_ urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        if URL(string: trimmed)?.scheme == nil, !trimmed.isEmpty {
            return "https://" + trimmed
        }
        return urlString
    }

    /// Bundle id of the browser macOS would ACTUALLY launch for an http(s) URL, "" if
    /// none. Resolves the concrete app (NSWorkspace.urlForApplication) rather than
    /// reading the recorded handler string — LaunchServices can hold a dangling
    /// handler id (e.g. a stale/duplicate bundle) that no longer resolves to a real
    /// browser; the old LSCopyDefaultHandlerForURLScheme returned that ghost id and
    /// made "is Prosper default?" report a false positive. urlForApplication returns
    /// what would truly open, so a broken registration honestly reads as not-default.
    static func defaultBrowserBundleID() -> String {
        guard let url = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let id = Bundle(url: appURL)?.bundleIdentifier else { return "" }
        return id
    }

    /// Make `bundleID` the default http+https handler. Returns true if both succeed.
    @discardableResult
    static func setDefaultBrowser(_ bundleID: String) -> Bool {
        let http = LSSetDefaultHandlerForURLScheme("http" as CFString, bundleID as CFString)
        let https = LSSetDefaultHandlerForURLScheme("https" as CFString, bundleID as CFString)
        return http == noErr && https == noErr
    }
}

// MARK: - Power edge dedup

/// Collapses repeated, identical power readings to a single edge. Both the IOPS
/// run-loop source and the notify(3) `…powersources.source` key fire repeatedly
/// with unchanged readings; without this an instant key floods openlid's Lua
/// handler (the storm that hung the app in v2.114.0). Pure value type → unit
/// tested in isolation, no IOKit needed. The decision is the battery hot path's
/// guard, so it must stay sub-µs.
struct PowerEdgeFilter {
    private var lastSource: String?
    private var lastPct: Int?

    /// True exactly when (source, pct) differs from the last accepted reading.
    /// Mutates the stored last-reading on a true result.
    mutating func shouldEmit(source: String, pct: Int) -> Bool {
        guard source != lastSource || pct != lastPct else { return false }
        lastSource = source
        lastPct = pct
        return true
    }
}

// MARK: - Native watchers → registry events

/// Owns the live native watchers (battery, network, wake, lid) and forwards each
/// transition to the extension registry as a broadcast event. Started lazily by the
/// app only while at least one enabled extension subscribes to the relevant event,
/// so a machine with no power-aware extension pays nothing.
@MainActor
final class SystemEventWatchers {

    /// Emits (eventName, payloadJSON) for the registry to broadcast. Set by the app.
    var emit: ((String, String) -> Void)?

    /// Cheap live gate consulted ONLY for the high-frequency `app.activated` event
    /// (fires on every focus/Cmd-Tab) before its JSON payload is built — returns
    /// false when no enabled extension subscribes, skipping the allocation entirely.
    /// nil = always emit (tests / unset). Rare hardware events aren't gated.
    var shouldEmit: ((String) -> Bool)?

    private var runLoopSource: CFRunLoopSource?
    private var powerNotifyToken: Int32 = -1  // NOTIFY_TOKEN_INVALID
    private var powerEdge = PowerEdgeFilter()
    private var reachability: SCNetworkReachability?
    private var wakeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    private var lastLidClosed: Bool?
    private var started = false

    /// Start watchers (idempotent). Call after the registry is wired; safe to call
    /// again after extensions toggle — it only starts once.
    func start() {
        guard !started else { return }
        started = true
        startBattery()
        startNetwork()
        startWakeAndScreen()
        startAppActivation()
    }

    // Frontmost-app changes via NSWorkspace activation notifications.
    private func startAppActivation() {
        let wc = NSWorkspace.shared.notificationCenter
        activateObserver = wc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.emitAppActivated(bundleID: app.bundleIdentifier ?? "",
                                       name: app.localizedName ?? "",
                                       pid: Int(app.processIdentifier))
            }
        }
    }

    /// Forward an app activation, skipping the JSON payload build when nothing
    /// subscribes. Extracted from the NSWorkspace observer so the gate is testable.
    func emitAppActivated(bundleID: String, name: String, pid: Int) {
        guard shouldEmit?("app.activated") ?? true else { return }
        emit?("app.activated", Self.json(["bundleID": bundleID, "name": name, "pid": pid]))
    }

    // Battery / power-source changes via IOPSNotificationCreateRunLoopSource.
    private func startBattery() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<SystemEventWatchers>.fromOpaque(ctx).takeUnretainedValue()
            // Source is added to the MAIN run loop → callback is already on the
            // main thread; assumeIsolated avoids a per-event Task allocation.
            MainActor.assumeIsolated { me.fireBattery() }
        }, ctx)?.takeRetainedValue() else { return }
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)

        // IOPSNotificationCreateRunLoopSource is coalesced with the battery
        // time-remaining recompute, so AC plug/unplug edges arrive seconds late.
        // This notify(3) key fires the instant the adapter state flips. Both
        // sources funnel into fireBattery, which edge-dedups — so a chatty key
        // can never flood the Lua VM (the bug that sank the first attempt).
        // ponytail: token leaked for app lifetime (singleton, like the other
        // watchers here); add a teardown only if this class ever gets a stop().
        notify_register_dispatch("com.apple.system.powersources.source",
                                 &powerNotifyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireBattery() }
        }
    }

    private func fireBattery() {
        let snap = SystemInfo.powerSnapshot()  // one IOPS blob copy, not two
        // Only broadcast on a real edge; a chatty notify key cannot flood the VM.
        guard powerEdge.shouldEmit(source: snap.source, pct: snap.pct) else { return }
        emit?("battery.changed", Self.json(["powerSource": snap.source, "percentage": snap.pct]))
    }

    // Network reachability for a general route (0.0.0.0).
    private func startNetwork() {
        var addr = sockaddr()
        addr.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        addr.sa_family = sa_family_t(AF_INET)
        guard let reach = withUnsafePointer(to: &addr, { ptr in
            SCNetworkReachabilityCreateWithAddress(nil, ptr)
        }) else { return }
        reachability = reach
        var ctx = SCNetworkReachabilityContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        SCNetworkReachabilitySetCallback(reach, { _, flags, info in
            guard let info else { return }
            let me = Unmanaged<SystemEventWatchers>.fromOpaque(info).takeUnretainedValue()
            let reachable = flags.contains(.reachable) && !flags.contains(.connectionRequired)
            Task { @MainActor in me.emit?("network.changed", SystemEventWatchers.json(["reachable": reachable])) }
        }, &ctx)
        SCNetworkReachabilityScheduleWithRunLoop(reach, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    // Wake (NSWorkspace) + screen-change (drives lid transitions natively, replacing
    // Hammerspoon's 2 s clamshell poll).
    private func startWakeAndScreen() {
        let wc = NSWorkspace.shared.notificationCenter
        wakeObserver = wc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit?("system.wake", "{}") }
        }
        lastLidClosed = SystemInfo.lidClosed()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLid() }
        }
    }

    private func checkLid() {
        let closed = SystemInfo.lidClosed()
        guard closed != lastLidClosed, let closed else { return }
        lastLidClosed = closed
        emit?("lid.changed", Self.json(["closed": closed]))
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
