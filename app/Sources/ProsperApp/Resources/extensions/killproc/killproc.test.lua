-- Unit tests for killproc/init.lua. The guard table IS the test: this extension
-- shells out to `kill`, so every refusal rule gets a case, and every end-to-end
-- case asserts on the RECORDED shell commands (the harness stub never runs a real
-- shell, so nothing on this machine is ever signalled).

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

-- shellRouter answers `ps`, `echo $PPID` and records every command; a `kill`
-- returns "" but is visible in env.shellLog.
local function newHost(opts)
    opts = opts or {}
    local log = {}
    local host, env
    host, env = h.makeHost{
        shellRouter = function(cmd)
            log[#log + 1] = cmd
            if cmd:find("echo %$PPID") then return tostring(opts.ownPid or 4242) end
            if cmd:find("^ps %-Ao") then return PS end
            local pid = cmd:match("^ps %-o comm= %-p (%d+)$")
            if pid then return (opts.comm and opts.comm[pid]) or "" end
            return ""
        end,
    }
    env.shellLog = log
    return host, env
end

local function killCmds(env)
    local out = {}
    for _, c in ipairs(env.shellLog) do
        if c:match("^kill ") then out[#out + 1] = c end
    end
    return out
end

local host, env = newHost()
local G = h.load(h.dir() .. "init.lua", host)
local guard, run = G.killproc_guard, G.killproc_run

-- ── 1. guard: the pid must be `^%d+$` (shell-injection boundary) ─────────────
for _, bad in ipairs({
    "12; rm -rf ~", "12 && reboot", "$(id)", "`id`", "12|cat", "-1", "1 2",
    "0x10", "12.0", " 12", "12 ", "", "abc", "12\n34",
}) do
    h.eq(guard(bad, "/usr/bin/vim", 4242), "not a pid",
         "non-numeric pid refused: " .. string.format("%q", bad))
end
h.eq(guard(nil, "/usr/bin/vim", 4242), "not a pid", "nil pid refused")
h.eq(guard(500, "/usr/bin/vim", 4242), nil, "numeric pid accepted (not just strings)")

-- ── 2. guard: pid <= 1 ───────────────────────────────────────────────────────
h.eq(guard("0", "kernel_task", 4242), "system pid", "pid 0 refused")
h.eq(guard("1", "/sbin/launchd", 4242), "system pid", "pid 1 refused")
h.eq(guard("2", "/usr/bin/vim", 4242), nil, "pid 2 allowed")

-- ── 3. guard: our own pid ────────────────────────────────────────────────────
h.eq(guard("4242", "/usr/bin/vim", 4242), "that's Prosper", "own pid refused")
h.eq(guard("4243", "/usr/bin/vim", 4242), nil, "neighbouring pid allowed")

-- ── 4. guard: the name blocklist, by bare name AND by full ps path ───────────
for _, name in ipairs({ "kernel_task", "launchd", "WindowServer", "loginwindow", "Prosper" }) do
    h.eq(guard("9001", name, 4242), "protected: " .. name, "blocked bare: " .. name)
    h.eq(guard("9001", "/System/Library/CoreServices/" .. name, 4242),
         "protected: " .. name, "blocked by basename: " .. name)
end
h.eq(guard("9001", "/usr/bin/Prosperity", 4242), nil, "substring of a blocked name is NOT blocked")

-- ── 5. guard: unknown / vanished process ─────────────────────────────────────
h.eq(guard("9001", nil, 4242), "no such process", "missing comm refused")
h.eq(guard("9001", "   ", 4242), "no such process", "blank comm refused")

-- ── 6. listing: parsed, CPU-sorted, protected rows flagged, no kill ──────────
local out = run("kill ")
h.eq(out.kind, "list", "empty query renders a list")
h.eq(out.items[1].title, "Prosper", "sorted by CPU desc (55.9 first)")
h.eq(out.items[2].title, "Safari", "second by CPU (12.5)")
h.eq(out.items[1].accessory, "that's Prosper", "own process shows its refusal, not a kill hint")
h.eq(out.items[3].accessory, "protected: WindowServer", "blocklisted row flagged")
h.eq(out.items[#out.items].title, "kernel_task", "lowest CPU last")
h.eq(out.items[2].accessory, "kill 501!", "killable row shows the commit gesture")
h.eq(out.items[2].subtitle, "pid 501  ·  12.5% CPU  ·  512 MB", "subtitle = pid · cpu · rss")
h.eq(#killCmds(env), 0, "listing never kills")

-- filter by name and by pid
h.eq(run("kill saf").items[1].title, "Safari", "filters by name (case-insensitive)")
h.eq(#run("kill 900").items, 1, "filters by pid substring")
h.eq(run("kill nosuchthing"), "No process matches 'nosuchthing'", "no match -> message")

-- ── 7. a bare pid NEVER kills (the per-keystroke hazard) ─────────────────────
host, env = newHost{ comm = { ["501"] = "/Applications/Safari.app/Contents/MacOS/Safari" } }
G = h.load(h.dir() .. "init.lua", host)
run = G.killproc_run
for _, q in ipairs({ "kill 5", "kill 50", "kill 501", "kill 501 " }) do run(q) end
h.eq(#killCmds(env), 0, "typing a pid without the ! sentinel never signals anything")

-- ── 8. `<pid>!` -> confirm -> kill -TERM, exactly once ───────────────────────
local msg = run("kill 501!")
h.eq(#killCmds(env), 1, "one kill issued")
h.eq(killCmds(env)[1], "kill -TERM 501", "SIGTERM by default")
h.eq(env.dialogConfirm.message, "Send -TERM to Safari (pid 501)?", "confirm names the process")
h.eq(msg, "Sent -TERM to Safari (pid 501)", "result text")
h.eq(env.notifications[1].title, "Sent -TERM", "notified")

-- ── 9. `<pid>!!` -> SIGKILL ──────────────────────────────────────────────────
host, env = newHost{ comm = { ["501"] = "/Applications/Safari.app/Contents/MacOS/Safari" } }
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
run("kill 501!!")
h.eq(killCmds(env)[1], "kill -9 501", "double bang forces SIGKILL")

-- ── 10. a declined confirm kills nothing ─────────────────────────────────────
host, env = newHost{ comm = { ["501"] = "/Applications/Safari.app/Contents/MacOS/Safari" } }
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
env.confirmReply = false
h.eq(run("kill 501!"), "Cancelled", "declined confirm cancels")
h.eq(#killCmds(env), 0, "declined confirm issues no kill")

-- ── 11. end-to-end refusals: every guard rule blocks the shell call ──────────
local REFUSALS = {
    { q = "kill 0!",    comm = { ["0"] = "kernel_task" },              want = "Refused (0): system pid" },
    { q = "kill 1!!",   comm = { ["1"] = "/sbin/launchd" },            want = "Refused (1): system pid" },
    { q = "kill 4242!", comm = { ["4242"] = "/Applications/Prosper.app/Contents/MacOS/Prosper" },
                                                                       want = "Refused (4242): that's Prosper" },
    { q = "kill 777!",  comm = { ["777"] = "/usr/sbin/WindowServer" }, want = "Refused (777): protected: WindowServer" },
    { q = "kill 778!",  comm = { ["778"] = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow" },
                                                                       want = "Refused (778): protected: loginwindow" },
    { q = "kill 999!",  comm = {},                                     want = "Refused (999): no such process" },
}
for _, c in ipairs(REFUSALS) do
    host, env = newHost{ comm = c.comm }
    G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
    h.eq(run(c.q), c.want, "refusal text: " .. c.q)
    h.eq(#killCmds(env), 0, "no kill issued for " .. c.q)
end

-- ── 12. a hostile process name never reaches a shell string ──────────────────
host, env = newHost{ comm = { ["501"] = "/tmp/evil; rm -rf ~ #" } }
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
run("kill 501!")
h.eq(killCmds(env)[1], "kill -TERM 501", "only the validated pid is interpolated")
for _, c in ipairs(env.shellLog) do
    h.eq(c:find("rm -rf", 1, true), nil, "no shell command ever contains the process name: " .. c)
end

-- ── 13. a non-numeric commit form is inert (never reaches the shell) ─────────
host, env = newHost()
G = h.load(h.dir() .. "init.lua", host); run = G.killproc_run
for _, q in ipairs({ "kill 501; rm -rf ~!", "kill $(id)!", "kill abc!", "kill -1!" }) do
    run(q)
end
h.eq(#killCmds(env), 0, "garbage commit forms fall through to the filter, never to kill")
for _, c in ipairs(env.shellLog) do
    h.eq(c:match("^ps %-o comm=") ~= nil and c:match("^ps %-o comm= %-p %d+$") == nil, false,
         "the targeted ps lookup only ever sees a numeric pid: " .. c)
end

print("✅ killproc")
