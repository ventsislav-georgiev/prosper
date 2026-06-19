-- url-dispatcher — route opened links to a browser chosen by domain (§O).
--
-- Flow: make Prosper the default browser (run the "Make Prosper the Default
-- Browser" command once). macOS then hands every clicked http/https link to
-- Prosper as a `url.open` event { url = "..." }. `on_url` picks a browser by
-- domain and re-opens the link there with host.url.open(url, bundleID).
--
-- Stateless: each link is one `on_url` invocation; no resident router.

local PROSPER = "eu.illegible.prosper"

-- domain substring -> browser bundle id. First match wins; falls through to the
-- system default browser (whatever it was before Prosper took over) otherwise.
local ROUTES = {
    { match = "github.com",     browser = "com.google.Chrome" },
    { match = "localhost",      browser = "com.google.Chrome" },
    { match = "figma.com",      browser = "company.thebrowser.Browser" },
    { match = "docs.google.com", browser = "com.google.Chrome" },
}

local function pick(url)
    for _, r in ipairs(ROUTES) do
        if string.find(url, r.match, 1, true) then return r.browser end
    end
    return nil -- nil bundle id => system default handler
end

function on_url(payload)
    local url = payload and payload.url
    if type(url) ~= "string" or #url == 0 then return end
    local browser = pick(url)
    -- Guard against a loop: if we ever resolve back to Prosper, fall through to
    -- the system default instead of re-dispatching to ourselves.
    if browser == PROSPER then browser = nil end
    host.url.open(url, browser)
end

-- Bound command: register Prosper as the default http/https handler.
function url_dispatcher_make_default()
    if host.url.set_default_browser(PROSPER) then
        host.alert.show("Prosper is now the default browser")
    else
        host.alert.show("Could not set default browser")
    end
end
