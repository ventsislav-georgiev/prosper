import Foundation

// Menu-bar ordering engine — pure, AX-free foundation (Phase 1).
//
// Properly persists menu-bar item order across relaunch, including multi-icon apps
// (Stats / iStat Menus) that native AppKit autosave collides. Opt-in,
// version-gated, self-probed. The load-bearing logic (identity composition, the
// reorder diff, the circuit breaker, the OS-support decision) lives here so it is
// unit-tested without touching ScreenCaptureKit / Accessibility / CGS. The live
// layers (image indexing, the synthetic ⌘-drag mover, the enforcement loop) wrap
// these in later phases. See .omc/plans/menubar-ordering-engine.md.

// MARK: - Item identity

/// Stable identity for one menu-bar item, robust across relaunch.
///
/// The hard problem: macOS gives no positional API and native autosave collides
/// items that share a bundle id (Stats publishes CPU / RAM / Net as separate items
/// from one app). We disambiguate with the strongest discriminator available:
///  - pre-Tahoe the OS hands us a per-item `title`;
///  - macOS 26 Tahoe reports every item as "Menu Item" → `title` is useless, so a
///    Screen-Recording index fills `imageHash` (perceptual) + `ocrName`.
struct MenuBarIdentity: Codable, Equatable, Hashable, Sendable {
    var bundleID: String
    /// OS-provided item title; nil/"Menu Item" on Tahoe (then indexing fills the rest).
    var title: String?
    /// Perceptual hash (hex) of the item image, set by the Tahoe indexer.
    var imageHash: String?
    /// Human-readable name recovered by OCR, set by the Tahoe indexer.
    var ocrName: String?

    init(bundleID: String, title: String? = nil, imageHash: String? = nil, ocrName: String? = nil) {
        self.bundleID = bundleID
        self.title = title
        self.imageHash = imageHash
        self.ocrName = ocrName
    }

    /// "Menu Item" / "Item-0" / "Item 1" are Tahoe's placeholders for an item it
    /// can't name — treat them as no title so they can't masquerade as a real
    /// discriminator (and so such foreign items stay unresolved → out of the managed
    /// set, instead of polluting the saved order as "Item-0").
    private var usableTitle: String? {
        guard let t = title, !t.isEmpty, !MenuBarIdentity.isPlaceholderTitle(t) else { return nil }
        return t
    }

    /// Tahoe names unidentifiable menu-bar items with the generic "Menu Item" or an
    /// ordinal "Item-0" / "Item 1". None is a real, app-distinct discriminator.
    static func isPlaceholderTitle(_ t: String) -> Bool {
        t == "Menu Item" || t.range(of: #"^Item[ -]?\d+$"#, options: .regularExpression) != nil
    }

    /// True for items the engine can actually manage on this OS: our own icons
    /// (`com.prosper`, always nameable + movable) or any foreign item with a real
    /// identity. Tahoe placeholder items ("Item-0", unresolvable foreign) are not.
    var isManageable: Bool { bundleID == "com.prosper" || isResolved }

    /// Stable matching key. Picks the strongest discriminator so two items of the
    /// same app don't collapse to one key. When none is available (unindexed on
    /// Tahoe) it degrades to bundle-id alone — correctly degenerate: such items
    /// can't be ordered apart until indexing runs.
    var key: String {
        let disc = usableTitle ?? imageHash ?? ocrName ?? ""
        return "\(bundleID)#\(disc)"
    }

    /// Whether this identity is strong enough to order against same-app siblings.
    var isResolved: Bool { usableTitle != nil || imageHash != nil || ocrName != nil }
}

// MARK: - Persisted store

/// Opt-in ordering settings + the desired left→right layout. Separate from
/// `MenuBarStore` (hide/spacing/chevron) because ordering is a distinct opt-in
/// subsystem with its own permissions and must never bloat the hide hot path.
/// JSON-in-UserDefaults, tolerant Codable (mirrors `MenuBarStore`).
struct MenuBarOrderStore: Codable, Equatable, Sendable {
    static let currentSchema = 1

    enum EnforceMode: String, Codable, Sendable {
        case onDemand   // arrange only on reveal / explicit "Apply order"
        case live       // also snap items back whenever they drift
    }

    var schemaVersion: Int = MenuBarOrderStore.currentSchema
    /// Master opt-in. Feature is fully inert until this is on AND permissions granted.
    var enabled: Bool = false
    var mode: EnforceMode = .onDemand
    /// Desired order, left→right (visible band first). Empty = nothing captured yet.
    var desiredOrder: [MenuBarIdentity] = []

    static let `default` = MenuBarOrderStore()

    init() {}

    /// Field-by-field tolerant decode: a blob missing a key keeps the others
    /// instead of failing the whole decode (which would reset to `.default`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MenuBarOrderStore.default
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        mode = try c.decodeIfPresent(EnforceMode.self, forKey: .mode) ?? d.mode
        desiredOrder = try c.decodeIfPresent([MenuBarIdentity].self, forKey: .desiredOrder) ?? d.desiredOrder
    }
}

// MARK: - OS capability gate

/// Whether the ordering engine can run on this macOS. Hide/show + spacing are
/// unaffected by this — only ordering gates on it.
enum MenuBarOrderingSupport: Equatable, Sendable {
    case supported
    case unsupportedOS(message: String)
}

enum MenuBarOrderingCapability {
    /// Pure OS-support decision from the major version. macOS 26 (Tahoe) is the
    /// built-and-tested target; older = the simpler OS-title path isn't built yet;
    /// newer = unverified, so we refuse rather than glitch ("works perfectly or
    /// not supported"). The live layer ANDs this with permission + self-probe.
    static func osSupport(major: Int) -> MenuBarOrderingSupport {
        switch major {
        case 26:
            return .supported
        case ..<26:
            return .unsupportedOS(message: "Menu-bar ordering currently requires macOS 26 (Tahoe). Support for earlier macOS is on the way.")
        default:
            return .unsupportedOS(message: "Menu-bar ordering hasn’t been verified on this version of macOS yet. Update Prosper once support ships.")
        }
    }
}

// MARK: - Reorder diff

/// One move the arranger must perform: place `key` immediately to the right of
/// `afterKey` (nil = move to the leftmost slot). The live mover realizes this as a
/// synthetic ⌘-drag dropped against the anchor's frame.
struct MenuBarMove: Equatable, Sendable {
    var key: String
    var afterKey: String?
}

enum MenuBarOrderDiff {
    /// Moves (in order) that transform `current` into `desired`. Only keys present
    /// in BOTH are considered (you can't move an item that isn't there, and items
    /// not in the desired layout are left alone).
    ///
    /// Algorithm: walk the desired order left→right, growing a correctly-ordered
    /// prefix. Whenever the next desired key isn't already positioned right after
    /// the running anchor, emit a move and splice it into place. After index i the
    /// prefix desired[0...i] is contiguous and ordered, so it always converges in
    /// ≤ n moves.
    ///
    /// ponytail: O(n²) splice, not move-count-minimal (an LIS pass would skip
    /// already-ordered runs). Fine for a menu bar (tens of items); LIS optimization
    /// is deferred to P4 where the move count actually costs cursor-hijack drags.
    static func reorderMoves(current: [String], desired: [String]) -> [MenuBarMove] {
        let present = Set(current)
        let target = desired.filter { present.contains($0) }
        guard !target.isEmpty else { return [] }

        var seq = current
        var moves: [MenuBarMove] = []
        for (i, key) in target.enumerated() {
            let anchor: String? = i == 0 ? nil : target[i - 1]
            if isPositioned(seq, key: key, after: anchor) { continue }
            moves.append(MenuBarMove(key: key, afterKey: anchor))
            seq = apply(MenuBarMove(key: key, afterKey: anchor), to: seq)
        }
        return moves
    }

    /// True when `key` already sits immediately to the right of `anchor` in `seq`
    /// (or at the front when `anchor` is nil).
    static func isPositioned(_ seq: [String], key: String, after anchor: String?) -> Bool {
        guard let idx = seq.firstIndex(of: key) else { return false }
        guard let anchor else { return idx == 0 }
        guard let aIdx = seq.firstIndex(of: anchor) else { return false }
        return idx == aIdx + 1
    }

    /// Apply one move to a sequence (pure; used by the diff and by tests to verify
    /// convergence). Removes `key`, reinserts it right after `afterKey`.
    static func apply(_ move: MenuBarMove, to seq: [String]) -> [String] {
        var out = seq
        guard let from = out.firstIndex(of: move.key) else { return out }
        out.remove(at: from)
        guard let afterKey = move.afterKey else { out.insert(move.key, at: 0); return out }
        guard let aIdx = out.firstIndex(of: afterKey) else { out.append(move.key); return out }
        out.insert(move.key, at: aIdx + 1)
        return out
    }

    /// Live-mode drift check: are the desired items that are present in `current`
    /// in the correct RELATIVE order (a subsequence of current)? This is laxer than
    /// `reorderMoves` (which also demands contiguity) on purpose — the live loop
    /// must not fight other apps' items wedging between ours, only correct genuine
    /// reordering. O(n). True when nothing needs doing.
    static func isRelativeOrderSatisfied(current: [String], desired: [String]) -> Bool {
        let live = Set(current)
        let target = desired.filter { live.contains($0) }
        guard target.count > 1 else { return true }
        var ti = 0
        for k in current where k == target[ti] {
            ti += 1
            if ti == target.count { return true }
        }
        return false
    }
}

// MARK: - Live enforcement policy

/// Throttle for the live (mode `.live`) enforcement loop. Combines the circuit
/// breaker with a minimum interval between real apply passes that stretches on
/// battery — a synthetic ⌘-drag is expensive and user-visible, so live mode stays
/// gentle. Pure: caller injects `now` (monotonic) and the power state.
struct MenuBarEnforcementPolicy: Equatable, Sendable {
    /// Minimum seconds between apply passes on AC power.
    var baseCooldown: TimeInterval
    /// Multiplier applied to the cooldown when on battery (longer = gentler).
    var batteryMultiplier: Double
    var breaker: MenuBarCircuitBreaker
    private(set) var lastApply: TimeInterval?

    init(baseCooldown: TimeInterval = 2.0, batteryMultiplier: Double = 4.0,
         breaker: MenuBarCircuitBreaker = MenuBarCircuitBreaker()) {
        self.baseCooldown = baseCooldown
        self.batteryMultiplier = batteryMultiplier
        self.breaker = breaker
    }

    func cooldown(onBattery: Bool) -> TimeInterval {
        onBattery ? baseCooldown * batteryMultiplier : baseCooldown
    }

    /// May the loop run an apply pass right now? False while tripped or inside the
    /// interval since the last pass.
    func canApply(now: TimeInterval, onBattery: Bool) -> Bool {
        if breaker.isTripped(now: now) { return false }
        if let last = lastApply, now - last < cooldown(onBattery: onBattery) { return false }
        return true
    }

    /// Record the outcome of an apply pass: stamps the interval and feeds the
    /// breaker (success clears it, failure counts toward a trip).
    mutating func recordApply(now: TimeInterval, success: Bool) {
        lastApply = now
        breaker.resetIfCooledDown(now: now)
        if success { breaker.recordSuccess() } else { breaker.recordFailure(now: now) }
    }

    /// Stamp the cooldown WITHOUT touching the breaker. For a no-op pass (nothing
    /// was actionable): we still want to throttle the next attempt, but feeding the
    /// breaker a "success" here would reset the failure count every tick and disarm
    /// runaway protection for a permanently-stuck loop.
    mutating func stampThrottleOnly(now: TimeInterval) {
        lastApply = now
        breaker.resetIfCooledDown(now: now)
    }
}

// MARK: - Perceptual hash (Tahoe identity rebuild)

/// dHash perceptual hashing + matching. On macOS 26 the OS strips item titles, so
/// identity is rebuilt from the item's rendered image: downsample to 9×8 gray,
/// hash the left→right gradient, and match across relaunch by Hamming distance
/// (tolerant of sub-pixel AA jitter). Pure — the capture/grayscale conversion is
/// the only impure part and lives in `MenuBarItemIndexer`.
enum MenuBarPerceptualHash {
    static let sampleWidth = 9
    static let sampleHeight = 8
    static let byteCount = 72   // 9 × 8

    /// 64-bit difference hash from a row-major 9×8 grayscale buffer. Each of the 8
    /// rows yields 8 bits by comparing each pixel to its right neighbor.
    static func dHash(gray9x8: [UInt8]) -> UInt64 {
        precondition(gray9x8.count == byteCount, "dHash needs a 9×8 (72-byte) buffer")
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<sampleHeight {
            let base = row * sampleWidth
            for col in 0..<8 {
                if gray9x8[base + col] > gray9x8[base + col + 1] { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Hex form used inside `MenuBarIdentity.imageHash` (zero-padded, stable width).
    static func hex(_ hash: UInt64) -> String { String(format: "%016llx", hash) }
    static func value(fromHex hex: String) -> UInt64? { UInt64(hex, radix: 16) }

    /// Among same-bundle candidates, the key whose hash is closest to `target`
    /// within `maxDistance`. Ties resolve to the first (stable). nil if none
    /// qualify — caller then leaves the item unmatched rather than guessing.
    static func bestMatch(target: UInt64, candidates: [(key: String, hash: UInt64)],
                          maxDistance: Int) -> String? {
        var bestKey: String?
        var bestDist = maxDistance + 1
        for c in candidates {
            let d = hamming(target, c.hash)
            if d < bestDist { bestDist = d; bestKey = c.key }
        }
        return bestDist <= maxDistance ? bestKey : nil
    }
}

// MARK: - Circuit breaker

/// Throttles the move/index loop so a misbehaving macOS (a move that never lands,
/// the Tahoe cursor-hijack class) can't melt the CPU — mirrors Bartender's
/// `arrangementCooldown` + "circuit breaker tripped" protection. Pure: the caller
/// injects a monotonic clock so it's deterministic in tests.
struct MenuBarCircuitBreaker: Equatable, Sendable {
    var failureThreshold: Int
    var cooldown: TimeInterval
    private(set) var failures: Int = 0
    private(set) var trippedUntil: TimeInterval?

    init(failureThreshold: Int = 3, cooldown: TimeInterval = 60) {
        self.failureThreshold = failureThreshold
        self.cooldown = cooldown
    }

    mutating func recordSuccess() {
        failures = 0
        trippedUntil = nil
    }

    mutating func recordFailure(now: TimeInterval) {
        failures += 1
        if failures >= failureThreshold {
            trippedUntil = now + cooldown
        }
    }

    /// Tripped → callers must skip arranging/indexing until the cooldown elapses.
    func isTripped(now: TimeInterval) -> Bool {
        guard let until = trippedUntil else { return false }
        return now < until
    }

    /// Clear the trip once the cooldown has elapsed (call at the top of a tick).
    mutating func resetIfCooledDown(now: TimeInterval) {
        if let until = trippedUntil, now >= until {
            failures = 0
            trippedUntil = nil
        }
    }
}
