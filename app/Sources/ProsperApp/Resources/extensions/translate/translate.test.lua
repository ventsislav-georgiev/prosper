-- Tests for the translate extension. Run via scripts/test-extensions.sh.
-- translate_run(query) strips the "l "/"t " prefix, calls host.llm.translate using
-- this extension's own target/source prefs, and renders the result inline.

local h = require("harness")

local function run(query, result, prefs)
    local host, env = h.makeHost{ translateResult = result }
    for k, v in pairs(prefs or {}) do host.prefs.set(k, v) end
    local G = h.load(h.dir() .. "init.lua", host)
    return G.translate_run(query), env
end

local RESULT = {
    primary = "здравей",
    detected = "English",
    candidates = {
        { text = "здрасти", label = "informal", note = "casual register" },
        { text = "здравей", label = "dup" },     -- equals primary → deduped out
    },
}

-- ── Default target, auto source ──────────────────────────────────────────────
local out, env = run("l hello", RESULT)
h.eq(env.translateArgs.text, "hello", "prefix stripped")
h.eq(env.translateArgs.target, "Bulgarian", "default target")
h.eq(env.translateArgs.source, nil, "no source pref → auto-detect (nil)")
h.eq(out.kind, "list", "renders a list")
h.eq(out.subtitle, "Detected: English", "detected language in subtitle")
h.eq(out.items[1].title, "здравей", "primary translation first")
h.eq(out.items[2].title, "здрасти", "alternative rendering")
h.eq(out.items[2].accessory, "informal", "register chip")
h.eq(#out.items, 2, "candidate equal to primary is deduped")

-- ── Configured target; "Auto" source means detect ───────────────────────────
_, env = run("t bonjour", RESULT, { target = "French", source = "Auto" })
h.eq(env.translateArgs.target, "French", "target pref honored")
h.eq(env.translateArgs.source, nil, "'Auto' → nil source")

-- ── Explicit source passed through ───────────────────────────────────────────
_, env = run("l hola", RESULT, { source = "Spanish" })
h.eq(env.translateArgs.source, "Spanish", "explicit source forwarded")

-- ── Declines ─────────────────────────────────────────────────────────────────
h.eq((run("l ", RESULT)), nil, "empty input declines")
h.eq((run("l hi", nil)), nil, "nil model result declines")
h.eq((run("l hi", { primary = "  " })), nil, "blank primary declines")

print("ok translate")
