<div align="center">

<img width="128" height="128" src="assets/AppIcon.png" alt="Prosper icon">

# Prosper

**Your Mac, autocompleted.** A local LLM at your fingertips — system-wide inline autocomplete and a command palette, 100% on-device.

[![Platform](https://img.shields.io/badge/Apple%20Silicon-black?logo=apple)](#install)

<br>

<p align="center"><img width="960" height="724" alt="Command palette part 1 — calc, percentages, units, currency, time zones" src="https://github.com/user-attachments/assets/ab5b9ed2-ccbb-4e4f-8343-feb659ee0392" /></p>

<sub>Everything runs locally. No cloud, no daemon, no typed text leaving your machine.</sub>

</div>

---

## Why Prosper

**Modular by design.** Prosper ships lean and stays out of your way — most features are off until you switch them on, so you run only what you need and nothing else costs you memory, permissions, or a model download.

- **A command palette that computes** — calc, units, currency, time zones, translate, base64, shell, window snapping, app launcher, file search, browser bookmarks, snippets, quicklinks, quickdirs… one hotkey, type, `⏎`.
- **Window management** — drag-to-edge snapping plus custom drag-into-zone layouts you paint on a grid.
- **System monitors in the menu bar** — CPU, memory, GPU, network, temps, fans, battery, and power, with rich detail popovers — no Accessibility, Screen Recording, or root.
- **Menu-bar management** — hide icons behind a chevron, add spacing, and keep multi-icon apps ordered across relaunches.
- **A domain-based browser router** — make Prosper your default browser and route each link to the right browser by domain.
- **Per-app keyboard input switching** — auto-set your input source by the focused app.
- **Lid-stay-awake** — keep your Mac running with the lid closed, no external display or charger required.
- **Local by architecture, not by promise** — Swift with **in-process MLX inference**: no extra process, minimal CPU/memory, nothing leaves your Mac but the one-time model pull.
- **Inline autocomplete everywhere** — ghost-text continuations at your caret in *any* app, powered by an in-process MLX model (Gemma 4 E4B QAT 8-bit; lighter E2B/E4B variants selectable in Settings).
- **A local coding agent** — `⌥G` opens a chat window driving an on-device tool-using agent (read/edit files, run shells, MCP tools), powered by an in-process MLX model — no API key, no cloud.
- **Extensible end to end** — Lua commands without recompiling, plus MCP servers, agent lifecycle hooks, and JS/TS plugins for the coding agent.

---

## Install

```sh
brew install --cask ventsislav-georgiev/tap/prosper
```

<details>
<summary>Other ways to install</summary>

- **Direct download** — grab `Prosper-<version>.zip` from the [latest release](https://github.com/ventsislav-georgiev/prosper/releases/latest), unzip, drag to `/Applications`. Signed + notarized, so it opens normally — no Gatekeeper workaround.

</details>

---

## Command palette

`⌥Space` opens a floating palette. `⏎` pastes the result where you were typing, `Esc` cancels. The two clips above walk the expression commands end to end — calc → units → currency → time zones, then emoji → shell → live base64 → fuzzy app launch — without ever closing the palette.

| Command | Example | Result |
| --- | --- | --- |
| **Calc** | `128*24` · `52% of 900` · `120 + 10%` | `3072` · `468` · `132` |
| **Unit** | `1 year to minutes` | `525960 minutes` |
| **Currency** | `32 usd to eur` · `$30 CAD + 5 USD - 7 EUR` | today's FX (cached daily), mixed-currency math |
| **Time** | `2:30 pm HKT in Berlin` · `time in Tokyo` | cross-zone conversion, city or zone names |
| **App** | `o Safari` | launch app by name (fuzzy) |
| **Files** | `f report.pdf` | Spotlight file/folder search, open one |
| **Shell** | `> date` | run command, output inline |
| **Base64** | `base64 hi` / `unbase64 aGk=` | live dual-pane encode/decode |
| **Bookmarks** | `bm github` | search browser bookmarks (Chrome/Brave/Edge/Vivaldi/Opera/Arc/Safari/Firefox/Zen), open one |
| **Snippets** | `sn sig` · `sn add` | insert a saved snippet (dynamic placeholders); `add`/`rm`/`list` to manage |
| **QuickLink** | `ql gh anthropics/repo` | open a saved URL/path with `{query}` |
| **QuickDir** | `qd projects api` | browse a saved dir's subfolders, run its action on one |
| **Window** | `win left` / `win max` | snap the focused window (also `⌃⌥←→↑↓` / `⌃⌥⏎` / `⌃⌥C` global hotkeys) |
| **Emoji** | `:fire` | 🔥 |
| **Meta** | `:q` / `:c` | quit / clear clipboard history |
| **Translate** | *free text* (or `⌥L`) | best translation + alternatives, on-device |


<p align="center"><img width="960" height="724" alt="Command palette part 2 — emoji, shell, live base64, fuzzy app launch" src="https://github.com/user-attachments/assets/987e6aae-5e03-4479-9030-9d63b2f41ea0" /></p>

> **Shortcut already taken?** Another launcher may own the hotkey (Raycast claims `⌥Space` by default). Prosper detects the conflict on launch and notifies; rebind in **Settings → Shortcuts**.

---

## Clipboard history *(opt-in)*

`⇧⌥A` opens a floating history (text, files, image previews). Off by default — enable in **Settings → General**. Blobs live on disk; concealed/transient types are skipped.

<p align="center"><img width="960" height="724" alt="prosper-demo-clipboard" src="https://github.com/user-attachments/assets/0c54151f-ed67-4606-b104-2164e914a903" /></p>

Text is auto-typed into **link / email / color** (with a color swatch preview) for at-a-glance icons and filtering. In-panel keys: `⏎` paste · `⌘.` pin (pinned entries sort to the top and survive eviction / clear-all) · `⌘E` rename · `⌘P` cycle the type filter · `⌘⌫` delete · `↑↓` navigate · `Esc` dismiss.

---

## Translate

`⌥L` (or just type a sentence) — best translation plus alternative renderings, entirely on-device. A single ambiguous word lists its candidate meanings; a full sentence picks up the context.

<p align="center"><img width="960" height="724" alt="prosper-demo-translate" src="https://github.com/user-attachments/assets/0683c69a-955c-434b-8448-b80758b4b64e" /></p>

---

## QuickLinks & QuickDirs

Saved URLs with `{query}` templates and saved directories with per-dir actions — browse with a prefix, create new ones inline with `ql add` / `qd add`.

<p align="center"><img width="960" height="724" alt="prosper-demo-links" src="https://github.com/user-attachments/assets/a9a19b68-4f7d-4324-bbb4-dda5b2710ccb" /></p>

---

## Snippets

Insert saved text snippets with dynamic placeholders — type `sn`, pick one, and it expands at your caret in any app. Manage them inline: `sn add` opens a capture dialog, `sn rm` / `sn list` (an empty `sn` query lists everything).

---

## Bookmarks

Search and open browser bookmarks from the palette — type `bm` and filter across **Chrome, Brave, Edge, Vivaldi, Opera, Arc, Safari, Firefox, and Zen** at once. Refresh with `bm import`; `bm browsers` lists what was found.

---

## Window management

Snap and tile windows without a separate window manager. Drag a window to a screen edge (or use `win left` / `win max` in the palette, or the `⌃⌥←→↑↓` / `⌃⌥⏎` / `⌃⌥C` global hotkeys) to snap it. For more than halves and quarters, define your own **layouts**: paint a grid in **Settings → Windows**, then drag a window into a zone to drop it there. Gaps are equal on every side. A stateless take on Rectangle's drag-snapping and Mosaic's drag-into-zone layouts.

<p align="center"><img width="960" alt="Window management — drag-into-zone Mosaic-style layouts" src="https://github.com/user-attachments/assets/4b288b0b-7017-4f37-a102-3e941730f3ec" /></p>

---

## Browser router *(opt-in)*

Ships **disabled** — it hijacks the system default browser, so turn it on in **Settings → Extensions** first, then make Prosper your default from its settings pane. Once enabled, every clicked link is routed to the right
browser by domain — work links to Chrome, personal to Safari, a localhost rule to
whatever you like. Set it up in **Settings → URL Dispatcher**: a one-click *Make
Prosper the Default Browser* button, a fallback browser for unmatched links, and a
**domain → browser** rule list (first match wins, plain substring). Nothing is
hardcoded; rules live in your config. A stateless port of [Finicky](https://github.com/johnste/finicky) /
Hammerspoon URL routing — and the Hammerspoon facade runs an existing
`hs.urlevent.httpCallback` config unmodified.

<p align="center"><img width="647" height="661" alt="URL Dispatcher — domain → browser routing rules" src="https://github.com/user-attachments/assets/532cc8b4-044a-4b2f-816b-234c5423c7a5" /></p>

---

## OpenLid *(opt-in)*

Off by default. Keep your Mac awake with the lid closed — no external display or charger required. **Toggle Mac Awake** flips the clamshell-sleep override on/off, guarded by your battery, network, and AC-power state so it won't drain a disconnected laptop. **OpenLid Status** shows what's currently keeping it awake (read-only); **Toggle Display Awake** keeps the screen from sleeping / the screensaver from kicking in while the lid is open.

Works **out of the box** — no `sudo`, no Terminal, no `sudoers` edit. The lid override needs root, so Prosper installs a tiny privileged helper the first time you enable it (one-time approval in **System Settings → Login Items**); it uses no memory when idle and auto-resets if the app quits or crashes. Nothing is installed unless you use the feature.

Inspired by: https://github.com/openlid/openlid

<p align="center"><img width="637" height="486" alt="OpenLid — keep Mac awake with the lid closed" src="https://github.com/user-attachments/assets/593086f9-089f-4e53-8431-3840aace222c" /></p>

---

## Input Switcher *(opt-in)*

Automatically set your keyboard input source by focused app. Pick one default input for every app, then add per-app overrides — choose an app and the input source it should use; when that app comes to the front Prosper switches the layout for you, and switches back to your default elsewhere. A native take on the common Hammerspoon input-switching recipe. Ships **disabled** — turn it on in **Settings → Extensions**.

<p align="center"><img width="648" height="505" alt="Input Switcher — per-app keyboard input source" src="https://github.com/user-attachments/assets/7685d8a4-b5dc-4239-b178-aea5064ac01f" /></p>

---

## Menu Bar Management *(opt-in)*

Hide menu-bar icons behind a divider you reveal on demand, add spacing between icons, and pick the chevron style — with **no Accessibility or Screen Recording permission** for the basics. A live preview strip in Settings shows your real icons in order; mark any icon "always hidden", or drag the divider to choose what's tucked away. The clickable chevron is a separate, always-on-screen item, so showing/hiding never sweeps it (or Prosper's own icon) off screen. Optional item **ordering** keeps multi-icon apps (Stats, iStat Menus) in place across relaunches. A native take on Ice / Bartender. Ships **disabled** — turn it on in **Settings → Extensions**.

<p align="center"><img width="688" alt="Menu Bar Management — hidden section revealed" src="https://github.com/user-attachments/assets/c928fc57-0174-41a3-bbcf-355061d9c0f4" /></p>

---

## System Stats *(opt-in)*

Native menu-bar system monitors in Prosper's style — **CPU, memory, GPU, network, temperatures, fans, battery, and power**. Pick which modules show and in what order; built entirely on public, on-device APIs (no Accessibility, Screen Recording, or root just to read your stats). Every sampler runs in microseconds and the bar updates once a second, so the monitors don't add measurable load to the thing they measure. Ships **disabled** — turn on the ones you want in **Settings → System Stats**.

Click any module for a live history chart and full breakdown:

- **CPU** — per-core load bars, system/user/idle split, efficiency vs performance cores with live clocks, load average, uptime.
- **Memory** — app/wired/compressed usage, cached files, real kernel memory-pressure level, swap.
- **GPU** — utilization with renderer/tiler breakdown, a Neural-Engine estimate, VRAM, core count, FPS presented.
- **Network** — up/down throughput, live latency & jitter with a reachability badge, connectivity-history grid, active interface + MAC + Wi-Fi signal, local & public IP with country flag, and a per-process download/upload list.
- **Sensors** — full temperature list, fan speeds, labeled voltage/current rails.
- **Power** — live CPU, GPU, Neural Engine, and DRAM wattage with total.
- **Battery** — charge, health, cycle count, live draw, voltage, amperage, capacity, adapter wattage, time remaining.

<p align="center">
<img height="320" alt="System Stats — CPU popover" src="https://github.com/user-attachments/assets/226741ec-7b70-45e8-9433-ffd96bf542db" />
<img height="320" alt="System Stats — Memory popover" src="https://github.com/user-attachments/assets/4eeff975-a974-4a00-8d33-9142a2d5ca76" />
<img height="320" alt="System Stats — Network popover" src="https://github.com/user-attachments/assets/12c8e042-c3aa-47fe-a7e3-db7284cfdd33" />
<img height="320" alt="System Stats — GPU popover" src="https://github.com/user-attachments/assets/100b3d91-8c3d-4ee3-a368-6112b80c7860" />
</p>
<p align="center">
<img height="300" alt="System Stats — Power popover" src="https://github.com/user-attachments/assets/5c311744-5939-4b1a-a400-e558749ce180" />
<img height="300" alt="System Stats — Sensors popover" src="https://github.com/user-attachments/assets/1860ceb7-eb05-4af6-b803-b8f0fa7298a9" />
<img height="300" alt="System Stats — Battery popover" src="https://github.com/user-attachments/assets/40bed14b-4b2a-4575-94b6-421dfcd3a463" />
</p>

---

## Themes

Re-skin the whole app — palette, menu-bar, and dock chrome — from a flat 12-token color palette, with instant redraw. Pick one in **Settings → Personalization**. Ships with the built-in neon-blue console theme and a warm **amber** theme; extensions can contribute their own (`[[contributes.themes]]` → `theme.json`). See [Writing extensions](extensions.md).

<p align="center"><img width="637" height="804" alt="Themes — re-skin the whole app from a 12-token palette" src="https://github.com/user-attachments/assets/ec16cd42-52fc-412f-be07-4cd6772e68a2" /></p>

---

## Extensions

Add commands without recompiling — small **Lua** scripts, auto-loaded, routed by regex. Manage in **Settings → Extensions**: enable/disable, edit live (everything lives in `~/.config/prosper/extensions`), reset bundled extensions to original, **install from GitHub** by pasting a repo URL, or browse the **Marketplace** to one-click-install (and publish) signed extensions — fresh installs stay untrusted until you grant trust. The marketplace opens in its own window with search, All / Themes / Extensions filters, and sort by recently updated or most downloaded.

<p align="center"><img width="764" height="523" alt="Extensions Marketplace — browse and install signed extensions" src="https://github.com/user-attachments/assets/29ba6637-b9fa-4f2b-907d-5bee73624229" /></p>

The built-in commands above (calc, currency, units, base64, quicklinks, quickdirs, snippets, window, open, find files, translate, shell, browser bookmarks, plus the OpenLid and URL-dispatcher automations) *are* Lua extensions — open them in Settings to see how they're written, or use them as templates. Extensions can also **contribute themes** (a flat 12-token palette that re-skins the whole app, including menu-bar/dock chrome — pick one in **Settings → Personalization**) and drive **system automation** — global hotkeys, key remaps, app launchers, screen/power control, filesystem watches — the Hammerspoon territory, with a facade that even loads an unmodified `~/.hammerspoon/init.lua`. See [Writing extensions](extensions.md).

---

## Inline autocomplete *(opt-in)*

Off by default — enable it (and grant Accessibility) in **Settings → Completions**. Once on, type in *any* text field → Prosper shows a continuation as ghost text at the caret.

<p align="center"><img width="960" height="290" alt="prosper-demo-typing" src="https://github.com/user-attachments/assets/69ba3409-27c7-469d-91c6-2e2048dc3f46" /></p>

| Key | Action |
| --- | --- |
| `→` | accept whole suggestion |
| `Tab` / `⌥→` | accept one word (repeat to walk word-by-word) |
| `⌥Tab` | pass a literal Tab through (form navigation) |
| `Esc` | dismiss + stay quiet in that field until focus moves |
| `⌥.` | regenerate the suggestion in place |
| `⌃` + `` ` `` | force a fresh suggestion (also lifts an `Esc` mute) |

- **Type-through ghost** — keep typing what the ghost predicts and it absorbs your keystrokes in place (no flicker, no re-request); steer toward a different word and it snaps to your word instantly while the model catches up.
- **Always suggests** — quiet only for security: password managers, Secure Input, browser address bars (plus your own `Esc` / per-app rules). Whether the context is "enough" is your call, not the model's.
- **Screen-aware context** — nearby on-screen text and the visible conversation (local OCR), plus app/site-specific prompt context, sharpen suggestions in chat apps and browsers.
- **Live indicator** (optional accessory icon) — pulses while thinking, shows a lock under Secure Input, turns orange when generation failed (click it, or hit `⌥.`, to retry). The menu bar names the app holding Secure Input when completions are paused.
- **Electron/Chromium-aware caret tracking** — Slack, Discord & co. hide caret geometry from assistive tooling; Prosper unlocks their accessibility tree and pins the ghost to the real caret, baseline-aligned with your text.
- Completion length (short/medium/long), optional trailing space after the final word-accept, custom AI instructions, per-app/per-domain rules, hide-overlays-on-click — **Settings → Completions / Apps**. The menu-bar icon also toggles completions for the app you were just using.
- **Frees its own RAM** — the model unloads when you turn completions off, and after an idle timeout (default 2 min, configurable), reloading on demand. The inline hot path is untouched.

Typing `:name` also ghost-replaces with an emoji on accept.

---

## Coding agent *(opt-in)*

`⌥G` opens a chat window with a local, tool-using coding agent — it reads and edits files, runs shell commands, and calls MCP tools, all driven by an in-process MLX model (default **Qwen3-Coder 30B-A3B**; lighter Qwen3 variants selectable in **Settings → Agent**). No API key, no cloud round-trip — the model server is loopback-only and never exposed to the network.

> First agent use downloads two things on demand (so an install that never opens the agent stays slim): the model, and the ~86 MB Codex helper binary (pinned release, SHA-256-verified). Both are cached for later launches.

<!-- TODO: chat window demo gif -->

- **Real tool use** — file read/write, shell, and any MCP server you add; approvals surface inline so you stay in control of writes and commands.
- **Run from the terminal** — `prosper agent [--cwd <dir>] <prompt…>` queues a one-shot run against the already-running app (sessions persist).
- **Extensible** — bring your own **MCP servers** (`~/.config/prosper/mcp.json`), **lifecycle hooks** (`~/.config/prosper/hooks.json`, Claude Code-compatible schema), and **JS/TS plugins** (opencode-style, run on a sandboxed Bun host). Manage in **Settings → Agent**.

---

## AI Models

One place to manage every on-device model — **Settings → General → AI Models**. Download or delete models, load/unload them on demand, and watch live loaded-state and measured RAM as they come and go. Rename any model to a friendly label, or add your own from a Hugging Face URL (custom models slot in for the **coding agent**; inline autocomplete stays pinned to the Gemma 4 VLM). The picker is always sorted smallest-to-largest by RAM footprint. Nothing is downloaded until you actually use the feature that needs it.

<p align="center"><img width="640" height="606" alt="AI Models management" src="https://github.com/user-attachments/assets/ee5a74f6-6904-448d-aa1f-67e14c434748" /></p>

---

## Menu bar & Settings

Prosper lives in the notification tray: toggle completions globally or per-app, switch completion length, open the runner/clipboard, check for updates, quit.

A full **Settings** window (`⌥\`) covers General (incl. AI Models) / Shortcuts / Windows / QuickLinks / QuickDirs / Extensions / Agent / Completions / Context / Apps / Personalization / Statistics / About — per-app enable lists, Disable-Tab list, model selector, custom AI instructions, hotkey rebinding, and usage stats.

<p align="center"><img width="960" height="724" alt="prosper-demo-system" src="https://github.com/user-attachments/assets/e61519a5-1cc9-4452-ab09-aa7de9580adc" /></p>

---

## On-device personalization *(opt-in)*

With personalization on, Prosper records your **accepted** completions to a local, encrypted-at-rest store (off by default; **Delete All** any time). From those it can train a per-user **LoRA adapter** on-device — the model learns *your* phrasing without anything leaving your Mac. Everything here is opt-in and stays local. Per-app behavior (force-enable accessibility for Electron/Chromium apps, caret-mirror fallback, custom instructions) is configurable in **Settings → Apps**.

---

## Permissions

Inline autocomplete needs one macOS privacy permission, requested when you enable the feature:

- **Accessibility** — drives the global keystroke tap: watch keys, read the focused field / caret, and insert accepted suggestions. The tap is an active session event tap, so Accessibility alone authorizes it — Input Monitoring (the listen-only HID grant) is not used.

Grant in **System Settings → Privacy & Security**. Settings → Context links straight to the pane and shows a live status check. (Screen Recording is needed only for screenshot / OCR context.)

---

## First launch

Prosper is **Developer ID-signed and notarized by Apple**, so it opens normally — no Gatekeeper workaround, no "unidentified developer" dialog. Install via Homebrew, or download the `.zip` from the [latest release](https://github.com/ventsislav-georgiev/prosper/releases/latest), unzip, and drag `Prosper.app` to `/Applications`.

---

## Updates

Prosper auto-updates via [Sparkle](https://sparkle-project.org) straight from GitHub Releases — use **Check for Updates** in the menu, or update via `brew` (the cask sets `auto_updates true`, so both coexist).

---

## Support Prosper

Prosper is **free, and stays free** — every feature, no paywalls, no subscription. If it earns a place in your workflow and you'd like to chip in, there's an optional, pay-what-you-want supporter option in **Settings → Account** (think *buy me a coffee*). Entirely optional; nothing is gated behind it.

Optionally sign in (passwordless) to sync your settings across Macs — also free, and **end-to-end encrypted with a key that never leaves your devices**. The server stores only ciphertext; no one (not even us) can read your settings.

<p align="center"><img width="640" height="691" alt="Automatic end-to-end encrypted cloud settings sync" src="https://github.com/user-attachments/assets/f05b4961-9789-4043-ad2b-35047b0701cf" /></p>

---

## Limitations

- **Ghost text** renders in a floating overlay at the caret — macOS forbids drawing inside another app's text view. Accepting inserts via synthesized keystrokes / Accessibility.
- Quality/latency track the model: E2B is fast and light; E4B is better but slower.
- First launch downloads the model (~8.9 GB for the default E4B QAT 8-bit; smaller variants from ~4.3 GB) to the HuggingFace Hub cache at `~/.config/prosper/hf`; later launches are instant. (An existing `~/Documents/huggingface` cache from older builds is migrated there automatically on first run.)

---

## Privacy

All inference — including optional LoRA fine-tuning — is local and in-process. Personalization data (accepted completions) is stored on-device in an encrypted-at-rest database and never transmitted. Outbound network is limited to (1) the one-time model download on first launch, (2) at most one currency-rate fetch per day (only if you use the currency command), cached locally, (3) anonymous usage analytics (see below), and (4) — *only if you choose to sign in* — passwordless account and optional settings sync (end-to-end encrypted with an on-device key; the server only ever sees ciphertext). No typed text ever leaves your machine.

### Anonymous usage analytics

Prosper sends anonymous usage analytics once a day to help prioritize what to improve. It is **on by default and opt-out** — turn it off any time in **Settings → Analytics**, which also shows the *exact* payload that will be sent.

What's collected is strictly **counters and on/off flags** — never personal data:

- A random anonymous id (generated on-device, unlinkable to you or your data).
- App version, OS, locale, and the AI model ids you run.
- Per-feature usage **counts** for built-in extensions (e.g. how many times the calculator ran).
- **Counts only** of things you've customized — user extensions, MCP servers, hooks, commands, agents, quicklinks, shortcuts, plugins, per-app rules, etc.
- Settings state as booleans (enabled/disabled).

It **never** sends typed text, completion contents, your name, custom prompts/instructions, file paths, links, app/domain names, or any free text — only the counts and flags above. Data goes to [Aptabase](https://aptabase.com) (EU region).

---

## Extending Prosper

Prosper is free and open source. Extend it without touching the core: write **Lua extensions** (no recompile) — see [extensions.md](extensions.md) — or bring your own **MCP servers**, **agent lifecycle hooks**, and **JS/TS plugins** (see [Coding agent](#coding-agent)). Or build from source — `app/` (Swift) and `server/` (Cloudflare Worker) live in this repo.

---

## Acknowledgements

Prosper takes inspiration — ideas, UI/UX, and implementation know-how — from a number of projects we admire:

- **[exelban/Stats](https://github.com/exelban/stats)** — the System Stats modules (CPU / RAM / GPU / network / sensors / fans) and their popups. Much of our know-how for the private IOReport / IOHID sensor paths and the SMC fan-control sequence came from studying it.
- **[jordanbaird/Ice](https://github.com/jordanbaird/Ice)** — the menu-bar management (hiding, reordering, layout).
- **[openlid/openlid](https://github.com/openlid/openlid)** — the OpenLid lid-stay-awake feature.
- **[Raycast](https://www.raycast.com)** & **[Alfred](https://www.alfredapp.com)** — the command palette / launcher, clipboard history, snippets, and QuickLinks.
- **[Cotypist](https://cotypist.app)** — on-device inline autocomplete.
- **[Hammerspoon](https://github.com/Hammerspoon/hammerspoon)** — the Lua automation / scripting bridge.
- **[Rectangle](https://github.com/rxhanson/Rectangle)** — drag-to-edge window snapping.
- **[Mosaic](https://www.lightpillar.com/mosaic.html)** — drag-into-zone window layouts.

Huge thanks to all of them — their work shaped ours. Also building on mlx-swift, swift-transformers, GRDB.swift, Sparkle, TOMLDecoder, and Apple's Vision / ScreenCaptureKit.

---

## License

Prosper is **free and open source**, licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE). You're free to use, study, modify, and redistribute it; derivative works must also be GPLv3. Every feature is free; [supporting](#support-prosper) the project is optional.
