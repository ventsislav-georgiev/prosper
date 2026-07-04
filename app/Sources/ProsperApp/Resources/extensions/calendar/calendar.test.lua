-- Calendar extension is a native-feature gate: init.lua must load cleanly and
-- define NO globals — no commands table, no on_* event handlers. The host
-- treats any defined handler as routable, so the stub staying inert is the
-- contract (all behavior lives in Swift, gated on this extension being live).
local h = require("harness")

local host = h.makeHost{}

-- Snapshot the globals the harness pre-seeds, load, then diff: the gate must
-- add nothing.
local before = {}
for k in pairs(_G) do before[k] = true end

local G = h.load(h.dir() .. "init.lua", host)

local added = {}
for k in pairs(G) do
    if not before[k] and k ~= "host" then added[#added + 1] = tostring(k) end
end
h.eq(#added, 0, "gate defines no globals (got: " .. table.concat(added, ", ") .. ")")

-- Belt and braces: the two shapes the host would route.
h.eq(G.commands, nil, "no commands table")
h.eq(G.on_launch, nil, "no lifecycle handlers")

print("calendar: OK")
