import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import LidHelperProtocol
import SystemConfiguration
import UniformTypeIdentifiers
import UserNotifications
import os

/// Production implementation of `ExtensionHostServices`, bridging the extension
/// host API to Prosper's native subsystems (system pasteboard, clipboard store,
/// MLX via CoreBridge, shell, notifications, per-extension prefs).
///
/// `@unchecked Sendable`: the only mutable shared state is `UserDefaults`
/// (thread-safe); all AppKit/MainActor access is funnelled through `mainSync`.
final class LiveExtensionHostServices: ExtensionHostServices, @unchecked Sendable {

    static let shared = LiveExtensionHostServices()
    private let defaults = UserDefaults.standard

    /// Presents a host-rendered window for `host.window.open`. Injected by
    /// `AppDelegate` once the extension registry exists (the presenter wires the
    /// window's controls back into the registry for transform/action dispatch).
    /// nil before wiring / in headless runs — `openWindow` then no-ops.
    var windowPresenter: (@MainActor (_ extensionID: String, _ node: ExtensionViewNode) -> Void)?

    /// Dismisses the open host-rendered window for `host.window.close`. Injected by
    /// `AppDelegate`; nil before wiring / in headless runs (`closeWindow` no-ops).
    var windowCloser: (@MainActor () -> Void)?

    // MARK: Clipboard (live system pasteboard + native history store)

    func clipboardRead() -> String? {
        mainSync { NSPasteboard.general.string(forType: .string) }
    }

    func clipboardWrite(_ text: String) {
        mainSync {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    func clipboardHistory(limit: Int) -> [String] {
        mainSync {
            ClipboardStore.shared.items
                .filter { $0.kind.isTextual }
                .prefix(max(0, limit))
                .map { $0.preview }
        }
    }

    // MARK: Local LLM (async; queued onto MLX through CoreBridge)

    func llmComplete(_ prompt: String) async -> String {
        await withCheckedContinuation { cont in
            Task { @MainActor in
                CoreBridge.generate(prompt: prompt, system: nil) { cont.resume(returning: $0 ?? "") }
            }
        }
    }

    /// Translate, returning a JSON object string the Lua `host.llm.translate`
    /// wrapper decodes into a table: `{ primary, detected, candidates = [{ text,
    /// label, note }] }`. The full structure (alternatives + detected language) is
    /// surfaced so extensions can build rich result views, not just a flat string.
    /// Empty string on failure (the Lua wrapper maps that to nil).
    func llmTranslate(_ text: String, target: String, source: String?) async -> String {
        let result: TranslationResult? = await withCheckedContinuation { cont in
            Task { @MainActor in
                CoreBridge.translate(text, target: target, source: source) { cont.resume(returning: $0) }
            }
        }
        guard let result, !result.primary.isEmpty else { return "" }
        let obj: [String: Any] = [
            "primary": result.primary,
            "detected": result.detectedLanguage ?? "",
            "candidates": result.candidates.map { c -> [String: String] in
                var item = ["text": c.text]
                if let l = c.label { item["label"] = l }
                if let e = c.explanation { item["note"] = e }
                return item
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    // MARK: Shell

    func shellRun(_ command: String) async -> String {
        await ShellRunner.run(command)
    }

    // MARK: Outbound HTTP (trusted-extension capability)

    /// Perform an http/https request. Restricted to those two schemes, time-boxed,
    /// and response-size capped (5 MB) so a sandboxed extension cannot stream
    /// unbounded data into the VM. Returns nil on bad scheme / transport error.
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? {
        guard let u = URL(string: url),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        var req = URLRequest(url: u)
        req.httpMethod = method.uppercased()
        req.timeoutInterval = timeout > 0 ? min(timeout, 30) : 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body, !body.isEmpty { req.httpBody = body.data(using: .utf8) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = req.timeoutInterval
        config.timeoutIntervalForResource = req.timeoutInterval
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let maxBytes = 5 * 1024 * 1024
        do {
            let (data, response) = try await session.data(for: req)
            let capped = data.count > maxBytes ? data.prefix(maxBytes) : data[...]
            let http = response as? HTTPURLResponse
            var headerMap: [String: String] = [:]
            if let fields = http?.allHeaderFields {
                for (k, v) in fields { headerMap[String(describing: k)] = String(describing: v) }
            }
            return HTTPResponse(
                status: http?.statusCode ?? 0,
                body: String(data: Data(capped), encoding: .utf8) ?? "",
                headers: headerMap
            )
        } catch {
            return nil
        }
    }

    // MARK: Window management (Accessibility — same permission as autocomplete)

    func focusedWindowFrame() -> WindowFrame? {
        mainSync {
            guard let win = Self.focusedWindowElement(),
                  let pos = Self.axValue(win, kAXPositionAttribute, .cgPoint, CGPoint.self),
                  let size = Self.axValue(win, kAXSizeAttribute, .cgSize, CGSize.self)
            else { return nil }
            let winRect = CGRect(origin: pos, size: size)
            let visible = Self.visibleFrameAX(for: winRect)
            return WindowFrame(
                x: Double(winRect.origin.x), y: Double(winRect.origin.y),
                w: Double(winRect.width), h: Double(winRect.height),
                visibleX: Double(visible.origin.x), visibleY: Double(visible.origin.y),
                visibleW: Double(visible.width), visibleH: Double(visible.height))
        }
    }

    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool {
        mainSync {
            guard let win = Self.focusedWindowElement() else { return false }
            var pos = CGPoint(x: x, y: y)
            var sz = CGSize(width: width, height: height)
            guard let posVal = AXValueCreate(.cgPoint, &pos),
                  let sizeVal = AXValueCreate(.cgSize, &sz) else { return false }
            // Size, then position, then size again: moving across displays can
            // re-clamp the size, and some apps ignore a resize until placed.
            let s1 = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
            let p1 = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal)
            _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal)
            return s1 == .success && p1 == .success
        }
    }

    /// The Accessibility element for the frontmost app's focused window, or nil.
    private static func focusedWindowElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let win = ref, CFGetTypeID(win) == AXUIElementGetTypeID()
        else { return nil }
        return (win as! AXUIElement)
    }

    /// Read a CGPoint / CGSize AX attribute generically.
    private static func axValue<T>(_ el: AXUIElement, _ attr: String, _ type: AXValueType, _: T.Type) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID()
        else { return nil }
        var out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        return AXValueGetValue(v as! AXValue, type, &out.pointee) ? out.pointee : nil
    }

    /// Visible frame (Dock/menu-bar excluded) of the screen the window sits on,
    /// in the AX top-left global space. Picks the screen containing the window
    /// centre, else the largest overlap, else main.
    private static func visibleFrameAX(for winRectAX: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func toAX(_ r: CGRect) -> CGRect {
            CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height,
                   width: r.width, height: r.height)
        }
        let center = CGPoint(x: winRectAX.midX, y: winRectAX.midY)
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let fAX = toAX(screen.frame)
            if fAX.contains(center) { best = screen; break }
            let inter = fAX.intersection(winRectAX)
            let area = inter.width * inter.height
            if area > bestArea { bestArea = area; best = screen }
        }
        guard let chosen = best ?? NSScreen.main ?? NSScreen.screens.first else { return winRectAX }
        return toAX(chosen.visibleFrame)
    }

    // MARK: Wall-clock

    func currentEpochSeconds() -> Double { Date().timeIntervalSince1970 }

    // MARK: Per-extension prefs (namespaced in UserDefaults)

    func prefGet(extensionID: String, key: String) -> String? {
        defaults.string(forKey: Self.prefKey(extensionID, key))
    }

    func prefSet(extensionID: String, key: String, value: String) {
        defaults.set(value, forKey: Self.prefKey(extensionID, key))
    }

    private static func prefKey(_ id: String, _ key: String) -> String { "ext.\(id).\(key)" }

    // MARK: Privacy grants (read-only check for host.perms.has)

    func permissionGranted(_ name: String) -> Bool {
        PermissionsManager.isGranted(name)
    }

    // MARK: Filesystem (read-only directory listing)

    func listDirectories(_ path: String) -> [String] {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: expanded),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url -> String? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            return url.lastPathComponent
        }.sorted()
    }

    // MARK: App launcher (ranked AppIndex search)

    /// Ranked application matches for `query`, encoded as a JSON array string
    /// `[{name, path}]`. Mirrors the native launcher's `o ` search so the `open`
    /// system extension produces the same results. `AppIndex` is MainActor-bound.
    func appsSearch(_ query: String) -> String {
        let entries = mainSync { AppIndex.shared.search(query) }
        let arr = entries.map { ["name": $0.name, "path": $0.url.path] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    // MARK: Snippets (native store + placeholder engine)

    func snippetsAll() -> String {
        encodeSnippets(SnippetStore.all())
    }

    func snippetGet(name: String) -> String? {
        guard let hit = SnippetStore.byName(name),
              let data = try? JSONSerialization.data(withJSONObject: Self.snippetDict(hit)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    func snippetSave(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let name = (obj["name"] as? String) ?? ""
        let text = (obj["text"] as? String) ?? ""
        guard !name.isEmpty, !text.isEmpty else { return }
        SnippetStore.save(SnippetHit(
            name: name,
            keyword: (obj["keyword"] as? String) ?? "",
            text: text,
            collection: (obj["collection"] as? String) ?? "",
            description: (obj["description"] as? String) ?? "",
            autoExpand: (obj["autoExpand"] as? Bool) ?? true,
            richText: (obj["richText"] as? Bool) ?? false))
    }

    func snippetRemove(name: String) {
        SnippetStore.remove(name: name)
    }

    func snippetExpand(keyword: String, argsJSON: String?) -> String {
        guard let hit = SnippetStore.all().first(where: { $0.keyword == keyword || $0.name == keyword })
        else { return "" }
        var args: [String: String] = [:]
        if let argsJSON, let data = argsJSON.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (k, v) in obj { args[k] = String(describing: v) }
        }
        let isRich = hit.richText
        // For rich snippets, resolve against the decoded plain projection (the
        // palette inserts plain text); for plain snippets, the body is the template.
        let template = isRich ? RichSnippet.plainText(rtf: hit.text) : hit.text
        return mainSync {
            let clip = NSPasteboard.general.string(forType: .string)
            let history: [String] = ClipboardStore.shared.items
                .filter { $0.kind.isTextual }
                .compactMap { ClipboardStore.shared.text(for: $0) ?? $0.preview }
            let snippets = SnippetStore.all()
            var customs: [String: String] = [:]
            if let registry = CommandRouter.registry {
                for token in PlaceholderEngine.customTokens(in: template) {
                    if let value = registry.resolvePlaceholder(name: token.name, raw: token.raw) {
                        customs[token.raw] = value
                    }
                }
            }
            var ctx = PlaceholderContext()
            ctx.clipboard = { clip }
            ctx.clipboardHistory = { n in (n >= 0 && n < history.count) ? history[n] : nil }
            ctx.arguments = args
            ctx.snippetByKeyword = { key in
                snippets.first { $0.keyword == key || $0.name == key }?.text
            }
            ctx.custom = { _, raw in customs[raw] }
            return PlaceholderEngine.render(template, ctx).text
        }
    }

    // MARK: Snippet settings surface (Tier-B management page)

    func snippetConfig() -> String {
        Self.jsonString([
            "enabled": Preferences.snippetsEnabled,
            "autoExpand": Preferences.snippetsAutoExpand,
            "wordBoundary": Preferences.snippetsExpandOnWordBoundary,
            "restoreClipboard": Preferences.snippetsRestoreClipboard,
        ]) ?? "{}"
    }

    func snippetSetConfig(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let v = obj["enabled"] as? Bool { Preferences.snippetsEnabled = v }
        if let v = obj["autoExpand"] as? Bool { Preferences.snippetsAutoExpand = v }
        if let v = obj["wordBoundary"] as? Bool { Preferences.snippetsExpandOnWordBoundary = v }
        if let v = obj["restoreClipboard"] as? Bool { Preferences.snippetsRestoreClipboard = v }
        if let cb = snippetConfigChanged { Task { @MainActor in cb() } }
    }

    func snippetCollections() -> String {
        let arr = SnippetStore.allCollections().map {
            ["name": $0.name, "prefix": $0.prefix, "suffix": $0.suffix]
        }
        return Self.jsonString(arr) ?? "[]"
    }

    func snippetSetCollections(json: String) {
        // An empty list may arrive JSON-encoded as `{}` (Lua); treat any non-array
        // as "no collections" so deleting the last one persists.
        let arr = Self.jsonArray(json) ?? []
        SnippetStore.replaceCollections(arr.compactMap { e in
            guard let name = (e["name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return nil }
            return SnippetCollection(name: name,
                                     prefix: (e["prefix"] as? String) ?? "",
                                     suffix: (e["suffix"] as? String) ?? "")
        })
    }

    func snippetIgnored() -> String {
        Self.jsonString(Preferences.snippetsIgnoredBundleIds.sorted()) ?? "[]"
    }

    func snippetSetIgnored(json: String) {
        let raw = (json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String]) ?? []
        Preferences.snippetsIgnoredBundleIds = Set(
            raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    func snippetImportFile() -> String {
        mainSync {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url,
                  let json = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            _ = SnippetStore.importJSON(json)
            return "Imported"
        }
    }

    private static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func jsonArray(_ json: String) -> [[String: Any]]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    private static func snippetDict(_ hit: SnippetHit) -> [String: Any] {
        [
            "name": hit.name,
            "keyword": hit.keyword,
            "text": hit.text,
            "collection": hit.collection,
            "description": hit.description,
            "autoExpand": hit.autoExpand,
            "richText": hit.richText,
        ]
    }

    private func encodeSnippets(_ hits: [SnippetHit]) -> String {
        let arr = hits.map(Self.snippetDict)
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    // MARK: File finder (Spotlight via FileSearchEngine / NSMetadataQuery)

    /// Ranked file/folder matches for the `host.files.search{…}` options object,
    /// encoded as the JSON array string the Lua wrapper decodes. The Spotlight
    /// gather runs on the main actor (run-loop driven); the extension worker awaits
    /// it off-main via the host bridge. Powers the `files` system extension.
    func filesSearch(_ optsJSON: String) async -> String {
        await FileSearchEngine.searchJSON(.decode(json: optsJSON))
    }

    /// Runs a built-in file action (`host.files.act`) on the main actor and records
    /// the engagement for frecency ranking. Unknown ids / non-engagements are
    /// no-ops at the relevant layer.
    func filesAct(id: String, path: String) {
        mainSync { FileActionDispatcher.live.run(id: id, path: path) }
    }

    // MARK: Host-rendered windows (host.window.open)

    /// Decode the declarative node and hand it to the injected presenter on the
    /// main thread. Bad JSON / no presenter → silently ignored.
    func openWindow(extensionID: String, nodeJSON: String) {
        guard let node = try? ExtensionViewNode.decode(json: nodeJSON) else { return }
        mainSync {
            self.windowPresenter?(extensionID, node)
        }
    }

    func closeWindow() {
        mainSync { self.windowCloser?() }
    }

    /// Opens the Prosper Settings window at an extension's pane. `selection` is the
    /// sidebar id ("ext:<extID>|<sectionID>") the window restores on open. Injected
    /// by `AppDelegate`; nil before wiring / in headless runs (`openSettings` no-ops).
    var settingsOpener: (@MainActor (_ selection: String) -> Void)?

    /// Fired after snippet settings change so the app can reconcile the keystroke
    /// tap — snippet auto-expansion needs the tap up even when inline autocomplete
    /// is off (see `AppDelegate.reconcileKeyTap`).
    var snippetConfigChanged: (@MainActor () -> Void)?

    func openSettings(extensionID: String, sectionID: String?) {
        mainSync {
            // nil sectionID → the extension's first sidebar section. Resolve it (an
            // "ext:<id>|" with an empty section is not a real sidebar id and would
            // just bounce the window to General). No pane for this extension → no-op
            // rather than open Settings somewhere unrelated.
            let sid = sectionID ?? SettingsHooks.shared.extensionRegistry?
                .settingsSections(placement: "sidebar")
                .first { $0.record.id == extensionID }?.section.id
            guard let sid, !sid.isEmpty else { return }
            self.settingsOpener?("ext:\(extensionID)|\(sid)")
        }
    }

    // MARK: Durable timers (host.timer → TimerScheduler)

    func timerSchedule(extensionID: String, id: String, every: Bool, seconds: Double, handler: String) {
        TimerScheduler.shared.schedule(extID: extensionID, id: id, every: every,
                                       seconds: seconds, handler: handler)
    }

    func timerCancel(extensionID: String, id: String) {
        TimerScheduler.shared.cancel(extID: extensionID, id: id)
    }

    // MARK: Logging + environment

    private static let extLog = Logger(subsystem: "com.prosper.app", category: "extension")

    func log(level: String, message: String) {
        switch level {
        case "error": Self.extLog.error("\(message, privacy: .public)")
        case "warn":  Self.extLog.warning("\(message, privacy: .public)")
        default:      Self.extLog.info("\(message, privacy: .public)")
        }
    }

    func envGet(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }

    // MARK: Power / caffeinate (host.caffeinate → IOKit + privileged pmset)

    func caffeinatePreventIdleSleep(extensionID: String, kind: String, on: Bool) {
        ExtensionResources.shared.setAssertion(extID: extensionID, kind: kind, on: on)
    }

    /// `pmset -a disablesleep` overrides lid-close sleep, and that needs root. We
    /// route it through the privileged `ProsperLidHelper` daemon (installed lazily
    /// via SMAppService on first use) — NO sudoers entry, works out of the box.
    /// Tracked in ExtensionResources so it is reset on disable/quit; the daemon
    /// also resets it if the app crashes (the XPC connection drops). Only records
    /// the override as held when the helper confirms it actually applied.
    func caffeinateSetDisableLidSleep(extensionID: String, on: Bool) async {
        let ok = await LidSleepHelper.setDisabled(on)
        if ok || !on {
            // On failure to turn ON, don't claim we hold it. Turning OFF always
            // clears our bookkeeping regardless (best-effort release).
            ExtensionResources.shared.setLidSleepDisabled(extID: extensionID, on: on && ok)
        }
    }

    /// Arm/disarm the daemon's remote-wake poll. The host owns the sensitive bits:
    /// the poll URL is built here from the worker base + a wake id DERIVED from the
    /// device id (`SHA256(deviceID ‖ ":wake")`, never the raw device key/id on the
    /// wire) so the extension can't redirect the root poll. The extension supplies
    /// only the cadence + battery floor; `enabled == false` disarms.
    func caffeinateSetRemoteWake(extensionID: String, enabled: Bool, deviceID: String, intervalAC: Double, intervalBatt: Double, batteryFloor: Int) async {
        // Remote-wake REQUIRES a signed-in account: the poll URL's acctTag is derived
        // from the session email, and only an authenticated session can POST a matching
        // wake. With no account the daemon would poll a URL nothing can ever trigger —
        // pure battery waste. Force-disable here so enabling while signed out can't arm
        // it (complements the disarm-on-signOut: this also covers the steady-state
        // signed-out case and any future re-apply path, e.g. on_launch).
        let signedIn = !(SupporterStore.load()?.email ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let cfg = RemoteWakeConfig(
            enabled: enabled && signedIn,
            pollURL: Self.wakePollURL(deviceTag: deviceID),
            intervalAC: intervalAC,
            intervalBatt: intervalBatt,
            batteryFloor: batteryFloor)
        // NOT tracked in ExtensionResources / reset on quit — unlike the idle/lid
        // assertions, remote-wake MUST keep running after the app quits or sleeps
        // (that is the whole point). The daemon owns its residency via its config
        // file; turning it off is an explicit user action that sends enabled=false.
        _ = await LidSleepHelper.setRemoteWake(cfg)
        // Remember the meta URL whenever signed in (the device has a meta row on the
        // server whether enabled or not) so `signOut` can DELETE it even though it lacks
        // the device tag to rebuild the URL. Set synchronously, before the report task,
        // so signOut can't read a half-written key.
        if signedIn {
            UserDefaults.standard.set(cfg.pollURL + "/meta", forKey: Self.wakeMetaURLKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.wakeMetaURLKey)
        }
        // Report state so a paired device knows whether this Mac can be woken (enabled)
        // and the ETA. The daemon config above is the real state and is set first; this
        // is the advertisement of it. Fire off the chain — never block lid/daemon ops on
        // a network call.
        // ponytail: last-write-wins; a fast enable/disable toggle could leave a stale
        //   advertised state. Sequence server-side only if it ever matters — toggles are
        //   human-paced, the window is ~one RTT.
        Task.detached { await Self.reportWakeMeta(cfg) }
    }

    /// UserDefaults key holding the last meta URL (`<pollURL>/meta`) so
    /// `SupporterClient.signOut` can DELETE the server-side wake metadata (it lacks the
    /// device tag to rebuild the URL).
    static let wakeMetaURLKey = "prosper.remoteWake.metaURL"

    /// Best-effort, fail-open: POST this device's remote-wake state (enabled + cadence)
    /// to `<pollURL>/meta` on every toggle, so a paired device can tell whether the Mac
    /// is wakeable. Authenticated (the server's ownership gate matches the poll id); a
    /// disable posts `enabled:false` (not a delete) so "off" stays distinct from "never
    /// set up". Removal happens only on signOut.
    private static func reportWakeMeta(_ cfg: RemoteWakeConfig) async {
        guard let session = SupporterStore.load()?.session,
              let url = URL(string: cfg.pollURL + "/meta") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "enabled": cfg.enabled, "intervalAC": cfg.intervalAC, "intervalBatt": cfg.intervalBatt,
            "batteryFloor": cfg.batteryFloor,
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// `<worker-base>/wake/<acctTag>-<devTag>`. Two halves, two jobs:
    ///
    /// - `acctTag = sha256(email)[:16]` — OWNERSHIP. The server re-derives it from
    ///   the authenticated session on POST and rejects a mismatch, so only the
    ///   owning account can set the flag. Not a secret; it's a namespace tag. If not
    ///   signed in the email is "", giving a tag no real session can match —
    ///   fail-safe: the device can't be woken until an account signs in.
    /// - `devTag` — the user-chosen device handle (a LAN IP, Tailscale IP/MagicDNS,
    ///   or hostname). It's the SAME string the remote app uses to wake AND to
    ///   connect to this Mac. Readable on purpose; POST-auth makes that safe. Falls
    ///   back to the hostname, then an opaque device hash, if none was set.
    ///
    /// The extension supplies only `deviceTag` (+ cadence/floor); the host owns the
    /// worker URL and the ownership tag, so an extension can't redirect the poll or
    /// forge another account.
    /// Ownership namespace tag = sha256(normalized email)[:16 hex]. MUST stay
    /// byte-identical to the server's `acctTag` (wakeId.mjs) or every wake POST 403s
    /// against this device's URL, silently. Normalizes (trim + lowercase) to mirror
    /// the server's normalizeEmail. Pinned by a golden-value test against the JS impl.
    static func wakeAcctTag(_ rawEmail: String) -> String {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(SHA256.hash(data: Data(email.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    private static func wakePollURL(deviceTag: String) -> String {
        let acctTag = wakeAcctTag(SupporterStore.load()?.email ?? "")
        var dev = normalizeTag(deviceTag)
        if dev.isEmpty { dev = normalizeTag(ProcessInfo.processInfo.hostName) }
        if dev.isEmpty {
            dev = String(SHA256.hash(data: Data("\(SupporterStore.deviceID()):wake".utf8))
                .map { String(format: "%02x", $0) }.joined().prefix(32))
        }
        return ProsperServer.baseURL.appending(path: "/wake/\(acctTag)-\(dev)").absoluteString
    }

    /// Lowercase, strip to URL-safe `[a-z0-9.\-_:]`, cap 63 chars. The remote app
    /// MUST normalize identically or the flag keys won't match (no fuzzy match by
    /// design — the handle is an exact key). ponytail: IPv6 colons survive here but
    /// `URL.appending(path:)` may percent-encode them; IPv4/DNS/hostname (the common
    /// case) pass through untouched. Hash the handle both sides if that ever bites.
    private static func normalizeTag(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_:")
        let lower = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(lower.filter { allowed.contains($0) }.prefix(63))
    }

    func caffeinateLockScreen() {
        // User-space lock (no entitlement): the CGSession menu-extra suspends the
        // session. Fire-and-forget off-main.
        Task.detached {
            _ = await ShellRunner.run(
                "'/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession' -suspend")
        }
    }

    func caffeinateStartScreensaver() {
        Task.detached { _ = await ShellRunner.run("/usr/bin/open -a ScreenSaverEngine") }
    }

    // MARK: Battery / network / screen (read-only)

    func batteryPowerSource() -> String { SystemInfo.powerSource() }
    func batteryPercentage() -> Int { SystemInfo.batteryPercentage() ?? -1 }

    func networkIsReachable() -> Bool {
        var addr = sockaddr()
        addr.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        addr.sa_family = sa_family_t(AF_INET)
        guard let reach = withUnsafePointer(to: &addr, { ptr in
            SCNetworkReachabilityCreateWithAddress(nil, ptr)
        }) else { return true }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reach, &flags) else { return true }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }

    /// Candidate wake handles for this Mac, best first: Tailscale IPs (100.64/10),
    /// then private LAN IPv4, then the hostname. Tailscale + LAN IPs come free as
    /// interface addresses via `getifaddrs` — no Tailscale CLI / path guessing. JSON
    /// array of `{address, kind}`; the UI labels them and the user can also type any
    /// address by hand.
    func networkAddressesJSON() -> String {
        var ts: [String] = [], lan: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0 {
            var p = ifap
            while let cur = p {
                let f = cur.pointee
                let flags = f.ifa_flags  // UInt32 on Darwin — Int32() cast traps if high bit set
                if let sa = f.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                   (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_LOOPBACK)) == 0 {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buf, socklen_t(buf.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: buf)
                        let o = ip.split(separator: ".")
                        let isTS = o.count == 4 && o[0] == "100" && (Int(o[1]).map { $0 >= 64 && $0 <= 127 } ?? false)
                        if isTS { ts.append(ip) }
                        else if !ip.hasPrefix("169.254") { lan.append(ip) }  // skip link-local
                    }
                }
                p = f.ifa_next
            }
            freeifaddrs(ifap)
        }
        var out = ts.map { ["address": $0, "kind": "tailscale"] }
        out += lan.map { ["address": $0, "kind": "lan"] }
        let hn = ProcessInfo.processInfo.hostName
        if !hn.isEmpty { out.append(["address": hn, "kind": "hostname"]) }
        return (try? JSONSerialization.data(withJSONObject: out))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    func screenAllJSON() -> String { mainSync { SystemInfo.screensJSON() } }

    func screenLidClosed() -> Int {
        switch SystemInfo.lidClosed() {
        case .some(true): return 1
        case .some(false): return 0
        case nil: return -1
        }
    }

    func resetResources(extensionID: String) {
        let hadLid = ExtensionResources.shared.releaseAll(extID: extensionID)
        if hadLid {
            // Route through the SAME serial chain as set_disable_lid_sleep so this
            // teardown release is ordered against the extension's own applies. On a
            // settings-Apply reload (teardown then re-enable) a direct release could
            // otherwise land AFTER the re-enable's set(true) and wedge sleep back on.
            LidSleepHelper.enqueueApply { _ = await LidSleepHelper.setDisabled(false) }
        }
        Task { @MainActor in
            ExtensionMenuBar.shared.removeAll(extensionID: extensionID)
            ExtensionKeyRules.shared.removeRules(extensionID: extensionID)
            ExtensionFSWatch.shared.removeAll(extensionID: extensionID)
        }
    }

    // MARK: Host-rendered UI (menubar / dialog / alert) — main-bridged

    func menubarSet(extensionID: String, id: String, json: String) {
        Task { @MainActor in ExtensionMenuBar.shared.set(extensionID: extensionID, id: id, json: json) }
    }

    func menubarRemove(extensionID: String, id: String) {
        Task { @MainActor in ExtensionMenuBar.shared.remove(extensionID: extensionID, id: id) }
    }

    func dialogPrompt(json: String) async -> String? {
        await MainActor.run { ExtensionMenuBar.shared.prompt(json: json) }
    }

    func dialogConfirm(json: String) async -> Bool {
        await MainActor.run { ExtensionMenuBar.shared.confirm(json: json) }
    }

    func alertShow(text: String, seconds: Double) {
        Task { @MainActor in ExtensionMenuBar.shared.alert(text: text, seconds: seconds) }
    }

    // MARK: App control / scripting / keyboard

    func appLaunchOrFocus(_ nameOrBundleID: String) {
        Task { @MainActor in AppControl.launchOrFocus(nameOrBundleID) }
    }
    func appFrontmostJSON() -> String { mainSync { AppControl.frontmostJSON() } }
    func appWindowCount(bundleID: String) -> Int { mainSync { AppControl.windowCount(bundleID: bundleID) } }
    func appHide(bundleID: String) { Task { @MainActor in AppControl.hide(bundleID: bundleID) } }
    func runAppleScript(_ source: String) -> String { Scripting.runAppleScript(source) }
    // Carbon TIS must be called on the main thread — these handlers fire on the
    // off-main async event lane (e.g. app.activated → per-app input switching), where
    // TISSelectInputSource silently no-ops. Funnel through mainSync like every other
    // AppKit/system call here.
    func keyboardCurrentSource() -> String { mainSync { KeyboardSource.currentSourceID() } }
    func keyboardLayoutsJSON() -> String { mainSync { KeyboardSource.layoutsJSON() } }
    func keyboardSetSource(_ id: String) -> Bool { mainSync { KeyboardSource.setSource(id) } }

    func keysSetRules(extensionID: String, json: String) {
        Task { @MainActor in
            ExtensionKeyRules.shared.setRules(extensionID: extensionID, json: json)
            // A (re)install is the one signal the extension's config — and thus its
            // eventtap set — may have changed. Cheap no-op unless it opted in.
            EventTapHost.shared.refreshIfDeclares(extensionID: extensionID)
        }
    }
    func keysStroke(_ spec: String) {
        guard let chord = KeyChord(spec: spec) else { return }
        Task { @MainActor in KeyInjector.stroke(chord) }
    }
    func keysSystem(_ name: String) { Task { @MainActor in KeyInjector.system(name) } }

    func urlOpen(_ url: String, bundleID: String?) -> Bool { URLServices.open(url, bundleID: bundleID) }
    func urlDefaultBrowser() -> String { URLServices.defaultBrowserBundleID() }
    func urlSetDefaultBrowser(_ bundleID: String) -> Bool { URLServices.setDefaultBrowser(bundleID) }

    // Fallback web-search providers. The store is @MainActor; funnel through mainSync
    // like the other AppKit/main-actor reads above.
    func fallbackList() -> String { mainSync { FallbackSearchStore.shared.providersJSON() } }
    func fallbackSave(_ json: String) { mainSync { FallbackSearchStore.shared.setProvidersJSON(json) } }
    func fallbackMode() -> Bool { mainSync { FallbackSearchStore.shared.appendMode } }
    func fallbackSetMode(_ on: Bool) { mainSync { FallbackSearchStore.shared.appendMode = on } }
    func fallbackImport() -> Int {
        // The browser-DB read (file copy + SQLite parse, multi-MB) is the heavy part —
        // do it OFF the main thread, then hop to the @MainActor store only for the
        // cheap dedupe-merge. settings_action already runs off-main, so `bundleID`
        // (a LaunchServices read) and the importer run on this lane; never on main.
        let bundleID = URLServices.defaultBrowserBundleID()
        let discovered = BrowserSearchImporter.providers(forDefaultBrowser: bundleID)
        return mainSync { FallbackSearchStore.shared.merge(discovered) }
    }

    func fsExists(_ path: String) -> Bool { FSReads.exists(path) }
    func fsAttributesJSON(_ path: String) -> String { FSReads.attributesJSON(path) }
    func fsRead(_ path: String) -> String? { FSReads.read(path) }
    func fsWatch(extensionID: String, path: String, handler: String) {
        Task { @MainActor in ExtensionFSWatch.shared.watch(extensionID: extensionID, path: path, handler: handler) }
    }
    func fsUnwatch(extensionID: String, path: String) {
        Task { @MainActor in ExtensionFSWatch.shared.unwatch(extensionID: extensionID, path: path) }
    }

    // MARK: Notifications

    func notify(title: String, body: String) {
        // UNUserNotificationCenter requires a real bundle; skip in dev/CLI runs.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { center.add(request) }
        }
    }

    // MARK: Main-thread bridge

    /// Run a MainActor-isolated body synchronously from any thread. Extensions
    /// run off-main, so `DispatchQueue.main.sync` cannot deadlock here.
    private func mainSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
