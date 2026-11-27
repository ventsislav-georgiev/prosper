import Foundation

/// #1866: the agent kit lifecycle over the control channel: kits.list, kits.install, kits.apply, kits.repair,
/// kits.rollback, kits.remove. Every call goes through the Settings kit pane's own paths: the shared runtime of
/// KitRuntimes (one single-flight with the pane), KitPaneModel's facts read, its install apply (applyRun), its confirmed
/// toggle (toggleRun) and its settings form, and the registry's install and Trust calls. Nothing here selects, closes,
/// renders or writes kit files itself. Each call passes its own KitAgentConsent to the runtime: the config change sheet is
/// not shown for it (the person's consent is the "Let agents control Prosper" switch); the config file changes it was
/// asked to approve come back in the reply ("approved", not a list of files written) with their count in the log line,
/// and the Claude Code permission, env and bypass slots and shell rc blocks it covered ("slots") in the reply and the
/// log line. The pane's own calls pass none and still ask the sheet.
///
/// Arguments are outside data: the source is https://github.com/<owner>/<repo> (optionally /tree/<tag>) or an existing
/// absolute folder; setting keys are the kit's declared ones with plain text values; piece ids exist. A refusal throws
/// before anything is written (no notice, no log line). Runtime work runs off main, as the pane's does.
@MainActor
enum ControlKits {
    /// Seams: the app's kit runtimes and the GitHub install (rows: a fake owner over temp roots; never the network).
    static var owner: () -> KitRuntimes? = { KitRuntimes.shared }
    /// n186/n188: the registry's GitHub install with the market's download cap, the quiet decline and kits.install's admit.
    static let githubInstall: (ExtensionRegistry, String, @escaping ExtensionRegistry.Admit) async throws -> ExtensionRecord = {
        try await $0.installRemote(url: $1, maxBytes: RemoteInstaller.maxArtifactBytes, review: quiet, admit: $2)
    }
    static var installGitHub = githubInstall
    /// n188: where a folder source is staged (RemoteInstaller.stage) before the registry copies it; rows pass a tempDir.
    static var stageRoot: URL = FileManager.default.temporaryDirectory
    /// n188: the GitHub install's deadline (ControlCLI gives up at 70 s).
    static let installDeadline: Double = 60
    /// n186: an update that adds a permission is declined quietly, as the daily update check does: no alert for an agent.
    static let quiet: ExtensionRegistry.PermissionReview = { _, _ in false }
    /// The last undo's work (undo is synchronous, the remove and uninstall are not): rows await it.
    static var lastUndo: Task<Void, Never>?

    static let maxValue = 1000

    /// The id kits.install's GitHub task installed, read after its deadline (n190).
    @MainActor private final class Landed { var id: String? }

    private static func shown(_ s: String) -> String { OutsideText.shown(s, max: 80) }

    static func runtimes() throws -> KitRuntimes {
        guard let o = owner() else { throw ControlError("kits are not loaded yet") }
        return o
    }

    /// The switch, again after an await and before the next write (checked first in ControlRegistry.reply).
    private static func gate() throws {
        guard Preferences.agentControlEnabled else { throw ControlError(ControlChanges.offError) }
    }

    // MARK: - arguments

    enum Source: Equatable {
        case github(String)
        case folder(URL)
    }

    /// https://github.com/<owner>/<repo> or .../tree/<ref>[/<subdir>] (RemoteInstaller's forms, https only, no query,
    /// fragment, user or port), or an absolute path of an existing folder. Anything else is refused.
    static func source(_ raw: String) throws -> Source {
        guard !raw.isEmpty, !ControlSessionsTalk.hasUnseen(raw) else { throw ControlError("source has a control or hidden character") }
        if raw.hasPrefix("https://github.com/") {
            guard let u = URL(string: raw), u.query == nil, u.fragment == nil, u.user == nil, u.port == nil, RemoteInstaller.parse(raw) != nil
            else { throw ControlError("not a GitHub repo URL: give https://github.com/<owner>/<repo>") }
            let parts = u.pathComponents.filter { $0 != "/" }
            guard parts.count == 2 || (parts.count >= 4 && parts[2] == "tree") else {
                throw ControlError("not a GitHub repo URL: give https://github.com/<owner>/<repo> or .../tree/<tag>")
            }
            return .github(raw)
        }
        guard raw.hasPrefix("/") else {
            throw ControlError("source must be https://github.com/<owner>/<repo> or an absolute folder path")
        }
        let dir = URL(fileURLWithPath: raw).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ControlError("no such folder: \(OutsideText.shown(raw, max: 200))")
        }
        return .folder(dir)
    }

    /// The `settings` object: only the kit's declared keys, plain text values. nil: not given.
    static func settings(_ args: [String: ControlJSON], _ kit: KitManifest) throws -> [String: String]? {
        guard case .object(let given)? = args["settings"] else { return nil }
        let keys = Set(kit.settings.map(\.key))
        var out: [String: String] = [:]
        for (k, v) in given.sorted(by: { $0.key < $1.key }) {
            guard keys.contains(k) else {
                throw ControlError("unknown setting '\(shown(k))': the kit declares \(keys.isEmpty ? "none" : keys.sorted().joined(separator: ", "))")
            }
            guard case .string(let s) = v else { throw ControlError("setting '\(k)' must be a string") }
            guard s.count <= maxValue else { throw ControlError("setting '\(k)' is longer than \(maxValue) characters") }
            if ControlSessionsTalk.hasUnseen(s) { throw ControlError("setting '\(k)' has a control or hidden character") }
            out[k] = s
        }
        return out
    }

    /// A piece id list (`off`, `pieces`): every id must be one of the kit's. nil: not given.
    static func pieces(_ args: [String: ControlJSON], _ key: String, _ kit: KitManifest) throws -> Set<String>? {
        guard case .array(let list)? = args[key] else { return nil }
        let ids = Set(kit.pieces.map(\.id))
        var out: Set<String> = []
        for v in list {
            guard case .string(let id) = v else { throw ControlError("'\(key)' lists piece ids (strings)") }
            guard ids.contains(id) else { throw ControlError("unknown piece '\(shown(id))': the kit has \(ids.sorted().joined(separator: ", "))") }
            out.insert(id)
        }
        return out
    }

    // MARK: - one kit

    struct Target {
        let rec: ExtensionRecord
        let rt: KitRuntime
        let kit: KitManifest
        let source: KitInstallSource
        let others: Set<String>
    }

    static func target(_ o: KitRuntimes, _ id: String) throws -> Target {
        guard let rec = o.record(id), let raw = rec.manifest.contributes?.kit else {
            throw ControlError("no kit '\(shown(id))' (kits.list lists them)")
        }
        guard let rt = o.runtime(for: id) else { throw ControlError("no kit store for '\(shown(id))'") }
        let src: KitInstallSource = KitPaneModel.source(updateURL: rec.manifest.extension.updateURL) == .market ? .market : .local
        return Target(rec: rec, rt: rt, kit: KitManifest.parse(raw).kit, source: src, others: o.otherKitSlugs(except: id))
    }

    /// The pane's settings save: the whole form (stored values, else defaults) with the given keys over it.
    nonisolated private static func save(_ rt: KitRuntime, _ kit: KitManifest, _ given: [String: String]) -> String {
        let values = KitPaneModel.form(kit, env: rt.store.readSettingsEnv()).merging(given) { _, new in new }
        do { try rt.store.writeSettingsEnv(values); return "saved" } catch { return "not saved: \(error)" }
    }

    private static func result(_ r: KitRuntimeResult) -> [String: ControlJSON] {
        ["failures": .array(r.failures.map { .string($0) }),
         "configRefusals": .array(r.configRefusals.map { .string($0.description) })]
    }

    /// The change sets the call's agent consent was asked about: [{path, action, change}] (F7: asked and approved, not
    /// necessarily written: a later failure or replan may leave one unwritten; the kit's own files are not listed).
    private static func approved(_ a: KitAgentConsent) -> ControlJSON {
        .array(a.files.map { .object(["path": .string(OutsideText.shown($0.path, max: 400)), "action": .string($0.action), "change": .string($0.change)]) })
    }

    private static func approvedLine(_ a: KitAgentConsent) -> String {
        let n = a.files.count
        return "\(n) config file change\(n == 1 ? "" : "s") approved"
    }

    private static func strings(_ list: [String]) -> ControlJSON { .array(list.map { .string(OutsideText.shown($0, max: 400)) }) }

    /// n189: the slots in the log line (ControlChanges cuts the summary at 200; the warned ones come first).
    private static func slotsLine(_ a: KitAgentConsent) -> String {
        let s = a.slots
        return s.isEmpty ? "" : "; " + s.joined(separator: "; ")
    }

    /// kits.install / kits.apply: (never applied) the install selection closed and written, then apply; (applied) the
    /// settings, the confirmed toggle when `off` changes it, then apply (an update when the version is newer). `off`
    /// lists the pieces to leave out; an opt-in (shell-path) piece keeps its state (only the pane switches one on).
    /// `first`: the kit had no live version before this call.
    static func applyKit(_ o: KitRuntimes, _ id: String, _ args: [String: ControlJSON], agent: KitAgentConsent) async throws -> (json: ControlJSON, first: Bool) {
        let t = try target(o, id)
        let given = try settings(args, t.kit), asked = try pieces(args, "off", t.kit)
        let rt = t.rt, ext = t.rec.loaded, src = t.source, others = t.others, kit = t.kit
        let (status, preview) = await Task.detached { (await rt.refresh(ext), rt.preview(ext, source: src, otherKitSlugs: others)) }.value
        if status?.notes.contains(KitRuntime.busyText) == true { throw ControlError(KitRuntime.busyText) }
        guard case .ok(let v) = preview else {
            if case .refused(let why) = preview { throw ControlError(KitPaneModel.refusedText + ": " + why.map { OutsideText.shown($0.description, max: 400) }.joined(separator: "; ")) }
            throw ControlError(KitPaneModel.refusedText)
        }
        let live = status?.live, current = status?.off ?? []
        let optIn = KitPieceSelection(v).optIn
        let keep = live == nil ? optIn : optIn.intersection(current)
        let off = asked.map { $0.union(keep) }
        // As toggle() and the install sheet: a selection that does not close is refused whole, before anything is written.
        if let off, case .refused(let why) = KitPieceSelection(v).closure(off: off) {
            throw ControlError("the selection is refused, nothing written: \(why.description)")
        }
        try gate()
        var out: [String: ControlJSON] = [:], notes: [String] = []
        if live != nil, let given {
            let line = await Task.detached { save(rt, kit, given) }.value
            guard line == "saved" else { throw ControlError(line) }
            out["settings"] = .string(line)
        }
        if live != nil, let off, off != current {
            let tools = rt.offTools()
            let toggled = await Task.detached { await KitPaneModel.toggleRun(rt, ext, v, off: off, before: current, applied: true, tools: tools, agent: agent) }.value
            out["selection"] = .string(toggled.line)
            notes += toggled.notes
        }
        let first = live == nil, sel = off ?? (first ? optIn : current)
        let r = await Task.detached { await KitPaneModel.applyRun(rt, ext, first: first, off: sel, source: src, others: others, agent: agent) }.value
        guard let ran = r.ran else { throw ControlError(r.line) }
        // n187: a refused run (busy, untrusted, no managed config) applied nothing: thrown, so the caller puts trust back,
        // logs nothing and offers no Undo
        if ran.refused != nil { throw ControlError(r.line) }
        notes += ran.notes
        // A first apply records the kit's slug, which the settings file is named by: saved after it.
        if first, let given { out["settings"] = .string(await Task.detached { save(rt, kit, given) }.value) }
        out.merge(result(ran)) { a, _ in a }
        out["id"] = .string(id)
        out["line"] = .string(r.line)
        out["notes"] = strings(notes)
        out["live"] = rt.current.map { .string($0.live.version) } ?? .null
        out["approved"] = approved(agent)
        out["slots"] = strings(agent.slots)
        return (.object(out), first)
    }

    private static func title(_ rec: ExtensionRecord) -> String { ExtensionRowText.title(rec.manifest.extension.title, id: rec.id) }

    // MARK: - commands

    /// {"kits": [{id, title, version, trusted, applied, live, pieces [{id, kind, on}], settings [{key, value}], notes, refused}]}
    static func list() async throws -> ControlJSON {
        let o = try runtimes()
        var rows: [ControlJSON] = []
        for rec in o.kitRecords() {
            guard let rt = o.runtime(for: rec.id), let raw = rec.manifest.contributes?.kit else { continue }
            let kit = KitManifest.parse(raw).kit, ext = rec.loaded, others = o.otherKitSlugs(except: rec.id)
            let src: KitInstallSource = KitPaneModel.source(updateURL: rec.manifest.extension.updateURL) == .market ? .market : .local
            // the pane's own facts read; the login PATH only names requirements, which this list does not show
            let f = await Task.detached { await KitPaneModel.read(rt, ext, source: src, others: others, loginPath: { nil }, now: Date()) }.value
            var refused: [String] = []
            var off = f.status?.off ?? []
            switch f.preview {
            case .ok(let v): if f.status?.live == nil { off.formUnion(KitPieceSelection(v).optIn) }
            case .refused(let why): refused = why.map(\.description)
            }
            // as the pane's warnings: the refresh notes, else the restore refusal
            let notes = (f.status.map(\.notes) ?? (f.restoreRefusal.map { [$0] } ?? [])).map(KitPaneModel.restoreShown)
                + (f.filesEdited ? ["kit files edited since they were applied"] : []) + (f.sourceRefusal.map { [$0] } ?? [])
            let form = KitPaneModel.form(kit, env: f.settingsEnv)
            rows.append(.object([
                "id": .string(rec.id), "title": .string(title(rec)),
                "version": .string(OutsideText.shown(rec.manifest.extension.version, max: ExtensionRowText.versionMax)),
                "trusted": .bool(rec.trusted), "applied": .bool(f.status?.live != nil),
                "live": f.status?.live.map { .string($0) } ?? .null, "updateAvailable": .bool(f.updateAvailable),
                "pieces": .array(kit.pieces.map { .object(["id": .string($0.id), "kind": .string($0.kind.rawValue), "on": .bool(!off.contains($0.id))]) }),
                "settings": .array(kit.settings.map { .object(["key": .string($0.key), "value": .string(form[$0.key] ?? "")]) }),
                "notes": strings(notes), "refused": strings(refused),
            ]))
        }
        return .object(["kits": .array(rows)])
    }

    /// n185: the candidate's manifest, read before anything on disk changes (installLocal calls this right after its load,
    /// on main, with no await before its copy): the deadline passed, the switch off, a non-kit, or an id already installed
    /// (a kit or not; a case variant is the registry's own refusal) are refused. kits.install never replaces an installed
    /// extension, so a refusal never has an old folder to put back: kits.apply applies an installed kit, and its update
    /// comes through Settings > Extensions.
    private static func admit(_ reg: ExtensionRegistry) -> ExtensionRegistry.Admit {
        { loaded in
            try Task.checkCancellation()
            try gate()
            let id = loaded.id
            guard loaded.manifest.contributes?.kit != nil else { throw ControlError("\(shown(id)) is not an agent kit (no [contributes.kit])") }
            guard reg.record(id: id) == nil else {
                throw ControlError("\(shown(id)) is already installed: kits.install does not replace an installed extension (kits.apply applies an installed kit)")
            }
        }
    }

    /// Install from GitHub or a folder (the registry's own install), Trust it (the Trust button's call), then applyKit.
    /// GitHub: under a 60 s deadline, the download capped at the market's 4 MiB and its tree at the kit store's caps.
    /// A folder: checked against those caps and staged off main first (RemoteInstaller.stage); the registry copies the stage.
    /// Undo, when the kit had no live version before: Remove of what it applied, then the uninstall. A kit already applied
    /// before (its kit store kept a live version) has no undo: Remove would take what the person applied.
    /// A refusal after the install puts the extension back the same way.
    static func install(_ args: [String: ControlJSON]) async throws -> ControlChange {
        let src = try source(try ControlSessions.required(args, "source"))
        let reg = try ControlExtensions.loaded(), o = try runtimes()
        let before = Set(reg.records.map(\.id))
        let rec: ExtensionRecord
        do {
            switch src {
            case .github(let url):
                let landed = Landed()
                let got: ControlJSON
                do {
                    got = try await ControlXray.within(installDeadline, "kits.install") { @MainActor in
                        do {
                            let id = try await installGitHub(reg, url, admit(reg)).id
                            landed.id = id
                            return .success(.string(id))
                        }
                        catch let e as ControlError { return .failure(e) }
                        catch { return .failure(ControlError("not installed: \(error)")) }
                    }
                } catch {
                    // n190: within waits for the install task, so a copy that finished after the deadline has landed by now:
                    // take back an id this call installed (never one that was there before)
                    if let id = landed.id, !before.contains(id) { try? await reg.uninstall(id: id) }
                    throw error
                }
                guard case .string(let id) = got, let r = reg.record(id: id) else { throw ControlError("not installed") }
                rec = r
            case .folder(let dir):
                let root = stageRoot
                let staged = try await Task.detached { try RemoteInstaller.stage(dir, tempRoot: root) }.value
                let done = Result { try reg.installLocal(from: staged, review: quiet, admit: admit(reg)) }
                await Task.detached { RemoteInstaller.removeWorkFolder(holding: staged, tempRoot: root) }.value
                rec = try done.get()
            }
        } catch let e as ControlError { throw e } catch { throw ControlError("not installed: \(error)") }
        let id = rec.id, fresh = !before.contains(id), wasTrusted = rec.trusted
        let putBack: @MainActor @Sendable () async -> Void = {
            // trust first: the registry's trust list outlives an uninstall (a reinstall of the id would come back trusted),
            // and an uninstall that stops (config it kept) leaves the record as it was trusted
            if !wasTrusted, reg.record(id: id)?.trusted == true { try? reg.untrust(id: id) }
            if fresh { try? await reg.uninstall(id: id) }
        }
        do {
            guard rec.manifest.contributes?.kit != nil else { throw ControlError("\(shown(id)) is not an agent kit (no [contributes.kit])") }
            try gate()
            if !wasTrusted { try reg.trust(id: id) }
            let agent = KitAgentConsent()
            let done = try await applyKit(o, id, args, agent: agent)
            let summary = "\(title(rec)) \(rec.manifest.extension.version), \(approvedLine(agent))" + (done.first ? "" : " (no Undo: it was applied before)")
                + slotsLine(agent)
            var undo: (@MainActor () -> Void)?
            if done.first {
                undo = { @MainActor in
                    lastUndo = Task { @MainActor in
                        // the person's Undo click: the pane's path, the sheet asks
                        if let rt = o.runtime(for: id), let ext = o.record(id)?.loaded {
                            // a declined sheet (or a failed Remove) keeps the kit applied: installed and trusted as it is (F8)
                            guard KitPaneModel.line(await Task.detached { await rt.remove(ext) }.value) == "done" else { return }
                        }
                        await putBack()
                    }
                }
            }
            return ControlChange(summary: summary, result: done.json, verb: "installed an agent kit", undo: undo)
        } catch {
            await putBack()
            throw error
        }
    }

    /// kits.apply: an installed kit named by id; Trust granted first when it lacks it (the Trust button's call).
    static func apply(_ args: [String: ControlJSON]) async throws -> ControlChange {
        let id = try ControlSessions.required(args, "id")
        let o = try runtimes()
        let t = try target(o, id)
        _ = try settings(args, t.kit)
        _ = try pieces(args, "off", t.kit)
        let wasTrusted = t.rec.trusted
        if !wasTrusted { try ControlExtensions.loaded().trust(id: id) }
        let agent = KitAgentConsent()
        do {
            let done = try await applyKit(o, id, args, agent: agent)
            return ControlChange(summary: "\(title(t.rec)), \(approvedLine(agent)) (no Undo: kits.rollback goes back a version)" + slotsLine(agent), result: done.json,
                                 verb: "applied an agent kit")
        } catch {
            // nothing applied: the trust this call granted goes back
            if !wasTrusted { try? ControlExtensions.loaded().untrust(id: id) }
            throw error
        }
    }

    /// kits.repair / kits.rollback / kits.remove: the pane's buttons over the runtime. Refused (busy, untrusted, nothing
    /// applied): thrown, nothing logged. No undo.
    static func runtimeCall(_ verb: String, _ args: [String: ControlJSON]) async throws -> ControlChange {
        let id = try ControlSessions.required(args, "id")
        let t = try target(try runtimes(), id)
        let ids = try pieces(args, "pieces", t.kit).map { $0.sorted() }
        let rt = t.rt, ext = t.rec.loaded, agent = KitAgentConsent()
        let r: KitRuntimeResult = await Task.detached {
            switch verb {
            case "repair": return await rt.repair(ext, agent: agent)
            case "rollback": return await rt.rollback(ext, agent: agent)
            default: return await rt.remove(ext, ids: ids, agent: agent)
            }
        }.value
        let line = KitPaneModel.line(r)
        if r.refused != nil { throw ControlError(line) }
        var out = result(r)
        out["id"] = .string(id)
        out["line"] = .string(line)
        out["notes"] = strings(r.notes)
        out["live"] = rt.current.map { .string($0.live.version) } ?? .null
        out["approved"] = approved(agent)
        let what = verb == "remove" ? (ids.map { $0.joined(separator: ", ") } ?? "the whole kit") : verb
        return ControlChange(summary: "\(title(t.rec)): \(what), \(approvedLine(agent)) (no Undo)", result: .object(out), verb: ["repair": "repaired", "rollback": "rolled back"][verb, default: "removed"] + " an agent kit")
    }

    /// As ControlCommand.change (switch-gated in reply, notice, log line), awaited: reply(to:) calls runAsync, never run.
    nonisolated static func change(_ name: String, _ summary: String, _ args: [String: ControlArg],
                                   _ work: @escaping @MainActor @Sendable ([String: ControlJSON]) async throws -> ControlChange) -> ControlCommand {
        ControlCommand(name: name, summary: summary, args: args, mutates: true,
                       run: { _, _ in throw ControlError("\(name) runs off main: send it through the control channel") },
                       runAsync: { reg, a in
            let c = try await work(a)
            reg.changes.record(command: name, change: c, sender: reg.sender)
            return c.result
        })
    }
}

extension ControlRegistry {
    /// #1866: wired in ControlRegistry.standard().
    static func registerKits(_ r: inout ControlRegistry) {
        let id = ControlArg(type: "string", required: true, summary: "a kit id from kits.list")
        let settings = ControlArg(type: "object", summary: "kit settings: {key: text} with the kit's declared keys")
        let off = ControlArg(type: "array", summary: "piece ids to leave out; the pieces that need one go with it")
        r.register(ControlCommand(name: "kits.list", summary: "Every installed agent kit: id, title, version, trusted, applied, live, updateAvailable, pieces (id, kind, on), settings (key, value), notes, refused.",
                                  args: [:], mutates: false, run: { _, _ in throw ControlError("kits.list reads off main: send it through the control channel") },
                                  runAsync: { _, _ in try await ControlKits.list() }))
        r.register(ControlKits.change("kits.install", "Install an agent kit from https://github.com/<owner>/<repo> (or .../tree/<tag>) or an absolute folder, trust it, write its selection and settings, and apply it; the config file changes it is asked about are approved for this call (listed in the reply with the Claude Code slots they write). Refuses an id already installed. Undo (a kit not applied before) removes what it applied and uninstalls it.",
                                      ["source": ControlArg(type: "string", required: true, summary: "https://github.com/<owner>/<repo> or an absolute folder"),
                                       "settings": settings, "off": off]) { try await ControlKits.install($0) })
        r.register(ControlKits.change("kits.apply", "Apply or update an installed kit, with a changed selection or settings (trusts it first if needed). No undo.",
                                      ["id": id, "settings": settings, "off": off]) { try await ControlKits.apply($0) })
        r.register(ControlKits.change("kits.repair", "Repair an applied kit, as its Repair button. No undo.", ["id": id]) { try await ControlKits.runtimeCall("repair", $0) })
        r.register(ControlKits.change("kits.rollback", "Roll an applied kit back to its previous version, as its Roll back button. No undo.", ["id": id]) {
            try await ControlKits.runtimeCall("rollback", $0)
        })
        r.register(ControlKits.change("kits.remove", "Remove an applied kit's files, or only some pieces, as its Remove button. No undo.",
                                      ["id": id, "pieces": ControlArg(type: "array", summary: "piece ids to remove (all when absent)")]) {
            try await ControlKits.runtimeCall("remove", $0)
        })
    }
}
