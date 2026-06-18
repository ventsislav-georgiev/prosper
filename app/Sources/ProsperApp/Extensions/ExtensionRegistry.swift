import Foundation
import LuaRuntime
import os

/// One installed extension's live state: its validated manifest, its disk
/// location, whether it is enabled, and a lazily-created Lua runtime.
final class ExtensionRecord {
    let loaded: LoadedExtension
    var enabled: Bool
    /// Created on first activation, torn down on disable/reset/reload.
    var runtime: LuaRuntime?

    init(loaded: LoadedExtension, enabled: Bool) {
        self.loaded = loaded
        self.enabled = enabled
    }

    var id: String { loaded.id }
    var manifest: ExtensionManifest { loaded.manifest }
    var isSystem: Bool { loaded.isSystem }
}

enum ExtensionError: Error, Equatable {
    case notFound(String)
    case cannotUninstallSystem(String)
    case cannotResetUserExtension(String)
    case noPristineCopy(String)
}

/// Off-main Lua VM cache for commands that call async host APIs (http / llm /
/// shell). `LuaRuntime` is single-thread-confined and `ExtensionHost.awaitSync`
/// blocks its caller, so these VMs must live OFF the main thread and apart from
/// the MainActor `invokeSync` VMs — otherwise the bridge would deadlock the UI.
/// One dedicated serial queue owns the cache and every VM created on it.
final class AsyncExtensionRuntimes: @unchecked Sendable {

    /// Everything needed to (re)build one VM, captured on the MainActor side.
    struct Spec: Sendable {
        let extensionID: String
        let entryURL: URL
        let handler: String
        let callTimeout: TimeInterval
        /// Bundled system extension → privileged host surface (shell/agent).
        let privileged: Bool
    }

    private let queue = DispatchQueue(label: "com.prosper.extensions.async")
    private var cache: [String: LuaRuntime] = [:]   // confined to `queue`
    private let services: ExtensionHostServices

    init(services: ExtensionHostServices) {
        self.services = services
    }

    /// Run `spec.handler(args…)` on the async lane, building + caching the VM on
    /// first use. Returns the handler's string result, or nil to decline / error.
    func invoke(_ spec: Spec, args: [String]) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            queue.async { cont.resume(returning: self.callOnQueue(spec, args: args)) }
        }
    }

    private func callOnQueue(_ spec: Spec, args: [String]) -> String? {
        do {
            let rt: LuaRuntime
            if let existing = cache[spec.extensionID] {
                rt = existing
            } else {
                rt = try LuaRuntime()
                try ExtensionHost(extensionID: spec.extensionID, services: services,
                                  callTimeout: spec.callTimeout,
                                  privileged: spec.privileged).install(into: rt)
                let source = try String(contentsOf: spec.entryURL, encoding: .utf8)
                try rt.run(source, name: "@\(spec.extensionID)")
                cache[spec.extensionID] = rt
            }
            return try rt.callGlobal(spec.handler, args)
        } catch {
            return nil
        }
    }

    func invalidate(id: String) { queue.async { self.cache[id] = nil } }
    func invalidateAll() { queue.async { self.cache.removeAll() } }
}

/// Discovers, validates, and routes to extensions. Static-first + lazy: every
/// manifest is parsed up front to build a `(trigger → extension id)` table, but
/// each extension's Lua VM is spawned only when one of its triggers fires.
/// See docs/ADR-002-extensibility.md.
@MainActor
final class ExtensionRegistry: ObservableObject {

    /// All discovered extensions, system first, in discovery order.
    @Published private(set) var records: [ExtensionRecord] = []

    private let systemDir: URL?
    private let userDir: URL
    /// Pristine copies of system extensions, used by `reset(id:)`.
    private let systemPristineDir: URL?
    private let hostVersion: String
    private let defaults: UserDefaults
    /// Native capabilities exposed to extensions via `host.*`.
    private let services: ExtensionHostServices
    private let callTimeout: TimeInterval
    /// Off-main VM lane for commands that call async host APIs (http/llm/shell).
    private let asyncRuntimes: AsyncExtensionRuntimes
    private let log = Logger(subsystem: "com.prosper.app", category: "extensions")

    private static let disabledKey = "disabledExtensionIDs"

    /// Command routing: id → record, plus an ordered list carrying compiled
    /// `match` regexes for query-prefix dispatch.
    private var commandByID: [String: (record: ExtensionRecord, command: CommandContribution)] = [:]
    private var matchRoutes: [(regex: NSRegularExpression, command: CommandContribution, record: ExtensionRecord)] = []

    init(
        systemDir: URL? = ExtensionRegistry.bundledSystemDir,
        userDir: URL = ExtensionRegistry.defaultUserDir,
        hostVersion: String = ExtensionRegistry.bundleVersion,
        defaults: UserDefaults = .standard,
        services: ExtensionHostServices = LiveExtensionHostServices.shared,
        callTimeout: TimeInterval = ExtensionHost.defaultCallTimeout
    ) {
        self.systemDir = systemDir
        self.systemPristineDir = systemDir
        self.userDir = userDir
        self.hostVersion = hostVersion
        self.defaults = defaults
        self.services = services
        self.callTimeout = callTimeout
        self.asyncRuntimes = AsyncExtensionRuntimes(services: services)
    }

    /// Bundled system-extensions directory. Lives in the app bundle's
    /// Contents/Resources (`Bundle.main`); scripts/bundle.sh copies it there.
    /// We deliberately do NOT use SwiftPM's `Bundle.module`: its generated
    /// accessor looks at the .app root, where a resource bundle can't be placed
    /// without breaking the code-signature seal (see Package.swift).
    static var bundledSystemDir: URL? {
        Bundle.main.url(forResource: "extensions", withExtension: nil)
    }

    static var defaultUserDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/prosper/extensions")
    }

    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
    }

    // MARK: - Discovery

    /// Seed system extensions from the pristine bundled dir into the editable
    /// userDir. A missing one is copied in. An existing one is refreshed only when
    /// the bundled copy has a NEWER manifest version — so shipped updates to a
    /// system extension (new commands, a runner-mode `prefix`, bug fixes) reach
    /// users on upgrade. User edits to a system extension therefore persist within
    /// a version and reset on a version bump; a user can still `reset(id:)` anytime.
    private func seedSystemExtensions() {
        guard let pristineRoot = systemPristineDir else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        guard let children = try? fm.contentsOfDirectory(
            at: pristineRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let dest = userDir.appendingPathComponent(child.lastPathComponent, isDirectory: true)
            // Development / unstamped bundles report host 0.0.0. There, ALWAYS
            // overwrite from the bundle — the source tree is the single source of
            // truth, and a stale seeded copy (an old init.lua left from a previous
            // build) would otherwise silently shadow local edits and waste hours.
            let isDevHost = SemanticVersion(hostVersion) == SemanticVersion("0.0.0")
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: child, to: dest)
            } else if isDevHost {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: child, to: dest)
            } else if let bundled = manifestVersion(at: child),
                      let installed = manifestVersion(at: dest),
                      installed < bundled {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: child, to: dest)
                log.info("refreshed system extension \(child.lastPathComponent, privacy: .public) to newer bundled version")
            }
        }
    }

    /// Reads just the `version` from an extension directory's `extension.toml`,
    /// without a full validating load (used by seeding to compare versions).
    private func manifestVersion(at dir: URL) -> SemanticVersion? {
        let toml = dir.appendingPathComponent("extension.toml")
        guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("version") else { continue }
            // version = "1.2.3"  → grab the quoted value
            guard let open = t.firstIndex(of: "\""),
                  let close = t[t.index(after: open)...].firstIndex(of: "\"") else { return nil }
            return SemanticVersion(String(t[t.index(after: open)..<close]))
        }
        return nil
    }

    /// The set of directory names that exist under the pristine system dir.
    private func systemFolderNames() -> Set<String> {
        guard let pristineRoot = systemPristineDir,
              let children = try? FileManager.default.contentsOfDirectory(
                at: pristineRoot, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return Set(children.compactMap { child -> String? in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            return child.lastPathComponent
        })
    }

    /// (Re)scan the editable userDir (after seeding from pristine), parse +
    /// validate manifests, and rebuild the routing table. Safe to call repeatedly.
    func discover() {
        seedSystemExtensions()
        let systemNames = systemFolderNames()

        var found: [ExtensionRecord] = []
        let disabled = disabledIDs()
        var seen = Set<String>()

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: userDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            records = found
            rebuildRoutes()
            asyncRuntimes.invalidateAll()
            return
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let isSystem = systemNames.contains(entry.lastPathComponent)
            do {
                let loaded = try ExtensionLoader.load(
                    directory: entry, isSystem: isSystem, hostVersion: hostVersion)
                guard !seen.contains(loaded.id) else {
                    log.warning("duplicate extension id \(loaded.id, privacy: .public), skipping \(entry.path, privacy: .public)")
                    continue
                }
                seen.insert(loaded.id)
                found.append(ExtensionRecord(loaded: loaded, enabled: !disabled.contains(loaded.id)))
            } catch {
                log.error("failed to load extension at \(entry.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        records = found
        rebuildRoutes()
        asyncRuntimes.invalidateAll()   // drop stale off-main VMs on rescan
    }

    private func rebuildRoutes() {
        commandByID.removeAll(keepingCapacity: true)
        matchRoutes.removeAll(keepingCapacity: true)
        for record in records where record.enabled {
            for command in record.manifest.contributes?.allCommands ?? [] {
                commandByID[command.id] = (record, command)
                if let pattern = command.match,
                   let regex = try? NSRegularExpression(pattern: pattern) {
                    matchRoutes.append((regex, command, record))
                }
            }
        }
    }

    // MARK: - Routing

    /// Resolve a palette query to the first enabled extension command whose
    /// `match` regex accepts it. Pure lookup — does not spawn the Lua VM.
    func route(query: String) -> (record: ExtensionRecord, command: CommandContribution)? {
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        for r in matchRoutes where r.regex.firstMatch(in: query, range: range) != nil {
            return (r.record, r.command)
        }
        return nil
    }

    func command(id: String) -> (record: ExtensionRecord, command: CommandContribution)? {
        commandByID[id]
    }

    /// Window-launching commands (manifest `launches_window`) discoverable by a
    /// PARTIAL query: a prefix of the title, id, or any keyword (case-insensitive).
    /// This is what lets "base" surface the Base64 command before the regex `match`
    /// verb is fully typed — general discovery for every launcher extension, not a
    /// base64 special case. Pure lookup; does not spawn the Lua VM. Title-prefix
    /// matches rank ahead of keyword-only matches.
    func launcherMatches(query: String) -> [CommandContribution] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var titleHits: [CommandContribution] = []
        var otherHits: [CommandContribution] = []
        for record in records where record.enabled {
            for command in record.manifest.contributes?.allCommands ?? []
            where command.launchesWindow {
                if command.title.lowercased().hasPrefix(q) {
                    titleHits.append(command)
                } else if ([command.id] + (command.keywords ?? []))
                    .contains(where: { $0.lowercased().hasPrefix(q) }) {
                    otherHits.append(command)
                }
            }
        }
        return titleHits + otherHits
    }

    /// A manifest-declared runner-mode trigger: the leading prefix that locks the
    /// universal launcher into an extension command, plus the chip label/icon.
    struct ModeTriggerSpec: Sendable, Equatable {
        let prefix: String
        let commandID: String
        let title: String
        let icon: String
        /// Display name of the contributing extension, used to disambiguate
        /// identically-titled commands in the shortcut target picker (e.g. several
        /// "Run Shell" commands → "Run Shell · gh-payhawk"). Empty for dynamic
        /// triggers whose titles are already unique (a quickdir's own name).
        var extensionTitle: String = ""
        /// Opaque argument carried into the locked mode (e.g. which quickdir a
        /// dynamic prefix selects). nil for ordinary manifest triggers.
        var arg: String? = nil
    }

    /// Provider of runtime mode triggers contributed by an extension from its own
    /// data (not the static manifest) — e.g. quickdirs giving each configured
    /// directory its own activation prefix. Set by the app; consulted live in
    /// `modeTriggers()` so edits take effect without a rescan.
    var dynamicModeProvider: (@MainActor () -> [ModeTriggerSpec])?

    /// Runner-mode triggers contributed by enabled extensions (manifest `prefix`)
    /// plus any dynamic triggers from `dynamicModeProvider`, longest-prefix-first
    /// so a more specific trigger wins over a shorter overlap. This is what lets
    /// extensions surface as labelled modes without host edits.
    func modeTriggers() -> [ModeTriggerSpec] {
        var out: [ModeTriggerSpec] = []
        for record in records where record.enabled {
            for command in record.manifest.contributes?.allCommands ?? [] {
                for prefix in command.allPrefixes where !prefix.isEmpty {
                    out.append(ModeTriggerSpec(
                        prefix: prefix,
                        commandID: command.id,
                        title: command.title,
                        icon: command.icon ?? "puzzlepiece.extension",
                        extensionTitle: record.manifest.extension.title))
                }
            }
        }
        out.append(contentsOf: dynamicModeProvider?() ?? [])
        return out.sorted { $0.prefix.count > $1.prefix.count }
    }

    /// Resolves a custom dynamic placeholder `{name …}` contributed by an enabled
    /// extension (manifest `[[contributes.placeholders]]`). Invokes the declared
    /// Lua handler synchronously with the raw token body and returns its string,
    /// or nil when no enabled extension contributes `name`. Used by the snippet
    /// engine; resolution happens only when a snippet actually uses the placeholder
    /// (never on the per-keystroke hot path).
    func resolvePlaceholder(name: String, raw: String) -> String? {
        let lower = name.lowercased()
        for record in records where record.enabled {
            for p in record.manifest.contributes?.allPlaceholders ?? []
            where p.name.lowercased() == lower {
                if let value = callExtensionString(extensionID: record.id, function: p.handler, arg: raw) {
                    return value
                }
            }
        }
        return nil
    }

    /// True when any ENABLED extension declares a command that `requires = ["model"]`
    /// (i.e. depends on `host.llm`). Drives the host's model-unload policy: the
    /// local LLM stays resident while at least one such extension is enabled, even
    /// if inline autocomplete is off, and unloads only once every LLM consumer is
    /// disabled. See AppDelegate.shouldKeepModelResident.
    func anyEnabledRequiresModel() -> Bool {
        for record in records where record.enabled {
            for command in record.manifest.contributes?.allCommands ?? []
            where command.requiresModel {
                return true
            }
        }
        return false
    }

    /// Lua handler global for a command id: non-alphanumerics → '_'
    /// ("calc.eval" → "calc_eval"). See Resources/extensions/*/init.lua.
    static func handlerName(for commandID: String) -> String {
        String(commandID.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    /// Invoke a command's Lua handler synchronously, returning its string result
    /// or nil to decline (caller falls back to native / next command).
    ///
    /// SYNCHRONOUS — safe only for commands that do NOT call async host APIs
    /// (calc/unit/base64/emoji/meta). Commands that call `host.llm`/`host.shell`
    /// must use the off-main async lane so the bridge cannot block the caller.
    func invokeSync(commandID: String, query: String) -> String? {
        guard let (record, command) = command(id: commandID), record.enabled else { return nil }
        do {
            let rt = try activate(record)
            let result = try rt.callGlobal(Self.handlerName(for: command.id), [query])
            if result != nil, record.isSystem { AnalyticsStore.bumpUsage(extensionID: record.id) }
            return result
        } catch {
            log.error("extension \(record.id, privacy: .public) command \(command.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Invoke a command's Lua handler on the OFF-MAIN async lane, returning its
    /// string result or nil to decline. Use this for commands that call async
    /// host APIs (`host.http` / `host.llm` / `host.shell`) — the bridge blocks
    /// its worker thread, which must never be the main thread. The async lane
    /// keeps a separate VM cache (see `AsyncExtensionRuntimes`).
    func invokeAsync(commandID: String, query: String) async -> String? {
        guard let (record, command) = command(id: commandID), record.enabled else { return nil }
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id,
            entryURL: record.loaded.entryURL,
            handler: Self.handlerName(for: command.id),
            callTimeout: callTimeout,
            privileged: record.isSystem
        )
        let result = await asyncRuntimes.invoke(spec, args: [query])
        if result != nil, record.isSystem { AnalyticsStore.bumpUsage(extensionID: record.id) }
        return result
    }

    /// Render a `mode = "view"` command on the OFF-MAIN async lane (for views
    /// that call async host APIs). Mirrors `renderView` but does not block.
    func renderViewAsync(commandID: String, query: String = "") async -> ExtensionViewNode? {
        guard let (_, command) = command(id: commandID), command.mode == .view else { return nil }
        guard let json = await invokeAsync(commandID: commandID, query: query) else { return nil }
        do {
            return try ExtensionViewNode.decode(json: json)
        } catch {
            log.error("view \(commandID, privacy: .public) returned invalid JSON: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Dispatch a UI action on the OFF-MAIN async lane. The handler may call
    /// async host APIs (http/llm/shell); the panel shows a spinner meanwhile.
    func dispatchActionAsync(
        commandID: String, actionID: String, value: String?, formValues: [String: String]
    ) async -> ExtensionViewNode? {
        guard let (record, command) = command(id: commandID), record.enabled else { return nil }
        let formJSON = (try? JSONEncoder().encode(formValues))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id,
            entryURL: record.loaded.entryURL,
            handler: Self.handlerName(for: command.id) + "_action",
            callTimeout: callTimeout,
            privileged: record.isSystem
        )
        guard let json = await asyncRuntimes.invoke(spec, args: [actionID, value ?? "", formJSON]) else { return nil }
        return try? ExtensionViewNode.decode(json: json)
    }

    // MARK: - Settings sections (declarative settings UI)

    /// (record, section) for every enabled extension section with `placement`
    /// ("sidebar" | "inline"). Pure lookup; does not spawn a VM.
    func settingsSections(placement: String) -> [(record: ExtensionRecord, section: SettingsSection)] {
        var out: [(ExtensionRecord, SettingsSection)] = []
        for record in records where record.enabled {
            for section in record.manifest.contributes?.allSettingsSections ?? []
            where (section.placement ?? "sidebar") == placement {
                out.append((record, section))
            }
        }
        return out
    }

    /// Locate a specific (record, section) by ids.
    func settingsSection(extensionID: String, sectionID: String) -> (ExtensionRecord, SettingsSection)? {
        guard let record = record(id: extensionID), record.enabled else { return nil }
        guard let section = (record.manifest.contributes?.allSettingsSections ?? [])
            .first(where: { $0.id == sectionID }) else { return nil }
        return (record, section)
    }

    /// Tier B: render a dynamic section via the extension's `settings_render`
    /// handler on the async lane. Returns the decoded tree, or nil.
    func renderSettingsAsync(extensionID: String, sectionID: String,
                             state: String = "{}") async -> SettingsUI? {
        guard let record = record(id: extensionID), record.enabled else { return nil }
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id, entryURL: record.loaded.entryURL,
            handler: "settings_render", callTimeout: callTimeout, privileged: record.isSystem)
        guard let json = await asyncRuntimes.invoke(spec, args: [sectionID, state]) else { return nil }
        return try? SettingsUI.decode(json: json)
    }

    /// Tier B: dispatch a settings interaction to `settings_action`; returns the
    /// next tree (nil → caller keeps the current one / re-renders).
    func dispatchSettingsActionAsync(extensionID: String, sectionID: String,
                                     actionID: String, value: String?,
                                     formValues: [String: String]) async -> SettingsUI? {
        guard let record = record(id: extensionID), record.enabled else { return nil }
        let formJSON = (try? JSONEncoder().encode(formValues))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id, entryURL: record.loaded.entryURL,
            handler: "settings_action", callTimeout: callTimeout, privileged: record.isSystem)
        guard let json = await asyncRuntimes.invoke(
            spec, args: [sectionID, actionID, value ?? "", formJSON]) else { return nil }
        return try? SettingsUI.decode(json: json)
    }

    // MARK: - View commands (declarative UI, ADR-002 §D7)

    /// Render a `mode = "view"` command: invoke its handler (which returns a JSON
    /// component tree via `host.ui.render`) and decode it into a native view
    /// model. Returns nil if the command isn't a view, declines, or the handler
    /// produced invalid JSON.
    func renderView(commandID: String, query: String = "") -> ExtensionViewNode? {
        guard let (_, command) = command(id: commandID), command.mode == .view else { return nil }
        guard let json = invokeSync(commandID: commandID, query: query) else { return nil }
        do {
            return try ExtensionViewNode.decode(json: json)
        } catch {
            log.error("view \(commandID, privacy: .public) returned invalid JSON: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Dispatch a UI action back into the extension. The handler is the command
    /// handler name suffixed with `_action`; it receives
    /// `(actionID, value, formJSON)` and may return a new component tree (for
    /// intra-extension navigation) or nil.
    func dispatchAction(
        commandID: String, actionID: String, value: String?, formValues: [String: String]
    ) -> ExtensionViewNode? {
        guard let (record, command) = command(id: commandID), record.enabled else { return nil }
        do {
            let rt = try activate(record)
            let handler = Self.handlerName(for: command.id) + "_action"
            let formJSON = (try? JSONEncoder().encode(formValues))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            guard let json = try rt.callGlobal(handler, [actionID, value ?? "", formJSON]) else { return nil }
            return try? ExtensionViewNode.decode(json: json)
        } catch {
            log.error("action \(actionID, privacy: .public) on \(commandID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Host-window callbacks (host.window.open)

    /// Call a bare global Lua function `function(arg)` in an extension's MainActor
    /// VM and return its string result. Powers `converter` panes opened via
    /// `host.window.open`: each keystroke runs the declared forward/backward
    /// transform synchronously (cheap, on-device string work — base64, hex, …).
    /// Returns nil to decline (missing extension / error), which the UI treats as
    /// an empty pane.
    func callExtensionString(extensionID: String, function: String, arg: String) -> String? {
        guard let record = record(id: extensionID), record.enabled else { return nil }
        do {
            let rt = try activate(record)
            return try rt.callGlobal(function, [arg])
        } catch {
            log.error("window fn \(function, privacy: .public) on \(extensionID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Call a global Lua function in an extension on the OFF-MAIN async lane and
    /// decode its result as a component tree (for host-window button actions that
    /// may touch async host APIs). Returns nil to decline / on bad JSON.
    func callExtensionViewAsync(extensionID: String, function: String, args: [String]) async -> ExtensionViewNode? {
        guard let record = record(id: extensionID), record.enabled else { return nil }
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id,
            entryURL: record.loaded.entryURL,
            handler: function,
            callTimeout: callTimeout,
            privileged: record.isSystem
        )
        guard let json = await asyncRuntimes.invoke(spec, args: args) else { return nil }
        return try? ExtensionViewNode.decode(json: json)
    }

    // MARK: - Lazy activation

    /// Return the extension's runtime, creating + loading its entry script on
    /// first use. Host API wiring is layered on in task #22.
    func activate(_ record: ExtensionRecord) throws -> LuaRuntime {
        if let rt = record.runtime { return rt }
        let rt = try LuaRuntime()
        try ExtensionHost(extensionID: record.id, services: services, callTimeout: callTimeout,
                          privileged: record.isSystem)
            .install(into: rt)
        let source = try String(contentsOf: record.loaded.entryURL, encoding: .utf8)
        try rt.run(source, name: "@\(record.id)")
        record.runtime = rt
        return rt
    }

    // MARK: - Management

    func record(id: String) -> ExtensionRecord? { records.first { $0.id == id } }

    /// Fired after an extension's enabled state changes, so the host can reconcile
    /// side effects — notably model residency (an LLM extension toggling on/off
    /// changes whether the local model must stay loaded). Set by AppDelegate.
    var onEnabledChanged: (@MainActor () -> Void)?

    func setEnabled(_ enabled: Bool, id: String) throws {
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        record.enabled = enabled
        if !enabled { record.runtime = nil }   // tear down VM when disabled
        asyncRuntimes.invalidate(id: id)        // and its off-main twin
        persistDisabled()
        rebuildRoutes()
        objectWillChange.send()
        onEnabledChanged?()
    }

    /// Uninstall a user extension. System extensions cannot be uninstalled
    /// (only disabled) — see ADR-002 system-extension semantics.
    func uninstall(id: String) throws {
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        guard !record.isSystem else { throw ExtensionError.cannotUninstallSystem(id) }
        try FileManager.default.removeItem(at: record.loaded.directory)
        discover()
    }

    /// Install (or upgrade) a user extension by copying a validated source
    /// directory into the user extensions dir. The source must contain an
    /// `extension.toml`; it is validated against the host before any copy.
    @discardableResult
    func installLocal(from sourceDir: URL) throws -> ExtensionRecord {
        // Validate first so a bad download never lands in the extensions dir.
        let loaded = try ExtensionLoader.load(
            directory: sourceDir, isSystem: false, hostVersion: hostVersion)
        // A remote extension cannot masquerade as a bundled system one.
        guard !loaded.manifest.extension.isSystem else {
            throw ExtensionError.cannotUninstallSystem(loaded.id)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        // Use the extension id as the on-disk folder name (stable across renames).
        let dest = userDir.appendingPathComponent(loaded.id, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: sourceDir, to: dest)
        discover()
        guard let record = record(id: loaded.id) else { throw ExtensionError.notFound(loaded.id) }
        return record
    }

    /// Fetch + install an extension from a GitHub URL (repo or repo subdir).
    @discardableResult
    func installRemote(url: String) async throws -> ExtensionRecord {
        let extDir = try await RemoteInstaller.fetch(url)
        defer { try? FileManager.default.removeItem(at: extDir.deletingLastPathComponent().deletingLastPathComponent()) }
        // Stamp the origin so future launches can poll it for updates (no-op if
        // the author already declared an update_url).
        injectUpdateURL(url, intoManifestAt: extDir)
        return try installLocal(from: extDir)
    }

    // MARK: - Auto-update

    private static let updateCheckKey = "extensionsUpdateLastCheck"

    /// Surfaced to the UI after a check: e.g. "Updated 2 extensions". nil = idle.
    @Published private(set) var updateStatus: String?

    /// Poll each user extension's `update_url` for a newer version and auto-apply
    /// it. Throttled to once per day unless `force` (the "Check for Updates"
    /// button passes force). System extensions update via the bundle, not here.
    func checkForUpdates(force: Bool = false) async {
        if !force, let last = defaults.object(forKey: Self.updateCheckKey) as? Date,
           Date().timeIntervalSince(last) < 86_400 { return }
        defaults.set(Date(), forKey: Self.updateCheckKey)

        // Snapshot candidates up front — installLocal() rebuilds `records`.
        let candidates: [(id: String, version: SemanticVersion, url: String)] =
            records.compactMap { rec in
                guard !rec.isSystem,
                      let url = rec.manifest.extension.updateURL else { return nil }
                return (rec.id, SemanticVersion(rec.manifest.extension.version), url)
            }
        guard !candidates.isEmpty else { if force { updateStatus = "No updatable extensions." }; return }
        if force { updateStatus = "Checking…" }

        var updated = 0
        for cand in candidates {
            do {
                let remoteDir = try await RemoteInstaller.fetch(cand.url)
                let temp = remoteDir.deletingLastPathComponent().deletingLastPathComponent()
                defer { try? FileManager.default.removeItem(at: temp) }
                guard let remote = manifestVersion(at: remoteDir), cand.version < remote else { continue }
                injectUpdateURL(cand.url, intoManifestAt: remoteDir)   // keep origin sticky
                try installLocal(from: remoteDir)
                updated += 1
                log.info("auto-updated extension \(cand.id, privacy: .public) to a newer version")
            } catch {
                log.error("update check failed for \(cand.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if force || updated > 0 {
            updateStatus = updated == 0 ? "All extensions up to date." : "Updated \(updated) extension\(updated == 1 ? "" : "s")."
        }
    }

    /// Persist the GitHub origin as `update_url` in the extension's manifest so
    /// auto-update knows where to poll. No-op when the manifest already declares
    /// one (author-provided or stamped by a prior install).
    private func injectUpdateURL(_ url: String, intoManifestAt dir: URL) {
        let toml = dir.appendingPathComponent(ExtensionLoader.manifestFileName)
        guard var text = try? String(contentsOf: toml, encoding: .utf8) else { return }
        if text.range(of: #"(?m)^[ \t]*update_url[ \t]*="#, options: .regularExpression) != nil { return }
        guard let header = text.range(of: #"(?m)^[ \t]*\[extension\][ \t]*$"#, options: .regularExpression) else { return }
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        text.replaceSubrange(header.upperBound..<header.upperBound, with: "\nupdate_url = \"\(escaped)\"")
        try? text.write(to: toml, atomically: true, encoding: .utf8)
    }

    // MARK: - Per-extension settings (schema-driven UI <-> host prefs)

    func setSetting(extensionID: String, key: String, value: String) {
        services.prefSet(extensionID: extensionID, key: key, value: value)
    }

    /// Current raw `host.prefs` value for a key (nil if unset). Used by Tier-A
    /// settings sections to seed their controls.
    func prefValue(extensionID: String, key: String) -> String? {
        services.prefGet(extensionID: extensionID, key: key)
    }

    /// Reveal an extension's source directory in Finder (for editing system or
    /// user extensions in place).
    func directory(id: String) -> URL? { record(id: id)?.loaded.directory }

    /// Reset a system extension to its bundled pristine copy, discarding local
    /// edits. Copies the pristine bundled dir over the editable copy in userDir.
    func reset(id: String) throws {
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        guard record.isSystem else { throw ExtensionError.cannotResetUserExtension(id) }
        guard let pristineRoot = systemPristineDir else { throw ExtensionError.noPristineCopy(id) }
        let folder = record.loaded.directory.lastPathComponent
        let pristine = pristineRoot.appendingPathComponent(folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: pristine.path) else {
            throw ExtensionError.noPristineCopy(id)
        }
        let dest = userDir.appendingPathComponent(folder, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: pristine, to: dest)
        record.runtime = nil
        asyncRuntimes.invalidate(id: id)
        discover()
    }

    // MARK: - Disabled-id persistence

    private func disabledIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
    }

    private func persistDisabled() {
        let ids = records.filter { !$0.enabled }.map(\.id).sorted()
        defaults.set(ids, forKey: Self.disabledKey)
    }
}
