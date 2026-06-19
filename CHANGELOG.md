# Changelog

Notable changes per release. The release pipeline (`.github/workflows/release.yml`)
reads the section whose heading matches the version being tagged (e.g. `## v2.91.0`)
and uses it as the GitHub Release body, with the auto-generated commit list appended
below it. Add a new `## vX.Y.Z` section at the top before cutting a release.

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
