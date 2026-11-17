import AppKit
import SwiftUI

/// Settings pane for managing extensions: list installed (system + user), toggle
/// enable/disable, trust newly installed ones, reset system extensions, uninstall
/// user ones, browse + install from the marketplace, and publish your own.
/// See docs/ADR-002-extensibility.md (D8/D9) and the trust gate
/// in ExtensionRegistry (installed-but-inert until the user clicks Trust).
struct ExtensionsPane: View {
    @ObservedObject var registry: ExtensionRegistry
    // #078 round 5: the marketplace button block below sits directly inside
    // NeonScroll, outside any NeonSection — needs its own repaint trigger.
    // Round 6 dropped the `.id(theme.generation)` this used to carry (see
    // `SettingsWindow.swift`'s `PaneTitle` comment for why that was a bug —
    // this block and `PaneTitle` right above it were two direct `LazyVStack`
    // children sharing the identical id value, exactly the collision that
    // corrupted manual scroll): the HStack is written directly in this
    // type's own body, so self-observing alone is enough. The property is
    // unused elsewhere but still required — holding `@ObservedObject` is what
    // subscribes this view to `ThemeStore.objectWillChange` and forces `body`
    // to re-run on a select.
    @ObservedObject private var theme = ThemeStore.shared

    @State private var checkingUpdates = false

    // Per-section collapse state, persisted across opens (user > system > themes).
    // Themes start expanded: they are the section users browse, not manage.
    @AppStorage("ext.collapse.user", store: Preferences.defaults) private var userCollapsed = true
    @AppStorage("ext.collapse.system", store: Preferences.defaults) private var systemCollapsed = true
    @AppStorage("ext.collapse.themes", store: Preferences.defaults) private var themesCollapsed = false

    private var userRecords: [ExtensionRecord] { registry.records.filter { !$0.isSystem } }
    private var systemRecords: [ExtensionRecord] {
        registry.records.filter { $0.isSystem && ($0.manifest.contributes?.allThemes ?? []).isEmpty }
    }
    /// System extensions whose only job is contributing a color theme get their
    /// own always-visible section — they'd otherwise drown the real system list.
    private var themeRecords: [ExtensionRecord] {
        registry.records.filter { $0.isSystem && !($0.manifest.contributes?.allThemes ?? []).isEmpty }
    }

    /// Render a divider-separated list of extension rows, or an empty-state caption.
    @ViewBuilder
    private func installedList(_ records: [ExtensionRecord], emptyText: String) -> some View {
        if records.isEmpty {
            Text(emptyText).foregroundStyle(Neon.textSecondary).font(Neon.font(.caption))
        } else {
            ForEach(Array(records.enumerated()), id: \.element.id) { idx, record in
                if idx > 0 { NeonDivider() }
                ExtensionRow(registry: registry, record: record)
            }
        }
    }

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Extensions", subtitle: "Install and manage Lua extensions")

            // Discovery lives in its own window — a marketplace full of packages wants
            // room to search/sort/scroll, which would crowd this settings pane.
            HStack {
                Button {
                    MarketplaceWindow.shared.show()
                } label: {
                    Label("Browse Marketplace", systemImage: "bag")
                }
                .buttonStyle(.neon)
                .help("Open the extension marketplace in its own window")
                Spacer()
            }
            .padding(.bottom, sz(4))

            NeonSection("User Extensions", collapsed: $userCollapsed) {
                HStack {
                    if let status = registry.updateStatus {
                        Text(status).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    }
                    Spacer()
                    if checkingUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check for Updates", action: checkUpdates)
                            .rowAction()
                            .help("Poll GitHub- and marketplace-installed extensions for newer versions and update them")
                    }
                }
                NeonDivider()
                installedList(userRecords, emptyText: "No user extensions installed yet.")
                // #984: a folder discover() refused, as a disabled row with its plain reason; Reveal is the only action.
                ForEach(Array(registry.refused.enumerated()), id: \.offset) { _, refused in
                    NeonDivider()
                    HStack(spacing: sz(12)) {
                        Text(verbatim: Self.refusedLine(refused))
                            .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([refused.directory])
                        }.rowAction().accessibilityLabel(Self.revealLabel(refused))
                    }
                }
            }

            NeonSection("System Extensions", collapsed: $systemCollapsed) {
                installedList(systemRecords, emptyText: "No system extensions found.")
            }

            NeonSection("System Theme Extensions", collapsed: $themesCollapsed) {
                installedList(themeRecords, emptyText: "No theme extensions found.")
            }
        }
    }

    /// #984: one refused folder's line in the list: its name as shown and why it was not loaded.
    nonisolated static func refusedLine(_ refused: ExtensionRegistry.RefusedFolder) -> String {
        "Not loaded: \(refused.folder): \(refused.reason)"
    }

    /// R984-s1: the refused row's Reveal button names its folder for VoiceOver (already cleaned and cut at 80).
    nonisolated static func revealLabel(_ refused: ExtensionRegistry.RefusedFolder) -> String {
        "Reveal \(refused.folder) in Finder"
    }

    /// #726: the row's "Allow on iPhone" toggle shows only for a trusted user or market
    /// extension that offers phone commands, while "Run commands from iPhone" is on.
    static func showsPhoneToggle(_ record: ExtensionRecord, commandsFromPhone: Bool) -> Bool {
        commandsFromPhone && !record.isSystem && record.trusted
            && !(record.manifest.contributes?.phoneCommands ?? []).isEmpty
    }

    private func checkUpdates() {
        checkingUpdates = true
        Task {
            await registry.checkForUpdates(force: true)
            await MainActor.run { checkingUpdates = false }
        }
    }
}

/// One row in the installed-extensions list. Handles enable/reset/uninstall, the
/// trust gate (untrusted rows are inert and show Trust + a review prompt), and
/// publishing a user extension to the marketplace.
struct ExtensionRow: View {
    @ObservedObject var registry: ExtensionRegistry
    let record: ExtensionRecord
    /// #1182: the live Marketplace version for an id; a row passes a fake. Sendable, run from the row's task.
    let fetchVersion: @Sendable (String) async -> String?
    /// #1182: the Marketplace upload (manifest, blob, kind, preview); a row passes a fake. Sendable, run from publish's task.
    let publishCall: @Sendable (MarketClient.PublishManifest, String, String, MarketClient.ThemePreview?) async throws -> Void

    init(registry: ExtensionRegistry, record: ExtensionRecord,
         fetchVersion: @escaping @Sendable (String) async -> String? = { await MarketClient.publishedVersion(id: $0) },
         publishCall: @escaping @Sendable (MarketClient.PublishManifest, String, String, MarketClient.ThemePreview?) async throws -> Void
             = { try await MarketClient.publish(manifest: $0, blobBase64: $1, kind: $2, preview: $3) }) {
        self.registry = registry
        self.record = record
        self.fetchVersion = fetchVersion
        self.publishCall = publishCall
    }

    @State private var publishing = false
    /// Latest version live on the marketplace for this id (nil = never published /
    /// yanked / not yet fetched). Drives the Publish vs Published-badge UX.
    @State private var publishedVersion: String?
    /// Errors from this row's own actions (trust/publish/uninstall/…) render
    /// inline here, not in the unrelated GitHub-install section below the list.
    @State private var rowError: String?
    /// #1141: what a publish would send, shown under the actions until its own action publishes.
    @StateObject private var confirmation = PublishConfirmation()

    private var meta: ExtensionMeta { record.manifest.extension }
    /// #1174: the row shows the Publish button; the open list closes when this turns false.
    private var offered: Bool { Self.offers(record, publishing: publishing, published: publishedVersion) }

    /// #1182: whether a row over `record` offers Publish (the body's `offered`, and publish's guard on the current record).
    static func offers(_ record: ExtensionRecord, publishing: Bool, published: String?) -> Bool {
        PublishActions.offers(system: record.isSystem, trusted: record.trusted, publishing: publishing,
                              published: published, version: record.manifest.extension.version)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            HStack(alignment: .top) {
                Image(systemName: meta.icon ?? "puzzlepiece.extension")
                    .foregroundColor(.accentColor)
                    .frame(width: sz(22))
                VStack(alignment: .leading, spacing: sz(2)) {
                    HStack(spacing: sz(6)) {
                        ExtensionRowTitle(text: ExtensionRowText.title(meta.title, id: meta.id))
                        if record.isSystem {
                            rowBadge("SYSTEM")
                        } else if !record.trusted {
                            rowBadge("UNTRUSTED")
                        }
                        if record.privileged && !record.isSystem {
                            rowBadge("PRIVILEGED")
                        }
                        Text(verbatim: ExtensionRowText.version(meta.version)).font(Neon.font(.caption)).foregroundColor(.secondary)
                    }
                    Text(verbatim: ExtensionRowText.description(meta.description)).font(Neon.font(.caption)).foregroundColor(.secondary)
                    Text(verbatim: ExtensionRowText.byLine(meta.author)).font(Neon.font(.caption2)).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { record.enabled },
                    set: { setEnabled($0) }))
                    .labelsHidden()
                    .disabled(!record.trusted)
                    .help(record.trusted ? "" : "Trust this extension to enable it")
            }

            if !record.isSystem && !record.trusted {
                Text("Not loaded. Review the files, then Trust to load its commands.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
            }

            if record.privileged && !record.isSystem {
                Text("System access granted: this extension can run shell commands, the coding-agent, and delete files as you. Revoke if unsure.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
            }

            if ExtensionsPane.showsPhoneToggle(record, commandsFromPhone: Preferences.runCommandsFromPhone) {
                Toggle("Allow on iPhone", isOn: Binding(
                    get: { registry.isPhoneApproved(id: record.id) },
                    set: { registry.setPhoneApproved($0, id: record.id) }))
                    .toggleStyle(.checkbox)
                    .font(Neon.font(.caption))
                    .help("List " + ExtensionRowText.help((record.manifest.contributes?.phoneCommands ?? []).map(\.title).joined(separator: ", "))
                          + " on the iPhone's Commands screen. An update that changes these commands turns this off again.")
            }

            HStack(spacing: sz(12)) {
                Button("Reveal in Finder") {
                    if let dir = registry.directory(id: record.id) {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }.rowAction()

                if record.isSystem {
                    Button("Reset", action: reset)
                        .rowAction()
                        .help("Restore this system extension to its bundled version")
                } else {
                    if record.trusted {
                        Button("Untrust", action: untrust)
                            .rowAction()
                            .help("Stop loading this extension until you trust it again")
                        if record.privileged {
                            Button("Revoke System Access", action: revokePrivilege)
                                .rowAction()
                                .help("Drop back to the automation tier — no shell, coding-agent, or file deletion")
                        } else {
                            Button("Grant System Access", action: grantPrivilege)
                                .rowAction()
                                .help("Allow host.shell, the coding-agent, and destructive file ops. This extension could run any command as you — only grant configs you have read.")
                        }
                        PublishActions(publishing: publishing, published: publishedVersion, version: meta.version,
                                       dir: registry.directory(id: record.id), model: confirmation, publish: publish)
                    } else {
                        Button("Trust", action: trust)
                            .rowAction(prominent: true)
                    }
                    Button(role: .destructive, action: uninstall) { Text("Uninstall") }
                        .rowAction()
                }
            }

            PublishConfirmView(model: confirmation)

            if let rowError {
                Text(rowError).font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
            }
        }
        .padding(.vertical, sz(4))
        .closesPublishList(confirmation, offered: offered)
        .task(id: record.id) { await refreshPublishedVersion() }
    }

    private func refreshPublishedVersion() async {
        guard !record.isSystem else { return }
        let v = await fetchVersion(record.id)
        await MainActor.run { publishedVersion = v }
    }

    /// Derive the marketplace category + look-and-feel preview from an extension's
    /// contributed themes. No themes → ("extension", nil). Reads each theme.json's
    /// flat color map straight off disk (declarative data, no VM).
    /// R1182-q3: only a theme file among `members` (the confirmed plan's), still a regular file reached through real
    /// folders, with no "." or ".." part, is read; any other gives no swatch (the publish goes on without it).
    static func themePreview(themes: [ThemeContribution], dir: URL, members: [String])
        -> (kind: String, preview: MarketClient.ThemePreview?) {
        guard !themes.isEmpty else { return ("extension", nil) }
        var swatches: [MarketClient.ThemePreview.Swatch] = []
        for t in themes {
            let parts = t.path.split(separator: "/", omittingEmptySubsequences: false)
            guard members.contains("./" + t.path),
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  RemoteInstaller.changedMembers(["./" + t.path], in: dir) == nil,
                  let data = try? BoundedFileRead.data(dir.appendingPathComponent(t.path), maxBytes: BoundedFileRead.themeJSONMaxBytes),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let colors = obj["colors"] as? [String: String] else { continue }
            swatches.append(.init(
                title: t.title,
                appearance: t.appearance ?? (obj["appearance"] as? String) ?? "dark",
                colors: colors))
        }
        return ("theme", swatches.isEmpty ? nil : .init(themes: swatches))
    }

    // MARK: Actions

    private func setEnabled(_ on: Bool) {
        rowError = nil
        do { try registry.setEnabled(on, id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func trust() {
        rowError = nil
        do { try registry.trust(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func untrust() {
        rowError = nil
        do { try registry.untrust(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func grantPrivilege() {
        rowError = nil
        do { try registry.grantPrivilege(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func revokePrivilege() {
        rowError = nil
        do { try registry.revokePrivilege(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func reset() {
        rowError = nil
        do { try registry.reset(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func uninstall() {
        rowError = nil
        Task {
            do { try await registry.uninstall(id: record.id) }
            catch ExtensionError.managedConfigKept(_, let reason) { rowError = reason }
            catch { rowError = String(describing: error) }
        }
    }

    /// The confirmation's action (main actor) with the plan the person confirmed: exactly its members are packed.
    /// Internal so a row can call it on a row value whose record no longer offers Publish.
    func publish(_ plan: RemoteInstaller.PublishPlan) {
        // #1182: a list still open over a row that stopped offering (untrusted, system, publishing, live) publishes
        // nothing; judged on this row and on the registry's current record (the closure holds the row of the press).
        guard offered, let now = registry.record(id: record.id),
              Self.offers(now, publishing: publishing, published: publishedVersion) else { return }
        guard let dir = registry.directory(id: record.id) else { return }
        rowError = nil
        // R1182-e: the upload lists this record's fields; the folder's extension.toml (read by the plan) must still hold them.
        if let why = plan.uploadRefusal(record.manifest) { rowError = why; return }
        publishing = true
        let m = meta
        let themes = record.manifest.contributes?.allThemes ?? []
        Task {
            do {
                let blob = try await PublishActions.pack(dir, plan)
                let manifest = MarketClient.PublishManifest(
                    id: m.id, name: m.name, title: m.title, description: m.description,
                    version: m.version, author: m.author, icon: m.icon, license: m.license)
                let (kind, preview) = Self.themePreview(themes: themes, dir: dir, members: plan.members)
                try await publishCall(manifest, blob, kind, preview)
                await MainActor.run { publishing = false; publishedVersion = m.version }
            } catch {
                await MainActor.run {
                    publishing = false
                    rowError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                }
            }
        }
    }
}

/// #1141: a publish waits here between the Publish button and the upload. Main actor: SwiftUI bodies
/// and button actions are its only callers.
@MainActor final class PublishConfirmation: ObservableObject {
    @Published private(set) var plan: RemoteInstaller.PublishPlan?
    private var dir: URL?
    private var publish: (@MainActor (RemoteInstaller.PublishPlan) -> Void)?

    /// Opens the confirmation with what a publish of `dir` would send; publishes nothing. `publish` runs on
    /// the main actor with the confirmed plan, whose members are all a publish may pack (#1160).
    func ask(_ dir: URL, publish: @escaping @MainActor (RemoteInstaller.PublishPlan) -> Void) {
        // shortcut: walks the folder on the main actor, slow only for a linked development folder with a large published tree; move it off main if that is reported.
        plan = RemoteInstaller.publishPlan(dir)
        self.dir = dir
        self.publish = publish
    }

    /// The confirmation's own action. It reads the folder again: unchanged, it closes and publishes; changed,
    /// it shows the new plan (or its refusal) and publishes nothing, so only what was on screen is confirmed.
    func confirm() {
        guard let plan, plan.refusal == nil, let dir, let run = publish else { return }
        let now = RemoteInstaller.publishPlan(dir)
        guard now == plan else { self.plan = now; return }
        cancel()
        run(plan)
    }

    func cancel() { plan = nil; dir = nil; publish = nil }

    /// The confirmation's text, top to bottom: the refusal alone, or the count, the first
    /// `shown` names and the count left out.
    static func lines(_ plan: RemoteInstaller.PublishPlan, shown: Int = 10) -> [String] {
        if let why = plan.refusal { return [why] }
        let n = plan.members.count
        var out = ["\(n) file\(n == 1 ? "" : "s") will be published:"]
        out += plan.members.prefix(shown).map { String($0.dropFirst(2)) }
        if n > shown { out.append("and \(n - shown) more") }
        if plan.leftOut > 0 {
            out.append("\(plan.leftOut) hidden or test item\(plan.leftOut == 1 ? "" : "s") left out")
        }
        return out
    }

    static func actionTitle(_ plan: RemoteInstaller.PublishPlan) -> String {
        "Publish \(plan.members.count) file\(plan.members.count == 1 ? "" : "s")"
    }
}

/// A Publish button: opens the confirmation; only the confirmation's action publishes.
struct PublishButton: View {
    let title: String
    var prominent = false
    let help: String
    let dir: URL?
    @ObservedObject var model: PublishConfirmation
    let publish: @MainActor (RemoteInstaller.PublishPlan) -> Void

    /// The button's action (main actor), a property so a row can run it without a window.
    var tap: @MainActor () -> Void {
        { [dir, model, publish] in if let dir { model.ask(dir, publish: publish) } }
    }

    var body: some View {
        // No onDisappear close (#1174): a lazy list sends it for a row scrolled far out; the row closes the list.
        Button(title, action: tap).rowAction(prominent: prominent).help(help)
    }
}

/// A row's publish state among its actions: a spinner while publishing, the live version's badge, and the
/// Publish button while the local version is not live. One `if` holds the button whatever its title, so
/// "Publish" becoming "Publish v<x>" when the live version arrives keeps it (and its open list) (#1160).
struct PublishActions: View {
    let publishing: Bool
    let published: String?      // latest live version; nil = never published, yanked or not fetched yet
    let version: String         // the local version
    let dir: URL?
    let model: PublishConfirmation
    let publish: @MainActor (RemoteInstaller.PublishPlan) -> Void

    /// A row's packing step with the confirmed plan (#1160, #1168: a row passes a recording `packer`).
    /// packageForPublish spawns tar + gzip + base64 (sync), so `packer` runs in a detached task on the global
    /// executor, off the main actor; it takes only Sendable values (URL, PublishPlan).
    nonisolated static func pack(_ dir: URL, _ plan: RemoteInstaller.PublishPlan,
                                 packer: @escaping @Sendable (URL, RemoteInstaller.PublishPlan?) throws -> String
                                     = { try RemoteInstaller.packageForPublish($0, plan: $1) }) async throws -> String {
        try await Task.detached { try packer(dir, plan) }.value
    }

    /// nil: nothing live (never published, yanked or not fetched yet); else whether the local version is newer.
    static func ahead(_ published: String?, _ version: String) -> Bool? {
        published.map { SemanticVersion(version) > SemanticVersion($0) }
    }

    /// Whether a row shows the Publish button (#1174): a trusted user extension, not publishing, its local version
    /// not live yet or ahead of the live one. The body below draws the button under exactly this condition.
    static func offers(system: Bool, trusted: Bool, publishing: Bool, published: String?, version: String) -> Bool {
        !system && trusted && !publishing && ahead(published, version) != false
    }

    var body: some View {
        let ahead = Self.ahead(published, version)
        if publishing {
            ProgressView().controlSize(.small)
        } else {
            if let pv = published {
                // Ahead: what is live, next to the version bump; else up to date (or behind): nothing to push.
                rowBadge(ahead == true ? "v\(pv) published" : "Published v\(pv)")
                    .help(ahead == true ? "Version \(pv) is live on the marketplace" : "This version is live on the marketplace")
            }
            if ahead != false {
                PublishButton(title: ahead == true ? "Publish v\(version)" : "Publish", prominent: ahead == true,
                              help: ahead == true ? "Push the newer local version (\(version)) to the marketplace"
                                  : "Publish this extension to the marketplace",
                              dir: dir, model: model, publish: publish)
            }
        }
    }
}

extension View {
    /// #1174: closes `model`'s list when the row stops offering Publish (untrusted, publishing, already live).
    /// Not on disappear: a lazy list sends that for a row scrolled far out. The action runs on the main actor.
    @MainActor func closesPublishList(_ model: PublishConfirmation, offered: Bool) -> some View {
        onChange(of: offered) { _, now in if !now { model.cancel() } }
    }
}

/// Not named `badge`: inside a view body that name is SwiftUI's View.badge modifier on `self`, which recurses.
/// #1251: an extension's own texts (manifest or Marketplace package) as the extension list and the Marketplace rows draw
/// them: through OutsideText.shown (unseen scalars dropped, at most three marks per base scalar, OutsideText.maxMarks) with a bound per field, drawn
/// verbatim (no Markdown, no localization lookup). Display only: ids and versions used in logic stay the decoded values.
enum ExtensionRowText {
    static let titleMax = 80, versionMax = 24, authorMax = 80, descriptionMax = 300, helpMax = 160

    /// The title; one with nothing visible left (empty, spaces or marks only) falls back to the id, then to "Extension".
    static func title(_ title: String, id: String) -> String {
        for s in [title, id] {
            let shown = OutsideText.shown(s, max: titleMax)
            if shown.unicodeScalars.contains(where: { $0 != " " && !isMark($0) }) { return shown }
        }
        return "Extension"
    }

    static func version(_ v: String) -> String { "v" + OutsideText.shown(v, max: versionMax) }
    static func description(_ d: String) -> String { OutsideText.shown(d, max: descriptionMax) }
    /// An empty author reads "by " as before.
    static func byLine(_ author: String) -> String { "by " + OutsideText.shown(author, max: authorMax) }
    static func help(_ s: String) -> String { OutsideText.shown(s, max: helpMax) }

    private static func isMark(_ u: Unicode.Scalar) -> Bool {
        let c = u.properties.generalCategory
        return c == .nonspacingMark || c == .enclosingMark
    }
}

/// #1251: the row's title line: one line, truncated, clipped to its own bounds so no mark it draws reaches the badges
/// beside it or the lines under it; it gives way first when the row is narrow (the badges and the version keep their size).
struct ExtensionRowTitle: View {
    let text: String

    var body: some View {
        Text(verbatim: text).font(Neon.font(.body)).bold()
            .lineLimit(1)
            .clipped()
            .layoutPriority(-1)
    }
}

@MainActor private func rowBadge(_ text: String) -> some View {
    Text(text).font(Neon.font(.caption2)).bold()
        .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
        .background(Color.secondary.opacity(0.2))
        .clipShape(Capsule())
}

/// The list under a row's actions while a publish waits for its confirmation.
struct PublishConfirmView: View {
    @ObservedObject var model: PublishConfirmation

    var body: some View {
        if let plan = model.plan {
            VStack(alignment: .leading, spacing: sz(2)) {
                ForEach(Array(PublishConfirmation.lines(plan).enumerated()), id: \.offset) { _, line in
                    Text(line).font(Neon.font(.caption))
                        .foregroundStyle(plan.refusal == nil ? Neon.textSecondary : Neon.magenta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: sz(12)) {
                    if plan.refusal == nil {
                        Button(PublishConfirmation.actionTitle(plan)) { model.confirm() }.rowAction(prominent: true)
                    }
                    Button("Cancel") { model.cancel() }.rowAction()
                }
                .padding(.top, sz(2))
            }
        }
    }
}

/// Borderless text actions read as labels, not buttons (no cursor change, no
/// affordance). This styles them accent-colored with pressed feedback, and the
/// `.rowAction` modifier adds a pointing-hand cursor on hover.
private struct RowActionStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Neon.font(.caption))
            .fontWeight(prominent ? .bold : .regular)
            .foregroundStyle(configuration.role == .destructive ? Neon.magenta : Color.accentColor)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

private extension View {
    func rowAction(prominent: Bool = false) -> some View {
        buttonStyle(RowActionStyle(prominent: prominent))
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}
