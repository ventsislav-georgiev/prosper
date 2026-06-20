import AppKit
import ApplicationServices
import Foundation
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
            Task { await LidSleepHelper.setDisabled(false) }
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
