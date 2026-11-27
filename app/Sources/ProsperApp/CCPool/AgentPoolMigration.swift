import Foundation

/// #2012 (design #2003 section 5): the one-off move of the account pool's settings from its ccpool names to the
/// Agent Account Pool's. Not CCPoolMigration (that one imports the Homebrew ccpool's vault).
///
/// AppDelegate runs it once at launch, before `extensions.discover()` reads the extension record sets and before
/// CCPoolRuntime builds its store or reads a key. After the first launch it is one defaults read (the marker).
/// The first launch does one rename(2) of a directory: metadata only, so it runs where it is called (main), as the
/// runtime that must wait for it is built on main right after. Logs labels only, never a path or a value.
enum AgentPoolMigration {
    static let markerKey = "agentPoolMigrated"
    static let oldExtensionID = "com.prosper.ccpool"
    static let newExtensionID = "com.prosper.agentpool"
    static let oldFolder = "ccpool"
    static let newFolder = "agentpool"
    /// Old key -> new key. Every ccpool* key the pane, the runtime or the island writes (rg 'ccpool' at 9edb279a).
    static let keys: [(old: String, new: String)] = [
        ("ccpoolRouteAgentSessions", CCPoolPaneModel.routeKey),
        ("ccpoolRouteCodexSessions", CCPoolPaneModel.codexRouteKey),
        ("ccpoolExhaustedThreshold", CCPoolPaneModel.exhaustedKey),
    ]
    /// The Settings window's stored sidebar selection (SettingsWindow's @AppStorage).
    static let selectedPaneKey = "settingsSelectedPane"

    /// `defaults` holds the pane's keys and the extension registry's record sets (both Preferences.defaults in the
    /// app); `support` is Application Support/Prosper, the parent of the pool's folder.
    @MainActor static func migrateV1(defaults: UserDefaults = Preferences.defaults,
                          support: URL = CCPoolStore.defaultDirectory.deletingLastPathComponent(),
                          logger: CCPoolLogger = CCPoolOSLog()) {
        guard defaults.object(forKey: markerKey) == nil else { return }
        // a. The extension record: enabled, trusted (and disabled, privileged) carried to the new id, old id dropped.
        ExtensionRegistry.carryRecord(from: oldExtensionID, to: newExtensionID, in: defaults)
        // b. Defaults: a stored value is carried, an absent one stays absent (the reader's default).
        for (old, new) in keys {
            if let value = defaults.object(forKey: old) { defaults.set(value, forKey: new) }
            defaults.removeObject(forKey: old)
        }
        if let pane = defaults.string(forKey: selectedPaneKey) { defaults.set(settingsPaneAlias(pane), forKey: selectedPaneKey) }
        // c. Files: one exclusive rename; an existing target is never replaced.
        let from = support.appendingPathComponent(oldFolder, isDirectory: true)
        let to = support.appendingPathComponent(newFolder, isDirectory: true)
        let exclusiveMove = { renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
        var moved = exclusiveMove()
        var setAside = false
        // An agentpool without state.json next to a ccpool with one is a by-product (an empty pane's store write or a
        // Codex scratch folder from a launch whose move failed), not the person's data: set it aside, never delete it.
        if moved == EEXIST, !hasState(to), hasState(from) {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let aside = support.appendingPathComponent("\(newFolder)-replaced-\(stamp.string(from: Date()))", isDirectory: true)
            guard renamex_np(to.path, aside.path, UInt32(RENAME_EXCL)) == 0 else {
                logger.note(nil, "agent pool migration: the agentpool folder could not be set aside (errno \(errno)); trying again next launch")
                return
            }
            setAside = true
            moved = exclusiveMove()
        }
        switch moved {
        case 0: logger.note(nil, setAside ? "agent pool migration: set aside the agentpool folder, then moved the ccpool folder to agentpool"
                                          : "agent pool migration: moved the ccpool folder to agentpool")
        case ENOENT: break   // no old folder (a fresh install, or nothing was ever stored)
        case EEXIST: logger.note(nil, "agent pool migration: kept both folders; nothing moved")
        default:
            // Marker unset. This launch's pool runs on a missing agentpool folder and its writes may create one; the next
            // launch's EEXIST branch above sets that by-product aside and moves the ccpool folder then.
            logger.note(nil, "agent pool migration: the ccpool folder could not be moved (errno \(moved)); trying again next launch")
            return
        }
        defaults.set(1, forKey: markerKey)
    }

    private static func hasState(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path)
    }
}
