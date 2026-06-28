-- Reusable test harness for Prosper Lua extensions.
--
-- Builds a stub `host` table that records side effects (prefs, alerts, timers,
-- power-assertion flags, rendered UI, window/url/agent calls…) so an extension's
-- init.lua can be exercised with a stock `lua` / `luajit` — no running app
-- required. Run all extension tests with scripts/test-extensions.sh; that script
-- puts this dir on LUA_PATH so a test can simply `require("harness")`.
--
-- A test typically does:
--   local h = require("harness")
--   local host, env = h.makeHost{ power = "AC Power" }
--   host.prefs.set("busy_cmd", "dch -ls")
--   local G = h.load(h.dir() .. "init.lua", host)   -- defines the ext globals
--   G.on_battery(host.json.encode{ powerSource = "Battery Power" })
--   h.eq(env.flags.lidDisabled, false, "lid override released")

local M = {}

function M.eq(a, b, msg)
    if a ~= b then
        error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end

-- Assert a <= max (perf/cost budgets).
function M.le(a, max, msg)
    if not (a <= max) then
        error((msg or "le") .. ": expected <= " .. tostring(max) .. ", got " .. tostring(a), 2)
    end
end

-- Zero the host-bridge call counters so the next op's cost can be measured.
function M.resetCalls(env)
    for k in pairs(env.calls) do env.calls[k] = 0 end
end

-- Mean per-call CPU seconds over `iters` runs of fn(): one os.clock() span / iters.
-- Amortizing over many iters beats os.clock's coarse resolution; enough to catch
-- order-of-magnitude (algorithmic) regressions, not for absolute microbenchmarks.
function M.bench(iters, fn)
    local t0 = os.clock()
    for _ = 1, iters do fn() end
    return (os.clock() - t0) / iters
end

-- Directory of the running test file (so it can locate its own init.lua).
function M.dir()
    return (arg[0] or ""):gsub("[^/\\]+$", "")
end

-- ── JSON ─────────────────────────────────────────────────────────────────────
-- A real (compact, recursive) JSON codec. The extensions store nested objects
-- and arrays-of-objects (quickdirs/bookmarks), so the codec must handle them and
-- round-trip — not just flat string maps.
--
-- JSON null decodes to the M.NULL sentinel (a unique table), NOT Lua nil, so it
-- occupies an array slot and array indices never shift. encode(M.NULL) -> "null".
-- Known round-trip limits (no live extension hits them, so left as-is): an empty
-- array [] decodes to {} and re-encodes as {} (indistinguishable from an empty
-- object in Lua), and a mixed table (sequence + string keys) encodes as an object.

local NULL = setmetatable({}, { __tostring = function() return "null" end })
M.NULL = NULL

local function is_array(t)
    local len = #t
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > len then return false end
        count = count + 1
    end
    return len > 0 and count == len
end

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
              ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f' }

local function encode(v)
    if v == NULL then return "null" end
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if math.type(v) == "integer" then return string.format("%d", v) end
        return string.format("%.14g", v)
    elseif t == "string" then
        return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
            return ESC[c] or string.format("\\u%04x", string.byte(c))
        end) .. '"'
    elseif t == "table" then
        local parts = {}
        if is_array(v) then
            for _, e in ipairs(v) do parts[#parts + 1] = encode(e) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, e in pairs(v) do
            parts[#parts + 1] = encode(tostring(k)) .. ":" .. encode(e)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function decode(str)
    if type(str) ~= "string" or #str == 0 then return nil end
    local i, n = 1, #str
    local parse_value

    local function skip_ws()
        while i <= n do
            local c = str:sub(i, i)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end
        end
    end

    local function parse_string()
        i = i + 1 -- opening quote
        local buf = {}
        while i <= n do
            local c = str:sub(i, i)
            if c == '"' then
                i = i + 1
                return table.concat(buf)
            elseif c == "\\" then
                local e = str:sub(i + 1, i + 1)
                if e == "u" then
                    local code = tonumber(str:sub(i + 2, i + 5), 16) or 0
                    if code < 0x80 then
                        buf[#buf + 1] = string.char(code)
                    elseif code < 0x800 then
                        buf[#buf + 1] = string.char(0xC0 | (code >> 6), 0x80 | (code & 0x3F))
                    else
                        buf[#buf + 1] = string.char(0xE0 | (code >> 12),
                            0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F))
                    end
                    i = i + 6
                else
                    local m = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                                n = '\n', t = '\t', r = '\r', b = '\b', f = '\f' }
                    buf[#buf + 1] = m[e] or e
                    i = i + 2
                end
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
        return table.concat(buf)
    end

    local function parse_number()
        local s = i
        while i <= n and str:sub(i, i):match("[%d%+%-%.eE]") do i = i + 1 end
        return tonumber(str:sub(s, i - 1))
    end

    local function parse_object()
        i = i + 1 -- {
        local t = {}
        skip_ws()
        if str:sub(i, i) == "}" then i = i + 1; return t end
        while i <= n do
            skip_ws()
            local key = parse_string()
            skip_ws()
            i = i + 1 -- :
            t[key] = parse_value()
            skip_ws()
            local c = str:sub(i, i)
            if c == "," then i = i + 1
            elseif c == "}" then i = i + 1; break
            else break end
        end
        return t
    end

    local function parse_array()
        i = i + 1 -- [
        local t = {}
        skip_ws()
        if str:sub(i, i) == "]" then i = i + 1; return t end
        while i <= n do
            t[#t + 1] = parse_value()
            skip_ws()
            local c = str:sub(i, i)
            if c == "," then i = i + 1
            elseif c == "]" then i = i + 1; break
            else break end
        end
        return t
    end

    parse_value = function()
        skip_ws()
        local c = str:sub(i, i)
        if c == '"' then return parse_string()
        elseif c == "{" then return parse_object()
        elseif c == "[" then return parse_array()
        elseif c == "t" then i = i + 4; return true
        elseif c == "f" then i = i + 5; return false
        elseif c == "n" then i = i + 4; return NULL
        else return parse_number() end
    end

    local ok, res = pcall(parse_value)
    if not ok then return nil end
    return res
end

M.encode, M.decode = encode, decode

-- Tag a UI node with its kind and return it as-is, so tests can inspect the
-- declarative tree the extension built.
local function uiNode(kind)
    return function(t)
        t = t or {}
        t.kind = kind
        return t
    end
end

-- Build a stub host. opts: { power, pct, shellOut, screens, date, now, frame,
-- apps, files, fsDirs, translateResult, agentResult, httpResponse,
-- setDefaultOK, perms, snippets, shellRouter }.
-- Returns (host, env); inspect env.* and mutate env.* between steps.
function M.makeHost(opts)
    opts = opts or {}
    local env = {
        prefs = {}, alerts = {}, timers = {}, notifications = {},
        flags = { idleSystem = false, idleDisplay = false, lidDisabled = false, locked = false },
        power = opts.power or "AC Power",
        pct = opts.pct or 90,
        shellOut = opts.shellOut or "",
        now = opts.now or 1000,
        frame = opts.frame,
        apps = opts.apps or {},
        files = opts.files or {},
        fsDirs = opts.fsDirs or {},
        translateResult = opts.translateResult,
        agentResult = opts.agentResult,
        httpResponse = opts.httpResponse,
        setDefaultOK = (opts.setDefaultOK ~= false),
        defaultBrowser = opts.defaultBrowser, -- current system default (url.default_browser)
        urlOpens = {},                        -- full log of url.open(url, browser) calls
        perms = opts.perms or {},
        snippets = opts.snippets or {},
        snippetCollections = opts.snippetCollections or {},
        snippetIgnored = opts.snippetIgnored or {},
        snippetConfig = opts.snippetConfig or { enabled = true, autoExpand = true,
            wordBoundary = true, restoreClipboard = false },
        windowClosed = 0,
        -- shellRouter(cmd) -> string lets a test return different output per command.
        shellRouter = opts.shellRouter,
        -- Host-bridge call counters. Each real call is a Lua→Swift hop (and often a
        -- UserDefaults / pmset / NSScreen syscall), so counting them is a stable,
        -- timing-free proxy for an extension's per-event cost. h.resetCalls(env)
        -- before an op, then assert env.calls.* budgets after.
        calls = { prefsGet = 0, prefsSet = 0, shell = 0, timerSchedule = 0,
                  timerCancel = 0, menubarSet = 0, screen = 0, battery = 0, http = 0 },
    }
    local function shell_run(cmd)
        env.calls.shell = env.calls.shell + 1
        if env.shellRouter then return env.shellRouter(cmd) end
        return env.shellOut
    end
    local settings = {
        ui = uiNode("settings.ui"),
        section = uiNode("settings.section"),
        row = uiNode("settings.row"),
        records = uiNode("settings.records"),
        render = function(node) env.settingsRendered = node; return node end,
    }
    local host = {
        prefs = {
            get = function(k) env.calls.prefsGet = env.calls.prefsGet + 1; return env.prefs[k] end,
            set = function(k, v) env.calls.prefsSet = env.calls.prefsSet + 1; env.prefs[k] = tostring(v) end,
        },
        json = { encode = encode, decode = decode },
        shell = { run = shell_run },
        timer = {
            schedule = function(o) env.calls.timerSchedule = env.calls.timerSchedule + 1; env.timers[o.id] = o end,
            cancel = function(id) env.calls.timerCancel = env.calls.timerCancel + 1; env.timers[id] = nil end,
        },
        alert = { show = function(m) env.alerts[#env.alerts + 1] = m end },
        notify = function(t, b) env.notifications[#env.notifications + 1] = { title = t, body = b } end,
        caffeinate = {
            prevent_idle_sleep = function(kind, on)
                if kind == "display" then env.flags.idleDisplay = on else env.flags.idleSystem = on end
            end,
            set_disable_lid_sleep = function(on) env.flags.lidDisabled = on end,
            lock_screen = function() env.flags.locked = true end,
            set_remote_wake = function(t) env.flags.remoteWake = t and t.enabled or false end,
            start_screensaver = function() env.flags.screensaver = true end,
            sleep_now = function() env.flags.sleepNow = (env.flags.sleepNow or 0) + 1 end,
        },
        battery = {
            power_source = function() env.calls.battery = env.calls.battery + 1; return env.power end,
            percentage = function() env.calls.battery = env.calls.battery + 1; return env.pct end,
        },
        screen = { count = function() env.calls.screen = env.calls.screen + 1; return opts.screens or 1 end },
        dch = { sessions = function() return opts.dchSessions or {} end },
        time = function() return env.now end,
        date = function() return opts.date or { hour = 12, min = 0, sec = 0 } end,
        menubar = { set = function(t) env.calls.menubarSet = env.calls.menubarSet + 1; env.menu = t end,
                    remove = function() env.menu = nil end },
        settings = { open = function(id) env.settingsOpened = id end },
        dialog = { prompt = function(o) env.dialogPrompt = o; return env.dialogReply end },
        network = {
            addresses = function() return opts.addresses or {} end,
            reachable = function() return env.reachable ~= false end,
        },

        -- Declarative UI surface: constructors tag-and-return the node; render
        -- records it and returns it so the extension's return value is inspectable.
        ui = {
            list = uiNode("list"),
            form = uiNode("form"),
            converter = uiNode("converter"),
            render = function(node) env.rendered = node; return node end,
            settings = settings,
        },

        window = {
            open = function(node) env.window = node end,
            close = function() env.windowClosed = env.windowClosed + 1 end,
            frame = function() return env.frame end,
            set = function(x, y, w, h) env.windowSet = { x = x, y = y, w = w, h = h } end,
        },

        apps = { search = function(q) env.appQuery = q; return env.apps end },
        files = {
            search = function(o) env.fileQuery = o; return env.files end,
            act = function(id, path) env.fileAct = { id = id, path = path } end,
        },
        fs = { list_dirs = function(path) return env.fsDirs[path] or {} end },
        llm = {
            translate = function(text, target, source)
                env.translateArgs = { text = text, target = target, source = source }
                return env.translateResult
            end,
        },
        agent = {
            run = function(goal, o)
                env.agentArgs = { goal = goal, opts = o }
                return env.agentResult
            end,
        },
        http = {
            -- Mirrors the real host wrapper: env.httpResponse is the WIRE shape
            -- ({ status, body = <json string>, headers }); the stub synthesizes
            -- ok = status∈[200,300) and json = decode(body), so tests exercise
            -- the real status→ok / body→json transform instead of pre-baking it.
            -- Divergence (intentional): no retry/backoff (real wrapper retries
            -- 5xx/408/429) — the stub answers once. On a non-ok status it returns
            -- (resp, "http <status>"); currency reads only resp and gates on ok.
            get = function(url, o)
                env.calls.http = env.calls.http + 1
                env.httpArgs = { url = url, opts = o }
                local wire = env.httpResponse
                if wire == nil then return nil, "request failed" end
                -- Fresh resp per call (the real host decodes raw→resp anew each
                -- time), so the caller's fixture table is never mutated.
                local status = wire.status or 0
                local resp = { status = status, body = wire.body, headers = wire.headers,
                               ok = status >= 200 and status < 300,
                               json = wire.body and decode(wire.body) or nil }
                if resp.ok then return resp end
                return resp, "http " .. tostring(status)
            end,
        },
        url = {
            -- Every open is recorded (last in env.urlOpened, full log in env.urlOpens)
            -- so a router test can assert the browser each link went to.
            open = function(u, b)
                env.urlOpened = { url = u, browser = b }
                env.urlOpens[#env.urlOpens + 1] = env.urlOpened
            end,
            default_browser = function() return env.defaultBrowser end,
            set_default_browser = function(id)
                env.defaultBrowserSet = id
                if env.setDefaultOK then env.defaultBrowser = id end
                return env.setDefaultOK
            end,
        },
        perms = { has = function(name) return env.perms[name] == true end },

        -- Snippet store, backed by env tables so management verbs can be tested.
        snippets = {
            all = function() return env.snippets end,
            save = function(s)
                for i, e in ipairs(env.snippets) do
                    if e.name == s.name then env.snippets[i] = s; return end
                end
                env.snippets[#env.snippets + 1] = s
            end,
            remove = function(name)
                for i, e in ipairs(env.snippets) do
                    if e.name == name then table.remove(env.snippets, i); return end
                end
            end,
            expand = function(name)
                for _, e in ipairs(env.snippets) do
                    if e.name == name then return e.expanded or e.text end
                end
                return nil
            end,
            config = function() return env.snippetConfig end,
            set_config = function(patch)
                for k, v in pairs(patch) do env.snippetConfig[k] = v end
            end,
            collections = function() return env.snippetCollections end,
            set_collections = function(list) env.snippetCollections = list end,
            ignored = function() return env.snippetIgnored end,
            set_ignored = function(list) env.snippetIgnored = list end,
            import_file = function() env.snippetImported = true end,
        },
    }
    env.host = host
    return host, env
end

-- Load an extension's init.lua with `host` installed as a global. Returns the
-- global table so the test can call the handlers the extension defined.
function M.load(initPath, host)
    _G.host = host
    local chunk = assert(loadfile(initPath))
    chunk()
    return _G
end

-- Convenience: the last alert string shown (what the user would see in a toast).
function M.lastAlert(env) return env.alerts[#env.alerts] end

return M
