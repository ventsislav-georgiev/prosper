import XCTest
@testable import ProsperApp

/// Performance + concurrency guarantees for the extension hot paths.
///
/// HOT-PATH REQUIREMENTS (asserted below, with generous ceilings so CI noise can't
/// flake them — the real numbers are ~10–100× under budget and printed for tracking):
///
///   • `ExtensionKeyRules.evaluate` runs inside the shared CGEvent tap on EVERY
///     keyDown. The tap has a hard system budget (~tens of ms before macOS disables
///     it); our self-imposed ceiling is **< 5 µs/call** even with a full rule set and
///     a worst-case miss (scans every rule). Typical is well under 1 µs.
///   • Async extension lanes are **per-extension**: a slow handler in one extension
///     must not block another's. Asserted by running a 0.4 s sleeper next to a trivial
///     handler and requiring the trivial one to finish first.
final class ExtensionPerfTests: XCTestCase {

    // Minimal services — only the methods without a protocol default. Everything the
    // automation surface adds (app/keys/url/fs/…) has a no-op default already.
    private final class PerfServices: ExtensionHostServices, @unchecked Sendable {
        var prefs: [String: String] = [:]
        func clipboardRead() -> String? { nil }
        func clipboardWrite(_ text: String) {}
        func clipboardHistory(limit: Int) -> [String] { [] }
        func llmComplete(_ prompt: String) async -> String { "" }
        func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
        func shellRun(_ command: String) async -> String { "" }
        func httpRequest(method: String, url: String, headers: [String: String],
                         body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
        func currentEpochSeconds() -> Double { 0 }
        func focusedWindowFrame() -> WindowFrame? { nil }
        func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
        func prefGet(extensionID: String, key: String) -> String? { prefs["\(extensionID).\(key)"] }
        func prefSet(extensionID: String, key: String, value: String) { prefs["\(extensionID).\(key)"] = value }
        func notify(title: String, body: String) {}
        func listDirectories(_ path: String) -> [String] { [] }
    }

    // MARK: hot path — key evaluation budget

    @MainActor
    func testKeyEvaluateHotPathBudget() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "perf")

        // 24 rules spread across several apps — more than any real config.
        var entries: [String] = []
        let apps = ["com.apple.Safari", "com.google.Chrome", "com.apple.Terminal"]
        for i in 0..<24 {
            let app = apps[i % apps.count]
            entries.append(#"{ "from": "cmd+\#(i % 9 + 1)", "to": "cmd+alt+\#(i % 9 + 1)", "apps": ["\#(app)"] }"#)
        }
        mgr.setRules(extensionID: "perf", json: "[\(entries.joined(separator: ","))]")
        XCTAssertFalse(mgr.isEmpty)

        // Representative worst case: a chord whose keyCode IS registered (so the
        // bucket lookup hits) but whose frontmost app doesn't match any rule's filter
        // — forces the bucket scan + app-filter rejection on every call.
        let miss = KeyChord(spec: "cmd+5")!
        let now: UInt64 = 1_000_000_000

        // Warm up (first call touches lazily-initialized caches).
        for _ in 0..<1_000 { _ = mgr.evaluate(chord: miss, bundleID: "com.unmatched.app", nowNanos: now) }

        let n = 200_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n {
            _ = mgr.evaluate(chord: miss, bundleID: "com.unmatched.app", nowNanos: now)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let perCall = Double(elapsed) / Double(n)
        print("evaluate hot path: \(String(format: "%.0f", perCall)) ns/call over \(n) iters, 24 rules (keyCode-indexed), bucket-scan miss")

        XCTAssertLessThan(perCall, 5_000, "key evaluation exceeded the 5µs hot-path budget")
        mgr.removeRules(extensionID: "perf")
    }

    // MARK: hot path — incoming media-key evaluation budget (systemDefined tap)

    /// `evaluateMedia` runs inside the same shared tap for every INCOMING media key.
    /// Same 5µs ceiling. The realistic worst case is a miss with media rules present
    /// (volume key pressed while only PLAY is mapped) — must stay cheap so the volume
    /// HUD isn't delayed.
    @MainActor
    func testMediaEvaluateHotPathBudget() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "mperf")
        mgr.setRules(extensionID: "mperf", json: #"[{ "from": "media:PLAY", "to": "cmd+c" }, { "from": "media:NEXT", "swallow": true }]"#)
        XCTAssertTrue(mgr.hasMediaRules)

        let now: UInt64 = 1_000_000_000
        // A miss: SOUND_UP (code 0) is not mapped → passes through (HUD intact).
        for _ in 0..<1_000 { _ = mgr.evaluateMedia(code: 0, bundleID: "com.unmatched.app") }
        XCTAssertEqual(mgr.evaluateMedia(code: 0, bundleID: nil), .passThrough)

        let n = 200_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { _ = mgr.evaluateMedia(code: 0, bundleID: "com.unmatched.app") }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n)
        print("evaluateMedia hot path: \(String(format: "%.0f", perCall)) ns/call over \(n) iters, miss")
        _ = now
        XCTAssertLessThan(perCall, 5_000, "media evaluation exceeded the 5µs hot-path budget")
        mgr.removeRules(extensionID: "mperf")
    }

    // MARK: hot path — invoke-rule evaluation budget (hammerspoon-compat hotkeys)

    /// `hs.hotkey.bind` compiles to an `invoke` key rule. When a bound key is
    /// pressed the tap matches natively and resolves `.invoke` — the closure fires
    /// later on the async lane, so the ONLY work inside the tap budget is this
    /// resolution. Lock it under the same 5µs ceiling as remap/swallow.
    @MainActor
    func testInvokeRuleEvaluateHotPathBudget() {
        let mgr = ExtensionKeyRules.shared
        mgr.removeRules(extensionID: "hsperf")

        // 24 global invoke rules — well above a typical hammerspoon config's hotkey count.
        var entries: [String] = []
        for i in 0..<24 {
            entries.append(#"{ "from": "cmd+\#(i % 9 + 1)", "invoke": "hs_dispatch", "arg": "\#(i)" }"#)
        }
        mgr.setRules(extensionID: "hsperf", json: "[\(entries.joined(separator: ","))]")
        XCTAssertFalse(mgr.isEmpty)

        // A HIT: a bound chord is pressed → resolves `.invoke` (builds the
        // handler/arg-carrying resolution every press — the realistic hot case).
        let hit = KeyChord(spec: "cmd+5")!
        let now: UInt64 = 1_000_000_000
        for _ in 0..<1_000 { _ = mgr.evaluate(chord: hit, bundleID: nil, nowNanos: now) }

        // Sanity: it really resolves to invoke (not a no-op miss).
        guard case .invoke = mgr.evaluate(chord: hit, bundleID: nil, nowNanos: now) else {
            return XCTFail("expected an .invoke resolution for a bound chord")
        }

        let n = 200_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { _ = mgr.evaluate(chord: hit, bundleID: nil, nowNanos: now) }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n)
        print("invoke evaluate hot path: \(String(format: "%.0f", perCall)) ns/call over \(n) iters, 24 invoke rules, match HIT")

        XCTAssertLessThan(perCall, 5_000, "invoke resolution exceeded the 5µs hot-path budget")
        mgr.removeRules(extensionID: "hsperf")
    }

    // MARK: integration — hammerspoon-compat shim register + warm-VM dispatch

    /// Drives the REAL shim init.lua end-to-end: register emits one invoke rule per
    /// `hs.hotkey.bind`, and a dispatch fires the bound closure. Critically asserts
    /// the warm VM re-reads the config FILE only ONCE (at register) — every later
    /// keypress fires the cached closure with no I/O / parse, the whole point of the
    /// resident-closure fast path.
    /// Absolute path to the shim init.lua (… app/Examples/extensions/…/init.lua).
    private func shimInitURL() -> URL {
        URL(fileURLWithPath: #filePath)                 // .../ExtensionPerfTests.swift
            .deletingLastPathComponent()                // ProsperAppTests
            .deletingLastPathComponent()                // Tests
            .deletingLastPathComponent()                // app
            .appendingPathComponent("Examples/extensions/hammerspoon-compat/init.lua")
    }

    func testHammerspoonShimRegisterAndDispatch() async throws {
        let shimURL = shimInitURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shimURL.path),
                          "shim init.lua not found at \(shimURL.path)")

        // A bound hotkey whose callback flips a durable pref via hs.settings.set —
        // observable, and gated by the shim's `allowed()` (so it must NOT fire at register).
        let config = #"hs.hotkey.bind({"cmd"}, "j", function() hs.settings.set("fired", true) end)"#
        let svc = HSServices(config: config)
        let extID = "eu.illegible.prosper.hammerspoon"
        svc.prefs["\(extID).enabled"] = "true"          // enabled — disabled-by-default is covered elsewhere

        let runtimes = AsyncExtensionRuntimes(services: svc)
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "on_launch",
            callTimeout: 5, privileged: true, trusted: true)

        // register
        _ = await runtimes.invoke(spec, args: [])
        XCTAssertEqual(svc.fsReadCount, 1, "register should read the config exactly once")
        let rules = svc.lastRulesJSON ?? ""
        XCTAssertTrue(rules.contains(#""from":"cmd+j""#) || rules.contains(#""from": "cmd+j""#),
                      "expected a cmd+j invoke rule, got: \(rules)")
        XCTAssertTrue(rules.contains("hs_dispatch"), "rule should target hs_dispatch")
        XCTAssertNil(svc.prefs["\(extID).hs.settings.fired"],
                     "the hotkey callback must NOT fire at register time")

        // dispatch — warm VM fires the cached closure (no re-read)
        let dispatch = AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "hs_dispatch",
            callTimeout: 5, privileged: true, trusted: true)
        _ = await runtimes.invoke(dispatch, args: ["1"])
        XCTAssertEqual(svc.prefs["\(extID).hs.settings.fired"], "true",
                       "dispatch did not fire the bound hotkey closure")
        XCTAssertEqual(svc.fsReadCount, 1, "warm dispatch must not re-read the config file")

        // Many more presses: still no extra file reads, and measurably fast.
        let n = 200
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { _ = await runtimes.invoke(dispatch, args: ["1"]) }
        let perMs = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n) / 1_000_000
        print("warm hs_dispatch: \(String(format: "%.3f", perMs)) ms/call over \(n) presses, fsReadCount=\(svc.fsReadCount)")
        XCTAssertEqual(svc.fsReadCount, 1, "warm VM re-read the config on a later keypress — fast path broken")
        XCTAssertLessThan(perMs, 5, "warm dispatch unexpectedly slow (>5ms) — likely re-parsing per press")
    }

    /// A bound key can be pressed when our VM was never registered or was evicted
    /// from the lane cache. hs_dispatch must self-heal: rebuild the closures once
    /// (effects suppressed) and fire — WITHOUT a prior on_launch. Proves the cold path.
    func testHammerspoonColdDispatchSelfHeals() async throws {
        let shimURL = shimInitURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shimURL.path),
                          "shim init.lua not found at \(shimURL.path)")

        let config = #"hs.hotkey.bind({"cmd"}, "j", function() hs.settings.set("fired", true) end)"#
        let svc = HSServices(config: config)
        let extID = "eu.illegible.prosper.hammerspoon"
        svc.prefs["\(extID).enabled"] = "true"

        let runtimes = AsyncExtensionRuntimes(services: svc)
        // No register: dispatch straight onto a cold VM (simulates lane eviction).
        let dispatch = AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "hs_dispatch",
            callTimeout: 5, privileged: true, trusted: true)
        _ = await runtimes.invoke(dispatch, args: ["1"])

        XCTAssertEqual(svc.prefs["\(extID).hs.settings.fired"], "true",
                       "cold dispatch must rebuild closures and fire the bound hotkey")
        XCTAssertEqual(svc.fsReadCount, 1, "cold dispatch reads the config exactly once to rebuild")
    }

    /// Real hammerspoon configs use three hotkey idioms. Lock them:
    ///   1. bind with an optional message arg — bind(mods,key,"msg",fn)
    ///   2. new(...):enable() — records + activates
    ///   3. new(...) without :enable() — recorded but emits NO rule (fires nothing)
    func testHammerspoonBindVariants() async throws {
        let shimURL = shimInitURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shimURL.path),
                          "shim init.lua not found at \(shimURL.path)")

        let config = """
        hs.hotkey.bind({"cmd"}, "j", "Reload config", function() hs.settings.set("a", true) end)
        hs.hotkey.new({"cmd"}, "k", function() hs.settings.set("b", true) end):enable()
        hs.hotkey.new({"cmd"}, "l", function() hs.settings.set("c", true) end)
        """
        let svc = HSServices(config: config)
        let extID = "eu.illegible.prosper.hammerspoon"
        svc.prefs["\(extID).enabled"] = "true"
        let runtimes = AsyncExtensionRuntimes(services: svc)

        _ = await runtimes.invoke(AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "on_launch",
            callTimeout: 5, privileged: true, trusted: true), args: [])

        let rules = svc.lastRulesJSON ?? ""
        XCTAssertTrue(rules.contains(#""from":"cmd+j""#), "message-arg bind must still register a rule: \(rules)")
        XCTAssertTrue(rules.contains(#""from":"cmd+k""#), "new(...):enable() must register a rule: \(rules)")
        XCTAssertFalse(rules.contains(#""from":"cmd+l""#), "new(...) without :enable() must NOT register a rule: \(rules)")

        // Dispatch the message-arg binding (index 1) — its fn must fire despite the
        // string message argument sitting between key and callback.
        let dispatch = AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "hs_dispatch", callTimeout: 5, privileged: true, trusted: true)
        _ = await runtimes.invoke(dispatch, args: ["1"])
        XCTAssertEqual(svc.prefs["\(extID).hs.settings.a"], "true",
                       "message-arg bind callback did not fire (string arg mistaken for the fn?)")
        // And the new():enable() binding (index 2).
        _ = await runtimes.invoke(dispatch, args: ["2"])
        XCTAssertEqual(svc.prefs["\(extID).hs.settings.b"], "true",
                       "new(...):enable() callback did not fire")
    }

    /// hs.timer.doAfter/doEvery schedule durable host timers and fire their closure
    /// via the timer.fired event. Register must schedule (not fire); a fired event
    /// must run the right closure.
    func testHammerspoonTimerSchedulesAndFires() async throws {
        let shimURL = shimInitURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shimURL.path),
                          "shim init.lua not found at \(shimURL.path)")

        let config = """
        hs.timer.doEvery(60, function() hs.settings.set("tick", true) end)
        hs.timer.doAfter(5, function() hs.settings.set("once", true) end)
        """
        let svc = HSServices(config: config)
        let extID = "eu.illegible.prosper.hammerspoon"
        svc.prefs["\(extID).enabled"] = "true"
        let runtimes = AsyncExtensionRuntimes(services: svc)

        _ = await runtimes.invoke(AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "on_launch",
            callTimeout: 5, privileged: true, trusted: true), args: [])

        // Register scheduled both timers, fired neither.
        XCTAssertEqual(svc.scheduledTimers.count, 2, "both timers should be scheduled at register")
        let every = svc.scheduledTimers.first { $0.every }
        let once = svc.scheduledTimers.first { !$0.every }
        XCTAssertEqual(every?.id, "hst_1"); XCTAssertEqual(every?.seconds, 60); XCTAssertEqual(every?.handler, "hs_timer_fired")
        XCTAssertEqual(once?.id, "hst_2");  XCTAssertEqual(once?.seconds, 5)
        XCTAssertNil(svc.prefs["\(extID).hs.settings.tick"], "timer must not fire at register")

        // Fire the repeating timer (warm VM) — closure runs, no re-schedule.
        let fired = AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "hs_timer_fired", callTimeout: 5, privileged: true, trusted: true)
        _ = await runtimes.invoke(fired, args: [#"{"id":"hst_1"}"#])
        XCTAssertEqual(svc.prefs["\(extID).hs.settings.tick"], "true", "doEvery closure did not fire")
        _ = await runtimes.invoke(fired, args: [#"{"id":"hst_2"}"#])
        XCTAssertEqual(svc.prefs["\(extID).hs.settings.once"], "true", "doAfter closure did not fire")
        XCTAssertEqual(svc.scheduledTimers.count, 2, "warm timer fire must not re-schedule (multiplication)")
    }

    /// A timer can fire on a cold/evicted VM. The rebuild re-runs the config to
    /// repopulate closures but MUST NOT re-arm the timers (effects suppressed),
    /// else every fire would schedule another timer — runaway multiplication.
    func testHammerspoonTimerColdFireDoesNotRemultiply() async throws {
        let shimURL = shimInitURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shimURL.path),
                          "shim init.lua not found at \(shimURL.path)")

        let config = #"hs.timer.doEvery(60, function() hs.settings.set("tick", true) end)"#
        let svc = HSServices(config: config)
        let extID = "eu.illegible.prosper.hammerspoon"
        svc.prefs["\(extID).enabled"] = "true"
        let runtimes = AsyncExtensionRuntimes(services: svc)

        // No register: fire straight onto a cold VM (simulates eviction between fires).
        _ = await runtimes.invoke(AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "hs_timer_fired",
            callTimeout: 5, privileged: true, trusted: true), args: [#"{"id":"hst_1"}"#])

        XCTAssertEqual(svc.prefs["\(extID).hs.settings.tick"], "true", "cold timer fire must rebuild + fire the closure")
        XCTAssertTrue(svc.scheduledTimers.isEmpty, "cold rebuild must NOT re-arm timers — would multiply on every fire")
    }

    /// Flipping the enable toggle must install rules LIVE — no restart, no separate
    /// Apply step. The section is dynamic, so the toggle's change is delivered to
    /// settings_action("set:enabled", ...) which persists the pref and installs.
    /// Flipping it back must tear the rules down. Guards the enable→install footgun
    /// (a static section would write the pref silently and install nothing).
    func testHammerspoonEnableToggleInstallsLive() async throws {
        let shimURL = shimInitURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shimURL.path),
                          "shim init.lua not found at \(shimURL.path)")

        let config = #"hs.hotkey.bind({"alt"}, "b", function() end)"#
        let svc = HSServices(config: config)
        let extID = "eu.illegible.prosper.hammerspoon"
        // Start DISABLED (pref unset) — exactly the state after first enabling the
        // extension in the list without touching the toggle.
        let runtimes = AsyncExtensionRuntimes(services: svc)
        let action = AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "settings_action",
            callTimeout: 5, privileged: true, trusted: true)

        // Flip the toggle ON: dynamic section delivers "set:enabled" = "true".
        _ = await runtimes.invoke(action, args: ["hammerspoon-compat", "set:enabled", "true", "{}"])
        XCTAssertEqual(svc.prefs["\(extID).enabled"], "true", "toggle must persist the enabled pref")
        let rules = svc.lastRulesJSON ?? ""
        XCTAssertTrue(rules.contains("hs_dispatch") && rules.contains("alt+b"),
                      "enabling the toggle must install the alt+b rule live, got: \(rules)")

        // Flip it OFF: must persist + clear the rules.
        _ = await runtimes.invoke(action, args: ["hammerspoon-compat", "set:enabled", "false", "{}"])
        XCTAssertEqual(svc.prefs["\(extID).enabled"], "false", "toggle off must persist")
        XCTAssertFalse((svc.lastRulesJSON ?? "").contains("hs_dispatch"),
                       "disabling must tear down the rules, got: \(svc.lastRulesJSON ?? "")")
    }

    /// hs.prosper.* is the opt-in bridge for the two raw-eventtap idioms that map
    /// to native rules: double-tap passthrough (⌘Q-to-really-quit) and per-app
    /// remap (option+arrow tab-nav). install() must emit them as native key rules
    /// (double_tap / to + apps) alongside any hotkey rules.
    func testHammerspoonProsperNativeRuleBridge() async throws {
        let shimURL = shimInitURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shimURL.path),
                          "shim init.lua not found at \(shimURL.path)")

        let config = """
        hs.prosper.doubleTap("cmd+q")
        hs.prosper.remap{ from="alt+down", to="ctrl+tab", apps={"com.apple.Safari"} }
        """
        let svc = HSServices(config: config)
        let extID = "eu.illegible.prosper.hammerspoon"
        svc.prefs["\(extID).enabled"] = "true"

        let runtimes = AsyncExtensionRuntimes(services: svc)
        _ = await runtimes.invoke(AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "on_launch",
            callTimeout: 5, privileged: true, trusted: true), args: [])

        let rules = svc.lastRulesJSON ?? ""
        // Decode + verify via the real engine so we test behavior, not JSON spelling.
        let decoded = KeyRuleEngine.decode(json: rules)
        XCTAssertTrue(decoded.contains { rule in
            if case .doubleTap = rule.action { return rule.chord == KeyChord(spec: "cmd+q") }
            return false
        }, "doubleTap cmd+q rule missing, got: \(rules)")
        XCTAssertTrue(decoded.contains { rule in
            if case .remap(let target) = rule.action {
                return rule.chord == KeyChord(spec: "alt+down")
                    && target == KeyChord(spec: "ctrl+tab")
                    && rule.apps == ["com.apple.Safari"]
            }
            return false
        }, "per-app remap rule missing, got: \(rules)")
    }

    /// The migration of hammerspoon-compat from a bundled SYSTEM extension to a
    /// TRUSTED user/marketplace extension hinges on the two-tier host surface: a
    /// trusted (non-system) extension gets the AUTOMATION tier (key rules, apps,
    /// caffeinate, UI, file read, osascript) but NOT the system-only RCE tier
    /// (host.shell / agent / files.act). Drive the real shim with privileged:false,
    /// trusted:true and assert both halves — this is the regression guard for the
    /// `automation = privileged || trusted` gate in ExtensionHostAPI.
    func testTrustedNonSystemGetsAutomationNotShell() async throws {
        let shimURL = shimInitURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shimURL.path),
                          "shim init.lua not found at \(shimURL.path)")

        let config = """
        hs.prosper.remap{ from="alt+down", to="ctrl+tab", apps={"com.apple.Safari"} }
        hs.settings.set("shellout", hs.execute("echo hi"))
        """
        let svc = HSServices(config: config)
        let extID = "eu.illegible.prosper.hammerspoon"
        svc.prefs["\(extID).enabled"] = "true"

        let runtimes = AsyncExtensionRuntimes(services: svc)
        // privileged:false (NOT a system ext) but trusted:true (user reviewed + trusted).
        _ = await runtimes.invoke(AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "on_launch",
            callTimeout: 5, privileged: false, trusted: true), args: [])

        // AUTOMATION granted: the native remap reached host.keys.set_rules.
        let rules = svc.lastRulesJSON ?? ""
        let decoded = KeyRuleEngine.decode(json: rules)
        XCTAssertTrue(decoded.contains { rule in
            if case .remap(let t) = rule.action {
                return rule.chord == KeyChord(spec: "alt+down") && t == KeyChord(spec: "ctrl+tab")
            }
            return false
        }, "trusted non-system ext should reach host.keys (automation tier), got: \(rules)")

        // SYSTEM-ONLY denied: hs.execute → host.shell is refused for a non-system ext.
        let shellOut = svc.prefs["\(extID).hs.settings.shellout"] ?? ""
        XCTAssertTrue(shellOut.contains("restricted to system extensions"),
                      "host.shell must stay system-only even for trusted exts, got: \(shellOut)")
    }

    /// Regression guard for the shim's "load UNMODIFIED configs" contract: a real
    /// ~/.hammerspoon/init.lua routinely touches APIs Prosper can't back —
    /// deep-indexes an unsupported sub-API (`hs.eventtap.event.types.keyDown`),
    /// indexes a concrete table's missing field (`hs.application.watcher.new`),
    /// and calls globals HS predefines (`require`, `loadfile`, `spoon`). Each of
    /// these previously threw and aborted the chunk, so any rules defined AFTER
    /// (the user's cmd+q double-tap, per-app remaps) never registered. Assert the
    /// hazardous prelude is inert AND the trailing hs.prosper rules still install.
    func testHammerspoonUnsupportedApisDoNotAbortLaterRules() async throws {
        let shimURL = shimInitURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shimURL.path),
                          "shim init.lua not found at \(shimURL.path)")

        let config = """
        local _ = hs.eventtap.event.types.keyDown          -- deep-index unsupported API
        local w = hs.application.watcher.new(function() end) -- missing field on concrete table
        local m = require("openlid"); m.start()             -- require + chained call
        spoon.SpoonInstall:andUse("URLDispatcher", {})       -- predefined `spoon` global
        local r = loadfile("/nope"); if r then r() end       -- loadfile no-op
        hs.prosper.doubleTap("cmd+q")                        -- must still register
        hs.prosper.remap{ from="alt+down", to="ctrl+tab", apps={"com.apple.Safari"} }
        """
        let svc = HSServices(config: config)
        let extID = "eu.illegible.prosper.hammerspoon"
        svc.prefs["\(extID).enabled"] = "true"

        let runtimes = AsyncExtensionRuntimes(services: svc)
        _ = await runtimes.invoke(AsyncExtensionRuntimes.Spec(
            extensionID: extID, entryURL: shimURL, handler: "on_launch",
            callTimeout: 5, privileged: false, trusted: true), args: [])

        let decoded = KeyRuleEngine.decode(json: svc.lastRulesJSON ?? "")
        XCTAssertTrue(decoded.contains { rule in
            if case .doubleTap = rule.action { return rule.chord == KeyChord(spec: "cmd+q") }
            return false
        }, "cmd+q doubleTap missing — unsupported-API prelude aborted the chunk: \(svc.lastRulesJSON ?? "<nil>")")
        XCTAssertTrue(decoded.contains { rule in
            if case .remap(let t) = rule.action {
                return rule.chord == KeyChord(spec: "alt+down") && t == KeyChord(spec: "ctrl+tab")
            }
            return false
        }, "alt+down remap missing — unsupported-API prelude aborted the chunk: \(svc.lastRulesJSON ?? "<nil>")")
    }

    // Richer services for the shim integration test: serves a fixed config to
    // host.fs.read (counting reads), captures host.keys.set_rules, and backs
    // host.prefs / host.env. Everything else inherits the no-op defaults.
    private final class HSServices: ExtensionHostServices, @unchecked Sendable {
        var prefs: [String: String] = [:]
        var lastRulesJSON: String?
        var fsReadCount = 0
        var scheduledTimers: [(id: String, every: Bool, seconds: Double, handler: String)] = []
        var cancelledTimerIDs: [String] = []
        private let config: String
        init(config: String) { self.config = config }

        // non-defaulted protocol surface
        func clipboardRead() -> String? { nil }
        func clipboardWrite(_ text: String) {}
        func clipboardHistory(limit: Int) -> [String] { [] }
        func llmComplete(_ prompt: String) async -> String { "" }
        func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
        func shellRun(_ command: String) async -> String { "" }
        func httpRequest(method: String, url: String, headers: [String: String],
                         body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
        func currentEpochSeconds() -> Double { 0 }
        func focusedWindowFrame() -> WindowFrame? { nil }
        func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
        func prefGet(extensionID: String, key: String) -> String? { prefs["\(extensionID).\(key)"] }
        func prefSet(extensionID: String, key: String, value: String) { prefs["\(extensionID).\(key)"] = value }
        func notify(title: String, body: String) {}
        func listDirectories(_ path: String) -> [String] { [] }

        // overrides of defaulted automation surface used by the shim
        func fsRead(_ path: String) -> String? { fsReadCount += 1; return config }
        func keysSetRules(extensionID: String, json: String) { lastRulesJSON = json }
        func envGet(_ name: String) -> String? { name == "HOME" ? "/Users/test" : nil }
        func timerSchedule(extensionID: String, id: String, every: Bool, seconds: Double, handler: String) {
            scheduledTimers.append((id, every, seconds, handler))
        }
        func timerCancel(extensionID: String, id: String) { cancelledTimerIDs.append(id) }
    }

    // MARK: stability — per-extension lanes don't head-of-line-block each other

    func testAsyncLanesRunInParallel() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-perf-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let slowURL = dir.appendingPathComponent("slow.lua")
        let fastURL = dir.appendingPathComponent("fast.lua")
        try #"function slow() host.sleep(0.4); return "a" end"#.write(to: slowURL, atomically: true, encoding: .utf8)
        try #"function quick() return "b" end"#.write(to: fastURL, atomically: true, encoding: .utf8)

        let runtimes = AsyncExtensionRuntimes(services: PerfServices())
        let specSlow = AsyncExtensionRuntimes.Spec(
            extensionID: "ext.slow", entryURL: slowURL, handler: "slow",
            callTimeout: 5, privileged: true, trusted: true)
        let specFast = AsyncExtensionRuntimes.Spec(
            extensionID: "ext.fast", entryURL: fastURL, handler: "quick",
            callTimeout: 5, privileged: true, trusted: true)

        let start = DispatchTime.now().uptimeNanoseconds
        // Fire the 0.4s sleeper first, then the trivial handler. With per-extension
        // lanes the fast one returns almost immediately; a single shared queue would
        // make it wait behind the sleeper (> 0.4s).
        async let slow = runtimes.invoke(specSlow, args: [])
        async let fast = runtimes.invoke(specFast, args: [])

        let fastResult = await fast
        let fastElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("fast handler returned in \(String(format: "%.0f", fastElapsedMs)) ms while a 400ms sleeper ran on another lane")

        XCTAssertEqual(fastResult, "b")
        XCTAssertLessThan(fastElapsedMs, 300, "fast handler was blocked by the slow extension — lanes are not per-extension")

        let slowResult = await slow
        XCTAssertEqual(slowResult, "a")
    }

    // MARK: stability — awaitSync cancels the abandoned op on timeout

    /// One-shot thread-safe flag the cancellation-aware op flips when it observes
    /// `Task.isCancelled`.
    private final class CancelFlag: @unchecked Sendable {
        private var v = false
        private let lock = NSLock()
        func set() { lock.lock(); v = true; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return v }
    }

    func testAwaitSyncCancelsOnTimeout() {
        let flag = CancelFlag()
        // Cancellation-aware op: sleeps in a loop until cancelled (mirrors a
        // URLSession request / Task.sleep backoff that honors cancellation).
        let result = ExtensionHost.awaitSync(timeout: 0.05) {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_000_000) }
            flag.set()
            return "late"
        }
        XCTAssertNil(result, "awaitSync must return nil when the op exceeds the timeout")

        // After the timeout, the detached op must actually observe cancellation
        // (otherwise it leaks a cooperative-pool thread until it finishes on its own).
        let deadline = Date().addingTimeInterval(2)
        while !flag.get() && Date() < deadline { usleep(2_000) }
        XCTAssertTrue(flag.get(), "timed-out op was never cancelled — abandoned work keeps running")
    }

    func testAwaitSyncReturnsValueWhenFast() {
        let result = ExtensionHost.awaitSync(timeout: 1.0) { "ok" }
        XCTAssertEqual(result, "ok", "awaitSync must return the op's value when it finishes in time")
    }

    // MARK: PowerEdgeFilter — correctness

    /// The filter is the guard that makes a chatty notify(3) key safe: every
    /// power event funnels through `fireBattery` → `shouldEmit`, and only a real
    /// (source, pct) edge is forwarded to the Lua VM. If this regresses, an
    /// adapter-state key that fires repeatedly with identical readings floods
    /// openlid's handler — the storm that hung the app in v2.114.0.
    func testPowerEdgeFilterEmitsFirstReading() {
        var f = PowerEdgeFilter()
        XCTAssertTrue(f.shouldEmit(source: "AC Power", pct: 80),
                      "first reading must always emit — no prior state to dedup against")
    }

    func testPowerEdgeFilterSuppressesIdenticalRepeat() {
        var f = PowerEdgeFilter()
        _ = f.shouldEmit(source: "AC Power", pct: 80)
        XCTAssertFalse(f.shouldEmit(source: "AC Power", pct: 80),
                       "identical repeat must be suppressed — this is what stops the storm")
        XCTAssertFalse(f.shouldEmit(source: "AC Power", pct: 80),
                       "still suppressed on a third identical reading")
    }

    func testPowerEdgeFilterEmitsOnSourceFlip() {
        var f = PowerEdgeFilter()
        _ = f.shouldEmit(source: "AC Power", pct: 80)
        XCTAssertTrue(f.shouldEmit(source: "Battery Power", pct: 80),
                      "unplug at same % must emit — the toast depends on this edge")
    }

    func testPowerEdgeFilterEmitsOnPercentChange() {
        var f = PowerEdgeFilter()
        _ = f.shouldEmit(source: "Battery Power", pct: 80)
        XCTAssertTrue(f.shouldEmit(source: "Battery Power", pct: 79),
                      "%-drop at same source must emit — battery-threshold extensions need it")
    }

    func testPowerEdgeFilterEmitsOnFlipBack() {
        var f = PowerEdgeFilter()
        _ = f.shouldEmit(source: "AC Power", pct: 80)
        _ = f.shouldEmit(source: "Battery Power", pct: 80)
        XCTAssertTrue(f.shouldEmit(source: "AC Power", pct: 80),
                      "replug must emit — last accepted state was Battery, so AC is a real edge")
    }

    // MARK: PowerEdgeFilter — performance (hot path: battery callback guard)

    /// HOT-PATH REQUIREMENT: `shouldEmit` runs on EVERY power notification (run-loop
    /// source + notify key, both chatty) before any emit. It is two comparisons and
    /// two assignments — ceiling **< 500 ns/call**, typically single-digit ns.
    func testPowerEdgeFilterPerformance() {
        var f = PowerEdgeFilter()
        let iters = 1_000_000
        // Warmup.
        for i in 0..<10_000 { _ = f.shouldEmit(source: "AC Power", pct: i & 1) }
        let start = DispatchTime.now().uptimeNanoseconds
        var emits = 0
        for i in 0..<iters where f.shouldEmit(source: "AC Power", pct: i & 1) { emits += 1 }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let perCall = Double(elapsed) / Double(iters)
        print("PowerEdgeFilter.shouldEmit: \(String(format: "%.1f", perCall)) ns/call over \(iters) iters")
        XCTAssertGreaterThan(emits, 0, "alternating input must produce emits — sanity on the loop")
        XCTAssertLessThan(perCall, 500, "PowerEdgeFilter.shouldEmit exceeded its 500 ns hot-path budget")
    }

    /// HOT-PATH REQUIREMENT: `powerSnapshot()` is the one IOKit read per power event.
    /// It copies a single IOPS blob (down from two in the old powerSource() +
    /// batteryPercentage() pair). IOKit dominates and varies by hardware, so the
    /// ceiling is generous — **< 2 ms/call** — and the real number is printed.
    func testPowerSnapshotPerformance() {
        let iters = 200
        for _ in 0..<10 { _ = SystemInfo.powerSnapshot() }  // warmup
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iters { _ = SystemInfo.powerSnapshot() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let perCall = Double(elapsed) / Double(iters) / 1_000_000
        print("SystemInfo.powerSnapshot: \(String(format: "%.3f", perCall)) ms/call over \(iters) iters")
        XCTAssertLessThan(perCall, 2.0, "powerSnapshot exceeded its 2 ms ceiling — IOKit read regressed")
    }
}
