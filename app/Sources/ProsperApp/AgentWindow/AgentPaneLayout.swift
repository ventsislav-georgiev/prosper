import CoreGraphics
import Foundation

// #831 Phase A: split panes and saved layouts in the Agent Sessions window, the pure model (spec v3.1
// §3, §4.1-4.1a, §7.1, §8.1-8.2, §15.0). Foundation and CoreGraphics only: no view, no window, no
// defaults, no file access. Geometry is top-left origin, y growing down (SwiftUI's), in ·s points the
// caller has already scaled with sz(). Nothing calls this yet; Phase A2 wires it into the window model.

// MARK: - 3.1 Types

/// What a pane shows. A pane stores a target, never a session (4.1). Equality and hashing ignore a
/// History target's `seen` (3.1).
enum PaneTarget: Hashable {
    /// A local session, its AgentSessionKey.
    case session(dir: String, name: String)
    /// A History record by its `id` (#714: the aside file, else the name) and its lastSeen when targeted.
    case history(dir: String, id: String, seen: TimeInterval?)
    /// #822 P3: a remote session (Terminal only).
    case remote(host: String, name: String)

    /// The session a target stands for, for the no-duplicates rule (3.2): `.session(d, n)` and the name's
    /// own `.history(d, n)` are one session (#580: that record's id equals the live key).
    enum Identity: Hashable {
        case local(dir: String, name: String)
        case remote(host: String, name: String)
    }

    var identity: Identity {
        switch self {
        case let .session(d, n), let .history(d, n, _): .local(dir: d, name: n)
        case let .remote(h, n): .remote(host: h, name: n)
        }
    }

    private var fields: [String] {
        switch self {
        case let .session(d, n): ["session", d, n]
        case let .history(d, id, _): ["history", d, id]
        case let .remote(h, n): ["remote", h, n]
        }
    }

    static func == (a: PaneTarget, b: PaneTarget) -> Bool { a.fields == b.fields }
    func hash(into h: inout Hasher) { h.combine(fields) }
}

struct Pane: Hashable {
    /// Stable for the pane's life.
    let id: UUID
    /// nil = an empty pane ("Pick a session from the list").
    var target: PaneTarget?
}

indirect enum PaneNode: Hashable {
    case leaf(Pane)
    /// `first` is left (columns) or top (rows).
    case split(Axis, ratio: Double, PaneNode, PaneNode)

    /// columns = side by side.
    enum Axis: String, Codable { case columns, rows }
}

struct PaneLayout: Hashable, Codable, Identifiable {
    let id: UUID
    /// nil = automatic (the pane titles joined, 8.1).
    var name: String?
    var tree: PaneNode
    /// A pane id of this tree.
    var focused: UUID
    /// A pane id, or nil.
    var zoomed: UUID?
    /// Pane ids, most recently focused first: `neighbour` ties and the focus after a close (QA D3).
    /// Runtime only: not saved, not compared.
    var recent: [UUID] = []

    private enum CodingKeys: String, CodingKey { case id, name, tree, focused, zoomed }

    static func == (a: PaneLayout, b: PaneLayout) -> Bool {
        a.id == b.id && a.name == b.name && a.tree == b.tree && a.focused == b.focused && a.zoomed == b.zoomed
    }

    func hash(into h: inout Hasher) {
        h.combine(id); h.combine(name); h.combine(tree); h.combine(focused); h.combine(zoomed)
    }

    /// One pane, focused: the default layout (8.1) and a New Layout.
    static func single(_ target: PaneTarget? = nil, id: UUID = UUID()) -> PaneLayout {
        let pane = Pane(id: UUID(), target: target)
        return PaneLayout(id: id, name: nil, tree: .leaf(pane), focused: pane.id, zoomed: nil)
    }
}

/// A refused operation. `notice` is the pane notice line's text (3.3), returned as data: nothing is drawn here.
enum PaneRefusal: Error, Equatable {
    /// The 7th pane (3.3).
    case cap
    /// A split that would leave a pane below the minimum, or a layout already too small for its panes.
    case noRoom
    /// Close of the only pane: the window closes instead (7.3).
    case lastPane
    /// The target is already shown in this pane of the layout (no duplicates, 3.2).
    case shown(UUID)
    case noSuchPane
    case noSuchSplit
    /// The 10th layout (8.1).
    case layoutCap
    /// Delete of the only layout (8.1).
    case lastLayout
    case noSuchLayout

    var notice: String? {
        switch self {
        case .cap: "6 panes is the most a layout holds"
        case .noRoom: "No room for another pane here. Widen the window or hide the sidebar (⌃⌘S)."
        default: nil
        }
    }

    /// Appended to a disabled menu item's title: "Split Right (6 panes max)", "New Layout (9 layouts max)".
    var menuSuffix: String? {
        switch self {
        case .cap: "(6 panes max)"
        case .layoutCap: "(9 layouts max)"
        default: nil
        }
    }
}

// MARK: - 8.2 The blob's leaf and split shapes

extension Pane: Codable {
    private enum Key: String, CodingKey { case pane, session, history, remote }
    private struct Local: Codable { var dir: String; var name: String }
    private struct Record: Codable { var dir: String; var id: String; var seen: TimeInterval? }
    private struct Remote: Codable { var host: String; var name: String }

    /// {"pane": id, "session"|"history"|"remote": {...}}. No target key, an unknown kind, or a known kind
    /// this build cannot read is an empty pane (8.2).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(UUID.self, forKey: .pane)
        if let s = try? c.decode(Local.self, forKey: .session) {
            target = .session(dir: s.dir, name: s.name)
        } else if let r = try? c.decode(Record.self, forKey: .history) {
            target = .history(dir: r.dir, id: r.id, seen: r.seen)
        } else if let r = try? c.decode(Remote.self, forKey: .remote) {
            target = .remote(host: r.host, name: r.name)
        } else {
            target = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .pane)
        switch target {
        case let .session(d, n)?: try c.encode(Local(dir: d, name: n), forKey: .session)
        case let .history(d, id, seen)?: try c.encode(Record(dir: d, id: id, seen: seen), forKey: .history)
        case let .remote(h, n)?: try c.encode(Remote(host: h, name: n), forKey: .remote)
        case nil: break
        }
    }
}

extension PaneNode: Codable {
    private enum Key: String, CodingKey { case split, ratio, first, second }

    /// A split is {"split": axis, "ratio", "first", "second"}; anything else is a leaf.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard c.contains(.split) else {
            self = .leaf(try Pane(from: decoder))
            return
        }
        // shortcut: an axis this build does not know reads as columns; a newer schema is flagged by "v" (8.2).
        let axis = Axis(rawValue: try c.decode(String.self, forKey: .split)) ?? .columns
        // A missing ratio is 0.5; an out-of-range one is clamped by repair (3.2).
        let ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5
        self = .split(axis, ratio: ratio, try c.decode(PaneNode.self, forKey: .first),
                      try c.decode(PaneNode.self, forKey: .second))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .leaf(pane):
            try pane.encode(to: encoder)
        case let .split(axis, ratio, a, b):
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(axis, forKey: .split)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(a, forKey: .first)
            try c.encode(b, forKey: .second)
        }
    }
}

// MARK: - 3.1 Tree helpers

extension PaneNode {
    /// Tree order: depth first, first before second.
    var panes: [Pane] {
        switch self {
        case let .leaf(p): [p]
        case let .split(_, _, a, b): a.panes + b.panes
        }
    }

    func mapPanes(_ f: (Pane) -> Pane) -> PaneNode {
        switch self {
        case let .leaf(p): .leaf(f(p))
        case let .split(axis, ratio, a, b): .split(axis, ratio: ratio, a.mapPanes(f), b.mapPanes(f))
        }
    }

    func mapRatios(_ f: (Double) -> Double) -> PaneNode {
        switch self {
        case .leaf: self
        case let .split(axis, ratio, a, b): .split(axis, ratio: f(ratio), a.mapRatios(f), b.mapRatios(f))
        }
    }

    /// The leaf `id` swapped for `f(pane)`.
    func replacing(_ id: UUID, _ f: (Pane) -> PaneNode) -> PaneNode {
        switch self {
        case let .leaf(p): p.id == id ? f(p) : self
        case let .split(axis, ratio, a, b): .split(axis, ratio: ratio, a.replacing(id, f), b.replacing(id, f))
        }
    }

    /// The tree without the leaf `id`: its sibling takes the parent's place. nil when this is that leaf.
    func removing(_ id: UUID) -> PaneNode? {
        switch self {
        case let .leaf(p):
            return p.id == id ? nil : self
        case let .split(axis, ratio, a, b):
            guard let a2 = a.removing(id) else { return b }
            guard let b2 = b.removing(id) else { return a }
            return .split(axis, ratio: ratio, a2, b2)
        }
    }

    /// The first `budget` leaves in tree order, in one pass that stops descending once the budget is spent:
    /// a split left with one side becomes that side (as `removing` does). nil when `budget` starts at 0.
    func keepingFirst(_ budget: inout Int) -> PaneNode? {
        guard budget > 0 else { return nil }
        switch self {
        case .leaf:
            budget -= 1
            return self
        case let .split(axis, ratio, a, b):
            let a2 = a.keepingFirst(&budget)
            let b2 = b.keepingFirst(&budget)
            guard let a2 else { return b2 }
            guard let b2 else { return a2 }
            return .split(axis, ratio: ratio, a2, b2)
        }
    }

    /// The subtree that takes the space when the leaf `id` closes.
    func sibling(of id: UUID) -> PaneNode? {
        guard case let .split(_, _, a, b) = self else { return nil }
        if case let .leaf(p) = a, p.id == id { return b }
        if case let .leaf(p) = b, p.id == id { return a }
        return a.sibling(of: id) ?? b.sibling(of: id)
    }

    /// The node at `path` (0 = first, 1 = second, from the root) and its rect in `r`.
    func locate(_ path: ArraySlice<Int>, in r: CGRect) -> (node: PaneNode, rect: CGRect)? {
        guard let i = path.first else { return (self, r) }
        guard case let .split(axis, ratio, a, b) = self, i == 0 || i == 1 else { return nil }
        let (x, y) = Self.divide(r, axis, ratio)
        return i == 0 ? a.locate(path.dropFirst(), in: x) : b.locate(path.dropFirst(), in: y)
    }

    /// `f` applied to the node at `path` (a path `locate` found).
    func updating(_ path: ArraySlice<Int>, _ f: (PaneNode) -> PaneNode) -> PaneNode {
        guard let i = path.first, case let .split(axis, ratio, a, b) = self else { return f(self) }
        return i == 0 ? .split(axis, ratio: ratio, a.updating(path.dropFirst(), f), b)
                      : .split(axis, ratio: ratio, a, b.updating(path.dropFirst(), f))
    }

    /// QA D1: ratio = leaves(first) / leaves(both); `deep` also equalizes every split below.
    func equalized(deep: Bool) -> PaneNode {
        guard case let .split(axis, _, a, b) = self else { return self }
        let (na, nb) = (a.panes.count, b.panes.count)
        return .split(axis, ratio: Double(na) / Double(na + nb),
                      deep ? a.equalized(deep: true) : a, deep ? b.equalized(deep: true) : b)
    }

    /// The smallest size that keeps every leaf at `m` with this tree's ratios.
    func minSize(_ m: CGSize) -> CGSize {
        guard case let .split(axis, ratio, a, b) = self else { return m }
        let (x, y) = (a.minSize(m), b.minSize(m))
        return axis == .columns
            ? CGSize(width: max(x.width / ratio, y.width / (1 - ratio)), height: max(x.height, y.height))
            : CGSize(width: max(x.width, y.width), height: max(x.height / ratio, y.height / (1 - ratio)))
    }

    func tile(_ r: CGRect, into out: inout [UUID: CGRect]) {
        switch self {
        case let .leaf(p):
            out[p.id] = r
        case let .split(axis, ratio, a, b):
            let (x, y) = Self.divide(r, axis, ratio)
            a.tile(x, into: &out)
            b.tile(y, into: &out)
        }
    }

    static func divide(_ r: CGRect, _ axis: Axis, _ ratio: Double) -> (CGRect, CGRect) {
        if axis == .columns {
            let w = r.width * ratio
            return (CGRect(x: r.minX, y: r.minY, width: w, height: r.height),
                    CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
        }
        let h = r.height * ratio
        return (CGRect(x: r.minX, y: r.minY, width: r.width, height: h),
                CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h))
    }
}

// MARK: - 3.1 Operations, 3.3 cap and minimum, 3.4 frames

extension PaneLayout {
    /// 3.3: at most 6 panes per layout.
    static let maxPanes = 6
    /// 3.3: the minimum pane, in ·s units (the caller scales it with sz()).
    static let minimumPane = CGSize(width: 300, height: 200)
    /// 3.2: every ratio stays in [0.1, 0.9].
    static let ratioRange = 0.1...0.9

    enum Direction { case left, right, up, down }

    /// 3.4: `.tiled` gives every visible pane's frame; `.tooSmall` shows the focused pane alone.
    enum Frames: Equatable {
        case tiled([UUID: CGRect])
        case tooSmall(UUID)
    }

    var panes: [Pane] { tree.panes }
    var order: [UUID] { panes.map(\.id) }

    /// The pane already showing `target`'s session, by identity (3.2).
    func pane(showing target: PaneTarget) -> UUID? {
        panes.first { $0.target?.identity == target.identity }?.id
    }

    /// Splits the focused pane: the new pane (empty, or `target`) goes right or below and takes focus.
    /// Refused at the cap, for a target already shown, and when the result does not fit `area` (3.3).
    func split(axis: PaneNode.Axis, target: PaneTarget? = nil, minimum: CGSize,
               in area: CGRect) -> Result<PaneLayout, PaneRefusal> {
        // A dangling focus would otherwise "split" nothing and focus a pane that is not in the tree.
        guard order.contains(focused) else { return .failure(.noSuchPane) }
        if panes.count >= Self.maxPanes { return .failure(.cap) }
        if let target, let shown = pane(showing: target) { return .failure(.shown(shown)) }
        let new = Pane(id: UUID(), target: target)
        var out = self
        out.zoomed = nil   // 7.3: a split while zoomed unzooms first
        out.tree = tree.replacing(focused) { .split(axis, ratio: 0.5, .leaf($0), .leaf(new)) }
        guard case .tiled = out.frames(in: area, minimum: minimum, splitsEnabled: true) else { return .failure(.noRoom) }
        out.setFocus(new.id)
        return .success(out)
    }

    /// Closes a pane: its sibling subtree takes the space and, when it was focused, the focus goes to the
    /// sibling's most recently focused pane, else its first in tree order (7.3). The last pane is refused.
    func close(_ id: UUID) -> Result<PaneLayout, PaneRefusal> {
        guard order.contains(id) else { return .failure(.noSuchPane) }
        guard panes.count > 1, let rest = tree.removing(id), let sibling = tree.sibling(of: id) else {
            return .failure(.lastPane)
        }
        var out = self
        out.tree = rest
        out.zoomed = nil   // 7.3: a close while zoomed unzooms first
        out.recent.removeAll { $0 == id }
        if focused == id {
            let ids = sibling.panes.map(\.id)
            if let next = out.recent.first(where: ids.contains) ?? ids.first { out.setFocus(next) }
        }
        return .success(out)
    }

    /// Focuses a pane. While zoomed the zoom moves to it (7.4, OQ-2).
    func focus(_ id: UUID) -> Result<PaneLayout, PaneRefusal> {
        guard order.contains(id) else { return .failure(.noSuchPane) }
        var out = self
        out.setFocus(id)
        return .success(out)
    }

    private mutating func setFocus(_ id: UUID) {
        focused = id
        recent = [id] + recent.filter { $0 != id }
        if zoomed != nil { zoomed = id }
    }

    /// The nearest pane in `direction` from `id` that overlaps it on the other axis; ties go to the most
    /// recently focused, then tree order (QA D3). nil when there is none.
    func neighbour(of id: UUID, direction: Direction, frames: [UUID: CGRect]) -> UUID? {
        guard let from = frames[id] else { return nil }
        let tol: CGFloat = 0.5
        let rank = { (p: UUID) in recent.firstIndex(of: p) ?? recent.count }
        var best: (gap: CGFloat, rank: Int, id: UUID)?
        for p in order where p != id {
            guard let r = frames[p] else { continue }
            let rows = r.minY < from.maxY - tol && r.maxY > from.minY + tol
            let cols = r.minX < from.maxX - tol && r.maxX > from.minX + tol
            let edge: (gap: CGFloat, overlaps: Bool) = switch direction {
            case .left: (from.minX - r.maxX, rows)
            case .right: (r.minX - from.maxX, rows)
            case .up: (from.minY - r.maxY, cols)
            case .down: (r.minY - from.maxY, cols)
            }
            let gap = edge.gap
            guard edge.overlaps, gap > -tol else { continue }
            if let b = best, gap > b.gap - tol, !(abs(gap - b.gap) <= tol && rank(p) < b.rank) { continue }
            best = (gap, rank(p), p)
        }
        return best?.id
    }

    /// ⌘] / ⌘[: the next or previous pane in tree order, wrapping (12.1).
    var next: UUID { cycled(1) }
    var previous: UUID { cycled(-1) }

    private func cycled(_ step: Int) -> UUID {
        let ids = order
        guard let i = ids.firstIndex(of: focused) else { return ids.first ?? focused }
        return ids[(i + step + ids.count) % ids.count]
    }

    /// A divider's ratio: kept in [0.1, 0.9] and, where `area` leaves room, with both sides at or above the
    /// minimum (3.3: a drag clamps at it). `path` names the split (0 = first, 1 = second, from the root).
    func setRatio(path: [Int], _ ratio: Double, minimum: CGSize, in area: CGRect) -> Result<PaneLayout, PaneRefusal> {
        guard let found = tree.locate(path[...], in: area), case let .split(axis, _, a, b) = found.node else {
            return .failure(.noSuchSplit)
        }
        var r = Self.clampRatio(ratio)
        let length = axis == .columns ? found.rect.width : found.rect.height
        if length > 0 {
            let lo = (axis == .columns ? a.minSize(minimum).width : a.minSize(minimum).height) / length
            let hi = 1 - (axis == .columns ? b.minSize(minimum).width : b.minSize(minimum).height) / length
            if lo <= hi { r = Self.clampRatio(min(max(r, lo), hi)) }
        }
        var out = self
        out.tree = tree.updating(path[...]) { _ in .split(axis, ratio: r, a, b) }
        return .success(out)
    }

    /// Equalizes the split at `path` (a divider's double-click); `deep` also every split below it
    /// ("Equalize" in "⋯" is `path: []`, `deep: true`). Ratio = leaves(first) / leaves(both) (QA D1).
    func equalize(path: [Int], deep: Bool = false) -> Result<PaneLayout, PaneRefusal> {
        guard case .split? = tree.locate(path[...], in: .zero)?.node else { return .failure(.noSuchSplit) }
        var out = self
        out.tree = tree.updating(path[...]) { $0.equalized(deep: deep) }
        return .success(out)
    }

    /// ⇧⌘Return: zoom the focused pane, or unzoom. One pane, or a focus on no pane, has nothing to zoom.
    func toggleZoom() -> PaneLayout {
        var out = self
        out.zoomed = zoomed == nil && panes.count > 1 && order.contains(focused) ? focused : nil
        return out
    }

    /// Sets a pane's target (nil empties it). Refused when another pane already shows that session.
    func replace(_ id: UUID, target: PaneTarget?) -> Result<PaneLayout, PaneRefusal> {
        guard order.contains(id) else { return .failure(.noSuchPane) }
        if let target, let shown = pane(showing: target), shown != id { return .failure(.shown(shown)) }
        var out = self
        out.tree = tree.replacing(id) { .leaf(Pane(id: $0.id, target: target)) }
        return .success(out)
    }

    /// Every pane's frame in `area`, or `.tooSmall(focused)` when a pane would fall below `minimum` (3.4).
    /// Zoom is not applied here: the zoomed pane is drawn over the whole area and the tiling stays the
    /// geometry `neighbour` moves the zoom over (7.4). 15.0: with the split gate off a multi-pane layout
    /// shows its focused pane alone, with no chip; the tree is kept as it is.
    func frames(in area: CGRect, minimum: CGSize, splitsEnabled: Bool) -> Frames {
        if !splitsEnabled, panes.count > 1 { return .tiled([focused: area]) }
        var out: [UUID: CGRect] = [:]
        tree.tile(area, into: &out)
        let fits = out.values.allSatisfy { Self.atLeast($0.width, minimum.width) && Self.atLeast($0.height, minimum.height) }
        return fits || panes.count == 1 ? .tiled(out) : .tooSmall(focused)
    }

    /// `v >= m` to a thousandth of a point, so a pane exactly at the minimum fits despite float division.
    static func atLeast(_ v: CGFloat, _ m: CGFloat) -> Bool { (v * 1000).rounded() >= (m * 1000).rounded() }

    static func clampRatio(_ r: Double) -> Double {
        r.isFinite ? min(max(r, ratioRange.lowerBound), ratioRange.upperBound) : 0.5
    }
}

// MARK: - 3.2 Invariants and repair

/// One repair, for the caller to log once. No paths, names or ids in it (QA R6.10).
enum PaneRepair: Equatable {
    case duplicatePaneID, tooManyPanes, duplicateTarget, ratioClamped, danglingFocus, danglingZoom
    /// The zoom is a leaf but not the focused one (keys would go to a hidden pane).
    case zoomNotFocused
    case corruptBlob, noLayouts, tooManyLayouts, duplicateLayoutID, danglingActive, mru
}

extension PaneLayout {
    /// 3.2: 1 to 6 leaves, unique pane ids, no session twice, ratios in [0.1, 0.9], focus on a leaf, zoom nil
    /// or the focused leaf.
    func validate() -> Bool { repaired().repairs.isEmpty }

    /// Repair, never drop (3.2): a later duplicate pane id gets a fresh UUID; leaves beyond 6 go from the
    /// end of tree order in one pass (their sibling takes the space); a later duplicate target becomes an
    /// empty pane; ratios clamp; a dangling focus moves to the first leaf; then a zoom that is not on a
    /// leaf, or not on the (repaired) focus, clears.
    func repaired() -> (layout: PaneLayout, repairs: [PaneRepair]) {
        var out = self, repairs: [PaneRepair] = []
        var ids = Set<UUID>(), dupID = false
        out.tree = out.tree.mapPanes { p in
            if !ids.insert(p.id).inserted { dupID = true; return Pane(id: UUID(), target: p.target) }
            return p
        }
        if dupID { repairs.append(.duplicatePaneID) }
        if out.panes.count > Self.maxPanes {
            var budget = Self.maxPanes
            if let kept = out.tree.keepingFirst(&budget) { out.tree = kept }
            repairs.append(.tooManyPanes)
        }
        var shown = Set<PaneTarget.Identity>(), dupTarget = false
        out.tree = out.tree.mapPanes { p in
            if let t = p.target, !shown.insert(t.identity).inserted { dupTarget = true; return Pane(id: p.id, target: nil) }
            return p
        }
        if dupTarget { repairs.append(.duplicateTarget) }
        var clamped = false
        out.tree = out.tree.mapRatios { r in
            let c = Self.clampRatio(r)
            if c != r { clamped = true }
            return c
        }
        if clamped { repairs.append(.ratioClamped) }
        let leaves = out.order
        if !leaves.contains(out.focused), let first = leaves.first {
            out.focused = first
            repairs.append(.danglingFocus)
        }
        if let z = out.zoomed, !leaves.contains(z) {
            out.zoomed = nil
            repairs.append(.danglingZoom)
        } else if let z = out.zoomed, z != out.focused {
            // 7.4: every operation keeps zoomed == focused; a saved blob need not. Compared with the
            // focus as repaired above, so a zoom on the first leaf survives a focus moved there.
            out.zoomed = nil
            repairs.append(.zoomNotFocused)
        }
        out.recent = out.recent.filter(leaves.contains)
        return (out, repairs)
    }
}

// MARK: - 4.1 resolve, 4.1a the lastLive map, 15.0 the split gate

/// What a pane's target resolves to right now (4.1).
enum PaneContent: Equatable {
    case live(AgentSession)
    case history(DchHistoryRecord)
    case notRunning(AgentSessionKey)
    case removed(PaneTarget)
}

/// The last live sight of a pane's `.session` target (4.1a). Never persisted.
struct LastLive: Hashable {
    /// The store poll's time of the publish that listed it live.
    var at: TimeInterval
    /// AgentSession.claudeSessionID at that publish; "" when none.
    var claudeSessionID: String
}

enum AgentPaneLayout {
    /// 15.0: split creation stays unreachable until Phase C flips this. Not user facing: no defaults key, no menu.
    @MainActor static var splitsEnabled = false

    /// AgentWindowModel.recordSlack (65 s): that one is @MainActor-isolated, so a nonisolated default
    /// argument cannot read it. A test pins the two equal.
    static let recordSlack: TimeInterval = 65

    /// 4.1a: the window model's [pane id: LastLive], kept for the process lifetime.
    typealias LastLiveMap = [UUID: LastLive]

    /// 4.1. Pure: reads no file, runs nothing. `lastLive` is this pane's entry in the map, nil when none.
    static func resolve(_ target: PaneTarget, sessions: [AgentSession], history: [DchHistoryRecord],
                        lastLive: LastLive?, slack: TimeInterval = AgentPaneLayout.recordSlack) -> PaneContent {
        switch target {
        case let .session(dir, name):
            let key = AgentSessionKey(dir: dir, name: name)
            if let s = sessions.first(where: { $0.key == key }) { return .live(s) }
            // Only a pane that saw this instance live can tell which record is its own (QA #669 F1).
            if let l = lastLive,
               let r = history.filter({ $0.key == key && matches($0, l, slack: slack) }).max(by: { $0.lastSeen < $1.lastSeen }) {
                return .history(r)
            }
            return .notRunning(key)
        case let .history(dir, id, seen):
            let rid = AgentSessionKey(dir: dir, name: id)
            if let r = history.first(where: { $0.id == rid && (seen == nil || $0.lastSeen == seen) }) { return .history(r) }
            // QA INFO-14: a cold start under the name moved the name's own record aside to <name>.<ended>.
            if let seen, let r = history.first(where: { $0.key == rid && $0.isAside && $0.lastSeen == seen }) {
                return .history(r)
            }
            return .removed(target)
        case let .remote(host, name):
            // shortcut: no remote list exists before #822 P3, so a remote pane is never live; P3 adds the list.
            return .notRunning(AgentSessionKey(dir: "@" + host, name: name))
        }
    }

    /// 4.1 `matches` (QA #669 INFO-N8): the record was last seen within `slack` of the last live sight AND,
    /// when both Claude session ids are set, they are equal. One id unset: the time rule alone. The time
    /// rule always holds for the instance's own record, so a hand `claude --resume <id>` that leaves an
    /// older aside record with the same id cannot bind that record.
    static func matches(_ r: DchHistoryRecord, _ l: LastLive, slack: TimeInterval = AgentPaneLayout.recordSlack) -> Bool {
        guard r.lastSeen >= l.at - slack else { return false }
        if let sid = r.agent?.sessionID, !sid.isEmpty, !l.claudeSessionID.isEmpty { return sid == l.claudeSessionID }
        return true
    }

    /// 4.1a: stamps every visible pane whose `.session` target is live in this publish, with the store
    /// poll's time `at` (never a later refresh's).
    static func stamp(_ map: LastLiveMap, panes: [Pane], visible: Set<UUID>, sessions: [AgentSession],
                      at: TimeInterval) -> LastLiveMap {
        var out = map
        for p in panes where visible.contains(p.id) {
            guard case let .session(dir, name)? = p.target,
                  let s = sessions.first(where: { $0.key == AgentSessionKey(dir: dir, name: name) }) else { continue }
            out[p.id] = LastLive(at: at, claudeSessionID: s.claudeSessionID ?? "")
        }
        return out
    }

    /// 4.1a: entries for pane ids in no layout are dropped (store load, layout or pane delete).
    static func pruned(_ map: LastLiveMap, keeping store: PaneLayoutStore) -> LastLiveMap {
        let ids = Set(store.layouts.flatMap(\.order))
        return map.filter { ids.contains($0.key) }
    }
}

// MARK: - 7.1 The browse rule

extension PaneLayout {
    enum Placement { case focused, side }

    /// `show(row, placement)`: (1) a session or record already shown focuses its pane; (2) `.focused` puts it
    /// in the focused pane; (3) `.side` splits the focused pane along its longer side (a tie gives columns),
    /// refused at the cap or below the minimum. With the split gate off `.side` acts as `.focused` (15.0).
    func show(_ target: PaneTarget, placement: Placement, minimum: CGSize, in area: CGRect,
              splitsEnabled: Bool) -> Result<PaneLayout, PaneRefusal> {
        if let shown = pane(showing: target) { return focus(shown) }
        guard placement == .side, splitsEnabled else { return replace(focused, target: target) }
        var r = area
        if case let .tiled(f) = frames(in: area, minimum: minimum, splitsEnabled: true), let mine = f[focused] { r = mine }
        return split(axis: r.width >= r.height ? .columns : .rows, target: target, minimum: minimum, in: area)
    }

    /// Walking the list (7.1, OQ-1): the next navigable row after the focused pane's (before it when
    /// `down` is false), skipping rows shown in ANOTHER pane. nil = the step is a no-op: never a wrap.
    /// A focused pane showing no row starts before the first (after the last) row.
    func walk(_ rows: [PaneTarget], down: Bool) -> PaneTarget? {
        let mine = panes.first { $0.id == focused }?.target?.identity
        let elsewhere = Set(panes.filter { $0.id != focused }.compactMap { $0.target?.identity })
        let ids = rows.map(\.identity)
        var i = mine.flatMap { ids.firstIndex(of: $0) } ?? (down ? -1 : ids.count)
        for _ in ids.indices {
            i += down ? 1 : -1
            guard ids.indices.contains(i) else { return nil }
            if !elsewhere.contains(ids[i]) { return rows[i] }
        }
        return nil
    }
}

// MARK: - 8.1 / 8.2 The layout store

/// Every layout of the window, as one versioned blob: {"v", "active", "mru", "layouts"} (8.2).
struct PaneLayoutStore: Hashable {
    static let version = 1
    /// 8.1: at most 9 (⌘1..9).
    static let maxLayouts = 9

    /// The ⌘1..9 order.
    var layouts: [PaneLayout]
    var active: UUID
    /// Layout ids, most recently active first (⌃Tab switches to the second).
    var mru: [UUID]

    /// 8.1: one layout of one empty pane that follows the sidebar.
    static func makeDefault() -> PaneLayoutStore {
        let l = PaneLayout.single()
        return PaneLayoutStore(layouts: [l], active: l.id, mru: [l.id])
    }

    /// ⌃Tab's target: the layout active before this one.
    var previous: UUID? { mru.dropFirst().first }

    /// A switch: `id` becomes active and the front of the MRU.
    func activate(_ id: UUID) -> Result<PaneLayoutStore, PaneRefusal> {
        guard layouts.contains(where: { $0.id == id }) else { return .failure(.noSuchLayout) }
        var out = self
        out.active = id
        out.mru = [id] + mru.filter { $0 != id }
        return .success(out)
    }

    /// New / Duplicate: refused at 9 layouts.
    func adding(_ layout: PaneLayout) -> Result<PaneLayoutStore, PaneRefusal> {
        guard layouts.count < Self.maxLayouts else { return .failure(.layoutCap) }
        var out = self
        out.layouts.append(layout)
        return .success(out)
    }

    /// Delete: refused on the last layout. A deleted active layout hands over to the MRU's next.
    func deleting(_ id: UUID) -> Result<PaneLayoutStore, PaneRefusal> {
        guard layouts.contains(where: { $0.id == id }) else { return .failure(.noSuchLayout) }
        guard layouts.count > 1 else { return .failure(.lastLayout) }
        var out = self
        out.layouts.removeAll { $0.id == id }
        out.mru.removeAll { $0 == id }
        if active == id, let next = out.mru.first ?? out.layouts.first?.id {
            out.active = next
            out.mru = [next] + out.mru.filter { $0 != next }
        }
        return .success(out)
    }

    private struct Blob: Codable {
        var v: Int?
        var active: UUID?
        var mru: [UUID]?
        var layouts: [PaneLayout]
    }

    private struct Probe: Decodable { var v: Int? }

    /// The largest blob decoded. A full store (9 layouts of 6 panes with long paths) is a few tens of KB;
    /// anything over this is corrupt, refused before any JSON work.
    static let maxBlobBytes = 1 << 20

    /// Tolerant decode (8.2): unknown fields ignored, missing optional ones nil, every layout repaired (3.2),
    /// never dropped. nil data is the default store; a corrupt or oversized blob is the default store with
    /// `.corruptBlob`. `needsBackup`: the caller copies the raw bytes once to the backup key before its
    /// first write. True for a blob whose "v" is newer than this build's, and for any non-empty blob that
    /// does not decode (or is over `maxBlobBytes`), so one bad field never costs the user their layouts.
    /// nil and empty data: false (nothing to keep).
    static func decode(_ data: Data?) -> (store: PaneLayoutStore, repairs: [PaneRepair], needsBackup: Bool) {
        guard let data else { return (makeDefault(), [], false) }
        if data.count > maxBlobBytes { return (makeDefault(), [.corruptBlob], true) }
        let needsBackup = ((try? JSONDecoder().decode(Probe.self, from: data))?.v ?? 0) > version
        guard let blob = try? JSONDecoder().decode(Blob.self, from: data) else {
            return (makeDefault(), [.corruptBlob], !data.isEmpty)
        }
        var repairs: [PaneRepair] = [], layouts: [PaneLayout] = [], ids = Set<UUID>()
        if blob.layouts.count > maxLayouts { repairs.append(.tooManyLayouts) }
        for decoded in blob.layouts.prefix(maxLayouts) {
            let fixed = decoded.repaired()
            var l = fixed.layout
            repairs += fixed.repairs
            if !ids.insert(l.id).inserted {
                l = PaneLayout(id: UUID(), name: l.name, tree: l.tree, focused: l.focused, zoomed: l.zoomed)
                ids.insert(l.id)
                repairs.append(.duplicateLayoutID)
            }
            layouts.append(l)
        }
        guard let first = layouts.first else { return (makeDefault(), [.noLayouts], needsBackup) }
        var active = first.id
        if let a = blob.active, ids.contains(a) { active = a } else if blob.active != nil { repairs.append(.danglingActive) }
        var seen = Set<UUID>()
        let mru = ([active] + (blob.mru ?? []).filter(ids.contains)).filter { seen.insert($0).inserted }
        if let m = blob.mru, m != mru { repairs.append(.mru) }
        return (PaneLayoutStore(layouts: layouts, active: active, mru: mru), repairs, needsBackup)
    }

    /// The blob (8.2), keys sorted. Throws only on a value JSON cannot hold; the caller then writes nothing.
    func encode() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(Blob(v: Self.version, active: active, mru: mru, layouts: layouts))
    }
}
