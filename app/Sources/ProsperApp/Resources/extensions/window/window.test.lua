-- Tests for the window extension. Run via scripts/test-extensions.sh.
-- window_move(query) -> status string; snaps via host.window.set.

local h = require("harness")

-- A 1000×800 visible screen at origin, with a 400×300 window at (100,100).
local function host_with_window()
    return h.makeHost{ frame = {
        x = 100, y = 100, w = 400, h = 300,
        screen = { x = 0, y = 0, w = 1000, h = 800 },
    } }
end

local function snap(arg)
    local host, env = host_with_window()
    local G = h.load(h.dir() .. "init.lua", host)
    local msg = G.window_move(arg)
    return env.windowSet, msg
end

-- ── Halves ───────────────────────────────────────────────────────────────────
local s = snap("win left")
h.eq(s.x, 0, "left x"); h.eq(s.y, 0, "left y"); h.eq(s.w, 500, "left w"); h.eq(s.h, 800, "left h")

s = snap("win right")
h.eq(s.x, 500, "right x"); h.eq(s.w, 500, "right w")

-- ── Aliases resolve to the same layout ───────────────────────────────────────
local s2, msg = snap("win l")
h.eq(s2.w, 500, "alias 'l' == left"); h.eq(msg, "Snapped: left", "alias normalizes to canonical name")

-- ── Maximize / center ────────────────────────────────────────────────────────
s = snap("win max")
h.eq(s.x, 0, "max x"); h.eq(s.w, 1000, "max w"); h.eq(s.h, 800, "max h")

s = snap("win center")  -- size-preserving, centered on screen
h.eq(s.x, 300, "center x = (1000-400)/2"); h.eq(s.y, 250, "center y = (800-300)/2")
h.eq(s.w, 400, "center keeps width"); h.eq(s.h, 300, "center keeps height")

-- ── Thirds round to integer pixels ───────────────────────────────────────────
s = snap("win first-third")
h.eq(s.w, 333, "first-third w = round(1000/3)")

-- ── Usage / errors ───────────────────────────────────────────────────────────
h.eq(snap("win"), nil, "no arg → no snap")   -- windowSet stays nil
local _, usage = snap("win")
h.eq(usage:find("win left") ~= nil, true, "bare 'win' returns usage")
local _, unknown = snap("win bogus")
h.eq(unknown:find("Unknown layout") ~= nil, true, "unknown layout is reported")

-- ── No focused window (missing Accessibility / no frame) ─────────────────────
do
    local host, env = h.makeHost{}      -- env.frame is nil
    local G = h.load(h.dir() .. "init.lua", host)
    local msg = G.window_move("win left")
    h.eq(env.windowSet, nil, "no frame → nothing snapped")
    h.eq(msg:find("No focused window") ~= nil, true, "explains the missing window")
end

print("ok window")
