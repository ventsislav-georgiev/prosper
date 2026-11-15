import Foundation

// #917 S2b (spec 4.5 item 3, G1, ruling E-13): which pieces of a validated kit stay off. Pure: values in, values
// out; nothing is read, written or run. The saved off set is outside data: it can be stale or hand-edited.

enum KitSelectionResult: Equatable, Sendable {
    /// `off`: the asked pieces plus every piece that needs one of them, transitively; `unknown`: asked ids the kit
    /// does not have, ignored
    case closed(off: Set<String>, unknown: Set<String>)
    /// the local.md piece would go off while another claude-md piece stays on
    case refused(KitRefusal)
}

struct KitPieceSelection: Sendable {
    var kit: KitValidated

    init(_ kit: KitValidated) { self.kit = kit }

    func closure(off asked: Set<String>) -> KitSelectionResult {
        let pieces = kit.kit.pieces
        let ids = Set(pieces.map(\.id))
        var dependents: [String: [String]] = [:]
        for p in pieces { for n in p.needs { dependents[n, default: []].append(p.id) } }
        // iterative; each piece enters `off` once, so at most maxPieces pops of known ids
        var off: Set<String> = []
        var stack = Array(asked.intersection(ids))
        while let id = stack.popLast() {
            guard off.insert(id).inserted else { continue }
            stack += dependents[id] ?? []
        }
        if let local = kit.localPiece, off.contains(local),
           pieces.contains(where: { $0.kind == .claudeMD && !off.contains($0.id) }) {
            return .refused(KitRefusal(subject: local, reason: .localPieceStaysOn))
        }
        return .closed(off: off, unknown: asked.subtracting(ids))
    }
}
