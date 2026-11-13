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
local brewOut, suOut, upgradeOut, catOut = BREW_OUTDATED_0, SU_NONE, "0", ""
local onUpgrade   -- runs inside the `brew upgrade` call, when set

local function router(cmd)
    shellLog[#shellLog + 1] = cmd
    if cmd:find("^/bin/cat ") then return catOut end   -- the watch reading a status file
    if cmd:find("outdated", 1, true) then return brewOut end
    if cmd:find("softwareupdate", 1, true) then return suOut end
    if cmd:find("brew upgrade", 1, true) then
        if onUpgrade then onUpgrade() end
        return upgradeOut
    end
    return ""
end

local host, env = h.makeHost{
    shellRouter = router,
    fsExists = { [BREW] = true },
    now = 100000,
}
host.env = { get = function() return "/fake-tmp/" end }   -- the harness has no host.env
local G = h.load(h.dir() .. "init.lua", host)

local function reset()
    shellLog = {}
    env.notifications = {}
end

local function ran(pat)
    for _, c in ipairs(shellLog) do if c:find(pat, 1, true) then return true end end
    return false
end

local function count(pat)
    local n = 0
    for _, c in ipairs(shellLog) do if c:find(pat, 1, true) then n = n + 1 end end
    return n
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
onUpgrade = function() brewOut = BREW_OUTDATED_0 end   -- they upgrade cleanly
G.appupdates_upgrade()
onUpgrade = nil
h.eq(ran("brew upgrade"), true, "runs brew upgrade")
h.eq(env.notifications[1].body, "2 packages upgraded", "count comes from re-running brew outdated")

reset()
brewOut = BREW_OUTDATED_2
G.appupdates_refresh()
reset()
G.appupdates_upgrade()                 -- still outdated afterwards
h.eq(env.notifications[1].body, "Nothing was upgraded", "a no-op upgrade is reported honestly")

-- A non-zero exit that is not a lock refusal (some packages failed): refresh and say both.
reset()
brewOut = BREW_OUTDATED_2
G.appupdates_refresh()
reset()
onUpgrade = function() brewOut = BREW_OUTDATED_0 end
upgradeOut = "Error: lua: post-install step failed\n1"
G.appupdates_upgrade()
onUpgrade = nil
h.eq(env.notifications[1].body, "brew upgrade failed for some packages (exit 1); 2 packages upgraded",
     "a partial failure says the status and the count")

-- Homebrew's lock refusal. Someone else's lock: re-check and say so.
reset()
brewOut = BREW_OUTDATED_2
G.appupdates_refresh()
reset()
upgradeOut = "Error: A `brew upgrade` process has already locked /opt/homebrew/var/homebrew/locks/lua.formula.lock.\n"
          .. "Please wait for it to finish or terminate it to continue.\n1"
G.appupdates_upgrade()
h.eq(count("outdated"), 2, "a foreign lock re-checks the list (one read before, one after)")
h.eq(env.notifications[1].body, "brew upgrade stopped: another Homebrew process holds its lock (exit 1)", "names the lock")
-- Our own backgrounded upgrade holds it, its record written after this call began (a
-- record there at the start refuses before brew runs, section 7b): no re-check, the watch stays.
reset()
local REC = '{"file":"/fake-tmp/x/status","at":100000,"before":2}'
onUpgrade = function() host.prefs.set("upgrade_pending", REC) end
G.appupdates_upgrade()
onUpgrade = nil
h.eq(ran("brew upgrade"), true, "this brew ran: the record came while it ran")
h.eq(count("outdated"), 1, "a lock held by our own upgrade does not re-check (only the read before)")
h.eq(env.notifications[1].body, "brew upgrade refused: an upgrade Prosper started is still running", "names our upgrade")
h.eq(host.prefs.get("upgrade_pending"), REC, "the watch pref survives")
host.prefs.set("upgrade_pending", "")
upgradeOut = "0"

-- MARK: - 7b. A second Upgrade while ours runs in the background (QA #730 r2 F1)

local PENDING, WATCH = "upgrade_pending", "appupdates.upgrade_poll"
local REFUSED = "brew upgrade refused: an upgrade Prosper started is still running"

reset()
brewOut = BREW_OUTDATED_2
G.appupdates_refresh()                 -- cache: 2 outdated
reset()
env.timers, env.calls.timerSchedule = {}, 0
upgradeOut = ""                        -- the host timeout wins: brew goes on in the background
G.appupdates_upgrade()
h.eq(env.notifications[1].body, "brew upgrade is still running in the background", "first Upgrade backgrounds")
local rec = env.prefs[PENDING]
local recFile = host.json.decode(rec).file

-- t1: status file absent, record fresh: refused, nothing runs, nothing written.
reset()
env.now = 100000 + 20
h.resetCalls(env)
G.appupdates_upgrade()
h.eq(#shellLog, 0, "t1: no shell call at all")
h.eq(count("mkdir"), 0, "t1: no second mkdir")
h.eq(count("brew upgrade"), 0, "t1: no second brew upgrade")
h.eq(#env.notifications, 1, "t1: one notice")
h.eq(env.notifications[1].body, REFUSED, "t1: the refused sentence")
h.eq(env.prefs[PENDING], rec, "t1: the pending record is byte-identical")
h.eq(env.calls.prefsSet, 0, "t1: no prefs write")
h.eq(env.calls.timerSchedule, 0, "t1: no new timer")
h.eq(env.calls.timerCancel, 0, "t1: the watch is not cancelled")
h.eq(env.timers[WATCH].handler, "on_upgrade_poll", "t1: the first watch is still armed")

-- t2: the status file appears, Upgrade again before the 60 s poll: the first result is
-- reported and its file and folder removed, THEN the second upgrade starts.
reset()
env.now = 100000 + 40
env.fsExists[recFile] = true
catOut, brewOut, upgradeOut = "0", BREW_OUTDATED_0, "0"
G.appupdates_upgrade()
h.eq(shellLog[1], "/bin/cat '" .. recFile .. "'; [ ! -L '/fake-tmp/prosper-appupdates-100000000' ] && "
     .. "[ -O '/fake-tmp/prosper-appupdates-100000000' ] && { /bin/rm -f '" .. recFile .. "' '" .. recFile
     .. ".part'; /bin/rmdir '/fake-tmp/prosper-appupdates-100000000'; }", "t2: the first status is read and removed first")
h.eq(env.notifications[1].body, "2 packages upgraded", "t2: the first upgrade's result is reported")
h.eq(count("mkdir"), 1, "t2: one new mkdir")
h.eq(count("brew upgrade"), 1, "t2: one brew upgrade")
h.eq(count("/bin/mkdir -m 700 '/fake-tmp/prosper-appupdates-100040000'"), 1, "t2: in a new folder")
h.eq(env.notifications[2].body, "Nothing was upgraded", "t2: then the second upgrade's own result")
h.eq(env.prefs[PENDING], "", "t2: the first record is cleared")
h.eq(env.timers[WATCH], nil, "t2: the first watch is cancelled")
env.fsExists[recFile] = nil
catOut = ""

-- t3: a record UPGRADE_CAP old with no status file is dropped; the new upgrade starts.
reset()
host.prefs.set(PENDING, '{"file":"/fake-tmp/prosper-appupdates-1/status","at":' .. (env.now - 2 * 3600) .. ',"before":2}')
G.appupdates_upgrade()
h.eq(count("/bin/cat '/fake-tmp/prosper-appupdates-1/status'"), 0, "t3: no status file to read")
h.eq(count("brew upgrade"), 1, "t3: the new upgrade starts")
h.eq(env.notifications[1].body, "Nothing was upgraded", "t3: no refusal")
h.eq(env.prefs[PENDING], "", "t3: the stale record is dropped")

-- t4: a malformed record (no file name, or an `at` that is no number) never refuses for good.
for _, bad in ipairs({ '{"at":100040,"before":2}', '{"file":7,"at":100040}', '[1,2]',
                       '{"file":"/fake-tmp/prosper-appupdates-2/status","at":"soon"}',
                       '{"file":"/fake-tmp/prosper-appupdates-2/status","at":{}}',
                       '{"file":"/fake-tmp/prosper-appupdates-2/status","at":null}',
                       '{"file":"/fake-tmp/prosper-appupdates-2/status","at":true}' }) do
    reset()
    host.prefs.set(PENDING, bad)
    G.appupdates_upgrade()
    h.eq(count("brew upgrade"), 1, "t4: the upgrade starts under " .. bad)
    h.eq(env.notifications[1].body, "Nothing was upgraded", "t4: no refusal under " .. bad)
    h.eq(env.prefs[PENDING], "", "t4: the record is cleared under " .. bad)
end

-- MARK: - 7c. Upgrade notices and the background watch (#1011)

local AT = 200000
local DIR = "/fake-tmp/prosper-appupdates-200000000"        -- the folder an upgrade at AT makes
local OLD = "/fake-tmp/prosper-appupdates-192800000"        -- one made UPGRADE_CAP before AT
local BREW_OUTDATED_1 = [[{"formulae":[{"name":"lua","installed_versions":["5.4.6"],"current_version":"5.4.7"}],"casks":[]}]]
-- What `brew upgrade` prints when its auto-update step meets a running `brew update`; it upgrades on.
local AUTO_UPDATE_LOCK = "Error: Another `brew update` process is already running.\n"
                      .. "Please wait for it to finish or terminate it to continue."
local OLD_CLEANUP = "[ ! -L '" .. OLD .. "' ] && [ -O '" .. OLD .. "' ] && { /bin/rm -f '" .. OLD
                 .. "/status' '" .. OLD .. "/status.part'; /bin/rmdir '" .. OLD .. "'; }"

local function settle()
    onUpgrade, upgradeOut, catOut = nil, "0", ""
    host.prefs.set(PENDING, "")
    env.timers, env.fsExists = {}, { [BREW] = true }
    env.now = AT
end

-- The cache holds 2 outdated packages; brew lists `pre` before the upgrade and `post` after.
-- `during` runs inside the brew upgrade call. Returns the first notice.
local function upgrade(pre, post, out, during)
    settle()
    reset()
    brewOut = BREW_OUTDATED_2
    G.appupdates_refresh()
    reset()
    brewOut, upgradeOut = pre, out or "0"
    onUpgrade = function() brewOut = post; if during then during() end end
    G.appupdates_upgrade()
    onUpgrade, upgradeOut = nil, "0"
    return env.notifications[1] and env.notifications[1].body
end

local function upgradeCmd()
    for _, c in ipairs(shellLog) do if c:find("brew upgrade", 1, true) then return c end end
    return ""
end

-- A watch record for a status file that exists and reads `cat`, polled once.
local function pollEnded(rec, cat)
    settle()
    reset()
    host.prefs.set(PENDING, rec)
    env.fsExists[DIR .. "/status"] = true
    catOut, brewOut = cat, BREW_OUTDATED_0
    G.on_upgrade_poll()
    return env.notifications[1] and env.notifications[1].body
end

-- C1: the count is taken against brew's list read just before the upgrade, not the cache.
local function c1()
    -- firefox was upgraded in Terminal after the last check: the cache says 2, brew says 1.
    h.eq(upgrade(BREW_OUTDATED_1, BREW_OUTDATED_0), "1 package upgraded", "C1: counted against brew's list read just before")
    h.eq(count("outdated"), 2, "C1: brew outdated runs before and after the upgrade")
    h.eq(shellLog[1], "/opt/homebrew/bin/brew outdated --json=v2 2>/dev/null", "C1: the list is read first")
    -- That read gets no answer: no count rather than the stale cached one.
    h.eq(upgrade("", BREW_OUTDATED_0), "brew upgrade finished", "C1: no fresh list before, no count")
    h.eq(upgrade("", BREW_OUTDATED_0, "Error: lua: post-install step failed\n1"), "brew upgrade failed (exit 1)",
         "C1: no fresh list before, a failure says the status only")
    -- A backgrounded upgrade's record keeps the fresh count.
    upgrade(BREW_OUTDATED_1, BREW_OUTDATED_1, "")
    h.eq(env.notifications[1].body, "brew upgrade is still running in the background", "C1: backgrounded")
    h.eq(host.json.decode(env.prefs[PENDING]).before, 1, "C1: the watch record holds the fresh count, not the cached 2")
    -- `before` read back from the record: a whole number 0-100000, else no count.
    local function rec(b) return '{"file":"' .. DIR .. '/status","at":' .. AT .. b .. '}' end
    h.eq(pollEnded(rec(',"before":2'), "0"), "2 packages upgraded", "C1: a good record counts")
    h.eq(pollEnded(rec(',"before":2.0'), "0"), "2 packages upgraded", "C1: 2.0 is the count 2")
    h.eq(pollEnded(rec(''), "0"), "brew upgrade finished", "C1: no before")
    h.eq(pollEnded(rec(',"before":"lots"'), "0"), "brew upgrade finished", "C1: before not a number")
    h.eq(pollEnded(rec(',"before":-3'), "0"), "brew upgrade finished", "C1: before negative")
    h.eq(pollEnded(rec(',"before":2.5'), "0"), "brew upgrade finished", "C1: before not whole")
    h.eq(pollEnded(rec(',"before":1e999'), "0"), "brew upgrade finished", "C1: before infinite")
    h.eq(pollEnded(rec(',"before":100001'), "0"), "brew upgrade finished", "C1: before past 100000")
    h.eq(pollEnded(rec(',"before":{}'), "1"), "brew upgrade failed (exit 1)", "C1: bad before, a failure says the status only")
    settle()
end

-- The exit status is brew's last line only when it is a whole number 0-255.
local function status()
    local fail = "Error: lua: post-install step failed\n"
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, fail .. "1"), "brew upgrade failed (exit 1)", "status: 1")
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, fail .. "255"), "brew upgrade failed (exit 255)", "status: 255")
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, fail .. "0x1"), "brew upgrade failed (exit ?)", "status: hex")
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, fail .. "1e2"), "brew upgrade failed (exit ?)", "status: exponent")
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, fail .. "1.0"), "brew upgrade failed (exit ?)", "status: fraction")
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, fail .. "-1"), "brew upgrade failed (exit ?)", "status: negative")
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, fail .. "256"), "brew upgrade failed (exit ?)", "status: past 255")
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, fail .. "99999999999999999999"), "brew upgrade failed (exit ?)",
         "status: past the integer range")
    settle()
end

-- C3: brew's output goes to a file in the private folder, never to Prosper's pipe, so a
-- quit in the middle of an upgrade gives brew no closed pipe to write into.
local function c3()
    upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2)
    local cmd = upgradeCmd()
    h.eq(cmd:find("/opt/homebrew/bin/brew upgrade > '" .. DIR .. "/status.part' 2>&1; s=$?; ", 1, true) ~= nil, true,
         "C3: brew's stdout and stderr go to the status file")
    h.eq(cmd:find("brew upgrade 2>&1", 1, true), nil, "C3: brew's output never goes to the pipe")
    settle()
end

-- C4: the status file holds brew's output, then the status, so a backgrounded run stopped
-- by a foreign lock is reported as the lock.
local function c4()
    upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2)
    h.eq(upgradeCmd():find("{ echo $s >> '" .. DIR .. "/status.part' && /bin/mv -f '" .. DIR .. "/status.part' '"
         .. DIR .. "/status' && /bin/cat '" .. DIR .. "/status'; }", 1, true) ~= nil, true,
         "C4: the status is appended after brew's output, and that whole file is the result")
    local rec = '{"file":"' .. DIR .. '/status","at":' .. AT .. ',"before":2}'
    h.eq(pollEnded(rec, "Error: A `brew upgrade` process has already locked /opt/homebrew/var/homebrew/locks/lua.formula.lock.\n"
                     .. "Please wait for it to finish or terminate it to continue.\n1"),
         "brew upgrade stopped: another Homebrew process holds its lock (exit 1); 2 packages upgraded",
         "C4: the watch names the lock")
    h.eq(count("outdated"), 1, "C4: and re-checks the list")
    settle()
end

-- C5: the lock stopped brew only when its line is brew's last; the auto-update step prints
-- the same line for a running `brew update` and brew upgrades on.
local function c5()
    local upgraded = "\n==> Upgrading 2 outdated packages:\nlua 5.4.6 -> 5.4.7\nfirefox 130.0 -> 131.0\n"
    local partial = "brew upgrade failed for some packages (exit 1); 2 packages upgraded"
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_0, AUTO_UPDATE_LOCK .. upgraded .. "Error: lua: post-install step failed\n1"),
         partial, "C5: an auto-update lock line then a package failure is a partial failure, not a lock")
    -- Our own watch record appears while this brew runs: still not a lock, so no refusal.
    local REC = '{"file":"' .. OLD .. '/status","at":' .. AT .. ',"before":2}'
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_0, AUTO_UPDATE_LOCK .. upgraded .. "Error: lua: post-install step failed\n1",
                 function() host.prefs.set(PENDING, REC) end),
         partial, "C5: with our watch pending it is not 'refused'")
    h.eq(count("outdated"), 2, "C5: the list is re-checked")
    h.eq(env.prefs[PENDING], REC, "C5: the watch record is left to its watch")
    -- Lock text and exit 0 (no test had it): a success.
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_0, AUTO_UPDATE_LOCK .. upgraded .. "0"), "2 packages upgraded",
         "C5: lock text with exit 0 is a success")
    -- The real refusal, with HOMEBREW_LOCK_CONTEXT between its lines, is still the lock.
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2,
                 "Error: A `brew upgrade` process has already locked /opt/homebrew/var/homebrew/locks/lua.formula.lock.\n"
                 .. "context from HOMEBREW_LOCK_CONTEXT\nPlease wait for it to finish or terminate it to continue.\n1"),
         "brew upgrade stopped: another Homebrew process holds its lock (exit 1)", "C5: the refusal as brew's last line")
    settle()
end

-- C6: a failed upgrade whose re-check gets no answer says the list is stale.
local function c6()
    h.eq(upgrade(BREW_OUTDATED_2, "", "Error: lua: post-install step failed\n1"),
         "brew upgrade failed (exit 1); the list could not be refreshed", "C6: failed + no re-check")
    h.eq(upgrade(BREW_OUTDATED_2, "", "Error: A `brew upgrade` process has already locked /opt/homebrew/var/homebrew/locks/lua.formula.lock.\n"
                                    .. "Please wait for it to finish or terminate it to continue.\n1"),
         "brew upgrade stopped: another Homebrew process holds its lock (exit 1); the list could not be refreshed",
         "C6: foreign lock + no re-check")
    h.eq(upgrade(BREW_OUTDATED_2, "", "0"), "brew upgrade finished; the list could not be refreshed", "C6: success + no re-check")
    settle()
end

-- C7: a refused mkdir means brew never ran: said so, no re-check, nothing removed.
local function c7()
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, "mkdir: " .. DIR .. ": File exists\nbrew upgrade did not start"),
         "brew upgrade did not start: mkdir: " .. DIR .. ": File exists", "C7: names mkdir's refusal")
    h.eq(#env.notifications, 1, "C7: one notice")
    h.eq(count("outdated"), 1, "C7: only the list read before; no re-check")
    h.eq(ran("/bin/rm"), false, "C7: a folder Prosper did not make is not removed")
    h.eq(env.prefs[PENDING], "", "C7: no watch record")
    h.eq(upgradeCmd():find("/bin/mkdir -m 700 '" .. DIR .. "' 2>&1 || { echo 'brew upgrade did not start'; exit; }; ", 1, true)
         ~= nil, true, "C7: the shell says brew did not start when mkdir refuses")
    settle()
end

-- C8: the folder goes when the watch gives up (the cap, a relaunch), not only on a normal end.
local function c8()
    settle()
    reset()
    host.prefs.set(PENDING, '{"file":"' .. OLD .. '/status","at":' .. (AT - 2 * 3600) .. ',"before":2}')
    env.timers[WATCH] = { id = WATCH }
    G.on_upgrade_poll()
    h.eq(shellLog[1], OLD_CLEANUP, "C8: past the cap the status files and the folder are removed")
    h.eq(#shellLog, 1, "C8: and nothing else runs")
    h.eq(#env.notifications, 0, "C8: silently")
    h.eq(env.prefs[PENDING], "", "C8: the record is dropped")
    h.eq(env.timers[WATCH], nil, "C8: the watch is cancelled")
    -- A relaunch drops the watch and its folder.
    settle()
    reset()
    host.prefs.set(PENDING, '{"file":"' .. OLD .. '/status","at":' .. (AT - 60) .. ',"before":2}')
    G.on_launch()
    h.eq(shellLog[1], OLD_CLEANUP, "C8: a relaunch removes the dropped watch's folder")
    h.eq(#shellLog, 1, "C8: one shell call at launch")
    h.eq(env.prefs[PENDING], "", "C8: the record is dropped at launch")
    -- No record: launch runs no shell at all.
    reset()
    G.on_launch()
    h.eq(#shellLog, 0, "C8: no record, no shell at launch")
    -- A record naming a file Prosper never makes: nothing read, nothing removed, record dropped.
    for _, file in ipairs({ "/Users/example/notes.txt", "/fake-tmp/prosper-appupdates-1/notes",
                            "/fake-tmp/prosper-appupdates-x/status", "/Users/example/prosper-appupdates-1/status.part" }) do
        settle()
        reset()
        env.fsExists[file] = true
        host.prefs.set(PENDING, '{"file":"' .. file .. '","at":' .. AT .. ',"before":2}')
        G.on_upgrade_poll()
        h.eq(#shellLog, 0, "C8: poll reads and removes nothing for " .. file)
        h.eq(env.prefs[PENDING], "", "C8: poll drops the record for " .. file)
        host.prefs.set(PENDING, '{"file":"' .. file .. '","at":' .. AT .. ',"before":2}')
        G.on_launch()
        h.eq(#shellLog, 0, "C8: launch removes nothing for " .. file)
    end
    settle()
end

-- C9: a start time in the future counts as expired, like a missing one.
local function c9()
    settle()
    reset()
    host.prefs.set(PENDING, '{"file":"' .. OLD .. '/status","at":' .. (AT + 3600) .. ',"before":2}')
    brewOut = BREW_OUTDATED_2
    G.appupdates_upgrade()
    h.eq(shellLog[1], OLD_CLEANUP, "C9: the future record is dropped with its folder")
    h.eq(count("brew upgrade"), 1, "C9: the new upgrade starts")
    h.eq(env.notifications[1].body, "Nothing was upgraded", "C9: no refusal")
    for _, at in ipairs({ "1e999", "-1e999" }) do
        settle()
        reset()
        host.prefs.set(PENDING, '{"file":"' .. OLD .. '/status","at":' .. at .. ',"before":2}')
        G.on_upgrade_poll()
        h.eq(env.prefs[PENDING], "", "C9: an infinite at expires: " .. at)
    end
    -- One second in the past is still fresh (pins the comparison's direction).
    settle()
    reset()
    host.prefs.set(PENDING, '{"file":"' .. OLD .. '/status","at":' .. (AT - 1) .. ',"before":2}')
    G.appupdates_upgrade()
    h.eq(env.notifications[1].body, REFUSED, "C9: a record started a second ago refuses")
    h.eq(#shellLog, 0, "C9: and runs nothing")
    -- A record started at this very second is fresh too: refused, and a poll keeps it and its timer.
    settle()
    reset()
    local NOW_REC = '{"file":"' .. OLD .. '/status","at":' .. AT .. ',"before":2}'
    host.prefs.set(PENDING, NOW_REC)
    G.appupdates_upgrade()
    h.eq(env.notifications[1].body, REFUSED, "C9: a record started this second refuses")
    h.eq(#shellLog, 0, "C9: this second: runs nothing")
    env.timers[WATCH] = { id = WATCH, handler = "on_upgrade_poll" }
    G.on_upgrade_poll()
    h.eq(env.prefs[PENDING], NOW_REC, "C9: this second: the poll keeps the record")
    h.eq(env.timers[WATCH] ~= nil, true, "C9: this second: the poll keeps the timer")
    h.eq(#shellLog, 0, "C9: this second: the poll runs nothing")
    settle()
end

-- The cache's `at` is read back from prefs: a non-number or a time in the future is "never checked".
local function cacheAt()
    settle()
    for _, at in ipairs({ '"soon"', '"abc"', tostring(AT + 600), "{}" }) do
        host.prefs.set("cache", '{"at":' .. at .. ',"brew":[],"macos":[]}')
        local node = G.appupdates_check()
        h.eq(node.items[1].subtitle, "never checked · run “Check for Updates Now” to re-check", "cache at " .. at)
        env.timers = {}
        G.on_launch()
        h.eq(env.timers["appupdates.kick"] ~= nil, true, "cache at " .. at .. ": launch kicks a check")
    end
    host.prefs.set("cache", '{"at":' .. (AT - 120) .. ',"brew":[],"macos":[]}')
    h.eq(G.appupdates_check().items[1].subtitle, "checked 2m ago · run “Check for Updates Now” to re-check", "a good at")
    settle()
end

-- The whole upgrade command, written out.
local function wholeCommand()
    upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2)
    h.eq(upgradeCmd(), "/bin/mkdir -m 700 '" .. DIR .. "' 2>&1 || { echo 'brew upgrade did not start'; exit; }; "
         .. "/opt/homebrew/bin/brew upgrade > '" .. DIR .. "/status.part' 2>&1; s=$?; "
         .. "[ ! -L '" .. DIR .. "' ] && [ -O '" .. DIR .. "' ] && { echo $s >> '" .. DIR .. "/status.part' && "
         .. "/bin/mv -f '" .. DIR .. "/status.part' '" .. DIR .. "/status' && /bin/cat '" .. DIR .. "/status'; } || echo $s",
         "the upgrade command")
    settle()
end

-- When the status file cannot be printed (redirect refused, folder check false, append/mv/cat
-- failed) the shell prints the bare status, so a foreground run never reads as backgrounded.
local function bareStatus()
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, "1"), "brew upgrade failed (exit 1)", "bare status 1")
    h.eq(env.prefs[PENDING], "", "bare status 1: no watch record")
    h.eq(env.timers[WATCH], nil, "bare status 1: no watch timer")
    h.eq(upgrade(BREW_OUTDATED_2, BREW_OUTDATED_2, "0"), "Nothing was upgraded", "bare status 0, list unchanged")
    h.eq(env.prefs[PENDING], "", "bare status 0: no watch record")
    h.eq(env.timers[WATCH], nil, "bare status 0: no watch timer")
    settle()
end

c1()
status()
c3()
c4()
c5()
c6()
c7()
c8()
c9()
cacheAt()
wholeCommand()
bareStatus()

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
