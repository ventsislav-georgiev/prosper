-- Tests for the units extension. Run via scripts/test-extensions.sh.
-- unit_convert(query) -> "<fromDisplay>\t<toDisplay>\t<formatted>", or nil.

local h = require("harness")
local host = h.makeHost{}
local G = h.load(h.dir() .. "init.lua", host)
local function eq(q, want) h.eq(G.unit_convert(q), want, "units '" .. q .. "'") end

-- ── Length / mass / data within a category ───────────────────────────────────
eq("1 km to m", "km\tm\t1000 m")
eq("100 cm to m", "cm\tm\t1 m")
eq("1 mile to km", "mi\tkm\t1.609344 km")  -- Foundation coefficient, %.8f trimmed
eq("1 kg to g", "kg\tg\t1000 g")
eq("1 GB to MB", "GB\tMB\t1000 MB")        -- decimal data units

-- ── Separators + plural normalization ────────────────────────────────────────
eq("60 minutes to hours", "minutes\thours\t1 hours")  -- trailing "s" stripped to "minute"
eq("1km->m", "km\tm\t1000 m")              -- "->" separator, no spaces

-- ── Declines (return nil) ────────────────────────────────────────────────────
eq("1 kg to m", nil)                        -- cross-category
eq("100 celsius to fahrenheit", nil)        -- temperature deliberately not handled
eq("5 m", nil)                              -- no separator
eq("1 km to zzz", nil)                       -- unknown target unit
eq("km to m", nil)                          -- no number
eq("", nil)
h.eq(G.unit_convert(nil), nil, "nil query declines")

print("ok units")
