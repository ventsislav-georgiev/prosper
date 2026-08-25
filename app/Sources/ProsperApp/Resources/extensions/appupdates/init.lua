-- appupdates — pending Homebrew + macOS updates in one list.
--
-- Handler contract: the host invokes the global named after the command id with
-- non-alphanumerics replaced by '_' ("appupdates.check" -> appupdates_check).
--
-- Cost is the whole design. `softwareupdate -l` talks to Apple and takes 10-60 s,
-- so it runs in exactly two places: the background poll and the explicit
-- "Check for Updates Now" command. `appupdates.check` reads the host.prefs cache
-- and shells out to nothing at all — it is the command a user runs constantly,
-- and a runner command's handler is re-invoked as the query changes
-- (RunnerPanel.swift:741-765), so anything it does gets done per keystroke.
-- That is also why this command declares no `prefix`: no typing, no re-runs.
-- See plan 019 §E.
--
-- Notifications are EDGE-TRIGGERED on a rising count: the poll fires every few
-- hours and would otherwise re-nag about the same 3 pending updates forever
-- (the PowerEdgeFilter lesson, ExtensionSystemServices.swift:552-556).

local PREFS_CACHE    = "cache"           -- JSON { at, brew = [...], macos = [...] }
local PREFS_COUNT    = "last_count"      -- integer, the edge the notifier compares against
local PREFS_INTERVAL = "interval_hours"  -- number, default 6
local PREFS_NOTIFY   = "notifications"   -- "true" / "false", default true
local TIMER_ID       = "appupdates.poll"
local KICK_ID        = "appupdates.kick"
local SU_PANE        = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"

-- Both Homebrew prefixes: Apple Silicon and the Intel/rosetta layout. host.shell
-- runs a login shell, but PATH is not guaranteed inside a timer-spawned worker,
-- so resolve an absolute path rather than trusting `brew` to be found.
local BREW_PATHS = { "/opt/homebrew/bin/brew", "/usr/local/bin/brew" }

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function brew_path()
    for _, p in ipairs(BREW_PATHS) do
        if host.fs.exists(p) then return p end
    end
    return nil   -- brew-less Mac: macOS updates only, no error row
end

local function notifications_on() return host.prefs.get(PREFS_NOTIFY) ~= "false" end

local function interval_hours()
    local n = tonumber(host.prefs.get(PREFS_INTERVAL) or "") or 6
    if n < 1 then n = 1 end
    if n > 168 then n = 168 end
    return n
end

-- MARK: - Parsing (pure; the tests drive these with captured fixtures)

-- `installed_versions` is an array for formulae and a bare string for casks.
local function first_version(v)
    if type(v) == "table" then return tostring(v[1] or "?") end
    if v == nil then return "?" end
    return tostring(v)
end

-- brew outdated --json=v2 -> { { name, from, to, cask }, ... }
function parse_brew(json_text)
    local out = {}
    local ok, doc = pcall(host.json.decode, json_text or "")
    if not ok or type(doc) ~= "table" then return out end
    for _, key in ipairs({ "formulae", "casks" }) do
        local list = doc[key]
        if type(list) == "table" then
            for _, p in ipairs(list) do
                if type(p) == "table" and p.name then
                    out[#out + 1] = {
                        name = tostring(p.name),
                        from = first_version(p.installed_versions),
                        to   = tostring(p.current_version or "?"),
                        cask = (key == "casks") or nil,
                    }
                end
            end
        end
    end
    return out
end

-- softwareupdate -l -> { "Safari 18.1", ... }. Text-scrape by necessity: there is
-- no stable machine-readable mode. "No new software available." yields {}.
function parse_softwareupdate(text)
    local titles, labels = {}, {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local title, version = line:match("Title:%s*(.-),%s*Version:%s*([^,]+)")
        if title then
            titles[#titles + 1] = trim(title) .. " " .. trim(version)
        else
            local label = line:match("^%s*%*%s*Label:%s*(.+)$")
            if label then labels[#labels + 1] = trim(label) end
        end
    end
    -- Each update prints a `* Label:` line AND an indented `Title:` line. Prefer
    -- the readable Title pair; the labels are the fallback for terser layouts
    -- that omit it (counting both would double every update).
    return #titles > 0 and titles or labels
end

-- MARK: - Cache

local function load_cache()
    local raw = host.prefs.get(PREFS_CACHE)
    if not raw or #raw == 0 then return { brew = {}, macos = {} } end
    local ok, t = pcall(host.json.decode, raw)
    if not ok or type(t) ~= "table" then return { brew = {}, macos = {} } end
    t.brew  = type(t.brew) == "table" and t.brew or {}
    t.macos = type(t.macos) == "table" and t.macos or {}
    return t
end

local function save_cache(c) host.prefs.set(PREFS_CACHE, host.json.encode(c)) end

local function total(c) return #c.brew + #c.macos end

-- MARK: - Sources (never called from a render path)

local function check_brew()
    local brew = brew_path()
    if not brew then return {} end
    return parse_brew(host.shell.run(brew .. " outdated --json=v2 2>/dev/null"))
end

local function check_macos()
    return parse_softwareupdate(host.shell.run("softwareupdate -l 2>&1"))
end

local function refresh_all()
    local c = { at = host.time(), brew = check_brew(), macos = check_macos() }
    save_cache(c)
    return c
end

-- MARK: - Rendering

local function summary(c)
    local n = total(c)
    if n == 0 then return "Everything is up to date" end
    return n .. " update" .. (n == 1 and "" or "s") .. " pending"
end

local function checked_at(c)
    if not c.at then return "never checked" end
    local mins = math.floor((host.time() - c.at) / 60)
    if mins < 1 then return "checked just now" end
    if mins < 60 then return "checked " .. mins .. "m ago" end
    return "checked " .. math.floor(mins / 60) .. "h ago"
end

local function render(c)
    local items = {}

    for _, p in ipairs(c.brew) do
        -- Informational row. The runner only dispatches a row's `url` / `launch`
        -- on Enter — a custom action id is dropped on the floor
        -- (RunnerPanel.swift:1685-1688 -> FileActions.perform's `default: return
        -- false`), so per-package Enter-to-upgrade is not expressible today.
        -- ponytail: "Upgrade Homebrew Packages" upgrades the lot; wire a per-row
        -- upgrade once list rows can call back into Lua.
        items[#items + 1] = {
            id       = "brew:" .. p.name,
            title    = p.name,
            subtitle = (p.cask and "Cask · " or "Formula · ") .. p.from .. " → " .. p.to,
            icon     = "shippingbox",
        }
    end

    if #c.macos > 0 then
        items[#items + 1] = {
            id       = "macos",
            title    = "macOS: " .. table.concat(c.macos, ", "),
            subtitle = "Open Software Update",
            icon     = "apple.logo",
            url      = SU_PANE,          -- host opens this natively on Enter
        }
    end

    if #items == 0 then
        items[1] = {
            id = "clean", title = "Everything is up to date",
            subtitle = checked_at(c) .. " · run “Check for Updates Now” to re-check",
            icon = "checkmark.circle",
        }
    end

    return host.ui.render(host.ui.list{ title = "App Updates", style = "rows", items = items })
end

-- MARK: - Commands

-- Cache only. No shell, no network — safe however often the runner re-invokes it.
function appupdates_check()
    return render(load_cache())
end

-- The slow one, behind its own palette entry so the cost is always deliberate.
function appupdates_refresh()
    return render(refresh_all())
end

function appupdates_upgrade()
    local brew = brew_path()
    if not brew then return "Homebrew is not installed" end
    local before = #load_cache().brew
    host.shell.run(brew .. " upgrade 2>&1")
    -- Re-derive from brew rather than trusting the upgrade's exit text.
    local c = load_cache()
    c.brew = check_brew()
    save_cache(c)
    local done = before - #c.brew
    host.notify("Homebrew", (done > 0)
        and (done .. " package" .. (done == 1 and "" or "s") .. " upgraded")
        or "Nothing was upgraded")
    return render(c)
end

-- MARK: - Background poll

local function arm_timer()
    host.timer.schedule{ id = TIMER_ID, every = interval_hours() * 3600, handler = "on_poll" }
end

function on_launch()
    -- A repeating timer starts counting from now (TimerScheduler.swift:58-66), so
    -- re-arming on every launch would starve the poll on a machine that restarts
    -- often. A one-shot kick covers that, and the first check on a fresh install.
    arm_timer()
    local c = load_cache()
    if not c.at or (host.time() - c.at) >= interval_hours() * 3600 then
        host.timer.schedule{ id = KICK_ID, after = 30, handler = "on_poll" }
    end
end

function on_poll()
    local c = refresh_all()
    local n = total(c)
    local prev = tonumber(host.prefs.get(PREFS_COUNT) or "") or 0
    host.prefs.set(PREFS_COUNT, n)
    -- Edge-triggered: only a RISING count notifies. Steady state (the same 3
    -- updates still pending six hours later) and a falling count stay silent.
    if n > prev and notifications_on() then
        host.notify("Updates available", summary(c))
    end
end

-- MARK: - Settings (Tier B)

function settings_render(section_id, state)
    local s = host.ui.settings
    local c = load_cache()
    return s.render(s.ui{
        title = "App Updates",
        subtitle = "Homebrew and macOS update checks",
        sections = {
            s.section{
                id = "schedule", title = "Background check",
                footer = "The macOS check contacts Apple and can take up to a minute, so it only runs on this schedule and when you ask for it.",
                rows = {
                    s.row{ kind = "number", key = PREFS_INTERVAL, title = "Check every (hours)",
                           value = tostring(interval_hours()), min = 1, max = 168, step = 1 },
                    s.row{ kind = "toggle", key = PREFS_NOTIFY, title = "Notify on new updates",
                           subtitle = "Only when the pending count goes up — no repeat nagging.",
                           value = notifications_on() and "true" or "false" },
                },
            },
            s.section{
                id = "status", title = "Status",
                rows = {
                    s.row{ kind = "button", id = "recheck", actionID = "recheck",
                           title = "Check now",
                           subtitle = summary(c) .. " · " .. checked_at(c) },
                },
            },
        },
    })
end

function settings_action(section_id, action, value, form_json)
    local key = action:match("^set:(.+)$")
    if key then
        host.prefs.set(key, value or "")
        -- A new interval only takes effect once the durable timer is re-armed.
        if key == PREFS_INTERVAL then arm_timer() end
    elseif action == "recheck" then
        refresh_all()
    end
    return settings_render(section_id, "{}")
end
