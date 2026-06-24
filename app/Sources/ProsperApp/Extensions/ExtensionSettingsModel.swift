import Foundation

/// Lenient keyed decoding helpers. The in-VM Lua encoder serialises an *empty*
/// table as `{}` (an object), not `[]`, so any settings array can arrive as `{}`
/// on a fresh/empty render. `array(_:)` tolerates that (and a missing key) → [].
private extension KeyedDecodingContainer {
    // `try? decodeIfPresent(_:forKey:)` yields a double optional (`T??`); the inner
    // `?? nil` flattens it to `T?` before any further defaulting.
    func array<T: Decodable>(_ key: Key) -> [T] {
        ((try? decodeIfPresent([T].self, forKey: key)) ?? nil) ?? []
    }
    func str(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }
    func dbl(_ key: Key) -> Double? {
        (try? decodeIfPresent(Double.self, forKey: key)) ?? nil
    }
    func strs(_ key: Key) -> [String]? {
        (try? decodeIfPresent([String].self, forKey: key)) ?? nil
    }
}

/// The decoded settings UI for one extension section — the single model the
/// SwiftUI renderer consumes. Produced two ways that converge here: Tier A maps a
/// manifest `SettingsSection.controls` into it (reading host.prefs); Tier B decodes
/// it from the extension's `settings_render` JSON. Field names ARE the JSON
/// contract a dynamic render handler emits (camelCase: `optionLabels`, `actionID`,
/// `addLabel`, `revealFile`). See EXTENSION_SETTINGS_SPEC.md.
struct SettingsUI: Decodable, Equatable {
    var title: String?
    var subtitle: String?
    var sections: [SettingsUISection]

    init(title: String?, subtitle: String?, sections: [SettingsUISection]) {
        self.title = title; self.subtitle = subtitle; self.sections = sections
    }
    enum K: String, CodingKey { case title, subtitle, sections }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        title = c.str(.title); subtitle = c.str(.subtitle)
        sections = c.array(.sections)
    }

    static func decode(json: String) throws -> SettingsUI {
        guard let data = json.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "non-utf8 settings JSON"))
        }
        return try JSONDecoder().decode(SettingsUI.self, from: data)
    }
}

struct SettingsUISection: Decodable, Equatable, Identifiable {
    var id: String
    var title: String?
    var accent: String?
    var footer: String?
    var rows: [SettingsUIRow]

    init(id: String, title: String?, accent: String?, footer: String?, rows: [SettingsUIRow]) {
        self.id = id; self.title = title; self.accent = accent; self.footer = footer; self.rows = rows
    }
    enum K: String, CodingKey { case id, title, accent, footer, rows }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.str(.title); accent = c.str(.accent); footer = c.str(.footer)
        rows = c.array(.rows)
    }
}

/// One row. `kind` discriminates; the relevant optional fields are populated.
/// kinds: group | toggle | text | secret | number | stepper | enum | path | info
///        | permission | button | link | records
struct SettingsUIRow: Decodable, Equatable, Identifiable {
    var id: String
    var kind: String
    var key: String?
    var title: String?
    var subtitle: String?
    var value: String?
    var placeholder: String?
    var options: [String]?
    var optionLabels: [String]?
    var name: String?
    var url: String?
    var file: String?
    var action: String?
    var actionID: String?
    var style: String?
    var min: Double?
    var max: Double?
    var step: Double?
    var records: [SettingsUIRecord]?
    var addLabel: String?
    var revealFile: String?
    /// Optional trailing pill (e.g. a live count) shown before a toggle's switch.
    var badge: String?
    /// Records control only: field schema for a *new* record. When present, the
    /// Add button opens an inline blank editor (matching native add-then-edit)
    /// instead of round-tripping `record.add` to the extension.
    var fields: [SettingsUIField]?
    /// Records control only: empty-state text and the reveal button's label.
    var emptyText: String?
    var revealLabel: String?
    /// Button only: when set, the button opens a popover showing this text
    /// (dismissed on outside click) instead of firing an action.
    var help: String?

    var controlStyle: String { style ?? "neon" }

    init(id: String, kind: String, key: String? = nil, title: String? = nil, subtitle: String? = nil,
         value: String? = nil, placeholder: String? = nil, options: [String]? = nil,
         optionLabels: [String]? = nil, name: String? = nil, url: String? = nil, file: String? = nil,
         action: String? = nil, actionID: String? = nil, style: String? = nil,
         min: Double? = nil, max: Double? = nil, step: Double? = nil,
         records: [SettingsUIRecord]? = nil, addLabel: String? = nil, revealFile: String? = nil,
         fields: [SettingsUIField]? = nil, emptyText: String? = nil, revealLabel: String? = nil,
         badge: String? = nil, help: String? = nil) {
        self.id = id; self.kind = kind; self.key = key; self.title = title; self.subtitle = subtitle
        self.value = value; self.placeholder = placeholder; self.options = options
        self.optionLabels = optionLabels; self.name = name; self.url = url; self.file = file
        self.action = action; self.actionID = actionID; self.style = style
        self.min = min; self.max = max; self.step = step
        self.records = records; self.addLabel = addLabel; self.revealFile = revealFile
        self.fields = fields; self.emptyText = emptyText; self.revealLabel = revealLabel
        self.badge = badge; self.help = help
    }

    enum K: String, CodingKey {
        case id, kind, key, title, subtitle, value, placeholder, options, optionLabels
        case name, url, file, action, actionID, style, min, max, step, records, addLabel, revealFile
        case fields, emptyText, revealLabel, badge, help
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        kind = try c.decode(String.self, forKey: .kind)
        key = c.str(.key); title = c.str(.title); subtitle = c.str(.subtitle)
        // `id` is the row's identity. Tier-B handlers routinely omit it on keyed
        // rows (toggle/enum/number carry only `key`); fall back the same way Tier-A's
        // fromManifest does (key ?? id ?? actionID), so a missing `id` doesn't fail
        // the whole lenient `rows` decode and silently drop the section's controls.
        id = c.str(.id) ?? key ?? c.str(.actionID) ?? "\(kind).row"
        value = c.str(.value); placeholder = c.str(.placeholder)
        options = c.strs(.options); optionLabels = c.strs(.optionLabels)
        name = c.str(.name); url = c.str(.url); file = c.str(.file)
        action = c.str(.action); actionID = c.str(.actionID); style = c.str(.style)
        min = c.dbl(.min); max = c.dbl(.max); step = c.dbl(.step)
        // A `records` row keeps an empty [] (so the Add button still shows); other
        // rows carry records only if a non-empty list was provided.
        let recs: [SettingsUIRecord] = c.array(.records)
        records = (kind == "records" || !recs.isEmpty) ? recs : nil
        addLabel = c.str(.addLabel); revealFile = c.str(.revealFile)
        let tmpl: [SettingsUIField] = c.array(.fields)
        fields = tmpl.isEmpty ? nil : tmpl
        emptyText = c.str(.emptyText); revealLabel = c.str(.revealLabel)
        badge = c.str(.badge); help = c.str(.help)
    }
}

struct SettingsUIRecord: Decodable, Equatable, Identifiable {
    var id: String
    var title: String?
    var subtitle: String?
    var icon: String?
    var fields: [SettingsUIField]?

    enum K: String, CodingKey { case id, title, subtitle, icon, fields }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.str(.title); subtitle = c.str(.subtitle); icon = c.str(.icon)
        let f: [SettingsUIField] = c.array(.fields)
        fields = f
    }
}

struct SettingsUIField: Decodable, Equatable, Identifiable {
    var id: String
    var label: String?
    var kind: String?
    var value: String?
    var placeholder: String?
    var options: [String]?
    /// `richtext` field only: id of a sibling `toggle` field. When that toggle is
    /// off, the body is edited as plain multi-line text instead of RTF.
    var toggleKey: String?

    enum K: String, CodingKey { case id, label, kind, value, placeholder, options, toggleKey }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.str(.label); kind = c.str(.kind); value = c.str(.value)
        placeholder = c.str(.placeholder); options = c.strs(.options)
        toggleKey = c.str(.toggleKey)
    }
}

// MARK: - Tier A: manifest controls → SettingsUI

extension SettingsUI {
    /// Build a static section's UI from its manifest `controls`, reading current
    /// values via `prefs` (e.g. `registry.prefValue`). A `group` control opens a
    /// new titled sub-section; every other control becomes a row.
    static func fromManifest(_ section: SettingsSection,
                             prefs: (_ key: String) -> String?) -> SettingsUI {
        var sections: [SettingsUISection] = []
        var rows: [SettingsUIRow] = []
        var currentTitle: String? = nil
        var currentFooter: String? = nil
        var groupIndex = 0
        var rowIndex = 0

        // Map every keyed control's manifest default, so `visible_when` can resolve a
        // referenced pref even when the user never touched it (unset → default).
        let defaults: [String: String] = Dictionary(
            section.allControls.compactMap { c in
                c.key.map { ($0, c.default?.stringValue ?? "") }
            }, uniquingKeysWith: { a, _ in a })
        func isTruthy(_ key: String) -> Bool {
            let v = prefs(key) ?? defaults[key] ?? "false"
            return v == "true" || (Double(v).map { $0 != 0 } ?? false)
        }

        func flush() {
            guard !rows.isEmpty || currentTitle != nil else { return }
            sections.append(SettingsUISection(
                id: "\(section.id).g\(groupIndex)", title: currentTitle,
                accent: sections.isEmpty ? section.accent : nil, footer: currentFooter, rows: rows))
            rows = []
        }

        for control in section.allControls {
            if let gate = control.visible_when, !isTruthy(gate) { continue }
            if control.kind == .group {
                flush()
                groupIndex += 1
                currentTitle = control.title
                currentFooter = control.footer
                continue
            }
            rowIndex += 1
            let rowID = control.key ?? control.id ?? control.name ?? "\(section.id).r\(rowIndex)"
            let value = (control.key.flatMap(prefs)) ?? control.default?.stringValue
            rows.append(SettingsUIRow(
                id: rowID, kind: control.kind.rawValue,
                key: control.key, title: control.title, subtitle: control.subtitle,
                value: value, placeholder: control.placeholder,
                options: control.values, optionLabels: control.value_labels,
                name: control.name, url: control.url, file: control.file,
                action: control.action, actionID: control.id, style: control.style,
                min: control.min, max: control.max, step: control.step))
        }
        flush()
        return SettingsUI(title: nil, subtitle: section.subtitle, sections: sections)
    }
}

/// A unified interaction the renderer emits; Tier A handles it natively (write
/// prefs / native verb), Tier B forwards it to `settings_action`.
enum SettingsEvent: Equatable {
    case setValue(key: String, value: String)
    case button(actionID: String)
    case recordAdd(recordsID: String)
    case recordSave(recordsID: String, recordID: String, fields: [String: String])
    case recordDelete(recordsID: String, recordID: String)
    case openURL(String)
    case reveal(path: String)
    case permissionOpen(name: String)
    case recheck
}
