-- Tests for the calc extension. Run via scripts/test-extensions.sh.
-- calc_eval(query) -> formatted result string, or nil to decline.

local h = require("harness")
local host = h.makeHost{}
local G = h.load(h.dir() .. "init.lua", host)
local function eq(q, want) h.eq(G.calc_eval(q), want, "calc '" .. q .. "'") end

-- ── Core arithmetic + precedence ─────────────────────────────────────────────
eq("2+2", "4")
eq("2 + 3 * 4", "14")               -- * binds tighter than +
eq("(2 + 3) * 4", "20")             -- parentheses override
eq("2 ^ 3 ^ 2", "512")             -- ^ is right-associative (3^2 first)
eq("-5 + 3", "-2")                 -- unary minus
eq("10 - -4", "14")                -- unary after binary op

-- ── Formatting parity with native Calc.format ────────────────────────────────
eq("10 / 4", "2.5")
eq("10 / 3", "3.33333333")          -- %.8f, trailing zeros trimmed
eq("1_000 + 1,000", "2000")        -- _ and , digit separators

-- ── Unicode operators ────────────────────────────────────────────────────────
eq("6 × 7", "42")
eq("8 ÷ 2", "4")

-- ── Declines (return nil) ────────────────────────────────────────────────────
eq("5 / 0", nil)                    -- division by zero
eq("5 % 0", nil)                    -- modulo by zero
eq("42", nil)                       -- a bare number is not a "calc"
eq("(2 + 3", nil)                   -- unbalanced parens
eq("hello", nil)                    -- non-arithmetic
eq("", nil)
h.eq(G.calc_eval(nil), nil, "nil query declines")

-- ── Percentage shorthands (Raycast parity) ───────────────────────────────────
eq("52% of 900", "468")
eq("20% off 50", "40")
eq("120 + 10%", "132")
eq("120 - 10%", "108")
eq("what is 3% of 123", "3.69")
eq("what's 50% of 10", "5")

print("ok calc")
