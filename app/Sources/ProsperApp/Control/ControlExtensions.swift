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

    /// #1869: extensions.update's deadline, as kits.install's (ControlCLI gives up at 70 s).
    static var updateDeadline: Double = 60
    static let updateLate = "extensions.update ran past its deadline and stopped before the next extension; an update already "
        + "installing finished (each swaps its folder whole). extensions.list shows the versions now"

    /// One reply row. Every text is outside data (the manifest's and the listing's versions, an error's text): cleaned.
    static func updateRow(_ r: ExtensionRegistry.UpdateResult, _ reg: ExtensionRegistry) -> ControlJSON {
        var o: [String: ControlJSON] = [
            "id": .string(OutsideText.shown(r.id, max: 80)), "outcome": .string(r.outcome.rawValue),
            "from": .string(OutsideText.shown(r.from, max: ExtensionRowText.versionMax)),
        ]
        if let to = r.to { o["to"] = .string(OutsideText.shown(to, max: ExtensionRowText.versionMax)) }
        if let why = r.reason { o["reason"] = .string(OutsideText.shown(why, max: 400)) }
        if r.outcome == .updated, reg.record(id: r.id)?.manifest.contributes?.kit != nil {
            o["note"] = .string("an agent kit: its applied files stay at the old version until kits.apply (kits.list shows updateAvailable)")
        }
        return .object(o)
    }

    /// #1869: the Check for Updates button's check (force: no 24 h wait), quiet: an update that adds a permission is held
    /// as the daily check holds it, never asked. `id`: that extension only (a user one with an update source).
    static func update(_ args: [String: ControlJSON]) async throws -> ControlChange {
        let reg = try loaded()
        let only: String? = try args["id"].map { v in
            guard case .string(let id) = v else { throw ControlError("argument 'id' must be a string") }
            let name = OutsideText.shown(id, max: 80)
            guard let rec = reg.record(id: id) else { throw ControlError("unknown extension '\(name)' (extensions.list lists them)") }
            guard !rec.isSystem else { throw ControlError("\(name) is built in: it updates with Prosper, not here") }
            guard rec.manifest.extension.updateURL != nil else { throw ControlError("\(name) has no update source (no update_url)") }
            return id
        }
        let got = try await ControlSessionsRead.within(updateDeadline, "extensions.update", late: updateLate) { @MainActor in
            let results = await reg.checkForUpdates(force: true, quiet: true, only: only)
            return .success(.array(results.map { updateRow($0, reg) }))
        }
        guard case .array(let rows) = got else { throw ControlError("extensions.update: no reply") }
        let outcomes = rows.compactMap { row -> ControlJSON? in if case .object(let r) = row { return r["outcome"] } else { return nil } }
        let count = { (o: String) in outcomes.filter { $0 == .string(o) }.count }
        let summary = "checked \(rows.count): \(count("updated")) updated, \(count("held")) held, \(count("failed")) failed (no Undo: an update is a reinstall)"
        return ControlChange(summary: summary, result: .object(["results": got]), verb: "updated extensions")
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
        r.register(ControlKits.change("extensions.update",
                                      "Check extensions for updates now, as Settings > Extensions > Check for Updates (no daily wait), and install them. An update that asks for a new permission is held for a person's review, never asked here. Reply: results [{id, from, to, outcome (updated, upToDate, held, failed), reason}]. An updated agent kit stays applied at its old version until kits.apply (kits.list shows updateAvailable). No Undo: an update is a reinstall.",
                                      ["id": ControlArg(type: "string", summary: "only this extension (an id from extensions.list); all updatable ones when absent")]) {
            try await ControlExtensions.update($0)
        })
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
