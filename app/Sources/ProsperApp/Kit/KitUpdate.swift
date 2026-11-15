import Foundation

// #917 S4: the staged-update machine as VALUES. Pure: no file system, path, URL, clock, network or
// process. A version, slug, publisher and hash are outside text and are only compared for equality.
// `step` never traps: an event that does not fit the phase returns the state unchanged and no action.
// The actions are values a later step carries out; nothing here installs, renders or writes a kit.

struct KitRef: Equatable, Sendable {
    var version: String
    var treeHash: String
    var slug: String
}

enum KitUpdatePhase: Equatable, Sendable {
    case idle, validating, rendering, consenting, swapping, shims, wiring, rollingBack
}

enum KitUpdateRefusal: Equatable, Sendable {
    case slugChanged, publisherChanged, validation, consentDenied
}

struct KitUpdateState: Equatable, Sendable {
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

enum KitUpdateEvent: Equatable, Sendable {
    case staged(version: String, treeHash: String, slug: String, publisher: String?)
    case validatedOk(String)
    case validationRefused(String)
    case rendered(String)
    case consentGiven(String)
    case consentDenied(String)
    case swapped(String)
    case swapFailed(String)
    case shimsWritten(String)
    case shimsFailed(String)
    case wiringApplied(String)
    case wiringFailed(String)
    case rollbackRequested
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
    case keepPrevious(String)
    case dropPrevious(String)
    case dropStaged(String)
}

enum KitUpdateMachine {
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
        case let .validatedOk(v):
            guard s.phase == .validating, v == s.staged?.version else { return (s, []) }
            n.phase = .rendering
            return (n, [.renderStaged(v)])
        case let .validationRefused(v):
            guard s.phase == .validating, v == s.staged?.version else { return (s, []) }
            n.phase = .idle; n.staged = nil; n.lastRefusal = .validation
            return (n, [.dropStaged(v)])
        case let .rendered(v):
            guard s.phase == .rendering, v == s.staged?.version else { return (s, []) }
            n.phase = .consenting
            return (n, [.askConsent(v)])
        case let .consentGiven(v):
            guard s.phase == .consenting, v == s.staged?.version else { return (s, []) }
            n.phase = .swapping
            return (n, [.swap(v)])
        case let .consentDenied(v):
            guard s.phase == .consenting, v == s.staged?.version else { return (s, []) }
            n.phase = .idle; n.staged = nil; n.lastRefusal = .consentDenied
            return (n, [.dropStaged(v)])
        case let .swapped(v):
            guard s.phase == .swapping, let st = s.staged, v == st.version else { return (s, []) }
            n.retiring = s.previous; n.previous = s.live; n.live = st; n.phase = .shims
            return (n, [.keepPrevious(s.live.version), .writeShims(v)])
        case let .swapFailed(v):
            guard s.phase == .swapping, v == s.staged?.version else { return (s, []) }
            n.phase = .idle; n.staged = nil
            return (n, [.dropStaged(v)])
        case let .shimsWritten(v):
            guard s.phase == .shims, v == s.live.version else { return (s, []) }
            n.phase = .wiring
            return (n, [.applyWiring(v)])
        case let .shimsFailed(v):
            guard s.phase == .shims, v == s.live.version, let old = s.previous else { return (s, []) }
            n.live = old; n.previous = s.retiring; n.retiring = nil; n.staged = nil; n.phase = .idle
            return (n, [.swapBack, .writeShims(old.version), .dropStaged(v)])
        case let .wiringApplied(v):
            guard v == s.live.version else { return (s, []) }
            if s.phase == .wiring {
                n.phase = .idle; n.staged = nil; n.retiring = nil
                return (n, s.retiring.map { [.dropPrevious($0.version)] } ?? [])
            }
            if s.phase == .rollingBack { n.phase = .idle; return (n, []) }
            return (s, [])
        case let .wiringFailed(v):
            guard v == s.live.version else { return (s, []) }
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
            n.live = prev; n.previous = s.live; n.phase = .rollingBack
            return (n, [.swapBack, .writeShims(prev.version), .applyWiring(prev.version)])
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
