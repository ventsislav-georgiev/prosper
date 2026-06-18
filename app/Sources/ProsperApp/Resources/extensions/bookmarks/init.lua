-- Browser Bookmarks: import bookmarks from installed browsers and search/open
-- them from the palette.
--
-- Verbs (sub-parsed from a single `bm` command):
--   bm <query>   search the imported bookmarks (Enter opens the URL)
--   bm import    (re)scan every installed browser and refresh the cache
--   bm browsers  show how many bookmarks were imported per browser
--   bm help      usage
--
-- Sources, all read through host.shell (system-extension capability) + host.json:
--   Chromium family (Chrome/Brave/Edge/Vivaldi/Opera) — JSON `Bookmarks` file
--   Arc                                                — StorableSidebar.json
--   Safari   — Bookmarks.plist via `plutil -convert json` (needs Full Disk Access)
--   Firefox  — places.sqlite via `sqlite3 -readonly -json` (immutable, lock-free)
--
-- The heavy parse runs once at import; the flattened result is cached in
-- host.prefs so per-keystroke search never re-shells. Opening a result goes
-- through the host's native URL-open path (each row carries `url`), which also
-- gives it the same favicon engine Quicklinks uses. See BROWSER_BOOKMARKS_PLAN.md.

local STORE_KEY = "cache"
local STAMP_KEY = "imported_at"
local MAX_BOOKMARKS = 5000        -- cap so a giant library can't blow the VM budget
local MAX_RESULTS   = 50          -- default rows per search (overridable in settings)
local USAGE = "bm <query> · bm import · bm browsers · bm help"

-- Declarative settings (see extension.toml `settings_sections`), read straight
-- from host.prefs. A source is on unless explicitly toggled off ("false"); an
-- unset/blank pref keeps the manifest default (enabled).
local function source_on(name)
    return host.prefs.get("source." .. name) ~= "false"
end

-- Max rows per search; clamps a bad/blank pref back to the default.
local function max_results()
    local n = tonumber(host.prefs.get("max_results"))
    if type(n) ~= "number" or n < 1 then return MAX_RESULTS end
    return math.floor(n)
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Single-quote escape for a shell argument (identical to quicklinks' `shq`).
local function shq(s)
    return "'" .. (s:gsub("'", function() return "'\\''" end)) .. "'"
end

local function sh(cmd)
    local out = host.shell.run(cmd)
    if out == nil then return "" end
    return out
end

-- Absolute home directory, resolved once via the login shell. Paths are built
-- absolute (not `~`) because `shq` single-quotes them and the shell does NOT
-- expand `~` inside single quotes.
local HOME
local function home()
    if HOME == nil then HOME = trim(sh('printf %s "$HOME"')) end
    return HOME
end

-- Absolute path under the user's home for a Library-relative subpath.
local function p(rel) return home() .. "/" .. rel end

-- Read a file's contents via the shell (the sandbox has no direct fs read).
-- Returns nil when the file is missing / empty / unreadable.
local function read_file(path)
    local out = sh("cat " .. shq(path) .. " 2>/dev/null")
    if out == nil or #out == 0 then return nil end
    return out
end

local function decode(str)
    if type(str) ~= "string" or #str == 0 then return nil end
    local t = host.json.decode(str)
    if type(t) ~= "table" then return nil end
    return t
end

local function list_dirs(path)
    local d = host.fs.list_dirs(path)
    if type(d) ~= "table" then return {} end
    return d
end

-- Append a bookmark to the accumulator (capped, URL required, title defaulted).
local function add(acc, title, url, browser, folder)
    if #acc >= MAX_BOOKMARKS then return end
    if type(url) ~= "string" or #url == 0 then return end
    title = (type(title) == "string" and #title > 0) and title or url
    acc[#acc + 1] = { title = title, url = url, browser = browser, folder = folder or "" }
end

local function join_folder(folder, name)
    if type(name) ~= "string" or #name == 0 then return folder end
    if folder ~= "" then return folder .. "/" .. name end
    return name
end

-- MARK: Chromium family (Chrome/Brave/Edge/Vivaldi/Opera) — JSON `Bookmarks`.

local function walk_chromium(node, acc, browser, folder)
    if type(node) ~= "table" then return end
    if node.type == "url" then
        add(acc, node.name, node.url, browser, folder)
    elseif node.type == "folder" and type(node.children) == "table" then
        local sub = join_folder(folder, node.name)
        for _, child in ipairs(node.children) do
            walk_chromium(child, acc, browser, sub)
        end
    end
end

-- `single` browsers (Opera) keep the `Bookmarks` file directly under `support`;
-- the rest store one per profile dir (Default / Profile N).
local function parse_chromium(support, browser, single, acc)
    local count0 = #acc
    local profiles
    if single then
        profiles = { "" }
    else
        profiles = {}
        for _, name in ipairs(list_dirs(support)) do
            if name == "Default" or name:match("^Profile %d+$") then
                profiles[#profiles + 1] = name
            end
        end
    end
    for _, prof in ipairs(profiles) do
        local path = (prof ~= "") and (support .. "/" .. prof .. "/Bookmarks")
                                  or (support .. "/Bookmarks")
        local data = decode(read_file(path))
        if data and type(data.roots) == "table" then
            for _, key in ipairs({ "bookmark_bar", "other", "synced" }) do
                walk_chromium(data.roots[key], acc, browser, "")
            end
        end
    end
    return #acc - count0
end

-- MARK: Safari — Bookmarks.plist (binary plist → JSON via plutil). TCC-gated.

local function walk_safari(node, acc, folder)
    if type(node) ~= "table" then return end
    local t = node.WebBookmarkType
    if t == "WebBookmarkTypeLeaf" then
        local title = type(node.URIDictionary) == "table" and node.URIDictionary.title or nil
        add(acc, title, node.URLString, "Safari", folder)
    elseif type(node.Children) == "table" then
        -- A titled list nests under its own folder; the untyped root proxy keeps
        -- the current folder.
        local sub = (t == "WebBookmarkTypeList") and join_folder(folder, node.Title) or folder
        for _, child in ipairs(node.Children) do walk_safari(child, acc, sub) end
    end
end

-- Returns the number imported, or nil when blocked by a missing Full Disk Access
-- grant (so the caller can tell the user how to enable it).
local function parse_safari(acc)
    if not host.perms.has("full-disk-access") then return nil end
    local data = decode(sh("plutil -convert json -o - "
        .. shq(p("Library/Safari/Bookmarks.plist")) .. " 2>/dev/null"))
    if not data then return 0 end
    local count0 = #acc
    walk_safari(data, acc, "")
    return #acc - count0
end

-- MARK: Firefox — places.sqlite via sqlite3. `immutable=1` reads it lock-free
-- even while Firefox is running; spaces in the path are percent-encoded for the
-- file: URI (which `shq` then single-quotes for the shell).

local function file_uri(abs_path)
    -- Percent-encode the two chars realistically present in these paths. Function
    -- replacements are used literally (no `%` expansion), so return "%20"/"%25".
    local enc = abs_path:gsub("[ %%]", function(c) return c == " " and "%20" or "%25" end)
    return "file:" .. enc .. "?immutable=1"
end

local function parse_firefox(acc)
    local count0 = #acc
    local profiles_root = p("Library/Application Support/Firefox/Profiles")
    local sql = "SELECT b.title AS title, p.url AS url FROM moz_bookmarks b "
        .. "JOIN moz_places p ON b.fk = p.id WHERE b.type = 1 AND p.url LIKE 'http%';"
    for _, prof in ipairs(list_dirs(profiles_root)) do
        local db = profiles_root .. "/" .. prof .. "/places.sqlite"
        local cmd = "sqlite3 -readonly -json " .. shq(file_uri(db)) .. " " .. shq(sql) .. " 2>/dev/null"
        local rows = decode(sh(cmd))
        if type(rows) == "table" then
            for _, r in ipairs(rows) do
                if type(r) == "table" then add(acc, r.title, r.url, "Firefox", prof) end
            end
        end
    end
    return #acc - count0
end

-- MARK: Arc — StorableSidebar.json. The schema is a flat `items` list addressed
-- by id, plus `spaces` that reference root container ids. We resolve container
-- ids to items and recurse `childrenIds`, then flat-scan for any tab the space
-- walk missed (the format is version-volatile, so we stay defensive).

local function arc_container(data)
    local sb = data.sidebar
    if type(sb) ~= "table" or type(sb.containers) ~= "table" then return nil end
    for _, c in ipairs(sb.containers) do
        if type(c) == "table" and type(c.items) == "table" and type(c.spaces) == "table" then
            return c
        end
    end
    return nil
end

local function arc_emit_tab(acc, it, folder)
    local d = it.data
    if type(d) == "table" and type(d.tab) == "table" and type(d.tab.savedURL) == "string" then
        add(acc, d.tab.savedTitle or it.title, d.tab.savedURL, "Arc", folder)
        return true
    end
    return false
end

-- containerIDs / newContainerIDs alternate id strings with section objects; pull
-- every string id out of either shape.
local function arc_collect_ids(list, out)
    if type(list) ~= "table" then return end
    for _, e in ipairs(list) do
        if type(e) == "string" then
            out[#out + 1] = e
        elseif type(e) == "table" then
            for _, v in pairs(e) do if type(v) == "string" then out[#out + 1] = v end end
        end
    end
end

local function parse_arc(acc)
    local data = decode(read_file(p("Library/Application Support/Arc/StorableSidebar.json")))
    if not data then return 0 end
    local cont = arc_container(data)
    if not cont then return 0 end

    local byId = {}
    for _, it in ipairs(cont.items) do
        if type(it) == "table" and type(it.id) == "string" then byId[it.id] = it end
    end

    local count0 = #acc
    local visited = {}
    local function walk(id, folder)
        local it = byId[id]
        if type(it) ~= "table" or visited[id] then return end
        visited[id] = true
        if not arc_emit_tab(acc, it, folder) and type(it.childrenIds) == "table" then
            local sub = join_folder(folder, it.title)
            for _, cid in ipairs(it.childrenIds) do walk(cid, sub) end
        end
    end

    for _, sp in ipairs(cont.spaces) do
        if type(sp) == "table" then
            local ids = {}
            arc_collect_ids(sp.containerIDs, ids)
            arc_collect_ids(sp.newContainerIDs, ids)
            local space_name = (type(sp.title) == "string") and sp.title or ""
            for _, id in ipairs(ids) do walk(id, space_name) end
        end
    end

    -- Defensive sweep: capture any tab the space walk never reached.
    for id, it in pairs(byId) do
        if not visited[id] then arc_emit_tab(acc, it, "") end
    end
    return #acc - count0
end

-- MARK: Import / cache

local function do_import()
    local acc, blocked = {}, {}
    if source_on("chrome") then
        parse_chromium(p("Library/Application Support/Google/Chrome"),               "Chrome",  false, acc)
    end
    if source_on("brave") then
        parse_chromium(p("Library/Application Support/BraveSoftware/Brave-Browser"), "Brave",   false, acc)
    end
    if source_on("edge") then
        parse_chromium(p("Library/Application Support/Microsoft Edge"),              "Edge",    false, acc)
    end
    if source_on("vivaldi") then
        parse_chromium(p("Library/Application Support/Vivaldi"),                     "Vivaldi", false, acc)
    end
    if source_on("opera") then
        parse_chromium(p("Library/Application Support/com.operasoftware.Opera"),     "Opera",   true,  acc)
    end
    if source_on("arc") then parse_arc(acc) end
    if source_on("firefox") then parse_firefox(acc) end
    if source_on("safari") then
        if parse_safari(acc) == nil then blocked[#blocked + 1] = "Safari (needs Full Disk Access)" end
    end
    host.prefs.set(STORE_KEY, host.json.encode(acc))
    host.prefs.set(STAMP_KEY, tostring(math.floor(host.time())))
    return acc, blocked
end

-- Decoded-cache memo. The async VM is reused across keystrokes, so we decode the
-- stored JSON only when it actually changes (i.e. after an import), keeping
-- per-keystroke search allocation-free. Decode itself is native (host.json.decode).
local _cache_raw, _cache_val
local function load_cache()
    local raw = host.prefs.get(STORE_KEY)
    if raw == _cache_raw and _cache_val ~= nil then return _cache_val end
    local t = raw and host.json.decode(raw) or nil
    if type(t) ~= "table" then t = {} end
    _cache_raw, _cache_val = raw, t
    return t
end

local function counts_by_browser(cache)
    local counts, names = {}, {}
    for _, b in ipairs(cache) do
        local k = b.browser or "?"
        if counts[k] == nil then names[#names + 1] = k end
        counts[k] = (counts[k] or 0) + 1
    end
    table.sort(names)
    return counts, names
end

-- MARK: Search

local function matches(item, terms)
    local hay = ((item.title or "") .. " " .. (item.url or "") .. " " .. (item.folder or "")):lower()
    for _, t in ipairs(terms) do
        if not hay:find(t, 1, true) then return false end
    end
    return true
end

local function empty_list(message)
    return host.ui.render(host.ui.list{
        title = "Browser Bookmarks", style = "rows",
        items = {{ id = "0", title = message,
                   subtitle = "Run  bm import  to (re)scan your browsers.", icon = "bookmark" }},
    })
end

local function do_search(query)
    local cache = load_cache()
    -- Auto-import once, on first ever use (no prior import stamp). A genuinely
    -- empty result after an import must NOT re-shell on every keystroke; the user
    -- refreshes explicitly with `bm import`.
    if #cache == 0 and host.prefs.get(STAMP_KEY) == nil then
        cache = (do_import())
    end

    local terms = {}
    for w in query:lower():gmatch("%S+") do terms[#terms + 1] = w end

    local limit = max_results()
    local items = {}
    for _, b in ipairs(cache) do
        if #terms == 0 or matches(b, terms) then
            local folder = (b.folder and #b.folder > 0) and (" · " .. b.folder) or ""
            items[#items + 1] = {
                id       = tostring(#items),
                title    = b.title or b.url,
                subtitle = (b.browser or "") .. folder,
                icon     = "bookmark",
                url      = b.url,          -- host opens this natively + shows its favicon
            }
            if #items >= limit then break end
        end
    end

    if #items == 0 then
        return empty_list(#cache == 0 and "No bookmarks imported"
                                       or ("No bookmarks match \"" .. trim(query) .. "\""))
    end
    return host.ui.render(host.ui.list{ title = "Browser Bookmarks", style = "rows", items = items })
end

-- MARK: Command handler

function bookmarks_run(query)
    query = trim(query or "")
    local rest = trim((query:gsub("^[Bb][Mm]", "", 1)))
    local verb = rest:match("^(%S+)")
    local lv = verb and verb:lower() or ""

    if lv == "import" or lv == "reload" or lv == "refresh" then
        local acc, blocked = do_import()
        local counts, names = counts_by_browser(acc)
        local parts = {}
        for _, k in ipairs(names) do parts[#parts + 1] = k .. " " .. counts[k] end
        local summary = (#parts == 0) and "No bookmarks found."
            or ("Imported " .. #acc .. " bookmarks (" .. table.concat(parts, ", ") .. ").")
        if #blocked > 0 then summary = summary .. "  Skipped: " .. table.concat(blocked, ", ") .. "." end
        return summary

    elseif lv == "browsers" then
        local cache = load_cache()
        if #cache == 0 then return "No bookmarks imported yet. Run  bm import." end
        local counts, names = counts_by_browser(cache)
        local lines = {}
        for _, k in ipairs(names) do lines[#lines + 1] = k .. " — " .. counts[k] .. " bookmarks" end
        return table.concat(lines, "\n")

    elseif lv == "help" then
        return USAGE
    end

    -- Otherwise the whole remainder is the search query (empty => list all).
    return do_search(rest)
end

-- MARK: Settings (Tier B) — rendered dynamically so each enabled browser's
-- toggle can show a live count badge of the bookmarks found at the last scan.

-- Pref key ↔ display name (the `browser` field cached rows carry, hence the
-- key in counts_by_browser).
local SOURCES = {
    { key = "chrome",  name = "Chrome"  },
    { key = "brave",   name = "Brave"   },
    { key = "edge",    name = "Edge"    },
    { key = "vivaldi", name = "Vivaldi" },
    { key = "opera",   name = "Opera"   },
    { key = "arc",     name = "Arc"     },
    { key = "firefox", name = "Firefox" },
    { key = "safari",  name = "Safari"  },
}

function settings_render(section_id, state)
    local s = host.ui.settings
    local counts = counts_by_browser(load_cache())
    local total = 0
    for _, n in pairs(counts) do total = total + n end

    local source_rows = {}
    for _, src in ipairs(SOURCES) do
        local n = counts[src.name]
        source_rows[#source_rows + 1] = s.row{
            kind = "toggle", key = "source." .. src.key, title = src.name,
            value = source_on(src.key) and "true" or "false",
            -- Badge only when this browser was actually detected at the last scan.
            badge = (n and n > 0) and tostring(n) or nil,
        }
    end

    local sections = {}
    -- Full Disk Access matters only when Safari is in the mix.
    if source_on("safari") then
        sections[#sections + 1] = s.section{
            id = "perm", title = "Permission",
            rows = { s.row{ kind = "permission", name = "full-disk-access",
                title = "Full Disk Access",
                subtitle = "Required only for the Safari source; other browsers import without it." } },
        }
    end
    sections[#sections + 1] = s.section{
        id = "sources", title = "Sources",
        footer = "Disable a browser to skip it on import. The badge is the count detected at the last scan.",
        rows = source_rows,
    }
    sections[#sections + 1] = s.section{
        id = "search", title = "Search",
        rows = { s.row{ kind = "number", key = "max_results", title = "Max results",
                        value = tostring(max_results()), min = 1, max = 500, step = 1 } },
    }
    sections[#sections + 1] = s.section{
        id = "scan", title = "Scan",
        rows = { s.row{ kind = "button", id = "rescan", actionID = "rescan",
                        title = "Re-scan all browsers",
                        subtitle = (total > 0) and (total .. " bookmarks cached")
                                                or "No bookmarks scanned yet" } },
    }
    return s.render(s.ui{
        title = "Browser Bookmarks",
        subtitle = "Import and search browser bookmarks",
        sections = sections,
    })
end

function settings_action(section_id, action, value, form_json)
    local key = action:match("^set:(.+)$")
    if key then
        host.prefs.set(key, value or "")
        return settings_render(section_id, "{}")
    end
    if action == "rescan" then
        do_import()   -- repopulates the cache so the badges reflect the new scan
        return settings_render(section_id, "{}")
    end
    return settings_render(section_id, "{}")
end
