import AppKit
import SwiftUI

/// Renders one extension settings section in the Settings window. Tier A (static)
/// builds a `SettingsUI` from the manifest controls (+ current host.prefs values);
/// Tier B (dynamic) renders the extension's `settings_render` tree and dispatches
/// interactions to `settings_action`. Both feed the same `SettingsUIView`, drawn
/// with the neon Settings vocabulary. See EXTENSION_SETTINGS_SPEC.md.
struct ExtensionSettingsPane: View {
    @ObservedObject var registry: ExtensionRegistry
    let record: ExtensionRecord
    let section: SettingsSection

    @State private var ui: SettingsUI?
    @State private var busy = false
    /// Bumped after the user returns from System Settings, to re-read permission grants.
    @State private var permissionTick = 0

    var body: some View {
        Group {
            if let ui {
                SettingsUIView(ui: ui, section: section, busy: busy,
                               permissionTick: permissionTick, onEvent: handle)
            } else {
                NeonScroll {
                    PaneTitle(title: section.title, accent: section.accent,
                              subtitle: section.subtitle ?? "")
                    ProgressView().controlSize(.small)
                }
            }
        }
        .onAppear(perform: reload)
    }

    // MARK: Load

    private func reload() {
        if section.isDynamic {
            busy = true
            Task {
                let next = await registry.renderSettingsAsync(
                    extensionID: record.id, sectionID: section.id)
                await MainActor.run { if let next { ui = next }; busy = false }
            }
        } else {
            ui = SettingsUI.fromManifest(section) { key in
                registry.prefValue(extensionID: record.id, key: key)
            }
        }
    }

    // MARK: Events

    private func handle(_ event: SettingsEvent) {
        // Native verbs run natively in both tiers.
        switch event {
        case .openURL(let s): open(url: s); return
        case .reveal(let path): reveal(path); return
        case .permissionOpen(let name):
            PermissionsManager.openSettings(forPermission: name); permissionTick += 1; return
        case .recheck:
            permissionTick += 1; if !section.isDynamic { reload() }; return
        default: break
        }

        if section.isDynamic { dispatchDynamic(event); return }

        // Tier A: persist scalar edits to host.prefs.
        switch event {
        case .setValue(let key, let value):
            registry.setSetting(extensionID: record.id, key: key, value: value)
            reload()
        default:
            break   // buttons / records have no native meaning in a static section
        }
    }

    private func dispatchDynamic(_ event: SettingsEvent) {
        let (actionID, value, form) = Self.encode(event)
        guard !actionID.isEmpty else { return }
        busy = true
        Task {
            let next = await registry.dispatchSettingsActionAsync(
                extensionID: record.id, sectionID: section.id,
                actionID: actionID, value: value, formValues: form)
            await MainActor.run { if let next { ui = next }; busy = false }
        }
    }

    private static func encode(_ event: SettingsEvent) -> (String, String?, [String: String]) {
        switch event {
        case .setValue(let key, let value): return ("set:\(key)", value, [:])
        case .button(let id): return (id, nil, [:])
        case .recordAdd(let r): return ("record.add:\(r)", nil, [:])
        case .recordDelete(let r, let id): return ("record.delete:\(r):\(id)", nil, [:])
        case .recordSave(let r, let id, let fields): return ("record.save:\(r):\(id)", nil, fields)
        default: return ("", nil, [:])
        }
    }

    private func open(url s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
    private func reveal(_ path: String) {
        let p = (path as NSString).expandingTildeInPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
}

// MARK: - Renderer

struct SettingsUIView: View {
    let ui: SettingsUI
    let section: SettingsSection
    let busy: Bool
    let permissionTick: Int
    let onEvent: (SettingsEvent) -> Void

    var body: some View {
        NeonScroll {
            PaneTitle(title: ui.title ?? section.title, accent: section.accent,
                      subtitle: ui.subtitle ?? section.subtitle ?? "")
            ForEach(ui.sections) { sec in
                NeonSection(sec.title, accent: sec.accent, footer: sec.footer) {
                    // Index, not row.id: info rows with no id/key/actionID all decode
                    // to the same id ("info.row"), and ForEach with duplicate ids
                    // renders the first match N times (the "What's loaded" 4× dup bug).
                    ForEach(Array(sec.rows.enumerated()), id: \.offset) { idx, row in
                        if idx > 0, needsDivider(row) { NeonDivider() }
                        SettingsRowView(row: row, permissionTick: permissionTick, onEvent: onEvent)
                    }
                }
            }
            if busy {
                HStack { ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(Neon.textSecondary) }
            }
        }
    }

    /// Records rows manage their own internal dividers; scalar rows get one between.
    private func needsDivider(_ row: SettingsUIRow) -> Bool { row.kind != "records" }
}

// MARK: - One row (dispatches by kind)

private struct SettingsRowView: View {
    let row: SettingsUIRow
    let permissionTick: Int
    let onEvent: (SettingsEvent) -> Void

    var body: some View {
        switch row.kind {
        case "toggle":     ToggleRow(row: row, onEvent: onEvent)
        case "enum":       EnumRow(row: row, onEvent: onEvent)
        case "number", "stepper": NumberRow(row: row, onEvent: onEvent)
        case "text", "secret":    ScalarFieldRow(row: row, onEvent: onEvent)
        case "path":       PathRow(row: row, onEvent: onEvent)
        case "info":       InfoRow(row: row)
        case "permission": PermissionRow(row: row, onEvent: onEvent).id("\(row.name ?? "")-\(permissionTick)")
        case "button":     ButtonRow(row: row, onEvent: onEvent)
        case "link":       LinkRow(row: row, onEvent: onEvent)
        case "records":    RecordsRow(row: row, onEvent: onEvent)
        default:           InfoRow(row: row)
        }
    }
}

// MARK: - Scalar controls

private struct ToggleRow: View {
    let row: SettingsUIRow
    let onEvent: (SettingsEvent) -> Void
    var body: some View {
        NeonRow(row.title ?? row.key ?? "", subtitle: row.subtitle) {
            HStack(spacing: 8) {
                if let badge = row.badge, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Neon.blue.opacity(0.18)))
                        .foregroundStyle(Neon.blue)
                }
                Toggle("", isOn: Binding(
                    get: { (row.value ?? "false") == "true" },
                    set: { onEvent(.setValue(key: row.key ?? "", value: $0 ? "true" : "false")) }))
                    .labelsHidden()
            }
        }
    }
}

private struct EnumRow: View {
    let row: SettingsUIRow
    let onEvent: (SettingsEvent) -> Void
    private var options: [String] { row.options ?? [] }
    private func label(_ i: Int, _ value: String) -> String {
        (row.optionLabels?[safe: i]) ?? value
    }
    var body: some View {
        NeonRow(row.title ?? row.key ?? "", subtitle: row.subtitle) {
            Picker("", selection: Binding(
                get: { row.value ?? options.first ?? "" },
                set: { onEvent(.setValue(key: row.key ?? "", value: $0)) })) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, value in
                    Text(label(i, value)).tag(value)
                }
            }
            .labelsHidden()
            // Hug the menu button to its content (the selected code) so NeonRow's
            // Spacer pushes its trailing edge flush right — lining it up with the
            // other rows' controls (toggle switch, number field) instead of the
            // picker stretching and floating mid-row.
            .fixedSize()
        }
    }
}

private struct NumberRow: View {
    let row: SettingsUIRow
    let onEvent: (SettingsEvent) -> Void
    @State private var text: String = ""
    var body: some View {
        NeonRow(row.title ?? row.key ?? "", subtitle: row.subtitle) {
            TextField(row.placeholder ?? "", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 120)
                .onAppear { text = row.value ?? "" }
                .onSubmit { commit() }
        }
    }
    private func commit() {
        let n = Double(text) ?? row.min ?? 0
        let clamped = min(max(n, row.min ?? -.greatestFiniteMagnitude),
                          row.max ?? .greatestFiniteMagnitude)
        // Keep integers integer-formatted.
        let out = (clamped == clamped.rounded()) ? String(Int(clamped)) : String(clamped)
        onEvent(.setValue(key: row.key ?? "", value: out))
    }
}

private struct ScalarFieldRow: View {
    let row: SettingsUIRow
    let onEvent: (SettingsEvent) -> Void
    @State private var text: String = ""
    var body: some View {
        NeonRow(row.title ?? row.key ?? "", subtitle: row.subtitle) {
            Group {
                if row.kind == "secret" {
                    SecureField(row.placeholder ?? "", text: $text).onSubmit(commit)
                } else {
                    TextField(row.placeholder ?? "", text: $text).onSubmit(commit)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 260)
            .onAppear { text = row.value ?? "" }
        }
    }
    private func commit() { onEvent(.setValue(key: row.key ?? "", value: text)) }
}

private struct PathRow: View {
    let row: SettingsUIRow
    let onEvent: (SettingsEvent) -> Void
    @State private var text: String = ""
    var body: some View {
        NeonRow(row.title ?? row.key ?? "", subtitle: row.subtitle) {
            HStack(spacing: 6) {
                TextField(row.placeholder ?? "~/folder", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onAppear { text = row.value ?? "" }
                    .onSubmit { onEvent(.setValue(key: row.key ?? "", value: text)) }
                Button("Choose…", action: choose).buttonStyle(.borderless).font(.caption)
            }
        }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
            onEvent(.setValue(key: row.key ?? "", value: url.path))
        }
    }
}

private struct InfoRow: View {
    let row: SettingsUIRow
    var body: some View {
        NeonRow(row.title ?? "", subtitle: row.subtitle) { EmptyView() }
    }
}

// MARK: - Permission / buttons / links

private struct PermissionRow: View {
    let row: SettingsUIRow
    let onEvent: (SettingsEvent) -> Void
    private var name: String { row.name ?? "" }
    private var granted: Bool { PermissionsManager.isGranted(name) }
    var body: some View {
        NeonRow(row.title ?? PermissionsManager.label(forPermission: name),
                subtitle: row.subtitle ?? (granted ? "Granted" : "Required — grant in System Settings")) {
            HStack(spacing: 10) {
                Label(granted ? "Granted" : "Not granted",
                      systemImage: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(granted ? Neon.blue : Neon.magenta)
                if !granted {
                    Button("Open") { onEvent(.permissionOpen(name: name)) }.buttonStyle(.neon)
                }
                Button("Re-check") { onEvent(.recheck) }.buttonStyle(.neon)
            }
        }
    }
}

private struct ButtonRow: View {
    let row: SettingsUIRow
    let onEvent: (SettingsEvent) -> Void
    var body: some View {
        HStack {
            Button(row.title ?? "Run", action: fire)
                .buttonStyle(row.controlStyle == "destructive" ? .neonDestructive : .neon)
            if let subtitle = row.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(Neon.textSecondary)
            }
            Spacer()
        }
    }
    private func fire() {
        switch row.action {
        case "reveal": if let f = row.file { onEvent(.reveal(path: f)) }
        case "open-url": if let u = row.url { onEvent(.openURL(u)) }
        default: onEvent(.button(actionID: row.actionID ?? row.id))
        }
    }
}

private struct LinkRow: View {
    let row: SettingsUIRow
    let onEvent: (SettingsEvent) -> Void
    var body: some View {
        NeonRow(row.title ?? "", subtitle: row.subtitle) {
            Button("Open") {
                if let u = row.url { onEvent(.openURL(u)) }
                else if let f = row.file { onEvent(.reveal(path: f)) }
            }.buttonStyle(.borderless).font(.caption)
        }
    }
}

// MARK: - Editable record collection (Tier B `records`)

private struct RecordsRow: View {
    /// Sentinel `editingID` for the inline "add new" editor (no server record yet).
    private static let newID = "__new__"

    let row: SettingsUIRow
    let onEvent: (SettingsEvent) -> Void
    @State private var editingID: String?
    @State private var working: [String: String] = [:]

    private var records: [SettingsUIRecord] { row.records ?? [] }
    private var recordsID: String { row.id }
    /// Field schema for a brand-new record (Tier-B `fields` template).
    private var template: [SettingsUIField] { row.fields ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if records.isEmpty, editingID != Self.newID {
                Text(row.emptyText ?? "Nothing here yet. Add one below.")
                    .font(.system(size: 12)).foregroundStyle(Neon.textSecondary)
            } else {
                ForEach(Array(records.enumerated()), id: \.element.id) { idx, rec in
                    if idx > 0 { NeonDivider() }
                    recordView(rec)
                }
            }
            if editingID == Self.newID {
                if !records.isEmpty { NeonDivider() }
                editor(fields: template, onSave: { saveNew() })
            }
            NeonDivider()
            HStack {
                Button(action: addTapped) {
                    Label(row.addLabel ?? "Add", systemImage: "plus")
                }.buttonStyle(.neon).disabled(editingID == Self.newID)
                Spacer()
                if let file = row.revealFile {
                    Button { onEvent(.reveal(path: file)) } label: {
                        Label(row.revealLabel ?? "Reveal file", systemImage: "folder")
                    }.buttonStyle(.borderless).foregroundStyle(Neon.textSecondary)
                }
            }
        }
    }

    /// Add-then-edit inline when a field template exists (native parity); otherwise
    /// fall back to a server `record.add` round-trip.
    private func addTapped() {
        if template.isEmpty { onEvent(.recordAdd(recordsID: recordsID)); return }
        working = [:]
        for f in template { working[f.id] = f.value ?? "" }
        editingID = Self.newID
    }

    private func saveNew() {
        var fields = working
        for f in template where fields[f.id] == nil { fields[f.id] = f.value ?? "" }
        // Empty recordID → the extension treats this as a create.
        onEvent(.recordSave(recordsID: recordsID, recordID: "", fields: fields))
        editingID = nil; working = [:]
    }

    @ViewBuilder
    private func editor(fields: [SettingsUIField], onSave: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields) { field in fieldEditor(field) }
            HStack(spacing: 8) {
                Button("Save", action: onSave).buttonStyle(.neon)
                Button("Cancel") { editingID = nil; working = [:] }
                    .buttonStyle(.borderless).foregroundStyle(Neon.textSecondary)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func recordView(_ rec: SettingsUIRecord) -> some View {
        if editingID == rec.id {
            editor(fields: rec.fields ?? [], onSave: { save(rec) })
        } else {
            HStack(spacing: 10) {
                Image(systemName: rec.icon ?? "circle.fill")
                    .foregroundStyle(Neon.blue).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.title ?? "(unnamed)")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Neon.textPrimary)
                    if let sub = rec.subtitle {
                        Text(sub).font(.system(size: 11)).foregroundStyle(Neon.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Button { beginEdit(rec) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                Button(role: .destructive) {
                    onEvent(.recordDelete(recordsID: recordsID, recordID: rec.id))
                } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func fieldEditor(_ field: SettingsUIField) -> some View {
        let binding = Binding(
            get: { working[field.id] ?? field.value ?? "" },
            set: { working[field.id] = $0 })
        switch field.kind {
        case "secret":
            SecureField(field.label ?? field.id, text: binding).textFieldStyle(.roundedBorder)
        case "enum":
            Picker(field.label ?? field.id, selection: binding) {
                ForEach(field.options ?? [], id: \.self) { Text($0).tag($0) }
            }
        case "toggle":
            Toggle(field.label ?? field.id, isOn: Binding(
                get: { (working[field.id] ?? field.value ?? "false") == "true" },
                set: { working[field.id] = $0 ? "true" : "false" }))
        case "textarea":
            NeonTextEditor(text: binding, minHeight: 84)
        case "richtext":
            // RTF editor, unless a sibling toggle says this body is plain text.
            if let tk = field.toggleKey, (working[tk] ?? "false") != "true" {
                NeonTextEditor(text: binding, minHeight: 84)
            } else {
                NeonRichTextEditor(rtf: binding, minHeight: 84)
            }
        default:
            TextField(field.placeholder ?? field.label ?? field.id, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func beginEdit(_ rec: SettingsUIRecord) {
        working = [:]
        for f in rec.fields ?? [] { working[f.id] = f.value ?? "" }
        editingID = rec.id
    }

    private func save(_ rec: SettingsUIRecord) {
        var fields = working
        // Ensure every declared field is present (so blanks persist as blanks).
        for f in rec.fields ?? [] where fields[f.id] == nil { fields[f.id] = f.value ?? "" }
        onEvent(.recordSave(recordsID: recordsID, recordID: rec.id, fields: fields))
        editingID = nil; working = [:]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
