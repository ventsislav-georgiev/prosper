-- clipclear — clear the clipboard after it has been sitting around, when the Mac
-- sleeps, or when the screen locks. See plan 019 §G.
--
-- Handler contract: the host invokes the global named after the command id with
-- non-alphanumerics replaced by '_' ("clipclear.now" -> clipclear_now). Event
-- handlers are named in extension.toml and receive the payload as a JSON STRING.
--
-- Two pieces of state, both in host.prefs (no resident VM):
--   last_change — host.time() of the clip currently sitting on the pasteboard,
--                 stamped by clipboard.changed and cleared by a wipe. Absent
--                 means "nothing pending we know the age of".
--   the four settings below.
--
-- The delay is a durable one-shot (#769) armed only while something is pending:
-- on_copy (re)arms it for the clip's deadline, a wipe cancels it, and nothing
-- pending means no timer at all. The old 60 s sweep spun a Lua worker every
-- minute all day, also with an empty clipboard. A one-shot costs one timer write
-- per copy, fires once per clip, on the deadline; the host persists it, and an
-- overdue one fires at once after a relaunch (TimerScheduler.restore).

local P_ENABLED = "enabled"
local P_DELAY   = "delay_minutes"
local P_SLEEP   = "clear_on_sleep"
local P_LOCK    = "clear_on_lock"
local P_LAST    = "last_change"
local TIMER_ID  = "clipclear.tick"

local DEFAULTS = { [P_ENABLED] = true, [P_SLEEP] = true, [P_LOCK] = false }

local function flag(key)
    local v = host.prefs.get(key)
    if v == nil or v == "" then return DEFAULTS[key] end
    return v == "true"
end

local function delay_minutes()
    local n = tonumber(host.prefs.get(P_DELAY) or "") or 5
    if n < 1 then n = 1 end
    if n > 1440 then n = 1440 end
    return n
end

local function last_change() return tonumber(host.prefs.get(P_LAST) or "") end

-- One-shot at the pending clip's deadline; cancelled when nothing is pending or
-- auto-clear is off. Idempotent by id, so re-arming just moves the deadline.
local function arm_timer()
    local ts = last_change()
    if not (ts and flag(P_ENABLED)) then host.timer.cancel(TIMER_ID); return end
    local left = delay_minutes() * 60 - (host.time() - ts)
    -- A wall-clock step back must not push the deadline past the full delay.
    left = math.max(1, math.min(left, delay_minutes() * 60))
    host.timer.schedule{ id = TIMER_ID, after = left, handler = "on_tick" }
end

local function stamp() host.prefs.set(P_LAST, host.time()); arm_timer() end

-- Anything worth clearing? The stamp covers clips we watched arrive — including
-- images and files, which have no string form — and the read covers text that
-- was already on the pasteboard before we started watching.
local function pending()
    if last_change() then return true end
    return #(host.clipboard.read() or "") > 0
end

-- host.clipboard.write("") clears the pasteboard outright (the host special-cases
-- the empty string to clearContents rather than writing an empty item), and a
-- host-originated write does not re-fire clipboard.changed, so this cannot loop.
local function wipe()
    host.clipboard.write("")
    host.prefs.set(P_LAST, "")   -- nothing pending any more
    host.timer.cancel(TIMER_ID)
end

-- MARK: - Triggers

local function arm()
    -- A clip that predates us (relaunch, or auto-clear switched on with something
    -- already copied) has no stamp, so the delay would have nothing to measure
    -- from and would never fire. Start its clock now (stamp arms the timer).
    if flag(P_ENABLED) and not last_change() and #(host.clipboard.read() or "") > 0 then
        stamp()
    else
        arm_timer()   -- also replaces a pre-#769 repeating sweep under the same id
    end
end

function on_launch() arm() end

-- Only the moment matters; the {kind, text} payload is deliberately not read —
-- keeping copied text out of this VM is the whole point of the 8 KB cap upstream.
function on_copy()
    if flag(P_ENABLED) then stamp() end
end

function on_tick()
    local ts = last_change()
    -- Too young (the delay was raised, or the clock moved): arm_timer re-arms for
    -- the rest. Off or nothing pending: arm_timer cancels.
    if not (flag(P_ENABLED) and ts) or host.time() - ts < delay_minutes() * 60 then
        arm_timer(); return
    end
    wipe()
end

function on_sleep()
    if flag(P_ENABLED) and flag(P_SLEEP) and pending() then wipe() end
end

function on_lock(payload)
    if not (flag(P_ENABLED) and flag(P_LOCK)) then return end
    -- {locked} carries both directions; unlocking is not a reason to wipe.
    local p = payload and host.json.decode(payload) or nil
    if type(p) ~= "table" or p.locked ~= true then return end
    if pending() then wipe() end
end

-- MARK: - Command

-- Explicit, so it ignores the master switch — the user asked for it right now.
function clipclear_now()
    if not pending() then return "Clipboard is already empty" end
    wipe()
    return "Clipboard cleared"
end

-- MARK: - Settings (Tier B)

local function b2s(v) return v and "true" or "false" end

local function status()
    local ts = last_change()
    if not ts then
        return pending() and "Something is on the clipboard" or "Clipboard is empty"
    end
    local mins = math.floor((host.time() - ts) / 60)
    return "Copied " .. (mins < 1 and "just now" or (mins .. "m ago"))
        .. " · clears after " .. delay_minutes() .. "m"
end

function settings_render(section_id, state)
    local s = host.ui.settings
    return s.render(s.ui{
        title = "Clipboard Auto-Clear",
        subtitle = "Clear the clipboard on a delay, on sleep, or on lock",
        sections = {
            s.section{
                id = "auto", title = "Automatic clearing",
                footer = "Turning this off leaves the manual “Clear Clipboard "
                    .. "Now” command; to stop the pasteboard being watched at all, "
                    .. "disable the extension itself in Settings › Extensions.",
                rows = {
                    s.row{ kind = "toggle", key = P_ENABLED, title = "Clear automatically",
                           subtitle = "Master switch for the three triggers below",
                           value = b2s(flag(P_ENABLED)) },
                    s.row{ kind = "number", key = P_DELAY, title = "Clear after (minutes)",
                           subtitle = "Measured from the moment you copied",
                           value = tostring(delay_minutes()), min = 1, max = 1440, step = 1 },
                    s.row{ kind = "toggle", key = P_SLEEP, title = "Clear when the Mac sleeps",
                           value = b2s(flag(P_SLEEP)) },
                    s.row{ kind = "toggle", key = P_LOCK, title = "Clear when the screen locks",
                           subtitle = "Off by default — locking is frequent, and this "
                               .. "throws away whatever you just copied",
                           value = b2s(flag(P_LOCK)) },
                },
            },
            s.section{
                id = "now", title = "Right now",
                rows = {
                    s.row{ kind = "button", id = "now", actionID = "now",
                           title = "Clear Clipboard Now", subtitle = status() },
                },
            },
        },
    })
end

function settings_action(section_id, action, value, form_json)
    local key = action:match("^set:(.+)$")
    if key then
        host.prefs.set(key, value or "")
        -- The master switch and the delay both move the pending clip's deadline.
        if key == P_ENABLED then arm() elseif key == P_DELAY then arm_timer() end
    elseif action == "now" then
        clipclear_now()
    end
    return settings_render(section_id, "{}")
end
