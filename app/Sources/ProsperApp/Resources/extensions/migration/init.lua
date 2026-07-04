-- migration — one-time importer that moves quicklinks & snippets from Raycast /
-- Alfred into Prosper.
--
-- Sources, easiest first:
--   • Raycast per-feature exports: the "Export Quicklinks" / "Export Snippets"
--     commands write plain JSON — no password. One button imports either file
--     (the type is auto-detected from the object shape).
--   • Raycast full backup (.rayconfig, Settings → Advanced → Export): encrypted
--     AES-256-CBC with OpenSSL's legacy no-salt key derivation, wrapping a
--     16-byte header + gzipped JSON. The export password is asked for in a
--     native dialog (never persisted) and the decrypt runs through openssl.
--   • Alfred: everything is plaintext on disk — web searches (Alfred's
--     quicklink equivalent) in websearch/prefs.plist, snippets as
--     snippets/<Collection>/*.json. One click, no export step. An exported
--     .alfredsnippets collection (a zip) is also accepted.
--
-- Imports MERGE: existing Prosper quicklinks (by name) and snippets (by name or
-- keyword) are never overwritten — duplicates are counted and skipped, so
-- re-running an import is always safe.
--
-- Stateless: every button press is one settings_action invocation; the only
-- persisted state is the last-import summary in host.prefs.

local REPORT_KEY = "last_report"

local function trim(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

-- Single-quote a value for the shell — the only safe way to pass user-picked
-- paths (and the export password) through host.shell.run.
local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- MARK: native dialogs (osascript) ------------------------------------------------

-- Native file picker. Returns an absolute POSIX path, or nil when cancelled.
local function choose_file(prompt)
    local out = trim(host.shell.run(
        "osascript -e 'POSIX path of (choose file with prompt \"" .. prompt .. "\")' 2>/dev/null") or "")
    if #out == 0 then return nil end
    return out
end

-- Password prompt with hidden input. Returns the password, or nil when
-- cancelled / left empty. Transient by design: the password is never written to
-- prefs or disk, and is passed to openssl via the environment (not argv).
local function ask_password(title)
    local out = host.shell.run(
        "osascript -e 'text returned of (display dialog \"Enter the password you set when exporting.\""
        .. " with title \"" .. title .. "\" default answer \"\" with hidden answer)' 2>/dev/null") or ""
    out = out:gsub("\n$", "") -- keep inner whitespace — only the trailing newline is ours
    if #out == 0 then return nil end
    return out
end

-- MARK: merge into Prosper ----------------------------------------------------------

-- Existing entries win: quicklinks dedup by name, snippets by name or keyword.
local function merge_quicklinks(items)
    local seen = {}
    for _, ql in ipairs(host.quicklinks.all()) do seen[ql.name] = true end
    local added, skipped = 0, 0
    for _, item in ipairs(items) do
        local name, target = trim(item.name), trim(item.target)
        if #name == 0 or #target == 0 or seen[name] then
            skipped = skipped + 1
        else
            host.quicklinks.save{ name = name, target = target,
                                  description = type(item.description) == "string" and item.description or nil }
            seen[name] = true
            added = added + 1
        end
    end
    return added, skipped
end

local function merge_snippets(items)
    local names, keywords = {}, {}
    for _, s in ipairs(host.snippets.all()) do
        names[s.name] = true
        if type(s.keyword) == "string" and #s.keyword > 0 then keywords[s.keyword] = true end
    end
    local added, skipped = 0, 0
    for _, item in ipairs(items) do
        local name, keyword = trim(item.name), trim(item.keyword)
        local text = type(item.text) == "string" and item.text or ""
        if #name == 0 or #text == 0 or names[name] or (#keyword > 0 and keywords[keyword]) then
            skipped = skipped + 1
        else
            host.snippets.save{
                name = name, keyword = keyword, text = text,
                collection = type(item.collection) == "string" and item.collection or "",
                autoExpand = #keyword > 0,
            }
            names[name] = true
            if #keyword > 0 then keywords[keyword] = true end
            added = added + 1
        end
    end
    return added, skipped
end

local function report(source, ql_added, ql_skipped, sn_added, sn_skipped)
    local parts = {}
    if ql_added + ql_skipped > 0 then
        parts[#parts + 1] = string.format("%d quicklinks added (%d skipped)", ql_added, ql_skipped)
    end
    if sn_added + sn_skipped > 0 then
        parts[#parts + 1] = string.format("%d snippets added (%d skipped)", sn_added, sn_skipped)
    end
    if #parts == 0 then parts[1] = "nothing to import" end
    local msg = source .. ": " .. table.concat(parts, ", ")
    host.prefs.set(REPORT_KEY, msg)
    host.notify("Migration", msg)
    return msg
end

-- MARK: Raycast ----------------------------------------------------------------------

-- Raycast link placeholders → Prosper. Prosper natively substitutes {query} and
-- {argument}; only Raycast's extended forms ({argument name="…" …}) need mapping.
local function convert_link(link)
    return (link:gsub("{[Aa]rgument[^}]*}", "{query}"))
end

-- Pull quicklink- and snippet-shaped objects out of ANY decoded Raycast JSON.
-- Works for the per-feature exports (flat arrays of {name,link} / {name,text})
-- AND the full .rayconfig payload (the same objects nested under category keys)
-- without depending on Raycast's top-level schema.
local function scan_raycast(node, links, snippets)
    if type(node) ~= "table" then return end
    if type(node.name) == "string" and type(node.link) == "string" then
        links[#links + 1] = {
            name = node.name,
            target = convert_link(node.link),
            description = (type(node.openWith) == "string" and #node.openWith > 0)
                and ("Opens with " .. node.openWith) or nil,
        }
    elseif type(node.name) == "string" and type(node.text) == "string" then
        snippets[#snippets + 1] = { name = node.name, keyword = node.keyword,
                                    text = node.text, collection = "Raycast" }
    end
    for _, v in pairs(node) do scan_raycast(v, links, snippets) end
end

local function import_raycast_table(data, source)
    local links, snippets = {}, {}
    scan_raycast(data, links, snippets)
    if #links == 0 and #snippets == 0 then
        host.alert.show("No quicklinks or snippets found in that file")
        return
    end
    local qa, qs = merge_quicklinks(links)
    local sa, ss = merge_snippets(snippets)
    host.alert.show(report(source, qa, qs, sa, ss))
end

local function import_raycast_json(path)
    local raw = host.shell.run("cat " .. q(path) .. " 2>/dev/null") or ""
    local data = host.json.decode(raw)
    if type(data) ~= "table" then
        host.alert.show("Could not read that file as Raycast JSON")
        return
    end
    import_raycast_table(data, "Raycast")
end

local function import_rayconfig(path, password)
    -- .rayconfig = AES-256-CBC (openssl legacy -nosalt/-md md5 key derivation)
    -- around a 16-byte header + gzipped JSON. A wrong password makes gunzip
    -- fail, so the pipeline yields an empty string — that's the error signal.
    local raw = host.shell.run(
        "RAYPASS=" .. q(password)
        .. " openssl enc -d -aes-256-cbc -nosalt -md md5 -pass env:RAYPASS -in " .. q(path)
        .. " 2>/dev/null | tail -c +17 | gunzip 2>/dev/null") or ""
    local data = host.json.decode(raw)
    if type(data) ~= "table" then
        host.alert.show("Could not decrypt — wrong password, or not a Raycast .rayconfig export")
        return
    end
    import_raycast_table(data, "Raycast backup")
end

-- MARK: Alfred -----------------------------------------------------------------------

-- Active Alfred.alfredpreferences bundle: Alfred records a relocated bundle
-- (e.g. in a sync folder) in prefs.json; fall back to the default location.
local function alfred_prefs_dir()
    local out = host.shell.run('cat "$HOME/Library/Application Support/Alfred/prefs.json" 2>/dev/null') or ""
    local t = host.json.decode(out)
    if type(t) == "table" and type(t.current) == "string" and #t.current > 0 then
        return t.current
    end
    local probe = trim(host.shell.run(
        '[ -d "$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences" ]'
        .. ' && echo "$HOME/Library/Application Support/Alfred/Alfred.alfredpreferences"') or "")
    if #probe > 0 then return probe end
    return nil
end

-- Alfred custom web searches → quicklinks. Same {query} placeholder as Prosper.
local function alfred_websearches(dir)
    local out = host.shell.run("plutil -convert json -o - "
        .. q(dir .. "/preferences/features/websearch/prefs.plist") .. " 2>/dev/null") or ""
    local t = host.json.decode(out)
    local sites = type(t) == "table" and t.customSites or nil
    local items = {}
    if type(sites) == "table" then
        for _, site in pairs(sites) do
            if type(site) == "table" and type(site.url) == "string" and site.enabled ~= false then
                local keyword = type(site.keyword) == "string" and site.keyword or ""
                local name = (type(site.text) == "string" and #site.text > 0) and site.text or keyword
                items[#items + 1] = {
                    name = name, target = site.url,
                    description = #keyword > 0 and ("Alfred keyword: " .. keyword) or nil,
                }
            end
        end
    end
    return items
end

-- Parse every snippet JSON under `root`. Layout: <root>/<Collection>/Name [UID].json,
-- each {"alfredsnippet":{name=,keyword=,snippet=}}. A collection's info.plist may
-- carry keyword prefix/suffix affixes Alfred applies at expansion time — bake
-- them into the imported keyword. `default_collection` names snippets that sit
-- directly in root (an unzipped .alfredsnippets has no collection folder).
local function alfred_snippets_in(root, default_collection)
    local listing = host.shell.run("find " .. q(root) .. " -type f -name '*.json' 2>/dev/null") or ""
    local items, affixes = {}, {}
    for path in listing:gmatch("[^\n]+") do
        local dir = path:match("^(.*)/[^/]+$") or root
        local aff = affixes[dir]
        if not aff then
            local plist = host.shell.run("plutil -convert json -o - "
                .. q(dir .. "/info.plist") .. " 2>/dev/null") or ""
            local t = host.json.decode(plist)
            aff = {
                prefix = (type(t) == "table" and type(t.snippetkeywordprefix) == "string") and t.snippetkeywordprefix or "",
                suffix = (type(t) == "table" and type(t.snippetkeywordsuffix) == "string") and t.snippetkeywordsuffix or "",
            }
            affixes[dir] = aff
        end
        local raw = host.shell.run("cat " .. q(path) .. " 2>/dev/null") or ""
        local t = host.json.decode(raw)
        local s = type(t) == "table" and t.alfredsnippet or nil
        if type(s) == "table" and type(s.snippet) == "string" then
            local keyword = type(s.keyword) == "string" and s.keyword or ""
            if #keyword > 0 then keyword = aff.prefix .. keyword .. aff.suffix end
            local collection = dir:match("([^/]+)$")
            if dir == root then collection = default_collection end
            items[#items + 1] = { name = s.name, keyword = keyword, text = s.snippet,
                                  collection = collection or "Alfred" }
        end
    end
    return items
end

local function import_alfred()
    local dir = alfred_prefs_dir()
    if not dir then
        host.alert.show("Alfred preferences not found — is Alfred installed?")
        return
    end
    local links = alfred_websearches(dir)
    local snippets = alfred_snippets_in(dir .. "/snippets", nil)
    if #links == 0 and #snippets == 0 then
        host.alert.show("No web searches or snippets found in Alfred")
        return
    end
    local qa, qs = merge_quicklinks(links)
    local sa, ss = merge_snippets(snippets)
    host.alert.show(report("Alfred", qa, qs, sa, ss))
end

local function import_alfredsnippets(path)
    local tmp = "/tmp/prosper-migration-" .. tostring(host.time())
    host.shell.run("mkdir -p " .. q(tmp) .. " && ditto -x -k " .. q(path) .. " " .. q(tmp) .. " 2>/dev/null")
    local collection = path:match("([^/]+)%.alfredsnippets$") or "Alfred"
    local items = alfred_snippets_in(tmp, collection)
    host.shell.run("rm -rf " .. q(tmp))
    if #items == 0 then
        host.alert.show("No snippets found in that file")
        return
    end
    local sa, ss = merge_snippets(items)
    host.alert.show(report("Alfred snippets", 0, 0, sa, ss))
end

-- MARK: command -----------------------------------------------------------------------

-- Palette command ("Import from Raycast or Alfred") — jump to the settings pane.
function migration_open()
    host.settings.open("migration")
end

-- MARK: settings (Tier B) ---------------------------------------------------------------

function settings_render(section_id, state)
    local s = host.ui.settings

    local raycast = s.section{
        id = "raycast", title = "Raycast", accent = "migration",
        footer = "Quickest path: in Raycast, run the “Export Quicklinks” and “Export Snippets” "
            .. "commands — each saves a plain JSON file, no password — then import them here "
            .. "(either file; the type is detected automatically). The full backup "
            .. "(Raycast Settings → Advanced → Export) also works: it writes a "
            .. "password-protected .rayconfig — you'll be asked for that password during "
            .. "import, and it is never stored.",
        rows = {
            s.row{ kind = "button", id = "raycast_json", actionID = "raycast_json",
                   title = "Import Raycast JSON export…",
                   subtitle = "A file saved by “Export Quicklinks” or “Export Snippets”",
                   style = "prominent" },
            s.row{ kind = "button", id = "raycast_backup", actionID = "raycast_backup",
                   title = "Import full Raycast backup (.rayconfig)…",
                   subtitle = "Password-protected export from Raycast Settings → Advanced" },
        },
    }

    local alfred_dir = alfred_prefs_dir()
    local alfred_rows = {
        s.row{ kind = "info", title = "Alfred preferences",
               subtitle = alfred_dir or "Not found — Alfred doesn't seem to be installed." },
    }
    if alfred_dir then
        alfred_rows[#alfred_rows + 1] = s.row{
            kind = "button", id = "alfred_auto", actionID = "alfred_auto",
            title = "Import from Alfred",
            subtitle = "Web searches → quicklinks, snippet collections → snippets",
            style = "prominent" }
    end
    alfred_rows[#alfred_rows + 1] = s.row{
        kind = "button", id = "alfred_zip", actionID = "alfred_zip",
        title = "Import snippet collection (.alfredsnippets)…",
        subtitle = "An exported Alfred snippet collection file" }
    local alfred = s.section{
        id = "alfred", title = "Alfred",
        footer = "Alfred stores everything unencrypted on disk, so no export step is "
            .. "needed — “Import from Alfred” reads your web searches and snippet "
            .. "collections directly. Collection keyword prefixes/suffixes are baked "
            .. "into the imported keywords.",
        rows = alfred_rows,
    }

    local last = host.prefs.get(REPORT_KEY)
    local status = s.section{
        id = "status", title = "Last import",
        footer = "Imports merge: existing quicklinks (same name) and snippets (same name "
            .. "or keyword) are kept and duplicates from the import are skipped, so "
            .. "re-running an import is always safe.",
        rows = {
            s.row{ kind = "info", title = "Result",
                   subtitle = (last and #last > 0) and last or "Nothing imported yet." },
        },
    }

    return s.render(s.ui{
        title = "Migration Assistant",
        subtitle = "Import quicklinks & snippets from Raycast or Alfred",
        sections = { raycast, alfred, status },
    })
end

function settings_action(section_id, action, value, form_json)
    if action == "raycast_json" then
        local path = choose_file("Choose a Raycast JSON export")
        if path then import_raycast_json(path) end
    elseif action == "raycast_backup" then
        local path = choose_file("Choose your Raycast .rayconfig backup")
        if path then
            local password = ask_password("Raycast Export Password")
            if password then import_rayconfig(path, password) end
        end
    elseif action == "alfred_auto" then
        import_alfred()
    elseif action == "alfred_zip" then
        local path = choose_file("Choose an .alfredsnippets file")
        if path then import_alfredsnippets(path) end
    end
    return settings_render(section_id, "{}")
end
