-- Snippets: insert saved text snippets (with dynamic placeholders) from the
-- palette, and manage them. The store + placeholder resolution live natively
-- (host.snippets.*); this extension is the hackable management/browse surface.
--
-- Verbs (sub-parsed from a single `sn` command):
--   sn <query>        browse matching snippets; Enter pastes the resolved text
--   sn add [name]     open the Add Snippet dialog
--   sn rm <name>      delete
--   sn list           show all saved snippets
--   sn help           usage
--
-- Inline keyword auto-expansion (typing a keyword anywhere) is handled natively
-- and independently of this extension.

local USAGE = "sn <query> · sn add · sn rm <name> · sn list"

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function contains_ci(hay, needle)
    if not hay then return false end
    return hay:lower():find(needle:lower(), 1, true) ~= nil
end

-- Build the "Add Snippet" form node (reused by the opener and the validation
-- re-render path so typed values survive a failed submit). The body is a
-- multi-line `textarea`; rich (RTF) authoring lives in Settings → Snippets.
local function add_form(name, keyword, collection, text, err)
    return host.ui.form{
        title = err and ("Add Snippet — " .. err) or "Add Snippet",
        fields = {
            { id = "name", label = "Name", kind = "text",
              value = name or "", placeholder = "My address" },
            { id = "keyword", label = "Keyword", kind = "text",
              value = keyword or "", placeholder = ";;addr" },
            { id = "collection", label = "Collection (optional)", kind = "text",
              value = collection or "" },
            { id = "text", label = "Snippet", kind = "textarea",
              value = text or "", placeholder = "1 Infinite Loop, Cupertino{cursor}" },
        },
        actions = {
            { id = "sn_save", title = "Save", icon = "checkmark.circle.fill" },
        },
    }
end

-- `sn add [name]` launcher: open the dialog, pre-filling name from trailing text.
function snippets_add(query)
    local rest = trim((trim(query or ""):gsub("^[Ss][Nn]%s+[Aa][Dd][Dd]", "", 1)))
    local name = rest:match("^(%S+)") or ""
    host.window.open(add_form(name, "", "", ""))
    return ""
end

-- Submit handler: persist + close, or re-render the form with an error.
function sn_save(_, form_json)
    local form = host.json.decode(form_json or "") or {}
    local name = trim(form.name or "")
    local text = form.text or ""
    if #name == 0 or #text == 0 then
        return host.ui.render(add_form(name, form.keyword, form.collection, text,
                                       "name & snippet required"))
    end
    host.snippets.save{
        name = name,
        keyword = trim(form.keyword or ""),
        collection = trim(form.collection or ""),
        text = text,
    }
    host.notify("Snippet saved", name)
    host.window.close()
    return nil
end

function snippets_run(query)
    query = trim(query or "")
    local rest = trim((query:gsub("^[Ss][Nn]", "", 1)))

    -- Management verbs (only when the first word is a recognized verb).
    local verb, tail = rest:match("^(%S+)%s*(.*)$")
    if verb then
        local lv = verb:lower()
        tail = trim(tail or "")
        if lv == "rm" or lv == "remove" or lv == "del" or lv == "delete" then
            if #tail == 0 then return "Usage: sn rm <name>" end
            host.snippets.remove(tail)
            return "Removed '" .. tail .. "'"
        elseif lv == "list" or lv == "ls" then
            local all = host.snippets.all()
            if #all == 0 then return "No snippets yet. Add one: sn add" end
            local lines = {}
            for _, s in ipairs(all) do
                local kw = (s.keyword and #s.keyword > 0) and ("  [" .. s.keyword .. "]") or ""
                lines[#lines + 1] = s.name .. kw
            end
            return table.concat(lines, "\n")
        elseif lv == "help" then
            return USAGE
        end
    end

    -- Otherwise browse/insert. Each item's title is the RESOLVED snippet body
    -- (placeholders applied), which is what the runner pastes on Enter; the name
    -- and keyword ride along in the subtitle.
    local all = host.snippets.all()
    local items = {}
    for _, s in ipairs(all) do
        if #rest == 0 or contains_ci(s.name, rest) or contains_ci(s.keyword, rest)
            or contains_ci(s.description, rest) then
            local resolved = host.snippets.expand(s.name)
            if resolved == nil or #resolved == 0 then resolved = s.text end
            local kw = (s.keyword and #s.keyword > 0) and ("  ·  " .. s.keyword) or ""
            items[#items + 1] = {
                id = tostring(#items),
                title = resolved,
                subtitle = s.name .. kw,
                icon = "text.append",
            }
        end
    end
    if #items == 0 then
        if #all == 0 then return "No snippets yet. Add one: sn add" end
        return "No snippet matches '" .. rest .. "'"
    end
    return host.ui.render(host.ui.list{ title = "Snippets", items = items })
end

-- MARK: Settings (Tier B) — the whole management page, rendered dynamically.
-- Replaces the former hardcoded Swift SnippetsPane. Snippet + collection edits
-- go through the native store (host.snippets.*) so the file mirror and inline
-- expander stay in sync; the four toggles + ignored apps are global prefs.

local SNIPPETS_JSON = "~/.config/prosper/snippets.json"

local function b2s(v) return v and "true" or "false" end

-- Field schema for one snippet record (shared by the rows and the "add" template).
local function snip_fields(name, keyword, collection, auto, rich, text)
    return {
        { id = "name", label = "Name", kind = "text", value = name, placeholder = "My address" },
        { id = "keyword", label = "Keyword", kind = "text", value = keyword, placeholder = ";;addr" },
        { id = "collection", label = "Collection", kind = "text", value = collection },
        { id = "autoExpand", label = "Include in system-wide auto-expand", kind = "toggle", value = b2s(auto) },
        { id = "richText", label = "Rich text (RTF)", kind = "toggle", value = b2s(rich) },
        -- RTF editor when richText is on, multi-line plain otherwise (toggleKey).
        { id = "text", label = "Snippet", kind = "richtext", toggleKey = "richText",
          value = text, placeholder = "1 Infinite Loop, Cupertino{cursor}" },
    }
end

local function col_fields(name, prefix, suffix)
    return {
        { id = "name", label = "Name", kind = "text", value = name },
        { id = "prefix", label = "Prefix", kind = "text", value = prefix, placeholder = ";;" },
        { id = "suffix", label = "Suffix", kind = "text", value = suffix },
    }
end

function settings_render(section_id, state)
    local s = host.ui.settings
    local cfg = host.snippets.config()

    local expansion = s.section{
        id = "expansion", title = "Expansion",
        footer = "Auto-expansion types the snippet in place when you type its keyword in any app. "
            .. "Keywords can't contain spaces or quotes. Use a symbol prefix (e.g. ;;addr) so everyday "
            .. "words don't trigger. Placeholders: {cursor} {clipboard} {date} {date +1d} {time} {uuid} "
            .. "{snippet:keyword} {argument} — with modifiers like {clipboard | uppercase}.",
        rows = {
            s.row{ kind = "toggle", key = "enabled", title = "Enable Snippets",
                   value = b2s(cfg.enabled) },
            s.row{ kind = "toggle", key = "autoExpand",
                   title = "Auto-expand snippets by keyword (system-wide)", value = b2s(cfg.autoExpand) },
            s.row{ kind = "toggle", key = "wordBoundary",
                   title = "Only expand after a word boundary (space/punctuation)",
                   value = b2s(cfg.wordBoundary) },
            s.row{ kind = "toggle", key = "restoreClipboard",
                   title = "Restore the clipboard after a paste-based expansion",
                   value = b2s(cfg.restoreClipboard) },
        },
    }

    local recs = {}
    for _, sn in ipairs(host.snippets.all()) do
        local kw = (sn.keyword and #sn.keyword > 0) and (sn.keyword .. "  ·  ") or ""
        local preview = sn.richText and "(rich text)" or ((sn.text or ""):gsub("[\r\n]+", " "))
        recs[#recs + 1] = {
            id = sn.name, title = sn.name, subtitle = kw .. preview, icon = "text.append",
            fields = snip_fields(sn.name, sn.keyword or "", sn.collection or "",
                                 sn.autoExpand ~= false, sn.richText == true, sn.text or ""),
        }
    end
    local library = s.section{
        id = "library", title = "Library",
        footer = "Each snippet has a name, an optional keyword (the auto-expansion trigger) and a body. "
            .. "Turn on “Rich text” to author a formatted RTF body.",
        rows = {
            s.records{
                id = "lib", records = recs, fields = snip_fields("", "", "", true, false, ""),
                addLabel = "Add Snippet",
                revealFile = SNIPPETS_JSON, revealLabel = "Reveal snippets.json",
                emptyText = "No snippets yet. Add one below.",
            },
            s.row{ kind = "button", id = "import", actionID = "import",
                   title = "Import JSON", subtitle = "Merge snippets from a JSON file" },
        },
    }

    local col_recs = {}
    for _, c in ipairs(host.snippets.collections()) do
        local affix = (c.prefix or "") .. "…" .. (c.suffix or "")
        col_recs[#col_recs + 1] = {
            id = c.name, title = c.name, subtitle = affix, icon = "folder",
            fields = col_fields(c.name, c.prefix or "", c.suffix or ""),
        }
    end
    local collections = s.section{
        id = "collections", title = "Collections",
        footer = "A collection adds a prefix and/or suffix to every member keyword "
            .. "(e.g. a “;;” prefix turns keyword “addr” into “;;addr”).",
        rows = { s.records{ id = "cols", records = col_recs, fields = col_fields("", "", ""),
                 addLabel = "Add Collection",
                 emptyText = "No collections. Snippets without a collection use their keyword as-is." } },
    }

    local ign_recs = {}
    for _, id in ipairs(host.snippets.ignored()) do
        ign_recs[#ign_recs + 1] = { id = id, title = id, icon = "nosign",
            fields = { { id = "id", label = "Bundle id", kind = "text", value = id,
                         placeholder = "com.example.app" } } }
    end
    local ignored = s.section{
        id = "ignored", title = "Ignored apps",
        footer = "Bundle ids where inline auto-expansion never fires (password managers, launchers, etc.).",
        rows = { s.records{ id = "ign", records = ign_recs,
                 fields = { { id = "id", label = "Bundle id", kind = "text", value = "",
                              placeholder = "com.example.app" } },
                 addLabel = "Add ignored app", emptyText = "None." } },
    }

    -- Inline auto-expansion rides the native active key tap (same as completions),
    -- which Accessibility authorizes for both watching keystrokes and typing the
    -- expansion in place. Shown here even if granted elsewhere, so a user whose
    -- snippets won't expand finds the fix in this extension's own settings.
    local permissions = s.section{
        id = "permissions", title = "Permissions",
        footer = "Auto-expansion watches your typing and types the snippet in place. "
            .. "If snippets don't expand, make sure Accessibility is enabled.",
        rows = {
            s.row{ kind = "permission", name = "accessibility",
                title = "Accessibility",
                subtitle = "Required to detect snippet keywords and type the expansion into the focused app." },
        },
    }

    return s.render(s.ui{
        title = "Snippets", subtitle = "Reusable text with dynamic placeholders",
        sections = { permissions, expansion, library, collections, ignored },
    })
end

function settings_action(section_id, action, value, form_json)
    local form = host.json.decode(form_json or "") or {}

    -- Expansion toggles → global prefs (only the changed key is sent).
    local cfgkey = action:match("^set:(.+)$")
    if cfgkey then
        host.snippets.set_config({ [cfgkey] = (value == "true") })
        return settings_render(section_id, "{}")
    end

    -- Library (snippets) — identity is the name.
    local del = action:match("^record%.delete:lib:(.*)$")
    if del then host.snippets.remove(del); return settings_render(section_id, "{}") end
    local old = action:match("^record%.save:lib:(.*)$")
    if old then
        local name = trim(form.name or "")
        local text = form.text or ""
        if #name > 0 and #text > 0 then
            if #old > 0 and old ~= name then host.snippets.remove(old) end
            host.snippets.save{
                name = name, keyword = trim(form.keyword or ""),
                collection = trim(form.collection or ""), text = text,
                autoExpand = (form.autoExpand == "true"),
                richText = (form.richText == "true"),
            }
        end
        return settings_render(section_id, "{}")
    end

    -- Collections — set_collections replaces the whole list.
    local cdel = action:match("^record%.delete:cols:(.*)$")
    if cdel then
        local kept = {}
        for _, c in ipairs(host.snippets.collections()) do
            if c.name ~= cdel then kept[#kept + 1] = c end
        end
        host.snippets.set_collections(kept)
        return settings_render(section_id, "{}")
    end
    local cold = action:match("^record%.save:cols:(.*)$")
    if cold then
        local name = trim(form.name or "")
        if #name > 0 then
            local kept = {}
            for _, c in ipairs(host.snippets.collections()) do
                if c.name ~= cold and c.name ~= name then kept[#kept + 1] = c end
            end
            kept[#kept + 1] = { name = name, prefix = trim(form.prefix or ""),
                                suffix = trim(form.suffix or "") }
            host.snippets.set_collections(kept)
        end
        return settings_render(section_id, "{}")
    end

    -- Ignored apps — set_ignored replaces the whole list.
    local idel = action:match("^record%.delete:ign:(.*)$")
    if idel then
        local kept = {}
        for _, x in ipairs(host.snippets.ignored()) do
            if x ~= idel then kept[#kept + 1] = x end
        end
        host.snippets.set_ignored(kept)
        return settings_render(section_id, "{}")
    end
    local iold = action:match("^record%.save:ign:(.*)$")
    if iold then
        local id = trim(form.id or "")
        if #id > 0 then
            local kept = {}
            for _, x in ipairs(host.snippets.ignored()) do
                if x ~= iold and x ~= id then kept[#kept + 1] = x end
            end
            kept[#kept + 1] = id
            host.snippets.set_ignored(kept)
        end
        return settings_render(section_id, "{}")
    end

    if action == "import" then
        host.snippets.import_file()
        return settings_render(section_id, "{}")
    end

    return settings_render(section_id, "{}")
end
