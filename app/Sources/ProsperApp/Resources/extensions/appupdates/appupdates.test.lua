-- Unit tests for appupdates/init.lua. Shared harness (real JSON codec, recorded
-- host side effects) so scripts/test-extensions.sh runs it. No brew, no
-- softwareupdate, no network: every source is a captured fixture string routed
-- through the stub host.shell.
--
-- What matters here:
--   * both softwareupdate fixtures — "No new software available." and 2 updates
--   * the brew guard: no brew binary on disk => no brew shell call, no error row
--   * the notification EDGE — a rising count notifies, steady/falling stays silent
--   * appupdates.check shells out to NOTHING (it is the per-keystroke-safe one)

local h = require("harness")

local BREW = "/opt/homebrew/bin/brew"

-- MARK: - Fixtures (verbatim shapes from the real tools)

local BREW_OUTDATED_2 = [[
{"formulae":[{"name":"lua","installed_versions":["5.4.6"],"current_version":"5.4.7","pinned":false}],
 "casks":[{"name":"firefox","installed_versions":"130.0","current_version":"131.0"}]}
]]

local BREW_OUTDATED_0 = [[{"formulae":[],"casks":[]}]]

local SU_NONE = [[
Software Update Tool

Finding available software
No new software available.
]]

local SU_TWO = [[
Software Update Tool

Finding available software
Software Update found the following new or updated software:
* Label: macOS Sequoia 15.1-24B83
	Title: macOS Sequoia, Version: 15.1, Size: 6440027KiB, Recommended: YES, Action: restart,
* Label: Safari18.1MontereyAuto-18.1
	Title: Safari, Version: 18.1, Size: 132587KiB, Recommended: YES,
]]

-- MARK: - Harness wiring

-- Route by command so one host serves both sources; every shell call is logged
-- so the tests can assert what did NOT run.
local shellLog = {}
local brewOut, suOut = BREW_OUTDATED_0, SU_NONE

local function router(cmd)
    shellLog[#shellLog + 1] = cmd
    if cmd:find("outdated", 1, true) then return brewOut end
    if cmd:find("softwareupdate", 1, true) then return suOut end
    return ""
end

local host, env = h.makeHost{
    shellRouter = router,
    fsExists = { [BREW] = true },
    now = 100000,
}
local G = h.load(h.dir() .. "init.lua", host)

local function reset()
    shellLog = {}
    env.notifications = {}
end

local function ran(pat)
    for _, c in ipairs(shellLog) do if c:find(pat, 1, true) then return true end end
    return false
end

-- MARK: - 1. Pure parsers, both fixtures

local brewRows = G.parse_brew(BREW_OUTDATED_2)
h.eq(#brewRows, 2, "brew fixture yields both a formula and a cask")
h.eq(brewRows[1].name, "lua", "formula name parsed")
h.eq(brewRows[1].from, "5.4.6", "formula installed version comes out of the array")
h.eq(brewRows[1].to, "5.4.7", "formula current version parsed")
h.eq(brewRows[2].name, "firefox", "cask name parsed")
h.eq(brewRows[2].from, "130.0", "cask installed version is a bare string, not an array")
h.eq(brewRows[2].cask, true, "cask flagged")

h.eq(#G.parse_brew(BREW_OUTDATED_0), 0, "empty brew fixture yields no rows")
h.eq(#G.parse_brew("not json at all"), 0, "garbage brew output degrades to no rows")

h.eq(#G.parse_softwareupdate(SU_NONE), 0, "'No new software available.' yields no rows")
local su = G.parse_softwareupdate(SU_TWO)
h.eq(#su, 2, "2-update softwareupdate fixture yields exactly 2 rows, not 4")
h.eq(su[1], "macOS Sequoia 15.1", "Title + Version scraped, Size/Recommended dropped")
h.eq(su[2], "Safari 18.1", "second update scraped")

-- MARK: - 2. The palette command touches no subprocess at all

reset()
brewOut, suOut = BREW_OUTDATED_2, SU_TWO
local node = G.appupdates_check()
h.eq(#shellLog, 0, "appupdates.check runs no shell command — cache only")
h.eq(#node.items, 1, "empty cache renders the single up-to-date row")
h.eq(node.items[1].title, "Everything is up to date", "…and says so")

-- MARK: - 3. Check-for-updates-now pays the cost and fills the cache

reset()
node = G.appupdates_refresh()
h.eq(ran("outdated"), true, "refresh runs brew")
h.eq(ran("softwareupdate"), true, "refresh runs the slow macOS check")
h.eq(#node.items, 3, "2 brew rows + 1 macOS row")
h.eq(node.items[1].title, "lua", "brew row titled by package")
h.eq(node.items[1].subtitle, "Formula · 5.4.6 → 5.4.7", "brew row shows the version bump")
h.eq(node.items[3].title:find("macOS Sequoia 15.1", 1, true) ~= nil, true,
     "macOS row lists the updates")
h.eq(node.items[3].url,
     "x-apple.systempreferences:com.apple.Software-Update-Settings.extension",
     "macOS row opens the Software Update pane natively on Enter")

reset()
node = G.appupdates_check()
h.eq(#shellLog, 0, "still no shell after the cache is warm")
h.eq(#node.items, 3, "…and the cached rows are what the palette shows")

-- MARK: - 4. Notification edge: only a RISING count notifies

reset()
env.prefs["last_count"] = nil          -- first ever poll: 0 -> 4
G.on_poll()
h.eq(#env.notifications, 1, "first poll with updates notifies")
h.eq(env.notifications[1].body, "4 updates pending", "…with the count")
h.eq(env.prefs["last_count"], "4", "count cached for the next edge comparison")

reset()
G.on_poll()                            -- same 4 updates six hours later
h.eq(#env.notifications, 0, "steady count does not re-nag")

reset()
brewOut = BREW_OUTDATED_0              -- 4 -> 2
G.on_poll()
h.eq(#env.notifications, 0, "falling count does not notify")
h.eq(env.prefs["last_count"], "2", "count still tracked downwards")

reset()
brewOut = BREW_OUTDATED_2              -- 2 -> 4
G.on_poll()
h.eq(#env.notifications, 1, "count rising again notifies")

reset()
host.prefs.set("notifications", "false")
brewOut, suOut = BREW_OUTDATED_0, SU_NONE
G.on_poll()                            -- 4 -> 0
brewOut, suOut = BREW_OUTDATED_2, SU_TWO
G.on_poll()                            -- 0 -> 4, but notifications are off
h.eq(#env.notifications, 0, "notifications toggle silences the rising edge")
host.prefs.set("notifications", "true")

-- MARK: - 5. Timer arming, the launch kick, and the interval setting

env.timers = {}
G.on_launch()
local t = env.timers["appupdates.poll"]
h.eq(t ~= nil, true, "system.launch arms the poll timer")
h.eq(t.every, 6 * 3600, "default interval is 6 hours")
h.eq(t.handler, "on_poll", "timer calls on_poll")
h.eq(env.timers["appupdates.kick"], nil, "cache is fresh, so no catch-up kick")

env.timers = {}
env.now = 100000 + 7 * 3600            -- cache is now older than the interval
G.on_launch()
h.eq(env.timers["appupdates.kick"].after, 30, "a stale cache schedules a catch-up check")
h.eq(env.timers["appupdates.kick"].handler, "on_poll", "the kick runs the same poll")
env.now = 100000

env.timers = {}
G.settings_action("appupdates", "set:interval_hours", "12", "{}")
h.eq(env.timers["appupdates.poll"].every, 12 * 3600, "changing the interval re-arms the timer")
G.settings_action("appupdates", "set:interval_hours", "0", "{}")
h.eq(env.timers["appupdates.poll"].every, 3600, "sub-hour intervals clamp to 1 hour")
G.settings_action("appupdates", "set:interval_hours", "6", "{}")

-- MARK: - 6. No Homebrew on this Mac: macOS updates only, no error row

env.fsExists = {}
reset()
node = G.appupdates_refresh()
h.eq(ran("outdated"), false, "brew-less Mac never shells out to brew")
h.eq(#node.items, 1, "macOS row only, and no error row")
h.eq(node.items[1].id, "macos", "…and it is the macOS row")
h.eq(G.appupdates_upgrade(), "Homebrew is not installed", "upgrade says so plainly")
env.fsExists = { [BREW] = true }

-- MARK: - 7. brew upgrade reports what actually changed

reset()
brewOut = BREW_OUTDATED_2
G.appupdates_refresh()                 -- cache: 2 outdated
reset()
brewOut = BREW_OUTDATED_0              -- they upgrade cleanly
G.appupdates_upgrade()
h.eq(ran("brew upgrade"), true, "runs brew upgrade")
h.eq(env.notifications[1].body, "2 packages upgraded", "count comes from re-running brew outdated")

reset()
brewOut = BREW_OUTDATED_2
G.appupdates_refresh()
reset()
G.appupdates_upgrade()                 -- still outdated afterwards
h.eq(env.notifications[1].body, "Nothing was upgraded", "a no-op upgrade is reported honestly")

-- MARK: - 8. Settings render

node = G.settings_render("appupdates", "{}")
h.eq(node.kind, "settings.ui", "renders a settings ui")
h.eq(#node.sections, 2, "schedule + status sections")
h.eq(node.sections[1].rows[1].key, "interval_hours", "interval row")
h.eq(node.sections[1].rows[2].key, "notifications", "notifications row")
h.eq(node.sections[2].rows[1].actionID, "recheck", "status section has the Check now button")

reset()
G.settings_action("appupdates", "recheck", "", "{}")
h.eq(ran("softwareupdate"), true, "the Check now button runs the slow path")

print("✅ appupdates tests passed")
