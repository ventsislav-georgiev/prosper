import SwiftUI

/// #918 S4 (spec 4.6, 4.9, 4.12; errata A9): the kit pane over KitPaneModel, UNMOUNTED (S5 adds the Settings tab).
/// House Neon components and `sz()` throughout. Every control comes from `controls(_:)`, the one list the view draws
/// from (an id missing there is not drawn), so a row can read what is offered, enabled and labelled without an AX tree
/// (a never-shown window has none). Outside text (names, targets, README lines) goes through OutsideText.
/// Nothing here opens a file, a folder or a URL itself: `opener` is the seam (S5 passes NSWorkspace). The mounter calls
/// model.load(); the view starts nothing on its own.
struct KitPaneView: View {
    @ObservedObject var model: KitPaneModel
    let opener: KitPaneOpener
    @State private var readmeCollapsed = true

    static let applyNote = "settings.json changes apply to open Claude Code sessions; CLAUDE.md changes in new sessions"
    static let userScopeNote = "Prosper sees user scope only: project and local Claude Code settings are not read."
    static let editedNote = "kit files edited: the applied copy differs from what was applied. Repair writes it again."
    static let hooksOffNote = "Claude Code hooks are disabled (disableAllHooks): this kit's hooks and statusline do not run."
    static let untrustedNote = "Trust this kit in Extensions to apply, repair or roll it back."
    static let readmeMaxBytes = 64 << 10
    static let readmeMaxLines = 400

    var body: some View {
        let plan = Self.controls(model)
        VStack(alignment: .leading, spacing: sz(18)) {
            header(plan)
            if let reqs = model.facts?.requirements, !reqs.isEmpty { requirements(reqs) }
            if model.live == nil {
                NeonSection("Install") { KitInstallSheet(model: model) }
            } else {
                pieces(plan)
                NeonSection("Actions") {
                    fitting {
                        button(plan, "apply") { _ = model.apply() }
                        button(plan, "repair") { _ = model.repair() }
                        button(plan, "remove", destructive: true) { _ = model.remove() }
                    }
                }
            }
            if !Self.settingRows(model).isEmpty { settings(plan) }
            if let o = model.facts?.overrides, !o.isEmpty { overrides(o) }
        }
    }

    // MARK: header

    private func header(_ plan: [KitPaneControl]) -> some View {
        VStack(alignment: .leading, spacing: sz(18)) {
            NeonSection(OutsideText.shown(model.title, max: KitManifest.maxTitle)) {
                VStack(alignment: .leading, spacing: sz(8)) {
                    caption(Self.subtitle(model))
                    ForEach(Self.notes(model), id: \.self) { caption($0, color: Neon.textSecondary) }
                    ForEach(Self.alerts(model), id: \.self) { caption($0, color: Neon.magenta) }
                    fitting {
                        button(plan, "update") { _ = model.apply() }
                        button(plan, "rollback") { _ = model.rollback() }
                        button(plan, "reveal") { Self.reveal(model, opener) }
                        button(plan, "local") { Self.openLocal(model, opener) }
                    }
                }
            }
            NeonSection("README", collapsed: $readmeCollapsed) {
                if !readmeCollapsed { caption(Self.readme(Self.kitDir(model))) }
            }
        }
    }

    /// The version line: version, author, source, trust; the applied version when one is live.
    static func subtitle(_ m: KitPaneModel) -> String {
        let source = ["market": "Market", "github": "GitHub", "local": "Local folder"][m.source.rawValue] ?? ""
        var parts = ["Version " + OutsideText.shown(m.version, max: 64)]
        if !m.author.isEmpty { parts.append("by " + OutsideText.shown(m.author, max: 64)) }
        parts += [source, m.trusted ? "trusted" : "not trusted"]
        parts.append(m.live.map { "applied: " + OutsideText.shown($0, max: 64) } ?? "not applied")
        return parts.joined(separator: " - ")
    }

    /// The plain notes under the header: the A9 line, user scope, edited, drifted pieces, hooks off, untrusted.
    static func notes(_ m: KitPaneModel) -> [String] {
        var out = [applyNote, userScopeNote]
        if m.facts?.filesEdited == true { out.append(editedNote) }
        out += (m.facts?.drifted ?? []).map(KitPaneModel.driftNote) // #2099
        if m.facts?.hooksDisabled == true { out.append(hooksOffNote) }
        if !m.trusted { out.append(untrustedNote) }
        return out
    }

    /// The red lines: the restore warnings (R1409-i1 wording, see KitPaneModel.warnings), busy, the last result,
    /// and the market cap refusal (#1421 carry).
    static func alerts(_ m: KitPaneModel) -> [String] {
        var out = m.warnings
        if let b = m.busy { out.append(b) }
        if let r = m.result, r != m.busy { out.append(r) }
        if let c = m.facts?.sourceRefusal { out.append(KitInstallSheet.capText(c)) }
        return out.map { OutsideText.shown($0, max: 400) }
    }

    // MARK: requirements

    private func requirements(_ reqs: [KitPaneFacts.Requirement]) -> some View {
        NeonSection("Requirements") {
            VStack(alignment: .leading, spacing: sz(6)) {
                ForEach(reqs, id: \.name) { r in
                    NeonRow(r.name, subtitle: r.found ? "found on the login PATH" : "not found on the login PATH") { EmptyView() }
                }
            }
        }
    }

    // MARK: pieces

    struct PieceRow: Equatable {
        var id: String
        var kind: String
        /// the managed state, "off", or "not applied"
        var state: String
        var target: String?
        var hook: String?
        var inUse: String?
        var tools: [String]
        /// #922: a shell-path piece's exact rc line, shown before it is applied
        var shellLine: String? = nil
    }

    static func pieceRows(_ m: KitPaneModel, shell: String = KitRender.userLoginShell,
                          bashRC: @autoclosure () -> String = KitRender.bashLoginRC { FileManager.default.fileExists(atPath: NSHomeDirectory() + "/" + $0) }) -> [PieceRow] {
        guard case .ok(let v)? = m.facts?.preview else { return [] }
        let off = m.facts?.status?.off ?? []
        return v.kit.pieces.map { p in
            let st = m.facts?.status?.pieces.first { $0.id == p.id }
            // #920: an agents piece has no managed-config record; its state is the runtime's agents line (a refusal included)
            let agents = p.kind == .agents ? m.facts?.status?.agents[p.id] : nil
            let state = off.contains(p.id) ? "off" : (agents ?? st?.state.rawValue ?? (m.live == nil ? "not applied" : "on"))
            let hook = p.kind == .hook ? [p.event, p.matcher].compactMap { $0 }.joined(separator: " ") : nil
            return PieceRow(id: p.id, kind: p.kind.rawValue, state: state,
                            target: st.map { OutsideText.shown($0.target, max: 120) }, hook: hook.map { OutsideText.shown($0, max: 120) },
                            inUse: m.facts?.inUse[p.id], tools: (v.tools[p.id] ?? []).map(\.name).sorted(),
                            shellLine: p.kind == .shellPath
                                ? KitRender.shellPathNote(kitBin: m.facts?.kitBin ?? "", shell: shell, slug: v.slug, bashRC: shell == "bash" ? bashRC() : "").map { OutsideText.shown($0, max: 400) } : nil)
        }
    }

    /// The name a tool row draws (the same cap the piece rows use for outside text).
    static func toolName(_ t: String) -> String { OutsideText.shown(t, max: 120) }

    private func pieces(_ plan: [KitPaneControl]) -> some View {
        NeonSection("Pieces") {
            VStack(alignment: .leading, spacing: sz(10)) {
                ForEach(Array(Self.pieceRows(model).enumerated()), id: \.element.id) { i, row in
                    if i > 0 { NeonDivider() }
                    NeonRow(row.id, subtitle: Self.pieceLine(row)) {
                        HStack(spacing: sz(8)) {
                            toggle(plan, "piece:\(row.id)", isOn: Binding(get: { row.state != "off" },
                                                                         set: { model.toggle(row.id, on: $0) }))
                            menu(plan, row.id)
                        }
                    }
                    ForEach(row.tools, id: \.self) { t in
                        NeonRow(Self.toolName(t)) {
                            toggle(plan, "tool:\(row.id)/\(t)", isOn: Binding(get: { model.facts?.offTools[row.id]?.contains(t) != true },
                                                                             set: { _ = model.setTool(t, of: row.id, on: $0) }))
                        }
                        .padding(.leading, sz(16))
                    }
                }
                if model.pendingOff != nil {
                    caption(model.alsoOff.isEmpty ? "Switch it off?" : "Also switches off: " + model.alsoOff.joined(separator: ", "))
                    fitting {
                        button(plan, "confirm") { _ = model.confirmToggle() }
                        button(plan, "cancel") { model.cancelToggle() }
                    }
                }
            }
        }
    }

    static func pieceLine(_ r: PieceRow) -> String {
        [r.kind, r.state, r.target, r.hook, r.inUse, r.shellLine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
    }

    // MARK: settings and overrides

    static func settingRows(_ m: KitPaneModel) -> [KitManifest.Setting] {
        guard case .ok(let v)? = m.facts?.preview else { return [] }
        return v.kit.settings
    }

    private func settings(_ plan: [KitPaneControl]) -> some View {
        NeonSection("Kit settings") {
            VStack(alignment: .leading, spacing: sz(8)) {
                ForEach(Self.settingRows(model), id: \.key) { s in
                    let value = Binding(get: { model.settings[s.key] ?? "" }, set: { model.settings[s.key] = $0 })
                    let label = plan.first { $0.id == "setting:\(s.key)" }?.label ?? s.key
                    switch s.kind {
                    case .bool:
                        Toggle(OutsideText.shown(s.title, max: 120), isOn: Binding(get: { value.wrappedValue == "true" },
                                                                                  set: { value.wrappedValue = $0 ? "true" : "false" }))
                            .accessibilityLabel(label).disabled(!model.canAct)
                    case .choice:
                        Picker(OutsideText.shown(s.title, max: 120), selection: value) {
                            ForEach(s.values, id: \.self) { Text(OutsideText.shown($0, max: 120)).tag($0) }
                        }
                        .accessibilityLabel(label).disabled(!model.canAct)
                    case .string, .path:
                        NeonRow(OutsideText.shown(s.title, max: 120)) {
                            TextField(s.kind == .path ? "path" : "value", text: value).textFieldStyle(.roundedBorder)
                                .frame(maxWidth: sz(240)).accessibilityLabel(label).disabled(!model.canAct)
                        }
                    }
                }
                button(plan, "save") { _ = model.saveSettings() }
            }
        }
    }

    private func overrides(_ list: [KitPaneFacts.Override]) -> some View {
        NeonSection("Overrides", footer: "Your own .pre and .post scripts in the kit's hooks folder.") {
            VStack(alignment: .leading, spacing: sz(6)) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, o in
                    caption("\(o.name).\(o.point.rawValue): " + (o.skipped.map { "skipped, " + $0 } ?? "runs"))
                }
            }
        }
    }

    // MARK: paths and README

    /// The applied copy when one is live, else the extension's own folder.
    static func kitDir(_ m: KitPaneModel) -> URL? {
        if m.live != nil, let rt = m.owner.runtime(for: m.extID) { return URL(fileURLWithPath: rt.store.layout.live, isDirectory: true) }
        return m.owner.record(m.extID)?.loaded.directory
    }

    /// <config home>/<recorded slug>/local.md; nil before the first apply records the slug.
    static func localMD(_ m: KitPaneModel) -> URL? {
        guard let store = m.owner.runtime(for: m.extID)?.store, let slug = store.recordedSlug() else { return nil }
        return URL(fileURLWithPath: store.layout.configHome, isDirectory: true).appendingPathComponent(slug).appendingPathComponent("local.md")
    }

    /// Reveal kit folder, through the seam only.
    static func reveal(_ m: KitPaneModel, _ opener: KitPaneOpener) { if let u = kitDir(m) { opener.reveal(u) } }

    /// Open local.md, through the seam only.
    static func openLocal(_ m: KitPaneModel, _ opener: KitPaneOpener) { if let u = localMD(m) { opener.open(u) } }

    /// README.md, read through BoundedFileRead (readmeMaxBytes), at most readmeMaxLines lines, each as OutsideText shows it.
    static func readme(_ dir: URL?) -> String {
        guard let dir else { return "No kit folder." }
        guard let text = try? BoundedFileRead.text(dir.appendingPathComponent("README.md"), maxBytes: readmeMaxBytes) else {
            return "README.md cannot be read here (missing, or over 64 KiB): reveal the kit folder to read it."
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(readmeMaxLines)
        return lines.map { OutsideText.shown(String($0), max: 400) }.joined(separator: "\n")
    }

    // MARK: controls

    /// Every control the pane draws: id, title, VoiceOver label, enabled. Untrusted (spec 4.9): no Apply, Repair,
    /// Update or Rollback at all; Remove stays (it only takes out). Busy: every writing control disabled while this
    /// model runs a call.
    static func controls(_ m: KitPaneModel) -> [KitPaneControl] {
        let name = OutsideText.shown(m.title, max: 64)
        let act = m.canAct, idle = !m.running
        var out: [KitPaneControl] = []
        func add(_ id: String, _ kind: KitPaneControl.Kind, _ title: String, _ label: String, _ enabled: Bool) {
            out.append(KitPaneControl(id: id, kind: kind, title: title, label: label, enabled: enabled))
        }
        let live = m.live != nil
        if m.trusted, live, m.facts?.updateAvailable == true, m.facts?.sourceRefusal == nil {
            let v = OutsideText.shown(m.version, max: 64) // R1424-s1: the header's cleaned, capped version
            add("update", .button, "Update to \(v)", "Update \(name) to version \(v)", act)
        }
        if m.trusted, let p = previous(m) { add("rollback", .button, "Roll back to \(p)", "Roll back \(name) to version \(p)", act) }
        add("reveal", .button, "Reveal kit folder", "Reveal the folder of \(name) in Finder", kitDir(m) != nil)
        add("local", .button, "Open local.md", "Open the local.md of \(name)", localMD(m) != nil)
        if live {
            for r in pieceRows(m) {
                add("piece:\(r.id)", .toggle, r.id, "Piece \(r.id) on", act)
                add("menu:\(r.id)", .menu, "Actions", "Actions for piece \(r.id)", idle)
                if m.trusted {
                    add("item:\(r.id):apply", .menuItem, "Apply", "Apply \(name)", act)
                    add("item:\(r.id):repair", .menuItem, "Repair", "Repair \(name)", act)
                }
                add("item:\(r.id):remove", .menuItem, "Remove this piece", "Remove piece \(r.id)", idle)
                for t in r.tools { add("tool:\(r.id)/\(t)", .toggle, t, "Tool \(t) of piece \(r.id) on", act) }
            }
            if m.pendingOff != nil {
                add("confirm", .button, "Switch off", "Confirm switching off", act)
                add("cancel", .button, "Cancel", "Cancel switching off", true)
            }
            if m.trusted {
                add("apply", .button, "Apply", "Apply \(name)", act)
                add("repair", .button, "Repair", "Repair \(name)", act)
            }
            add("remove", .button, "Remove", "Remove \(name)", idle)
        } else {
            out += KitInstallSheet.controls(m)
        }
        for s in settingRows(m) {
            add("setting:\(s.key)", .field, OutsideText.shown(s.title, max: 120), "Kit setting " + OutsideText.shown(s.title, max: 120), act)
        }
        if !settingRows(m).isEmpty { add("save", .button, "Save settings", "Save the settings of \(name)", act) }
        return out
    }

    /// The version a rollback returns to (nil: none to roll back to).
    static func previous(_ m: KitPaneModel) -> String? {
        guard m.live != nil, let p = m.owner.runtime(for: m.extID)?.current?.previous?.version, !p.isEmpty else { return nil }
        return OutsideText.shown(p, max: 64)
    }

    // MARK: helpers

    @ViewBuilder
    private func button(_ plan: [KitPaneControl], _ id: String, destructive: Bool = false, _ run: @escaping () -> Void) -> some View {
        if let c = plan.first(where: { $0.id == id }) {
            Button(c.title, action: run).buttonStyle(NeonButtonStyle(destructive: destructive)).fixedSize()
                .disabled(!c.enabled).accessibilityLabel(c.label)
        }
    }

    @ViewBuilder
    private func toggle(_ plan: [KitPaneControl], _ id: String, isOn: Binding<Bool>) -> some View {
        if let c = plan.first(where: { $0.id == id }) {
            Toggle(c.title, isOn: isOn).toggleStyle(.switch).labelsHidden().disabled(!c.enabled).accessibilityLabel(c.label)
        }
    }

    @ViewBuilder
    private func menu(_ plan: [KitPaneControl], _ piece: String) -> some View {
        if let c = plan.first(where: { $0.id == "menu:\(piece)" }) {
            Menu(c.title) {
                ForEach(plan.filter { $0.id.hasPrefix("item:\(piece):") }, id: \.id) { item in
                    Button(item.title) {
                        if item.id.hasSuffix(":apply") { _ = model.apply() } else if item.id.hasSuffix(":repair") { _ = model.repair() } else { _ = model.remove(ids: [piece]) }
                    }
                    .disabled(!item.enabled).accessibilityLabel(item.label)
                }
            }
            .fixedSize().disabled(!c.enabled).accessibilityLabel(c.label)
        }
    }

    private func caption(_ text: String, color: Color = Neon.textSecondary) -> some View {
        Text(text).font(Neon.font(.caption)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    /// One row when it fits, stacked when it does not.
    private func fitting<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        let c = content()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: sz(8)) { c }
            VStack(alignment: .leading, spacing: sz(6)) { c }
        }
    }
}

/// One control of the kit pane (KitPaneView.controls): what a row checks instead of the AX tree.
struct KitPaneControl: Equatable {
    enum Kind: Equatable { case button, toggle, menu, menuItem, field, checkbox }
    var id: String
    var kind: Kind
    var title: String
    /// the VoiceOver label
    var label: String
    var enabled: Bool
}

/// The seam for Reveal kit folder and Open local.md: the pane never opens anything itself (S5 passes NSWorkspace;
/// a row passes a recorder).
struct KitPaneOpener {
    var reveal: @MainActor (URL) -> Void
    var open: @MainActor (URL) -> Void
}
