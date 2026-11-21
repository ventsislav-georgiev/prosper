import AppKit
import Foundation

/// #1811: extensions.list / enable / disable and themes.list / set. Enable and disable call the same
/// `ExtensionRegistry.setEnabled` the Extensions pane toggle does, and refuse an untrusted extension as the pane's
/// greyed toggle does (Trust stays a person's click). themes.set is settings.set's "theme" write
/// (`ControlSettings.apply`), so both commands share one ThemeStore path and one undo. Built per call: no observers.
@MainActor
enum ControlExtensions {
    /// Seam: the running app's registry; rows put a fake one here.
    static var registry: () -> ExtensionRegistry? = { (NSApp?.delegate as? AppDelegate)?.extensionRegistry }

    static func loaded() throws -> ExtensionRegistry {
        guard let r = registry() else { throw ControlError("extensions are not loaded yet") }
        return r
    }

    static func row(_ r: ExtensionRecord) -> ControlJSON {
        let meta = r.manifest.extension
        return .object([
            "id": .string(r.id), "title": .string(ExtensionRowText.title(meta.title, id: r.id)),
            "version": .string(OutsideText.shown(meta.version, max: ExtensionRowText.versionMax)),
            "enabled": .bool(r.enabled), "trusted": .bool(r.trusted), "builtIn": .bool(r.isSystem),
            "commands": .number(Double(r.manifest.contributes?.commands?.count ?? 0)),
        ])
    }

    static func setEnabled(_ on: Bool, args: [String: ControlJSON]) throws -> ControlChange {
        guard case .string(let id)? = args["id"] else { throw ControlError("missing argument 'id'") }
        let reg = try loaded()
        guard let record = reg.record(id: id) else { throw ControlError("unknown extension '\(OutsideText.shown(id, max: 80))' (extensions.list lists them)") }
        guard record.trusted else {
            throw ControlError("\(OutsideText.shown(id, max: 80)) needs a trust approval: a person reviews it and clicks Trust in Settings > Extensions")
        }
        let title = ExtensionRowText.title(record.manifest.extension.title, id: id)
        // setEnabled is not a no-op (it drops the async runtime and rebuilds routes), and the pane never calls it
        // with the current value; .change always logs, so a same-state call is refused instead.
        guard record.enabled != on else { throw ControlError("\(title) is already \(on ? "on" : "off")") }
        let was = record.enabled
        try reg.setEnabled(on, id: id)
        return ControlChange(summary: "\(title) \(on ? "on" : "off")", result: row(record)) {
            // The extension may be gone by the time Undo is clicked: nothing left to flip back.
            try? reg.setEnabled(was, id: id)
        }
    }

    static func themes() -> ControlJSON {
        let store = ThemeStore.shared
        let reg = registry()
        return .object(["themes": .array(store.available.map { d -> ControlJSON in
            let builtIn = d.extensionID.map { reg?.record(id: $0)?.isSystem == true } ?? true
            return .object([
                "id": .string(d.id), "title": .string(d.title), "appearance": .string(d.appearance.rawValue),
                "builtIn": .bool(builtIn), "extension": d.extensionID.map { .string($0) } ?? .null,
                "current": .bool(d.id == store.activeID),
            ])
        })])
    }
}

extension ControlRegistry {
    /// #1811: the supervisor adds `ControlRegistry.registerExtensions(&r)` to `standard()` on landing.
    static func registerExtensions(_ r: inout ControlRegistry) {
        let id = ["id": ControlArg(type: "string", required: true, summary: "an id from extensions.list")]
        r.register(ControlCommand(name: "extensions.list",
                                  summary: "Every installed extension: id, title, version, enabled, trusted, builtIn, commands (count).",
                                  args: [:], mutates: false) { _, _ in
            .object(["extensions": .array(try ControlExtensions.loaded().records.map { ControlExtensions.row($0) })])
        })
        r.register(.change(name: "extensions.enable", summary: "Turn an extension on, as its Settings toggle does. Untrusted ones are refused; Undo turns it back.",
                           args: id) { _, args in try ControlExtensions.setEnabled(true, args: args) })
        r.register(.change(name: "extensions.disable", summary: "Turn an extension off, as its Settings toggle does. Untrusted ones are refused; Undo turns it back.",
                           args: id) { _, args in try ControlExtensions.setEnabled(false, args: args) })
        r.register(ControlCommand(name: "themes.list",
                                  summary: "Every theme: id, title, appearance (dark/light), builtIn, extension, current.",
                                  args: [:], mutates: false) { _, _ in ControlExtensions.themes() })
        r.register(.change(name: "themes.set", summary: "Switch the theme (same as settings.set theme); Undo restores the previous one.",
                           args: ["id": ControlArg(type: "string", required: true, summary: "an id from themes.list")]) { _, args in
            guard case .string(let id)? = args["id"] else { throw ControlError("missing argument 'id' for themes.set") }
            return try ControlSettings.apply(["theme": .string(id)])
        })
    }
}
