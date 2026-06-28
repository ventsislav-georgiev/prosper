-- inputswitch — select the keyboard input source by focused app.
--
-- A default input source applies to every app; per-app overrides win when their
-- app is focused. On each app activation `on_app` selects the matching source via
-- host.keyboard (Carbon TIS). Native port of the Hammerspoon recipe:
--   appWatcher: on activated -> hs.keycodes.currentSourceID(map[app] or default)
--
-- Nothing is hardcoded: the default + the per-app map live in host.prefs and are
-- edited in the settings pane below. The extension VM is cached (one resident Lua
-- runtime reused across events), but this script holds NO mutable module state:
-- every read goes back to host.prefs so settings edits are seen immediately.

-- MARK: input-source name <-> id (settings only — never on the on_app hot path) ---
--
-- host.keyboard.layouts() enumerates EVERY system input source (a main-thread TIS
-- hop), so callers fetch the list ONCE per render/action and pass it to these pure
-- helpers — O(1) enumerations per render instead of O(records).

local function layouts()
    return host.keyboard.layouts() or {} -- { { id=, name= }, ... }
end
local function names(ls)
    local t = {}
    for _, l in ipairs(ls) do t[#t + 1] = l.name end
    return t
end
local function name_for(ls, id)
    for _, l in ipairs(ls) do if l.id == id then return l.name end end
    return id or "" -- unknown id (e.g. a layout that was removed) passes through
end
local function id_for(ls, name)
    -- ponytail: keyed on localized name because record-field enums carry no
    -- optionLabels (only the stable id is stored; the name is the round-trip key).
    -- Two ENABLED sources with byte-identical localized names would collide to the
    -- first match — rare, cold path, user-visible & re-pickable. Upgrade path: add
    -- optionLabels to SettingsField so fields can round-trip by id like rows do.
    for _, l in ipairs(ls) do if l.name == name then return l.id end end
    return name or ""
end

-- MARK: persistence (host.prefs) ------------------------------------------------

local DEFAULT_KEY, APPS_KEY = "default", "apps"

local function load_default()
    local id = host.prefs.get(DEFAULT_KEY)
    return (id and #id > 0) and id or nil
end

-- apps: JSON array of { bundleID = "...", name = "...", source = "<input id>" }.
local function load_apps()
    local raw = host.prefs.get(APPS_KEY)
    if not raw or #raw == 0 then return {} end
    local t = host.json.decode(raw)
    return type(t) == "table" and t or {} -- corrupt pref -> empty, never crash switching
end
local function save_apps(t)
    host.prefs.set(APPS_KEY, host.json.encode(t))
end

local function override_for(bundleID)
    for _, a in ipairs(load_apps()) do
        -- A blank source must NOT shadow the default ("" is truthy in Lua, so
        -- `override or default` would wrongly stop at ""). Return nil to fall through.
        if a.bundleID == bundleID then
            return (type(a.source) == "string" and #a.source > 0) and a.source or nil
        end
    end
    return nil
end

-- MARK: switching (HOT PATH) ----------------------------------------------------
--
-- Fires on EVERY app activation. Budget: < 1ms/activation (measured ~25µs in the
-- test harness). Host hops are the cost, not Lua: at most 1 json.decode (payload) +
-- ≤2 prefs.get (apps, then default only if no override) + 1 TIS read, and a TIS
-- write ONLY when the source actually changes (the write re-enumerates the source
-- list internally — Carbon's API, unavoidable). Never enumerates layouts() here.
-- Returns early before any TIS hop when nothing is configured.

function on_app(payload)
    -- Event payloads arrive as a JSON STRING, not a table — decode before reading.
    local data = payload and host.json.decode(payload) or nil
    if type(data) ~= "table" then return end
    local bundleID = data.bundleID
    if type(bundleID) ~= "string" or #bundleID == 0 then return end

    local want = override_for(bundleID) or load_default()
    if not want or #want == 0 then return end -- nothing configured -> leave layout as-is
    if host.keyboard.current_source() == want then return end -- already correct
    -- layouts() only offers selectable sources, so a freshly-picked `want` always
    -- sets. Residual edge: a source disabled in System Settings AFTER being picked
    -- fails to set and retries on each focus of that one app until re-picked —
    -- self-limited (2 TIS hops), no state kept to suppress it. ponytail: rare, recovers.
    host.keyboard.set_source(want)
end

-- MARK: settings (Tier B) -------------------------------------------------------

local function app_fields(ls, ln, source)
    return {
        { id = "source", label = "Input source", kind = "enum",
          value = name_for(ls, source), options = ln },
    }
end

function settings_render(section_id, state)
    local s = host.ui.settings
    local ls = layouts()        -- one TIS enumeration for the whole render
    local ln = names(ls)
    local default_id = load_default()

    local def = s.section{
        id = "default", title = "Default input source", accent = "inputswitch",
        footer = "Selected when you focus any app without an override below. "
            .. "Leave unset to never change the layout for unlisted apps.",
        rows = {
            s.row{ kind = "enum", key = "default", title = "Use for all apps",
                   value = default_id and name_for(ls, default_id) or (ln[1] or ""),
                   options = ln },
        },
    }

    local recs = {}
    for _, a in ipairs(load_apps()) do
        recs[#recs + 1] = {
            id = a.bundleID, title = a.name or a.bundleID,
            subtitle = "→ " .. name_for(ls, a.source),
            icon = "app.badge",
            fields = app_fields(ls, ln, a.source),
        }
    end
    local overrides = s.section{
        id = "apps", title = "Per-app overrides",
        footer = "Each app uses its own input source when focused. "
            .. "“Add App…” opens a picker; tap a row to change its source, or delete it.",
        rows = {
            s.records{
                id = "apps", records = recs, addLabel = "Add App…",
                emptyText = "No overrides yet — every app uses the default.",
            },
        },
    }

    return s.render(s.ui{
        title = "Input Switcher",
        subtitle = "Switch keyboard input source by focused app",
        sections = { def, overrides },
    })
end

function settings_action(section_id, action, value, form_json)
    local form = host.json.decode(form_json or "") or {}

    if action == "set:default" then
        host.prefs.set(DEFAULT_KEY, id_for(layouts(), value))
        return settings_render(section_id, "{}")
    end

    if action == "record.add:apps" then
        local app = host.ui.chooseApp()
        if app and type(app.bundleID) == "string" and #app.bundleID > 0 then
            local kept = {}
            for _, a in ipairs(load_apps()) do
                if a.bundleID ~= app.bundleID then kept[#kept + 1] = a end
            end
            local ls = layouts()
            -- Seed with the default, else the first selectable source. If there's no
            -- default AND layouts() is empty (only on a transient TIS failure — the
            -- list is otherwise always ≥1), source = "" and the row is deliberately
            -- inert: override_for treats "" as "fall through", so it switches nothing
            -- until the user edits it. The row persists so a later edit can fix it.
            kept[#kept + 1] = {
                bundleID = app.bundleID, name = app.name or app.bundleID,
                source = load_default() or (ls[1] and ls[1].id) or "",
            }
            save_apps(kept)
        end
        return settings_render(section_id, "{}")
    end

    local del = action:match("^record%.delete:apps:(.+)$")
    if del then
        local kept = {}
        for _, a in ipairs(load_apps()) do
            if a.bundleID ~= del then kept[#kept + 1] = a end
        end
        save_apps(kept)
        return settings_render(section_id, "{}")
    end

    local edit = action:match("^record%.save:apps:(.+)$")
    if edit then
        local apps = load_apps()
        local ls = layouts()
        for _, a in ipairs(apps) do
            if a.bundleID == edit then a.source = id_for(ls, form.source or "") end
        end
        save_apps(apps)
        return settings_render(section_id, "{}")
    end

    return settings_render(section_id, "{}")
end
