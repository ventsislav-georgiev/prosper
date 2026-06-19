-- Self-test for the test harness itself (scripts/ext-test/harness.lua) — the
-- highest-risk new code is the hand-rolled JSON codec, so exercise it directly
-- instead of only transitively through the extension tests.
-- Run via scripts/test-extensions.sh (the runner scans this dir too).

local h = require("harness")

-- Recursive equality (h.eq only does ~=); treats h.NULL like any value.
local function deepeq(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local seen = {}
    for k, v in pairs(a) do
        if not deepeq(v, b[k]) then return false end
        seen[k] = true
    end
    for k in pairs(b) do if not seen[k] then return false end end
    return true
end
local function rt(v, msg) -- round-trip: decode(encode(v)) deep-equals v
    h.eq(deepeq(h.decode(h.encode(v)), v), true, msg)
end

-- ── scalars ──────────────────────────────────────────────────────────────────
h.eq(h.encode(true), "true", "bool true")
h.eq(h.encode(false), "false", "bool false")
h.eq(h.encode(42), "42", "integer")
h.eq(h.encode(0.9), "0.9", "float keeps value")
h.eq(h.encode(150.0), "150", "whole float → integer form")
h.eq(h.encode(0/0), "null", "NaN → null")
h.eq(h.encode(1/0), "null", "inf → null")
h.eq(h.decode("42"), 42, "decode bare integer")
h.eq(h.decode("  -3.5 "), -3.5, "decode negative float w/ whitespace")
h.eq(h.decode(""), nil, "empty string → nil")

-- ── strings + escaping + unicode ─────────────────────────────────────────────
h.eq(h.encode('a"b\\c'), '"a\\"b\\\\c"', "quote + backslash escaped")
h.eq(h.encode("tab\there"), '"tab\\there"', "tab escaped")
rt("plain", "string round-trips")
rt("new\nline\ttab", "control chars round-trip")
h.eq(h.decode('"\\u00e9"'), "é", "unicode escape decodes to UTF-8")
rt("café ☕", "utf-8 literal round-trips")

-- ── nested objects / arrays ──────────────────────────────────────────────────
rt({ a = 1, b = "two", c = true }, "flat object")
rt({ 1, 2, 3 }, "number array")
rt({ { name = "a", tags = { "x", "y" } }, { name = "b", tags = {} } },
   "array of objects with nested array")
rt({ outer = { inner = { deep = { 1, 2 } } } }, "deeply nested")

-- ── JSON null → M.NULL sentinel (the critic's MAJOR): no index shift ─────────
local arr = h.decode("[1,null,3]")
h.eq(#arr, 3, "null occupies its array slot — length preserved")
h.eq(arr[1], 1, "index 1 intact")
h.eq(arr[2], h.NULL, "index 2 is the NULL sentinel, not a shifted value")
h.eq(arr[3], 3, "index 3 did NOT shift down")
h.eq(h.encode(h.NULL), "null", "sentinel re-encodes to null")
h.eq(h.encode({ 1, h.NULL, 3 }), "[1,null,3]", "null round-trips in an array")
local obj = h.decode('{"a":1,"b":null}')
h.eq(obj.b, h.NULL, "object null value kept as sentinel (key not dropped)")

-- ── documented round-trip limits (asserted so they don't silently change) ────
h.eq(h.encode(h.decode("[]")), "{}", "empty array → {} (documented Lua limit)")

-- ── http.get stub models the real host transform ────────────────────────────
do
    local wire = { status = 200, body = h.encode{ result = "ok", n = 7 } }
    local host, env = h.makeHost{ httpResponse = wire }
    local resp, err = host.http.get("https://x/y", { timeout = 1 })
    h.eq(resp.ok, true, "2xx → ok=true")
    h.eq(err, nil, "success has no error")
    h.eq(resp.json.result, "ok", "body decoded into resp.json")
    h.eq(resp.json.n, 7, "nested value decoded")
    h.eq(env.httpArgs.url, "https://x/y", "records the requested url")
    h.eq(env.calls.http, 1, "counts the bridge call")
    -- the caller's fixture must NOT be mutated (real host builds resp fresh)
    h.eq(wire.ok, nil, "fixture table left pristine — no ok leaked back")
    h.eq(wire.json, nil, "fixture table left pristine — no json leaked back")
end
do  -- non-2xx returns the resp plus an error, ok=false, no decode crash
    local host = h.makeHost{ httpResponse = { status = 503 } }
    local resp, err = host.http.get("https://x")
    h.eq(resp.ok, false, "5xx → ok=false")
    h.eq(resp.json, nil, "no body → json nil")
    h.eq(err, "http 503", "carries the status in the error")
end
do  -- nil fixture → total failure (nil, err), matching the real contract
    local host = h.makeHost{}
    local resp, err = host.http.get("https://x")
    h.eq(resp, nil, "no response → nil")
    h.eq(err, "request failed", "error string on total failure")
end

-- ── bench/le helpers behave ──────────────────────────────────────────────────
local per = h.bench(1000, function() return 1 + 1 end)
h.eq(type(per) == "number" and per >= 0, true, "bench returns a per-call time")
h.le(0, 1, "le passes when within budget")
local ok = pcall(h.le, 2, 1, "should error")
h.eq(ok, false, "le raises when over budget")

print("ok harness")
