-- Fallback Search — settings UI + browser import for the runner's web-search
-- "default results" (Alfred/Raycast fallbacks). The query path is NATIVE: this
-- extension never runs per keystroke. It only edits the native FallbackSearchStore
-- through host.fallback.* (system-only), so what you configure here is exactly what
-- the runner shows.
--
--   host.fallback.list()             -> JSON array of providers
--   host.fallback.save(json)         -- replace the provider list
--   host.fallback.get_mode()         -> boolean (true = always append)
--   host.fallback.set_mode(on)       -- toggle append vs empty-only
--   host.fallback.import_browser()   -> integer (providers added)

local function load_providers()
    local raw = host.fallback.list()
    if not raw or #raw == 0 then return {} end
    local t = host.json.decode(raw)
    if type(t) ~= "table" then return {} end
    return t
end

local function save_providers(list)
    -- An empty Lua table encodes as `{}` (a JSON object), NOT `[]`, so force the array
    -- form when clearing — otherwise the native [FallbackProvider] decoder rejects it and
    -- the delete silently no-ops. (Native side also coerces `{}` → [], belt-and-suspenders.)
    host.fallback.save(#list == 0 and "[]" or host.json.encode(list))
end

-- Field schema for one provider (existing rows carry values; the blank template is
-- what the Add button opens).
local function provider_fields(name, url, enabled)
    return {
        { id = "name", label = "Name", kind = "text",
          value = name or "", placeholder = "Google" },
        { id = "urlTemplate", label = "Search URL", kind = "text",
          value = url or "", placeholder = "https://www.google.com/search?q={query}" },
        { id = "enabled", label = "Enabled", kind = "toggle",
          value = (enabled == false) and "false" or "true" },
    }
end

-- Stable slug for a provider id (lowercase, non-alphanumerics → "-"). Mirrors the
-- native importer so manually-added rows dedupe against imported ones.
local function slug(s)
    local out = (s or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    return out
end

function settings_render(section_id, state)
    local s = host.fallback
    local ui = host.ui.settings
    local providers = load_providers()
    local append = host.fallback.get_mode()

    local mode_section = ui.section{
        id = "mode", title = "Mode", accent = "Links",
        footer = "Append mode shows web searches at the END of every result list. "
            .. "Turn it off to show them only when a query has no local match.",
        rows = {
            ui.row{ kind = "toggle", key = "append_mode",
                    title = "Always append web searches",
                    subtitle = "Alfred-style \u{201C}smart append\u{201D} — fallbacks sit below real results",
                    value = append and "true" or "false" },
        },
    }

    local recs = {}
    for _, p in ipairs(providers) do
        recs[#recs + 1] = {
            id = p.id or slug(p.name), title = p.name or p.id,
            subtitle = p.urlTemplate, icon = "magnifyingglass",
            fields = provider_fields(p.name, p.urlTemplate, p.enabled),
        }
    end
    local providers_section = ui.section{
        id = "providers", title = "Search providers",
        footer = "Put {query} in the URL where the search term goes — e.g. "
            .. "https://www.google.com/search?q={query}. Rows open in your default browser.",
        rows = {
            ui.records{
                id = "providers", records = recs, fields = provider_fields("", "", true),
                addLabel = "Add provider",
                emptyText = "No providers yet — add one below, or import from your browser.",
            },
        },
    }

    local import_section = ui.section{
        id = "import", title = "Import",
        footer = "Pulls the search engines from your default browser (Chromium "
            .. "\u{201C}Web Data\u{201D} keywords, or Safari's default engine).",
        rows = {
            ui.row{ kind = "button", id = "import_browser", actionID = "import_browser",
                    title = "Import from default browser",
                    subtitle = "Add the search engines configured in your browser",
                    style = "prominent" },
        },
    }

    return ui.render(ui.ui{
        title = "Fallback Search",
        subtitle = "Web searches shown when a query has no local match",
        sections = { mode_section, providers_section, import_section },
    })
end

function settings_action(section_id, action, value, form_json)
    local form = host.json.decode(form_json or "") or {}

    if action == "set:append_mode" then
        host.fallback.set_mode(value == "true" or value == true)
        return settings_render(section_id, "{}")
    end

    if action == "import_browser" then
        local added = host.fallback.import_browser()
        if added > 0 then
            host.alert.show("Imported " .. added .. " search provider" .. (added == 1 and "" or "s"))
        else
            host.alert.show("No new providers found in your default browser")
        end
        return settings_render(section_id, "{}")
    end

    local del = action:match("^record%.delete:providers:(.*)$")
    if del then
        local kept = {}
        for _, p in ipairs(load_providers()) do
            if (p.id or slug(p.name)) ~= del then kept[#kept + 1] = p end
        end
        save_providers(kept)
        return settings_render(section_id, "{}")
    end

    -- `record.save:providers:<oldId>` — empty <oldId> means a brand-new record.
    local old = action:match("^record%.save:providers:(.*)$")
    if old then
        local name = (form.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local url = (form.urlTemplate or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #name > 0 and #url > 0 then
            local id = slug(name)
            local enabled = (form.enabled ~= "false" and form.enabled ~= false)
            local kept = {}
            for _, p in ipairs(load_providers()) do
                local pid = p.id or slug(p.name)
                if pid ~= old and pid ~= id then kept[#kept + 1] = p end
            end
            kept[#kept + 1] = { id = id, name = name, urlTemplate = url, enabled = enabled }
            save_providers(kept)
        end
        return settings_render(section_id, "{}")
    end

    return settings_render(section_id, "{}")
end
