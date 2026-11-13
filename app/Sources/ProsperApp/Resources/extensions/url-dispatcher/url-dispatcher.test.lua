-- Unit tests for url-dispatcher/init.lua. Uses the shared harness (real JSON
-- codec, recorded host side effects) so scripts/test-extensions.sh runs it.
--
-- Guards the routing logic + the payload-decode fix: on_url receives a JSON
-- STRING (callGlobal pushes a Lua string), not a table — the old `payload.url`
-- silently no-op'd every link.
--
-- Hot-path budget (asserted below): on_url stays well under 1ms/link — a few
-- prefs reads + a substring scan; links arrive at human click rate, not on the
-- keystroke path, so this is comfortable headroom.

local h = require("harness")
local PROSPER = "eu.illegible.prosper"

local host, env = h.makeHost{ defaultBrowser = PROSPER } -- Prosper is default now
local G = h.load(h.dir() .. "init.lua", host)
local on_url = G.on_url
local J = host.json.encode
local function payload(url) return J{ url = url } end
local function lastBrowser() return env.urlOpened and env.urlOpened.browser end
local function reset() env.urlOpened = nil; env.urlOpens = {}; env.alerts = {} end

-- 1. decode fix: a STRING payload must route (the bug: payload.url == nil)
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })
reset()
on_url(payload("https://github.com/x/y"))
h.eq(lastBrowser(), "com.google.Chrome", "string payload routes by rule (decode fix)")
h.eq(env.urlOpened.url, "https://github.com/x/y", "url forwarded intact")

-- 2. proves the OLD path was broken: indexing the JSON string yields nil
h.eq(payload("https://x").url, nil, "indexing JSON string directly is nil (why old code failed)")

-- 3. no rule -> fallback browser
host.prefs.set("fallback", "org.mozilla.firefox")
reset()
on_url(payload("https://example.com"))
h.eq(lastBrowser(), "org.mozilla.firefox", "unmatched link -> fallback")

-- 4. no rule + no fallback -> SAFE_FALLBACK (Safari), never lost
env.prefs["fallback"] = nil
reset()
on_url(payload("https://nowhere.test"))
h.eq(lastBrowser(), "com.apple.Safari", "no fallback -> Safari safety net")

-- 5. loop guard: a rule resolving to Prosper must divert to Safari
host.prefs.set("routes", J{ { match = "loop.test", browser = PROSPER } })
reset()
on_url(payload("https://loop.test/a"))
h.eq(lastBrowser(), "com.apple.Safari", "loop guard: Prosper rule -> Safari")
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })

-- 6. malformed / empty payloads never call open
reset()
on_url(nil); on_url(""); on_url(J{ url = "" }); on_url(J{ noturl = 1 })
h.eq(#env.urlOpens, 0, "nil/empty/garbage payloads open nothing")

-- 6b. non-table decode (corrupt/odd payload) must not crash
reset()
on_url("123"); on_url("true")
h.eq(#env.urlOpens, 0, "non-table payload decode -> no crash, no open")

-- 6c. corrupt routes pref (non-table) -> empty, falls to fallback
env.prefs["routes"] = "123"
host.prefs.set("fallback", "com.apple.Safari")
reset()
on_url(payload("https://anything.test"))
h.eq(lastBrowser(), "com.apple.Safari", "corrupt routes pref -> empty, uses fallback")
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })

-- 7. first match wins
host.prefs.set("routes", J{
    { match = "docs.google.com", browser = "com.google.Chrome" },
    { match = "google.com",      browser = "com.apple.Safari" },
})
reset()
on_url(payload("https://docs.google.com/d/1"))
h.eq(lastBrowser(), "com.google.Chrome", "first matching rule wins")

-- ── settings_action ──────────────────────────────────────────────────────────
-- 8. add a route (form arrives as the 4th arg form_json, not the value arg)
env.prefs["routes"] = nil
G.settings_action("url-dispatcher", "record.save:routes:", nil, J{ match = "figma.com", browser = "Arc" })
local routes = host.json.decode(env.prefs["routes"])
h.eq(routes and #routes, 1, "add route: one rule persisted")
h.eq(routes[1].match, "figma.com", "add route: match persisted")
h.eq(routes[1].browser, "company.thebrowser.Browser", "add route: friendly name -> bundle id")

-- 9. edit a route (old id removed, new saved, no dup)
G.settings_action("url-dispatcher", "record.save:routes:figma.com", nil, J{ match = "figma.com", browser = "Chrome" })
routes = host.json.decode(env.prefs["routes"])
h.eq(#routes, 1, "edit route: no duplicate")
h.eq(routes[1].browser, "com.google.Chrome", "edit route updates in place")

-- 10. delete a route
G.settings_action("url-dispatcher", "record.delete:routes:figma.com", "")
routes = host.json.decode(env.prefs["routes"])
h.eq(routes and #routes, 0, "delete route removes it")

-- 11. set fallback maps name -> bundle id
G.settings_action("url-dispatcher", "set:fallback", "Brave")
h.eq(env.prefs["fallback"], "com.brave.Browser", "set:fallback name -> bundle id")

-- 12. make_default seeds fallback from the prior default browser
env.prefs["fallback"] = nil
env.defaultBrowser = "com.google.Chrome" -- prior default before takeover
reset()
G.url_dispatcher_make_default()
h.eq(env.prefs["fallback"], "com.google.Chrome", "make_default seeds fallback from prior default")
h.eq(env.defaultBrowser, PROSPER, "make_default sets Prosper default")
h.eq(#env.alerts, 1, "make_default shows one alert")

-- 13. make_default does NOT clobber an existing fallback
host.prefs.set("fallback", "org.mozilla.firefox")
env.defaultBrowser = "com.apple.Safari"
G.url_dispatcher_make_default()
h.eq(env.prefs["fallback"], "org.mozilla.firefox", "make_default keeps existing fallback")

-- 14. settings_render returns a settings UI with the 4 sections (no crash)
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })
local ui = G.settings_render("url-dispatcher", "{}")
h.eq(ui and ui.kind, "settings.ui", "settings_render builds a settings UI")
h.eq(#ui.sections, 4, "settings_render builds 4 sections (status/privacy/fallback/routes)")

-- ── tracking cleanup (opt-in) ────────────────────────────────────────────────
host.prefs.set("routes", J{})
host.prefs.set("fallback", "com.apple.Safari")

-- 15. off by default: every param preserved verbatim
host.prefs.set("clean_tracking", "false")
reset()
on_url(payload("https://x.com/a?utm_source=z&id=5&fbclid=abc"))
h.eq(env.urlOpened.url, "https://x.com/a?utm_source=z&id=5&fbclid=abc", "clean off: url untouched")

-- 16. on: strips utm_*/fbclid, keeps functional params (id, q)
host.prefs.set("clean_tracking", "true")
reset()
on_url(payload("https://x.com/a?utm_source=z&id=5&fbclid=abc&q=hi"))
h.eq(env.urlOpened.url, "https://x.com/a?id=5&q=hi", "clean on: trackers stripped, real params kept")

-- 17. all params are trackers -> the '?' is dropped too
reset()
on_url(payload("https://x.com/a?utm_source=z&gclid=1&mc_eid=2"))
h.eq(env.urlOpened.url, "https://x.com/a", "clean on: all-tracker query drops '?'")

-- 18. fragment preserved
reset()
on_url(payload("https://x.com/a?utm_source=z#sec"))
h.eq(env.urlOpened.url, "https://x.com/a#sec", "clean on: fragment preserved")

-- 19. case-insensitive key match (UTM_Source, FBCLID)
reset()
on_url(payload("https://x.com/a?UTM_Source=z&keep=1"))
h.eq(env.urlOpened.url, "https://x.com/a?keep=1", "clean on: case-insensitive tracker match")

-- 20. '?' inside the fragment is not treated as a query
reset()
on_url(payload("https://x.com/a#/route?utm_source=z"))
h.eq(env.urlOpened.url, "https://x.com/a#/route?utm_source=z", "clean on: '?' in fragment untouched")

-- 21. no query -> untouched
reset()
on_url(payload("https://x.com/a"))
h.eq(env.urlOpened.url, "https://x.com/a", "clean on: no query untouched")

-- 21b. REGRESSION GUARD: generic/functional keys must never be stripped.
reset()
on_url(payload("https://x.com/s?id=5&ref=nav&q=hi&page=2&from=home&c=1&var=x&lang=en"))
h.eq(env.urlOpened.url, "https://x.com/s?id=5&ref=nav&q=hi&page=2&from=home&c=1&var=x&lang=en",
     "clean on: generic/functional keys all preserved")

-- 21c. new exacts (_ga/_gl/mibextid/epik) stripped, real param kept
reset()
on_url(payload("https://x.com/a?_ga=1&_gl=2&mibextid=3&epik=4&keep=ok"))
h.eq(env.urlOpened.url, "https://x.com/a?keep=ok", "clean on: GA/FB/Pinterest exacts stripped")

-- 21d. removed 'ga_' prefix must NOT over-match a functional 'ga_'-prefixed key
reset()
on_url(payload("https://x.com/a?ga_token=keepme&utm_source=z"))
h.eq(env.urlOpened.url, "https://x.com/a?ga_token=keepme", "clean on: 'ga_' prefix not over-matched")

-- 21e. removed 'uta_' prefix (unattested in AdGuard/ClearURLs) must NOT over-match
reset()
on_url(payload("https://x.com/a?uta_key=keepme&utm_source=z"))
h.eq(env.urlOpened.url, "https://x.com/a?uta_key=keepme", "clean on: 'uta_' prefix not over-matched")
host.prefs.set("clean_tracking", "false")

-- 22. set:clean_tracking action persists the toggle
G.settings_action("url-dispatcher", "set:clean_tracking", "true")
h.eq(env.prefs["clean_tracking"], "true", "set:clean_tracking on")
G.settings_action("url-dispatcher", "set:clean_tracking", "false")
h.eq(env.prefs["clean_tracking"], "false", "set:clean_tracking off")

-- ── opened local files (#721): .html arrives as a file:// url.open ──────────
-- 23. a rule matches a file URL like any link
host.prefs.set("routes", J{ { match = "/Sites/", browser = "org.mozilla.firefox" } })
host.prefs.set("fallback", "com.google.Chrome")
reset()
on_url(payload("file:///Users/me/Sites/index.html"))
h.eq(lastBrowser(), "org.mozilla.firefox", "file URL routed by rule")
h.eq(env.urlOpened.url, "file:///Users/me/Sites/index.html", "file URL forwarded intact")

-- 24. unmatched file URL -> fallback browser
reset()
on_url(payload("file:///tmp/page.htm"))
h.eq(lastBrowser(), "com.google.Chrome", "unmatched file URL -> fallback")

-- 25. tracker cleaning never rewrites a file URL (its query is the page's own)
host.prefs.set("clean_tracking", "true")
reset()
on_url(payload("file:///tmp/r.xhtml?utm_source=report&fbclid=x#top"))
h.eq(env.urlOpened.url, "file:///tmp/r.xhtml?utm_source=report&fbclid=x#top", "clean on: file URL untouched")
reset()
on_url(payload("FILE:///tmp/r.html?utm_source=report"))
h.eq(env.urlOpened.url, "FILE:///tmp/r.html?utm_source=report", "clean on: uppercase FILE scheme untouched")
reset()
on_url(payload("https://x.com/a?utm_source=z"))
h.eq(env.urlOpened.url, "https://x.com/a", "clean on: web link still cleaned next to the file guard")
host.prefs.set("clean_tracking", "false")
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })

-- ── percent-decoded matching (#936) ─────────────────────────────────────────
-- A rule matches the URL as given, or (URL decoded once, rule decoded once).
-- The decoded form only decides the match: what is opened stays byte-identical.
host.prefs.set("fallback", "com.apple.Safari")
local function route(rules, url)
    host.prefs.set("routes", J(rules))
    reset()
    on_url(payload(url))
    h.eq(env.urlOpened and env.urlOpened.url, url, "opened byte-identical: " .. url)
    return lastBrowser()
end
local FF = "org.mozilla.firefox"

-- 26. a space: rule typed plain, link encoded
h.eq(route({ { match = "My Sites", browser = FF } }, "file:///Users/example/My%20Sites/index.html"),
     FF, "rule with a space matches %20 in the link")
-- 27. a non-ASCII letter: rule typed plain, link encoded
h.eq(route({ { match = "café", browser = FF } }, "https://x.example/caf%C3%A9/menu"),
     FF, "rule with a non-ASCII letter matches its encoded form")
-- 28. a literal percent sign in the rule (lone % = invalid escape, rule kept as typed)
h.eq(route({ { match = "100% off", browser = FF } }, "https://x.example/100%25%20off"),
     FF, "rule with a literal % matches %25 in the link")
-- 29. a rule that already contains %20 matches the link encoded and unencoded
h.eq(route({ { match = "a%20b", browser = FF } }, "https://x.example/a%20b"), FF, "%20 rule, encoded link")
h.eq(route({ { match = "a%20b", browser = FF } }, "file:///Users/example/a b.html"),
     FF, "%20 rule matches an unencoded link")
-- 30. the double-encoded link decodes once: %2520 -> %20, never a space
h.eq(route({ { match = "a b", browser = FF } }, "https://x.example/a%2520b"),
     "com.apple.Safari", "double-encoded link is decoded once only")
h.eq(route({ { match = "a%20b", browser = FF } }, "https://x.example/a%2520b"),
     "com.apple.Safari", "double-encoded link vs %20 rule: no match")
-- 31. an invalid escape leaves the whole URL as given: no partial decode, no error
h.eq(route({ { match = "a b", browser = FF } }, "https://x.example/x%zz/a%20b"),
     "com.apple.Safari", "invalid escape %zz: URL as given, no match")
h.eq(route({ { match = "a b", browser = FF } }, "https://x.example/a%20b%"),
     "com.apple.Safari", "trailing lone %: URL as given, no match")
h.eq(route({ { match = "a b", browser = FF } }, "https://x.example/a%20b%4"),
     "com.apple.Safari", "truncated escape %4: URL as given, no match")
h.eq(route({ { match = "a%zz b", browser = FF } }, "https://x.example/a%zz%20b"),
     "com.apple.Safari", "invalid escape in rule and link: both as given, no error")
-- 32. which rule wins: list order, first match wins, decoded matches included
h.eq(route({ { match = "a b", browser = "com.google.Chrome" }, { match = "a%20b", browser = FF } },
           "https://x.example/a%20b"), "com.google.Chrome", "decoded match earlier in the list wins")
h.eq(route({ { match = "a%20b", browser = FF }, { match = "a b", browser = "com.google.Chrome" } },
           "https://x.example/a%20b"), FF, "as-given match earlier in the list wins")
-- 33. encoded delimiters stay encoded: decoding never moves where host/path/query end
h.eq(route({ { match = "/@good.example", browser = FF } }, "https://evil.example/%40good.example"),
     "com.apple.Safari", "%40 is not decoded to @")
h.eq(route({ { match = "//good.example/", browser = FF } }, "https://good.example%2F.evil.example"),
     "com.apple.Safari", "%2F is not decoded to /")
h.eq(route({ { match = "page?q", browser = FF } }, "https://x.example/page%3Fq"),
     "com.apple.Safari", "%3F is not decoded to ?")
h.eq(route({ { match = "page#top", browser = FF } }, "https://x.example/page%23top"),
     "com.apple.Safari", "%23 is not decoded to #")
-- 34. invalid UTF-8, NUL and newline: no error, no match widened
h.eq(route({ { match = "café", browser = FF } }, "https://x.example/%FF/caf%C3%A9"),
     "com.apple.Safari", "decoded bytes not valid UTF-8: URL as given")
h.eq(route({ { match = "a\0b", browser = FF } }, "https://x.example/a%00b"),
     "com.apple.Safari", "%00 is not decoded to NUL")
h.eq(route({ { match = "a\nb", browser = FF } }, "https://x.example/a%0Ab"),
     "com.apple.Safari", "%0A is not decoded to a newline")
h.eq(route({ { match = "a\31b", browser = FF } }, "https://x.example/a%1Fb"),
     "com.apple.Safari", "%1F (last control byte) is not decoded")
-- 34b. the rest of the kept delimiters, written out: %3A %5B %5D %7F
h.eq(route({ { match = "a:b", browser = FF } }, "https://x.example/a%3Ab"),
     "com.apple.Safari", "%3A is not decoded to :")
h.eq(route({ { match = "a[b", browser = FF } }, "https://x.example/a%5Bb"),
     "com.apple.Safari", "%5B is not decoded to [")
h.eq(route({ { match = "a]b", browser = FF } }, "https://x.example/a%5Db"),
     "com.apple.Safari", "%5D is not decoded to ]")
h.eq(route({ { match = "a\127b", browser = FF } }, "https://x.example/a%7Fb"),
     "com.apple.Safari", "%7F is not decoded to DEL")
-- 34c. a rule that matched as given still matches when the decoded compare cannot
h.eq(route({ { match = "%C3", browser = FF } }, "https://x.example/caf%C3%A9"),
     FF, "as-given match kept: rule %C3 (not UTF-8 alone) vs encoded link")
h.eq(route({ { match = "%41", browser = FF } }, "https://x.example/100%/%41"),
     FF, "as-given match kept: rule %41 vs link with a malformed escape")
-- 34d. a non-string match in a hand-edited pref is skipped, never an error
h.eq(route({ { match = 42, browser = FF }, { match = true, browser = FF }, { match = {}, browser = FF },
             { match = "x.example", browser = "com.google.Chrome" } }, "https://x.example/p"),
     "com.google.Chrome", "non-string rule matches skipped without error")
-- 35. the rule's own text decoded: an encoded non-ASCII rule matches a plain link
h.eq(route({ { match = "caf%C3%A9", browser = FF } }, "file:///Users/example/café.html"),
     FF, "encoded rule matches an unencoded link")
-- 36. tracker cleaning still runs first; what is opened is the cleaned link as given
host.prefs.set("clean_tracking", "true")
host.prefs.set("routes", J{ { match = "a b", browser = FF } })
reset()
on_url(payload("https://x.example/a%20b?utm_source=z&id=1"))
h.eq(env.urlOpened.url, "https://x.example/a%20b?id=1", "clean on: opened link stays encoded")
h.eq(lastBrowser(), FF, "clean on: decoded match still routes")
host.prefs.set("clean_tracking", "false")
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })

-- ── host rules (#1021): a domain-shaped rule matches the link's host only ───
-- route() also asserts every opened link stays byte-identical.
local GOOD = { { match = "good.example", browser = FF } }
local SAF = "com.apple.Safari" -- the fallback set above
-- 37. the host itself, and a subdomain of it
h.eq(route(GOOD, "https://good.example/a"), FF, "host rule: the host itself")
h.eq(route(GOOD, "https://docs.good.example/a"), FF, "host rule: a subdomain")
-- 38. a look-alike: the rule as a suffix of a longer label, or as a leading part of the host
h.eq(route(GOOD, "https://good.example.evil.example/"), SAF, "host rule: good.example.evil.example is not good.example")
h.eq(route(GOOD, "https://notgood.example/"), SAF, "host rule: label boundary, notgood.example")
-- 39. the host text in the path, the query or the fragment
h.eq(route(GOOD, "https://evil.example/good.example"), SAF, "host rule: host text in the path")
h.eq(route(GOOD, "https://evil.example/?next=good.example"), SAF, "host rule: host text in the query")
h.eq(route(GOOD, "https://evil.example/#good.example"), SAF, "host rule: host text in the fragment")
h.eq(route(GOOD, "https://evil.example\\good.example"), SAF, "host rule: a backslash ends the host")
h.eq(route(GOOD, "https://good.example\\@evil.example/"), FF, "host rule: backslash ends the host before the '@'")
-- 40. userinfo is not the host: the host is after the LAST '@'
h.eq(route(GOOD, "https://good.example@evil.example/"), SAF, "host rule: userinfo good.example")
h.eq(route(GOOD, "https://a@good.example:pw@evil.example/"), SAF, "host rule: last '@' decides")
h.eq(route(GOOD, "https://user:pw@good.example/"), FF, "host rule: userinfo dropped, host matches")
-- 41. a port is not part of the host
h.eq(route(GOOD, "https://good.example:8443/x"), FF, "host rule: port left out")
h.eq(route(GOOD, "https://evil.example:443/good.example"), SAF, "host rule: port, host text in the path")
-- 42. upper case on either side, and a trailing dot
h.eq(route(GOOD, "HTTPS://Docs.GOOD.Example/Path"), FF, "host rule: upper-case link")
h.eq(route({ { match = "Good.Example", browser = FF } }, "https://good.example/"), FF, "host rule: upper-case rule")
h.eq(route(GOOD, "https://good.example./"), FF, "host rule: trailing dot on the host")
-- 43. an IPv6 literal: the host is the bracketed address, its ':' is not a port
h.eq(route(GOOD, "http://[::1]:8080/good.example"), SAF, "host rule: IPv6 host, text in the path")
h.eq(route({ { match = "[::1]", browser = FF } }, "http://[::1]:8080/"), FF, "IPv6 rule is a substring rule")
-- 44. a file:// link has no host to compare: every rule stays a substring match
h.eq(route(GOOD, "file:///Users/example/good.example/index.html"), FF, "file link: domain-shaped rule as substring")
h.eq(route({ { match = "index.html", browser = FF } }, "file:///Users/example/index.html"), FF,
     "file link: index.html rule still matches")
-- 45. a link with no host: substring as before; an empty host matches no host rule
h.eq(route(GOOD, "about:good.example"), FF, "no-host link: substring as before")
h.eq(route(GOOD, "https:///evil.example/good.example"), SAF, "extra slashes: host is evil.example")
h.eq(route(GOOD, "https:///good.example/"), FF, "extra slashes: host is good.example")
h.eq(route(GOOD, "https://"), SAF, "empty host: no host rule matches, no error")
h.eq(route(GOOD, "good.example/x"), FF, "no scheme: no host to read, substring as before")
-- 46. non-domain rules keep the whole-link substring match
h.eq(route({ { match = "localhost", browser = FF } }, "http://localhost:3000/"), FF, "single label: substring")
h.eq(route({ { match = "good.example/a", browser = FF } }, "https://evil.example/x?u=good.example/a"), FF,
     "rule with a path: substring")
h.eq(route({ { match = ".good.example", browser = FF } }, "https://x.good.example/"), FF, "leading dot: substring")
h.eq(route({ { match = "github", browser = FF } }, "https://github.com/"), FF, "no dot: substring, still matches github.com")
h.eq(route({ { match = "a..example", browser = FF } }, "https://x.example/a..example"), FF, "empty label: substring")
-- 47. IDN: a Unicode rule and a punycode link (and the reverse) compare in one form
h.eq(route({ { match = "café.example", browser = FF } }, "https://xn--caf-dma.example/"), FF, "IDN: Unicode rule, punycode link")
h.eq(route({ { match = "xn--caf-dma.example", browser = FF } }, "https://café.example/"), FF, "IDN: punycode rule, Unicode link")
h.eq(route({ { match = "bücher.example", browser = FF } }, "https://www.xn--bcher-kva.example/"), FF, "IDN: bücher subdomain")
h.eq(route({ { match = "münchen.example", browser = FF } }, "https://xn--mnchen-3ya.example/"), FF, "IDN: münchen")
h.eq(route({ { match = "café.example", browser = FF } }, "https://caf%C3%A9.example/"), FF, "IDN: %-encoded host decoded")
h.eq(route({ { match = "café.example", browser = FF } }, "https://xn--caf-dma.example.evil.example/"), SAF,
     "IDN: look-alike suffix")
-- 47b. longer labels (the bias adapts between characters), vectors from Python's punycode codec
for _, v in ipairs({ { "παράδειγμα", "xn--hxajbheg2az3al" }, { "пример", "xn--e1afmkfd" },
                     { "ドメイン名例", "xn--eckwd4c7cu47r2wf" }, { "例え", "xn--r8jz45g" }, { "日本語", "xn--wgv71a119e" },
                     { "bücherbüchér", "xn--bcherbchr-i4a5rf" } }) do
    h.eq(route({ { match = v[1] .. ".example", browser = FF } }, "https://" .. v[2] .. ".example/"), FF,
         "IDN: " .. v[1] .. " is " .. v[2])
end
-- 48. the label cap counts characters: 40 (80 bytes) compares, 64 matches no host rule
h.eq(route({ { match = "xn--9c" .. string.rep("a", 40) .. ".example", browser = FF } },
           "https://" .. string.rep("é", 40) .. ".example/"), FF, "IDN: 40-character label compares")
h.eq(route({ { match = "xn--9c" .. string.rep("a", 64) .. ".example", browser = FF } },
           "https://" .. string.rep("é", 64) .. ".example/"), SAF, "IDN: 64-character label matches no host rule")
-- 49. a rule ending in a dot: its labels at a label boundary of the host, more labels after
local GDOT = { { match = "google.", browser = FF } }
h.eq(route(GDOT, "https://google.com/"), FF, "dot-ended: google.com")
h.eq(route(GDOT, "https://google.de/"), FF, "dot-ended: google.de")
h.eq(route(GDOT, "https://google.co.uk/"), FF, "dot-ended: google.co.uk")
h.eq(route(GDOT, "https://www.google.com/"), FF, "dot-ended: www.google.com (after a label boundary)")
h.eq(route(GDOT, "https://WWW.Google.COM:443/"), FF, "dot-ended: case and port")
h.eq(route(GDOT, "https://notgoogle.com/"), SAF, "dot-ended: notgoogle.com")
h.eq(route(GDOT, "https://mygoogle.de/"), SAF, "dot-ended: mygoogle.de")
h.eq(route(GDOT, "https://evil.example/google.com"), SAF, "dot-ended: google.com in the path")
h.eq(route(GDOT, "https://google/"), SAF, "dot-ended: the bare label needs an ending")
h.eq(route({ { match = "docs.google.", browser = FF } }, "https://docs.google.com/d"), FF, "dot-ended: two labels")
h.eq(route({ { match = "docs.google.", browser = FF } }, "https://xdocs.google.com/d"), SAF, "dot-ended: two labels, boundary")
-- 50. a rule of numbers: an address or its start, compared from the left of a dotted-number host
local NET = { { match = "192.168", browser = FF } }
h.eq(route(NET, "http://192.168.1.5:8080/"), FF, "address: 192.168 matches 192.168.1.5")
h.eq(route({ { match = "192.168.", browser = FF } }, "http://192.168.1.5/"), FF, "address: dot-ended 192.168.")
h.eq(route({ { match = "10.0.0", browser = FF } }, "http://10.0.0.7/"), FF, "address: 10.0.0")
h.eq(route(NET, "http://192.1680.1.1/"), SAF, "address: label boundary, 192.1680")
h.eq(route(NET, "http://10.192.168.1/"), SAF, "address: compared from the left")
h.eq(route(NET, "https://5.192.168.in-addr.example/"), SAF, "address: a name with the digits in it")
h.eq(route(NET, "https://192.168.evil.example/"), SAF, "address: a name starting with the digits")
h.eq(route(NET, "https://evil.example/192.168.1.5"), SAF, "address: digits in the path")
h.eq(route({ { match = "192.168.1.5", browser = FF } }, "http://192.168.1.5/"), FF, "address: full address, that host")
h.eq(route({ { match = "192.168.1.5", browser = FF } }, "http://192.168.1.50/"), SAF, "address: full address, label boundary")
h.eq(route({ { match = "192.168.1.5", browser = FF } }, "http://192.168.1.5.6/"), SAF, "address: full address, that host only")
h.eq(route({ { match = "1password.example", browser = FF } }, "https://my.1password.example/"), FF,
     "address: a domain that starts with a digit is still a domain")
-- 51. OQ-112 (with the operator): a domain without its ending stays strict, as built
h.eq(route({ { match = "docs.google", browser = FF } }, "https://docs.google.com/"), SAF,
     "OQ-112: docs.google does not match docs.google.com")
-- 52. a decoded host holding a delimiter or a space is no host: host rules match nothing,
-- and the substring match never re-admits it for a domain-shaped rule
h.eq(route(GOOD, "https://evil.example%23.good.example/"), SAF, "decoded host: %23 is no host")
h.eq(route(GOOD, "https://evil.example%2F.good.example/"), SAF, "decoded host: %2F is no host")
h.eq(route(GOOD, "https://evil.example%20.good.example/"), SAF, "decoded host: a decoded space is no host")
h.eq(route(GOOD, "https://evil.example%00.good.example/"), SAF, "decoded host: a control byte is no host")
h.eq(route({ { match = "%23", browser = FF } }, "https://evil.example%23.good.example/"), FF,
     "decoded host: a non-domain rule still substring-matches such a link")
h.eq(route(GOOD, "https://a_b.good.example/"), FF, "decoded host: '_' is a host character")
-- 53. round 3. A label starting or ending with '-' is no host label: such a rule stays a substring rule
h.eq(route({ { match = "-my.sharepoint.com", browser = FF } }, "https://contoso-my.sharepoint.com/x"), FF,
     "leading '-': substring, matches contoso-my.sharepoint.com")
h.eq(route({ { match = "tenant-.example", browser = FF } }, "https://x.example/tenant-.example/p"), FF,
     "label ending in '-': substring")
-- 53b. what the strict host match does today, pinned as built (OQ-115 is with the operator)
h.eq(route({ { match = "my.sharepoint.com", browser = FF } }, "https://contoso-my.sharepoint.com/x"), SAF,
     "OQ-115: my.sharepoint.com is only part of contoso-my.sharepoint.com")
h.eq(route({ { match = "github.com.", browser = FF } }, "https://github.com/"), SAF,
     "OQ-115: github.com. (dot-ended) needs more labels, not github.com")
h.eq(route({ { match = "github.com.", browser = FF } }, "https://github.com.evil.example/"), FF,
     "OQ-115: github.com. matches github.com.evil.example")
h.eq(route({ { match = "google.com", browser = FF } }, "https://google.com.au/"), SAF, "OQ-115: google.com is not google.com.au")
h.eq(route({ { match = "index.html", browser = FF } }, "https://example.com/index.html"), SAF,
     "OQ-115: index.html is domain-shaped, no match on a web link's path")
h.eq(route({ { match = "index.html", browser = FF } }, "file:///Users/example/index.html"), FF,
     "OQ-115: index.html still matches a file link")
-- 53c. a non-special scheme reads its host after "//" only
h.eq(route(GOOD, "ssh://good.example@evil.example/"), SAF, "non-special scheme: host after the last '@'")
h.eq(route(GOOD, "ssh://git@good.example/repo"), FF, "non-special scheme: host good.example")
-- 53d. non-ASCII upper case is not folded (lowercase is ASCII-only, in every locale)
h.eq(route({ { match = "CAFÉ.example", browser = FF } }, "https://café.example/"), SAF, "É is not folded: café.example misses")
h.eq(route({ { match = "CAFÉ.example", browser = FF } }, "https://xn--caf-dma.example/"), SAF, "É is not folded: punycode misses")
h.eq(route({ { match = "CAFÉ.example", browser = FF } }, "https://cafÉ.example/"), FF, "É is not folded: the same É matches")
-- 53e. invalid UTF-8 (a Latin-1 é, byte E9) on either side: no error. Such a rule is no host
-- rule (substring match); such a link host is "" (no host rule matches it)
h.eq(route({ { match = "caf\xE9.example", browser = FF } }, "https://x.example/caf\xE9.example"), FF,
     "invalid UTF-8 rule: substring match")
h.eq(route({ { match = "caf\xE9.example", browser = FF } }, "https://caf\xE9.example/"), FF,
     "invalid UTF-8 rule and host: substring match")
h.eq(route(GOOD, "https://caf\xE9.good.example/"), SAF, "invalid UTF-8 host: no host rule matches")
h.eq(route({ { match = "café.example", browser = FF } }, "https://caf\xE9.example/"), SAF,
     "invalid UTF-8 host vs a Unicode rule: no match")
-- 53f. a scheme is ASCII letters: "xê" (C3 AA, letters to a UTF-8 LC_CTYPE) is no scheme, so no host, substring
h.eq(route(GOOD, "xê://good.example@evil.example/"), FF, "non-ASCII scheme: no host, substring match")
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })

-- ── performance: on_url hot path ─────────────────────────────────────────────
host.prefs.set("routes", J{
    { match = "github.com", browser = "com.google.Chrome" },
    { match = "figma.com",  browser = "company.thebrowser.Browser" },
    { match = "localhost",  browser = "com.google.Chrome" },
})
host.prefs.set("fallback", "com.apple.Safari")
local p = payload("https://github.com/some/long/path?q=1")
local per = h.bench(20000, function() on_url(p) end) * 1e6 -- us/call
print(string.format("perf: on_url (clean off) = %.2f us/link", per))
h.le(per, 1000, "on_url under 1ms/link hot-path budget")

-- ── stability: tracking-cleanup edge cases (clean on) ────────────────────────
host.prefs.set("clean_tracking", "true")
host.prefs.set("routes", J{}); host.prefs.set("fallback", "com.apple.Safari")

reset(); on_url(payload("https://x.com/a?"))            -- empty query, no trackers
h.eq(env.urlOpened.url, "https://x.com/a?", "empty query preserved verbatim")

reset(); on_url(payload("https://x.com/a?keep=1&utm_source=z&"))  -- trailing &
h.eq(env.urlOpened.url, "https://x.com/a?keep=1", "trailing & + tracker handled")

reset(); on_url(payload("https://x.com/a?utm_source"))  -- tracker key, no value
h.eq(env.urlOpened.url, "https://x.com/a", "valueless tracker key stripped")

reset(); on_url(payload("https://x.com/a?flag&keep=1")) -- valueless non-tracker kept
h.eq(env.urlOpened.url, "https://x.com/a?flag&keep=1", "valueless non-tracker kept")

reset(); on_url(payload("https://x.com/p?a=1&b=2&c=3&d=4&e=5")) -- no trackers
h.eq(env.urlOpened.url, "https://x.com/p?a=1&b=2&c=3&d=4&e=5",
     "no-tracker URL returned byte-identical (early exit, no collapse)")
host.prefs.set("clean_tracking", "false")

-- ── performance: clean_url hot path (clean ON) ───────────────────────────────
-- Budget rationale: links arrive at human click rate, not on the keystroke tap,
-- so the bar is generous — but cleanup is pure Lua string work and must stay
-- comfortably sub-millisecond on every shape. We assert three representative
-- shapes: a clean URL (early-exit), a mixed URL, and a tracker-heavy URL.
host.prefs.set("clean_tracking", "true")
host.prefs.set("routes", J{
    { match = "github.com", browser = "com.google.Chrome" },
    { match = "figma.com",  browser = "company.thebrowser.Browser" },
    { match = "localhost",  browser = "com.google.Chrome" },
})

local p_clean = payload("https://shop.example.com/item?id=42&color=blue&size=large&ref=home")
local p_mixed = payload("https://shop.example.com/item?id=42&utm_source=nl&utm_medium=email&fbclid=XYZ&color=blue")
local p_heavy = payload("https://x.com/a?utm_source=a&utm_medium=b&utm_campaign=c&utm_term=d&utm_content=e&gclid=f&fbclid=g&mc_eid=h&msclkid=i&igshid=j")

local t_clean = h.bench(20000, function() on_url(p_clean) end) * 1e6
local t_mixed = h.bench(20000, function() on_url(p_mixed) end) * 1e6
local t_heavy = h.bench(20000, function() on_url(p_heavy) end) * 1e6
print(string.format("perf: on_url clean ON  early-exit=%.2f  mixed=%.2f  heavy=%.2f us/link",
    t_clean, t_mixed, t_heavy))
h.le(t_clean, 1000, "clean on, no-tracker link under 1ms/link")
h.le(t_mixed, 1000, "clean on, mixed link under 1ms/link")
h.le(t_heavy, 1000, "clean on, tracker-heavy link under 1ms/link")
host.prefs.set("clean_tracking", "false")

-- ── clean copied links (clipboard.changed → on_clipboard) ───────────────────
-- The write-back is the loop-prone path: every host.clipboard.write bumps
-- changeCount and would re-fire the event. Guard #1 is host-side
-- (suppressNextChange); guard #2 is the no-change early-out asserted here.
local on_clipboard = G.on_clipboard
local function clip(kind, text)
    env.clipboard = text or ""
    env.actions = {}
    on_clipboard(J{ kind = kind, text = text })
end
local function writes()
    local n = 0
    for _, a in ipairs(env.actions) do if a == "clip.write" then n = n + 1 end end
    return n
end

-- 15. off by default: even a tracker-laden copy is left alone
host.prefs.set("clean_tracking", "true") -- proves the two toggles are independent
clip("text", "https://shop.example.com/i?id=42&utm_source=nl")
h.eq(writes(), 0, "clean_copied off -> no write (independent of clean_tracking)")

host.prefs.set("clean_copied", "true")

-- 16. tracker-laden copy is rewritten in place
clip("text", "https://shop.example.com/i?id=42&utm_source=nl&fbclid=XYZ&color=blue")
h.eq(writes(), 1, "utm/fbclid copy -> exactly one write")
h.eq(env.clipboard, "https://shop.example.com/i?id=42&color=blue", "trackers stripped, functional params kept")

-- 17. loop guard #2: the cleaned URL cleans to itself -> no second write
clip("text", "https://shop.example.com/i?id=42&color=blue")
h.eq(writes(), 0, "already-clean URL -> no write (loop guard)")

-- 18. no query at all
clip("text", "https://example.com/page")
h.eq(writes(), 0, "query-less URL -> no write")

-- 19. non-URL text is never touched
clip("text", "utm_source=nl just some notes")
clip("text", "ftp://host/file?utm_source=x")
clip("text", "")
h.eq(writes(), 0, "non-http text -> no write")

-- 20. a URL embedded in prose is the user's text, not ours to rewrite
clip("text", "see https://x.com/a?utm_source=nl for details")
h.eq(writes(), 0, "URL inside prose -> no write")

-- 21. non-text kinds carry no text
clip("image", nil)
clip("file", nil)
h.eq(writes(), 0, "image/file copies -> no write")

-- 22. truncated payload (ClipboardMonitor caps text at 8 KB) must not be written
-- back — that would silently destroy everything past the cap.
clip("text", "https://x.com/a?utm_source=nl&pad=" .. string.rep("z", 8 * 1024))
h.eq(writes(), 0, "8 KB-capped payload -> no write (never truncate the user's copy)")

-- 22b. a link with "à" (C3 A0): A0 is a space to a UTF-8 LC_CTYPE (%s); the link is still one token
clip("text", "https://x.example/caf\xC3\xA0?utm_source=nl")
h.eq(writes(), 1, "link with C3 A0 -> one write in every locale")
h.eq(env.clipboard, "https://x.example/caf\xC3\xA0", "link with C3 A0 -> cleaned, bytes intact")

-- 23. malformed payloads never crash or write
env.actions = {}
on_clipboard(nil); on_clipboard(""); on_clipboard("123"); on_clipboard(J{ kind = "text" })
h.eq(writes(), 0, "nil/garbage clipboard payloads -> no crash, no write")

host.prefs.set("clean_copied", "false")
host.prefs.set("clean_tracking", "false")

print("url-dispatcher: ALL PASS")
