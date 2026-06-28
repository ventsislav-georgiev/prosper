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

local ROUTES_KEY, FALLBACK_KEY, CLEAN_KEY = "routes", "fallback", "clean_tracking"

-- routes: JSON array of { match = "<domain substring>", browser = "<bundle id>" }.
local function load_routes()
    local raw = host.prefs.get(ROUTES_KEY)
    if not raw or #raw == 0 then return {} end
    local t = host.json.decode(raw)
    return type(t) == "table" and t or {} -- corrupt pref -> empty, never crash routing
end
local function save_routes(t)
    host.prefs.set(ROUTES_KEY, host.json.encode(t))
end
local function load_fallback()
    local id = host.prefs.get(FALLBACK_KEY)
    return (id and #id > 0) and id or nil
end
local function load_clean() return host.prefs.get(CLEAN_KEY) == "true" end

-- MARK: tracking cleanup (opt-in, default off) ----------------------------------
-- Strips analytics / click-id query params from a link before it is opened, so
-- the browser never sees them. Reimplements the Hammerspoon removeTrackingParams,
-- widened to the AdGuard / ClearURLs param set. Pure string surgery: the URL is
-- preserved verbatim minus the matched pairs (the old HS version re-escaped the
-- whole URL, which mangled already-encoded links).
--
-- Generic, ambiguous keys (id, ref, q, c, from, pid, var…) are deliberately NOT
-- listed — only keys that are unambiguously trackers — so functional links never
-- break. Keys compared lowercased.
local TRACK_PREFIX = {
    "utm_", "utm-",              -- Google Analytics / generic campaign
    "mtm_", "pk_", "piwik_",     -- Matomo / Piwik
    "itm_",                      -- Tealium / internal campaign
    "hsa_", "__hs", "_hs",       -- HubSpot
    "vero_", "oly_",             -- Vero / Olytics
    "adj_", "adjust_",           -- Adjust
    "bsft_",                     -- Blueshift
    "dpg_",                      -- DPG Media
    "at_custom", "cm_mmc",       -- AT Internet / IBM Coremetrics
}
local TRACK_EXACT = {}
for _, k in ipairs({
    -- click ids
    "fbclid", "fbadid", "fb_action_ids", "fb_action_types", "fb_source", "fb_ref",
    "mibextid", "epik",          -- Facebook / Pinterest
    "_ga", "_gl",                -- Google Analytics cross-domain linker
    "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "gad_campaignid",
    "msclkid", "yclid", "ysclid", "ymid", "ym_tracking_id",
    "ttclid", "twclid", "tw_source", "tw_medium", "tw_profile_id",
    "igshid", "igsh", "li_fat_id",
    "irclickid", "irgwc", "ir_adid", "ir_campaignid", "ir_partnerid",
    "cjevent", "cjdata", "raneaid", "ranmid", "ransiteid", "sscid", "tduid",
    "admitad_uid", "rb_clickid", "wickedid", "unicorn_click_id", "external_click_id",
    "mt_click_id", "rtkcid", "iclid", "tgclid", "gps_adid", "loclid", "jmtyclid",
    -- email / campaign ids
    "mc_cid", "mc_eid", "mkt_tok", "_openstat", "oly_anon_id", "oly_enc_id",
    "vero_id", "vero_conv", "ml_subscriber", "ml_subscriber_hash",
    "s_cid", "srsltid", "hsctatracking", "mindbox-click-id", "mindbox-message-key",
    "elqtrackid", "elqcampaignid", "elqaid", "elqat", "elqak",
    "sms_click", "sms_source", "xtor", "wt_mc", "ldtag_cl",
    "recommended_by", "recommended_code", "asgtbndr", "spm",
    -- yahoo / misc referrers
    "guccounter", "guce_referrer", "guce_referrer_sig",
    "_branch_match_id", "_branch_referrer", "is_retargeting",
}) do TRACK_EXACT[k] = true end

-- Bucket prefixes by their first byte so a non-tracker key (the common case)
-- does at most a single byte compare + a tiny same-initial bucket scan, instead
-- of ~20 allocating key:sub() compares against the whole prefix list.
local PREFIX_BY_FIRST = {}
for _, p in ipairs(TRACK_PREFIX) do
    local b = p:byte(1)
    local g = PREFIX_BY_FIRST[b]
    if not g then g = {}; PREFIX_BY_FIRST[b] = g end
    g[#g + 1] = p
end

local function is_tracker(key)
    if TRACK_EXACT[key] then return true end
    local g = PREFIX_BY_FIRST[key:byte(1)]
    if g then
        for i = 1, #g do
            local p = g[i]
            if key:sub(1, #p) == p then return true end
        end
    end
    return false
end

local function clean_url(url)
    local qpos = url:find("?", 1, true)
    if not qpos then return url end -- no query, nothing to strip (fast exit)
    -- If a '#' precedes the '?', the '?' lives inside the fragment, not a real
    -- query — leave the URL untouched.
    local hashpos = url:find("#", 1, true)
    if hashpos and hashpos < qpos then return url end
    local orig = url
    local frag = ""
    if hashpos then frag = url:sub(hashpos); url = url:sub(1, hashpos - 1) end
    local head, query = url:sub(1, qpos - 1), url:sub(qpos + 1)
    local kept, removed = {}, false
    for pair in query:gmatch("[^&]+") do
        local key = pair:match("^([^=]+)") or pair
        if is_tracker(key:lower()) then
            removed = true
        else
            kept[#kept + 1] = pair
        end
    end
    -- Nothing matched: return the URL verbatim (no realloc, no empty-pair
    -- collapsing). Only links that actually carry trackers pay the rebuild.
    if not removed then return orig end
    local out = head
    if #kept > 0 then out = out .. "?" .. table.concat(kept, "&") end
    return out .. frag
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
    -- Event payloads arrive as a JSON STRING (callGlobal pushes a Lua string), not
    -- a table — decode before reading. The old `payload.url` indexed a string and
    -- silently got nil, so routing never fired.
    local data = payload and host.json.decode(payload) or nil
    if type(data) ~= "table" then return end
    local url = data.url
    if type(url) ~= "string" or #url == 0 then return end
    if load_clean() then url = clean_url(url) end
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

    local privacy = s.section{
        id = "privacy", title = "Privacy",
        footer = "Strip analytics & click-tracking query parameters (utm_*, fbclid, "
            .. "gclid, mc_eid, …) from links before opening them. Off by default. "
            .. "Functional parameters are kept; only known trackers are removed.",
        rows = {
            s.row{ kind = "toggle", key = "clean_tracking",
                   title = "Remove tracking parameters",
                   subtitle = "Clean links before handing them to the browser",
                   value = load_clean() and "true" or "false" },
        },
    }

    return s.render(s.ui{
        title = "URL Dispatcher",
        subtitle = "Route opened links to a browser by domain",
        sections = { status, privacy, fb, rules },
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

    if action == "set:clean_tracking" then
        host.prefs.set(CLEAN_KEY, value == "true" and "true" or "false")
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
