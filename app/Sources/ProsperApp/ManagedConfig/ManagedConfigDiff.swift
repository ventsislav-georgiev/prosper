import Foundation

/// #870 (spec 2.6, errata C11): the added/removed lines the consent sheet shows. Each planner step
/// is one splice, so trimming the common prefix and suffix lines gives that step's exact hunk.
/// In settings.json, a line that touches any byte outside the managed keys (`env` above all) is
/// replaced by a fixed mask string. Plain value type, no isolation.
enum ManagedConfigDiff {
    static let allowedPermissionKeys: Set<String> = ["allow", "deny", "ask", "additionalDirectories"]

    static func lines(old: [UInt8], new: [UInt8], json: Bool) -> [ManagedConfigChangeSet.Line] {
        let a = Lines(old), b = Lines(new)
        func full(_ l: Lines, _ n: Int) -> ArraySlice<UInt8> { l.bytes[l.start(n)..<l.lineEnd(n)] }
        var p = 0
        while p < a.count, p < b.count, full(a, p) == full(b, p) { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, full(a, a.count - 1 - s) == full(b, b.count - 1 - s) { s += 1 }
        let maskOld = json ? Mask(old) : nil
        let maskNew = json ? Mask(new) : nil
        func line(_ l: Lines, _ n: Int, _ mask: Mask?, _ sign: ManagedConfigChangeSet.Line.Sign) -> ManagedConfigChangeSet.Line {
            let shown = mask.map { $0.showable(l.range(n)) } ?? true
            return .init(sign: sign, text: shown ? l.text(n) : ManagedConfigChangeSet.maskedLine)
        }
        return (p..<a.count - s).map { line(a, $0, maskOld, .removed) } + (p..<b.count - s).map { line(b, $0, maskNew, .added) }
    }

    struct Mask {
        let doc: OrderedJSON?

        init(_ bytes: [UInt8]) { doc = try? OrderedJSON(bytes: bytes) }

        func showable(_ range: Range<Int>) -> Bool {
            guard let doc else { return false }
            for i in range where !isSpace(doc.bytes[i]) {
                if !allowed(i, in: doc) { return false }
            }
            return true
        }

        private func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A }

        private func allowed(_ offset: Int, in doc: OrderedJSON) -> Bool {
            guard case .object(let members) = doc.root.value else { return false }
            guard let m = members.first(where: { $0.range.contains(offset) }) else { return true } // root punctuation
            switch m.key {
            case "hooks", "statusLine":
                return true
            case "permissions":
                guard case .object(let kids) = m.value.value else { return false }
                guard let k = kids.first(where: { $0.range.contains(offset) }) else { return true }
                return ManagedConfigDiff.allowedPermissionKeys.contains(k.key)
            default:
                return false
            }
        }
    }
}
