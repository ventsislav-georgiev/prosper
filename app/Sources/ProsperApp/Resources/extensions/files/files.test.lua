-- Tests for the files extension. Run via scripts/test-extensions.sh.
-- files_run(query) strips the "f " prefix, parses filter tokens, searches
-- (host.files.search), and renders a launcher list with the file actions.

local h = require("harness")

local function run(query, files)
    local host, env = h.makeHost{ files = files or {} }
    local G = h.load(h.dir() .. "init.lua", host)
    return G.files_run(query), env
end

-- ── Filter tokens are parsed out of the query ────────────────────────────────
local hits = { { name = "report.pdf", path = "/Users/x/Docs/report.pdf",
                 display = "~/Docs", kind = "PDF document", isDir = false } }
local out, env = run("f kind:pdf quarterly in:~/Docs content:1", hits)
local q = env.fileQuery
h.eq(q.name, "quarterly", "free text accumulates into name")
h.eq(q.kind[1], "pdf", "kind: token parsed")
h.eq(q["in"], "~/Docs", "in: scope parsed")
h.eq(q.content, true, "content: flag parsed")

-- ── Hits render rows with the built-in file actions ──────────────────────────
h.eq(out.kind, "list", "renders a list")
h.eq(out.style, "rows", "compact rows")
h.eq(out.items[1].title, "report.pdf", "row title is the file name")
h.eq(out.items[1].launch, "/Users/x/Docs/report.pdf", "path rides along for actions")
h.eq(out.items[1].actions[1].id, "file.open", "primary action is Open")

-- ext: token strips a leading dot
_, env = run("f ext:.png logo", hits)
h.eq(env.fileQuery.ext[1], "png", "ext: leading dot stripped")

-- ── No matches → explanatory row ─────────────────────────────────────────────
out = run("f nope", {})
h.eq(out.items[1].title:find("No files matching") ~= nil, true, "empty-state row")

-- ── Empty query declines ─────────────────────────────────────────────────────
h.eq((run("f ", {})), nil, "bare prefix declines")
h.eq((run(nil, {})), nil, "nil declines")

print("ok files")
