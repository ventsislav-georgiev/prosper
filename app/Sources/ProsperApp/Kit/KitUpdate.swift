import Foundation

// #917 S4: the staged-update machine as VALUES. Pure: no file system, path, URL, clock, network or
// process. A version, slug, publisher and hash are outside text and are only compared for equality.
// `step` never traps: an event that does not fit the phase returns the state unchanged and no action.
// The actions are values a later step carries out; nothing here installs, renders or writes a kit.
//
// CONTRACT with the caller (S5): every answer-expecting action (validateStaged, renderStaged, askConsent,
// swap, writeShims, applyWiring) is answered EXACTLY ONCE, by the event that carries the version AND the
// tree hash of the action. An answer is compared with `staged` (or, after the swap, `live`) WHOLE: an
// answer for another version or another tree is ignored (S4b, R917-s4-q1). swapBack is ONE atomic rename
// swap in the store step and cannot fail half way, so it has no answer and no failure edge.
// A shims or wiring failure on a FIRST apply (previous is the runtime's empty ref) answers dropLive, never swapBack (#1408).

struct KitRef: Hashable, Sendable, Codable {
    var version: String
    var treeHash: String
    var slug: String
}

enum KitUpdatePhase: Hashable, Sendable, Codable {
    case idle, validating, rendering, consenting, swapping, shims, wiring, rollingBack
}

enum KitUpdateRefusal: Hashable, Sendable, Codable {
    case slugChanged, publisherChanged, validation, consentDenied, render, shims
    /// a rollback asked while previous is the runtime's empty ref (right after a first apply): nothing to roll back to
    case noRollbackCopy
}

struct KitUpdateState: Hashable, Sendable, Codable {
    var live: KitRef
    var staged: KitRef? = nil
    var previous: KitRef? = nil
    /// The older previous, kept only while an update is unconfirmed (phase shims or wiring); dropped at wiringApplied.
    var retiring: KitRef? = nil
    var phase: KitUpdatePhase = .idle
    /// Given by the caller; nil for a local or GitHub kit: the publisher is then not compared.
    var publisherPin: String? = nil
    var lastRefusal: KitUpdateRefusal? = nil
}

/// Every answer carries (version, tree): the tree hash of the staged copy the action was about.
enum KitUpdateEvent: Hashable, Sendable {
    case staged(version: String, treeHash: String, slug: String, publisher: String?)
    case validatedOk(String, tree: String)
    case validationRefused(String, tree: String)
    case rendered(String, tree: String)
    case renderFailed(String, tree: String)
    case consentGiven(String, tree: String)
    case consentDenied(String, tree: String)
    case swapped(String, tree: String)
    case swapFailed(String, tree: String)
    case shimsWritten(String, tree: String)
    case shimsFailed(String, tree: String)
    case wiringApplied(String, tree: String)
    case wiringFailed(String, tree: String)
    case rollbackRequested
    /// The person (or the app) gives up the pending update; honoured only before the swap.
    case cancel
}

enum KitUpdateAction: Hashable, Sendable {
    case copyToStaged(String)
    case validateStaged(String)
    case renderStaged(String)
    case askConsent(String)
    case swap(String)
    case writeShims(String)
    case applyWiring(String)
    case swapBack
    /// A failed FIRST apply (no real previous): the new live copy and its shims go; nothing is applied after it.
    case dropLive(String)
    case keepPrevious(String)
    case dropPrevious(String)
    case dropStaged(String)
}

enum KitUpdateMachine {
    private static func isStaged(_ s: KitUpdateState, _ v: String, _ t: String) -> Bool {
        guard let st = s.staged else { return false }
        return st.version == v && st.treeHash == t
    }

    private static func isLive(_ s: KitUpdateState, _ v: String, _ t: String) -> Bool {
        s.live.version == v && s.live.treeHash == t
    }

    /// The runtime seeds a first apply with an empty live ref (version ""), which the swap makes `previous`:
    /// that is no copy to swap back to.
    private static func isFirstApply(_ s: KitUpdateState) -> Bool { s.previous?.version.isEmpty == true }

    static func step(_ s: KitUpdateState, _ e: KitUpdateEvent) -> (KitUpdateState, [KitUpdateAction]) {
        var n = s
        switch e {
        case let .staged(version, treeHash, slug, publisher):
            guard s.phase == .idle || s.phase == .validating || s.phase == .rendering || s.phase == .consenting,
                  version != s.live.version, version != s.staged?.version else { return (s, []) }
            if slug != s.live.slug { n.lastRefusal = .slugChanged; return (n, []) }
            if let pin = s.publisherPin, publisher != pin { n.lastRefusal = .publisherChanged; return (n, []) }
            var out: [KitUpdateAction] = []
            if let old = s.staged { out.append(.dropStaged(old.version)) }
            n.staged = KitRef(version: version, treeHash: treeHash, slug: slug)
            n.phase = .validating
            n.lastRefusal = nil
            return (n, out + [.copyToStaged(version), .validateStaged(version)])
        case let .validatedOk(v, t):
            guard s.phase == .validating, isStaged(s, v, t) else { return (s, []) }
            n.phase = .rendering
            return (n, [.renderStaged(v)])
        case let .validationRefused(v, t):
            guard s.phase == .validating, isStaged(s, v, t) else { return (s, []) }
            n.phase = .idle; n.staged = nil; n.lastRefusal = .validation
            return (n, [.dropStaged(v)])
        case let .rendered(v, t):
            guard s.phase == .rendering, isStaged(s, v, t) else { return (s, []) }
            n.phase = .consenting
            return (n, [.askConsent(v)])
        case let .renderFailed(v, t):
            guard s.phase == .rendering, isStaged(s, v, t) else { return (s, []) }
            n.phase = .idle; n.staged = nil; n.lastRefusal = .render
            return (n, [.dropStaged(v)])
        case let .consentGiven(v, t):
            guard s.phase == .consenting, isStaged(s, v, t) else { return (s, []) }
            n.phase = .swapping
            return (n, [.swap(v)])
        case let .consentDenied(v, t):
            guard s.phase == .consenting, isStaged(s, v, t) else { return (s, []) }
            n.phase = .idle; n.staged = nil; n.lastRefusal = .consentDenied
            return (n, [.dropStaged(v)])
        case let .swapped(v, t):
            guard s.phase == .swapping, let st = s.staged, isStaged(s, v, t) else { return (s, []) }
            n.retiring = s.previous; n.previous = s.live; n.live = st; n.phase = .shims
            return (n, [.keepPrevious(s.live.version), .writeShims(v)])
        case let .swapFailed(v, t):
            guard s.phase == .swapping, isStaged(s, v, t) else { return (s, []) }
            n.phase = .idle; n.staged = nil
            return (n, [.dropStaged(v)])
        case let .shimsWritten(v, t):
            guard s.phase == .shims, isLive(s, v, t) else { return (s, []) }
            n.phase = .wiring
            return (n, [.applyWiring(v)])
        case let .shimsFailed(v, t):
            guard isLive(s, v, t) else { return (s, []) }
            if s.phase == .shims, isFirstApply(s), let none = s.previous {
                n.live = none; n.previous = nil; n.retiring = nil; n.staged = nil; n.phase = .idle
                return (n, [.dropLive(v)])
            }
            if s.phase == .shims, let old = s.previous {
                n.live = old; n.previous = s.retiring; n.retiring = nil; n.staged = nil; n.phase = .idle
                return (n, [.swapBack, .writeShims(old.version), .dropStaged(v)])
            }
            // Bounded: a failed shim write while rolling back swaps back ONCE and lands in idle, so the answer
            // to the rewrite after that swap back (another shimsFailed) is out of phase and ignored.
            if s.phase == .rollingBack, let newer = s.previous {
                n.live = newer; n.previous = s.live; n.phase = .idle; n.lastRefusal = .shims
                return (n, [.swapBack, .writeShims(newer.version)])
            }
            return (s, [])
        case let .wiringApplied(v, t):
            guard isLive(s, v, t) else { return (s, []) }
            if s.phase == .wiring {
                n.phase = .idle; n.staged = nil; n.retiring = nil
                return (n, s.retiring.map { [.dropPrevious($0.version)] } ?? [])
            }
            if s.phase == .rollingBack { n.phase = .idle; return (n, []) }
            return (s, [])
        case let .wiringFailed(v, t):
            guard isLive(s, v, t) else { return (s, []) }
            if s.phase == .wiring, isFirstApply(s), let none = s.previous {
                n.live = none; n.previous = nil; n.retiring = nil; n.staged = nil; n.phase = .idle
                return (n, [.dropLive(v)])
            }
            if s.phase == .wiring, let old = s.previous {
                n.live = old; n.previous = s.retiring; n.retiring = nil; n.staged = nil; n.phase = .idle
                return (n, [.swapBack, .writeShims(old.version), .dropStaged(v)])
            }
            if s.phase == .rollingBack, let newer = s.previous {
                n.live = newer; n.previous = s.live; n.phase = .idle
                return (n, [.swapBack, .writeShims(newer.version)])
            }
            return (s, [])
        case .rollbackRequested:
            guard s.phase == .idle, let prev = s.previous else { return (s, []) }
            if prev.version.isEmpty { n.lastRefusal = .noRollbackCopy; return (n, []) } // #1408 N2: no swapBack, no throw
            n.live = prev; n.previous = s.live; n.phase = .rollingBack
            return (n, [.swapBack, .writeShims(prev.version), .applyWiring(prev.version)])
        case .cancel:
            // Only before the swap; once swapping has begun the update is half applied and runs to its answer.
            guard s.phase == .validating || s.phase == .rendering || s.phase == .consenting,
                  let st = s.staged else { return (s, []) }
            n.phase = .idle; n.staged = nil
            return (n, [.dropStaged(st.version)])
        }
    }
}


struct KitFileFact: Equatable, Sendable {
    var size: Int
    var sha256: String
}

struct KitExecutableDiff: Equatable, Sendable {
    var added: [String]
    var removed: [String]
    var changed: [String]
}

extension KitUpdateMachine {
    /// Paths are keys of outside maps: compared and sorted only, never opened.
    static func diffExecutables(old: [String: KitFileFact], new: [String: KitFileFact]) -> KitExecutableDiff {
        KitExecutableDiff(
            added: new.keys.filter { old[$0] == nil }.sorted(),
            removed: old.keys.filter { new[$0] == nil }.sorted(),
            changed: new.keys.filter { k in old[k].map { $0 != new[k] } ?? false }.sorted())
    }
}
