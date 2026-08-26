-- Unit tests for killproc/init.lua.
--
-- The refusal RULES are not tested here any more — they live natively in
-- KillProcessSupport (see KillProcessSupportTests.swift), and this extension only
-- asks for them through host.process. What is tested here is everything this file
-- still owns: the listing, the filter, the trailing-"!" commit gesture, the
-- confirm gate, and the two shell-safety invariants (only a validated pid is ever
-- interpolated, the process name never is).
--
-- The harness's host.process never signals anything real: a kill that gets past
-- the stubbed refusals just appends to env.kills.

local h = require("harness")

local PS = table.concat({
    "  501  12.5  524288 /Applications/Safari.app/Contents/MacOS/Safari",
    "  777   3.2   65536 /usr/sbin/WindowServer",
    "    1   0.1    8192 /sbin/launchd",
    "    0   0.0       0 kernel_task",
    " 4242  55.9 2097152 /Applications/Prosper.app/Contents/MacOS/Prosper",
    "  900   0.4   16384 /usr/bin/ssh-agent",
    "garbage line that must be ignored",
}, "\n")

-- What the native guard would say about the pids in PS.
local REFUSALS = {
    ["0"] = "system pid",
    ["1"] = "system pid",
    ["777"] = "protected: WindowServer",
    ["4242"] = "that's Prosper",
}

-- shellRouter answers `ps` and records every command; opts.comm supplies the
-- targeted `ps -o comm= -p <pid>` lookup (display name only).
local function newHost(opts)
    opts = opts or {}
    local log = {}
    local host, env
    host, env = h.makeHost{
        processRefusals = opts.refusals or REFUSALS,
        shellRouter = function(cmd)
            log[#log + 1] = cmd
            if cmd:find("^ps %-Ao") then return PS end
            local pid = cmd:match("^ps %-o comm= %-p (%d+)$")
            if pid then return (opts.comm and opts.comm[pid]) or "" end
            return ""
        end,
    }
    env.shellLog = log
    return host, env
end

local host, env = newHost()
local G = h.load(h.dir() .. "init.lua", host)
local run = G.killproc_run

-- ── 1. the guard rules are NOT duplicated in Lua ─────────────────────────────
h.eq(G.killproc_guard, nil, "no Lua-side guard function survives (rules live natively)")

-- ── 2. listing: parsed, CPU-sorted, refused rows flagged, no kill ────────────
local out = run("kill ")
h.eq(out.kind, "list", "empty query renders a list")
h.eq(out.items[1].title, "Prosper", "sorted by CPU desc (55.9 first)")
h.eq(out.items[2].title, "Safari", "second by CPU (12.5)")
h.eq(out.items[1].accessory, "that's Prosper", "own process shows its refusal, not a kill hint")
h.eq(out.items[3].accessory, "protected: WindowServer", "blocklisted row flagged")
h.eq(out.items[#out.items].title, "kernel_task", "lowest CPU last")
h.eq(out.items[2].accessory, "kill 501!", "killable row shows the commit gesture")
h.eq(out.items[2].subtitle, "pid 501  ·  12.5% CPU  ·  512 MB", "subtitle = pid · cpu · rss")
h.eq(#env.kills, 0, "listing never kills")

-- filter by name and by pid
h.eq(run("kill saf").items[1].title, "Safari", "filters by name (case-insensitive)")
h.eq(#run("kill 900").items, 1, "filters by pid substring")
h.eq(run("kill nosuchthing"), "No process matches 'nosuchthing'", "no match -> message")

-- ── 3. a bare pid NEVER kills (the per-keystroke hazard) ─────────────────────
host, env = newHost{ comm = { ["501"] = "/Applications/Safari.app/Contents/MacOS/Safari" } }
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
for _, q in ipairs({ "kill 5", "kill 50", "kill 501", "kill 501 " }) do run(q) end
h.eq(#env.kills, 0, "typing a pid without the ! sentinel never signals anything")

-- ── 4. `<pid>!` -> confirm -> SIGTERM, exactly once ──────────────────────────
local msg = run("kill 501!")
h.eq(#env.kills, 1, "one kill issued")
h.eq(env.kills[1].pid, "501", "the pid from the query")
h.eq(env.kills[1].force, false, "SIGTERM by default")
h.eq(env.dialogConfirm.message, "Send -TERM to Safari (pid 501)?", "confirm names the process")
h.eq(msg, "Sent -TERM to Safari (pid 501)", "result text")
h.eq(env.notifications[1].title, "Sent -TERM", "notified")

-- ── 5. `<pid>!!` -> SIGKILL ──────────────────────────────────────────────────
host, env = newHost{ comm = { ["501"] = "/Applications/Safari.app/Contents/MacOS/Safari" } }
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
run("kill 501!!")
h.eq(env.kills[1].force, true, "double bang forces SIGKILL")

-- ── 6. a declined confirm kills nothing ──────────────────────────────────────
host, env = newHost{ comm = { ["501"] = "/Applications/Safari.app/Contents/MacOS/Safari" } }
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
env.confirmReply = false
h.eq(run("kill 501!"), "Cancelled", "declined confirm cancels")
h.eq(#env.kills, 0, "declined confirm issues no kill")

-- ── 7. a native refusal blocks the kill AND the dialog ───────────────────────
for _, c in ipairs({
    { q = "kill 0!",    want = "Refused (0): system pid" },
    { q = "kill 1!!",   want = "Refused (1): system pid" },
    { q = "kill 4242!", want = "Refused (4242): that's Prosper" },
    { q = "kill 777!",  want = "Refused (777): protected: WindowServer" },
    { q = "kill 999!",  want = "Refused (999): no such process",
      refusals = { ["999"] = "no such process" } },
}) do
    host, env = newHost{ refusals = c.refusals }
    G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
    h.eq(run(c.q), c.want, "refusal text: " .. c.q)
    h.eq(#env.kills, 0, "no kill issued for " .. c.q)
    h.eq(env.dialogConfirm, nil, "a refused kill never asks the user: " .. c.q)
end

-- ── 8. the native guard is authoritative even past the confirm ───────────────
-- The pid can be recycled while the dialog is up, so host.process.kill re-checks:
-- refusal() says yes, kill() says no, and the extension must report the refusal.
host, env = newHost{ comm = { ["501"] = "/Applications/Safari.app/Contents/MacOS/Safari" } }
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
host.process.kill = function() return "protected: WindowServer" end
h.eq(run("kill 501!"), "Refused (501): protected: WindowServer",
     "a refusal at the kill call wins over the earlier refusal() pass")
h.eq(#env.notifications, 0, "and nothing is reported as sent")

-- ── 9. a hostile process name never reaches a shell string ───────────────────
host, env = newHost{ comm = { ["501"] = "/tmp/evil; rm -rf ~ #" } }
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
run("kill 501!")
h.eq(env.kills[1].pid, "501", "the kill takes a pid, never a command")
for _, c in ipairs(env.shellLog) do
    h.eq(c:find("rm -rf", 1, true), nil, "no shell command ever contains the process name: " .. c)
    h.eq(c:match("^kill"), nil, "nothing is killed through a shell any more: " .. c)
end

-- ── 10. a non-numeric commit form is inert ───────────────────────────────────
host, env = newHost()
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
for _, q in ipairs({ "kill 501; rm -rf ~!", "kill $(id)!", "kill abc!", "kill -1!" }) do
    run(q)
end
h.eq(#env.kills, 0, "garbage commit forms fall through to the filter, never to kill")
for _, c in ipairs(env.shellLog) do
    h.eq(c:match("^ps %-o comm=") ~= nil and c:match("^ps %-o comm= %-p %d+$") == nil, false,
         "the targeted ps lookup only ever sees a numeric pid: " .. c)
end

print("✅ killproc")
