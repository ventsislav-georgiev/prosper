import Foundation

/// The runner's active input mode. `universal` is the default launcher (apps,
/// calc, units, currency, emoji, extensions by prefix) and never auto-translates.
/// The other cases LOCK the runner to one capability: the whole query is fed to
/// that handler without a prefix, and the UI shows a mode chip. Entered either by
/// typing the capability's prefix (e.g. `l ` → translate) or by a bound shortcut
/// (⌥L → translate) / clicking an extension.
enum RunnerMode: Equatable, Sendable {
    case universal
    /// A specific installed extension command, locked in. `icon` is an SF Symbol.
    /// `arg` carries an optional selector passed to the handler — used by dynamic
    /// modes (e.g. a quickdir's `p` prefix locks `quickdirs.run` with `arg` = the
    /// quickdir name, so the runner browses just that directory).
    case ext(id: String, title: String, icon: String, arg: String? = nil)

    /// Short label shown in the runner's mode chip.
    var title: String {
        switch self {
        case .universal: return ""
        case .ext(_, let title, _, _): return title
        }
    }

    /// SF Symbol for the mode chip / search glyph.
    var icon: String {
        switch self {
        case .universal: return "magnifyingglass"
        case .ext(_, _, let icon, _): return icon
        }
    }

    /// Per-mode placeholder for the search field.
    var placeholder: String {
        switch self {
        case .universal: return "Search for apps and commands\u{2026}"
        case .ext(_, let title, _, _): return "\(title)\u{2026}"
        }
    }
}

/// A leading prefix that switches the universal runner into a locked mode. The
/// prefix is stripped from the visible query once the mode is active.
struct ModeTrigger: Sendable {
    let prefix: String
    let mode: RunnerMode

    /// Built-in triggers, longest-prefix-first so `base64 ` wins over a shorter
    /// overlap. Translation is gated here: nothing translates unless the user
    /// types `l `/`t ` or enters translate mode via the shortcut.
    /// Translate (`l `/`t `), open-app (`o `) and shell (`! `/`> `/`!`) ship as
    /// system extensions that contribute their prefixes via their manifests (see
    /// Resources/extensions/*). The coding agent (`g `) is native — it drives
    /// `AgentController` directly, so it locks in here rather than via a manifest.
    static let builtin: [ModeTrigger] = [
        ModeTrigger(prefix: "g ", mode: .ext(id: CommandRouter.agentCommandID, title: "Coding Agent",
                                             icon: "sparkles", arg: nil)),
    ]

    /// If `input` begins with a built-in trigger, returns the mode and the query
    /// with the prefix removed. Built-ins only (native modes); see `resolve` for
    /// the full set that also includes manifest-declared extension triggers.
    static func match(_ input: String) -> (mode: RunnerMode, stripped: String)? {
        let lower = input.lowercased()
        for t in builtin where lower.hasPrefix(t.prefix) {
            return (t.mode, String(input.dropFirst(t.prefix.count)))
        }
        return nil
    }

    /// Full trigger resolution: built-in native modes first, then runner-mode
    /// triggers contributed by enabled extensions via their manifest `prefix`
    /// (e.g. `"ql "` → the Quicklinks command, shown with its title/icon as the
    /// mode chip). This is the single entry point the UI uses so extensions become
    /// labelled modes without any host-code change.
    @MainActor
    static func resolve(_ input: String) -> (mode: RunnerMode, stripped: String)? {
        if let native = match(input) { return native }
        let lower = input.lowercased()
        for spec in CommandRouter.registry?.modeTriggers() ?? []
        where lower.hasPrefix(spec.prefix.lowercased()) {
            let mode = RunnerMode.ext(id: spec.commandID, title: spec.title,
                                      icon: spec.icon, arg: spec.arg)
            return (mode, String(input.dropFirst(spec.prefix.count)))
        }
        return nil
    }
}

/// The result of running a command-palette query.
/// A window-launching extension command (manifest `launches_window`) surfaced as
/// a selectable launcher row. Enter invokes the command handler (which opens the
/// window via `host.window.open`); `query` is the raw text fed to the handler —
/// an exact verb match carries the full query for pre-fill, partial-discovery
/// hits carry "" (blank window).
struct ExtLaunchHit: Sendable, Equatable {
    let commandID: String
    let title: String
    let icon: String?
    let detail: String
    let query: String
}

enum RunnerOutcome: Sendable {
    /// Arithmetic: the echoed expression and its formatted value.
    case calc(expression: String, value: String)
    /// Unit conversion.
    case unit(title: String, value: String, detail: String)
    /// Currency conversion.
    case currency(value: String, detail: String)
    /// App launch (`o <app>`): resolved display name, launched flag.
    case app(name: String, launched: Bool)
    /// Ranked application matches for a query — the Raycast-style launcher list.
    /// Enter on a row launches that app (handled in the UI, not via copyText).
    case apps([AppEntry])
    /// Unified launcher results: apps + quicklinks + bookmarks merged and ranked
    /// on one ladder (see `SearchHit`/`SearchScore`). Enter behavior is per-row
    /// (launch app / open target), handled in the UI, not via copyText.
    case search([SearchHit])
    /// Nothing matched in universal mode. Carries the query so the UI can hint
    /// (e.g. "press l to translate"). Non-actionable.
    case noResults(query: String)
    /// Shell command (`> <cmd>`): echoed command and captured output.
    case shell(command: String, output: String)
    /// Emoji shortcode match (`:smile` → 😄).
    case emoji(name: String, emoji: String)
    /// `:` meta command (executed on commit).
    case meta(MetaCommand)
    /// Generic extension command (any installed extension matched by its `match`
    /// regex): the command's display title, its result string, and an optional
    /// detail line. Covers user extensions and system extensions without a
    /// dedicated `RunnerOutcome` case (e.g. quicklinks, window management).
    case ext(kind: String, value: String, detail: String)
    /// Saved quicklinks to list in the runner. Each row opens its target (handled
    /// in the UI). Surfaced by the `ql` verb (`ql` lists all, `ql <text>` filters)
    /// and by a bare query that prefix-matches a quicklink name. `launchers`
    /// appends window-launching extension rows (e.g. "Add Quicklink") so the
    /// verb's management commands stay discoverable next to the listing.
    case quicklinks([QuicklinkHit], launchers: [ExtLaunchHit])
    /// Browsable subdirectories of a quickdir to list in the runner. Each row runs
    /// the quickdir's action against that directory (handled in the UI). Surfaced
    /// by a quickdir's dynamic prefix mode (e.g. `p `) or the `qd <name>` verb.
    case quickdirs([QuickdirHit])
    /// The quickdirs picker: configured quickdirs to choose from. Selecting a row
    /// enters that quickdir's browse mode (handled in the UI). Surfaced by bare
    /// `qd` / `qd list`. `launchers` appends window-launching extension rows
    /// (e.g. "Add Quickdir") so the verb's management commands stay discoverable.
    case quickdirsMenu([QuickdirConfig], launchers: [ExtLaunchHit])
    /// A rich, structured result from an extension command — a declarative
    /// component tree (`host.ui.list`/`detail`/…) the runner renders INLINE as
    /// native Neon UI (candidate cards, detected-language header, etc.). This is
    /// how extensions like Translate present beautiful results without shipping
    /// any UI code. The first list item / detail body is what Enter copies.
    case extView(ExtensionViewNode)
    /// Extension commands that open their own window (`host.window.open`).
    /// Surfaced as selectable launcher rows; Enter invokes the handler (which
    /// opens the window) rather than auto-running on every keystroke. A list so a
    /// shared keyword ("add", "create") can surface EVERY matching launcher
    /// command, not just the best one.
    case extLaunch([ExtLaunchHit])
    /// An AI-dependent command was reached but the local model isn't ready yet
    /// (still downloading / loading). Carries a human-readable status line. Shown
    /// as a non-actionable info row; the command auto-works once the model loads.
    case modelPending(String)

    /// The text Enter copies/pastes.
    var copyText: String {
        switch self {
        case .calc(_, let value): return value
        case .unit(_, let value, _): return value
        case .currency(let value, _): return value
        case .app(let name, _): return name
        case .apps: return ""
        case .search: return ""
        case .noResults: return ""
        case .shell(_, let output): return output
        case .emoji(_, let emoji): return emoji
        case .meta(let cmd): return cmd.label
        case .ext(_, let value, _): return value
        case .quicklinks: return ""
        case .quickdirs: return ""
        case .quickdirsMenu: return ""
        case .extView(let node): return node.primaryCopyText
        case .extLaunch: return ""
        case .modelPending: return ""
        }
    }
}

/// Classifies a palette query and routes it to the right engine. Deterministic
/// commands (calc, unit, currency) are tried first and answered locally; only
/// genuinely free-form text falls through to the LLM translator.
///
/// Ordering matters: calc requires an operator; unit needs known unit names;
/// currency needs 3-letter codes — these are mutually exclusive in practice, so
/// the first that parses wins.
enum CommandRouter {

    /// Sentinel command id for the native coding-agent runner mode (`g `). Special-
    /// cased in `run` and `RunnerPanel.launchExtension` — it is NOT an extension id
    /// and must never resolve in the registry.
    static let agentCommandID = "prosper.agent"

    /// Extension registry, set at launch by the app. Command handlers that have
    /// been migrated to system extensions are tried through this; the native
    /// implementation remains as a fallback.
    @MainActor static var registry: ExtensionRegistry?

    /// Calc via the `calc.eval` system extension, falling back to native `Calc`.
    private static func calcResult(_ query: String) async -> String? {
        if let viaExtension = await MainActor.run(body: {
            registry?.invokeSync(commandID: "calc.eval", query: query)
        }) {
            return viaExtension
        }
        if let value = Calc.evaluate(query) { return Calc.format(value) }
        return nil
    }

    /// Unit conversion via the `unit.convert` system extension, falling back to
    /// native `UnitConvert`. The extension returns a TAB-delimited
    /// "<from>\t<to>\t<formatted>" triple; native returns the same fields.
    private static func unitResult(_ query: String)
        async -> (title: String, value: String, detail: String)? {
        if let raw = await MainActor.run(body: {
            registry?.invokeSync(commandID: "unit.convert", query: query)
        }) {
            let parts = raw.components(separatedBy: "\t")
            if parts.count == 3 {
                let title = "\(parts[0]) → \(parts[1])"
                return (title, parts[2], title)
            }
        }
        if let u = UnitConvert.convert(query) {
            let title = "\(u.fromUnit) → \(u.toUnit)"
            return (title, u.formatted, title)
        }
        return nil
    }

    /// Currency via the `currency.convert` system extension (OFF-MAIN async lane:
    /// it calls `host.http`), falling back to native `CurrencyService`. The
    /// extension returns a TAB-delimited "<formatted>\t<detail>" pair.
    private static func currencyResult(_ query: String)
        async -> (value: String, detail: String)? {
        if let registry = await MainActor.run(body: { registry }),
           let raw = await registry.invokeAsync(commandID: "currency.convert", query: query) {
            let parts = raw.components(separatedBy: "\t")
            if parts.count == 2 { return (parts[0], parts[1]) }
        }
        if let c = await CurrencyService.shared.convert(query) {
            return (c.formatted, c.detail)
        }
        return nil
    }

    /// Built-in system commands handled by their own dedicated `RunnerOutcome`
    /// cases above; the generic extension step must not re-dispatch them.
    /// Single source of truth lives on `ExtensionRegistry` (also used to keep
    /// these out of discovery rows).
    private static let dedicatedCommandIDs = ExtensionRegistry.dedicatedCommandIDs

    /// Generic dispatch for any installed extension whose `match` regex accepts
    /// the query and which isn't one of the dedicated built-ins. Runs on the
    /// OFF-MAIN async lane (safe for any host API). Only `no-view` (side-effect)
    /// commands are routed here; `view` commands need the view panel. The handler
    /// may return either a plain string (the whole value) or a TAB-delimited
    /// "<value>\t<detail>" pair.
    private static func extensionResult(_ query: String, modelReady: Bool)
        async -> (kind: String, value: String, detail: String)? {
        // Resolve to plain Sendable strings inside the actor — ExtensionRecord
        // itself isn't Sendable and must not cross the hop. A command that
        // declares `requires = ["model"]` is skipped while the model isn't ready,
        // so AI-dependent extensions stay out of the runner (without changing
        // their enabled state) until the model is downloaded and loaded.
        let routed: (id: String, title: String)? = await MainActor.run {
            guard let r = registry?.route(query: query),
                  !dedicatedCommandIDs.contains(r.command.id),
                  !r.command.launchesWindow,   // window launchers handled by extensionLauncher
                  r.command.mode == .noView,
                  modelReady || !r.command.requiresModel
            else { return nil }
            return (r.command.id, r.command.title)
        }
        guard let routed,
              let registry = await MainActor.run(body: { registry }),
              let raw = await registry.invokeAsync(commandID: routed.id, query: query)
        else { return nil }
        let parts = raw.components(separatedBy: "\t")
        if parts.count == 2 { return (routed.title, parts[0], parts[1]) }
        return (routed.title, raw, "")
    }

    /// Surfaces a window-launching extension command (manifest `launches_window`)
    /// as a selectable launcher row WITHOUT running its handler — the handler (which
    /// opens the window via `host.window.open`) fires only when the user commits the
    /// row. Pure lookup on the MainActor; no Lua invocation here.
    private static func extensionLauncher(_ query: String) async -> RunnerOutcome? {
        let hits = await MainActor.run { launcherHits(query) }
        return hits.isEmpty ? nil : .extLaunch(hits)
    }

    /// ALL window-launcher hits for `query`: the exact regex-routed command first
    /// (carrying the full query so its handler can pre-fill, e.g. "base64 hello"
    /// → window seeded with "hello"), then partial title/id/keyword discovery
    /// (query "" → blank window). A shared keyword like "add" thus lists every
    /// matching launcher command. Pure lookup; no Lua invocation.
    @MainActor
    private static func launcherHits(_ query: String) -> [ExtLaunchHit] {
        guard let registry else { return [] }
        var hits: [ExtLaunchHit] = []
        if let r = registry.route(query: query),
           !dedicatedCommandIDs.contains(r.command.id),
           r.command.launchesWindow {
            hits.append(ExtLaunchHit(commandID: r.command.id, title: r.command.title,
                                     icon: r.command.icon,
                                     detail: r.command.description ?? "",
                                     query: query))
        }
        for c in registry.launcherMatches(query: query)
        where !hits.contains(where: { $0.commandID == c.id }) {
            hits.append(ExtLaunchHit(commandID: c.id, title: c.title, icon: c.icon,
                                     detail: c.description ?? "", query: ""))
        }
        return hits
    }

    /// Appends launcher rows (e.g. "Add Quicklink") to a `ql`/`qd` listing outcome
    /// so the verb's window-launching management commands stay discoverable next
    /// to the listing instead of being swallowed by it.
    private static func attachLaunchers(_ outcome: RunnerOutcome, query: String) async -> RunnerOutcome {
        let hits = await MainActor.run { launcherHits(query) }
        guard !hits.isEmpty else { return outcome }
        switch outcome {
        case .quicklinks(let links, _): return .quicklinks(links, launchers: hits)
        case .quickdirsMenu(let menu, _): return .quickdirsMenu(menu, launchers: hits)
        default: return outcome
        }
    }

    /// Runs a query in the given `mode`. In `.universal` the runner is a launcher
    /// (apps + deterministic commands). The locked modes feed the whole `input` to
    /// one handler. Translation is no longer a built-in mode — it ships as the
    /// `com.prosper.translate` system extension (reached via its `l `/`t ` prefix
    /// or the ⌥L hotkey, which prefills the launcher).
    static func run(
        _ input: String,
        mode: RunnerMode = .universal
    ) async -> RunnerOutcome {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .ext(let id, let title, _, let arg):
            // Quicklinks locked-mode reuses the native rich listing (same as the
            // inline `ql` path): a non-management query lists/filters links as a
            // proper palette. Management verbs (add/rm/...) still fall through to
            // the Lua handler below. This is rendering-only special-casing; the
            // mode/label mechanism itself is fully manifest-driven.
            if id == "quicklinks.run", let ql = quicklinksLockedListing(trimmed) {
                return ql
            }
            // Quickdirs locked-mode: a dynamic per-quickdir prefix (`arg` = the
            // quickdir name) browses just that directory; the generic `qd ` prefix
            // (arg = nil) shows the picker / token-selects a quickdir. Management
            // verbs fall through to the Lua handler.
            if id == "quickdirs.run", let qd = quickdirsOutcome(arg: arg, rest: trimmed) {
                return qd
            }
            // Native coding agent (`g `): surface a launcher row that opens the agent
            // window and submits the goal on Enter (RunnerPanel routes the sentinel id
            // to AgentController, not the registry). Window launcher, like its old
            // `launches_window` extension shape — never auto-runs per keystroke.
            if id == agentCommandID {
                return .extLaunch([ExtLaunchHit(
                    commandID: agentCommandID, title: "Coding Agent", icon: "sparkles",
                    detail: "Run the typed text as a goal for the local coding agent",
                    query: trimmed)])
            }
            return await runExtension(id: id, title: title, query: trimmed)

        case .universal:
            return await runUniversal(trimmed)
        }
    }

    /// The default launcher routing: deterministic commands first, then an app
    /// search, then a non-actionable "no results" (NOT translation).
    private static func runUniversal(_ trimmed: String) async -> RunnerOutcome {
        // 0a. Meta command (`:q`, `:c`).
        if let meta = MetaCommand.parse(trimmed) {
            return .meta(meta)
        }

        // 0a2. Emoji shortcode (`:name`), if enabled.
        if Preferences.emojiSuggestionsEnabled, trimmed.hasPrefix(":"), trimmed.count > 1 {
            let name = String(trimmed.dropFirst())
            if let match = Emoji.best(forPrefix: name) {
                return .emoji(name: match.name, emoji: match.emoji)
            }
        }

        // 0a3. Quicklinks listing. `ql` alone lists all; `ql <text>` filters by
        //      name/description. Management verbs (add/rm/...) are NOT handled here
        //      — they fall through to the Lua extension (step 3.5) / meta (`ql new`).
        if let ql = quicklinksListing(trimmed) {
            return await attachLaunchers(ql, query: trimmed)
        }

        // 0a4. Quickdirs. `qd` alone shows the picker; `qd <name|prefix> <filter>`
        //      browses that quickdir's subdirectories. Management verbs (add/rm/...)
        //      fall through to the Lua extension (step 3.5).
        if let qd = quickdirsUniversal(trimmed) {
            return await attachLaunchers(qd, query: trimmed)
        }

        // 0b. App launch (`o <app>`). Defensive: normally the UI strips this into
        //     openApp mode, but keep inline routing for direct/test callers.
        if trimmed.lowercased().hasPrefix("o ") {
            let name = String(trimmed.dropFirst(2))
            let matches = await MainActor.run { AppIndex.shared.search(name) }
            return matches.isEmpty ? .noResults(query: name) : .apps(matches)
        }

        // 0c. Shell (`> <cmd>`).
        if trimmed.hasPrefix(">") {
            let cmd = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            let output = await ShellRunner.run(cmd)
            return .shell(command: cmd, output: output)
        }

        // 1. Calc (must contain an operator). System extension first, native
        //    fallback (so a disabled/edited calc extension never loses the
        //    feature). See docs/ADR-002-extensibility.md.
        if let value = await calcResult(trimmed) {
            return .calc(expression: trimmed, value: value)
        }

        // 2. Unit conversion. System extension first, native fallback.
        if let u = await unitResult(trimmed) {
            return .unit(title: u.title, value: u.value, detail: u.detail)
        }

        // 2.5 Time-zone conversion ("2:30 pm HKT in Berlin", "time in Tokyo").
        //     Strictly shaped (needs a resolvable zone on the right), so unit and
        //     currency queries fall through untouched. Native only.
        if let t = TimeConvert.convert(trimmed) {
            return .ext(kind: "Time", value: t.value, detail: t.detail)
        }

        // 3. Currency (async: cached FX). System extension first, native fallback.
        if let c = await currencyResult(trimmed) {
            return .currency(value: c.value, detail: c.detail)
        }

        // 3.45 Window-launching extension commands (manifest `launches_window`):
        //       surface a selectable row that OPENS the extension's window on Enter,
        //       instead of auto-running the handler on every keystroke. Placed before
        //       the generic extension step, which explicitly skips these.
        if let launch = await extensionLauncher(trimmed) {
            return launch
        }

        // 3.5 Generic extension commands (matched by their `match` regex).
        let modelReady = await MLXEngine.shared.isLoaded
        if let e = await extensionResult(trimmed, modelReady: modelReady) {
            return .ext(kind: e.kind, value: e.value, detail: e.detail)
        }

        // 4. Unified launcher search — apps + quicklinks + bookmarks scored on ONE
        //    ladder and merged (Alfred-style), replacing the old exclusive chain
        //    (quicklink-name → apps → inline-bookmarks) where the first non-empty
        //    source won. That chain let a stray fuzzy app match shadow an exact
        //    bookmark, so "pods" and "pods)" returned different results. Merging
        //    fixes that: a real substring/prefix hit in any source outranks a fuzzy
        //    hit in another. No match → noResults (translation lives behind `l `).
        if let merged = await unifiedSearch(trimmed) {
            return merged
        }

        return .noResults(query: trimmed)
    }

    /// The merged, ranked launcher result for a bare query, or nil when nothing
    /// matched. Gathers apps + quicklinks (always) and bookmarks (opt-in via the
    /// bookmarks extension's `show_in_launcher`), scores every candidate on the
    /// shared `SearchScore` ladder, and returns the top slice as `.search`.
    ///
    /// Hot path. Called per query change (after a 0.25s debounce). Budget design:
    ///   • main thread: ONE actor hop for cheap COW snapshots — no scoring on main.
    ///   • CPU scoring runs off-main (this func is nonisolated) and is allocation-
    ///     light (lowercased names precomputed in AppIndex; bookmark haystacks
    ///     precomputed in Lua). Measured ~1ms release / ~10ms debug for a 4800-
    ///     candidate worst case (see `SearchScoreTests.testScoringLargeSetIsFast`).
    ///   • the bookmark Lua call overlaps app/quicklink scoring via `async let`.
    private static func unifiedSearch(_ trimmed: String) async -> RunnerOutcome? {
        let q = trimmed.lowercased()
        let tokens = q.split(whereSeparator: { $0 == " " }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        // ONE main-actor hop snapshots every source's data (COW arrays — cheap to
        // hand to the off-main scorer below) plus the bookmark opt-in. Scoring then
        // runs on the cooperative pool (this func is nonisolated), never blocking
        // the main thread on the per-keystroke hot path.
        let snap = await MainActor.run { () -> Snapshot in
            let (apps, lower) = AppIndex.shared.entriesWithLower()
            let reg = registry
            let bmOn = reg?.prefValue(extensionID: Self.bookmarksID, key: "show_in_launcher") == "true"
            return Snapshot(apps: apps, lower: lower, links: QuicklinkStore.all(),
                            registry: reg, bookmarksEnabled: bmOn,
                            commands: reg?.commandSearchEntries() ?? [])
        }
        let alias = AppIndex.aliasTarget(for: q) // nonisolated static — no hop

        // Overlap the bookmark Lua call (off-main lane + JSON decode) with the CPU
        // scoring of apps/quicklinks below, instead of serializing after them.
        async let bookmarkRows = fetchBookmarkRows(snap.registry, query: trimmed,
                                                    enabled: snap.bookmarksEnabled)

        var hits: [SearchHit] = []

        // Apps (alias support — "settings" → System Settings). Lowercased names are
        // precomputed in AppIndex, so this loop allocates no per-app strings.
        for (app, lower) in zip(snap.apps, snap.lower) {
            if let s = SearchScore.score(q: q, tokens: tokens, matchText: lower,
                                         tieLen: lower.count, isAlias: alias == lower) {
                hits.append(SearchHit(kind: .app, title: app.name, subtitle: "",
                                      score: s, appURL: app.url))
            }
        }

        // Quicklinks — matched on NAME (same predictability as the old bare path).
        // "gh some/repo": a templated link takes trailing args, so when the full
        // query doesn't match the name we fall back to an EXACT first-token match
        // (exact, so two-word app searches aren't shadowed) — Enter opens the link
        // with the rest as its argument.
        let firstToken = tokens.first
        for link in snap.links {
            let name = link.name.lowercased()
            var s = SearchScore.score(q: q, tokens: tokens, matchText: name, tieLen: name.count)
            if s == nil, tokens.count > 1, name == firstToken {
                s = SearchScore.score(q: name, tokens: [name], matchText: name, tieLen: name.count)
            }
            if let s {
                let sub = link.description.isEmpty ? link.target : link.description
                hits.append(SearchHit(kind: .quicklink, title: link.name, subtitle: sub,
                                      score: s, openTarget: link.target, quicklink: link))
            }
        }

        // Bookmarks (opt-in). Scored over the precomputed lowercased haystack
        // (`hay`) the Lua matcher already built, tie-broken on title length so a
        // long URL doesn't penalize ranking.
        for b in await bookmarkRows {
            if let s = SearchScore.score(q: q, tokens: tokens, matchText: b.hay,
                                         tieLen: b.title.count) {
                let sub = b.folder.isEmpty ? b.browser : "\(b.browser) · \(b.folder)"
                hits.append(SearchHit(kind: .bookmark, title: b.title, subtitle: sub,
                                      score: s, openTarget: b.url))
            }
        }

        // Extension commands — discoverable by the contributing extension's name or
        // any command keyword (haystack precomputed in the snapshot), so "translate"
        // or "lid" surfaces the matching commands as selectable rows even when the
        // user never typed the `l `/`lid ` prefix. Enter behavior (run vs enter the
        // command's input mode) is carried per hit and resolved in the UI.
        for c in snap.commands {
            if let s = SearchScore.score(q: q, tokens: tokens, matchText: c.haystack,
                                         tieLen: c.tieLen) {
                hits.append(SearchHit(kind: .command, title: c.title,
                                      subtitle: c.extensionTitle, score: s,
                                      commandID: c.commandID, commandIcon: c.icon,
                                      commandLaunchesWindow: c.launchesWindow))
            }
        }

        guard !hits.isEmpty else { return nil }
        hits.sort(by: SearchScore.before)
        return .search(Array(hits.prefix(12)))
    }

    /// Bookmark extension id, shared by the snapshot + fetch.
    private static let bookmarksID = "com.prosper.bookmarks"
    /// Reused across keystrokes — `JSONDecoder()` is cheap but not free to spin up.
    private static let bookmarkDecoder = JSONDecoder()

    /// A single main-actor snapshot of the data the unified scorer needs.
    private struct Snapshot {
        let apps: [AppEntry]
        let lower: [String]
        let links: [QuicklinkHit]
        let registry: ExtensionRegistry?
        let bookmarksEnabled: Bool
        let commands: [ExtensionRegistry.CommandSearchEntry]
    }

    /// Ranked bookmark rows (off-main Lua lane + decode), or [] when bookmarks are
    /// disabled / the query is too short / the cache is empty / JSON is malformed.
    private static func fetchBookmarkRows(_ registry: ExtensionRegistry?, query: String,
                                          enabled: Bool) async -> [BookmarkRow] {
        guard enabled, query.count >= 2, let registry else { return [] }
        guard let json = await registry.callExtensionStringAsync(
                  extensionID: bookmarksID, function: "bookmarks_search", args: [query, "200"]),
              let data = json.data(using: .utf8),
              let rows = try? bookmarkDecoder.decode([BookmarkRow].self, from: data)
        else { return [] }
        return rows
    }

    /// One bookmark row as returned by the bookmarks extension's `bookmarks_search`.
    /// `hay` is the precomputed lowercased "title url folder" used for scoring.
    private struct BookmarkRow: Decodable {
        let title: String
        let url: String
        let folder: String
        let browser: String
        let hay: String
    }

    /// Returns a `.quicklinks` outcome when `trimmed` is the `ql` verb. `ql` alone
    /// lists all saved links; `ql <text>` filters. Returns nil for management verbs
    /// (add/rm/remove/del/delete/new/create/help), which are handled elsewhere.
    private static func quicklinksListing(_ trimmed: String) -> RunnerOutcome? {
        let lower = trimmed.lowercased()
        guard lower == "ql" || lower.hasPrefix("ql ") else { return nil }
        let rest = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let verb = rest.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        // Management verbs fall through to the Lua extension / meta (`ql new`).
        let management: Set<String> = ["add", "rm", "remove", "del", "delete", "new", "create", "help"]
        if management.contains(verb) { return nil }
        // `ql list` / `ql ls` mean "show all" — treat as an empty filter, not a
        // search for the literal text "list".
        if rest.lowercased() == "list" || rest.lowercased() == "ls" {
            return .quicklinks(QuicklinkStore.all(), launchers: [])
        }
        return .quicklinks(searchKeepingArgs(rest), launchers: [])
    }

    /// `ql <name> <args>`: a full-text search over "name args" matches nothing,
    /// which made the selected link vanish the moment arguments were typed (and
    /// Enter a no-op). When the full search is empty, list links whose name
    /// matches the first token; the trailing text is parsed as the `{query}`
    /// argument at open time (`RunnerPanel.quicklinkArguments`).
    private static func searchKeepingArgs(_ text: String) -> [QuicklinkHit] {
        let hits = QuicklinkStore.search(text)
        if !hits.isEmpty { return hits }
        guard text.contains(" "), let first = text.split(separator: " ").first else { return hits }
        return QuicklinkStore.nameMatches(String(first))
    }

    /// Quicklinks listing for the LOCKED `ql` mode, where the `ql ` prefix is
    /// already stripped so `rest` is the bare filter. Empty → all; otherwise a
    /// name/description search. Returns nil for management verbs (add/rm/...) so
    /// they fall through to the Lua handler.
    private static func quicklinksLockedListing(_ rest: String) -> RunnerOutcome? {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        let verb = trimmed.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        let management: Set<String> = ["add", "rm", "remove", "del", "delete", "new", "create", "help"]
        if management.contains(verb) { return nil }
        if trimmed.lowercased() == "list" || trimmed.lowercased() == "ls" || trimmed.isEmpty {
            return .quicklinks(QuicklinkStore.all(), launchers: [])
        }
        return .quicklinks(searchKeepingArgs(trimmed), launchers: [])
    }

    /// Universal-mode quickdirs entry: matches the bare `qd` verb (and `qd …`),
    /// stripping the prefix and delegating to `quickdirsOutcome`. Returns nil when
    /// the query isn't a quickdirs verb so other routing continues.
    private static func quickdirsUniversal(_ trimmed: String) -> RunnerOutcome? {
        let lower = trimmed.lowercased()
        guard lower == "qd" || lower.hasPrefix("qd ") else { return nil }
        let rest = lower == "qd" ? "" : String(trimmed.dropFirst(3))
        return quickdirsOutcome(arg: nil, rest: rest)
    }

    /// Core quickdirs routing shared by the universal verb and the locked modes.
    /// - `arg` non-nil: locked into that quickdir — `rest` is the subdirectory
    ///   filter, surfaced as a browsable `.quickdirs` listing.
    /// - `arg` nil (generic `qd`): empty / `list` shows the picker; a leading
    ///   token selecting a quickdir (by name or prefix) browses it; management
    ///   verbs (add/rm/...) return nil to fall through to the Lua handler.
    private static func quickdirsOutcome(arg: String?, rest: String) -> RunnerOutcome? {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if let arg, let cfg = QuickdirStore.config(named: arg) {
            return .quickdirs(QuickdirStore.listing(config: cfg, filter: trimmed))
        }
        let verb = trimmed.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        let management: Set<String> = ["add", "rm", "remove", "del", "delete", "new", "create", "help"]
        if management.contains(verb) { return nil }
        if trimmed.isEmpty || trimmed.lowercased() == "list" || trimmed.lowercased() == "ls" {
            return .quickdirsMenu(QuickdirStore.all(), launchers: [])
        }
        // A leading token may name/prefix a configured quickdir → browse it.
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        if let cfg = QuickdirStore.config(forToken: parts[0]) {
            let filter = parts.count > 1 ? parts[1] : ""
            return .quickdirs(QuickdirStore.listing(config: cfg, filter: filter))
        }
        // Otherwise filter the picker by name.
        let menu = QuickdirStore.all().filter { $0.name.lowercased().contains(trimmed.lowercased()) }
        return .quickdirsMenu(menu.isEmpty ? QuickdirStore.all() : menu, launchers: [])
    }

    /// Routes the whole `query` to a specific extension command id (locked mode).
    private static func runExtension(id: String, title: String, query: String) async -> RunnerOutcome {
        let modelReady = await MLXEngine.shared.isLoaded
        let info: (requiresModel: Bool, prefix: String?) = await MainActor.run {
            let c = registry?.command(id: id)?.command
            return (c?.requiresModel ?? false, c?.prefix)
        }
        if info.requiresModel && !modelReady {
            // The model is loaded lazily (it is NOT preloaded just because a
            // model-requiring extension like Translate is enabled — that would
            // cost ~4 GB at idle). The user has explicitly entered this locked
            // command mode, so AWAIT the load here (the runner is already showing
            // its loading spinner) and then fall through to run — instead of
            // surfacing a dead-end "pending" row that never refreshes on its own
            // and forces a manual cancel + retry. `load()` is coalesced +
            // idempotent. On failure we fall through; the handler then declines
            // (no model) and the runner shows its empty state.
            try? await MLXEngine.shared.load { _, _ in }
        }
        // The mode lock strips the manifest prefix from the visible query; restore
        // it before invoking the handler so the extension's Lua `match`/verb parser
        // sees the same string it would in the universal launcher (e.g. "ql add x").
        let handlerQuery = (info.prefix ?? "") + query
        guard let registry = await MainActor.run(body: { registry }),
              let raw = await registry.invokeAsync(commandID: id, query: handlerQuery) else {
            return .ext(kind: title, value: "", detail: "")
        }
        // A handler may return a declarative component tree (host.ui.render(...))
        // to be rendered inline as rich native UI. Detect it cheaply (JSON object
        // carrying a "type" discriminator) and decode; anything else is a plain
        // value / "value\tdetail" string row.
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRaw.hasPrefix("{"), trimmedRaw.contains("\"type\""),
           let node = try? ExtensionViewNode.decode(json: trimmedRaw) {
            return .extView(node)
        }
        let parts = raw.components(separatedBy: "\t")
        if parts.count == 2 { return .ext(kind: title, value: parts[0], detail: parts[1]) }
        return .ext(kind: title, value: raw, detail: "")
    }

}
