-- Tests for the snippets extension. Run via scripts/test-extensions.sh.
-- The store is native (host.snippets.*); this Lua surface is the browse/manage
-- command (snippets_run), the Add form (snippets_add/sn_save), and verbs.

local h = require("harness")

local function fresh(snips)
    local host, env = h.makeHost{ snippets = snips or {} }
    local G = h.load(h.dir() .. "init.lua", host)
    return G, env
end

local SEED = {
    { name = "addr", keyword = ";;addr", text = "1 Loop", expanded = "1 Infinite Loop" },
}

-- ── browse: title is the RESOLVED body (what Enter pastes) ────────────────────
local G, env = fresh(SEED)
local out = G.snippets_run("sn")
h.eq(out.kind, "list", "browse renders a list")
h.eq(out.items[1].title, "1 Infinite Loop", "title is the expanded snippet body")
h.eq(out.items[1].subtitle, "addr  ·  ;;addr", "subtitle carries name + keyword")

-- filter by name/keyword
h.eq(#G.snippets_run("sn addr").items, 1, "matches by name")
h.eq(G.snippets_run("sn nope"):find("No snippet matches") ~= nil, true, "no match message")

-- ── list verb ────────────────────────────────────────────────────────────────
h.eq(G.snippets_run("sn list"), "addr  [;;addr]", "list shows name + keyword")
h.eq(G.snippets_run("sn help"), "sn <query> · sn add · sn rm <name> · sn list", "help is usage")

-- ── rm verb ──────────────────────────────────────────────────────────────────
h.eq(G.snippets_run("sn rm addr"), "Removed 'addr'", "rm confirms")
h.eq(#env.snippets, 0, "snippet removed from the store")
h.eq(G.snippets_run("sn rm"):find("Usage: sn rm") ~= nil, true, "rm needs a name")

-- ── empty store messaging ────────────────────────────────────────────────────
h.eq(G.snippets_run("sn list"):find("No snippets yet") ~= nil, true, "empty list hint")
h.eq(G.snippets_run("sn"):find("No snippets yet") ~= nil, true, "empty browse hint")

-- ── Add form open + save ─────────────────────────────────────────────────────
do
    local g, e = fresh{}
    h.eq(g.snippets_add("sn add greeting"), "", "add returns empty (window-only)")
    h.eq(e.window.kind, "form", "opens the Add Snippet form")
    h.eq(e.window.fields[1].value, "greeting", "name pre-filled from trailing text")

    g.sn_save(nil, e.host.json.encode{ name = "sig", text = "— Sent from Prosper" })
    h.eq(e.windowClosed, 1, "valid save closes the window")
    h.eq(#e.snippets, 1, "snippet persisted")
    h.eq(#e.notifications, 1, "save notifies")

    local form = g.sn_save(nil, e.host.json.encode{ name = "", text = "" })
    h.eq(form.kind, "form", "invalid save re-renders the form")
    h.eq(form.title:find("name & snippet required") ~= nil, true, "validation error shown")
    h.eq(e.windowClosed, 1, "invalid save does not close again")
end

-- ── #731: phone sets — read-only palette rows + Settings Remove ──────────────
do
    local g, e = fresh{ { name = "addr", keyword = ";;addr", text = "1 Loop", expanded = "1 Infinite Loop" } }
    local removed = {}
    local sets = {
        { device_id = "dev-AB12", device = "Kitchen", count = 1, updated = "Nov 3, 2026",
          snippets = { { id = "\1phone\1dev-AB12\1addr", name = "addr", keyword = "pa", text = "phone addr",
                         group = "Home" } } },
    }
    e.host.snippets.phone = function() return sets end
    e.host.snippets.remove_phone = function(id)
        removed[#removed + 1] = id
        sets = {}
    end
    local out = g.snippets_run("sn addr")
    h.eq(#out.items, 2, "Mac and phone snippet named alike both list")
    h.eq(out.items[1].subtitle, "addr  ·  ;;addr", "Mac row first, untouched")
    h.eq(out.items[2].title, "phone addr", "phone row resolves (text fallback)")
    h.eq(out.items[2].subtitle, "addr  ·  pa  ·  Home", "phone group rides in the subtitle")
    h.eq(out.items[2].accessory, "Kitchen", "grouped under the device")
    h.eq(#g.snippets_run("sn home").items, 1, "group is searchable")

    local page = g.settings_render("main", "{}")
    local phone
    for _, sec in ipairs(page.sections) do if sec.id == "phone" then phone = sec end end
    h.eq(phone ~= nil, true, "Settings lists phone sets")
    h.eq(phone.rows[1].title, "Kitchen · AB12", "title is device name + last 4 of device_id")
    h.eq(phone.rows[1].subtitle, "1 snippets · updated Nov 3, 2026", "count + updated")
    h.eq(phone.rows[2].actionID, "phone.remove:dev-AB12", "Remove button per device")
    h.eq(phone.rows[2].subtitle, "It comes back when that iPhone's snippets change.", "Remove help text")
    for _, sec in ipairs(page.sections) do
        if sec.id == "library" then h.eq(#sec.rows[1].records, 1, "phone snippets are never editable records") end
    end
    local after = g.settings_action("main", "phone.remove:dev-AB12", "", "{}")
    h.eq(removed[1], "dev-AB12", "Remove deletes that device's set")
    local still = false
    for _, sec in ipairs(after.sections) do if sec.id == "phone" then still = true end end
    h.eq(still, false, "no phone section once every set is removed")
end

print("ok snippets")
