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

-- ── Mode → key rules ─────────────────────────────────────────────────────────
-- The rule set is what decides which chord is intercepted, so it is the piece
-- worth pinning: the wrong shape here either hijacks ⌘V uninvited or does nothing.

local function launch(mode)
    local host, env = h.makeHost{}
    if mode then host.prefs.set("mode", mode) end
    local G = h.load(h.dir() .. "init.lua", host)
    G.on_launch()
    return G, env
end

local function rule(env, from)
    for _, r in ipairs(env.keyRules or {}) do
        if r.from == from then return r end
    end
    return nil
end

-- Default: nothing at all is intercepted.
local G
G, env = launch(nil)
h.eq(#env.keyRules, 0, "no key rules until the user opts in")

-- An unknown/garbled stored mode falls back to off rather than guessing.
G, env = launch("nonsense")
h.eq(#env.keyRules, 0, "unknown mode is treated as off")

-- ⌘V-plain: both chords are claimed, ⌘V strips and ⇧⌘V pastes the original.
G, env = launch("cmd_v_plain")
h.eq(#env.keyRules, 2, "cmd_v_plain claims both paste chords")
h.eq(rule(env, "cmd+v").invoke, "pasteplain_chord", "cmd+v routed back to the extension")
h.eq(rule(env, "cmd+v").arg, "plain", "cmd+v is the plain one")
h.eq(rule(env, "cmd+v").not_apps[1], "com.apple.finder", "Finder keeps its own cmd+v")
h.eq(rule(env, "cmd+shift+v").arg, "rich", "shift+cmd+v pastes the original")
h.eq(rule(env, "cmd+shift+v").not_apps, nil, "the rich chord is claimed everywhere")

-- ⇧⌘V-plain: ⌘V is never claimed, so an ordinary paste never reaches us at all.
G, env = launch("shift_cmd_v_plain")
h.eq(#env.keyRules, 1, "shift_cmd_v_plain claims only one chord")
h.eq(rule(env, "cmd+v"), nil, "cmd+v is left completely alone")
h.eq(rule(env, "cmd+shift+v").arg, "plain", "shift+cmd+v is the plain one")

-- ── The intercepted chord always ends in a paste ─────────────────────────────
-- The tap already swallowed the real keystroke, so any path that skips the stroke
-- would silently eat the user's paste.
G, env = launch("cmd_v_plain")
env.clipboard = "styled"
G.pasteplain_chord("plain")
h.eq(env.actions[#env.actions - 1], "clip.write", "plain chord rewrites the pasteboard")
h.eq(env.actions[#env.actions], "keys.stroke:cmd+v", "then pastes")

G, env = launch("cmd_v_plain")
env.clipboard = "styled"
G.pasteplain_chord("rich")
h.eq(#env.strokes, 1, "the rich chord still pastes")
h.eq(env.actions[#env.actions], "keys.stroke:cmd+v", "and does it without touching the clipboard")

-- Non-text clipboard (an image, a copied file): paste it untouched rather than
-- swallowing the keystroke.
G, env = launch("cmd_v_plain")
env.clipboard = ""
G.pasteplain_chord("plain")
h.eq(env.strokes[1], "cmd+v", "a clipboard with no text still pastes")
h.eq(env.clipboard, "", "and is not rewritten")

-- ── Changing the mode in settings takes effect immediately ───────────────────
G, env = launch(nil)
h.eq(#env.keyRules, 0, "starts off")
G.settings_action("pasteplain", "set:mode", "shift_cmd_v_plain", "{}")
h.eq(env.prefs.mode, "shift_cmd_v_plain", "mode persisted")
h.eq(#env.keyRules, 1, "rules re-registered without a relaunch")
G.settings_action("pasteplain", "set:mode", "off", "{}")
h.eq(#env.keyRules, 0, "and cleared again when switched off")

print("ok pasteplain")
