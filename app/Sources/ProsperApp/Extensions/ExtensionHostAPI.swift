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
    // Coding agent (user-permissioned; same trust domain as shell). Fire-and-poll:
    // `agentRun` starts a run, opens the agent window so it is visible and approvals
    // can be answered, and returns a JSON `{ "runId": ... }` (or `{ "error": ... }`).
    // `agentStatus`/`agentResult` poll that handle. All return JSON object strings.
    // Synchronous (quick fire / state reads) — never block the extension worker for
    // the lifetime of a multi-minute run.
    func agentRun(goal: String, cwd: String?, optsJSON: String?) -> String
    func agentStatus(_ runID: String) -> String
    func agentResult(_ runID: String) -> String
    // Outbound HTTP (trusted-extension capability; http/https only, size-capped).
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse?
    // Focused-window geometry (Accessibility; same trust domain as the
    // autocomplete caret tracking). Coordinates are a top-left global space.
    func focusedWindowFrame() -> WindowFrame?
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool
    // Wall-clock, for cache keys / scheduling (the sandbox removes `os`).
    func currentEpochSeconds() -> Double
    // Per-extension settings (typed values declared in the manifest).
    func prefGet(extensionID: String, key: String) -> String?
    func prefSet(extensionID: String, key: String, value: String)
    // User notification.
    func notify(title: String, body: String)
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

    /// Default: no grants (test / minimal hosts). The live host overrides this
    /// with real `PermissionsManager` checks.
    func permissionGranted(_ name: String) -> Bool { false }

    /// Default: no agent backend (test / minimal hosts). The live host overrides
    /// these to drive `AgentController`.
    func agentRun(goal: String, cwd: String?, optsJSON: String?) -> String { #"{"error":"agent unavailable"}"# }
    func agentStatus(_ runID: String) -> String { #"{"error":"agent unavailable"}"# }
    func agentResult(_ runID: String) -> String { #"{"error":"agent unavailable"}"# }
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
    /// Bundled system extensions get the privileged surface (`host.shell`,
    /// `host.agent` — arbitrary command execution / workspace-write agent runs);
    /// user/remote-installed ones get error stubs. `isSystem` is derived from the
    /// bundle dir, not the manifest, so a remote extension can't claim it.
    let privileged: Bool

    init(extensionID: String,
         services: ExtensionHostServices,
         callTimeout: TimeInterval = ExtensionHost.defaultCallTimeout,
         privileged: Bool = true) {
        self.extensionID = extensionID
        self.services = services
        self.callTimeout = callTimeout
        self.privileged = privileged
    }

    /// Register every host function and assemble the `host` table. Call before
    /// running the extension's entry script.
    func install(into lua: LuaRuntime) throws {
        let services = self.services
        let extID = self.extensionID
        let timeout = self.callTimeout

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

        // --- agent (coding-agent runs; sync fire-and-poll; system extensions only:
        // a run gets workspace-write in its chosen cwd) ---
        // run(goal, optsJSON?) starts a run + returns {runId|error}; status/result
        // poll by runId. JSON strings; the UI bootstrap decodes them into tables.
        if privileged {
            lua.register("__h_agent_run") { rt in
                let goal = rt.stringArgument(1) ?? ""
                let opts = rt.stringArgument(2)
                rt.push(services.agentRun(goal: goal, cwd: nil, optsJSON: opts))
                return 1
            }
            lua.register("__h_agent_status") { rt in
                rt.push(services.agentStatus(rt.stringArgument(1) ?? ""))
                return 1
            }
            lua.register("__h_agent_result") { rt in
                rt.push(services.agentResult(rt.stringArgument(1) ?? ""))
                return 1
            }
        } else {
            let denied = "{\"error\":\"host.agent is restricted to system extensions\"}"
            for name in ["__h_agent_run", "__h_agent_status", "__h_agent_result"] {
                lua.register(name) { rt in
                    rt.push(denied)
                    return 1
                }
            }
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

        // Assemble the namespaced `host` table and hide the raw bindings.
        try lua.run(Self.bootstrap, name: "@host-bootstrap")
        // Layer on the pure-Lua UI helpers (host.json + host.ui builders) used
        // by `mode = "view"` commands to return component trees (ADR-002 §D7).
        try lua.run(Self.uiBootstrap, name: "@host-ui-bootstrap")
    }

    /// Lua that groups the flat `__h_*` bindings under `host.*` then removes the
    /// raw globals so extensions only see the namespaced API.
    private static let bootstrap = """
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
    }
    __h_clip_read = nil; __h_clip_write = nil; __h_clip_history = nil
    __h_llm_complete = nil; __h_llm_translate = nil
    __h_shell_run = nil
    __h_pref_get = nil; __h_pref_set = nil
    __h_perms_has = nil
    __h_notify = nil
    __h_time = nil; __h_sleep = nil
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

    -- App launcher search. Returns a Lua array of { name = , path = } ranked
    -- application matches for `query` ({} when nothing matches), decoded from the
    -- host's JSON array. Powers the `open` system extension.
    --   host.apps.search(query) -> { { name = , path = }, ... }
    local raw_apps_search = __h_apps_search
    host.apps = {
        search = function(query)
            local raw = raw_apps_search(query or "")
            return raw and json_decode(raw) or {}
        end,
    }
    __h_apps_search = nil

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

    -- Coding agent (host.agent). Drives the goal-prompt coding agent. run() starts
    -- a session — opening the agent window so the run is visible and tool approvals
    -- can be answered — and returns { runId = } or { error = }; status()/result()
    -- poll it. `opts` is an optional table { cwd = , ... }. Returns Lua tables
    -- (decoded from the host's JSON), so handlers never touch host.json directly.
    --   host.agent.run(goal [, opts]) -> { runId = } | { error = }
    --   host.agent.status(runId)      -> { phase=, active=, items=, approvals=, ... }
    --   host.agent.result(runId)      -> { done=, phase=, text=, error= }
    local raw_agent_run    = __h_agent_run
    local raw_agent_status = __h_agent_status
    local raw_agent_result = __h_agent_result
    host.agent = {
        run = function(goal, opts)
            local raw = raw_agent_run(goal or "", opts and json_encode(opts) or nil)
            return raw and json_decode(raw) or { error = "no response" }
        end,
        status = function(run_id)
            local raw = raw_agent_status(run_id or "")
            return raw and json_decode(raw) or { error = "no response" }
        end,
        result = function(run_id)
            local raw = raw_agent_result(run_id or "")
            return raw and json_decode(raw) or { error = "no response" }
        end,
    }
    __h_agent_run = nil
    __h_agent_status = nil
    __h_agent_result = nil

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
    static func awaitSync<T>(timeout: TimeInterval, _ op: @escaping @Sendable () async -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            let value = await op()
            box.set(value)
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .success ? box.get() : nil
    }

    /// Thread-safe one-shot holder for the bridged async result.
    private final class ResultBox<T>: @unchecked Sendable {
        private var value: T?
        private let lock = NSLock()
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }
}
