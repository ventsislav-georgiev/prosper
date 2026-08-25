-- Unit tests for clipclear/init.lua. Run via scripts/test-extensions.sh.
--
-- What matters here:
--   * the age boundary — one second under the delay must NOT clear, exactly on it must
--   * every trigger respects the master switch, and lock/sleep respect their own
--   * screen.locked fires on unlock too: {locked=false} must not wipe
--   * a wipe drops the stamp, so the next tick does not write again (no repeat wipes)
--   * "nothing pending" paths write NOTHING (env.actions stays empty)

local h = require("harness")

local INIT = h.dir() .. "init.lua"
local NOW = 100000

-- Fresh host per case: these handlers are all prefs state machines, and a leaked
-- stamp from the previous case would quietly satisfy the next one.
local function fresh(prefs, clip)
    local host, env = h.makeHost{ now = NOW, clipboard = clip or "" }
    for k, v in pairs(prefs or {}) do env.prefs[k] = tostring(v) end
    local G = h.load(INIT, host)
    return G, host, env
end

local function writes(env)
    local n = 0
    for _, a in ipairs(env.actions) do if a == "clip.write" then n = n + 1 end end
    return n
end

-- MARK: - Delay sweep (the boundary)

do  -- 5 min delay, copied 4:59 ago -> too young
    local G, _, env = fresh({ delay_minutes = 5, last_change = NOW - 299 }, "hunter2")
    G.on_tick()
    h.eq(writes(env), 0, "299 s < 5 min: no clear")
    h.eq(env.clipboard, "hunter2", "clipboard untouched")
end

do  -- exactly on the boundary -> clears
    local G, _, env = fresh({ delay_minutes = 5, last_change = NOW - 300 }, "hunter2")
    G.on_tick()
    h.eq(writes(env), 1, "300 s >= 5 min: cleared")
    h.eq(env.clipboard, "", "pasteboard emptied")
    h.eq(env.prefs.last_change, "", "stamp dropped by the wipe")
end

do  -- default delay is 5 minutes when nothing is configured
    local G, _, env = fresh({ last_change = NOW - 301 }, "x")
    G.on_tick()
    h.eq(writes(env), 1, "default 5 min delay applies")
end

do  -- a second tick after a wipe must not write again
    local G, _, env = fresh({ delay_minutes = 1, last_change = NOW - 300 }, "x")
    G.on_tick()
    G.on_tick()
    h.eq(writes(env), 1, "wipe is not repeated once the stamp is gone")
end

do  -- no stamp = nothing whose age we know -> the sweep leaves it alone
    local G, _, env = fresh({ delay_minutes = 1 }, "left over")
    G.on_tick()
    h.eq(writes(env), 0, "unstamped clip is not swept")
end

do  -- master switch off
    local G, _, env = fresh({ enabled = "false", delay_minutes = 1, last_change = NOW - 600 }, "x")
    G.on_tick()
    h.eq(writes(env), 0, "disabled: no sweep")
end

-- MARK: - clipboard.changed stamping

do
    local G, _, env = fresh({}, "")
    G.on_copy(env.host.json.encode{ kind = "text", text = "secret" })
    h.eq(env.prefs.last_change, tostring(NOW), "copy stamps host.time()")
end

do  -- image/file clips have no text; the stamp is what makes them clearable
    local G, _, env = fresh({}, "")
    G.on_copy(env.host.json.encode{ kind = "image" })
    h.eq(env.prefs.last_change, tostring(NOW), "non-text copy is stamped too")
    G.on_sleep()
    h.eq(writes(env), 1, "stamped image clip clears on sleep despite empty read()")
end

do
    local G, _, env = fresh({ enabled = "false" }, "")
    G.on_copy("{}")
    h.eq(env.prefs.last_change, nil, "disabled: no stamp written")
end

-- MARK: - system.sleep

do
    local G, _, env = fresh({ last_change = NOW }, "secret")
    G.on_sleep()
    h.eq(writes(env), 1, "clear-on-sleep is on by default")
    h.eq(env.clipboard, "", "cleared on sleep")
end

do
    local G, _, env = fresh({ clear_on_sleep = "false", last_change = NOW }, "secret")
    G.on_sleep()
    h.eq(writes(env), 0, "clear-on-sleep off: nothing cleared")
end

do  -- empty pasteboard, no stamp: sleeping must not cost a write
    local G, _, env = fresh({}, "")
    G.on_sleep()
    h.eq(writes(env), 0, "nothing pending: no write")
end

do  -- text that predates us (no stamp) still clears on sleep
    local G, _, env = fresh({}, "left over")
    G.on_sleep()
    h.eq(writes(env), 1, "unstamped text still clears on sleep")
end

-- MARK: - screen.locked

do
    local G, _, env = fresh({ clear_on_lock = "true", last_change = NOW }, "secret")
    G.on_lock(env.host.json.encode{ locked = true })
    h.eq(writes(env), 1, "cleared on lock")
end

do  -- the same event fires on unlock
    local G, _, env = fresh({ clear_on_lock = "true", last_change = NOW }, "secret")
    G.on_lock(env.host.json.encode{ locked = false })
    h.eq(writes(env), 0, "unlock does not clear")
    h.eq(env.clipboard, "secret", "clipboard survives the unlock")
end

do  -- off by default
    local G, _, env = fresh({ last_change = NOW }, "secret")
    G.on_lock(env.host.json.encode{ locked = true })
    h.eq(writes(env), 0, "clear-on-lock is off unless asked for")
end

do  -- malformed payload
    local G, _, env = fresh({ clear_on_lock = "true", last_change = NOW }, "secret")
    G.on_lock(nil)
    G.on_lock("not json")
    h.eq(writes(env), 0, "no payload, no clear")
end

-- MARK: - system.launch / timer arming

do
    local G, _, env = fresh({}, "")
    G.on_launch()
    local t = env.timers["clipclear.tick"]
    h.eq(t ~= nil, true, "sweep timer armed")
    h.eq(t.every, 60, "60 s sweep")
    h.eq(t.handler, "on_tick", "named handler, no live closure")
    h.eq(env.prefs.last_change, nil, "empty pasteboard: nothing to stamp")
end

do  -- a clip that predates launch gets its clock started, else it never ages out
    local G, _, env = fresh({}, "from before")
    G.on_launch()
    h.eq(env.prefs.last_change, tostring(NOW), "pre-existing clip stamped at launch")
end

do
    local G, _, env = fresh({ enabled = "false" }, "x")
    G.on_launch()
    h.eq(env.timers["clipclear.tick"], nil, "disabled: no timer left running")
end

-- MARK: - Manual command

do
    local G, _, env = fresh({ enabled = "false" }, "secret")
    h.eq(G.clipclear_now(), "Clipboard cleared", "manual clear ignores the master switch")
    h.eq(env.clipboard, "", "cleared")
end

do
    local G, _, env = fresh({}, "")
    h.eq(G.clipclear_now(), "Clipboard is already empty", "no-op message")
    h.eq(writes(env), 0, "no write when there is nothing to clear")
end

-- MARK: - Settings

do
    local G, _, env = fresh({}, "")
    local ui = G.settings_render("clipclear", "{}")
    h.eq(ui, env.settingsRendered, "render goes through host.ui.settings.render")
    local rows = ui.sections[1].rows
    h.eq(rows[1].value, "true", "enabled defaults on")
    h.eq(rows[2].value, "5", "delay defaults to 5 minutes")
    h.eq(rows[3].value, "true", "clear-on-sleep defaults on")
    h.eq(rows[4].value, "false", "clear-on-lock defaults off")
end

do  -- toggles arrive as "set:<key>"; the master switch owns the timer
    local G, _, env = fresh({}, "")
    G.on_launch()
    G.settings_action("clipclear", "set:" .. "enabled", "false", "{}")
    h.eq(env.prefs.enabled, "false", "pref written")
    h.eq(env.timers["clipclear.tick"], nil, "timer cancelled when switched off")
    G.settings_action("clipclear", "set:enabled", "true", "{}")
    h.eq(env.timers["clipclear.tick"] ~= nil, true, "timer re-armed when switched on")
end

do  -- switching auto-clear on with something already copied starts its clock
    local G, _, env = fresh({ enabled = "false" }, "already here")
    G.settings_action("clipclear", "set:enabled", "true", "{}")
    h.eq(env.prefs.last_change, tostring(NOW), "existing clip stamped on enable")
end

do
    local G, _, env = fresh({ delay_minutes = 5 }, "secret")
    G.settings_action("clipclear", "set:delay_minutes", "30", "{}")
    h.eq(env.prefs.delay_minutes, "30", "delay written")
    h.eq(writes(env), 0, "changing the delay does not clear anything")
    G.settings_action("clipclear", "now", nil, "{}")
    h.eq(env.clipboard, "", "the Clear Clipboard Now button clears")
end

do  -- out-of-range delays are clamped, not trusted
    local G, _, env = fresh({ delay_minutes = 0, last_change = NOW - 59 }, "x")
    G.on_tick()
    h.eq(writes(env), 0, "delay clamps up to 1 minute, 59 s is too young")
    env.prefs.last_change = tostring(NOW - 60)
    G.on_tick()
    h.eq(writes(env), 1, "…and clears at 60 s")
end

print("clipclear: ok")
