-- Tests for the pasteplain extension. Run via scripts/test-extensions.sh.
-- Everything is against the harness stub host — no real keystroke ever leaves here.

local h = require("harness")

local function run(opts)
    local host, env = h.makeHost(opts)
    local G = h.load(h.dir() .. "init.lua", host)
    return G.pasteplain_paste(""), env
end

-- ── Happy path: pasteboard rewritten as plain text, then ⌘V ──────────────────
local out, env = run{ clipboard = "hello", perms = { accessibility = true } }
h.eq(out, nil, "no-view command renders nothing")
h.eq(env.clipboard, "hello", "text written back verbatim")
h.eq(env.strokes[1], "cmd+v", "synthesizes cmd+v")
h.eq(#env.strokes, 1, "exactly one stroke")

-- ── The one assumption: hotkey path keeps the target app focused ─────────────
-- Proven by the recorded call ORDER — the write lands before the stroke (so ⌘V
-- reads the plain pasteboard), and nothing renders/opens UI in between, which is
-- what would steal focus from the app the user is typing in.
h.eq(env.actions[1], "clip.write", "write happens first")
h.eq(env.actions[2], "keys.stroke:cmd+v", "stroke happens second")
h.eq(#env.actions, 2, "no other side effect between write and stroke")
h.eq(#env.alerts, 0, "no alert on the happy path")

-- ── No Accessibility: alert, and crucially no stroke ─────────────────────────
out, env = run{ clipboard = "hello", perms = {} }
h.eq(out, nil, "still renders nothing")
h.eq(#env.strokes, 0, "no keystroke without Accessibility")
h.eq(#env.actions, 0, "clipboard untouched too")
h.eq(h.lastAlert(env) ~= nil, true, "tells the user to grant Accessibility")

-- ── Empty clipboard: nothing to do ───────────────────────────────────────────
out, env = run{ clipboard = "", perms = { accessibility = true } }
h.eq(#env.strokes, 0, "empty clipboard pastes nothing")
h.eq(#env.actions, 0, "and writes nothing")

print("ok pasteplain")
