-- url-dispatcher — route opened links to a browser chosen by domain (§O).
--
-- Flow: make Prosper the default browser (Settings → URL Dispatcher, or the
-- "Make Prosper the Default Browser" command). macOS then hands every clicked
-- http/https link to Prosper as a `url.open` event { url = "..." }. `on_url`
-- picks a browser by domain rule and re-opens the link there.
--
-- Nothing is hardcoded: the domain rules and the fallback browser live in
-- host.prefs and are edited in the settings pane below. With no rules set, every
-- link goes to the fallback browser.
--
-- Stateless: each link is one `on_url` invocation; no resident router.

local PROSPER = "eu.illegible.prosper"

-- Friendly name <-> bundle id for the settings dropdowns. Convenience picker
-- only — routing itself is 100% user-defined (host.prefs). id_of() passes an
-- unknown value through unchanged, so a raw bundle id typed elsewhere still works.
-- ponytail: fixed list covers the common browsers; widen it (or swap the enum for
-- a free-text bundle-id field) if someone needs an exotic one.
local BROWSERS = {
    { name = "Safari",  id = "com.apple.Safari" },
    { name = "Chrome",  id = "com.google.Chrome" },
    { name = "Firefox", id = "org.mozilla.firefox" },
    { name = "Edge",    id = "com.microsoft.edgemac" },
    { name = "Brave",   id = "com.brave.Browser" },
    { name = "Arc",     id = "company.thebrowser.Browser" },
    { name = "Vivaldi", id = "com.vivaldi.Vivaldi" },
    { name = "Opera",   id = "com.operasoftware.Opera" },
    { name = "Zen",     id = "app.zen-browser.zen" },
}
local SAFE_FALLBACK = "com.apple.Safari" -- always-present last resort (loop guard)

local function name_of(id)
    for _, b in ipairs(BROWSERS) do if b.id == id then return b.name end end
    return id or ""
end
local function id_of(name)
    for _, b in ipairs(BROWSERS) do if b.name == name then return b.id end end
    return name or "" -- pass an unknown value (e.g. a raw bundle id) through
end
local function browser_names()
    local t = {}
    for _, b in ipairs(BROWSERS) do t[#t + 1] = b.name end
    return t
end

-- MARK: persistence (host.prefs) ------------------------------------------------

local ROUTES_KEY, FALLBACK_KEY = "routes", "fallback"

-- routes: JSON array of { match = "<domain substring>", browser = "<bundle id>" }.
local function load_routes()
    local raw = host.prefs.get(ROUTES_KEY)
    if not raw or #raw == 0 then return {} end
    return host.json.decode(raw) or {}
end
local function save_routes(t)
    host.prefs.set(ROUTES_KEY, host.json.encode(t))
end
local function load_fallback()
    local id = host.prefs.get(FALLBACK_KEY)
    return (id and #id > 0) and id or nil
end

-- MARK: routing -----------------------------------------------------------------

local function pick(url)
    for _, r in ipairs(load_routes()) do
        if r.match and #r.match > 0 and string.find(url, r.match, 1, true) then
            return r.browser
        end
    end
    return nil
end

function on_url(payload)
    local url = payload and payload.url
    if type(url) ~= "string" or #url == 0 then return end
    local browser = pick(url) or load_fallback()
    -- Loop guard: Prosper IS the system default now, so opening with a nil/own
    -- bundle id would bounce the link straight back to us forever. Fall back to a
    -- real browser so the link is never lost.
    if not browser or #browser == 0 or browser == PROSPER then
        browser = SAFE_FALLBACK
    end
    host.url.open(url, browser)
end

-- MARK: make-default ------------------------------------------------------------

local function is_default() return host.url.default_browser() == PROSPER end

-- Bound command + settings button. Seeds the fallback from the browser that was
-- default before we took over, so unmatched links keep going where they used to.
function url_dispatcher_make_default()
    local prior = host.url.default_browser()
    if prior and #prior > 0 and prior ~= PROSPER and not load_fallback() then
        host.prefs.set(FALLBACK_KEY, prior)
    end
    if host.url.set_default_browser(PROSPER) then
        host.alert.show("Prosper is now the default browser")
    else
        host.alert.show("Could not set default browser")
    end
end

-- MARK: settings (Tier B) -------------------------------------------------------

local function route_fields(match, browser)
    return {
        { id = "match",   label = "Domain contains", kind = "text", value = match,
          placeholder = "github.com" },
        { id = "browser", label = "Open in", kind = "enum",
          value = name_of(browser), options = browser_names() },
    }
end

function settings_render(section_id, state)
    local s = host.ui.settings
    local default_now = is_default()

    local status_rows = {
        s.row{ kind = "info", title = "Default browser",
               subtitle = default_now
                   and "Prosper is your default browser — opened links are routed below."
                   or "Prosper is NOT your default browser. Routing is inactive until you set it." },
    }
    if not default_now then
        status_rows[#status_rows + 1] = s.row{
            kind = "button", id = "make_default", actionID = "make_default",
            title = "Make Prosper the Default Browser",
            subtitle = "macOS will route every clicked http/https link through Prosper",
            style = "prominent" }
    end
    local status = s.section{
        id = "status", title = "Status", accent = "url-dispatcher",
        footer = "macOS may pop a one-time confirmation the first time you set this.",
        rows = status_rows,
    }

    local fb = s.section{
        id = "fallback", title = "Fallback browser",
        footer = "Where links go when no rule below matches (and where Prosper sends "
            .. "everything when you have no rules). Defaults to Safari.",
        rows = {
            s.row{ kind = "enum", key = "fallback", title = "Open unmatched links in",
                   value = name_of(load_fallback() or SAFE_FALLBACK),
                   options = browser_names() },
        },
    }

    local recs = {}
    for _, r in ipairs(load_routes()) do
        recs[#recs + 1] = {
            id = r.match, title = r.match, subtitle = "→ " .. name_of(r.browser),
            icon = "arrow.triangle.branch",
            fields = route_fields(r.match, r.browser),
        }
    end
    local rules = s.section{
        id = "routes", title = "Routing rules",
        footer = "First match wins. “Domain contains” is a plain substring of the URL "
            .. "(e.g. github.com, localhost, docs.google.com).",
        rows = { s.records{
            id = "routes", records = recs, fields = route_fields("", ""),
            addLabel = "Add rule",
            emptyText = "No rules yet — all links go to the fallback browser.",
        } },
    }

    return s.render(s.ui{
        title = "URL Dispatcher",
        subtitle = "Route opened links to a browser by domain",
        sections = { status, fb, rules },
    })
end

function settings_action(section_id, action, value, form_json)
    local form = host.json.decode(form_json or "") or {}

    if action == "make_default" then
        url_dispatcher_make_default()
        return settings_render(section_id, "{}")
    end

    if action == "set:fallback" then
        host.prefs.set(FALLBACK_KEY, id_of(value))
        return settings_render(section_id, "{}")
    end

    local del = action:match("^record%.delete:routes:(.*)$")
    if del then
        local kept = {}
        for _, r in ipairs(load_routes()) do
            if r.match ~= del then kept[#kept + 1] = r end
        end
        save_routes(kept)
        return settings_render(section_id, "{}")
    end

    local old = action:match("^record%.save:routes:(.*)$")
    if old then
        local match = form.match or ""
        if #match > 0 then
            local kept = {}
            for _, r in ipairs(load_routes()) do
                if r.match ~= old and r.match ~= match then kept[#kept + 1] = r end
            end
            kept[#kept + 1] = { match = match, browser = id_of(form.browser or "") }
            save_routes(kept)
        end
        return settings_render(section_id, "{}")
    end

    return settings_render(section_id, "{}")
end
