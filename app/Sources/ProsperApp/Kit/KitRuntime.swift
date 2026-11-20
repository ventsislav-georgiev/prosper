import Foundation

// #917 S6 (#1402): the kit runtime. It drives KitUpdateMachine through KitEffectRunner and writes a person's CLAUDE.md and
// settings.json only through ManagedConfig: apply, remove, repair, status, update and rollback. No UI (P3 = #918).
// - An untrusted kit (spec 4.9) is refused before anything is read, written or asked.
// - The consent is ManagedConfig's own seam, asked at the machine's askConsent with the change set ManagedConfig plans (its
//   hook / statusLine notes are what #1075's warning reads); the swap, the shims and the wiring come only after a yes.
// - The wiring is one ManagedConfig apply; the sheet already approved answers itself there, any other sheet is asked again.
// - The owner is the LoadedExtension id; {{kit_config}} is <configHome>/<the RECORDED slug> (E-2).
// - "Update available" (source version > live version) is only reported, never applied.
// The two answers the runner needs that are async here (consent, wiring) are awaited BEFORE the runner runs that action and
// handed to it as values: the runner's handlers stay synchronous and nothing blocks on a Task.
// Kit content is never run here. One runtime per kit store; #918 S1 (R1402-i1): one op at a time per runtime, a second
// apply / rollback / remove / repair / refresh while one runs is refused busy and touches nothing.

struct KitRuntimeResult: Sendable {
    /// the machine after the call; nil when the call was refused before it
    var state: KitUpdateState? = nil
    /// why nothing started (untrusted, another kit's store, no managed config, nothing applied)
    var refused: String? = nil
    /// the runner's failures, in order (L1: a failed swapBack is reported only here)
    var failures: [String] = []
    /// ManagedConfig's refusals met at the consent or the wiring (a conflict, a corrupt file)
    var configRefusals: [ManagedConfigRefusal] = []
    var notes: [String] = []
    /// remove / repair: ManagedConfig's own answer
    var config: ManagedConfigResult? = nil
}

struct KitRuntimeStatus: Sendable {
    var pieces: [ManagedConfigPieceStatus]
    var off: Set<String>
    var live: String?
    /// #920: agents piece id -> its install state (KitStore.agentStates), for the live version's planned agents
    var agents: [String: String] = [:]
    /// #918 S1: refresh's notes (a kit not validated again, a refused state file, busy)
    var notes: [String] = []
}

/// The sheet approved at askConsent answers itself once more, at the wiring, when the wiring's sheet AND its per-file
/// identity (paths, base and new digests, modes) are the same; anything else goes to the real consent.
struct KitApprovedConsent: ManagedConfigConsent {
    let approved: ManagedConfigChangeSet?
    let fallback: any ManagedConfigConsent

    func confirm(_ changes: ManagedConfigChangeSet) async -> Bool {
        if let approved, approved.identity != nil, approved == changes, approved.identity == changes.identity { return true }
        return await fallback.confirm(changes)
    }
}

/// #1409: the validator over a rendered copy. A rendered `*.md` has the local.md import as an absolute path, which the
/// validator would not count; that one line reads back as KitValidator.localImportLine. Everything else is the disk's.
/// shortcut: only the exact `@{{kit_config}}/local.md` spelling reads back; another spelling of it fails the re-validation
/// (reported, nothing applied from it); store the validated kit instead if a kit needs one.
struct KitRenderedReader: KitFileReader {
    let importLine: String
    var base = KitPOSIXFileReader()

    func kind(_ path: String) -> KitFileKind { base.kind(path) }
    func names(_ dir: String) -> [String]? { base.names(dir) }
    func realPath(_ path: String) -> String? { base.realPath(path) }
    func contents(_ path: String) -> Data? {
        let d = base.contents(path)
        guard KitRender.isRendered(path), let data = d, let text = String(data: data, encoding: .utf8) else { return d }
        return Data(text.replacingOccurrences(of: importLine, with: KitValidator.localImportLine).utf8)
    }
}

enum KitRuntimeError: Error, Equatable {
    case notValidated(String)
    case wiring(String)
    case refused(String)

    var text: String {
        switch self {
        case .notValidated(let s), .wiring(let s), .refused(let s): return s
        }
    }
}

final class KitRuntime: @unchecked Sendable {
    let provider: ManagedConfigProvider
    let store: KitStore
    let isTrusted: @Sendable (String) -> Bool
    let now: @Sendable () -> Date

    private let lock = NSLock()
    // #1409: the machine state persists in kits/<ext-id>/runtime.json (written at the end of every drive that changes it);
    // the validated kits are not stored: they are re-validated from their dirs on disk (restoreKits) at the next call.
    private var state: KitUpdateState?
    private var kits: [String: KitValidated] = [:] // by version: live, previous, retiring and staged only
    private var consentAnswer = false
    private var approved: ManagedConfigChangeSet?
    private var wiring: String? // nil: the last wiring landed
    private var sluggedHere = false // this drive's shims step wrote kit.env's first KIT_SLUG (QA R1408-i1)
    private var busy = false // #918 S1: an op holds the runtime
    static let busyText = "busy: another kit action is running"
    /// Why the persisted state was not restored at init (nil: restored, or no file). The runtime then starts with nothing
    /// applied, and every call that needs an applied kit is refused with this text.
    let restoreRefusal: String?

    init(provider: ManagedConfigProvider, store: KitStore, isTrusted: @escaping @Sendable (String) -> Bool,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.store = store
        self.isTrusted = isTrusted
        self.now = now
        switch Self.restore(store) {
        case .success(let s): state = s; restoreRefusal = nil
        case .failure(let why): state = nil; restoreRefusal = why.text
        }
    }

    /// The persisted state, or why it is refused. Missing file: nothing applied (no refusal). Outside data: every ref
    /// must be a valid version and tree, and the dir of each applied ref (live, previous, retiring) must be on disk.
    private static func restore(_ store: KitStore) -> Result<KitUpdateState?, KitRuntimeError> {
        guard store.fs.kind(store.runtimeStatePath) != .missing else { return .success(nil) }
        guard let s = store.readRuntimeState() else {
            return .failure(.refused("kit state \(store.runtimeStatePath): unreadable, over \(KitStore.runtimeStateCap) bytes or not schema \(KitStore.runtimeStateSchema): nothing applied"))
        }
        guard s.phase == .idle else {
            return .failure(.refused("kit state \(store.runtimeStatePath): phase \(s.phase) is not idle: nothing applied"))
        }
        let refs: [(KitRef?, String?)] = [(s.live, store.layout.live), (s.previous, store.layout.previous),
                                          (s.retiring, store.layout.root + "/retiring"), (s.staged, nil)]
        for case let (ref?, dir) in refs where !ref.version.isEmpty {
            guard KitStore.isValidVersion(ref.version), KitStore.isTree(ref.treeHash) else {
                return .failure(.refused("kit state \(store.runtimeStatePath): a bad version or tree: nothing applied"))
            }
            guard ManagedConfigPaths.isValidSlug(ref.slug), !ref.slug.hasPrefix("-") else {
                return .failure(.refused("kit state \(store.runtimeStatePath): a bad slug: nothing applied"))
            }
            if let dir, store.fs.kind(dir) != .directory {
                return .failure(.refused("kit state \(store.runtimeStatePath): \(dir) is gone: nothing applied"))
            }
        }
        return .success(s)
    }

    /// After a relaunch: live, previous and retiring are validated again from their dirs on disk, each once. The copy on
    /// disk is RENDERED, so the reader turns the rendered local.md import line back into its placeholder form; the
    /// source (market / local) and the other kits' slugs were checked at the apply and are not known here (.local, []).
    private func restoreKits(_ ext: LoadedExtension, host: String) -> [String] {
        guard let s = current else { return [] }
        var notes: [String] = []
        let refs: [(KitRef?, String)] = [(s.live, store.layout.live), (s.previous, store.layout.previous),
                                         (s.retiring, store.layout.root + "/retiring")]
        for case let (ref?, dir) in refs where !ref.version.isEmpty && kit(ref.version) == nil {
            let reader = KitRenderedReader(importLine: "@" + KitRender.escapeImport(context(ref.slug).kitConfig) + "/local.md")
            guard let m = (try? ExtensionLoader.load(directory: URL(fileURLWithPath: dir, isDirectory: true), isSystem: false,
                                                     hostVersion: host))?.manifest,
                  m.extension.id == ext.manifest.extension.id, m.extension.version == ref.version,
                  case .ok(let v) = store.validate(KitStaged(version: ref.version, tree: ref.treeHash, path: dir, source: ""),
                                                   manifest: m, source: .local, otherKitSlugs: [], reader: reader) else {
                notes.append("kit \(ref.version) at \(dir): not validated again")
                continue
            }
            lock.withLock { kits[v.version] = v }
        }
        return notes
    }

    var current: KitUpdateState? { lock.withLock { state } }

    /// R1423-i2: the live version is validated in this run (by an apply or restoreKits). Lock only: no file read.
    var liveValidated: Bool { lock.withLock { state.map { !$0.live.version.isEmpty && kits[$0.live.version] != nil } ?? false } }

    /// #918 S1 single-flight: false when another op holds the runtime. Every caller releases with `defer { end() }`
    /// right after a true answer, so a refused or early return releases too.
    private func begin() -> Bool {
        lock.withLock { () -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
    }

    private func end() { lock.withLock { busy = false } }

    private var configHome: URL { URL(fileURLWithPath: store.layout.configHome, isDirectory: true) }

    /// E-2: the slug recorded at the first apply decides; the manifest's only until then.
    func kitSlug(_ fresh: String) -> String { store.recordedSlug() ?? fresh }

    private func context(_ slug: String) -> KitRenderContext {
        // {{home}}: the parent of the kitconfig: root (~/.config in production, the row's own dir in a test)
        KitRenderContext.standard(extensionID: store.layout.root.components(separatedBy: "/").last ?? "", slug: kitSlug(slug),
                                  kitDir: URL(fileURLWithPath: store.layout.live, isDirectory: true),
                                  home: configHome.deletingLastPathComponent(), configHome: configHome)
    }

    private func owner(_ ext: LoadedExtension, _ v: KitValidated, dir: String) -> ManagedConfigOwner {
        ManagedConfigOwner(id: ext.id, version: v.version, kitSlug: kitSlug(v.slug), extensionDir: URL(fileURLWithPath: dir, isDirectory: true),
                           displayName: ext.manifest.extension.title)
    }

    private func kit(_ version: String) -> KitValidated? { lock.withLock { kits[version] } }

    private func plan(_ v: KitValidated) -> KitPlan { KitRender.plan(v, context(v.slug), off: off(v), offTools: offTools()) }

    // MARK: the S2 off set (kits/<ext-id>/pieces.json, Prosper's own file: no sheet)

    /// #918 S1: offTools is optional, so a pieces.json written before it still decodes.
    private struct Pieces: Codable {
        var off: [String]
        var offTools: [String: [String]]? = nil
        /// #922: the opt-in pieces switched on; optional, so an older pieces.json reads as every one off
        var on: [String]? = nil
    }

    /// R1421-i1: each key decodes alone, so a wrongly typed offTools drops only offTools, never the off set.
    private func pieces() -> Pieces? {
        guard let d = store.fs.read(store.layout.piecesJSON, limit: 64 << 10),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        func part<T: Decodable>(_ key: String, _ t: T.Type) -> T? {
            guard let v = o[key], let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) else { return nil }
            return try? JSONDecoder().decode(t, from: data)
        }
        guard let off = part("off", [String].self) else { return nil }
        return Pieces(off: off, offTools: part("offTools", [String: [String]].self), on: part("on", [String].self))
    }

    /// Outside data (stale or hand-edited): KitRender.plan takes its closure and ignores unknown ids.
    func off() -> Set<String> {
        Set((pieces()?.off ?? []).prefix(KitManifest.maxPieces))
    }

    /// #922: the off set the plan takes: the stored one plus every opt-in piece of `v` not switched on.
    func off(_ v: KitValidated) -> Set<String> {
        let on = Set((pieces()?.on ?? []).prefix(KitManifest.maxPieces))
        return off().union(KitPieceSelection(v).optIn.subtracting(on))
    }

    /// #918 S1 (G1 c): tools piece id -> its tools switched off. Outside data as off(): at most maxPieces pieces, each
    /// with at most maxEntries names (the validator's file cap bounds a piece's tools); unknown ids and names are ignored by plan.
    func offTools() -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for (id, names) in (pieces()?.offTools ?? [:]).sorted(by: { $0.key < $1.key }).prefix(KitManifest.maxPieces) {
            out[id] = Set(names.prefix(KitValidator.maxEntries))
        }
        return out
    }

    /// The raw writer, no closure check: setSelection is the checked one. Keeps the per-tool part as it is.
    /// #1428: takes the busy flag, so a write cannot land between apply's plan and its shims handler.
    func setOff(_ ids: Set<String>) throws {
        guard begin() else { throw KitRuntimeError.refused(Self.busyText) }
        defer { end() } // setOff
        try writePieces(off: ids, offTools: offTools(), on: pieces()?.on ?? [])
    }

    private func writePieces(off ids: Set<String>, offTools: [String: Set<String>], on: [String]) throws {
        let tools = offTools.isEmpty ? nil : offTools.mapValues { $0.sorted() }
        try store.ensureLayout()
        try store.fs.openDir(store.layout.root).write("pieces.json", try JSONEncoder().encode(Pieces(off: ids.sorted(), offTools: tools, on: on.isEmpty ? nil : on.sorted())),
                                                      mode: KitStore.envMode)
    }

    /// #918 S1 (G1 a, b): the CLOSED off set is written (the asked pieces and their dependents), never the asked one; a
    /// refused selection (the local.md piece off while another claude-md piece is on) is returned and nothing is written.
    /// `offTools` keeps only the kit's own tools pieces and tool names.
    func setSelection(_ v: KitValidated, off asked: Set<String>, offTools: [String: Set<String>] = [:]) throws -> KitSelectionResult {
        guard begin() else { throw KitRuntimeError.refused(Self.busyText) }
        defer { end() } // setSelection
        let r = KitPieceSelection(v).closure(off: asked)
        guard case .closed(let closed, _) = r else { return r }
        var tools: [String: Set<String>] = [:]
        for (id, names) in offTools {
            guard let known = v.tools[id].map({ Set($0.map(\.name)) }) else { continue }
            let mine = names.intersection(known)
            if !mine.isEmpty { tools[id] = mine }
        }
        // #922: an opt-in piece left out of the closed off set was switched on
        try writePieces(off: closed, offTools: tools, on: Array(KitPieceSelection(v).optIn.subtracting(closed)))
        return r
    }

    /// #918 S1: the install sheet's preview of the extension's own dir, through the validator only: nothing is copied,
    /// written or run. Followed TIP over the split: KitValidation, not Result<_, [KitRefusal]> ([KitRefusal] is no Error).
    /// shortcut: the source byte cap (apply's treeHash) is not checked here; a market kit over it previews and is refused
    /// at apply. Add the treeHash walk here if the sheet must say so first.
    func preview(_ ext: LoadedExtension, source: KitInstallSource, otherKitSlugs: Set<String>) -> KitValidation {
        KitValidator.validate(kitDir: ext.directory, manifest: ext.manifest, source: source, otherKitSlugs: otherKitSlugs)
    }

    // MARK: checks every entry point shares

    private func config(for ext: LoadedExtension) -> Result<ManagedConfig, KitRuntimeError> {
        guard let mine = try? KitStore.layout(configHome: configHome, extID: ext.id), mine == store.layout else {
            return .failure(.refused("not this runtime's kit"))
        }
        guard case .success(let config) = provider.get() else { return .failure(.refused("managed config is unavailable")) }
        guard config.roots.configHome.standardizedFileURL.path == store.layout.configHome else { return .failure(.refused("the kit store and managed config disagree on the config home")) }
        return .success(config)
    }

    // MARK: apply / update

    /// Apply or update from the extension's own dir. Nothing happens for the version already live.
    func apply(_ ext: LoadedExtension, source: KitInstallSource = .local, otherKitSlugs: Set<String> = []) async -> KitRuntimeResult {
        guard begin() else { return KitRuntimeResult(refused: Self.busyText) }
        defer { end() } // apply
        guard isTrusted(ext.id) else { return KitRuntimeResult(refused: "untrusted kit: trust it first") } // spec 4.9
        let config: ManagedConfig
        switch self.config(for: ext) {
        case .success(let c): config = c
        case .failure(let why): return KitRuntimeResult(refused: why.text)
        }
        let meta = ext.manifest.extension
        let cap = source == .market ? KitStore.marketByteCap : KitStore.localByteCap
        let tree: String
        do { tree = try store.treeHash(of: ext.directory.path, byteCap: cap) } catch { return KitRuntimeResult(refused: "source: \(error)") }
        var s = current ?? KitUpdateState(live: KitRef(version: "", treeHash: "", slug: meta.name)) // first apply: no live yet
        s.live.slug = kitSlug(meta.name)
        let host = await ExtensionRegistry.bundleVersion
        let restored = restoreKits(ext, host: host)
        let runner = KitEffectRunner(store: store, handlers: handlers(ext, source: source, cap: cap, others: otherKitSlugs, host: host), now: now)
        var r = await drive(s, .staged(version: meta.version, treeHash: tree, slug: meta.name, publisher: nil), ext, config, runner)
        r.notes = restored + r.notes
        return r
    }

    /// Reported only: the caller decides whether to call apply.
    func updateAvailable(_ ext: LoadedExtension) async -> Bool {
        guard let live = current?.live.version, !live.isEmpty else { return false }
        let newer = ext.manifest.extension.version.compare(live, options: .numeric) == .orderedDescending
        return newer
    }

    func rollback(_ ext: LoadedExtension) async -> KitRuntimeResult {
        guard begin() else { return KitRuntimeResult(refused: Self.busyText) }
        defer { end() } // rollback
        guard isTrusted(ext.id) else { return KitRuntimeResult(refused: "untrusted kit: trust it first") }
        let config: ManagedConfig
        switch self.config(for: ext) {
        case .success(let c): config = c
        case .failure(let why): return KitRuntimeResult(refused: why.text)
        }
        guard let s = current else { return KitRuntimeResult(refused: restoreRefusal ?? "nothing applied") }
        let host = await ExtensionRegistry.bundleVersion
        let restored = restoreKits(ext, host: host)
        let runner = KitEffectRunner(store: store, handlers: handlers(ext, source: .local, cap: KitStore.localByteCap, others: [], host: host), now: now)
        var r = await drive(s, .rollbackRequested, ext, config, runner)
        r.notes = restored + r.notes
        if r.state?.lastRefusal == .noRollbackCopy { r.refused = "nothing to roll back to" } // #1408 N2
        return r
    }

    private func handlers(_ ext: LoadedExtension, source: KitInstallSource, cap: Int, others: Set<String>, host: String) -> KitEffectHandlers {
        let meta = ext.manifest.extension
        return KitEffectHandlers(
            source: { _ in (ext.directory.path, cap) },
            validate: { [self] st in
                // the staged copy's own manifest through the one extension.toml reader, never the one loaded from the source
                guard let m = (try? ExtensionLoader.load(directory: URL(fileURLWithPath: st.path, isDirectory: true), isSystem: false,
                                                         hostVersion: host))?.manifest,
                      m.extension.id == meta.id, m.extension.name == meta.name, m.extension.version == st.version,
                      case .ok(let v) = store.validate(st, manifest: m, source: source, otherKitSlugs: others) else { return false }
                lock.withLock { kits[v.version] = v }
                return true
            },
            renderContext: { [self] ref in context(ref.slug) },
            consent: { [self] _ in lock.withLock { consentAnswer } },
            shims: { [self] ref in
                guard let v = kit(ref.version) else { throw KitRuntimeError.notValidated(ref.version) }
                if store.recordedSlug() == nil { lock.withLock { sluggedHere = true } } // QA R1408-i1: this attempt records it
                _ = try store.recordSlug(v.slug) // E-2: the first apply records it; later the recorded one stays
                try store.installRunner()
                let c = context(v.slug)
                try store.writeKitEnv(c)
                return KitRender.plan(v, c, off: off(v), offTools: offTools()).shims
            },
            applyWiring: { [self] _ in
                if let why = lock.withLock({ wiring }) { throw KitRuntimeError.wiring(why) }
            })
    }

    private static func isAwaited(_ a: KitUpdateAction) -> Bool {
        switch a {
        case .askConsent, .applyWiring: return true
        default: return false
        }
    }

    /// Feeds the machine its own answers until it has none left. Bounded: every answer moves the phase on, and the
    /// longest path (staged .. wiringFailed .. swapBack) is under 12 events.
    private func drive(_ start: KitUpdateState, _ first: KitUpdateEvent, _ ext: LoadedExtension, _ config: ManagedConfig,
                       _ runner: KitEffectRunner) async -> KitRuntimeResult {
        var out = KitRuntimeResult()
        var s = start
        var pending = [first]
        lock.withLock { sluggedHere = false }
        var steps = 0
        while !pending.isEmpty, steps < 32 {
            steps += 1
            let e = pending.removeFirst()
            // #1424 (R1423-i1): the staged copy is rendered now; its hash travels with the ref to live (the pane's
            // "kit files edited" compares the live copy with this one, like with like). A throw leaves nil.
            if case let .rendered(v, t) = e, s.staged?.version == v, s.staged?.treeHash == t {
                s.staged?.rendered = try? store.treeHash(of: store.stagedPath(v, t))
            }
            let (n, actions) = KitUpdateMachine.step(s, e)
            var r = KitEffectResult()
            var rest = actions[...]
            while r.failure == nil, !rest.isEmpty {
                let cut = rest.firstIndex(where: Self.isAwaited) ?? rest.endIndex
                let head = Array(rest[rest.startIndex..<cut])
                if !head.isEmpty { Self.merge(&r, runner.run(head, n, prior: s)) }
                guard r.failure == nil, cut < rest.endIndex else { break }
                await prepare(rest[cut], n, ext, config, &out)
                Self.merge(&r, runner.run([rest[cut]], n, prior: s))
                rest = rest[(cut + 1)...]
            }
            s = n
            pending += r.events // a failure's answer is last: the machine hears it (wiringFailed swaps back)
            out.notes += r.notes
            if let f = r.failure { out.failures.append(f) }
        }
        let keep = Set([s.live.version, s.previous?.version, s.retiring?.version, s.staged?.version].compactMap { $0 })
        let slugged = lock.withLock { () -> Bool in
            state = s
            kits = kits.filter { keep.contains($0.key) }
            approved = nil
            wiring = nil
            defer { sluggedHere = false }
            return sluggedHere
        }
        // QA R1408-i1: a failed first apply (live is the empty ref again) forgets the slug it recorded, so a renamed kit's
        // retry records its own; the runner script and the seeds stay (the next apply rewrites them).
        if slugged, s.live.version.isEmpty {
            do { try store.removeTree(store.layout.kitEnv) } catch { out.failures.append("kit.env: \(error)") }
        }
        if s != start { // #1409: every drive that changes the state (apply, update, rollback, a failed one too)
            do { try store.writeRuntimeState(s) } catch { out.failures.append("runtime.json: \(error)") }
        }
        out.state = s
        return out
    }

    private static func merge(_ r: inout KitEffectResult, _ more: KitEffectResult) {
        r.events += more.events
        r.notes += more.notes
        r.failure = r.failure ?? more.failure
    }

    /// The async half of askConsent and applyWiring, run just before the runner runs that action.
    private func prepare(_ a: KitUpdateAction, _ s: KitUpdateState, _ ext: LoadedExtension, _ config: ManagedConfig,
                         _ out: inout KitRuntimeResult) async {
        switch a {
        case .askConsent(let version):
            lock.withLock { consentAnswer = false; approved = nil }
            guard let v = kit(version), let st = s.staged else { return }
            let p = plan(v)
            guard p.refusals.isEmpty else { out.notes += p.refusals.map(\.description); return }
            let mc = config.plan(p.pieces, owner: owner(ext, v, dir: store.stagedPath(st.version, st.treeHash)))
            guard mc.refusals.isEmpty else { out.configRefusals += mc.refusals; return }
            var yes = true
            if mc.writesUserFiles { yes = await config.consent.confirm(mc.changes) }
            lock.withLock { consentAnswer = yes; approved = yes ? mc.changes : nil }
        case .applyWiring(let version):
            lock.withLock { wiring = "no validated kit for \(version)" }
            guard let v = kit(version) else { return }
            let p = plan(v)
            guard p.refusals.isEmpty else { lock.withLock { wiring = p.refusals.map(\.description).joined(separator: "; ") }; return }
            let who = owner(ext, v, dir: store.layout.live)
            let once = lock.withLock { () -> ManagedConfigChangeSet? in defer { approved = nil }; return approved }
            let mc = ManagedConfig(roots: config.roots, consent: KitApprovedConsent(approved: once, fallback: config.consent),
                                   writer: config.writer, now: config.now)
            // a piece the new version no longer plans (or one switched off) leaves first
            let planned = Set(p.pieces.map(\.id))
            let gone = config.status(owner: who).map(\.id).filter { !planned.contains($0) }
            if !gone.isEmpty {
                let r = await mc.remove(owner: who, ids: gone)
                out.configRefusals += r.refusals
                guard r.ok else { lock.withLock { wiring = "remove: \(r.status.rawValue) \(r.message)" }; return }
            }
            let r = await mc.apply(p.pieces, owner: who)
            out.configRefusals += r.refusals
            lock.withLock { wiring = r.ok ? nil : "\(r.status.rawValue) \(r.message)" }
            // #920: after the wiring landed; a refused agent is a note, never a failed apply (the other pieces stay)
            if r.ok { out.notes += store.syncAgents(p.agents, from: store.layout.live, claude: config.roots.claude, home: config.roots.home) }
        default:
            return
        }
    }

    // MARK: remove / repair / status

    /// ManagedConfig's remove (its own sheet), then the shims of the removed pieces. `ids` nil: the whole kit.
    func remove(_ ext: LoadedExtension, ids: [String]? = nil) async -> KitRuntimeResult {
        guard begin() else { return KitRuntimeResult(refused: Self.busyText) }
        defer { end() } // remove
        let config: ManagedConfig
        switch self.config(for: ext) {
        case .success(let c): config = c
        case .failure(let why): return KitRuntimeResult(refused: why.text)
        }
        let host = await ExtensionRegistry.bundleVersion
        let notes = restoreKits(ext, host: host) // #1409: after a relaunch
        guard let live = current?.live.version, let v = kit(live) else { return KitRuntimeResult(refused: restoreRefusal ?? "nothing applied", notes: notes) }
        var out = KitRuntimeResult(state: current, notes: notes)
        let r = await config.remove(owner: owner(ext, v, dir: store.layout.live), ids: ids)
        out.config = r
        guard r.ok else { return out }
        let keep = ids.map { ids in plan(v).shims.filter { !ids.contains($0.pieceID) } } ?? []
        do { try store.writeShims(keep) } catch { out.failures.append("writeShims: \(error)") }
        out.notes += store.removeAgents(pieces: ids, claude: config.roots.claude, home: config.roots.home)
        return out
    }

    /// The live version's declared pieces through ManagedConfig's repair (its own sheet), then its shims again.
    func repair(_ ext: LoadedExtension) async -> KitRuntimeResult {
        guard begin() else { return KitRuntimeResult(refused: Self.busyText) }
        defer { end() } // repair
        guard isTrusted(ext.id) else { return KitRuntimeResult(refused: "untrusted kit: trust it first") }
        let config: ManagedConfig
        switch self.config(for: ext) {
        case .success(let c): config = c
        case .failure(let why): return KitRuntimeResult(refused: why.text)
        }
        let host = await ExtensionRegistry.bundleVersion
        let notes = restoreKits(ext, host: host) // #1409: after a relaunch
        guard let live = current?.live.version, let v = kit(live) else { return KitRuntimeResult(refused: restoreRefusal ?? "nothing applied", notes: notes) }
        var out = KitRuntimeResult(state: current, notes: notes)
        let p = plan(v)
        let r = await config.repair(p.pieces, owner: owner(ext, v, dir: store.layout.live))
        out.config = r
        guard r.ok else { return out }
        do { try store.writeShims(p.shims) } catch { out.failures.append("writeShims: \(error)") }
        out.notes += store.syncAgents(p.agents, from: store.layout.live, claude: config.roots.claude, home: config.roots.home)
        return out
    }

    /// #918 S1 (#1409 S3): status after a relaunch. restoreKits validates live, previous and retiring again from their dirs
    /// (with the host version), then status reports them; status() alone has live nil until a drive ran. Busy: nothing is
    /// read but pieces.json, live nil, the busy text in notes (the caller keeps what it shows). nil: not this runtime's kit
    /// or no managed config.
    func refresh(_ ext: LoadedExtension) async -> KitRuntimeStatus? {
        guard begin() else { return KitRuntimeStatus(pieces: [], off: off(), live: nil, notes: [Self.busyText]) }
        defer { end() } // refresh
        guard case .success = self.config(for: ext) else { return nil }
        let host = await ExtensionRegistry.bundleVersion
        let restored = restoreKits(ext, host: host) // refresh
        guard var s = status(ext) else { return nil }
        s.notes = (restoreRefusal.map { [$0] } ?? []) + restored
        return s
    }

    /// ManagedConfig.status(owner:declared:) for the live version's planned pieces, plus the off set.
    func status(_ ext: LoadedExtension) -> KitRuntimeStatus? {
        guard case .success(let mc) = self.config(for: ext) else { return nil }
        guard let live = current?.live.version, let v = kit(live) else {
            let who = ManagedConfigOwner(id: ext.id, version: "", kitSlug: store.recordedSlug())
            return KitRuntimeStatus(pieces: mc.status(owner: who), off: off(), live: nil)
        }
        let p = plan(v)
        return KitRuntimeStatus(pieces: mc.status(owner: owner(ext, v, dir: store.layout.live), declared: p.pieces), off: off(v), live: live,
                                agents: store.agentStates(p.agents, claude: mc.roots.claude, home: mc.roots.home))
    }
}
