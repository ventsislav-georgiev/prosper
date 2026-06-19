-- Tests for the url-dispatcher extension. Run via scripts/test-extensions.sh.
-- on_url(payload) routes a link to a browser; url_dispatcher_make_default() sets
-- Prosper as the default http/https handler.

local h = require("harness")
local function fresh()
    local host, env = h.makeHost{}
    return h.load(h.dir() .. "init.lua", host), env
end

-- ── Domain routing ───────────────────────────────────────────────────────────
local G, env = fresh()
G.on_url{ url = "https://github.com/torvalds/linux" }
h.eq(env.urlOpened.browser, "com.google.Chrome", "github.com → Chrome")
h.eq(env.urlOpened.url, "https://github.com/torvalds/linux", "original url preserved")

G, env = fresh()
G.on_url{ url = "https://www.figma.com/file/x" }
h.eq(env.urlOpened.browser, "company.thebrowser.Browser", "figma.com → Arc")

-- ── Unmatched domain → system default (nil bundle id) ────────────────────────
G, env = fresh()
G.on_url{ url = "https://example.com/" }
h.eq(env.urlOpened.browser, nil, "unmatched → system default")
h.eq(env.urlOpened.url, "https://example.com/", "still opened")

-- ── Guards ───────────────────────────────────────────────────────────────────
G, env = fresh()
G.on_url{ url = "" }
h.eq(env.urlOpened, nil, "empty url → no open")
G.on_url{}
h.eq(env.urlOpened, nil, "missing url → no open")

-- ── Make-default command ─────────────────────────────────────────────────────
do
    local host, env2 = h.makeHost{ setDefaultOK = true }
    local g = h.load(h.dir() .. "init.lua", host)
    g.url_dispatcher_make_default()
    h.eq(env2.defaultBrowserSet, "eu.illegible.prosper", "registers Prosper as default")
    h.eq(h.lastAlert(env2):find("now the default browser") ~= nil, true, "success toast")
end
do
    local host, env2 = h.makeHost{ setDefaultOK = false }
    local g = h.load(h.dir() .. "init.lua", host)
    g.url_dispatcher_make_default()
    h.eq(h.lastAlert(env2):find("Could not") ~= nil, true, "failure toast")
end

print("ok url-dispatcher")
