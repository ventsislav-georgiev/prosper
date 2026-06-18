-- Quicklinks: save URLs / file paths / deeplinks and open them from the palette
-- with `{query}` / `{argument}` substitution. Raycast-parity feature.
--
-- Verbs (sub-parsed from a single `ql` command):
--   ql <name> [args]        open the saved link, substituting {query}/{argument}
--   ql add <name> <target>  save (target = https://…/{query}, /path, app://…)
--   ql rm <name>            delete
--   ql list                 show all saved links
--   ql help                 usage
--
-- Storage is a JSON name→target map in host.prefs. Opening shells out to
-- `open`, so this runs on the off-main async lane (host.shell is async).

local STORE_KEY = "links"
local USAGE = "ql <name> [args] · ql add <name> <target> · ql rm <name> · ql list"

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function load_links()
    local raw = host.prefs.get(STORE_KEY)
    if not raw or #raw == 0 then return {} end
    local t = host.json.decode(raw)
    if type(t) ~= "table" then return {} end
    return t
end

local function save_links(t)
    host.prefs.set(STORE_KEY, host.json.encode(t))
end

-- Percent-encode an argument for safe substitution into a URL target.
-- `/` stays literal: RFC 3986 allows it in both path and query, and
-- path-style targets (github.com/{query} ← "owner/repo") break as %2F.
local function urlencode(s)
    return (s:gsub("[^%w%-%._~/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Single-quote escape for the shell `open` argument.
local function shq(s)
    return "'" .. (s:gsub("'", function() return "'\\''" end)) .. "'"
end

local function is_url(target) return target:find("://") ~= nil end

-- Replace {query}/{argument} (any case) with the user-supplied args, percent-
-- encoding when the target is a URL. Function replacements avoid Lua's `%`
-- expansion in string replacements (encoded args contain `%`).
local function substitute(target, args)
    args = args or ""
    local enc = is_url(target) and urlencode(args) or args
    local out = target:gsub("{%s*[Qq]uery%s*}", function() return enc end)
    out = out:gsub("{%s*[Aa]rgument%s*}", function() return enc end)
    return out
end

local function sorted_names(links)
    local names = {}
    for k in pairs(links) do names[#names + 1] = k end
    table.sort(names)
    return names
end

-- Build the "Add Quicklink" form node (reused by the opener and the
-- validation re-render path so typed values survive a failed submit).
local function ql_form(name, target, description, err)
    return host.ui.form{
        title = err and ("Add Quicklink — " .. err) or "Add Quicklink",
        fields = {
            { id = "name", label = "Name", kind = "text",
              value = name or "", placeholder = "github" },
            { id = "target", label = "Link", kind = "text",
              value = target or "", placeholder = "https://github.com/{query}" },
            { id = "description", label = "Description (optional)", kind = "text",
              value = description or "", placeholder = "GitHub repo search" },
        },
        actions = {
            { id = "ql_save", title = "Save", icon = "checkmark.circle.fill" },
        },
    }
end

-- `ql add [name]` launcher: open the dialog, pre-filling name from trailing text.
function quicklinks_add(query)
    local rest = trim((trim(query or ""):gsub("^[Qq][Ll]%s+[Aa][Dd][Dd]", "", 1)))
    local name = rest:match("^(%S+)") or ""
    host.window.open(ql_form(name, "", ""))
    return ""
end

-- Submit handler: persist + close, or re-render the form with an error.
-- The optional description lives in a parallel `descriptions` name→text map
-- (same store the native Settings pane / QuicklinkStore uses), so the Lua
-- target decoder stays a plain name→target map.
function ql_save(_, form_json)
    local form = host.json.decode(form_json or "") or {}
    local name = trim(form.name or "")
    local target = trim(form.target or "")
    local description = trim(form.description or "")
    if #name == 0 or #target == 0 then
        return host.ui.render(ql_form(name, target, description, "name & link required"))
    end
    local links = load_links()
    links[name] = target
    save_links(links)
    local raw_descs = host.prefs.get("descriptions")
    local descs = (raw_descs and #raw_descs > 0) and host.json.decode(raw_descs) or {}
    if type(descs) ~= "table" then descs = {} end
    if #description > 0 then descs[name] = description else descs[name] = nil end
    -- An empty Lua table encodes as a JSON array; pin the object form so the
    -- native [String: String] decoder never chokes.
    host.prefs.set("descriptions",
                   next(descs) == nil and "{}" or host.json.encode(descs))
    host.notify("Quicklink saved", name .. " → " .. target)
    host.window.close()
    return nil
end

function quicklinks_run(query)
    query = trim(query or "")
    local rest = trim((query:gsub("^[Qq][Ll]", "", 1)))
    if #rest == 0 then return USAGE end

    local verb, tail = rest:match("^(%S+)%s*(.*)$")
    tail = trim(tail or "")
    local lv = verb:lower()

    if lv == "add" then
        local name, target = tail:match("^(%S+)%s+(.+)$")
        if not name then return "Usage: ql add <name> <url-or-path>" end
        target = trim(target)
        local links = load_links()
        links[name] = target
        save_links(links)
        return "Saved '" .. name .. "' → " .. target

    elseif lv == "rm" or lv == "remove" or lv == "del" or lv == "delete" then
        local name = tail:match("^(%S+)")
        if not name then return "Usage: ql rm <name>" end
        local links = load_links()
        if links[name] == nil then return "No quicklink: " .. name end
        links[name] = nil
        save_links(links)
        return "Removed '" .. name .. "'"

    elseif lv == "list" or lv == "ls" then
        local links = load_links()
        local names = sorted_names(links)
        if #names == 0 then return "No quicklinks yet. Add one: ql add <name> <target>" end
        local lines = {}
        for _, n in ipairs(names) do lines[#lines + 1] = n .. " → " .. links[n] end
        return table.concat(lines, "\n")

    elseif lv == "help" then
        return USAGE
    end

    -- Otherwise `verb` is a quicklink name and `tail` are its arguments.
    local links = load_links()
    local target = links[verb]
    if not target then
        return "No quicklink '" .. verb .. "'. Add it: ql add " .. verb .. " <target>"
    end
    local final = substitute(target, tail)
    host.shell.run("open " .. shq(final))
    return "Opening " .. verb .. "\t" .. final
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Settings (Tier B): an editable QuickLinks list in its own sidebar section.
-- Backed by the same `links`/`descriptions` host.prefs store the runner reads, so
-- edits apply instantly. The on-disk quicklinks.json reconciles at launch (same as
-- `ql add`). Replaces the native QuicklinksPane — 1:1 via the `records` control.

local function load_descs()
    local raw = host.prefs.get("descriptions")
    if not raw or #raw == 0 then return {} end
    local t = host.json.decode(raw)
    if type(t) ~= "table" then return {} end
    return t
end

local function save_descs(t)
    -- An empty Lua table encodes as a JSON array; pin the object form so the
    -- native [String: String] decoder never chokes.
    host.prefs.set("descriptions", next(t) == nil and "{}" or host.json.encode(t))
end

-- Field schema for one quicklink (reused for existing rows, with values, and as
-- the blank template the Add button opens).
local function ql_fields(name, target, description)
    return {
        { id = "name", label = "Name", kind = "text",
          value = name, placeholder = "gh" },
        { id = "target", label = "Link", kind = "text",
          value = target, placeholder = "https://github.com/{query}" },
        { id = "description", label = "Description (optional)", kind = "text",
          value = description, placeholder = "" },
    }
end

function settings_render(section_id, state)
    local links = load_links()
    local descs = load_descs()
    local recs = {}
    for _, n in ipairs(sorted_names(links)) do
        recs[#recs + 1] = {
            id = n, title = n, subtitle = links[n], icon = "link",
            fields = ql_fields(n, links[n], descs[n] or ""),
        }
    end
    return host.ui.settings.render(host.ui.settings.ui{
        title = "QuickLinks",
        subtitle = "Save URLs, file paths and deeplinks; open them with ql <name>",
        sections = {
            host.ui.settings.section{
                id = "quicklinks", title = "QuickLinks", accent = "Links",
                footer = "Open later by typing ql <name> (or just the name) in the runner. "
                    .. "Put {query} in the link to substitute trailing text — "
                    .. "e.g. https://github.com/{query}. A target can also be a /path or an app://deeplink.",
                rows = {
                    host.ui.settings.records{
                        id = "links",
                        records = recs,
                        fields = ql_fields("", "", ""),
                        addLabel = "Add Quicklink",
                        revealFile = "~/.config/prosper/quicklinks.json",
                        revealLabel = "Reveal quicklinks.json",
                        emptyText = "No quicklinks yet. Add one below, e.g. name “gh”, "
                            .. "link “https://github.com/{query}”.",
                    },
                },
            },
        },
    })
end

function settings_action(section_id, action, value, form_json)
    local form = host.json.decode(form_json or "") or {}

    local del = action:match("^record%.delete:links:(.*)$")
    if del then
        local links = load_links()
        local descs = load_descs()
        links[del] = nil
        descs[del] = nil
        save_links(links)
        save_descs(descs)
        return settings_render(section_id, "{}")
    end

    -- `record.save:links:<oldName>` — empty <oldName> means a brand-new record.
    local old = action:match("^record%.save:links:(.*)$")
    if old then
        local name = trim(form.name or "")
        local target = trim(form.target or "")
        local description = trim(form.description or "")
        if #name > 0 and #target > 0 then
            local links = load_links()
            local descs = load_descs()
            -- Rename: a different key replaces the old one (no orphan left behind).
            if #old > 0 and old ~= name then
                links[old] = nil
                descs[old] = nil
            end
            links[name] = target
            if #description > 0 then descs[name] = description else descs[name] = nil end
            save_links(links)
            save_descs(descs)
        end
        return settings_render(section_id, "{}")
    end

    return settings_render(section_id, "{}")
end
