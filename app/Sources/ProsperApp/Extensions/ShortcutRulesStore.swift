import AppKit
import Foundation

/// User-configured global key shortcuts, owned natively (no extension required).
/// Replaces the old opinionated `appkeys` / `app-remaps` / `media-layer` system
/// extensions: instead of hard-coded combos, the user defines any number of rules in
/// Settings → Shortcuts and they feed the SAME shared key-rule engine
/// (`ExtensionKeyRules`) under a reserved pseudo-extension id. No defaults — the list
/// starts empty.
///
/// Storage is local UserDefaults JSON (b: local-first; settings-sync wraps it later).
@MainActor
final class ShortcutRulesStore {
    static let shared = ShortcutRulesStore()

    /// Reserved owner id in `ExtensionKeyRules`. Independent of any extension's
    /// enabled state, so these rules live as long as the app does.
    static let ownerID = "com.prosper.shortcuts"

    private static let defaultsKey = "nativeShortcutRules"

    enum ActionKind: String, Codable, CaseIterable {
        case launchApp   // open / activate an app
        case remap       // send a different key combo
        case sendMedia   // post a media/system key (PLAY, SOUND_UP, …)
        case swallow     // eat the trigger, do nothing
    }

    struct Rule: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        /// Trigger spec: a combo ("cmd+q", "f7", "alt+down") or a media key ("media:PLAY").
        var trigger: String = ""
        var action: ActionKind = .launchApp
        /// Action target: app bundle-id/path, remap combo, or media-key name. Ignored for `swallow`.
        var target: String = ""
        /// Only fire while the frontmost app is one of these bundle ids (empty = any).
        var apps: [String] = []
        /// Never fire while the frontmost app is one of these (empty = none).
        var notApps: [String] = []
        /// Require a double-press of the trigger within the double-tap window (remap only).
        var doubleTap: Bool = false
        var enabled: Bool = true
    }

    private(set) var rules: [Rule] = []

    private init() { rules = Self.load() }

    // MARK: - Persistence

    private static func load() -> [Rule] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Rule].self, from: data) else { return [] }
        return decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func setRules(_ newRules: [Rule]) {
        rules = newRules
        persist()
        apply()
    }

    // MARK: - Feed the engine

    /// Compile the enabled rules into the engine's JSON shape and register them.
    /// Idempotent — safe to call at launch and after every edit.
    func apply() {
        var objs: [[String: Any]] = []
        for r in rules where r.enabled && !r.trigger.isEmpty {
            var obj: [String: Any] = ["from": r.trigger]
            switch r.action {
            case .launchApp:
                guard !r.target.isEmpty else { continue }
                obj["launch"] = r.target
            case .remap:
                guard !r.target.isEmpty else { continue }
                if r.doubleTap { obj["double_tap"] = r.target } else { obj["to"] = r.target }
            case .sendMedia:
                guard !r.target.isEmpty else { continue }
                obj["system"] = r.target.uppercased()
            case .swallow:
                obj["swallow"] = true
            }
            if !r.apps.isEmpty { obj["apps"] = r.apps }
            if !r.notApps.isEmpty { obj["not_apps"] = r.notApps }
            objs.append(obj)
        }
        let json = (try? JSONSerialization.data(withJSONObject: objs))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        ExtensionKeyRules.shared.setRules(extensionID: Self.ownerID, json: json)
    }
}
