-- Tests for the quickchat extension. Run via scripts/test-extensions.sh.
-- quickchat_run(query) strips the "c "/"ask " prefix, calls host.llm.chat, and
-- renders the streamed answer inline (with a spinner row until "done").

local h = require("harness")

local function run(query, result)
    local host, env = h.makeHost{ chatResult = result }
    local G = h.load(h.dir() .. "init.lua", host)
    return G.quickchat_run(query), env
end

-- ── Streaming milestone: partial answer + spinner ────────────────────────────
local out, env = run("c what is 2+2", { status = "generating", text = "The answer" })
h.eq(env.chatArgs.prompt, "what is 2+2", "prefix stripped, prompt forwarded")
h.eq(out.kind, "list", "renders a list")
h.eq(out.items[1].title, "The answer", "streamed text in the first card")
h.eq(out.items[2].id, "progress", "spinner row while generating")
h.eq(out.items[2].loading, true, "spinner is loading")
h.eq(#out.items, 2, "answer + spinner")

-- ── Done: no spinner ─────────────────────────────────────────────────────────
out = (run("ask hello", { status = "done", text = "Hi there" }))
h.eq(out.items[1].title, "Hi there", "final answer")
h.eq(#out.items, 1, "no spinner once done")

-- ── "ask " alias stripped ────────────────────────────────────────────────────
_, env = run("ask tell me a joke", { status = "done", text = "ok" })
h.eq(env.chatArgs.prompt, "tell me a joke", "'ask ' alias stripped")

-- ── Loading milestone: progress row, no answer yet ───────────────────────────
out = (run("c hi", { status = "loading", text = "" }))
h.eq(out.items[1].title, "Loading model…", "loading label")
h.eq(out.items[1].loading, true, "loading spinner")

-- ── Failed with no text ──────────────────────────────────────────────────────
out = (run("c hi", { status = "failed", text = "" }))
h.eq(out.items[1].title, "No answer", "failed label")
h.eq(out.items[1].loading, false, "failed is not loading")

-- ── Declines ─────────────────────────────────────────────────────────────────
h.eq((run("c ", { status = "done", text = "x" })), nil, "empty input declines")
h.eq((run("c hi", nil)), nil, "nil model result declines")

print("ok quickchat")
