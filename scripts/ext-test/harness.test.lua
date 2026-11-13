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

-- ── shell.run stub mirrors the real host.shell.run (ExtensionHostAPI bootstrap) ─
do  -- opts checks: the exact texts the real shim raises (ShellRunnerTests testBadOptsRaiseNamingTheKey)
    local host, env = h.makeHost{ shellOut = "out" }
    local function e(o)
        local ok, err = pcall(host.shell.run, "true", o)
        return ok and "ok" or tostring(err)
    end
    h.eq(table.concat({ e("yes"), e({ keep_runing = true }), e({ keep_running = 1 }),
                        e({ keep_running = false }), e(nil), e(false), e(true), e(1) }, "|"),
         "host.shell.run: opts must be a table, got string"
         .. "|host.shell.run: unknown option 'keep_runing'"
         .. "|host.shell.run: keep_running must be a boolean, got number|ok|ok|ok"
         .. "|host.shell.run: opts must be a table, got boolean"
         .. "|host.shell.run: opts must be a table, got number", "bad opts raise like the host")
    h.eq(env.calls.shell, 3, "a rejected call is not counted: nothing ran")
    h.eq(#env.shellCalls, 3, "a rejected call is not recorded")
    -- level 2: the error names the caller's line, as the real shim does
    local _, err = pcall(function() host.shell.run("x", { timeout = 5 }) end)
    h.eq(err:match("^[^:]*harness%.test%.lua:%d+: host%.shell%.run: unknown option 'timeout'$") ~= nil,
         true, "error blames the calling line: " .. tostring(err))
end
do  -- the record: per call, the command and whether keep_running was set
    local host, env = h.makeHost{ shellOut = "out" }
    host.shell.run("a")
    host.shell.run("b", { keep_running = true })
    host.shell.run("c", { keep_running = false })
    host.shell.run("d", false)
    h.eq(env.calls.shell, 4, "calls.shell still counts every call")
    h.eq(#env.shellCalls, 4, "one record per call")
    local got = {}
    for _, c in ipairs(env.shellCalls) do got[#got + 1] = c.cmd .. "=" .. tostring(c.keep_running) end
    h.eq(table.concat(got, ","), "a=false,b=true,c=false,d=false", "cmd and keep_running recorded")
    h.eq(env.shellCalls[1].timed_out, false, "a normal call did not time out")
    h.eq(env.shellCalls[1].killed, false, "a normal call was not killed")
end
do  -- return shape: one value by default, (out, true) when truncated, never nil
    local host = h.makeHost{ shellOut = "out" }
    local r = table.pack(host.shell.run("x"))
    h.eq(r.n .. ":" .. r[1], "1:out", "canned output: one value")
    host = h.makeHost{ shellOut = "big", shellTruncated = true }
    r = table.pack(host.shell.run("x"))
    h.eq(r.n .. ":" .. r[1] .. ":" .. tostring(r[2]), "2:big:true", "canned truncated: two values")
    host = h.makeHost{ shellRouter = function(cmd) return cmd .. "!" end }
    r = table.pack(host.shell.run("one"))
    h.eq(r.n .. ":" .. r[1], "1:one!", "a one-value router keeps working, one value")
    host = h.makeHost{ shellRouter = function() return "cut", true end }
    r = table.pack(host.shell.run("x"))
    h.eq(r.n .. ":" .. r[1] .. ":" .. tostring(r[2]), "2:cut:true", "router truncated: two values")
    host = h.makeHost{ shellRouter = function() return "x", false, "junk" end }
    r = table.pack(host.shell.run("x"))
    h.eq(r.n .. ":" .. r[1], "1:x", "false truncated and extra values are dropped")
    host = h.makeHost{ shellRouter = function() return nil end }
    r = table.pack(host.shell.run("x"))
    h.eq(r.n .. ":" .. r[1], "1:", "the host never answers nil: \"\"")
end
do  -- h.TIMEOUT: "" (one value) like the host, recorded, killed unless keep_running
    local host, env = h.makeHost{ shellRouter = function() return h.TIMEOUT end }
    local r = table.pack(host.shell.run("slow"))
    h.eq(r.n .. ":" .. r[1], "1:", "timeout answers one empty value")
    r = table.pack(host.shell.run("slow", { keep_running = true }))
    h.eq(r.n .. ":" .. r[1], "1:", "keep_running timeout answers the same")
    local a, b = env.shellCalls[1], env.shellCalls[2]
    h.eq(tostring(a.timed_out) .. "," .. tostring(a.killed), "true,true", "timeout without keep_running kills")
    h.eq(tostring(b.timed_out) .. "," .. tostring(b.killed), "true,false", "keep_running timeout leaves it running")
    host, env = h.makeHost{ shellOut = h.TIMEOUT }
    h.eq(host.shell.run("x"), "", "canned shellOut can time out too")
    h.eq(env.shellCalls[1].timed_out, true, "canned timeout recorded")
end
-- ── the level: privileged = false is the real non-system answer (ExtensionHostAPI.swift:521-523) ─
local REFUSED = "error: host.shell is restricted to system extensions"
local function routed() -- a router that counts its calls
    local seen = { n = 0 }
    return seen, function(cmd) seen.n = seen.n + 1; seen.last = cmd; return "ran:" .. tostring(cmd) end
end
do  -- refused level, valid call: one value, the refusal, nothing ran
    local seen, router = routed()
    local host, env = h.makeHost{ privileged = false, shellRouter = router }
    h.eq(select("#", host.shell.run("echo hi")), 1, "refused: exactly one return value")
    h.eq(host.shell.run("echo hi", { keep_running = true }), REFUSED, "refused: the host's string")
    h.eq(select("#", host.shell.run(nil)), 1, "refused, nil cmd: still one value")
    h.eq(host.shell.run(42), REFUSED, "refused: cmd is never looked at")
    h.eq(seen.n, 0, "refused: the router was never called")
    h.eq(#env.shellCalls, 0, "refused: nothing recorded as run")
    h.eq(env.calls.shell, 4, "refused: each bridge hop still counted")
end
do  -- refused level, bad option: the shim's opts check wins over the gate
    local host, env = h.makeHost{ privileged = false }
    local ok, err = pcall(host.shell.run, "echo hi", { bogus = true })
    h.eq(ok, false, "refused + bad option raises")
    h.eq(err:match("host%.shell%.run: .*$"), "host.shell.run: unknown option 'bogus'", "the opts error, not the refusal")
    h.eq(env.calls.shell, 0, "a raised call is not counted")
end
do  -- system level (control) and the default when the option is absent
    local seen, router = routed()
    local host, env = h.makeHost{ privileged = true, shellRouter = router }
    h.eq(host.shell.run("echo hi"), "ran:echo hi", "privileged = true runs")
    host, env = h.makeHost{ shellRouter = router }
    h.eq(env.privileged, true, "default level is the system one")
    h.eq(select("#", host.shell.run("echo hi")), 1, "default: one value")
    h.eq(seen.n .. ":" .. #env.shellCalls, "2:1", "default: routed and recorded")
end
do  -- a cmd that is not a string, privileged: lua_tostring semantics (ExtensionHostAPI.swift:507)
    local seen, router = routed()
    local host, env = h.makeHost{ shellRouter = router }
    for _, c in ipairs({ { nil, "nil" }, { {}, "table" }, { true, "true" }, { false, "false" } }) do
        h.eq(select("#", host.shell.run(c[1])), 1, c[2] .. " cmd: one value")
        h.eq(host.shell.run(c[1]), "", c[2] .. " cmd answers \"\"")
    end
    h.eq(host.shell.run(""), "", "empty string cmd answers \"\"")
    h.eq(host.shell.run(" \n\t"), "", "blank string cmd answers \"\"")
    h.eq(host.shell.run(), "", "missing cmd answers \"\"")
    h.eq(seen.n .. ":" .. #env.shellCalls, "0:0", "none of them reached the router or the record")
    h.eq(env.calls.shell, 11, "each still a counted hop")
    h.eq(host.shell.run(42), "ran:42", "an integer runs as its string")
    h.eq(type(seen.last) .. ":" .. seen.last, "string:42", "the router gets a string, not a number")
    h.eq(host.shell.run(1.5), "ran:1.5", "a float runs as its string")
    h.eq(env.shellCalls[#env.shellCalls].cmd, "1.5", "recorded as the string")
    local ok, err = pcall(host.shell.run, nil, { keep_running = 1 })
    h.eq(ok, false, "opts still checked for a non-string cmd")
    h.eq(err:match("host%.shell%.run: .*$"), "host.shell.run: keep_running must be a boolean, got number", "opts error text")
end

-- ── bench/le helpers behave ──────────────────────────────────────────────────
local per = h.bench(1000, function() return 1 + 1 end)
h.eq(type(per) == "number" and per >= 0, true, "bench returns a per-call time")
h.le(0, 1, "le passes when within budget")
local ok = pcall(h.le, 2, 1, "should error")
h.eq(ok, false, "le raises when over budget")

print("ok harness")
