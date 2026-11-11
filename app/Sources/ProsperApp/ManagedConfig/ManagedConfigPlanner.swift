import Darwin
import Foundation

/// #870 (spec 2.3-2.5): the pure half of plan -> apply. Reads files, writes nothing. Works on a
/// copy of the state so later pieces see earlier pieces' claims (the `union` refcount).
/// Plain value type, no isolation.
struct ManagedConfigPlanner {
    struct Work {
        var url: URL
        var target: String
        var backupRel: String
        var kitDir: URL?
        var json: Bool
        var base: [UInt8]?
        var text: [UInt8]
        var existed: Bool
        var initial: String?
        var mode: mode_t
        var created: [[String]]
        var steps: [(old: [UInt8], new: [UInt8])] = []
        var upserts: [String: ManagedConfigRecord] = [:]
        var deletes: Set<String> = []
        var notes: [String] = []
        var deleteFile = false
        /// The path the records named before the target resolved here (a dotfiles symlink added or dropped).
        var movedFrom: String? = nil
    }

    let roots: ManagedConfigRoots
    let owner: ManagedConfigOwner
    let now: Date
    var state: ManagedConfigState
    var works: [String: Work] = [:]
    var order: [String] = []
    var refusals: [ManagedConfigRefusal] = []
    var actions: [ManagedConfigPieceAction] = []
    /// piece id -> the file its action belongs to, so a part-way failure reports only what landed.
    var pieceFiles: [String: String] = [:]

    static func key(_ owner: String, _ id: String) -> String { owner + "\u{1F}" + id }
    static func skeleton(_ nl: String) -> [UInt8] { Array(("{}" + nl).utf8) }

    // MARK: JSON allowlist (spec 2.3, operator ruling: no `env` writer in v1, errata A12)

    static let refusedTopKeys: Set<String> = ["env", "apiKeyHelper", "model", "disableAllHooks", "disableBypassPermissionsMode"]

    static func jsonRule(_ path: [String], _ op: ManagedConfigPiece.Op) -> ManagedConfigRefusalReason? {
        let name = path.joined(separator: ".")
        guard let first = path.first, !refusedTopKeys.contains(first), !(path.count >= 2 && path[0] == "permissions" && path[1] == "defaultMode") else {
            return .refusedJSONPath(name)
        }
        switch op {
        case .append:
            if path.count == 2, first == "hooks", let c = path[1].first, c.isUppercase, path[1].allSatisfy({ $0.isLetter }) { return nil }
        case .union:
            if path.count == 2, first == "permissions", ManagedConfigDiff.allowedPermissionKeys.contains(path[1]) { return nil }
        case .set:
            if path == ["statusLine"] { return nil }
        }
        return .refusedJSONPath(name)
    }

    // MARK: work files

    private mutating func work(_ url: URL, target: String, backupRel: String, kitDir: URL?, json: Bool) -> Work {
        if let w = works[url.path] { return w }
        let base = FileManager.default.contents(atPath: url.path).map { Array($0) }
        let record = state.files.first { $0.path == url.path }
        let blank = base.map { $0.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) } } ?? true
        var st = stat()
        let mode: mode_t = stat(url.path, &st) == 0 ? st.st_mode & 0o7777 : (json ? 0o600 : 0o644)
        var w = Work(url: url, target: target, backupRel: backupRel, kitDir: kitDir, json: json, base: base, text: base ?? [],
                     existed: record?.existed ?? (base != nil), initial: record?.initial, mode: mode, created: record?.created ?? [])
        if json, blank {
            if record == nil, let base { w.initial = String(decoding: base, as: UTF8.self) }
            w.text = ManagedConfigPlanner.skeleton(OrderedJSON.newline(of: base ?? []))
        }
        if !order.contains(url.path) { order.append(url.path) }
        return w
    }

    private func step(_ w: inout Work, _ new: [UInt8]) {
        guard new != w.text else { return }
        w.steps.append((w.text, new))
        w.text = new
    }

    private mutating func upsert(_ w: inout Work, _ r: ManagedConfigRecord) {
        let k = ManagedConfigPlanner.key(r.owner, r.piece.id)
        state.records.removeAll { ManagedConfigPlanner.key($0.owner, $0.piece.id) == k }
        state.records.append(r)
        w.upserts[k] = r
        w.deletes.remove(k)
    }

    private mutating func drop(_ w: inout Work, _ r: ManagedConfigRecord) {
        let k = ManagedConfigPlanner.key(r.owner, r.piece.id)
        state.records.removeAll { ManagedConfigPlanner.key($0.owner, $0.piece.id) == k }
        w.upserts[k] = nil
        w.deletes.insert(k)
    }

    /// The record's target now resolves to another file than the one it was written to: a user
    /// file moved into a dotfiles repo and symlinked back, or a link replaced by a regular file.
    /// Every record and the file record of the old path follow the target, so Remove and Repair
    /// act on the live file (and write through a link, never over it). Returns the old path.
    private mutating func relocate(from old: String, to url: URL) -> String? {
        guard old != url.path else { return nil }
        for i in state.records.indices where state.records[i].path == old { state.records[i].path = url.path }
        if state.files.contains(where: { $0.path == url.path }) {
            state.files.removeAll { $0.path == old }
        } else {
            for i in state.files.indices where state.files[i].path == old { state.files[i].path = url.path }
        }
        return old
    }

    private func record(_ id: String) -> ManagedConfigRecord? {
        state.records.first { $0.owner == owner.id && $0.piece.id == id }
    }

    private func newRecord(_ piece: ManagedConfigPiece, _ w: Work, written: String, hash: String) -> ManagedConfigRecord {
        ManagedConfigRecord(owner: owner.id, piece: piece, target: w.target, path: w.url.path, written: written, hash: hash,
                            version: owner.version, appliedAt: now, sourceDir: owner.extensionDir?.path)
    }

    // MARK: apply / repair

    mutating func apply(_ piece: ManagedConfigPiece, repair: Bool) {
        do throws(ManagedConfigRefusalReason) {
            guard ManagedConfigPaths.isValidID(piece.id) else { throw ManagedConfigRefusalReason.invalidPiece("id must be [A-Za-z0-9._-]") }
            let resolved = try ManagedConfigPaths.resolve(piece.target, kind: piece.kind, owner: owner, roots: roots).get()
            var movedFrom: String?
            if let r = record(piece.id) { movedFrom = relocate(from: r.path, to: resolved.url) }
            let existing = record(piece.id)
            var w = work(resolved.url, target: resolved.display, backupRel: resolved.backupRel, kitDir: resolved.kitDir, json: piece.kind == .json)
            if let movedFrom { w.movedFrom = movedFrom }
            let action: ManagedConfigPieceAction.Kind
            switch piece.kind {
            case .block: action = try applyBlock(piece, existing, repair, &w)
            case .json: action = try applyJSON(piece, existing, repair, &w)
            case .seed: action = try applySeed(piece, existing, repair, &w)
            }
            works[w.url.path] = w
            pieceFiles[piece.id] = w.url.path
            actions.append(.init(id: piece.id, action: action))
        } catch {
            refusals.append(.init(pieceID: piece.id, target: piece.target, reason: error))
        }
    }

    private mutating func applyBlock(_ piece: ManagedConfigPiece, _ existing: ManagedConfigRecord?, _ repair: Bool, _ w: inout Work) throws(ManagedConfigRefusalReason) -> ManagedConfigPieceAction.Kind {
        guard let body = piece.text, ManagedTextBlock.bodyIsValid(body) else { throw .invalidPiece("a block needs text without prosper markers") }
        let block = ManagedTextBlock.render(owner: owner.id, piece: piece.id, version: owner.version, body: body,
                                            syntax: ManagedTextBlock.syntax(for: w.url))
        let record = newRecord(piece, w, written: block, hash: OrderedJSON.sha256(Array(block.utf8)))
        switch ManagedTextBlock.find(owner: owner.id, piece: piece.id, in: w.text) {
        case .corrupt(let lines):
            throw .corrupt("broken prosper markers at line(s) \(lines.map(String.init).joined(separator: ", "))")
        case .present(let b, let e):
            let onDisk = ManagedTextBlock.text(of: w.text, begin: b, end: e)
            if onDisk == block {
                if existing == nil { upsert(&w, record); return .adopt }
                return .noop
            }
            if let existing, existing.written != onDisk, !repair { throw .drifted }
            step(&w, ManagedTextBlock.replacing(begin: b, end: e, with: block, in: w.text))
            upsert(&w, record)
            notes(&w)
            return .update
        case .absent:
            if existing != nil, !repair { throw .missing }
            step(&w, ManagedTextBlock.inserting(block, position: piece.position, into: w.text))
            upsert(&w, record)
            notes(&w)
            return existing == nil ? .insert : .update
        }
    }

    private mutating func applySeed(_ piece: ManagedConfigPiece, _ existing: ManagedConfigRecord?, _ repair: Bool, _ w: inout Work) throws(ManagedConfigRefusalReason) -> ManagedConfigPieceAction.Kind {
        let content: String
        if let text = piece.text { content = text } else {
            switch ManagedConfigPaths.readSource(piece.source ?? "", owner: owner) {
            case .failure(let r): throw r
            case .success(let s): content = s
            }
        }
        // Create-if-missing, never overwrite: a file already there is the user's, and is not recorded.
        if w.base != nil { return .noop }
        if existing != nil, !repair { throw .missing }
        step(&w, Array(content.utf8))
        upsert(&w, newRecord(piece, w, written: content, hash: OrderedJSON.sha256(Array(content.utf8))))
        return existing == nil ? .insert : .update
    }

    /// Lost state (spec 2.5 step 4 for JSON, which has no markers): with no record, an `append`
    /// element or a `set` slot deep-equal to the piece's value is ADOPTED: recorded, nothing written.
    /// This covers a crash between the rename and the state save, a wiped Application Support while
    /// ~/.claude came back from dotfiles, and a hand-deleted state.json. Known cost: a user who typed
    /// the byte-identical value by hand loses it on Remove.
    private mutating func applyJSON(_ piece: ManagedConfigPiece, _ existing: ManagedConfigRecord?, _ repair: Bool, _ w: inout Work) throws(ManagedConfigRefusalReason) -> ManagedConfigPieceAction.Kind {
        guard let path = piece.path, let op = piece.op, let valueText = piece.value else {
            throw .invalidPiece("a json piece needs path, op and value")
        }
        if let r = ManagedConfigPlanner.jsonRule(path, op) { throw r }
        guard let value = try? OrderedJSON(valueText).root.value else { throw .invalidPiece("value is not JSON") }
        let doc: OrderedJSON
        do { doc = try OrderedJSON(bytes: w.text) } catch { throw .corrupt("\(w.target) does not parse: \(error)") }
        let name = path.joined(separator: ".")
        let hash = OrderedJSON.hash(value)
        let node = doc.node(at: path)
        switch op {
        case .append:
            guard case .object = value else { throw .invalidPiece("a hooks entry is an object") }
            var elements: [OrderedJSON.Node] = []
            if let node {
                guard case .array(let els) = node.value else { throw .corrupt("\(name) is not an array") }
                elements = els
            }
            let old = existing.flatMap { r in elements.lastIndex { OrderedJSON.hash($0.value) == r.hash } }
            // deep-equal elements other records already hold are theirs, not adoptable
            let held = state.records.filter { $0.path == w.url.path && $0.piece.path == path && $0.piece.op == .append && $0.hash == hash }.count
            if let existing {
                if old != nil, existing.hash == hash { return .noop }
                if old == nil, !repair { throw .missing }
            } else if elements.filter({ OrderedJSON.hash($0.value) == hash }).count > held {
                adoptContainers(path, sole: elements.allSatisfy { OrderedJSON.hash($0.value) == hash }, doc, &w)
                upsert(&w, newRecord(piece, w, written: OrderedJSON.canonical(value), hash: hash))
                return .adopt
            }
            var current = doc
            if let old {
                step(&w, doc.removingElement(old, fromArrayAt: path))
                current = (try? OrderedJSON(bytes: w.text)) ?? doc
            }
            if current.node(at: path) != nil {
                step(&w, current.appendingElement(value, toArrayAt: path))
            } else {
                try insert(.array([.init(value: value, range: 0..<0)]), at: path, leafIsContainer: true, &w)
            }
            upsert(&w, newRecord(piece, w, written: OrderedJSON.canonical(value), hash: hash))
            hookNotes(&w, event: path[1], value)
            return existing == nil ? .insert : .update

        case .union:
            var strings: [String] = []
            switch value {
            case .string(let s): strings = [s]
            case .array(let els):
                for e in els {
                    guard case .string(let s) = e.value else { throw .invalidPiece("union values are strings") }
                    if !strings.contains(s) { strings.append(s) }
                }
            default: throw .invalidPiece("union values are strings")
            }
            var present: [String] = []
            if let node {
                guard case .array(let els) = node.value else { throw .corrupt("\(name) is not an array") }
                present = els.compactMap { if case .string(let s) = $0.value { return s } else { return nil } }
            }
            // union adopts nothing, lost state included: a string already present is the user's and is
            // never claimed, so Remove leaves it.
            let others = claims(on: w.url.path, path: path, except: existing)
            if let existing, !repair, existing.claimed.contains(where: { !present.contains($0) }) { throw .missing }
            let toAdd = strings.filter { !present.contains($0) }
            let toDrop = (existing?.claimed ?? []).filter { !strings.contains($0) && !others.contains($0) && present.contains($0) }
            let claimed = strings.filter { toAdd.contains($0) || others.contains($0) || (existing?.claimed.contains($0) ?? false) }
            for s in toDrop { removeLastString(s, at: path, &w) }
            if !toAdd.isEmpty {
                if let doc = try? OrderedJSON(bytes: w.text), doc.node(at: path) != nil {
                    for s in toAdd { step(&w, ((try? OrderedJSON(bytes: w.text)) ?? doc).appendingElement(.string(s), toArrayAt: path)) }
                } else {
                    try insert(.array(toAdd.map { .init(value: .string($0), range: 0..<0) }), at: path, leafIsContainer: true, &w)
                }
            }
            let record = newRecord(piece, w, written: OrderedJSON.canonical(value), hash: hash)
            var withClaims = record
            withClaims.claimed = claimed
            if toAdd.isEmpty, toDrop.isEmpty {
                if existing?.claimed != claimed || existing?.hash != hash { upsert(&w, withClaims) }
                return .noop
            }
            upsert(&w, withClaims)
            return existing == nil ? .insert : .update

        case .set:
            if let other = state.records.first(where: { $0.path == w.url.path && $0.piece.path == path && $0.piece.op == .set && $0.owner != owner.id }) {
                throw .conflict(owner: other.owner)
            }
            let currentIsOurs = existing.map { r in node.map { OrderedJSON.hash($0.value) == r.hash } ?? false } ?? false
            var record = newRecord(piece, w, written: OrderedJSON.canonical(value), hash: hash)
            if existing == nil, let node, OrderedJSON.hash(node.value) == hash {
                upsert(&w, record) // adopted: hadPrevious stays false, so Remove deletes the member
                return .adopt
            }
            if let existing {
                if currentIsOurs, existing.hash == hash { return .noop }
                if !currentIsOurs, !repair { throw node == nil ? .missing : .replaced }
                record.hadPrevious = existing.hadPrevious
                record.previous = existing.previous
            } else {
                record.hadPrevious = node != nil
                record.previous = node.map { doc.raw($0) }
            }
            if let node {
                if OrderedJSON.hash(node.value) != hash { step(&w, doc.replacingValue(at: path, with: value)) }
            } else {
                try insert(value, at: path, leafIsContainer: false, &w)
            }
            upsert(&w, record)
            statusLineNote(&w, value)
            return existing == nil ? .insert : .update
        }
    }

    /// Creates `path` (and any missing parent objects) holding `leaf`. Records every container it
    /// made, so a removal drops them only when Prosper made them and they are empty again.
    private func insert(_ leaf: OrderedJSON.Value, at path: [String], leafIsContainer: Bool, _ w: inout Work) throws(ManagedConfigRefusalReason) {
        guard let doc = try? OrderedJSON(bytes: w.text) else { throw .corrupt("\(w.target) does not parse") }
        var depth = 0
        while depth < path.count - 1, let n = doc.node(at: Array(path[...depth])) {
            guard case .object = n.value else { throw .corrupt("\(path[...depth].joined(separator: ".")) is not an object") }
            depth += 1
        }
        guard case .object = doc.node(at: Array(path[..<depth]))?.value else { throw .corrupt("\(w.target) is not a JSON object") }
        var value = leaf
        for key in path[(depth + 1)...].reversed() {
            value = .object([.init(key: key, start: 0, value: .init(value: value, range: 0..<0))])
        }
        step(&w, doc.insertingMember(path[depth], value: value, intoObjectAt: Array(path[..<depth])))
        let lastContainer = leafIsContainer ? path.count : path.count - 1
        if depth < lastContainer {
            for k in (depth + 1)...lastContainer where !w.created.contains(Array(path[..<k])) { w.created.append(Array(path[..<k])) }
        }
    }

    /// Adoption after lost state: a container holding nothing but copies of the adopted element is treated as
    /// Prosper's (a fresh apply would have made it), and so is a parent whose members all are.
    private func adoptContainers(_ path: [String], sole: Bool, _ doc: OrderedJSON, _ w: inout Work) {
        guard sole else { return }
        var c = path
        while !c.isEmpty {
            if !w.created.contains(c) { w.created.append(c) }
            c.removeLast()
            guard !c.isEmpty, case .object(let m)? = doc.node(at: c)?.value, m.allSatisfy({ w.created.contains(c + [$0.key]) }) else { return }
        }
    }

    private func claims(on file: String, path: [String], except: ManagedConfigRecord?) -> Set<String> {
        Set(state.records.filter { $0.path == file && $0.piece.path == path && $0.piece.op == .union && $0 != except }.flatMap(\.claimed))
    }

    private func removeLastString(_ s: String, at path: [String], _ w: inout Work) {
        guard let doc = try? OrderedJSON(bytes: w.text), case .array(let els)? = doc.node(at: path)?.value,
              let i = els.lastIndex(where: { if case .string(let x) = $0.value { return x == s } else { return false } }) else { return }
        step(&w, doc.removingElement(i, fromArrayAt: path))
    }

    /// Drops containers Prosper created that are empty again, deepest first.
    private func prune(_ w: inout Work) {
        for c in w.created.sorted(by: { $0.count > $1.count }) {
            guard let doc = try? OrderedJSON(bytes: w.text) else { return }
            guard let n = doc.node(at: c) else { w.created.removeAll { $0 == c }; continue }
            let empty: Bool
            switch n.value {
            case .object(let m): empty = m.isEmpty
            case .array(let a): empty = a.isEmpty
            default: empty = false
            }
            if empty {
                step(&w, doc.removingMember(at: c))
                w.created.removeAll { $0 == c }
            }
        }
    }

    // MARK: remove

    mutating func remove(_ r: ManagedConfigRecord) {
        func refuse(_ reason: ManagedConfigRefusalReason) { refusals.append(.init(pieceID: r.piece.id, target: r.target, reason: reason)) }
        // The file the target resolves to now, by the same checks as apply; never the recorded path blindly.
        let resolved: ManagedConfigResolvedTarget
        switch ManagedConfigPaths.resolve(r.target, kind: r.piece.kind, owner: owner, roots: roots) {
        case .failure(let reason): return refuse(reason)
        case .success(let t): resolved = t
        }
        let url = resolved.url // live target
        let movedFrom = relocate(from: r.path, to: url)
        var dir = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" { dir = dir.deletingLastPathComponent() }
        if access(dir.path, W_OK) != 0 || (FileManager.default.fileExists(atPath: url.path) && access(url.path, W_OK) != 0) {
            return refuse(.unwritable("read-only file or directory"))
        }
        var w = work(url, target: r.target, backupRel: resolved.backupRel, kitDir: nil, json: r.piece.kind == .json)
        if let movedFrom { w.movedFrom = movedFrom }
        var action: ManagedConfigPieceAction.Kind = .forget
        switch r.piece.kind {
        case .block:
            switch ManagedTextBlock.find(owner: r.owner, piece: r.piece.id, in: w.text) {
            case .corrupt(let lines):
                return refuse(.corrupt("broken prosper markers at line(s) \(lines.map(String.init).joined(separator: ", "))"))
            case .present(let b, let e):
                step(&w, ManagedTextBlock.removing(begin: b, end: e, from: w.text))
                action = .remove
            case .absent:
                break
            }
        case .seed:
            if let base = w.base {
                if base == Array(r.written.utf8) { step(&w, []); action = .remove } else { action = .keep }
            }
        case .json:
            guard let doc = try? OrderedJSON(bytes: w.text) else { return refuse(.corrupt("\(r.target) does not parse")) }
            let path = r.piece.path ?? []
            switch r.piece.op {
            case .append?:
                if case .array(let els)? = doc.node(at: path)?.value,
                   let i = els.lastIndex(where: { OrderedJSON.hash($0.value) == r.hash }) {
                    step(&w, doc.removingElement(i, fromArrayAt: path))
                    action = .remove
                }
            case .union?:
                let others = claims(on: w.url.path, path: path, except: state.records.first { $0.owner == r.owner && $0.piece.id == r.piece.id })
                let before = w.text
                for s in r.claimed where !others.contains(s) { removeLastString(s, at: path, &w) }
                if w.text != before { action = .remove }
            case .set?:
                if let n = doc.node(at: path) {
                    if OrderedJSON.hash(n.value) == r.hash {
                        step(&w, r.hadPrevious ? doc.replacingValue(at: path, withRaw: r.previous ?? "null") : doc.removingMember(at: path))
                        action = .remove
                    } else {
                        action = .keep // replaced by hand: left as it is
                    }
                }
            case nil:
                break
            }
            prune(&w)
        }
        drop(&w, r)
        works[w.url.path] = w
        pieceFiles[r.piece.id] = w.url.path
        actions.append(.init(id: r.piece.id, action: action))
    }

    // MARK: finish

    /// When the last piece leaves a file, a file Prosper created goes away and a whitespace-only
    /// original comes back, so the result is byte-identical to the pre-apply file.
    mutating func finish() {
        for path in order {
            guard var w = works[path], !state.records.contains(where: { $0.path == path }) else { continue }
            let skeleton = ManagedConfigPlanner.skeleton(OrderedJSON.newline(of: w.text))
            let empty = w.json ? w.text == skeleton : w.text.isEmpty
            if empty, !w.existed { w.deleteFile = true }
            if w.json, empty, let initial = w.initial { w.text = Array(initial.utf8) }
            works[path] = w
        }
    }

    // MARK: consent notes

    private func notes(_ w: inout Work) {
        guard w.target.hasPrefix("claude:") else { return }
        let note = "Read by new Claude Code sessions and after /compact."
        if !w.notes.contains(note) { w.notes.append(note) }
    }

    private func liveNote(_ w: inout Work) {
        let note = "Applies to open Claude Code sessions immediately."
        if !w.notes.contains(note) { w.notes.append(note) }
    }

    private func string(_ v: OrderedJSON.Value?, _ key: String) -> String? {
        guard case .object(let m)? = v, let n = m.first(where: { $0.key == key }), case .string(let s) = n.value.value else { return nil }
        return s
    }

    private func hookNotes(_ w: inout Work, event: String, _ group: OrderedJSON.Value) {
        liveNote(&w)
        let matcher = string(group, "matcher").map { "`\($0)`" } ?? "every match"
        guard case .object(let m) = group, let hooks = m.first(where: { $0.key == "hooks" }), case .array(let list) = hooks.value.value else { return }
        for h in list {
            if let command = string(h.value, "command") {
                w.notes.append("Claude Code will run `\(command)` on `\(event)` (\(matcher)) in every session.")
            }
        }
    }

    private func statusLineNote(_ w: inout Work, _ value: OrderedJSON.Value) {
        liveNote(&w)
        if let command = string(value, "command") { w.notes.append("Claude Code will run `\(command)` as the status line in every session.") }
    }
}
