-- Window Management: snap the focused window to a layout computed from its
-- screen's visible frame. Raycast-parity. Uses the native host.window API.
--
--   win left | right | top | bottom
--   win top-left | top-right | bottom-left | bottom-right
--   win first-third | center-third | last-third
--   win first-two-thirds | last-two-thirds
--   win maximize | center | almost-maximize | reasonable
--
-- Short aliases: l r t b · tl tr bl br · max/full/m · c/centre.

local USAGE = "win left|right|top|bottom · tl|tr|bl|br · first-third|center-third|last-third · max|center|almost-maximize"

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function round(n) return math.floor(n + 0.5) end

-- Each layout: f(screen, win) -> x, y, w, h. `screen` is the visible frame
-- {x,y,w,h}; `win` is the current window {x,y,w,h} (used by size-preserving
-- layouts like center).
local LAYOUTS = {
    ["left"]         = function(s) return s.x, s.y, s.w / 2, s.h end,
    ["right"]        = function(s) return s.x + s.w / 2, s.y, s.w / 2, s.h end,
    ["top"]          = function(s) return s.x, s.y, s.w, s.h / 2 end,
    ["bottom"]       = function(s) return s.x, s.y + s.h / 2, s.w, s.h / 2 end,

    ["top-left"]     = function(s) return s.x, s.y, s.w / 2, s.h / 2 end,
    ["top-right"]    = function(s) return s.x + s.w / 2, s.y, s.w / 2, s.h / 2 end,
    ["bottom-left"]  = function(s) return s.x, s.y + s.h / 2, s.w / 2, s.h / 2 end,
    ["bottom-right"] = function(s) return s.x + s.w / 2, s.y + s.h / 2, s.w / 2, s.h / 2 end,

    ["first-third"]      = function(s) return s.x, s.y, s.w / 3, s.h end,
    ["center-third"]     = function(s) return s.x + s.w / 3, s.y, s.w / 3, s.h end,
    ["last-third"]       = function(s) return s.x + 2 * s.w / 3, s.y, s.w / 3, s.h end,
    ["first-two-thirds"] = function(s) return s.x, s.y, 2 * s.w / 3, s.h end,
    ["last-two-thirds"]  = function(s) return s.x + s.w / 3, s.y, 2 * s.w / 3, s.h end,

    ["maximize"]        = function(s) return s.x, s.y, s.w, s.h end,
    ["center"]          = function(s, w) return s.x + (s.w - w.w) / 2, s.y + (s.h - w.h) / 2, w.w, w.h end,
    ["almost-maximize"] = function(s) return s.x + s.w * 0.05, s.y + s.h * 0.05, s.w * 0.9, s.h * 0.9 end,
    ["reasonable"]      = function(s) return s.x + s.w * 0.15, s.y + s.h * 0.1, s.w * 0.7, s.h * 0.8 end,
}

local ALIAS = {
    l = "left", r = "right", t = "top", b = "bottom",
    lefthalf = "left", righthalf = "right", tophalf = "top", bottomhalf = "bottom",
    tl = "top-left", tr = "top-right", bl = "bottom-left", br = "bottom-right",
    topleft = "top-left", topright = "top-right",
    bottomleft = "bottom-left", bottomright = "bottom-right",
    max = "maximize", full = "maximize", fullscreen = "maximize", m = "maximize",
    c = "center", centre = "center",
    ["left-third"] = "first-third", ["middle-third"] = "center-third", ["right-third"] = "last-third",
    ["left-two-thirds"] = "first-two-thirds", ["right-two-thirds"] = "last-two-thirds",
    almost = "almost-maximize",
}

-- Lower-case, collapse whitespace/underscores to single hyphens, strip edges.
local function normalize(s)
    s = s:lower():gsub("[%s_]+", "-"):gsub("%-+", "-")
    return (s:gsub("^%-", ""):gsub("%-$", ""))
end

function window_move(query)
    query = trim(query or "")
    local arg = trim(query:match("^win[dow]*%s*(.*)$") or "")
    if #arg == 0 then return USAGE end

    local key = normalize(arg)
    key = ALIAS[key] or key
    local layout = LAYOUTS[key]
    if not layout then
        return "Unknown layout '" .. arg .. "'. Try: " .. USAGE
    end

    local f = host.window.frame()
    if not f or not f.screen then
        return "No focused window (or Accessibility permission missing)."
    end
    local x, y, w, h = layout(f.screen, f)
    host.window.set(round(x), round(y), round(w), round(h))
    return "Snapped: " .. key
end
