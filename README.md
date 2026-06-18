<div align="center">

<img width="128" height="128" src="assets/AppIcon.png" alt="Prosper icon">

# Prosper

**Your Mac, autocompleted.** A local LLM at your fingertips — system-wide inline autocomplete and a command palette, 100% on-device.

[![Platform](https://img.shields.io/badge/Apple%20Silicon-black?logo=apple)](#install)

<br>

<p align="center"><img width="960" height="724" alt="Command palette part 1 — calc, percentages, units, currency, time zones" src="https://github.com/user-attachments/assets/04cdaecc-ed97-4031-999f-7ee2fa415b27" /></p>

<sub>Everything runs locally. No cloud, no daemon, no typed text leaving your machine.</sub>

</div>

---

## Why Prosper

- **Inline autocomplete everywhere** — ghost-text continuations at your caret in *any* app, powered by an in-process MLX model (Gemma 4 E4B QAT 8-bit, auto-downloaded on first launch; lighter E2B/E4B variants selectable in Settings).
- **A command palette that computes** — calc, units, currency, time zones, translate, shell, window snapping, quicklinks… one hotkey, type, `⏎`.
- **Local by architecture, not by promise** — Swift with **in-process MLX inference**: no extra process, minimal CPU/memory, nothing leaves your Mac but the one-time model pull.
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
| **Shell** | `> date` | run command, output inline |
| **Base64** | `base64 hi` / `unbase64 aGk=` | live dual-pane encode/decode |
| **QuickLink** | `ql gh anthropics/repo` | open a saved URL/path with `{query}` |
| **QuickDir** | `qd projects api` | browse a saved dir's subfolders, run its action on one |
| **Window** | `win left` / `win max` | snap the focused window (also `⌃⌥←→↑↓` / `⌃⌥⏎` / `⌃⌥C` global hotkeys) |
| **Emoji** | `:fire` | 🔥 |
| **Meta** | `:q` / `:c` | quit / clear clipboard history |
| **Translate** | *free text* (or `⌥L`) | best translation + alternatives, on-device |


<p align="center"><img width="960" height="724" alt="Command palette part 2 — emoji, shell, live base64, fuzzy app launch" src="https://github.com/user-attachments/assets/e7ea203a-d6e8-4cd1-a28a-26ccf890ae4d" /></p>

> **Shortcut already taken?** Another launcher may own the hotkey (Raycast claims `⌥Space` by default). Prosper detects the conflict on launch and notifies; rebind in **Settings → Shortcuts**.

---

## Clipboard history

`⇧⌥A` opens a floating history (text, files, image previews). Off by default — enable in **Settings → General**. Blobs live on disk; concealed/transient types are skipped.

<p align="center"><img width="960" height="724" alt="prosper-demo-clipboard" src="https://github.com/user-attachments/assets/e7a06f9f-03ab-45d0-9be8-6713423bd9ad" /></p>

Text is auto-typed into **link / email / color** (with a color swatch preview) for at-a-glance icons and filtering. In-panel keys: `⏎` paste · `⌘.` pin (pinned entries sort to the top and survive eviction / clear-all) · `⌘E` rename · `⌘P` cycle the type filter · `⌘⌫` delete · `↑↓` navigate · `Esc` dismiss.

---

## Inline autocomplete

Type in *any* text field → Prosper shows a continuation as ghost text at the caret.

<p align="center"><img width="960" height="290" alt="prosper-demo-typing" src="https://github.com/user-attachments/assets/cc02b2ec-f32e-4cee-915c-0eae517320b0" /></p>

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

Typing `:name` also ghost-replaces with an emoji on accept.

---

## Coding agent

`⌥G` opens a chat window with a local, tool-using coding agent — it reads and edits files, runs shell commands, and calls MCP tools, all driven by an in-process MLX model (default **Qwen3-Coder 30B-A3B**; lighter Qwen3 variants selectable in **Settings → Agent**). No API key, no cloud round-trip — the model server is loopback-only and never exposed to the network.

> First agent use downloads two things on demand (so an install that never opens the agent stays slim): the model, and the ~86 MB Codex helper binary (pinned release, SHA-256-verified). Both are cached for later launches.

<!-- TODO: chat window demo gif -->

- **Real tool use** — file read/write, shell, and any MCP server you add; approvals surface inline so you stay in control of writes and commands.
- **Run from the terminal** — `prosper agent [--cwd <dir>] <prompt…>` queues a one-shot run against the already-running app (sessions persist).
- **Extensible** — bring your own **MCP servers** (`~/.config/prosper/mcp.json`), **lifecycle hooks** (`~/.config/prosper/hooks.json`, Claude Code-compatible schema), and **JS/TS plugins** (opencode-style, run on a sandboxed Bun host). Manage in **Settings → Agent**.

---

## Translate

`⌥L` (or just type a sentence) — best translation plus alternative renderings, entirely on-device. A single ambiguous word lists its candidate meanings; a full sentence picks up the context.

<p align="center"><img width="960" height="724" alt="prosper-demo-translate" src="https://github.com/user-attachments/assets/3ed555fc-04ef-4db3-b637-1a13293fd500" /></p>

---

## QuickLinks & QuickDirs

Saved URLs with `{query}` templates and saved directories with per-dir actions — browse with a prefix, create new ones inline with `ql add` / `qd add`.

<p align="center"><img width="960" height="724" alt="prosper-demo-links" src="https://github.com/user-attachments/assets/c0355ae7-7311-4aac-8285-5a869d0f8152" /></p>

---

## Extensions

Add commands without recompiling — small **Lua** scripts, auto-loaded, routed by regex. Manage in **Settings → Extensions**: enable/disable, edit live (everything lives in `~/.config/prosper/extensions`), reset bundled extensions to original, or **install from GitHub** by pasting a repo URL.

The built-in commands above (calc, currency, units, base64, quicklinks, quickdirs, window, open, translate, shell) *are* Lua extensions — open them in Settings to see how they're written, or use them as templates. See [Writing extensions](extensions.md).

---

## Menu bar & Settings

Prosper lives in the notification tray: toggle completions globally or per-app, switch completion length, open the runner/clipboard, check for updates, quit.

A full **Settings** window (`⌥\`) covers General / Shortcuts / QuickLinks / QuickDirs / Extensions / Agent / Completions / Context / Apps / Personalization / Statistics / About — per-app enable lists, Disable-Tab list, model selector, custom AI instructions, hotkey rebinding, and usage stats.

<p align="center"><img width="960" height="724" alt="prosper-demo-system" src="https://github.com/user-attachments/assets/7391956d-e8e4-4e0f-9693-84f110e7107c" /></p>

---

## On-device personalization *(opt-in)*

With personalization on, Prosper records your **accepted** completions to a local, encrypted-at-rest store (off by default; **Delete All** any time). From those it can train a per-user **LoRA adapter** on-device — the model learns *your* phrasing without anything leaving your Mac. Everything here is opt-in and stays local. Per-app behavior (force-enable accessibility for Electron/Chromium apps, caret-mirror fallback, custom instructions) is configurable in **Settings → Apps**.

---

## Permissions

Two macOS privacy permissions, both requested on first use:

- **Accessibility** — read the focused field / caret, insert accepted suggestions.
- **Input Monitoring** — the global keystroke tap driving autocomplete.

Grant in **System Settings → Privacy & Security**. The menu has shortcuts to both panes.

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

## License

Prosper is **free and open source**, licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE). You're free to use, study, modify, and redistribute it; derivative works must also be GPLv3. Every feature is free; [supporting](#support-prosper) the project is optional.
