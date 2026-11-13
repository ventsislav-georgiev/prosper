import Foundation

/// #870 (spec 2.6, errata C11): the added/removed lines the consent sheet shows. Each planner step
/// is one splice, so trimming the common prefix and suffix lines gives that step's exact hunk.
/// In settings.json, a line that touches any byte outside the managed keys (`env` above all) is
/// replaced by a fixed mask string. Plain value type, no isolation.
enum ManagedConfigDiff {
    static let allowedPermissionKeys: Set<String> = ["allow", "deny", "ask", "additionalDirectories"]

    /// QA #724 INFO-11/12/13: the sheet shows the lines Prosper adds or removes, plus at most
    /// `contextLines` unchanged lines each side. A user line whose only change is a trailing comma
    /// or its line ending is context, not a change. In settings.json a context line that carries a
    /// value (a user's hook group, say) is elided, and `hide` replaces one side wholesale: the user's
    /// own value that a `set` replaces, or that a removal brings back.
    static let contextLines = 2

    static func lines(old: [UInt8], new: [UInt8], json: Bool, hide: ManagedConfigChangeSet.Line.Sign? = nil) -> [ManagedConfigChangeSet.Line] {
        typealias Line = ManagedConfigChangeSet.Line
        let a = Lines(old), b = Lines(new)
        func full(_ l: Lines, _ n: Int) -> ArraySlice<UInt8> { l.bytes[l.start(n)..<l.lineEnd(n)] }
        var p = 0
        while p < a.count, p < b.count, full(a, p) == full(b, p) { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, full(a, a.count - 1 - s) == full(b, b.count - 1 - s) { s += 1 }
        let maskOld = json ? Mask(old) : nil
        let maskNew = json ? Mask(new) : nil
        func line(_ l: Lines, _ n: Int, _ mask: Mask?, _ sign: Line.Sign) -> Line {
            let shown = mask.map { $0.showable(l.range(n)) } ?? true
            var text = shown ? l.text(n) : ManagedConfigChangeSet.maskedLine
            if shown, json, sign == .context, !structural(text) { text = ManagedConfigChangeSet.elidedLine }
            return .init(sign: sign, text: text, noFinalNewline: n == l.count - 1 && l.terminatorLength(n) == 0)
        }
        var removed = Array(p..<a.count - s), added = Array(p..<b.count - s)
        var lead: [Line] = [], trail: [Line] = []
        if let r = removed.first, let n = added.first, punctuationOnly(a.text(r), b.text(n)) {
            lead = [line(b, n, maskNew, .context)]
            removed.removeFirst(); added.removeFirst()
        }
        if let r = removed.last, let n = added.last, punctuationOnly(a.text(r), b.text(n)) {
            trail = [line(b, n, maskNew, .context)]
            removed.removeLast(); added.removeLast()
        }
        // One JSON line changed in place (a compact array gaining or losing our element): show only the
        // changed span, so the user's own element on that line is never printed.
        var inline: [Line] = []
        if json, hide == nil, removed.count == 1, added.count == 1, let r = removed.first, let n = added.first,
           maskOld?.showable(a.range(r)) == true, maskNew?.showable(b.range(n)) == true {
            let o = Array(a.text(r)), m = Array(b.text(n))
            var pre = 0
            while pre < o.count, pre < m.count, o[pre] == m[pre] { pre += 1 }
            var suf = 0
            while suf < o.count - pre, suf < m.count - pre, o[o.count - 1 - suf] == m[m.count - 1 - suf] { suf += 1 }
            func span(_ c: [Character]) -> String { (pre > 0 ? "…" : "") + String(c[pre..<(c.count - suf)]) + (suf > 0 ? "…" : "") }
            if pre + suf < o.count { inline.append(.init(sign: .removed, text: span(o))) }
            if pre + suf < m.count { inline.append(.init(sign: .added, text: span(m))) }
            removed = []; added = []
        }
        let before = max(0, p - contextLines)..<p
        let after = (b.count - s)..<min(b.count, b.count - s + contextLines)
        var out = before.map { line(b, $0, maskNew, .context) } + lead
        out += hide == .removed && !removed.isEmpty ? [Line(sign: .removed, text: ManagedConfigChangeSet.userValueLine)]
            : removed.map { line(a, $0, maskOld, .removed) }
        out += hide == .added && !added.isEmpty ? [Line(sign: .added, text: ManagedConfigChangeSet.userValueLine)]
            : added.map { line(b, $0, maskNew, .added) }
        return out + inline + trail + after.map { line(b, $0, maskNew, .context) }
    }

    /// Same content but for one trailing comma: the user's line next to an inserted or removed sibling.
    static func punctuationOnly(_ x: String, _ y: String) -> Bool {
        func core(_ s: String) -> Substring {
            var t = Substring(s)
            while t.last == " " || t.last == "\t" { t.removeLast() }
            if t.last == "," { t.removeLast() }
            return t
        }
        // A-INFO-3: bytes; String == would show an NFC/NFD change as an unchanged line
        return x.utf8.elementsEqual(y.utf8) || core(x).utf8.elementsEqual(core(y).utf8)
    }

    /// A JSON line with no value on it: a key opening a container, or brackets and commas.
    static func structural(_ text: String) -> Bool {
        text.range(of: #"^\s*("[^"\\]*"\s*:\s*)?[\[\]\{\},\s]*$"#, options: .regularExpression) != nil
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
