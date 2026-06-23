import Foundation
import LuaRuntime

/// The native capabilities an extension may reach through `host.*`. Abstracted
/// behind a protocol so it can be faked in tests and so the Lua surface is
/// decoupled from the concrete MLX / clipboard / shell implementations.
///
/// All long-running natives are `async`; the host bridges them to synchronous
/// Lua calls with a hard timeout (see `ExtensionHost`). Extensions therefore
/// MUST run off the main thread. See docs/ADR-002-extensibility.md (§D6).
protocol ExtensionHostServices: AnyObject, Sendable {
    // Clipboard (native store; the capture loop is never exposed).
    func clipboardRead() -> String?
    func clipboardWrite(_ text: String)
    func clipboardHistory(limit: Int) -> [String]
    // Local LLM (queued onto MLX; back-pressured).
    func llmComplete(_ prompt: String) async -> String
    func llmTranslate(_ text: String, target: String, source: String?) async -> String
    // Shell (user-permissioned).
    func shellRun(_ command: String) async -> String
    // Outbound HTTP (trusted-extension capability; http/https only, size-capped).
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse?
    // Focused-window geometry (Accessibility; same trust domain as the
    // autocomplete caret tracking). Coordinates are a top-left global space.
    func focusedWindowFrame() -> WindowFrame?
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool
    // Wall-clock, for cache keys / scheduling (the sandbox removes `os`).
    func currentEpochSeconds() -> Double
    // Local calendar breakdown of "now" (the sandbox removes `os.date`). JSON
    // { epoch, year, month, day, hour, min, sec, wday }. Powers e.g. openlid's
    // "stay awake until HH:MM".
    func currentLocalDateJSON() -> String
    // Per-extension settings (typed values declared in the manifest).
    func prefGet(extensionID: String, key: String) -> String?
    func prefSet(extensionID: String, key: String, value: String)
    // User notification.
    func notify(title: String, body: String)
    // Host-rendered menubar status item (upsert/remove by id), modal dialogs, and
    // a transient alert HUD — the openlid UI surface. Privileged (system
    // extensions only). `json` shapes are documented at the Lua surface. Dialogs
    // are async (they block on the user); the host bridges them to sync Lua calls.
    func menubarSet(extensionID: String, id: String, json: String)
    func menubarRemove(extensionID: String, id: String)
    func dialogPrompt(json: String) async -> String?
    func dialogConfirm(json: String) async -> Bool
    func alertShow(text: String, seconds: Double)
    // App control + scripting + keyboard input source (§G/§P/§F). Control ops
    // (launch/hide/run-script/set-source) are privileged; reads (frontmost,
    // windows, current source, layouts) are open. `*JSON` return documented shapes.
    func appLaunchOrFocus(_ nameOrBundleID: String)
    func appFrontmostJSON() -> String
    func appWindowCount(bundleID: String) -> Int
    func appHide(bundleID: String)
    func runAppleScript(_ source: String) -> String
    func keyboardCurrentSource() -> String
    func keyboardLayoutsJSON() -> String
    func keyboardSetSource(_ id: String) -> Bool
    // Declarative per-app key remapping (§D) + synthetic key injection (§E). Rules
    // (a JSON array) are evaluated natively inside the shared event tap — NO Lua in
    // the keystroke path. An extension registers its full set from `on_launch`;
    // passing an empty array clears it. Privileged. `stroke` takes a combo spec
    // ("cmd+alt+i"); `system` a media-key name ("PLAY").
    func keysSetRules(extensionID: String, json: String)
    func keysStroke(_ spec: String)
    func keysSystem(_ name: String)
    // URL handling + default-browser control (§O). open / reads are open; setting the
    // default browser is privileged. When Prosper is the default browser, opened
    // links arrive as the `url.open` event ({ url }).
    func urlOpen(_ url: String, bundleID: String?) -> Bool
    func urlDefaultBrowser() -> String
    func urlSetDefaultBrowser(_ bundleID: String) -> Bool
    // Fallback web-search providers (the runner's Alfred-style "default results").
    // Reads/writes the native FallbackSearchStore; system-only since it edits the
    // launcher's behaviour. `list` → providers JSON array, `save` ← providers JSON,
    // `getMode`/`setMode` toggle always-append vs empty-only, `importBrowser` pulls
    // engines from the default browser and returns the count added.
    func fallbackList() -> String
    func fallbackSave(_ json: String)
    func fallbackMode() -> Bool
    func fallbackSetMode(_ on: Bool)
    func fallbackImport() -> Int
    // Filesystem reads (open) + path watching (privileged, §Q). A watch fires a named
    // handler with payload { paths }. The host owns the FSEventStream; it is released
    // on disable/reset.
    func fsExists(_ path: String) -> Bool
    func fsAttributesJSON(_ path: String) -> String
    func fsRead(_ path: String) -> String?
    func fsWatch(extensionID: String, path: String, handler: String)
    func fsUnwatch(extensionID: String, path: String)
    // Whether a named macOS privacy grant (manifest `permissions`) is currently
    // held — e.g. "full-disk-access" for the bookmarks extension's Safari source.
    // Read-only; lets an extension degrade gracefully when a grant is missing.
    func permissionGranted(_ name: String) -> Bool
    // Filesystem: immediate subdirectory names of a path (tilde-expanded,
    // hidden entries skipped, sorted). Read-only — the only fs capability.
    func listDirectories(_ path: String) -> [String]
    // App launcher: ranked application matches for a query, as a JSON array
    // string `[{ "name": ..., "path": ... }]` (so the Lua layer can decode it
    // through host.json). Powers the `open` system extension's launcher list.
    func appsSearch(_ query: String) -> String
    // Snippets (native store + placeholder engine). All marshalled as JSON
    // strings (decoded Lua-side via host.json), like apps / fs. `snippetExpand`
    // resolves a keyword's snippet through `PlaceholderEngine` (dates, clipboard,
    // arguments, …) and returns the expanded text.
    func snippetsAll() -> String
    func snippetGet(name: String) -> String?
    func snippetSave(json: String)
    func snippetRemove(name: String)
    func snippetExpand(keyword: String, argsJSON: String?) -> String
    // Snippet management surface used by the extension's Settings page (Tier B):
    // the four expansion toggles (global `Preferences`), collections, ignored apps,
    // and a native "import from file" picker. JSON in/out, decoded Lua-side.
    func snippetConfig() -> String
    func snippetSetConfig(json: String)
    func snippetCollections() -> String
    func snippetSetCollections(json: String)
    func snippetIgnored() -> String
    func snippetSetIgnored(json: String)
    func snippetImportFile() -> String
    // File finder: ranked Spotlight (`NSMetadataQuery`) matches for a structured
    // query. `optsJSON` is the `host.files.search{…}` options object `{ name, kind,
    // ext, in, content, limit }`; returns a JSON array string `[{ name, path,
    // display, isDir, kind, size, modified }]` (decoded Lua-side via host.json).
    // Async (the Spotlight gather is run-loop driven); read-only.
    func filesSearch(_ optsJSON: String) async -> String
    // File action: run a built-in file operation (open / reveal / quick look /
    // copy / trash …) against `path`. `id` is a reserved `file.*` action id. Used
    // by `host.files.act(id, path)`; the runner also dispatches these natively.
    func filesAct(id: String, path: String)
    // Open a standalone host-rendered window from a declarative component tree
    // (`host.window.open`). `nodeJSON` is a JSON `ExtensionViewNode` (e.g. a
    // `converter`); `extensionID` is the owning extension whose Lua globals the
    // window's controls (converter transforms / actions) dispatch back into.
    func openWindow(extensionID: String, nodeJSON: String)
    // Close the currently-open host-rendered window (`host.window.close`). Used by
    // form/dialog submit handlers to dismiss themselves after persisting.
    func closeWindow()
    // Open the Prosper Settings window at this extension's settings pane
    // (`host.settings.open(sectionID)`). `sectionID` nil → the extension's first
    // section. Used by menubar "… Settings" items to deep-link into preferences.
    func openSettings(extensionID: String, sectionID: String?)
    // Durable named timer (host.timer). The host owns the timer + persistence and
    // re-invokes a NAMED Lua handler (event "timer.fired") — no resident VM / live
    // closure. `every` distinguishes one-shot (after) from repeating; `seconds` is
    // the delay/period. See TimerScheduler + the stateless model in the plan.
    func timerSchedule(extensionID: String, id: String, every: Bool, seconds: Double, handler: String)
    func timerCancel(extensionID: String, id: String)
    // Structured logging (host.log) → os_log. level ∈ {"info","warn","error"}.
    func log(level: String, message: String)
    // Environment variable read (host.env.get) — the sandbox strips Lua's `os`.
    func envGet(_ name: String) -> String?
    // Power / caffeinate (privileged). Idle-sleep assertions are host-held keyed by
    // extension id (ExtensionResources) and reset on disable/quit. `kind` is
    // "display" | "system". Lid-sleep override goes through privileged pmset.
    func caffeinatePreventIdleSleep(extensionID: String, kind: String, on: Bool)
    func caffeinateSetDisableLidSleep(extensionID: String, on: Bool) async
    func caffeinateLockScreen()
    func caffeinateStartScreensaver()
    // Battery (read-only, open). powerSource() = "AC Power"|"Battery Power"|"".
    func batteryPowerSource() -> String
    func batteryPercentage() -> Int          // -1 when no battery
    // Network reachability (read-only, open).
    func networkIsReachable() -> Bool
    // Screens (read-only, open). all() = JSON array; lidClosed = 1/0/-1(unknown).
    func screenAllJSON() -> String
    func screenLidClosed() -> Int
    // Release every native resource (power assertions, pmset lid override) an
    // extension holds. Called on disable/reset/quit so a wedged "disable sleep" can
    // never outlive its owner (stateless-resource teardown, plan §2.3).
    func resetResources(extensionID: String)
}

extension ExtensionHostServices {
    /// Default: no application index (test / minimal hosts). The live host
    /// (`LiveExtensionHostServices`) overrides this with a real `AppIndex` search.
    func appsSearch(_ query: String) -> String { "[]" }

    /// Default: empty snippet store (test / minimal hosts). The live host
    /// (`LiveExtensionHostServices`) overrides these with the real `SnippetStore`.
    func snippetsAll() -> String { "[]" }
    func snippetGet(name: String) -> String? { nil }
    func snippetConfig() -> String { "{}" }
    func snippetSetConfig(json: String) {}
    func snippetCollections() -> String { "[]" }
    func snippetSetCollections(json: String) {}
    func snippetIgnored() -> String { "[]" }
    func snippetSetIgnored(json: String) {}
    func snippetImportFile() -> String { "" }
    func snippetSave(json: String) {}
    func snippetRemove(name: String) {}
    func snippetExpand(keyword: String, argsJSON: String?) -> String { "" }

    /// Default: no Spotlight backend (test / minimal hosts). The live host
    /// overrides this with a real `FileSearchEngine` (`NSMetadataQuery`) query.
    func filesSearch(_ optsJSON: String) async -> String { "[]" }

    /// Default: no-op file actions (test / minimal hosts). The live host overrides
    /// this to drive `FileActions`.
    func filesAct(id: String, path: String) {}


    /// Default: no windowing (test / minimal hosts). The live host opens a real
    /// `ExtensionViewPanel`.
    func openWindow(extensionID: String, nodeJSON: String) {}

    /// Default: no windowing (test / minimal hosts).
    func closeWindow() {}

    /// Default: no settings window (test / minimal hosts). The live host opens the
    /// real Prosper Settings window at the extension's pane.
    func openSettings(extensionID: String, sectionID: String?) {}

    /// Default: no scheduler (test / minimal hosts). The live host overrides these
    /// to drive `TimerScheduler`.
    func timerSchedule(extensionID: String, id: String, every: Bool, seconds: Double, handler: String) {}
    func timerCancel(extensionID: String, id: String) {}

    /// Default: stderr log + no environment (test / minimal hosts).
    func log(level: String, message: String) {}
    func envGet(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }

    /// Default: local calendar breakdown of now (works in any host — pure Foundation).
    func currentLocalDateJSON() -> String {
        let now = Date()
        let c = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
        let obj: [String: Any] = [
            "epoch": now.timeIntervalSince1970,
            "year": c.year ?? 0, "month": c.month ?? 0, "day": c.day ?? 0,
            "hour": c.hour ?? 0, "min": c.minute ?? 0, "sec": c.second ?? 0,
            "wday": c.weekday ?? 0,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Default: no power/battery/network/screen backing (test / minimal hosts).
    func caffeinatePreventIdleSleep(extensionID: String, kind: String, on: Bool) {}
    func caffeinateSetDisableLidSleep(extensionID: String, on: Bool) async {}
    func caffeinateLockScreen() {}
    func caffeinateStartScreensaver() {}
    func batteryPowerSource() -> String { "" }
    func batteryPercentage() -> Int { -1 }
    func networkIsReachable() -> Bool { true }
    func screenAllJSON() -> String { "[]" }
    func screenLidClosed() -> Int { -1 }

    /// Default: nothing to release (test / minimal hosts). The live host frees native
    /// resources (lid assertion, menubar items, key rules, fs watches) here.
    func resetResources(extensionID: String) {}

    /// Default: no host UI (test / minimal hosts). The live host drives
    /// `ExtensionMenuBar`.
    func menubarSet(extensionID: String, id: String, json: String) {}
    func menubarRemove(extensionID: String, id: String) {}
    func dialogPrompt(json: String) async -> String? { nil }
    func dialogConfirm(json: String) async -> Bool { false }
    func alertShow(text: String, seconds: Double) {}

    /// Default: no app/scripting/keyboard backend (test / minimal hosts). The live
    /// host drives `AppControl` / `Scripting` / `KeyboardSource`.
    func appLaunchOrFocus(_ nameOrBundleID: String) {}
    func appFrontmostJSON() -> String { "{}" }
    func appWindowCount(bundleID: String) -> Int { 0 }
    func appHide(bundleID: String) {}
    func runAppleScript(_ source: String) -> String { #"{"ok":false,"error":"scripting unavailable"}"# }
    func keyboardCurrentSource() -> String { "" }
    func keyboardLayoutsJSON() -> String { "[]" }
    func keyboardSetSource(_ id: String) -> Bool { false }
    func keysSetRules(extensionID: String, json: String) {}
    func keysStroke(_ spec: String) {}
    func keysSystem(_ name: String) {}
    func urlOpen(_ url: String, bundleID: String?) -> Bool { false }
    func urlDefaultBrowser() -> String { "" }
    func urlSetDefaultBrowser(_ bundleID: String) -> Bool { false }
    func fallbackList() -> String { "[]" }
    func fallbackSave(_ json: String) {}
    func fallbackMode() -> Bool { true }
    func fallbackSetMode(_ on: Bool) {}
    func fallbackImport() -> Int { 0 }
    func fsExists(_ path: String) -> Bool { false }
    func fsAttributesJSON(_ path: String) -> String { #"{"exists":false}"# }
    func fsRead(_ path: String) -> String? { nil }
    func fsWatch(extensionID: String, path: String, handler: String) {}
    func fsUnwatch(extensionID: String, path: String) {}

    /// Default: no grants (test / minimal hosts). The live host overrides this
    /// with real `PermissionsManager` checks.
    func permissionGranted(_ name: String) -> Bool { false }
}

/// A captured HTTP response handed back to a Lua extension via `host.http`.
struct HTTPResponse: Sendable, Equatable {
    let status: Int
    let body: String
    let headers: [String: String]
}

/// Focused-window geometry handed to a Lua extension via `host.window.frame()`.
/// All values are in a top-left global coordinate space (y grows downward),
/// matching Accessibility `AXPosition`. `visible*` is the window's screen's
/// visible frame (menu bar / Dock excluded), in the same space.
struct WindowFrame: Sendable, Equatable {
    let x, y, w, h: Double
    let visibleX, visibleY, visibleW, visibleH: Double
}

/// Binds the `host.*` API into a `LuaRuntime` for one extension. Each host call
/// is time-boxed; an extension that exceeds its budget is aborted by the runtime
/// (instruction hook) or times out at the bridge (async natives).
struct ExtensionHost {

    /// Default wall-clock ceiling for a single async host call. Used by tests and
    /// any caller that doesn't override it; the live registry raises this (see
    /// `AppDelegate`) because on-device generation can run for tens of seconds.
    static let defaultCallTimeout: TimeInterval = 5.0

    let extensionID: String
    let services: ExtensionHostServices
    let callTimeout: TimeInterval
    /// System-only tier. Bundled system extensions get the RCE / destructive
    /// surface (`host.shell` — arbitrary command execution — and `host.files.act`);
    /// everyone else gets error stubs. `isSystem` is derived from the bundle dir,
    /// not the manifest, so a remote extension can't claim it.
    let privileged: Bool
    /// Automation tier. Trusted (user-reviewed) extensions — plus system ones — get
    /// the automation surface (key rules, app launch/hide, osascript, caffeinate,
    /// host-rendered UI, file read/watch, Lua `load`). This is everything the
    /// `privileged` tier grants EXCEPT the system-only RCE/destructive surface
    /// above. A bare untrusted extension never executes, so it gets neither.
    let trusted: Bool

    init(extensionID: String,
         services: ExtensionHostServices,
         callTimeout: TimeInterval = ExtensionHost.defaultCallTimeout,
         privileged: Bool = true,
         trusted: Bool = true) {
        self.extensionID = extensionID
        self.services = services
        self.callTimeout = callTimeout
        self.privileged = privileged
        self.trusted = trusted
    }

    /// Register every host function and assemble the `host` table. Call before
    /// running the extension's entry script.
    func install(into lua: LuaRuntime) throws {
        let services = self.services
        let extID = self.extensionID
        let timeout = self.callTimeout
        // Automation tier = system OR trusted. The narrower `privileged` (system-only)
        // tier still gates the RCE/destructive surface (host.shell/agent/files.act).
        let automation = privileged || trusted

        // --- clipboard ---
        lua.register("__h_clip_read") { rt in
            if let s = services.clipboardRead() { rt.push(s) } else { rt.pushNil() }
            return 1
        }
        lua.register("__h_clip_write") { rt in
            services.clipboardWrite(rt.stringArgument(1) ?? "")
            return 0
        }
        lua.register("__h_clip_history") { rt in
            let limit = Int(rt.numberArgument(1) ?? 50)
            let items = services.clipboardHistory(limit: limit)
            // join as newline-separated for v1 (table marshalling lands with UI, #23)
            rt.push(items.joined(separator: "\n"))
            return 1
        }

        // --- llm (async → sync, time-boxed) ---
        lua.register("__h_llm_complete") { rt in
            let prompt = rt.stringArgument(1) ?? ""
            let out = ExtensionHost.awaitSync(timeout: timeout) {
                await services.llmComplete(prompt)
            }
            rt.push(out ?? "")
            return 1
        }
        lua.register("__h_llm_translate") { rt in
            let text = rt.stringArgument(1) ?? ""
            let target = rt.stringArgument(2) ?? "English"
            let source = rt.stringArgument(3)
            let out = ExtensionHost.awaitSync(timeout: timeout) {
                await services.llmTranslate(text, target: target, source: source)
            }
            rt.push(out ?? "")
            return 1
        }

        // --- shell (async → sync, time-boxed; system extensions only) ---
        if privileged {
            lua.register("__h_shell_run") { rt in
                let cmd = rt.stringArgument(1) ?? ""
                let out = ExtensionHost.awaitSync(timeout: timeout) { await services.shellRun(cmd) }
                rt.push(out ?? "")
                return 1
            }
        } else {
            lua.register("__h_shell_run") { rt in
                rt.push("error: host.shell is restricted to system extensions")
                return 1
            }
        }

        // --- http (async → sync, time-boxed) ---
        // Args: (method, url, headersJSON, body?, timeoutSeconds?). Returns a JSON
        // string {status, body, headers} or nil on failure / bad scheme.
        lua.register("__h_http_request") { rt in
            let method = rt.stringArgument(1) ?? "GET"
            let url = rt.stringArgument(2) ?? ""
            let headers = Self.decodeStringMap(rt.stringArgument(3) ?? "{}")
            let body = rt.stringArgument(4)
            let reqTimeout = rt.numberArgument(5).map { min(max($0, 0.1), 30) } ?? timeout
            let result = ExtensionHost.awaitSync(timeout: reqTimeout + 1) {
                await services.httpRequest(method: method, url: url, headers: headers,
                                           body: body, timeout: reqTimeout)
            }
            if let resp = result ?? nil {
                rt.push(Self.encodeResponse(resp))
            } else {
                rt.pushNil()
            }
            return 1
        }

        // --- window (Accessibility; sync, main-bridged in the live impl) ---
        // frame() returns a JSON string {x,y,w,h,screen:{x,y,w,h}} or nil;
        // set(x,y,w,h) returns a boolean.
        lua.register("__h_window_frame") { rt in
            if let f = services.focusedWindowFrame() {
                rt.push(Self.encodeWindowFrame(f))
            } else {
                rt.pushNil()
            }
            return 1
        }
        lua.register("__h_window_set") { rt in
            let x = rt.numberArgument(1) ?? 0
            let y = rt.numberArgument(2) ?? 0
            let w = rt.numberArgument(3) ?? 0
            let h = rt.numberArgument(4) ?? 0
            rt.push(services.setFocusedWindowFrame(x: x, y: y, width: w, height: h))
            return 1
        }

        // --- time (sync; wall-clock epoch seconds) ---
        lua.register("__h_time") { rt in
            rt.push(services.currentEpochSeconds())
            return 1
        }
        // --- date (sync; local calendar breakdown JSON; decoded in UI bootstrap) ---
        lua.register("__h_date") { rt in
            rt.push(services.currentLocalDateJSON())
            return 1
        }

        // --- sleep (blocks the extension thread; used for retry backoff) ---
        // Capped so a buggy extension cannot stall its worker indefinitely.
        // Extensions run off the main thread, so this never freezes the UI.
        lua.register("__h_sleep") { rt in
            let secs = min(max(rt.numberArgument(1) ?? 0, 0), 10)
            if secs > 0 { Thread.sleep(forTimeInterval: secs) }
            return 0
        }

        // --- prefs ---
        lua.register("__h_pref_get") { rt in
            let key = rt.stringArgument(1) ?? ""
            if let v = services.prefGet(extensionID: extID, key: key) { rt.push(v) } else { rt.pushNil() }
            return 1
        }
        lua.register("__h_pref_set") { rt in
            services.prefSet(extensionID: extID, key: rt.stringArgument(1) ?? "", value: rt.stringArgument(2) ?? "")
            return 0
        }

        // --- notify ---
        lua.register("__h_notify") { rt in
            services.notify(title: rt.stringArgument(1) ?? "", body: rt.stringArgument(2) ?? "")
            return 0
        }

        // --- perms (read-only privacy-grant check; sync) ---
        lua.register("__h_perms_has") { rt in
            rt.push(services.permissionGranted(rt.stringArgument(1) ?? ""))
            return 1
        }

        // --- json decode (native; sync) ---
        // Heavy JSON parsing belongs in native code, not a char-by-char Lua loop.
        // Foundation parses the string and `pushJSON` materialises the Lua table
        // directly. Exposed as host.json.decode; returns nil on malformed input.
        // Stays alive past the bootstrap nil-out (assembled in the UI bootstrap,
        // alongside the pure-Lua encoder), like http / fs / apps.
        lua.register("__h_json_decode") { rt in
            let s = rt.stringArgument(1) ?? ""
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { rt.pushNil(); return 1 }
            rt.pushJSON(obj)
            return 1
        }

        // --- json encode (native; sync) ---
        // The reverse of decode: serialise the Lua value at arg 1 to a JSON string
        // natively (no char-by-char Lua loop). Powers host.json.encode AND
        // host.ui.render (which serialises result/view trees on every keystroke).
        lua.register("__h_json_encode") { rt in
            rt.push(rt.encodeJSON(at: 1))
            return 1
        }

        // --- fs (read-only directory listing; sync) ---
        // Returns a JSON array string of immediate subdirectory names so the Lua
        // layer can decode it into a table (assembled in the UI bootstrap, which
        // owns json_decode). Kept alive past the bootstrap nil-out, like http.
        lua.register("__h_fs_list_dirs") { rt in
            let path = rt.stringArgument(1) ?? ""
            let dirs = services.listDirectories(path)
            let data = (try? JSONSerialization.data(withJSONObject: dirs)) ?? Data("[]".utf8)
            rt.push(String(data: data, encoding: .utf8) ?? "[]")
            return 1
        }

        // --- apps (ranked app launcher search; sync) ---
        // Returns a JSON array string `[{name, path}]` so the Lua layer can decode
        // it into a table (assembled in the UI bootstrap, which owns json_decode).
        // Kept alive past the bootstrap nil-out, like http / fs.
        lua.register("__h_apps_search") { rt in
            let q = rt.stringArgument(1) ?? ""
            rt.push(services.appsSearch(q))
            return 1
        }

        // --- snippets (native store + placeholder engine; sync). JSON strings,
        // decoded Lua-side; kept alive past the bootstrap nil-out like apps / fs. ---
        lua.register("__h_snippets_all") { rt in
            rt.push(services.snippetsAll())
            return 1
        }
        lua.register("__h_snippets_get") { rt in
            if let s = services.snippetGet(name: rt.stringArgument(1) ?? "") { rt.push(s) } else { rt.pushNil() }
            return 1
        }
        lua.register("__h_snippets_save") { rt in
            services.snippetSave(json: rt.stringArgument(1) ?? "")
            return 0
        }
        lua.register("__h_snippets_remove") { rt in
            services.snippetRemove(name: rt.stringArgument(1) ?? "")
            return 0
        }
        lua.register("__h_snippets_expand") { rt in
            rt.push(services.snippetExpand(keyword: rt.stringArgument(1) ?? "",
                                           argsJSON: rt.stringArgument(2)))
            return 1
        }
        lua.register("__h_snippets_config") { rt in
            rt.push(services.snippetConfig())
            return 1
        }
        lua.register("__h_snippets_set_config") { rt in
            services.snippetSetConfig(json: rt.stringArgument(1) ?? "")
            return 0
        }
        lua.register("__h_snippets_collections") { rt in
            rt.push(services.snippetCollections())
            return 1
        }
        lua.register("__h_snippets_set_collections") { rt in
            services.snippetSetCollections(json: rt.stringArgument(1) ?? "")
            return 0
        }
        lua.register("__h_snippets_ignored") { rt in
            rt.push(services.snippetIgnored())
            return 1
        }
        lua.register("__h_snippets_set_ignored") { rt in
            services.snippetSetIgnored(json: rt.stringArgument(1) ?? "")
            return 0
        }
        lua.register("__h_snippets_import_file") { rt in
            rt.push(services.snippetImportFile())
            return 1
        }

        // --- files (Spotlight file finder; async → sync, time-boxed) ---
        // Arg is the JSON options object; returns a JSON array string of hits so
        // the Lua layer can decode it (assembled in the UI bootstrap). Kept alive
        // past the bootstrap nil-out, like apps / fs.
        lua.register("__h_files_search") { rt in
            let opts = rt.stringArgument(1) ?? "{}"
            let out = ExtensionHost.awaitSync(timeout: timeout) { await services.filesSearch(opts) }
            rt.push(out ?? "[]")
            return 1
        }
        // --- files.act (built-in file operation; sync, fire-and-forget) ---
        // Gated to system extensions: actions include destructive ops (trash) and
        // open arbitrary files — the same trust domain as host.shell. Search above
        // is read-only and stays open to all extensions (like host.fs / host.apps).
        if privileged {
            lua.register("__h_files_act") { rt in
                services.filesAct(id: rt.stringArgument(1) ?? "", path: rt.stringArgument(2) ?? "")
                return 0
            }
        } else {
            lua.register("__h_files_act") { _ in 0 }
        }

        // --- window.open (host-rendered standalone window; main-bridged) ---
        // Arg: a JSON ExtensionViewNode string. Side effect only.
        lua.register("__h_window_open") { rt in
            services.openWindow(extensionID: extID, nodeJSON: rt.stringArgument(1) ?? "")
            return 0
        }
        // --- window.close (dismiss the open host window; main-bridged) ---
        lua.register("__h_window_close") { _ in
            services.closeWindow()
            return 0
        }
        // --- settings.open(sectionID?) — deep-link to this ext's prefs pane ---
        lua.register("__h_settings_open") { rt in
            let sec = rt.stringArgument(1)
            services.openSettings(extensionID: extID, sectionID: (sec?.isEmpty ?? true) ? nil : sec)
            return 0
        }

        // --- timer (durable, host-owned; named handler re-invoked on fire) ---
        // schedule(id, every, seconds, handler): every=true → repeating, else
        // one-shot. The host persists + re-arms; the handler is invoked via the
        // "timer.fired" event with a JSON payload {id=...}. cancel(id) removes it.
        lua.register("__h_timer_schedule") { rt in
            let id = rt.stringArgument(1) ?? ""
            let every = rt.boolArgument(2) ?? false
            let seconds = rt.numberArgument(3) ?? 0
            let handler = rt.stringArgument(4) ?? ""
            guard !id.isEmpty, !handler.isEmpty else { return 0 }
            services.timerSchedule(extensionID: extID, id: id, every: every,
                                   seconds: seconds, handler: handler)
            return 0
        }
        lua.register("__h_timer_cancel") { rt in
            services.timerCancel(extensionID: extID, id: rt.stringArgument(1) ?? "")
            return 0
        }

        // --- log (os_log; sync) ---
        lua.register("__h_log") { rt in
            services.log(level: rt.stringArgument(1) ?? "info", message: rt.stringArgument(2) ?? "")
            return 0
        }

        // --- env (read-only environment variable; sync) ---
        lua.register("__h_env_get") { rt in
            if let v = services.envGet(rt.stringArgument(1) ?? "") { rt.push(v) } else { rt.pushNil() }
            return 1
        }

        // --- battery / network / screen (read-only; open to all extensions) ---
        lua.register("__h_battery_source") { rt in rt.push(services.batteryPowerSource()); return 1 }
        lua.register("__h_battery_pct") { rt in rt.push(Double(services.batteryPercentage())); return 1 }
        lua.register("__h_network_reachable") { rt in rt.push(services.networkIsReachable()); return 1 }
        lua.register("__h_screen_all") { rt in rt.push(services.screenAllJSON()); return 1 }
        lua.register("__h_screen_lid") { rt in rt.push(Double(services.screenLidClosed())); return 1 }

        // --- caffeinate / power (automation: holds system resources + pmset) ---
        if automation {
            lua.register("__h_caf_idle") { rt in
                services.caffeinatePreventIdleSleep(
                    extensionID: extID, kind: rt.stringArgument(1) ?? "display",
                    on: rt.boolArgument(2) ?? false)
                return 0
            }
            lua.register("__h_caf_lidsleep") { rt in
                let on = rt.boolArgument(1) ?? false
                // Fire-and-forget: the Lua caller ignores the result, and the work
                // does privileged XPC + SMAppService IPC that must NEVER block the
                // single-threaded VM (awaitSync here used to freeze openlid for the
                // whole IPC — no toast, dead shortcut). Enqueue on a serial chain
                // appended in VM call order so set(true)/set(false) apply strictly in
                // order and none are dropped (a drop-based coalescer regressed this:
                // a trailing set(false) killed the override → Mac slept on lid close).
                LidSleepHelper.enqueueApply {
                    await services.caffeinateSetDisableLidSleep(extensionID: extID, on: on)
                }
                return 0
            }
            lua.register("__h_caf_lock") { _ in services.caffeinateLockScreen(); return 0 }
            lua.register("__h_caf_screensaver") { _ in services.caffeinateStartScreensaver(); return 0 }
        } else {
            for name in ["__h_caf_idle", "__h_caf_lidsleep", "__h_caf_lock", "__h_caf_screensaver"] {
                lua.register(name) { _ in 0 }
            }
        }

        // --- menubar / dialog / alert (automation: host-rendered UI) ---
        if automation {
            lua.register("__h_menubar_set") { rt in
                services.menubarSet(extensionID: extID, id: rt.stringArgument(1) ?? "",
                                    json: rt.stringArgument(2) ?? "{}")
                return 0
            }
            lua.register("__h_menubar_remove") { rt in
                services.menubarRemove(extensionID: extID, id: rt.stringArgument(1) ?? "")
                return 0
            }
            // Dialogs block on the user; bridge with a generous timeout (treat a
            // 5-min no-answer as a cancel rather than wedging the worker forever).
            lua.register("__h_dialog_prompt") { rt in
                let json = rt.stringArgument(1) ?? "{}"
                let out = ExtensionHost.awaitSync(timeout: 300) { await services.dialogPrompt(json: json) }
                if let inner = out, let s = inner { rt.push(s) } else { rt.pushNil() }
                return 1
            }
            lua.register("__h_dialog_confirm") { rt in
                let json = rt.stringArgument(1) ?? "{}"
                let out = ExtensionHost.awaitSync(timeout: 300) { await services.dialogConfirm(json: json) }
                rt.push(out ?? false)
                return 1
            }
            lua.register("__h_alert_show") { rt in
                services.alertShow(text: rt.stringArgument(1) ?? "", seconds: rt.numberArgument(2) ?? 0)
                return 0
            }
        } else {
            for name in ["__h_menubar_set", "__h_menubar_remove", "__h_alert_show"] {
                lua.register(name) { _ in 0 }
            }
            lua.register("__h_dialog_prompt") { rt in rt.pushNil(); return 1 }
            lua.register("__h_dialog_confirm") { rt in rt.push(false); return 1 }
        }

        // --- app reads / scripting reads / keyboard reads (open to all) ---
        lua.register("__h_app_frontmost") { rt in rt.push(services.appFrontmostJSON()); return 1 }
        lua.register("__h_app_windows") { rt in
            rt.push(Double(services.appWindowCount(bundleID: rt.stringArgument(1) ?? ""))); return 1
        }
        lua.register("__h_kbd_current") { rt in rt.push(services.keyboardCurrentSource()); return 1 }
        lua.register("__h_kbd_layouts") { rt in rt.push(services.keyboardLayoutsJSON()); return 1 }
        lua.register("__h_url_open") { rt in
            rt.push(services.urlOpen(rt.stringArgument(1) ?? "", bundleID: rt.stringArgument(2))); return 1
        }
        lua.register("__h_url_default") { rt in rt.push(services.urlDefaultBrowser()); return 1 }
        lua.register("__h_fs_exists") { rt in rt.push(services.fsExists(rt.stringArgument(1) ?? "")); return 1 }
        lua.register("__h_fs_attrs") { rt in rt.push(services.fsAttributesJSON(rt.stringArgument(1) ?? "")); return 1 }

        // --- fallback web-search store (system extensions only; edits the runner) ---
        if privileged {
            lua.register("__h_fallback_list") { rt in rt.push(services.fallbackList()); return 1 }
            lua.register("__h_fallback_save") { rt in services.fallbackSave(rt.stringArgument(1) ?? "[]"); return 0 }
            lua.register("__h_fallback_mode_get") { rt in rt.push(services.fallbackMode()); return 1 }
            lua.register("__h_fallback_mode_set") { rt in services.fallbackSetMode(rt.boolArgument(1) ?? true); return 0 }
            lua.register("__h_fallback_import") { rt in rt.push(Double(services.fallbackImport())); return 1 }
        } else {
            lua.register("__h_fallback_list") { rt in rt.push("[]"); return 1 }
            lua.register("__h_fallback_save") { _ in 0 }
            lua.register("__h_fallback_mode_get") { rt in rt.push(true); return 1 }
            lua.register("__h_fallback_mode_set") { _ in 0 }
            lua.register("__h_fallback_import") { rt in rt.push(Double(0)); return 1 }
        }

        // --- app control / scripting / keyboard set (automation) ---
        if automation {
            lua.register("__h_app_launch") { rt in
                services.appLaunchOrFocus(rt.stringArgument(1) ?? ""); return 0
            }
            lua.register("__h_app_hide") { rt in
                services.appHide(bundleID: rt.stringArgument(1) ?? ""); return 0
            }
            lua.register("__h_osascript") { rt in
                rt.push(services.runAppleScript(rt.stringArgument(1) ?? "")); return 1
            }
            lua.register("__h_kbd_set") { rt in
                rt.push(services.keyboardSetSource(rt.stringArgument(1) ?? "")); return 1
            }
            lua.register("__h_keys_rules") { rt in
                services.keysSetRules(extensionID: extID, json: rt.stringArgument(1) ?? "[]"); return 0
            }
            lua.register("__h_keys_stroke") { rt in
                services.keysStroke(rt.stringArgument(1) ?? ""); return 0
            }
            lua.register("__h_keys_system") { rt in
                services.keysSystem(rt.stringArgument(1) ?? ""); return 0
            }
            lua.register("__h_url_set_default") { rt in
                rt.push(services.urlSetDefaultBrowser(rt.stringArgument(1) ?? "")); return 1
            }
            lua.register("__h_fs_watch") { rt in
                services.fsWatch(extensionID: extID, path: rt.stringArgument(1) ?? "",
                                 handler: rt.stringArgument(2) ?? ""); return 0
            }
            lua.register("__h_fs_unwatch") { rt in
                services.fsUnwatch(extensionID: extID, path: rt.stringArgument(1) ?? ""); return 0
            }
            // Read a text file (privileged — arbitrary path). Powers the
            // hammerspoon-compat shim loading the user's ~/.hammerspoon/init.lua.
            lua.register("__h_fs_read") { rt in
                if let s = services.fsRead(rt.stringArgument(1) ?? "") { rt.push(s) } else { rt.pushNil() }
                return 1
            }
        } else {
            for name in ["__h_app_launch", "__h_app_hide", "__h_keys_rules", "__h_keys_stroke",
                         "__h_keys_system", "__h_fs_watch", "__h_fs_unwatch"] {
                lua.register(name) { _ in 0 }
            }
            lua.register("__h_fs_read") { rt in rt.pushNil(); return 1 }
            lua.register("__h_osascript") { rt in rt.push(#"{"ok":false,"error":"not permitted"}"#); return 1 }
            lua.register("__h_kbd_set") { rt in rt.push(false); return 1 }
            lua.register("__h_url_set_default") { rt in rt.push(false); return 1 }
        }

        // Assemble the namespaced `host` table and hide the raw bindings.
        try lua.run(Self.bootstrap, name: "@host-bootstrap")
        // Layer on the pure-Lua UI helpers (host.json + host.ui builders) used
        // by `mode = "view"` commands to return component trees (ADR-002 §D7).
        try lua.run(Self.uiBootstrap, name: "@host-ui-bootstrap")
    }

    /// Lua that groups the flat `__h_*` bindings under `host.*` then removes the
    /// raw globals so extensions only see the namespaced API.
    private static let bootstrap = """
    -- Capture the raw bindings that the wrappers below reference by name, so they
    -- keep working after the globals are nil'd at the end of this chunk.
    local _timer_schedule   = __h_timer_schedule
    local _timer_cancel     = __h_timer_cancel
    local _log              = __h_log
    local _fallback_save    = __h_fallback_save
    local _fallback_mode_set = __h_fallback_mode_set
    host = {
        clipboard = {
            read    = __h_clip_read,
            write   = __h_clip_write,
            history = __h_clip_history,
        },
        llm = {
            complete  = __h_llm_complete,
            translate = __h_llm_translate,
        },
        shell  = { run = __h_shell_run },
        prefs  = { get = __h_pref_get, set = __h_pref_set },
        perms  = { has = __h_perms_has },
        notify = __h_notify,
        time   = __h_time,
        sleep  = __h_sleep,
        -- Durable named-handler timers (host-owned, persisted). schedule with
        -- after= (one-shot) OR every= (repeating); the handler global is invoked
        -- via the "timer.fired" event with a JSON payload {id=...}.
        --   host.timer.schedule{ id=, after=|every=, handler= }
        --   host.timer.cancel(id)
        timer  = {
            schedule = function(opts)
                opts = opts or {}
                local every = opts.every ~= nil
                local seconds = every and opts.every or (opts.after or 0)
                _timer_schedule(opts.id or "", every, seconds, opts.handler or "")
            end,
            cancel = function(id) _timer_cancel(id or "") end,
        },
        log = {
            info  = function(m) _log("info",  m or "") end,
            warn  = function(m) _log("warn",  m or "") end,
            error = function(m) _log("error", m or "") end,
        },
        env = { get = __h_env_get },
        -- Fallback web-search providers shown in the runner when a query has no
        -- local match (system-only; stubbed for non-system exts). list()/save(json)
        -- round-trip the provider array; get_mode()/set_mode(bool) toggle always-
        -- append vs empty-only; import_browser() pulls engines from the default
        -- browser and returns the count added.
        fallback = {
            list          = __h_fallback_list,
            save          = function(json) _fallback_save(json or "[]") end,
            get_mode      = __h_fallback_mode_get,
            set_mode      = function(on) _fallback_mode_set(on and true or false) end,
            import_browser = __h_fallback_import,
        },
    }
    __h_clip_read = nil; __h_clip_write = nil; __h_clip_history = nil
    __h_llm_complete = nil; __h_llm_translate = nil
    __h_shell_run = nil
    __h_fallback_list = nil; __h_fallback_save = nil
    __h_fallback_mode_get = nil; __h_fallback_mode_set = nil; __h_fallback_import = nil
    __h_pref_get = nil; __h_pref_set = nil
    __h_perms_has = nil
    __h_notify = nil
    __h_time = nil; __h_sleep = nil
    __h_timer_schedule = nil; __h_timer_cancel = nil
    __h_log = nil; __h_env_get = nil
    -- __h_http_request, __h_window_frame/__h_window_set and __h_fs_list_dirs stay
    -- alive; host.http, host.window and host.fs are assembled in the UI bootstrap
    -- (they need host.json's decoder, defined there) and nil'd afterwards.
    """

    /// Pure-Lua UI layer: a minimal JSON codec plus `host.ui` builders so a view
    /// command can return a component tree as a JSON string through the existing
    /// `String?` handler contract. No native bindings — runs entirely in-VM.
    /// Extended string delimiters keep Lua's own backslash escapes literal.
    private static let uiBootstrap = #"""
    local function json_encode(v)
        local t = type(v)
        if t == "nil" then return "null"
        elseif t == "boolean" then return v and "true" or "false"
        elseif t == "number" then
            if v ~= v or v == math.huge or v == -math.huge then return "null" end
            if v == math.floor(v) then return string.format("%d", v) end
            return string.format("%.14g", v)
        elseif t == "string" then
            local out = v:gsub('[%z\1-\31\\"]', function(c)
                local map = { ['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
                return map[c] or string.format('\\u%04x', string.byte(c))
            end)
            return '"' .. out .. '"'
        elseif t == "table" then
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            if n > 0 and #v == n then
                local parts = {}
                for _, item in ipairs(v) do parts[#parts + 1] = json_encode(item) end
                return "[" .. table.concat(parts, ",") .. "]"
            end
            local parts = {}
            for k, val in pairs(v) do
                parts[#parts + 1] = json_encode(tostring(k)) .. ":" .. json_encode(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
        return "null"
    end

    -- Compact recursive-descent JSON decoder (for the form payload an action
    -- handler receives). Returns the decoded value, or nil on malformed input.
    local function json_decode(s)
        if type(s) ~= "string" then return nil end
        local i, n = 1, #s
        local parse_value
        local function skip()
            while i <= n do
                local c = s:sub(i, i)
                if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end
            end
        end
        local function parse_string()
            i = i + 1 -- opening quote
            local buf = {}
            while i <= n do
                local c = s:sub(i, i)
                if c == '"' then i = i + 1; return table.concat(buf)
                elseif c == "\\" then
                    local e = s:sub(i + 1, i + 1)
                    local map = { ['"']='"', ['\\']='\\', ['/']='/', n='\n', r='\r', t='\t', b='\b', f='\f' }
                    if e == "u" then
                        local hex = s:sub(i + 2, i + 5)
                        buf[#buf + 1] = utf8.char(tonumber(hex, 16) or 0)
                        i = i + 6
                    else
                        buf[#buf + 1] = map[e] or e
                        i = i + 2
                    end
                else
                    buf[#buf + 1] = c; i = i + 1
                end
            end
            return table.concat(buf)
        end
        local function parse_object()
            i = i + 1; local obj = {}; skip()
            if s:sub(i, i) == "}" then i = i + 1; return obj end
            while true do
                skip(); local key = parse_string(); skip()
                i = i + 1 -- colon
                obj[key] = parse_value(); skip()
                local c = s:sub(i, i); i = i + 1
                if c == "}" then break elseif c ~= "," then break end
            end
            return obj
        end
        local function parse_array()
            i = i + 1; local arr = {}; skip()
            if s:sub(i, i) == "]" then i = i + 1; return arr end
            while true do
                arr[#arr + 1] = parse_value(); skip()
                local c = s:sub(i, i); i = i + 1
                if c == "]" then break elseif c ~= "," then break end
            end
            return arr
        end
        parse_value = function()
            skip()
            local c = s:sub(i, i)
            if c == '"' then return parse_string()
            elseif c == "{" then return parse_object()
            elseif c == "[" then return parse_array()
            elseif c == "t" then i = i + 4; return true
            elseif c == "f" then i = i + 5; return false
            elseif c == "n" then i = i + 4; return nil
            else
                local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
                if num then i = i + #num; return tonumber(num) end
                return nil
            end
        end
        local ok, result = pcall(parse_value)
        if ok then return result end
        return nil
    end

    -- Both directions are native: heavy JSON work happens in Foundation, not a
    -- char-by-char Lua loop. The pure-Lua json_encode/json_decode defined above
    -- stay as the in-VM fallback for the internal http/agent/window consumers
    -- (small payloads), but the extension-facing host.json — and host.ui.render
    -- below — use the native codec. `raw_json_encode` keeps the binding alive
    -- after the global is cleared.
    local raw_json_encode = __h_json_encode
    host.json = { encode = raw_json_encode, decode = __h_json_decode }
    __h_json_encode = nil
    __h_json_decode = nil

    -- Upgrade host.llm.translate to return a structured table instead of the raw
    -- JSON string the native bridge produces. Shape:
    --   { primary = "...", detected = "EN"|nil,
    --     candidates = { { text=, label=, note= }, ... } }
    -- Empty/failed translation => nil. This is the rich surface extensions use to
    -- build result views (host.ui.list of candidates + detected-language header).
    do
        local raw_translate = host.llm.translate
        host.llm.translate = function(text, target, source)
            local raw = raw_translate(text, target, source)
            if raw == nil or raw == "" then return nil end
            local t = json_decode(raw)
            if type(t) ~= "table" or t.primary == nil or t.primary == "" then return nil end
            if t.detected == "" then t.detected = nil end
            t.candidates = t.candidates or {}
            return t
        end
    end

    -- HTTP, with automatic retry + exponential backoff on transient failures
    -- (no response, or 5xx / 408 / 429). The raw binding (__h_http_request)
    -- returns a JSON string {status, body, headers} or nil. Decoded here so
    -- extensions get a Lua table; `body_json()` lazily parses the body.
    --
    --   host.http.request{ url=, method=, headers=, body=, timeout=,
    --                      retries=, backoff= } -> resp | nil, err
    --   host.http.get(url [, opts]) -> resp | nil, err
    --
    -- `resp` = { status, body, headers, ok = (status >= 200 and < 300),
    --            json = <decoded body or nil> }. On total failure returns
    --            nil plus an error string (last status or "request failed").
    -- Capture the raw binding into an upvalue BEFORE it is nil'd below, so the
    -- closure keeps a live reference (Lua resolves globals at call time).
    local raw_http = __h_http_request
    local function http_should_retry(status)
        return status == nil or status == 408 or status == 429
            or (status >= 500 and status <= 599)
    end
    local function http_request(opts)
        opts = opts or {}
        local url = opts.url
        if type(url) ~= "string" or #url == 0 then return nil, "missing url" end
        local method  = opts.method or "GET"
        local timeout = opts.timeout or 0
        local headers = opts.headers and json_encode(opts.headers) or "{}"
        local body    = opts.body
        local retries = opts.retries or 2           -- total attempts = retries + 1
        local backoff = opts.backoff or 0.4         -- seconds, doubled each retry
        local attempt, last_status, raw = 0, nil, nil
        while attempt <= retries do
            raw = raw_http(method, url, headers, body, timeout)
            local resp = raw and json_decode(raw) or nil
            last_status = resp and resp.status or nil
            if resp and not http_should_retry(last_status) then
                resp.ok = last_status >= 200 and last_status < 300
                resp.json = resp.body and json_decode(resp.body) or nil
                return resp
            end
            attempt = attempt + 1
            if attempt <= retries then
                host.sleep(backoff * (2 ^ (attempt - 1)))   -- exponential backoff
            end
        end
        if raw then
            local resp = json_decode(raw)
            if resp then
                resp.ok = (last_status or 0) >= 200 and (last_status or 0) < 300
                resp.json = resp.body and json_decode(resp.body) or nil
                return resp, "http " .. tostring(last_status)
            end
        end
        return nil, last_status and ("http " .. tostring(last_status)) or "request failed"
    end
    host.http = {
        request = http_request,
        get  = function(url, opts) opts = opts or {}; opts.url = url; opts.method = "GET";  return http_request(opts) end,
        post = function(url, opts) opts = opts or {}; opts.url = url; opts.method = "POST"; return http_request(opts) end,
    }
    __h_http_request = nil

    -- Window management (Accessibility). frame() returns the focused window's
    -- rect and its screen's visible frame in a top-left global coordinate space;
    -- set(x,y,w,h) moves/resizes it. Returns nil / false when no window is
    -- focused or Accessibility permission is missing.
    --   host.window.frame() -> { x, y, w, h, screen = { x, y, w, h } } | nil
    --   host.window.set(x, y, w, h) -> boolean
    local raw_win_frame = __h_window_frame
    local raw_win_set   = __h_window_set
    local raw_win_open  = __h_window_open
    local raw_win_close = __h_window_close
    host.window = {
        frame = function()
            local raw = raw_win_frame()
            return raw and json_decode(raw) or nil
        end,
        set = function(x, y, w, h) return raw_win_set(x, y, w, h) end,
        -- Open a standalone host-rendered window from a declarative node built
        -- with host.ui.* (e.g. host.ui.converter). The host owns every pixel; the
        -- window's controls dispatch back into this extension's Lua globals.
        --   host.window.open(host.ui.converter{ ... })
        open = function(node) raw_win_open(json_encode(node)) end,
        -- Dismiss the open host window. Used by a form/dialog submit handler to
        -- close itself after persisting (host.window.close()).
        close = function() raw_win_close() end,
    }
    __h_window_frame = nil
    __h_window_set = nil
    __h_window_open = nil
    __h_window_close = nil

    -- Open the Prosper Settings window at this extension's pane.
    --   host.settings.open()            -- first declared section
    --   host.settings.open("sectionId") -- a specific section
    local raw_settings_open = __h_settings_open
    host.settings = { open = function(sectionID) raw_settings_open(sectionID or "") end }
    __h_settings_open = nil

    -- Filesystem (read-only). Lists the immediate subdirectory names of `path`
    -- (tilde-expanded host-side, hidden entries skipped, sorted) as a Lua array;
    -- {} on a missing/unreadable path. The only filesystem capability exposed.
    --   host.fs.list_dirs(path) -> { "name", ... }
    local raw_fs_list = __h_fs_list_dirs
    host.fs = {
        list_dirs = function(path)
            local raw = raw_fs_list(path or "")
            return raw and json_decode(raw) or {}
        end,
    }
    __h_fs_list_dirs = nil

    -- Power / battery / network / screen (Hammerspoon openlid parity). Reads are
    -- open; the caffeinate writes are privileged (no-op stubs otherwise). Captured
    -- as upvalues before the globals are cleared, like http / fs above.
    local raw_caf_idle        = __h_caf_idle
    local raw_caf_lidsleep    = __h_caf_lidsleep
    local raw_caf_lock        = __h_caf_lock
    local raw_caf_screensaver = __h_caf_screensaver
    host.caffeinate = {
        -- prevent_idle_sleep(kind, on): kind = "display" | "system".
        prevent_idle_sleep    = function(kind, on) raw_caf_idle(kind or "display", on and true or false) end,
        set_disable_lid_sleep = function(on) raw_caf_lidsleep(on and true or false) end,
        lock_screen           = function() raw_caf_lock() end,
        start_screensaver     = function() raw_caf_screensaver() end,
    }
    __h_caf_idle = nil; __h_caf_lidsleep = nil; __h_caf_lock = nil; __h_caf_screensaver = nil

    local raw_bat_source = __h_battery_source
    local raw_bat_pct    = __h_battery_pct
    host.battery = {
        power_source = function() return raw_bat_source() end,
        -- nil when there is no battery (host returns -1).
        percentage   = function() local p = raw_bat_pct(); return p >= 0 and p or nil end,
    }
    __h_battery_source = nil; __h_battery_pct = nil

    local raw_net_reach = __h_network_reachable
    host.network = { is_reachable = function() return raw_net_reach() end }
    __h_network_reachable = nil

    local raw_screen_all = __h_screen_all
    local raw_screen_lid = __h_screen_lid
    host.screen = {
        all   = function() return json_decode(raw_screen_all()) or {} end,
        count = function() local a = json_decode(raw_screen_all()); return a and #a or 0 end,
        -- true | false | nil(unknown, e.g. desktop).
        lid_closed = function() local v = raw_screen_lid(); if v < 0 then return nil end; return v == 1 end,
    }
    __h_screen_all = nil; __h_screen_lid = nil

    -- Local calendar breakdown of now (sandbox has no os.date).
    --   host.date() -> { epoch, year, month, day, hour, min, sec, wday }
    local raw_date = __h_date
    host.date = function() return json_decode(raw_date()) or {} end
    __h_date = nil

    -- Host-rendered menubar + dialogs + alert HUD (openlid UI surface; privileged,
    -- no-op stubs otherwise). The host owns the NSStatusItem; a menu item's
    -- `handler` is a named global re-invoked with `payload` (JSON) on click — the
    -- same stateless event model as timers.
    --   host.menubar.set{ id=, title=, icon=, menu={ {title=, handler=, payload=} | {separator=true} } }
    --   host.menubar.remove(id)
    --   host.dialog.prompt{ title=, message=, default=, ok=, cancel= } -> string | nil(cancel)
    --   host.dialog.confirm{ title=, message=, ok=, cancel= }          -> boolean
    --   host.alert.show(text [, seconds])   -- transient on-screen HUD
    local raw_menubar_set    = __h_menubar_set
    local raw_menubar_remove = __h_menubar_remove
    local raw_dialog_prompt  = __h_dialog_prompt
    local raw_dialog_confirm = __h_dialog_confirm
    local raw_alert_show     = __h_alert_show
    host.menubar = {
        set    = function(opts) raw_menubar_set((opts and opts.id) or "", raw_json_encode(opts or {})) end,
        remove = function(id) raw_menubar_remove(id or "") end,
    }
    host.dialog = {
        prompt  = function(opts) return raw_dialog_prompt(raw_json_encode(opts or {})) end,
        confirm = function(opts) return raw_dialog_confirm(raw_json_encode(opts or {})) end,
    }
    host.alert = { show = function(text, seconds) raw_alert_show(text or "", seconds or 0) end }
    __h_menubar_set = nil; __h_menubar_remove = nil
    __h_dialog_prompt = nil; __h_dialog_confirm = nil; __h_alert_show = nil

    -- App launcher search. Returns a Lua array of { name = , path = } ranked
    -- application matches for `query` ({} when nothing matches), decoded from the
    -- host's JSON array. Powers the `open` system extension.
    --   host.apps.search(query) -> { { name = , path = }, ... }
    --   host.apps.launch_or_focus(name|bundleID)   -- launch if not running, else activate
    --   host.apps.hide(bundleID)
    --   host.apps.frontmost()        -> { name=, bundleID=, pid= }
    --   host.apps.windows(bundleID)  -> integer (AX window count; 0 if no a11y grant)
    local raw_apps_search = __h_apps_search
    local raw_app_launch    = __h_app_launch
    local raw_app_hide      = __h_app_hide
    local raw_app_frontmost = __h_app_frontmost
    local raw_app_windows   = __h_app_windows
    host.apps = {
        search = function(query)
            local raw = raw_apps_search(query or "")
            return raw and json_decode(raw) or {}
        end,
        launch_or_focus = function(name) raw_app_launch(name or "") end,
        hide            = function(bundleID) raw_app_hide(bundleID or "") end,
        frontmost       = function() return json_decode(raw_app_frontmost()) or {} end,
        windows         = function(bundleID) return raw_app_windows(bundleID or "") end,
    }
    __h_apps_search = nil
    __h_app_launch = nil; __h_app_hide = nil; __h_app_frontmost = nil; __h_app_windows = nil

    -- AppleScript / JXA bridge (privileged). Returns { ok=, output=, error= }.
    --   host.osascript.run(source) -> { ok=, output=, error= }
    local raw_osascript = __h_osascript
    host.osascript = { run = function(src) return json_decode(raw_osascript(src or "")) or {} end }
    __h_osascript = nil

    -- Keyboard input source (Carbon TIS). Reads open; set privileged.
    --   host.keyboard.current_source()  -> id string
    --   host.keyboard.layouts()         -> { { id=, name= }, ... }
    --   host.keyboard.set_source(id)    -> boolean
    local raw_kbd_current = __h_kbd_current
    local raw_kbd_layouts = __h_kbd_layouts
    local raw_kbd_set     = __h_kbd_set
    host.keyboard = {
        current_source = function() return raw_kbd_current() end,
        layouts        = function() return json_decode(raw_kbd_layouts()) or {} end,
        set_source     = function(id) return raw_kbd_set(id or "") end,
    }
    __h_kbd_current = nil; __h_kbd_layouts = nil; __h_kbd_set = nil

    -- Declarative per-app key remaps (§D) + synthetic injection (§E). Rules are
    -- evaluated NATIVELY in the event tap (no Lua per keystroke) — register the full
    -- set once from on_launch; an empty list clears them.
    --   host.keys.set_rules{
    --     { from = "cmd+shift+i", to = "cmd+alt+i", apps = { "com.apple.Safari" } },
    --     { from = "f8", system = "PLAY" },
    --     { from = "cmd+q", double_tap = "cmd+q" },   -- single swallowed; double quits
    --     { from = "f5", swallow = true },
    --   }
    --   host.keys.stroke("cmd+alt+i")   -- inject a combo
    --   host.keys.system("PLAY")        -- inject a media key
    local raw_keys_rules  = __h_keys_rules
    local raw_keys_stroke = __h_keys_stroke
    local raw_keys_system = __h_keys_system
    host.keys = {
        set_rules = function(rules) raw_keys_rules(raw_json_encode(rules or {})) end,
        stroke    = function(spec) raw_keys_stroke(spec or "") end,
        system    = function(name) raw_keys_system(name or "") end,
    }
    __h_keys_rules = nil; __h_keys_stroke = nil; __h_keys_system = nil

    -- URLs + default browser (§O). Set Prosper default to receive opened links as
    -- the "url.open" event ({ url }) — a url-dispatcher then rewrites/forwards them.
    --   host.url.open(url [, bundleID])     -- open (optionally in a chosen browser)
    --   host.url.default_browser()          -> bundle id of current http handler
    --   host.url.set_default_browser(id)    -> boolean  (privileged)
    local raw_url_open        = __h_url_open
    local raw_url_default     = __h_url_default
    local raw_url_set_default = __h_url_set_default
    host.url = {
        open                = function(u, bundleID) return raw_url_open(u or "", bundleID) end,
        default_browser     = function() return raw_url_default() end,
        set_default_browser = function(id) return raw_url_set_default(id or "") end,
    }
    __h_url_open = nil; __h_url_default = nil; __h_url_set_default = nil

    -- Filesystem reads + watch (§Q). watch fires a NAMED handler with { paths } when
    -- the path (file or dir tree) changes — register from on_launch, stateless.
    --   host.fs.exists(path)        -> boolean
    --   host.fs.attributes(path)    -> { exists, isDir, size, mtime }
    --   host.fs.watch(path, "handler_name")   (privileged)
    --   host.fs.unwatch(path)                 (privileged)
    local raw_fs_exists  = __h_fs_exists
    local raw_fs_attrs   = __h_fs_attrs
    local raw_fs_read    = __h_fs_read
    local raw_fs_watch   = __h_fs_watch
    local raw_fs_unwatch = __h_fs_unwatch
    -- EXTEND the existing host.fs (do not reassign — that would drop `list_dirs`
    -- wired above).
    host.fs.exists     = function(p) return raw_fs_exists(p or "") end
    host.fs.attributes = function(p) return json_decode(raw_fs_attrs(p or "")) or {} end
    host.fs.read       = function(p) return raw_fs_read(p or "") end   -- string | nil (privileged)
    host.fs.watch      = function(p, handler) raw_fs_watch(p or "", handler or "") end
    host.fs.unwatch    = function(p) raw_fs_unwatch(p or "") end
    __h_fs_exists = nil; __h_fs_attrs = nil; __h_fs_read = nil; __h_fs_watch = nil; __h_fs_unwatch = nil

    -- Snippets (host.snippets). Native store + placeholder engine: CRUD plus
    -- expand(keyword [, args]) which returns the resolved text (dates, clipboard,
    -- arguments, … applied). The hackable surface for snippet management.
    --   host.snippets.all()                    -> { { name=, keyword=, text=, ... }, ... }
    --   host.snippets.get(name)                -> { ... } | nil
    --   host.snippets.save{ name=, keyword=, text=, ... }   (upsert by name)
    --   host.snippets.remove(name)
    --   host.snippets.expand(keyword [, args]) -> string
    local raw_sn_all    = __h_snippets_all
    local raw_sn_get    = __h_snippets_get
    local raw_sn_save   = __h_snippets_save
    local raw_sn_remove = __h_snippets_remove
    local raw_sn_expand = __h_snippets_expand
    local raw_sn_config          = __h_snippets_config
    local raw_sn_set_config      = __h_snippets_set_config
    local raw_sn_collections     = __h_snippets_collections
    local raw_sn_set_collections = __h_snippets_set_collections
    local raw_sn_ignored         = __h_snippets_ignored
    local raw_sn_set_ignored     = __h_snippets_set_ignored
    local raw_sn_import_file      = __h_snippets_import_file
    host.snippets = {
        all = function()
            local raw = raw_sn_all()
            return raw and json_decode(raw) or {}
        end,
        get = function(name)
            local raw = raw_sn_get(name or "")
            return raw and json_decode(raw) or nil
        end,
        save = function(s) raw_sn_save(json_encode(s or {})) end,
        remove = function(name) raw_sn_remove(name or "") end,
        expand = function(keyword, args)
            return raw_sn_expand(keyword or "", args and json_encode(args) or nil)
        end,
        -- Settings-page surface (Tier B). config()/collections()/ignored() return
        -- Lua tables; the set_* counterparts replace the whole value natively (so
        -- SnippetStore's file mirror + change token stay in sync). import_file()
        -- opens a native JSON picker and returns a short summary string.
        config = function()
            local raw = raw_sn_config()
            return raw and json_decode(raw) or {}
        end,
        set_config = function(c) raw_sn_set_config(json_encode(c or {})) end,
        collections = function()
            local raw = raw_sn_collections()
            return raw and json_decode(raw) or {}
        end,
        set_collections = function(c) raw_sn_set_collections(json_encode(c or {})) end,
        ignored = function()
            local raw = raw_sn_ignored()
            return raw and json_decode(raw) or {}
        end,
        set_ignored = function(c) raw_sn_set_ignored(json_encode(c or {})) end,
        import_file = function() return raw_sn_import_file() end,
    }
    __h_snippets_all = nil
    __h_snippets_get = nil
    __h_snippets_save = nil
    __h_snippets_remove = nil
    __h_snippets_expand = nil
    __h_snippets_config = nil
    __h_snippets_set_config = nil
    __h_snippets_collections = nil
    __h_snippets_set_collections = nil
    __h_snippets_ignored = nil
    __h_snippets_set_ignored = nil
    __h_snippets_import_file = nil

    -- File finder (Spotlight). search{…} takes an options table — name plus
    -- optional kind/ext/in/content/limit filters — and returns a Lua array of
    -- { name, path, display, isDir, kind, size, modified } hits ({} when nothing
    -- matches). act(id, path) runs a built-in file operation (open / reveal /
    -- quicklook / copyPath / copyFile / openWith / enclosingFolder / trash).
    -- Powers the `files` system extension.
    --   host.files.search{ name=, kind=, ext=, in=, content=, limit= } -> { {…}, ... }
    --   host.files.act(id, path)
    local raw_files_search = __h_files_search
    local raw_files_act = __h_files_act
    host.files = {
        search = function(opts)
            local raw = raw_files_search(json_encode(opts or {}))
            return raw and json_decode(raw) or {}
        end,
        act = function(id, path) raw_files_act(id or "", path or "") end,
    }
    __h_files_search = nil
    __h_files_act = nil

    -- Convenience builders: stamp the discriminator so handlers can write
    -- `return host.ui.render(host.ui.list{ items = {...} })`.
    local function tag(kind)
        return function(opts) opts = opts or {}; opts.type = kind; return opts end
    end
    host.ui = {
        list    = tag("list"),
        detail  = tag("detail"),
        form    = tag("form"),
        grid    = tag("grid"),
        -- A live bidirectional two-pane transform window. Open via
        -- host.window.open. `forward`/`backward` name global Lua functions
        -- (text -> text) in this extension; editing the left pane runs `forward`
        -- into the right, editing the right runs `backward` into the left.
        --   host.ui.converter{ title=, left={label,placeholder,value},
        --                      right={...}, forward="fn", backward="fn", mono= }
        converter = tag("converter"),
        -- Loading states for async work: `progress` nil/absent => infinite
        -- spinner; a number in 0..1 => determinate bar. `title`/`subtitle`
        -- optional. Render while awaiting; replace with the result node.
        loading = tag("loading"),
        -- Native encode: a view command serialises its result tree on every
        -- keystroke, so this is the hot path that most benefits from going native.
        render  = raw_json_encode,
    }

    -- Declarative Settings sections (Tier B). A `settings_render(section_id, state)`
    -- handler returns host.ui.settings.render(host.ui.settings.ui{ sections = {...} }).
    -- Builders are thin sugar; the only required call is `render` (JSON-encode).
    --   ui{ title=, subtitle=, sections={ section{...}, ... } }
    --   section{ id=, title=, accent=, footer=, rows={ row{...}, records{...} } }
    --   row{ id=, kind="toggle|text|secret|number|enum|path|info|permission|button|link",
    --        key=, title=, subtitle=, value=, options=, optionLabels=, name=, url=,
    --        file=, action=, actionID=, style= }
    --   records{ id=, records={ { id=, title=, subtitle=, icon=, fields={ field } } },
    --            addLabel=, revealFile= }   (kind defaults to "records")
    host.ui.settings = {
        ui      = function(opts) opts = opts or {}; opts.type = "settings"; return opts end,
        section = function(opts) return opts or {} end,
        row     = function(opts) return opts or {} end,
        records = function(opts) opts = opts or {}; opts.kind = "records"; return opts end,
        render  = function(node) return json_encode(node) end,
    }
    """#

    /// Decode a JSON object of string→string (the Lua side encodes the request
    /// headers this way). Non-string values are stringified; malformed input
    /// yields an empty map.
    static func decodeStringMap(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = v as? String ?? String(describing: v) }
        return out
    }

    /// Encode an `HTTPResponse` as the JSON string the Lua `host.http` layer
    /// decodes back into a table: `{status, body, headers}`.
    static func encodeResponse(_ resp: HTTPResponse) -> String {
        let obj: [String: Any] = [
            "status": resp.status,
            "body": resp.body,
            "headers": resp.headers,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8)
        else { return "{\"status\":\(resp.status),\"body\":\"\",\"headers\":{}}" }
        return str
    }

    /// Encode a `WindowFrame` as the JSON string `host.window.frame()` decodes
    /// into `{x, y, w, h, screen = {x, y, w, h}}`.
    static func encodeWindowFrame(_ f: WindowFrame) -> String {
        let obj: [String: Any] = [
            "x": f.x, "y": f.y, "w": f.w, "h": f.h,
            "screen": ["x": f.visibleX, "y": f.visibleY, "w": f.visibleW, "h": f.visibleH],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8)
        else { return "{\"x\":0,\"y\":0,\"w\":0,\"h\":0,\"screen\":{\"x\":0,\"y\":0,\"w\":0,\"h\":0}}" }
        return str
    }

    /// Run an async operation to completion synchronously, returning nil if it
    /// does not finish within `timeout`. The calling thread blocks — must not be
    /// the main thread (extensions run on a dedicated queue).
    ///
    /// On timeout the detached task is **cancelled**, not merely abandoned: a hung
    /// `host.http`/`host.llm` would otherwise keep an in-flight URLSession request
    /// (and a cooperative-pool thread) alive long after the extension gave up. The
    /// URLSession async API and structured `Task.sleep` backoff honor cancellation,
    /// so the leaf work actually stops; a non-cancellation-aware op still runs to
    /// completion but its result is discarded (cancel is then a harmless no-op).
    static func awaitSync<T>(timeout: TimeInterval, _ op: @escaping @Sendable () async -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task.detached {
            let value = await op()
            box.set(value)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .success { return box.get() }
        task.cancel()
        return nil
    }

    /// Thread-safe one-shot holder for the bridged async result.
    private final class ResultBox<T>: @unchecked Sendable {
        private var value: T?
        private let lock = NSLock()
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
