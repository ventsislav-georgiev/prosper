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
// Kit content is never run here. One call at a time per kit (the caller serialises; there is one runtime per kit store).

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
    // shortcut: the machine state and the validated kits live in memory only, so a relaunch forgets live/previous; persist
    // them beside pieces.json when #918 gives the runtime a lifetime longer than one session.
    private var state: KitUpdateState?
    private var kits: [String: KitValidated] = [:] // by version: live, previous, retiring and staged only
    private var consentAnswer = false
    private var approved: ManagedConfigChangeSet?
    private var wiring: String? // nil: the last wiring landed

    init(provider: ManagedConfigProvider, store: KitStore, isTrusted: @escaping @Sendable (String) -> Bool,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.store = store
        self.isTrusted = isTrusted
        self.now = now
    }

    var current: KitUpdateState? { lock.withLock { state } }

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

    private func plan(_ v: KitValidated) -> KitPlan { KitRender.plan(v, context(v.slug), off: off()) }

    // MARK: the S2 off set (kits/<ext-id>/pieces.json, Prosper's own file: no sheet)

    private struct Pieces: Codable { var off: [String] }

    /// Outside data (stale or hand-edited): KitRender.plan takes its closure and ignores unknown ids.
    func off() -> Set<String> {
        guard let d = store.fs.read(store.layout.piecesJSON, limit: 64 << 10), let p = try? JSONDecoder().decode(Pieces.self, from: d) else { return [] }
        return Set(p.off.prefix(KitManifest.maxPieces))
    }

    func setOff(_ ids: Set<String>) throws {
        try store.ensureLayout()
        try store.fs.openDir(store.layout.root).write("pieces.json", try JSONEncoder().encode(Pieces(off: ids.sorted())), mode: KitStore.envMode)
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
        let runner = KitEffectRunner(store: store, handlers: handlers(ext, source: source, cap: cap, others: otherKitSlugs, host: host), now: now)
        return await drive(s, .staged(version: meta.version, treeHash: tree, slug: meta.name, publisher: nil), ext, config, runner)
    }

    /// Reported only: the caller decides whether to call apply.
    func updateAvailable(_ ext: LoadedExtension) async -> Bool {
        guard let live = current?.live.version, !live.isEmpty else { return false }
        let newer = ext.manifest.extension.version.compare(live, options: .numeric) == .orderedDescending
        return newer
    }

    func rollback(_ ext: LoadedExtension) async -> KitRuntimeResult {
        guard isTrusted(ext.id) else { return KitRuntimeResult(refused: "untrusted kit: trust it first") }
        let config: ManagedConfig
        switch self.config(for: ext) {
        case .success(let c): config = c
        case .failure(let why): return KitRuntimeResult(refused: why.text)
        }
        guard let s = current else { return KitRuntimeResult(refused: "nothing applied") }
        let host = await ExtensionRegistry.bundleVersion
        let runner = KitEffectRunner(store: store, handlers: handlers(ext, source: .local, cap: KitStore.localByteCap, others: [], host: host), now: now)
        var r = await drive(s, .rollbackRequested, ext, config, runner)
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
                _ = try store.recordSlug(v.slug) // E-2: the first apply records it; later the recorded one stays
                try store.installRunner()
                let c = context(v.slug)
                try store.writeKitEnv(c)
                return KitRender.plan(v, c, off: off()).shims
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
        var steps = 0
        while !pending.isEmpty, steps < 32 {
            steps += 1
            let e = pending.removeFirst()
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
        lock.withLock {
            state = s
            kits = kits.filter { keep.contains($0.key) }
            approved = nil
            wiring = nil
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
        default:
            return
        }
    }

    // MARK: remove / repair / status

    /// ManagedConfig's remove (its own sheet), then the shims of the removed pieces. `ids` nil: the whole kit.
    func remove(_ ext: LoadedExtension, ids: [String]? = nil) async -> KitRuntimeResult {
        let config: ManagedConfig
        switch self.config(for: ext) {
        case .success(let c): config = c
        case .failure(let why): return KitRuntimeResult(refused: why.text)
        }
        guard let live = current?.live.version, let v = kit(live) else { return KitRuntimeResult(refused: "nothing applied") }
        var out = KitRuntimeResult(state: current)
        let r = await config.remove(owner: owner(ext, v, dir: store.layout.live), ids: ids)
        out.config = r
        guard r.ok else { return out }
        let keep = ids.map { ids in plan(v).shims.filter { !ids.contains($0.pieceID) } } ?? []
        do { try store.writeShims(keep) } catch { out.failures.append("writeShims: \(error)") }
        return out
    }

    /// The live version's declared pieces through ManagedConfig's repair (its own sheet), then its shims again.
    func repair(_ ext: LoadedExtension) async -> KitRuntimeResult {
        guard isTrusted(ext.id) else { return KitRuntimeResult(refused: "untrusted kit: trust it first") }
        let config: ManagedConfig
        switch self.config(for: ext) {
        case .success(let c): config = c
        case .failure(let why): return KitRuntimeResult(refused: why.text)
        }
        guard let live = current?.live.version, let v = kit(live) else { return KitRuntimeResult(refused: "nothing applied") }
        var out = KitRuntimeResult(state: current)
        let p = plan(v)
        let r = await config.repair(p.pieces, owner: owner(ext, v, dir: store.layout.live))
        out.config = r
        guard r.ok else { return out }
        do { try store.writeShims(p.shims) } catch { out.failures.append("writeShims: \(error)") }
        return out
    }

    /// ManagedConfig.status(owner:declared:) for the live version's planned pieces, plus the off set.
    func status(_ ext: LoadedExtension) -> KitRuntimeStatus? {
        guard case .success(let mc) = self.config(for: ext) else { return nil }
        guard let live = current?.live.version, let v = kit(live) else {
            let who = ManagedConfigOwner(id: ext.id, version: "", kitSlug: store.recordedSlug())
            return KitRuntimeStatus(pieces: mc.status(owner: who), off: off(), live: nil)
        }
        return KitRuntimeStatus(pieces: mc.status(owner: owner(ext, v, dir: store.layout.live), declared: plan(v).pieces), off: off(), live: live)
    }
}
