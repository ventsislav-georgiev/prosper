import CryptoKit
import Foundation

extension Notification.Name {
    /// Posted on the main actor after a pulled snapshot has been written locally,
    /// so live state (hotkeys, extensions, agent config, UI toggles) can reconcile.
    /// `AppDelegate` observes this and re-applies the affected subsystems.
    static let prosperSyncApplied = Notification.Name("prosperSyncApplied")
}

/// Drives cross-device settings sync: snapshots everything the user can change in
/// Settings, includes small dependency-free extensions/plugins under a hard
/// compressed size cap, and reports what was included/excluded for the Sync pane.
///
/// The payload is `LZFSE(binary-plist)` then AES-GCM-encrypted by `SyncCrypto`
/// (iCloud-Keychain key) before it leaves the machine — the server stores only
/// ciphertext + a version. Concurrency is optimistic via `SyncClient`.
///
/// Disk-heavy collect/apply run **off the main actor** via `SyncSnapshotBuilder`;
/// only published state and the post-apply notification touch the main actor.
@MainActor
final class SyncCoordinator: ObservableObject {
    static let shared = SyncCoordinator()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var report = SyncReport()
    @Published private(set) var keyMode: SyncCrypto.KeyMode = .deviceFallback

    /// Hard cap on a single extension/plugin's *compressed* size to be sync-eligible.
    private let perItemCapBytes = 5 * 1024
    private let schema = 1
    private let defaults = UserDefaults.standard

    private init() {
        lastSync = defaults.object(forKey: DKeys.lastDate) as? Date
    }

    /// Whether sync is on for this device (local switch — not itself synced).
    var enabled: Bool {
        get { defaults.object(forKey: DKeys.enabled) == nil ? true : defaults.bool(forKey: DKeys.enabled) }
        set { defaults.set(newValue, forKey: DKeys.enabled) }
    }

    func startup() {
        keyMode = SyncCrypto.mode
        guard enabled, SupporterClient.shared.isSignedIn else { return }
        Task { await syncNow() }
    }

    /// Populate `report` from a local collect (no network) so the Sync pane can
    /// show what would be included/excluded without triggering a sync.
    func refreshReport() async {
        keyMode = SyncCrypto.mode
        let cap = perItemCapBytes, schema = self.schema
        if let (_, rep) = await Task.detached(priority: .utility, operation: {
            SyncSnapshotBuilder.collect(perItemCapBytes: cap, schema: schema)
        }).value {
            report = rep
        }
    }

    // MARK: - Sync

    func syncNow() async {
        keyMode = SyncCrypto.mode
        guard enabled else { lastError = "Sync is turned off."; return }
        guard SupporterClient.shared.isSignedIn else { lastError = "Sign in to sync settings."; return }
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        // 1) Pull remote; apply if newer than what we have.
        if let remote = await SyncClient.shared.pull() {
            if remote.version > storedVersion {
                if let data = remote.plaintext {
                    await applyOffMain(data)
                    storedVersion = remote.version
                } else {
                    lastError = "Waiting for your iCloud Keychain encryption key to reach this device."
                }
            }
        }

        // 2) Collect local; push if it changed since the last push.
        let cap = perItemCapBytes, schema = self.schema
        guard let (snapshot, rep) = await Task.detached(priority: .utility, operation: {
            SyncSnapshotBuilder.collect(perItemCapBytes: cap, schema: schema)
        }).value else {
            lastError = "Couldn't read settings to sync."
            return
        }
        report = rep
        let hash = sha256(snapshot)
        if hash == lastPushedHash {
            setLastSync(Date())
            return
        }

        switch await SyncClient.shared.push(snapshot, baseVersion: storedVersion) {
        case .ok(let v):
            storedVersion = v
            lastPushedHash = hash
            setLastSync(Date())
        case .conflict(let snap):
            if let data = snap.plaintext { await applyOffMain(data) }
            storedVersion = snap.version
            lastError = "Merged newer settings from another device — sync again to push this Mac's changes."
        case .unauthorized:
            lastError = "Session expired — sign in again."
        case .failed:
            lastError = "Sync failed — will retry."
        }
    }

    /// Write a decrypted payload to disk off-main, then notify reconcilers.
    private func applyOffMain(_ decryptedPayload: Data) async {
        await Task.detached(priority: .utility, operation: {
            SyncSnapshotBuilder.apply(decryptedPayload)
        }).value
        NotificationCenter.default.post(name: .prosperSyncApplied, object: nil)
    }

    // MARK: - Bookkeeping

    private enum DKeys {
        static let enabled = "settingsSyncEnabled"
        static let version = "settingsSyncVersion"
        static let pushedHash = "settingsSyncPushedHash"
        static let lastDate = "settingsSyncLastDate"
    }

    private var storedVersion: Int {
        get { defaults.integer(forKey: DKeys.version) }
        set { defaults.set(newValue, forKey: DKeys.version) }
    }
    private var lastPushedHash: String? {
        get { defaults.string(forKey: DKeys.pushedHash) }
        set { defaults.set(newValue, forKey: DKeys.pushedHash) }
    }
    private func setLastSync(_ date: Date) {
        lastSync = date
        defaults.set(date, forKey: DKeys.lastDate)
    }
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Off-main collect / apply

/// Pure, nonisolated snapshot collection + application. Safe to run on a
/// background task — touches only UserDefaults, FileManager, and Bundle.main.
enum SyncSnapshotBuilder {

    static func collect(perItemCapBytes: Int, schema: Int) -> (Data, SyncReport)? {
        let defaults = UserDefaults.standard
        var report = SyncReport()

        // (a) Allowlisted preferences (+ all `shortcut.*` / `ext.*` keys), minus
        //     the machine-local runtime/UI keys that share the `ext.` namespace.
        var defDict: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            if SyncedKeys.excluded.contains(key) { continue }
            if SyncedKeys.keys.contains(key)
                || SyncedKeys.prefixes.contains(where: { key.hasPrefix($0) }) {
                defDict[key] = value
            }
        }
        report.includedDefaults = defDict.count
        guard let defaultsBlob = try? PropertyListSerialization.data(
            fromPropertyList: defDict, format: .binary, options: 0) else { return nil }

        // (b) Config files + small, dependency-free extensions/plugins.
        var files: [String: Data] = [:]
        let cfg = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/prosper")

        for name in ["quicklinks.json", "quickdirs.json", "mcp.json", "hooks.json"] {
            collectFile(cfg.appending(path: name), rel: name, capBytes: 64 * 1024,
                        into: &files, report: &report)
        }
        collectFlatDir(cfg.appending(path: "agents"), rel: "agents",
                       allowedExt: ["md"], capBytes: 64 * 1024, into: &files, report: &report)
        collectFlatDir(cfg.appending(path: "commands"), rel: "commands",
                       allowedExt: ["md"], capBytes: 64 * 1024, into: &files, report: &report)
        collectBundles(cfg.appending(path: "extensions"), rel: "extensions",
                       allowedExt: ["lua", "toml", "json", "md", "txt"],
                       skipNames: bundledExtensionNames(), excludeDirNames: [],
                       perItemCapBytes: perItemCapBytes, into: &files, report: &report)
        collectBundles(cfg.appending(path: "plugins"), rel: "plugins",
                       allowedExt: ["js", "ts", "mjs", "cjs", "json", "md"],
                       skipNames: [], excludeDirNames: ["node_modules"],
                       perItemCapBytes: perItemCapBytes, into: &files, report: &report)

        let root: [String: Any] = ["schema": schema, "defaults": defaultsBlob, "files": files]
        guard let plist = try? PropertyListSerialization.data(
                fromPropertyList: root, format: .binary, options: 0),
              let compressed = plist.prosperCompressed() else { return nil }
        return (compressed, report)
    }

    static func apply(_ decryptedPayload: Data) {
        guard let plist = decryptedPayload.prosperDecompressed(),
              let root = (try? PropertyListSerialization.propertyList(
                from: plist, options: [], format: nil)) as? [String: Any] else { return }

        let defaults = UserDefaults.standard
        if let defaultsBlob = root["defaults"] as? Data,
           let dict = (try? PropertyListSerialization.propertyList(
            from: defaultsBlob, options: [], format: nil)) as? [String: Any] {
            for (key, value) in dict { defaults.set(value, forKey: key) }
        }

        if let files = root["files"] as? [String: Any] {
            let cfg = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/prosper")
            for (rel, value) in files {
                guard let data = value as? Data, !rel.contains("..") else { continue }
                let url = cfg.appending(path: rel)
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: [.atomic])
            }
        }
    }

    // MARK: - Collection helpers

    private static func collectFile(_ url: URL, rel: String, capBytes: Int,
                                    into files: inout [String: Data], report: inout SyncReport) {
        guard let data = try? Data(contentsOf: url) else { return }
        if data.count > capBytes {
            report.excluded.append(.init(name: rel, detail: "too large (\(kb(data.count)) > \(kb(capBytes)))", bytes: data.count))
            return
        }
        files[rel] = data
        report.includedFiles.append(.init(name: rel, detail: "synced", bytes: data.count))
    }

    private static func collectFlatDir(_ dir: URL, rel: String, allowedExt: Set<String>, capBytes: Int,
                                       into files: inout [String: Data], report: inout SyncReport) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items where allowedExt.contains(item.pathExtension.lowercased()) {
            guard let data = try? Data(contentsOf: item) else { continue }
            let name = "\(rel)/\(item.lastPathComponent)"
            if data.count > capBytes {
                report.excluded.append(.init(name: name, detail: "too large (\(kb(data.count)))", bytes: data.count))
                continue
            }
            files[name] = data
            report.includedFiles.append(.init(name: name, detail: "synced", bytes: data.count))
        }
    }

    /// One directory per item (extension or plugin). Synced only if fully text,
    /// free of dependency dirs, and compressing under `perItemCapBytes`. Bundled
    /// (system) extensions in `skipNames` are ignored — the app re-supplies those.
    private static func collectBundles(_ root: URL, rel: String, allowedExt: Set<String>,
                                       skipNames: Set<String>, excludeDirNames: Set<String>,
                                       perItemCapBytes: Int,
                                       into files: inout [String: Data], report: inout SyncReport) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".") || skipNames.contains(name) { continue }
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }

            var collected: [String: Data] = [:]
            var rejection: String?
            walk(item, prefix: "", allowedExt: allowedExt, excludeDirNames: excludeDirNames,
                 collected: &collected, rejection: &rejection)

            let display = "\(rel)/\(name)"
            if let reason = rejection {
                report.excluded.append(.init(name: display, detail: reason, bytes: 0))
                continue
            }
            if collected.isEmpty { continue }

            let itemPlist = (try? PropertyListSerialization.data(
                fromPropertyList: collected, format: .binary, options: 0)) ?? Data()
            let compressed = itemPlist.prosperCompressed()?.count ?? itemPlist.count
            if compressed > perItemCapBytes {
                report.excluded.append(.init(
                    name: display,
                    detail: "too large (\(kb(compressed)) compressed > \(kb(perItemCapBytes)) limit)",
                    bytes: compressed))
                continue
            }
            for (sub, data) in collected { files["\(display)/\(sub)"] = data }
            report.includedFiles.append(.init(name: display, detail: "synced (\(kb(compressed)) compressed)", bytes: compressed))
        }
    }

    private static func walk(_ url: URL, prefix: String, allowedExt: Set<String>, excludeDirNames: Set<String>,
                             collected: inout [String: Data], rejection: inout String?) {
        let fm = FileManager.default
        guard rejection == nil,
              let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for child in children {
            if rejection != nil { return }
            let cname = child.lastPathComponent
            if cname.hasPrefix(".") { continue }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                if excludeDirNames.contains(cname) { rejection = "has \(cname) (dependencies)"; return }
                walk(child, prefix: prefix + cname + "/", allowedExt: allowedExt,
                     excludeDirNames: excludeDirNames, collected: &collected, rejection: &rejection)
            } else {
                let ext = child.pathExtension.lowercased()
                guard allowedExt.contains(ext) else { rejection = "has non-text file .\(ext)"; return }
                if let data = try? Data(contentsOf: child) { collected[prefix + cname] = data }
            }
        }
    }

    /// Bundled system-extension folder names, read directly from the app bundle
    /// (avoids touching the @MainActor ExtensionRegistry from a background task).
    private static func bundledExtensionNames() -> Set<String> {
        guard let dir = Bundle.main.url(forResource: "extensions", withExtension: nil),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return Set(items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent })
    }

    private static func kb(_ bytes: Int) -> String { "\(max(1, bytes / 1024)) KB" }
}

// MARK: - Synced keys

enum SyncedKeys {
    /// UserDefaults keys the user changes via Settings that should sync. Excludes
    /// machine-local / transient state: migration flags, runtime
    /// LoRA A/B counters, and machine-specific paths (agentWorkingDirectory,
    /// agentWritableRoots) which wouldn't be valid on another Mac.
    static let keys: Set<String> = [
        // General / completions
        "autocompleteEnabled", "coreModel", "launchAtLogin", "completionLength",
        "completionsEnabledByDefault", "useClipboardContext", "midlineCompletionsEnabled",
        "emojiSuggestionsEnabled", "suppressOnTypo", "trailingSpaceAfterWordAccept",
        "showSuggestedFixes", "dismissOverlaysOnClick", "inlineKVBits",
        "speculativeDecodingEnabled", "draftModelId", "numDraftTokens",
        // Personalization
        "customInstructions", "userName", "userLanguages", "voiceStyle",
        "collectTypingHistory", "personalizeWordChoice", "emojiSkinTone", "emojiGender",
        // Apps / per-app
        "disabledBundleIds", "disableTabBundleIds", "enabledBundleIds",
        "improveCompatBundleIds", "perAppCustomInstructions", "disabledDomains",
        // Context / vision
        "useScreenshotContext", "improveAppearanceFromScreenshot", "useOCRContext",
        // Clipboard
        "clipboardHistoryEnabled", "clipboardHistoryMaxItems",
        // UI
        "showMenuBarIcon", "showDockIcon", "showAccessoryButton",
        // Updates / analytics
        "automaticUpdateChecks", "allowBetaUpdates", "analyticsEnabled",
        // Coding agent
        "agentModel", "agentMCPServers", "agentHooks", "agentPersona",
        "agentBypassAll", "agentApprovalPolicy", "agentNetworkAccess",
        "agentTemperature", "agentTopP",
        // LoRA (user-facing toggles/params; runtime counters excluded)
        "loraEnabled", "loraRank", "loraNumLayers", "loraIterations",
        "loraMinSamples", "loraABMinSamples",
    ]

    /// Key prefixes synced wholesale:
    /// - `shortcut.` — every per-action and custom shortcut.
    /// - `ext.` — every extension's settings (`ext.<id>.<key>`), so an extension
    ///   installed from the marketplace carries its config across devices with no
    ///   per-extension allowlist to maintain.
    static let prefixes: [String] = ["shortcut.", "ext."]

    /// `ext.`-namespaced keys that are machine-local runtime/UI state, NOT user
    /// settings — excluded so the wholesale `ext.` prefix doesn't sync them.
    static let excluded: Set<String> = [
        "ext.timers.v1",          // re-armed timer entries (per-machine runtime)
        "ext.collapse.user",      // Extensions-pane section collapse (UI only)
        "ext.collapse.system",
        "ext.collapse.market",
    ]
}
