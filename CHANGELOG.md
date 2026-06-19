# Changelog

Notable changes per release. The release pipeline (`.github/workflows/release.yml`)
reads the section whose heading matches the version being tagged (e.g. `## v2.91.0`)
and uses it as the GitHub Release body, with the auto-generated commit list appended
below it. Add a new `## vX.Y.Z` section at the top before cutting a release.

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
