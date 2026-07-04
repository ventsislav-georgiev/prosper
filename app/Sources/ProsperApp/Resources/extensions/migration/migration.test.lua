-- Tests for the migration extension (Raycast / Alfred importer).
-- Run via scripts/test-extensions.sh (stock lua + scripts/ext-test/harness.lua).

local h = require("harness")

-- Build a host whose shell answers per-command via router; opts merge through.
local function fresh(router, opts)
    opts = opts or {}
    opts.shellRouter = router
    local host, env = h.makeHost(opts)
    local G = h.load(h.dir() .. "init.lua", host)
    return G, env
end

local RAYCAST_QL = [=[
[
  { "link": "https://duckduckgo.com/?q={argument}", "name": "Search DuckDuckGo" },
  { "openWith": "Finder", "iconName": "folder-16", "link": "~/Downloads", "name": "Downloads" },
  { "link": "https://github.com/{argument name=\"repo\"}", "name": "GitHub Repo" }
]
]=]

local RAYCAST_SN = [=[
[
  { "name": "bug", "keyword": "xbug", "text": "🐛" },
  { "name": "sig", "text": "Cheers,\nV" }
]
]=]

-- ── Raycast quicklinks JSON (picker → cat → merge, placeholder conversion) ──────
do
    local G, env = fresh(function(cmd)
        if cmd:find("osascript", 1, true) and cmd:find("choose file", 1, true) then
            return "/x/ql.json\n"
        end
        if cmd:find("cat '/x/ql.json'", 1, true) then return RAYCAST_QL end
        return ""
    end)
    G.settings_action("migration", "raycast_json", "", "{}")
    h.eq(#env.quicklinks, 3, "three quicklinks imported")
    h.eq(env.quicklinks[1].target, "https://duckduckgo.com/?q={query}", "{argument} converted")
    h.eq(env.quicklinks[3].target, "https://github.com/{query}", "named {argument …} converted")
    h.eq(env.quicklinks[2].description, "Opens with Finder", "openWith kept as description")
    h.eq(env.prefs.last_report ~= nil, true, "report persisted")
    h.eq(#env.notifications, 1, "notified")
end

-- ── Raycast snippets JSON auto-detected by shape; dedup by keyword ──────────────
do
    local G, env = fresh(function(cmd)
        if cmd:find("choose file", 1, true) then return "/x/sn.json\n" end
        if cmd:find("cat '/x/sn.json'", 1, true) then return RAYCAST_SN end
        return ""
    end, { snippets = { { name = "existing", keyword = "xbug", text = "old" } } })
    G.settings_action("migration", "raycast_json", "", "{}")
    h.eq(#env.snippets, 2, "one added, keyword collision skipped")
    h.eq(env.snippets[2].name, "sig", "non-colliding snippet imported")
    h.eq(env.snippets[2].collection, "Raycast", "collection tagged")
    h.eq(env.snippets[2].autoExpand, false, "no keyword -> no autoExpand")
    h.eq(env.prefs.last_report:find("1 snippets added %(1 skipped%)") ~= nil, true, "report counts")
end

-- ── Raycast .rayconfig: password dialog + openssl pipeline; nested payload ──────
do
    local seen_cmd
    local G, env = fresh(function(cmd)
        if cmd:find("choose file", 1, true) then return "/x/backup.rayconfig\n" end
        if cmd:find("display dialog", 1, true) then return "s3cr'et\n" end
        if cmd:find("openssl enc -d", 1, true) then
            seen_cmd = cmd
            return '{"Quicklinks":{"items":[{"name":"GH","link":"https://github.com"}]},'
                .. '"Snippets":[{"name":"addr","keyword":"xaddr","text":"1 Main St"}]}'
        end
        return ""
    end)
    G.settings_action("migration", "raycast_backup", "", "{}")
    h.eq(#env.quicklinks, 1, "quicklink found in nested backup")
    h.eq(#env.snippets, 1, "snippet found in nested backup")
    h.eq(seen_cmd:find("RAYPASS='s3cr'\\''et'", 1, true) ~= nil, true, "password shell-quoted via env")
    h.eq(seen_cmd:find("-nosalt -md md5", 1, true) ~= nil, true, "legacy KDF flags present")
    h.eq(seen_cmd:find("tail -c +17", 1, true) ~= nil, true, "16-byte header stripped")
end

-- ── .rayconfig wrong password → empty pipeline output → alert, no import ────────
do
    local G, env = fresh(function(cmd)
        if cmd:find("choose file", 1, true) then return "/x/backup.rayconfig\n" end
        if cmd:find("display dialog", 1, true) then return "nope\n" end
        return "" -- openssl|gunzip pipeline yields nothing
    end)
    G.settings_action("migration", "raycast_backup", "", "{}")
    h.eq(#env.quicklinks, 0, "nothing imported")
    h.eq(h.lastAlert(env):find("wrong password") ~= nil, true, "decrypt failure explained")
end

-- ── Cancelled picker → no-op, still re-renders ──────────────────────────────────
do
    local G, env = fresh(function() return "" end)
    local node = G.settings_action("migration", "raycast_json", "", "{}")
    h.eq(#env.quicklinks, 0, "cancel imports nothing")
    h.eq(node.kind, "settings.ui", "action re-renders settings")
end

-- ── Alfred auto-import: prefs.json redirect, websearch plist, snippet affixes ───
do
    local PREFS = "/sync/Alfred.alfredpreferences"
    local G, env = fresh(function(cmd)
        if cmd:find("Alfred/prefs.json", 1, true) then
            return '{"current":"' .. PREFS .. '"}'
        end
        if cmd:find("websearch/prefs.plist", 1, true) then
            return '{"customSites":{"ABC-1":{"text":"Search GitHub","keyword":"gh",'
                .. '"url":"https://github.com/search?q={query}","enabled":true,"utf8":true},'
                .. '"ABC-2":{"text":"Disabled","keyword":"off","url":"https://x.y","enabled":false}}}'
        end
        if cmd:find("find '" .. PREFS .. "/snippets'", 1, true) then
            return PREFS .. "/snippets/Emoji/bug [UID-1].json\n"
        end
        if cmd:find("snippets/Emoji/info.plist", 1, true) then
            return '{"snippetkeywordprefix":"!","snippetkeywordsuffix":""}'
        end
        if cmd:find("bug %[UID%-1%]") then
            return '{"alfredsnippet":{"snippet":"🐛","uid":"UID-1","name":"bug","keyword":"bug"}}'
        end
        return ""
    end)
    G.settings_action("migration", "alfred_auto", "", "{}")
    h.eq(#env.quicklinks, 1, "enabled web search imported, disabled skipped")
    h.eq(env.quicklinks[1].name, "Search GitHub", "web search name")
    h.eq(env.quicklinks[1].description, "Alfred keyword: gh", "keyword kept as description")
    h.eq(#env.snippets, 1, "bundle snippet imported")
    h.eq(env.snippets[1].keyword, "!bug", "collection keyword prefix baked in")
    h.eq(env.snippets[1].collection, "Emoji", "collection from folder name")
end

-- ── Alfred not installed → alert, no crash ──────────────────────────────────────
do
    local G, env = fresh(function() return "" end)
    G.settings_action("migration", "alfred_auto", "", "{}")
    h.eq(h.lastAlert(env):find("Alfred preferences not found") ~= nil, true, "missing Alfred explained")
end

-- ── .alfredsnippets zip: ditto extract, root files get the file's collection ────
do
    local extracted, cleaned
    local G, env = fresh(function(cmd)
        if cmd:find("choose file", 1, true) then return "/x/Emoji Pack.alfredsnippets\n" end
        if cmd:find("ditto %-x %-k") then extracted = cmd; return "" end
        if cmd:find("rm %-rf") then cleaned = cmd; return "" end
        if cmd:find("^find ") then
            return "/tmp/prosper-migration-1000/wave [U2].json\n"
        end
        if cmd:find("wave %[U2%]") then
            return '{"alfredsnippet":{"snippet":"👋","uid":"U2","name":"wave","keyword":"wave"}}'
        end
        return ""
    end)
    G.settings_action("migration", "alfred_zip", "", "{}")
    h.eq(extracted ~= nil, true, "zip extracted with ditto")
    h.eq(cleaned ~= nil, true, "temp dir removed")
    h.eq(#env.snippets, 1, "zip snippet imported")
    h.eq(env.snippets[1].collection, "Emoji Pack", "collection named after the file")
end

-- ── Quicklink dedup by name; re-run is a no-op ──────────────────────────────────
do
    local G, env = fresh(function(cmd)
        if cmd:find("choose file", 1, true) then return "/x/ql.json\n" end
        if cmd:find("cat '/x/ql.json'", 1, true) then return RAYCAST_QL end
        return ""
    end)
    G.settings_action("migration", "raycast_json", "", "{}")
    G.settings_action("migration", "raycast_json", "", "{}")
    h.eq(#env.quicklinks, 3, "second run adds nothing")
    h.eq(env.prefs.last_report:find("0 quicklinks added %(3 skipped%)") ~= nil, true, "re-run reports skips")
end

-- ── Palette command deep-links into settings ────────────────────────────────────
do
    local G, env = fresh(function() return "" end)
    G.migration_open()
    h.eq(env.settingsOpened, "migration", "command opens the migration pane")
end

-- ── settings_render structure ───────────────────────────────────────────────────
do
    local G, env = fresh(function() return "" end)
    local node = G.settings_render("migration", "{}")
    h.eq(node.kind, "settings.ui", "renders settings ui")
    h.eq(#node.sections, 3, "raycast + alfred + status sections")
    h.eq(node.sections[2].rows[1].subtitle:find("Not found") ~= nil, true,
        "alfred status row reflects missing install")
end

print("ok migration")
