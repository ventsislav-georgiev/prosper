-- Tests for the shell extension. Run via scripts/test-extensions.sh.
-- shell_run(query) strips a leading "! "/"> " trigger, runs the command, renders.

local h = require("harness")

local function run(query, shellOut)
    local host, env = h.makeHost{ shellOut = shellOut or "" }
    local G = h.load(h.dir() .. "init.lua", host)
    return G.shell_run(query), env
end

-- ── Output rendered, command echoed in the subtitle ──────────────────────────
local out, env = run("! echo hi", "hi\n")
h.eq(out.kind, "list", "renders a list")
h.eq(out.style, "rows", "compact rows")
h.eq(out.items[1].title, "hi", "captured output, trimmed")
h.eq(out.items[1].subtitle, "$ echo hi", "command echoed (trigger stripped)")
h.eq(env.calls.shell, 1, "shells exactly once")

-- ── '>' trigger and tight (no-space) prefix both strip ───────────────────────
out = run("> pwd", "/tmp\n")
h.eq(out.items[1].subtitle, "$ pwd", "'>' trigger stripped")
out = run("!ls", "a\nb")
h.eq(out.items[1].subtitle, "$ ls", "tight '!' prefix stripped")

-- ── Empty output gets a placeholder ──────────────────────────────────────────
out = run("! true", "")
h.eq(out.items[1].title, "(no output)", "empty output placeholder")

-- ── Empty command declines ───────────────────────────────────────────────────
h.eq((run("!", "")), nil, "bare trigger declines")
h.eq((run("  ", "")), nil, "blank declines")
h.eq((run(nil, "")), nil, "nil declines")

print("ok shell")
