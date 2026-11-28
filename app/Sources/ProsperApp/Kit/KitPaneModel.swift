import Combine
import Foundation

/// #918 S3 (spec 4.6, 4.9, 4.12): everything the kit pane shows and does for one kit extension, over the shared runtime
/// of KitRuntimes (never one of its own: two models of one kit share its single-flight).
///
/// Isolation: @MainActor (the pane's model, the ccpool pane model's pattern). Every runtime call, file read and the login
/// PATH lookup run in `Task.detached` on nonisolated statics; results come back through `await self?...` on main. Each
/// action returns its task so a caller (or a row) can await it; nil when it was refused before anything ran.
///
/// Untrusted (spec 4.9): the facts are read, but apply, repair, rollback, the toggles and the settings save are refused
/// here, before the runtime or any file is reached.
@MainActor
final class KitPaneModel: ObservableObject {
    /// Where the kit came from, by its manifest's update URL (display only; market also picks apply's byte cap).
    enum Source: String, Sendable {
        case market, github, local
    }

    nonisolated static func source(updateURL: String?) -> Source {
        guard let u = updateURL, !u.isEmpty else { return .local }
        return u.hasPrefix("prosper://market/") ? .market : .github
    }

    nonisolated static let untrustedText = "untrusted kit: trust it first"

    /// What load() reads off main.
    struct Facts: Sendable {
        var status: KitRuntimeStatus?
        var preview: KitValidation
        var requirements: [KitPaneFacts.Requirement]
        var overrides: [KitPaneFacts.Override]?
        /// piece id -> its in-use line (KitPaneFacts.inUse)
        var inUse: [String: String]
        var hooksDisabled: Bool
        /// the live copy's tree differs from the one applied (spec 4.4 "kit files edited")
        var filesEdited: Bool
        var updateAvailable: Bool
        var restoreRefusal: String?
        /// KIT_<KEY> -> value, as .settings.env holds them
        var settingsEnv: [String: String]
        var offTools: [String: Set<String>]
        /// #1421 carry: a market kit's source over the market byte cap (apply would refuse it): why; nil otherwise
        var sourceRefusal: String? = nil
        /// #922: the kit's bin dir ({{kit_bin}}), for the shell-path piece's line shown before it is applied
        var kitBin: String = ""
        /// #2099: applied pieces whose slot or block was changed or removed outside Prosper (shown; never repaired here)
        var drifted: [String] = []
    }

    let extID: String
    let owner: KitRuntimes
    let now: @Sendable () -> Date

    @Published private(set) var title = ""
    @Published private(set) var version = ""
    @Published private(set) var author = ""
    @Published private(set) var source: Source = .local
    @Published private(set) var trusted = false
    @Published private(set) var facts: Facts?
    /// An action of this model is running.
    @Published private(set) var running = false
    /// The runtime refused busy (another model or caller holds it), or a selection write threw: shown, nothing written.
    @Published private(set) var busy: String?
    /// The last action's line.
    @Published private(set) var result: String?
    /// A toggle waiting for its confirm: the off set it asks, and the pieces the closure switches off with it.
    @Published private(set) var pendingOff: Set<String>?
    @Published private(set) var alsoOff: [String] = []
    /// The install selection of a never-applied kit: every piece on until unchecked, an opt-in one (#922) off until checked.
    @Published var installOff: Set<String> = []
    private var optInSeeded = false
    /// The settings form: manifest key -> value (manifest default until .settings.env holds one).
    @Published var settings: [String: String] = [:]

    init(extID: String, owner: KitRuntimes, now: @escaping @Sendable () -> Date = { Date() }) {
        self.extID = extID
        self.owner = owner
        self.now = now
    }

    var live: String? { facts?.status?.live }
    var canAct: Bool { trusted && !running }
    /// #1409 S4: the restore refusal and the refresh notes (refresh carries the refusal itself; without a status, it alone).
    /// R1409-i1: a restore refusal reads "not validated again", never "nothing applied" (files may still be live).
    var warnings: [String] { (facts?.status.map(\.notes) ?? (facts?.restoreRefusal.map { [$0] } ?? [])).map(Self.restoreShown) }

    nonisolated static let notValidated = "not validated again"

    /// #2099: the ids of the live kit's switched-on pieces in a drift state, from the status the refresh already read (no
    /// file read of its own). Not applied, off, or with no managed-config record (agents): never drifted.
    nonisolated static func drifted(_ s: KitRuntimeStatus?) -> [String] {
        guard let s, s.live != nil else { return [] }
        return s.pieces.filter { $0.state.isDrift && !s.off.contains($0.id) }.map(\.id)
    }

    nonisolated static func driftNote(_ id: String) -> String { "\(id) was changed outside Prosper; Repair puts it back" }

    /// R1409-i1: the runtime's restore refusal ends ": nothing applied"; the pane says the state was not validated again.
    nonisolated static func restoreShown(_ s: String) -> String {
        s.hasSuffix(": nothing applied") ? String(s.dropLast("nothing applied".count)) + notValidated : s
    }

    private var kit: KitManifest? { owner.record(extID)?.manifest.contributes?.kit.map { KitManifest.parse($0).kit } }

    /// The record and its runtime, with the header facts and trust read again from the record.
    private func target() -> (LoadedExtension, KitRuntime)? {
        guard let rec = owner.record(extID), let rt = owner.runtime(for: extID) else { result = "no such kit"; return nil }
        let meta = rec.manifest.extension
        title = meta.title
        version = meta.version
        author = meta.author
        source = Self.source(updateURL: meta.updateURL)
        trusted = rec.trusted
        return (rec.loaded, rt)
    }

    // MARK: load

    @discardableResult
    func load() -> Task<Void, Never>? {
        guard let t = target() else { return nil }
        let (ext, rt) = t, src = installSource
        let others = owner.otherKitSlugs(except: extID), login = owner.loginPath, at = now()
        return Task.detached { [weak self] in
            let f = await Self.read(rt, ext, source: src, others: others, loginPath: login, now: at)
            await self?.take(f)
        }
    }

    private func take(_ f: Facts) {
        // busy: the runtime read nothing but pieces.json; keep what is shown
        if f.status?.notes.contains(KitRuntime.busyText) == true {
            busy = KitRuntime.busyText
            return
        }
        facts = f
        // #922: once, for a never-applied kit: the opt-in pieces start unchecked
        if !optInSeeded, f.status?.live == nil, case .ok(let v) = f.preview {
            installOff.formUnion(KitPieceSelection(v).optIn)
            optInSeeded = true
        }
        settings = Self.form(kit, env: f.settingsEnv)
    }

    /// The settings form: manifest key -> its .settings.env value, else the manifest default (the pane and kits.list).
    nonisolated static func form(_ kit: KitManifest?, env: [String: String]) -> [String: String] {
        var form: [String: String] = [:]
        for s in kit?.settings ?? [] {
            form[s.key] = env["KIT_" + s.key.uppercased()] ?? text(s.defaultValue)
        }
        return form
    }

    nonisolated private static func text(_ v: TOMLValue?) -> String {
        switch v {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case nil: return ""
        }
    }

    nonisolated static func read(_ rt: KitRuntime, _ ext: LoadedExtension, source: KitInstallSource, others: Set<String>,
                                         loginPath: @Sendable () -> String?, now: Date) async -> Facts {
        let status = await rt.refresh(ext)
        let kit = ext.manifest.contributes?.kit.map { KitManifest.parse($0).kit }
        let store = rt.store, layout = rt.store.layout
        let requires = kit?.requires ?? []
        let reqs = requires.isEmpty ? [] : KitPaneFacts.requirements(requires, path: loginPath() ?? "", isExecutable: KitPaneFacts.isExecutable)
        let hooksDir = store.recordedSlug().flatMap { try? store.fs.openDir(layout.configHome + "/" + $0 + "/hooks") }
        let fired = try? store.fs.openDir(layout.fired)
        var inUse: [String: String] = [:]
        for p in kit?.pieces ?? [] {
            if let line = KitPaneFacts.inUse(p.kind, fired: fired?.modified(p.id), now: now) { inUse[p.id] = line }
        }
        var hooksOff = false
        if case .success(let config) = rt.provider.get() {
            hooksOff = KitPaneFacts.hooksDisabled(settingsAt: config.roots.claude.appendingPathComponent("settings.json"))
        }
        var edited = false
        // #1424 (R1423-i1): the live copy against the RENDERED tree recorded at its render, never the source tree; a
        // throw (a link or a special file in live/) counts as edited. No recorded hash (an older state file): not shown.
        if let ref = rt.current?.live, !ref.version.isEmpty, let want = ref.rendered { edited = (try? store.treeHash(of: layout.live)) != want }
        var capped: String?
        if source == .market {
            do { _ = try store.treeHash(of: ext.directory.path, byteCap: KitStore.marketByteCap) } catch { capped = "source: \(error)" }
        }
        return Facts(status: status, preview: rt.preview(ext, source: source, otherKitSlugs: others), requirements: reqs,
                     overrides: hooksDir.flatMap { KitPaneFacts.overrides($0, uid: getuid()) }, inUse: inUse, hooksDisabled: hooksOff,
                     filesEdited: edited, updateAvailable: await rt.updateAvailable(ext), restoreRefusal: rt.restoreRefusal,
                     settingsEnv: store.readSettingsEnv(), offTools: rt.offTools(), sourceRefusal: capped, kitBin: layout.bin,
                     drifted: drifted(status))
    }

    // MARK: actions

    /// One action: refused while this model runs one or (`needsTrust`) for an untrusted kit, before anything is
    /// reached. The work's line is shown; a busy refusal or a selection write that threw is shown as busy. Then load.
    private func act(needsTrust: Bool, _ work: @escaping @Sendable (KitRuntime, LoadedExtension) async -> String) -> Task<Void, Never>? {
        guard !running, let t = target() else { return nil }
        let (ext, rt) = t
        guard !needsTrust || trusted else { result = Self.untrustedText; return nil }
        running = true
        busy = nil
        return Task.detached { [weak self] in
            let line = await work(rt, ext)
            let reload = await self?.done(line)
            await reload?.value
        }
    }

    private func done(_ line: String) -> Task<Void, Never>? {
        running = false
        result = line
        busy = line == KitRuntime.busyText || line.hasPrefix(Self.notWritten) ? line : nil
        return load()
    }

    nonisolated private static let notWritten = "not written: "

    nonisolated static func line(_ r: KitRuntimeResult) -> String {
        // R1409-i1: after a relaunch whose re-validation failed, the runtime answers "nothing applied" with the reason
        // in its notes: show that note; a restore refusal reads "not validated again"
        if let why = r.refused {
            if why == "nothing applied", let note = r.notes.first(where: { $0.hasSuffix(": " + notValidated) }) { return note }
            return restoreShown(why)
        }
        if let f = r.failures.first { return f }
        if let c = r.configRefusals.first { return "\(c)" }
        if let c = r.config, !c.ok { return c.message }
        return "done"
    }

    /// The checked selection write (#1428: it may throw while busy). nil: written; else the line to show.
    nonisolated static func select(_ rt: KitRuntime, _ v: KitValidated, off: Set<String>, offTools: [String: Set<String>]) -> String? {
        do {
            if case .refused(let why) = try rt.setSelection(v, off: off, offTools: offTools) { return why.description }
            return nil
        } catch KitRuntimeError.refused(let why) {
            return why // #1428: refused busy while another op holds the runtime: shown as busy, nothing written
        } catch {
            return notWritten + ((error as? KitRuntimeError)?.text ?? error.localizedDescription)
        }
    }

    /// Market: apply's market byte cap and the validator's market rules; GitHub and local validate as .local.
    private var installSource: KitInstallSource { source == .market ? .market : .local }

    private var validated: KitValidated? {
        if case .ok(let v)? = facts?.preview { return v }
        return nil
    }

    /// Apply (or update) every piece not switched off, with the source's byte cap and the other kits' slugs. A
    /// never-applied kit's install selection is written first (closed), so an unchecked piece is never written.
    @discardableResult
    func apply() -> Task<Void, Never>? {
        let src = installSource
        let first = live == nil, off = installOff, others = owner.otherKitSlugs(except: extID)
        return act(needsTrust: true) { rt, ext in await Self.applyRun(rt, ext, first: first, off: off, source: src, others: others).line }
    }

    nonisolated static let refusedText = "the kit is refused: see its checks"

    /// #1866: apply's work, shared with kits.install / kits.apply: the line, and the runtime's result when apply ran (nil:
    /// refused before it, nothing written). `agent`: the ctl call's consent; the pane passes none (the sheet asks).
    nonisolated static func applyRun(_ rt: KitRuntime, _ ext: LoadedExtension, first: Bool, off: Set<String>, source src: KitInstallSource,
                                     others: Set<String>, agent: KitAgentConsent? = nil) async -> (line: String, ran: KitRuntimeResult?) {
        if first {
            guard case .ok(let v) = rt.preview(ext, source: src, otherKitSlugs: others) else { return (refusedText, nil) }
            if let why = select(rt, v, off: off, offTools: rt.offTools()) { return (why, nil) }
        }
        let r = await rt.apply(ext, source: src, otherKitSlugs: others, agent: agent)
        return (line(r), r)
    }

    @discardableResult
    func repair() -> Task<Void, Never>? { act(needsTrust: true) { rt, ext in Self.line(await rt.repair(ext)) } }

    @discardableResult
    func rollback() -> Task<Void, Never>? { act(needsTrust: true) { rt, ext in Self.line(await rt.rollback(ext)) } }

    /// The whole kit (`ids` nil) or some pieces, through its own sheet. Allowed for an untrusted kit: it only takes out.
    @discardableResult
    func remove(ids: [String]? = nil) -> Task<Void, Never>? { act(needsTrust: false) { rt, ext in Self.line(await rt.remove(ext, ids: ids)) } }

    /// A piece switched on or off: nothing is written yet. pendingOff is the asked off set, alsoOff the pieces the
    /// closure switches off with it ("also switches off: X, Y"); a refused selection is shown instead.
    func toggle(_ piece: String, on: Bool) {
        guard let v = validated else { return }
        let current = facts?.status?.off ?? []
        let asked = on ? current.subtracting([piece]) : current.union([piece])
        switch KitPieceSelection(v).closure(off: asked) {
        case .closed(let closed, _):
            pendingOff = asked
            alsoOff = closed.subtracting(asked).subtracting(current).sorted()
        case .refused(let why):
            pendingOff = nil
            alsoOff = []
            result = why.description
        }
    }

    func cancelToggle() {
        pendingOff = nil
        alsoOff = []
    }

    /// The confirmed toggle: the closed set is written, then (an applied kit) the newly off pieces are removed and the
    /// newly on ones repaired, each through its sheet.
    @discardableResult
    func confirmToggle() -> Task<Void, Never>? {
        guard let asked = pendingOff, let v = validated else { return nil }
        let before = facts?.status?.off ?? [], applied = live != nil, tools = facts?.offTools ?? [:]
        let t = act(needsTrust: true) { rt, ext in await Self.toggleRun(rt, ext, v, off: asked, before: before, applied: applied, tools: tools).line }
        if t != nil { cancelToggle() }
        return t
    }

    /// #1866: confirmToggle's work, shared with kits.apply: the line and the runtime's notes of the remove and repair it ran.
    nonisolated static func toggleRun(_ rt: KitRuntime, _ ext: LoadedExtension, _ v: KitValidated, off asked: Set<String>, before: Set<String>,
                                      applied: Bool, tools: [String: Set<String>], agent: KitAgentConsent? = nil) async -> (line: String, notes: [String]) {
        if let why = select(rt, v, off: asked, offTools: tools) { return (why, []) }
        guard applied else { return ("done", []) }
        let after = rt.off(v)
        let gone = after.subtracting(before), back = before.subtracting(after)
        var line = "done", notes: [String] = []
        if !gone.isEmpty { let r = await rt.remove(ext, ids: gone.sorted(), agent: agent); line = Self.line(r); notes += r.notes }
        if !back.isEmpty, line == "done" { let r = await rt.repair(ext, agent: agent); line = Self.line(r); notes += r.notes }
        return (line, notes)
    }

    /// One tool of a tools piece on or off (G1 c), then (an applied kit) a repair writes the shims again.
    @discardableResult
    func setTool(_ tool: String, of piece: String, on: Bool) -> Task<Void, Never>? {
        guard let v = validated else { return nil }
        var tools = facts?.offTools ?? [:]
        if on { tools[piece]?.remove(tool) } else { tools[piece, default: []].insert(tool) }
        let off = facts?.status?.off ?? [], applied = live != nil, asked = tools
        return act(needsTrust: true) { rt, ext in
            if let why = Self.select(rt, v, off: off, offTools: asked) { return why }
            return applied ? Self.line(await rt.repair(ext)) : "done"
        }
    }

    /// The settings form to .settings.env (Prosper's own file, 0600: no sheet).
    @discardableResult
    func saveSettings() -> Task<Void, Never>? {
        let values = settings
        return act(needsTrust: true) { rt, _ in
            do { try rt.store.writeSettingsEnv(values); return "saved" } catch { return "not saved: \(error)" }
        }
    }
}
