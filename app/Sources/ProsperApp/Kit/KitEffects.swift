import Foundation

// #917 S5b-2c (#1393): the ordered effect runner. It carries out one action list of KitUpdateMachine.step, strictly in
// order on one serial queue: the store's actions through KitStore, the rest through injected handlers. It stops at the
// first failure and reports it before any later action runs (R917-s4b-b); a failure that has a machine event ends the
// event list. The swap's partial throws are mapped by the step that threw (kit917k L2'), a crash-left incoming is
// recovered before a stage or a swap (L2''), and the store's stale-temp sweep runs here, before a stage only (QA r1252
// rider 2): never at launch, never on a timer, never beside a running apply. Kit content is never run here.

/// What the store cannot do itself. Every closure is called on the runner's serial queue.
struct KitEffectHandlers: Sendable {
    /// the source dir of the announced version and its byte cap (E-7)
    var source: @Sendable (KitRef) throws -> (path: String, byteCap: Int)
    /// KitValidator on the staged copy, after the store's tree check
    var validate: @Sendable (KitStaged) -> Bool
    var renderContext: @Sendable (KitRef) throws -> KitRenderContext
    var consent: @Sendable (KitRef) -> Bool
    var shims: @Sendable (KitRef) throws -> [KitShimPlan]
    var applyWiring: @Sendable (KitRef) throws -> Void
}

struct KitEffectResult: Equatable, Sendable {
    /// the machine's answers in order; a failure's answer, when it has one, is last
    var events: [KitUpdateEvent] = []
    /// the action that stopped the list and why; nil when every action ran
    var failure: String? = nil
    /// what the runner did beyond the list (the swap's retry)
    var notes: [String] = []
}

final class KitEffectRunner: Sendable {
    let store: KitStore
    let handlers: KitEffectHandlers
    /// the sweep's clock (plan A7 age), read only by the sweep before a stage
    let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "prosper.kit.effects")

    init(store: KitStore, handlers: KitEffectHandlers, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.handlers = handlers
        self.now = now
    }

    /// The machine's step, then its actions run. `prior` is the state the event met: dropStaged's tree is there.
    func step(_ s: KitUpdateState, _ e: KitUpdateEvent) -> (KitUpdateState, KitEffectResult) {
        let (n, actions) = KitUpdateMachine.step(s, e)
        return (n, run(actions, n, prior: s))
    }

    /// `state` is the machine's state after the step that emitted `actions`; each answer carries (version, tree) from it.
    func run(_ actions: [KitUpdateAction], _ state: KitUpdateState, prior: KitUpdateState) -> KitEffectResult {
        queue.sync {
            var r = KitEffectResult()
            for a in actions {
                guard perform(a, state, prior, &r) else { break } // R917-s4b-b: nothing after a failure runs
            }
            return r
        }
    }

    private static func text(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// false: stop the list here (r.failure says why)
    private func perform(_ a: KitUpdateAction, _ s: KitUpdateState, _ prior: KitUpdateState, _ r: inout KitEffectResult) -> Bool {
        func stop(_ event: KitUpdateEvent?, _ why: String) -> Bool {
            if let event { r.events.append(event) }
            r.failure = "\(a): " + why
            return false
        }
        func answer(_ ok: Bool, _ yes: KitUpdateEvent, _ no: KitUpdateEvent) -> Bool {
            guard ok else { return stop(no, "refused") }
            r.events.append(yes)
            return true
        }
        func staged(_ v: String) -> KitRef? { s.staged?.version == v ? s.staged : nil }
        func copy(_ ref: KitRef) -> KitStaged {
            KitStaged(version: ref.version, tree: ref.treeHash, path: store.stagedPath(ref.version, ref.treeHash), source: "")
        }
        switch a {
        case .copyToStaged(let v):
            guard let ref = staged(v) else { return stop(nil, "not the staged version") }
            do {
                try store.sweepStaleTemps(now: now())
                try store.recoverIncoming()
                let src = try handlers.source(ref)
                _ = try store.stageCopy(from: src.path, version: v, tree: ref.treeHash, byteCap: src.byteCap)
                return true
            } catch { return stop(.validationRefused(v, tree: ref.treeHash), Self.text(error)) }
        case .validateStaged(let v):
            guard let ref = staged(v) else { return stop(nil, "not the staged version") }
            let st = copy(ref)
            return answer(store.verify(st) == nil && handlers.validate(st), .validatedOk(v, tree: ref.treeHash),
                          .validationRefused(v, tree: ref.treeHash))
        case .renderStaged(let v):
            guard let ref = staged(v) else { return stop(nil, "not the staged version") }
            do {
                try store.render(copy(ref), try handlers.renderContext(ref))
                r.events.append(.rendered(v, tree: ref.treeHash))
                return true
            } catch { return stop(.renderFailed(v, tree: ref.treeHash), Self.text(error)) }
        case .askConsent(let v):
            guard let ref = staged(v) else { return stop(nil, "not the staged version") }
            return answer(handlers.consent(ref), .consentGiven(v, tree: ref.treeHash), .consentDenied(v, tree: ref.treeHash))
        case .swap(let v):
            guard let ref = staged(v) else { return stop(nil, "not the staged version") }
            let t = ref.treeHash
            do {
                try store.recoverIncoming()
                try store.swap(version: v, tree: t)
            } catch let e as KitSwapError where e.step == .keepOld {
                // after the RENAME_SWAP live IS the new copy: the machine hears swapped; incoming -> previous once more
                let kept = (try? store.recoverIncoming()) ?? false
                r.notes.append(kept ? "swap: incoming -> previous failed (\(e.error)), retried once: previous kept"
                                    : "swap: incoming -> previous failed twice (\(e.error)): the old live stays at incoming until the next stage or swap")
            } catch {
                // before the RENAME_SWAP live is the old copy; a previous moved to retiring goes back
                // retiring exists here only when this swap retired a previous (prepare removed any older one)
                if let e = error as? KitSwapError, e.step == .exchange, store.fs.kind(store.layout.root + "/retiring") != .missing {
                    do { try store.restoreRetiring() } catch { r.notes.append("swap: restoreRetiring failed: " + Self.text(error)) }
                }
                return stop(.swapFailed(v, tree: t), Self.text(error))
            }
            r.events.append(.swapped(v, tree: t))
            return true
        case .keepPrevious:
            return true // the swap already made previous = the old live and retiring = the older previous
        case .writeShims(let v):
            guard s.live.version == v else { return stop(nil, "not the live version") }
            let t = s.live.treeHash
            do {
                try store.writeShims(try handlers.shims(s.live))
                r.events.append(.shimsWritten(v, tree: t))
                return true
            } catch { return stop(.shimsFailed(v, tree: t), Self.text(error)) }
        case .applyWiring(let v):
            guard s.live.version == v else { return stop(nil, "not the live version") }
            let t = s.live.treeHash
            do {
                try handlers.applyWiring(s.live)
                r.events.append(.wiringApplied(v, tree: t))
                return true
            } catch { return stop(.wiringFailed(v, tree: t), Self.text(error)) }
        case .swapBack:
            do { try store.swapBack(); return true } catch { return stop(nil, Self.text(error)) }
        case .dropPrevious:
            do { try store.dropRetiring(); return true } catch { return stop(nil, Self.text(error)) }
        case .dropStaged(let v):
            do {
                if prior.phase == .shims || prior.phase == .wiring {
                    try store.restoreRetiring() // after the swapBack: the failed new is at previous, not staged/
                } else if let old = prior.staged, old.version == v {
                    try store.dropStaged(version: v, tree: old.treeHash)
                }
                return true
            } catch { return stop(nil, Self.text(error)) }
        }
    }
}
