# Changelog

Notable changes per release. The release pipeline (`.github/workflows/release.yml`)
reads the section whose heading matches the version being tagged (e.g. `## v2.91.0`)
and uses it as the GitHub Release body, with the auto-generated commit list appended
below it. Add a new `## vX.Y.Z` section at the top before cutting a release.

## v2.101.0

### Hammerspoon Compat
- **`hs.dialog.blockAlert` and `hs.alert.closeSpecific` now work.** Configs with a
  confirm-then-act hotkey — e.g. the common cmd+shift+delete "Empty Trash" binding
  that does `hs.dialog.blockAlert("Empty Trash", …)` and acts only if the returned
  button equals `"Empty Trash"` — did nothing: `hs.dialog` was unshimmed, so the
  call fell through to an inert stub that returned a table instead of the button
  title, and the `== "Empty Trash"` branch was never taken (no dialog, no action,
  silently). `hs.dialog.blockAlert` is now backed by the native confirm dialog and
  returns the chosen button title; `hs.alert.closeSpecific` is shimmed as a no-op so
  the progress-alert dismissal pattern doesn't error. (Actions that then drive
  another app via osascript — like `tell application "Finder" to empty trash` — also
  need the Apple Events automation grant added in v2.100.0.)

## v2.100.0

### Fixes
- **Hammerspoon URL routing that opens links via AppleScript now works.** A
  finicky-style config whose handler does `tell application "Safari" …` (or any
  `hs.osascript`/osascript host call that drives another app) was silently denied
  under the hardened runtime — Prosper shipped without the Apple Events automation
  entitlement, so a clicked link just focused Prosper and nothing opened. Added
  `com.apple.security.automation.apple-events` (and an `NSAppleEventsUsageDescription`
  so macOS can show the one-time Automation prompt). On the first routed link, allow
  "Prosper wants to control Safari". The native URL Dispatcher was unaffected — it
  routes through NSWorkspace, which needs no automation grant.

### Settings
- **Permission rows explain *why* the grant is needed** instead of repeating the
  status. The subtitle previously read "Granted", duplicating the badge; it now shows
  a short rationale (per permission), regardless of grant state.

## v2.99.0

### Extensions
- **Permission UI consistency, part 2.** Two more extensions now follow the same
  rule — a **"Permissions"** group at the **top** of the settings page. OpenLid's
  Background Helper (Login Items) approval moved out of the "Right now" section into
  its own Permissions group at the top, and Hammerspoon Compat's required
  Accessibility row moved out of the main section into a Permissions group above it.

## v2.98.0

### Extensions
- **Consistent permission UI across extensions.** Every extension that requires a
  host permission now surfaces it the same way: a group titled **"Permissions"**
  (plural) at the **top** of its settings page. The Window Management page moved its
  Accessibility group above the shortcut recorders, and Browser Bookmarks' Full Disk
  Access group was renamed from the singular "Permission" — so the look and feel is
  uniform with Snippets.

## v2.97.0

### Extensions
- **Window Management is now a first-class extension settings page.** The shortcut
  recorders + Accessibility permission that used to be a hardcoded Swift pane are
  now declared entirely in the extension's manifest, rendered natively with the
  same look. This also removes the duplicate "Window Management" entry that showed
  in the Settings sidebar. A new declarative `shortcut` control kind lets a manifest
  bind a recorder row to a host global shortcut by name (writes through to the same
  store, re-registers the Carbon hotkey on change) — no Lua required.

### Hammerspoon Compat
- **`URLDispatcher` Spoon now works.** Configs that route links by domain through
  the popular `spoon.SpoonInstall:andUse("URLDispatcher", …)` setup previously did
  nothing (Spoons were inert), so per-domain browser routing and URL rewriting from
  `~/.hammerspoon/init.lua` silently never ran. The Spoon is now shimmed: it wires
  `url_patterns`, `url_redir_decoders`, `default_handler`, and
  `decode_slack_redir_urls` onto the existing `hs.urlevent.httpCallback` path —
  decoders run, then the first matching pattern routes to its app, else the default
  handler. A minimal `hs.http` (`urlParts`, `encodeForQuery`) backs the decoders.
  Routing reuses the existing automation surface, so it carries no new privilege.
  Other Spoons stay inert. The "What's loaded" diagnostic now shows the live
  route/rewriter counts.

### Fixes
- **"Prosper is your default browser" no longer reports a false positive.** The
  check matched the recorded LaunchServices handler id as a string, which can be a
  stale/duplicate registration that no longer resolves to a real browser. It now
  resolves the app macOS would *actually* launch for an http(s) URL, so a broken or
  ghost registration honestly reads as not-default.

## v2.96.1

### Fixes
- **Double-tap-to-quit (⌘Q) now fires on the first try.** A held key's OS
  autorepeats arrive at ~the initial repeat delay (~0.5s) — right inside the
  double-tap window — and were consuming/resetting the pending first press, so
  the real second tap looked like a fresh first one and the chord kept getting
  swallowed (users had to mash ⌘Q several times). The keystroke tap now reads the
  autorepeat flag and ignores repeats in double-tap detection; ordinary
  remap/swallow rules still act on repeats as before.

## v2.96.0

### Fixes
- **Auto-update now installs.** Updates were downloaded but failed at the install
  step with "An error occurred while running the updater." The signing pass stamped
  the restricted `keychain-access-groups` entitlement onto *every* nested binary,
  including Sparkle's `Autoupdate` helper — a bare executable that can't carry the
  provisioning profile that entitlement requires, so macOS (AMFI) killed it on
  launch and the updater's helper process never came up. Signing now applies that
  entitlement to the main app executable only; the nested helpers stay
  profile-free and launchable.

### OpenLid
- **Keep awake with the lid closed now works out of the box — no `sudoers` edit.**
  The clamshell-sleep override (`pmset disablesleep`) needs root, which previously
  meant a manual `NOPASSWD` entry in `/etc/sudoers`. Prosper now ships a tiny
  privileged helper daemon (`ProsperLidHelper`) that does it, installed lazily via
  `SMAppService` the first time you actually disable lid sleep (one-time approval
  in System Settings → Login Items). It idle-exits when unused (zero memory) and
  resets the override automatically if the app quits or crashes, so the lid is
  never left wedged awake. Nothing is installed unless you use the feature — if
  the OpenLid extension is disabled, no background item is ever created.
- **Background Helper approval is now an inline settings row.** The one-time
  Login Items approval shows as a native permission row in the OpenLid section
  (only while the override is active), instead of an alert.
- **The lid is no longer left wedged awake if the helper is force-killed.** A
  daemon kill (force-quit, OOM) used to leave `disablesleep` on with nothing to
  reset it. The daemon now clears any stale override at cold start; a client that
  still wants it reconnects and re-applies.

### Permissions & Settings
- **First-run onboarding removed; Input Monitoring no longer requested.** Inline
  autocomplete and the coding agent are off by default, so first launch needs no
  permissions or model. The keystroke tap was always gated on Accessibility alone,
  so the Input Monitoring grant was redundant — it's gone everywhere. Enabling
  autocomplete without Accessibility now shows a tappable warning in General
  settings that deep-links to the grant.
- **Restored the "Reset & re-add Prosper" Accessibility recovery button.** It now
  lives on the Context pane's Accessibility row (shown only when not trusted) and
  fixes the "toggle is ON in System Settings but the app isn't trusted" trap.
- **"Re-run Setup…" is gated on the selected model, not Accessibility.** It runs
  the model download, so it now appears whenever the chosen completion model is
  missing — and won't pointlessly re-download when the model is already present.
- **Per-extension permission grants are surfaced in each extension's settings.**
  Snippets and window extensions list their Accessibility requirement in their own
  page, so a dead `win`/snippet expansion is debuggable from there.
- **Sync transparency.** Extension settings (`ext.*`) now sync (with machine-local
  state like timers excluded), and the Sync pane has a new "What's synced" section
  listing exactly which categories propagate.

## v2.95.0

### Fixes
- **Double-tap-to-quit (⌘Q) now works.** The detection window was 0.4s — tighter
  than a natural double-tap, so the second press often landed late and the chord
  was swallowed again, meaning ⌘Q appeared to do nothing no matter how many times
  you pressed it. Widened to 0.5s (the macOS double-click default), and the second
  press now lets the real key through instead of re-synthesizing one (some apps
  ignored the synthetic ⌘Q for menu shortcuts).

### Hammerspoon
- The **Hammerspoon** settings diagnostics now show a **URL routing** row —
  whether your `hs.urlevent.httpCallback` is active, and a warning if Prosper isn't
  the default browser (so links never reach it).

## v2.94.0

### Browser
- **Route links to a browser by domain.** Make Prosper your default browser and
  every clicked link is sent to the browser you choose per domain — set it up in
  **Settings → URL Dispatcher** (make-default button, fallback browser, and a
  domain → browser rule list). Nothing is hardcoded; rules live in your config.
- The **Hammerspoon facade** now runs an existing `hs.urlevent.httpCallback`
  (Finicky-style) URL-routing config unmodified.

### Fixes
- URL routing **never actually fired** before: the `url.open` event payload arrives
  as a JSON string, and the handler read it as an object, so every link silently
  fell through. Decoded correctly now, with a loop guard so a link is never bounced
  back to Prosper (the new default) forever.

## v2.93.0

### Fixes
- First click on a command-palette result card (browser bookmarks, file search, app
  launcher, snippets) now opens it. Previously the first click did nothing and you
  had to click a second time.

### Browser
- Prosper can now be chosen as your **default web browser** directly in System
  Settings → Desktop & Dock, alongside the existing "Make Prosper the Default
  Browser" palette command. (It was previously hidden from that list.)

## v2.92.0

### Keyboard
- Fixed shortcuts not firing when inline autocomplete is turned off. Hammerspoon
  hotkeys, per-app key remaps, media keys, and native Settings → Shortcuts mappings
  all share one keystroke tap; it now stays up whenever any of them needs it, not
  only while autocomplete is on.

### Extensions
- Hammerspoon Compat now shows a required-Accessibility row in its settings (with a
  warning when the grant is missing — without it nothing fires) and a "What's loaded"
  diagnostics section listing the hotkeys, key remaps, raw eventtaps, and timers
  parsed from your `~/.hammerspoon/init.lua`.
- Snippets list all entries on an empty `sn` query, matching `bm` / `ql` / `qd`.
- The marketplace now shows the version currently published for an extension and
  offers a one-click bump when your local build is newer.

### Fixes
- Fixed a settings list rendering glitch where info rows could appear duplicated.

## v2.91.0

**First public release.** Prosper is a local-first macOS app: a system-wide
inline autocomplete (ghost text at your caret in any app), a command palette
that computes (calc, units, currency, time zones, translate, shell, window
snapping, quicklinks), a local tool-using coding agent, and clipboard history —
all powered by an in-process MLX model. 100% on-device: no cloud, no daemon, no
typed text leaving your Mac. Extensible with Lua commands, themes, MCP servers,
agent hooks, JS/TS plugins, and Hammerspoon-style automation. Developer
ID-signed and notarized.

This release also lands the changes below.

### Coding agent
- The coding agent is now fully native. The thin `com.prosper.agent` Lua extension
  and the entire `host.agent` host-API bridge were removed; `g <goal>` in the runner
  drives `AgentController` directly. No behavior change — same window, same working
  directory, same approvals.

### Theming
- New theme system: extensions can contribute themes (`[[contributes.themes]]` →
  `theme.json`, a 12-token palette) with instant redraw across the app and AppKit
  chrome (menu-bar/dock). Ships with default and amber themes.

### Keyboard
- Native, configurable Key-Mappings UI (Settings → Shortcuts) replacing the old
  app-keys / app-remaps / media-layer flagships. Incoming media keys can be
  consumed or passed through (volume HUD preserved on miss).

### Memory & performance
- The on-device model now unloads when autocomplete is disabled and after an idle
  timeout (default 2 min, configurable), freeing RAM. The inline hot path is
  untouched.

### Extensions platform
- Extension marketplace: browse and publish extensions, with signed-manifest
  verification and an install-then-trust gate.
- Hammerspoon parity: from-scratch host APIs (timers, caffeinate, battery, network,
  screen/lid, menubar, dialogs, key multiplexer, URL/default-browser, filesystem
  watch) plus a facade that loads an unmodified `~/.hammerspoon/init.lua`.
- New Browser Bookmarks system extension (Safari / Chrome / Firefox / Zen).
- Many new host-API surfaces: durable timers, menu-bar items, FS watch, key rules,
  system services, and event taps.
