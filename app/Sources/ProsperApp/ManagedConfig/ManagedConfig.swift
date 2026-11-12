import Darwin
import Foundation

/// #870 (spec 2.5): a computed change set. `plan` is pure; `ManagedConfig.apply(_:)` asks consent
/// and writes it. Plain value type, no isolation.
struct ManagedConfigPlan: Sendable {
    enum Operation: Sendable, Equatable {
        case apply([ManagedConfigPiece])
        case remove([String]?)
        case repair([String]?)
    }

    struct FileChange: Sendable {
        var url: URL
        var target: String
        var backupRel: String
        var kitDir: URL?
        var base: [UInt8]?
        var baseHash: String
        var newBytes: [UInt8]? // nil: no write
        var delete: Bool
        var mode: mode_t
        var upserts: [ManagedConfigRecord]
        var deletes: Set<String>
        var fileRecord: ManagedConfigFileRecord? // after this change; nil drops it
        var kind: ManagedConfigPiece.Kind // to re-resolve the target after consent (A-INFO-6)
        var movedFrom: String? // the records' old path: the target resolves here now
        var pieces: Set<String> // ids whose action belongs to this file
        var writes: Bool { delete || newBytes != nil }
    }

    let owner: ManagedConfigOwner
    let operation: Operation
    let changes: ManagedConfigChangeSet
    let refusals: [ManagedConfigRefusal]
    let files: [FileChange]
    let stateHash: String

    var actions: [ManagedConfigPieceAction] { changes.pieces }
    var writesUserFiles: Bool { files.contains { $0.writes } }
}

/// #870: the managed-config primitive. Writes only what it can later find and remove exactly,
/// never without consent. Each file is replaced atomically and state.json matches disk after every
/// file. A change set spanning files can stop part-way (a failed write, or a concurrent write past
/// the replans): the result then lists only the pieces whose file landed, and a later apply
/// completes the rest.
///
/// Isolation: a `Sendable` final class with only immutable stored properties and no actor
/// isolation. `plan`/`status` are synchronous and may run on any thread; `apply`/`remove`/`repair`
/// are nonisolated async and suspend only inside `consent.confirm`. File writes run synchronously
/// under one process-wide lock (spec 2.5 "one serial queue for all managed writes").
/// Callers (P2): the Lua `host.config` bridge, the uninstall hook, the status refresh (ManagedConfigHost/).
final class ManagedConfig: Sendable {
    let roots: ManagedConfigRoots
    let consent: any ManagedConfigConsent
    let writer: any ManagedConfigFileWriter
    let now: @Sendable () -> Date

    /// errata C9: re-plan at most 3 times on a concurrent write, then "file changed, retry".
    static let maxReplans = 3
    /// errata C10: the first-write backup plus the last 5 pre-write copies per file.
    static let preWriteBackupsKept = 5
    /// errata C10: backups and state are 0600 files in 0700 dirs (a settings.json backup can hold `env` secrets).
    static let privateFileMode: mode_t = 0o600
    static let privateDirMode: mode_t = 0o700
    private static let writeLock = NSLock()

    init(roots: ManagedConfigRoots, consent: any ManagedConfigConsent,
         writer: any ManagedConfigFileWriter = ManagedConfigPOSIXWriter(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.roots = roots
        self.consent = consent
        self.writer = writer
        self.now = now
    }

    var stateURL: URL { roots.stateDir.appendingPathComponent("state.json") }
    /// D4: the dir #872's "Reveal backups" button opens on a user click. Never logged, never shown
    /// in a message or uploaded with diagnostics (errata C10).
    var backupsDir: URL { roots.stateDir.appendingPathComponent("backups", isDirectory: true) }
    /// errata E5 / D6: a crash between the temp write and the rename leaves this beside the target.
    static let staleTempAge: TimeInterval = 60

    // MARK: public surface

    func plan(_ pieces: [ManagedConfigPiece], owner: ManagedConfigOwner) -> ManagedConfigPlan { prepare(.apply(pieces), owner: owner) }
    func planRemove(owner: ManagedConfigOwner, ids: [String]? = nil) -> ManagedConfigPlan { prepare(.remove(ids), owner: owner) }
    func planRepair(owner: ManagedConfigOwner, ids: [String]? = nil) -> ManagedConfigPlan { prepare(.repair(ids), owner: owner) }

    func apply(_ pieces: [ManagedConfigPiece], owner: ManagedConfigOwner) async -> ManagedConfigResult { await apply(plan(pieces, owner: owner)) }
    /// `ids == nil` removes every piece of `owner`.
    func remove(owner: ManagedConfigOwner, ids: [String]? = nil) async -> ManagedConfigResult { await apply(planRemove(owner: owner, ids: ids)) }
    func repair(owner: ManagedConfigOwner, ids: [String]? = nil) async -> ManagedConfigResult { await apply(planRepair(owner: owner, ids: ids)) }

    /// Executes a plan: consent, then write with the concurrent-write checks (errata C9).
    func apply(_ initial: ManagedConfigPlan) async -> ManagedConfigResult {
        var plan = initial
        var consented: ManagedConfigChangeSet?
        var replans = 0
        var landed: [ManagedConfigPieceAction] = [] // committed in an earlier round of this call
        func merged(_ actions: [ManagedConfigPieceAction]) -> [ManagedConfigPieceAction] {
            landed + actions.filter { a in !landed.contains { $0.id == a.id } }
        }
        while true {
            if !plan.refusals.isEmpty {
                return .init(status: .refused, pieces: landed, refusals: plan.refusals, message: plan.refusals.map(\.description).joined(separator: "; "))
            }
            if plan.files.isEmpty { return .init(status: landed.isEmpty ? .nothingToDo : .done, pieces: merged(plan.actions)) }
            if plan.writesUserFiles, plan.changes != consented {
                guard await consent.confirm(plan.changes) else {
                    return .init(status: .denied, pieces: landed.isEmpty ? plan.actions : landed,
                                 message: landed.isEmpty ? "cancelled: nothing was written" : "cancelled: the rest was not written")
                }
                consented = plan.changes
            }
            switch commit(plan) {
            case .done:
                return .init(status: .done, pieces: merged(plan.actions))
            case .failed(let why, let ids):
                return .init(status: .failed, pieces: merged(plan.actions.filter { ids.contains($0.id) }), message: why)
            case .changed(let ids):
                landed = merged(plan.actions.filter { ids.contains($0.id) })
                replans += 1
                guard replans <= ManagedConfig.maxReplans else { return .init(status: .fileChanged, pieces: landed, message: "file changed, retry") }
                plan = prepare(plan.operation, owner: plan.owner)
            }
        }
    }

    // MARK: plan

    func prepare(_ operation: ManagedConfigPlan.Operation, owner: ManagedConfigOwner) -> ManagedConfigPlan {
        let stateBytes = read(stateURL)
        let action: ManagedConfigChangeSet.Action
        switch operation {
        case .apply: action = .apply
        case .remove: action = .remove
        case .repair: action = .repair
        }
        func refused(_ reason: ManagedConfigRefusalReason) -> ManagedConfigPlan {
            ManagedConfigPlan(owner: owner, operation: operation, changes: .init(action: action, owner: owner.id, files: [], pieces: []),
                              refusals: [.init(pieceID: "*", target: "*", reason: reason)], files: [], stateHash: hash(stateBytes))
        }
        guard ManagedConfigPaths.isValidID(owner.id) else { return refused(.invalidPiece("owner id must be [A-Za-z0-9._-]")) }
        var state = ManagedConfigState()
        if let stateBytes {
            guard let decoded = Self.decodeState(stateBytes) else { return refused(.stateUnreadable) }
            state = decoded
        }
        var planner = ManagedConfigPlanner(roots: roots, owner: owner, now: now(), state: state)
        switch operation {
        case .apply(let pieces):
            let ids = pieces.map(\.id)
            if Set(ids).count != ids.count { return refused(.invalidPiece("two pieces share an id")) }
            for p in pieces { planner.apply(p, repair: false) }
        case .remove(let ids), .repair(let ids):
            let mine = state.records.filter { $0.owner == owner.id }
            for id in ids ?? [] where !mine.contains(where: { $0.piece.id == id }) {
                planner.refusals.append(.init(pieceID: id, target: "*", reason: .unknownPiece))
            }
            for r in mine where ids?.contains(r.piece.id) ?? true {
                if case .remove = operation { planner.remove(r) } else { planner.apply(r.piece, repair: true) }
            }
        }
        planner.finish()
        // A-INFO-5: on a case-insensitive volume two case variants are one file, written twice.
        var seen: [String: String] = [:]
        for path in planner.order {
            if let first = seen[path.lowercased()], first != path {
                planner.refusals.append(.init(pieceID: "*", target: planner.works[path]?.target ?? "*",
                                              reason: .badPath("\(planner.works[first]?.target ?? first) and \(planner.works[path]?.target ?? path) differ only by case")))
            }
            seen[path.lowercased()] = seen[path.lowercased()] ?? path
        }

        var changes: [ManagedConfigPlan.FileChange] = []
        var files: [ManagedConfigChangeSet.File] = []
        for path in planner.order {
            guard let w = planner.works[path] else { continue }
            let remaining = planner.state.records.contains { $0.path == path }
            let changed = w.text != (w.base ?? [])
            let delete = w.deleteFile && w.base != nil
            let newBytes = !w.deleteFile && changed && !w.steps.isEmpty ? w.text : nil
            let old = state.files.first { $0.path == (w.movedFrom ?? path) }
            var record: ManagedConfigFileRecord?
            if remaining {
                record = old ?? .init(path: path, target: w.target, existed: w.existed, initial: w.initial)
                record?.path = path // a moved record's file entry follows it
                record?.created = w.created
            }
            guard delete || newBytes != nil || !w.upserts.isEmpty || !w.deletes.isEmpty || record != old || w.movedFrom != nil else { continue }
            changes.append(.init(url: w.url, target: w.target, backupRel: w.backupRel, kitDir: w.kitDir, base: w.base, baseHash: hash(w.base),
                                 newBytes: newBytes, delete: delete, mode: w.mode, upserts: Array(w.upserts.values),
                                 deletes: w.deletes, fileRecord: record, kind: w.kind, movedFrom: w.movedFrom,
                                 pieces: Set(planner.pieceFiles.filter { $0.value == path }.keys)))
            if delete || newBytes != nil {
                // QA #724 INFO-13: the first step starts from the file as it is (absent: nothing, never the
                // `{}` skeleton) and the last ends at what is written (a restored original, or nothing).
                // A file that appears or goes is one whole-file hunk; otherwise one hunk per splice.
                let last = w.steps.count - 1
                let lines = delete || w.base == nil
                    ? ManagedConfigDiff.lines(old: w.base ?? [], new: delete ? [] : w.text, json: w.json)
                    : w.steps.enumerated().flatMap { i, s in
                        ManagedConfigDiff.lines(old: i == 0 ? (w.base ?? []) : s.old, new: i == last ? w.text : s.new,
                                                json: w.json, hide: w.hidden[i])
                    }
                files.append(.init(target: w.target, path: path,
                                   backupDirectory: backupsDir.appendingPathComponent(w.backupRel).deletingLastPathComponent().path,
                                   lines: lines, notes: w.notes, newFile: w.base == nil, deletesFile: delete))
            }
        }
        return ManagedConfigPlan(owner: owner, operation: operation,
                                 changes: .init(action: action, owner: owner.id, files: files, pieces: planner.actions),
                                 refusals: planner.refusals, files: changes, stateHash: hash(stateBytes))
    }

    // MARK: commit

    /// `committed`: the ids whose file change landed (and is in state) before the stop.
    enum CommitOutcome: Equatable { case done, changed(committed: Set<String>), failed(String, committed: Set<String>) }

    private func commit(_ plan: ManagedConfigPlan) -> CommitOutcome {
        ManagedConfig.writeLock.lock()
        defer { ManagedConfig.writeLock.unlock() }
        let stateBytes = read(stateURL)
        guard hash(stateBytes) == plan.stateHash else { return .changed(committed: []) }
        var state = stateBytes.flatMap(Self.decodeState) ?? ManagedConfigState()
        // Spec 2.5 step 1: every target still matches the plan before anything is written.
        for f in plan.files where f.writes && hash(read(f.url)) != f.baseHash { return .changed(committed: []) }
        // A-INFO-6: the path shape is re-checked after consent too: a symlink that appeared or went
        // while the sheet was up is a concurrent change (replan, and the sheet again if the set differs).
        for f in plan.files where f.writes {
            guard case .success(let t) = ManagedConfigPaths.resolve(f.target, kind: f.kind, owner: plan.owner, roots: roots),
                  t.url.path == f.url.path else { return .changed(committed: []) }
        }
        var committed: Set<String> = []
        for f in plan.files {
            if let from = f.movedFrom { // the target resolves elsewhere now: its records follow it
                for i in state.records.indices where state.records[i].path == from { state.records[i].path = f.url.path }
                if state.files.contains(where: { $0.path == f.url.path }) {
                    state.files.removeAll { $0.path == from }
                } else {
                    for i in state.files.indices where state.files[i].path == from { state.files[i].path = f.url.path }
                }
            }
            var firstBackup: String?
            if f.writes {
                do {
                    if let kitDir = f.kitDir { try createKitDir(kitDir, owner: plan.owner.id) }
                    try makeDirs(f.url.deletingLastPathComponent(), mode: ManagedConfig.privateDirMode)
                    var backup: URL?
                    if let base = f.base {
                        let first = !state.files.contains { $0.path == f.url.path }
                        backup = try writeBackup(base, rel: f.backupRel, kind: first ? "orig" : "pre")
                        if first { firstBackup = backup?.path }
                    }
                    if f.delete {
                        guard hash(read(f.url)) == f.baseHash else { if let backup { _ = unlink(backup.path) }; return .changed(committed: committed) }
                        guard unlink(f.url.path) == 0 else {
                            return .failed("removing \(f.target) failed: \(String(cString: strerror(errno)))", committed: committed)
                        }
                    } else if let bytes = f.newBytes {
                        let temp = try writer.writeTemp(bytes, besides: f.url, mode: f.mode)
                        // errata C9: re-read and compare right before rename; Claude Code writes this file too.
                        guard hash(read(f.url)) == f.baseHash else {
                            _ = unlink(temp.path)
                            if let backup { _ = unlink(backup.path) }
                            return .changed(committed: committed)
                        }
                        do { try writer.replace(f.url, with: temp) } catch {
                            _ = unlink(temp.path)
                            if let backup { _ = unlink(backup.path) }
                            throw error
                        }
                    }
                } catch {
                    return .failed("writing \(f.target) failed: \(error)", committed: committed)
                }
            }
            state.records.removeAll { f.deletes.contains(ManagedConfigPlanner.key($0.owner, $0.piece.id)) }
            for u in f.upserts {
                state.records.removeAll { ManagedConfigPlanner.key($0.owner, $0.piece.id) == ManagedConfigPlanner.key(u.owner, u.piece.id) }
                state.records.append(u)
            }
            let old = state.files.first { $0.path == f.url.path }
            state.files.removeAll { $0.path == f.url.path }
            if var record = f.fileRecord {
                record.firstBackup = old?.firstBackup ?? firstBackup
                state.files.append(record)
            } else if let orig = old?.firstBackup, f.writes {
                // errata C10 narrowed by D8: the first-write backup goes with the last piece only when this
                // Remove wrote the file (a fresh `pre` copy now exists); after a .forget it stays in backups/.
                _ = unlink(orig)
            }
            do { try saveState(state) } catch {
                return .failed("saving managed-config state after \(f.target) failed: \(error)", committed: committed)
            }
            committed.formUnion(f.pieces)
        }
        if plan.files.contains(where: { $0.target.hasPrefix("kitconfig:") }) { removeEmptyKitDir(owner: plan.owner, state: state) }
        return .done
    }

    /// D2: when the owner's last `kitconfig:` piece has left, the dir Prosper created goes too, but
    /// only while it holds nothing except our `.prosper-kit` marker. Any other entry keeps it.
    private func removeEmptyKitDir(owner: ManagedConfigOwner, state: ManagedConfigState) {
        guard let slug = owner.kitSlug, ManagedConfigPaths.isValidSlug(slug) else { return }
        let dir = roots.configHome.appendingPathComponent(slug, isDirectory: true)
        let real = dir.resolvingSymlinksInPath().path + "/"
        guard !state.records.contains(where: { $0.path.hasPrefix(real) || $0.path.hasPrefix(dir.path + "/") }),
              case .ours = ManagedConfigPaths.ownership(of: dir, owner: owner.id),
              Self.entries(of: dir) == [ManagedConfigPaths.kitMarkerFile] else { return }
        if unlink(dir.appendingPathComponent(ManagedConfigPaths.kitMarkerFile).path) == 0 { _ = rmdir(dir.path) }
    }

    /// Every name in `dir` by readdir: FileManager hides AppleDouble `._*` names.
    static func entries(of dir: URL) -> [String]? {
        guard let d = opendir(dir.path) else { return nil }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(Int(e.pointee.d_namlen)), as: UTF8.self) }
            if name != ".", name != ".." { out.append(name) }
        }
        return out.sorted()
    }

    private func createKitDir(_ dir: URL, owner: String) throws {
        switch ManagedConfigPaths.ownership(of: dir, owner: owner) {
        case .ours: return
        case .foreign: throw ManagedConfigRefusalReason.foreignDir
        case .absent: break
        }
        try makeDirs(dir, mode: ManagedConfig.privateDirMode)
        let marker = dir.appendingPathComponent(ManagedConfigPaths.kitMarkerFile)
        try writer.replace(marker, with: try writer.writeTemp(Array((owner + "\n").utf8), besides: marker, mode: 0o644))
    }

    private func makeDirs(_ dir: URL, mode: mode_t) throws {
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: Int(mode)])
    }

    /// `backups/<root>/<rel>.<UTC yyyyMMdd-HHmmss>-<nn>.<orig|pre>`, 0600 in 0700 dirs.
    private func writeBackup(_ bytes: [UInt8], rel: String, kind: String) throws -> URL {
        let target = backupsDir.appendingPathComponent(rel)
        let dir = target.deletingLastPathComponent()
        for d in [roots.stateDir, backupsDir] {
            try makeDirs(d, mode: ManagedConfig.privateDirMode)
            _ = chmod(d.path, ManagedConfig.privateDirMode)
        }
        try makeDirs(dir, mode: ManagedConfig.privateDirMode)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())
        var n = 0
        var url: URL
        repeat {
            url = dir.appendingPathComponent("\(target.lastPathComponent).\(stamp)-\(String(format: "%02d", n)).\(kind)")
            n += 1
        } while FileManager.default.fileExists(atPath: url.path)
        try writer.replace(url, with: try writer.writeTemp(bytes, besides: url, mode: ManagedConfig.privateFileMode))
        if kind == "pre" {
            let prefix = target.lastPathComponent + "."
            let pres = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".pre") }.sorted()
            for name in pres.dropLast(ManagedConfig.preWriteBackupsKept) { _ = unlink(dir.appendingPathComponent(name).path) }
        }
        return url
    }

    private func saveState(_ state: ManagedConfigState) throws {
        try makeDirs(roots.stateDir, mode: ManagedConfig.privateDirMode)
        _ = chmod(roots.stateDir.path, ManagedConfig.privateDirMode)
        let data = try Self.encoder.encode(state)
        try writer.replace(stateURL, with: try writer.writeTemp(Array(data), besides: stateURL, mode: ManagedConfig.privateFileMode))
    }

    // MARK: status (spec 2.4)

    /// The owner's pieces and their drift state. `declared` are the owner's current pieces: one with
    /// no record whose marker-matched block is on disk is adopted (spec 2.5 step 4, crash between
    /// the target write and the state write); others report `notApplied`.
    /// An unreadable state.json (written by a newer Prosper, half-edited) makes status write nothing
    /// and claim no adoption; check `stateIsReadable()` to tell the user.
    func status(owner: ManagedConfigOwner, declared: [ManagedConfigPiece] = []) -> [ManagedConfigPieceStatus] {
        var state = loadState()
        let readable = stateIsReadable()
        sweepStaleTemps(beside: state)
        var out = state.records.filter { $0.owner == owner.id }.map { r in
            // the live file: the target may have become (or stopped being) a symlink since the write
            var live = r
            if case .success(let t) = ManagedConfigPaths.resolve(r.target, kind: r.piece.kind, owner: owner, roots: roots) { live.path = t.url.path }
            return ManagedConfigPieceStatus(id: r.piece.id, state: pieceState(live, in: state), target: r.target, path: live.path)
        }
        var adopted: [ManagedConfigRecord] = []
        for p in declared where !state.records.contains(where: { $0.owner == owner.id && $0.piece.id == p.id }) {
            var s = ManagedConfigPieceStatus(id: p.id, state: .notApplied, target: p.target, path: "")
            if readable, p.kind == .block, case .success(let t) = ManagedConfigPaths.resolve(p.target, kind: .block, owner: owner, roots: roots) {
                s.path = t.url.path
                let bytes = read(t.url) ?? []
                if case .present(let b, let e) = ManagedTextBlock.find(owner: owner.id, piece: p.id, in: bytes) {
                    let text = ManagedTextBlock.text(of: bytes, begin: b, end: e)
                    let block = p.text.flatMap { body in ManagedTextBlock.syntax(for: t.url).map {
                        ManagedTextBlock.render(owner: owner.id, piece: p.id, version: owner.version, body: body, syntax: $0)
                    } }
                    // F1 (QA #723): adopt only the byte-equal block; an edited one is drift and stays unowned.
                    guard text == block else { s.state = .drifted; out.append(s); continue }
                    adopted.append(.init(owner: owner.id, piece: p, target: t.display, path: t.url.path, written: text,
                                         hash: OrderedJSON.sha256(Array(text.utf8)), version: owner.version, appliedAt: now(),
                                         sourceDir: owner.extensionDir?.path))
                    s.state = .adopted
                }
            }
            out.append(s)
        }
        if !adopted.isEmpty {
            ManagedConfig.writeLock.lock()
            defer { ManagedConfig.writeLock.unlock() }
            guard let fresh = decodedState() else { return out } // never overwrite a state file we cannot read
            state = fresh
            for a in adopted where !state.records.contains(where: { $0.owner == a.owner && $0.piece.id == a.piece.id }) {
                state.records.append(a)
                if !state.files.contains(where: { $0.path == a.path }) {
                    state.files.append(.init(path: a.path, target: a.target, existed: true))
                }
            }
            try? saveState(state)
        }
        return out
    }

    /// errata A12: `disableAllHooks` at user scope also silences statusLine; the status page says so.
    func hooksDisabledAtUserScope() -> Bool {
        guard let bytes = read(roots.claude.appendingPathComponent("settings.json")), let doc = try? OrderedJSON(bytes: bytes),
              case .bool(true)? = doc.node(at: ["disableAllHooks"])?.value else { return false }
        return true
    }

    private func pieceState(_ r: ManagedConfigRecord, in state: ManagedConfigState) -> ManagedConfigPieceState {
        let url = URL(fileURLWithPath: r.path)
        if let src = r.sourceDir, !FileManager.default.fileExists(atPath: src) { return .orphaned }
        let bytes = read(url)
        if bytes != nil, access(url.path, W_OK) != 0 { return .unwritable }
        guard let bytes else { return .missing }
        switch r.piece.kind {
        case .seed:
            return .applied
        case .block:
            switch ManagedTextBlock.find(owner: r.owner, piece: r.piece.id, in: bytes) {
            case .absent: return .missing
            case .corrupt: return .corrupt
            case .present(let b, let e):
                guard ManagedTextBlock.text(of: bytes, begin: b, end: e) == r.written else { return .drifted }
                for line in ManagedTextBlock.bodyLines(of: r.written) where line.hasPrefix("@/") {
                    let path = String(line.dropFirst()).replacingOccurrences(of: "\\ ", with: " ")
                    if !FileManager.default.fileExists(atPath: path) { return .importMissing }
                }
                return .applied
            }
        case .json:
            guard let doc = try? OrderedJSON(bytes: bytes) else { return .corrupt }
            let node = doc.node(at: r.piece.path ?? [])
            switch r.piece.op {
            case .append?:
                guard case .array(let els)? = node?.value, els.contains(where: { OrderedJSON.hash($0.value) == r.hash }) else { return .missing }
                return .applied
            case .union?:
                guard case .array(let els)? = node?.value else { return .missing }
                let present = Set(els.compactMap { if case .string(let s) = $0.value { return s } else { return nil } })
                return r.claimed.allSatisfy(present.contains) ? .applied : .missing
            case .set?:
                guard let node else { return .missing }
                let h = OrderedJSON.hash(node.value)
                if h == r.hash { return .applied }
                if state.records.contains(where: { $0.path == r.path && $0.piece.path == r.piece.path && $0.owner != r.owner && $0.hash == h }) {
                    return .conflict
                }
                return .replaced
            case nil:
                return .corrupt
            }
        }
    }

    /// D6 (errata E5): deletes `.<name>.prosper-<UUID>` regular files beside a recorded path once they
    /// are older than `staleTempAge` (wall clock against the file's mtime), under the write lock, so a
    /// temp of a write in flight is never taken. Nothing else is ever deleted.
    private func sweepStaleTemps(beside state: ManagedConfigState) {
        let targets = Set(state.records.map(\.path) + state.files.map(\.path)).map { URL(fileURLWithPath: $0) }
        guard !targets.isEmpty else { return }
        ManagedConfig.writeLock.lock()
        defer { ManagedConfig.writeLock.unlock() }
        let cutoff = Date().addingTimeInterval(-ManagedConfig.staleTempAge).timeIntervalSince1970
        for target in targets {
            let dir = target.deletingLastPathComponent()
            let prefix = "." + target.lastPathComponent + ".prosper-"
            for name in Self.entries(of: dir) ?? [] where name.hasPrefix(prefix) {
                let tail = String(name.dropFirst(prefix.count))
                guard tail.count == 36, UUID(uuidString: tail) != nil else { continue }
                let path = dir.appendingPathComponent(name).path
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, Double(st.st_mtimespec.tv_sec) < cutoff else { continue }
                _ = unlink(path)
            }
        }
    }

    /// Every file a record points at: the paths the status refresh watches (never the state dir).
    func recordedPaths() -> [String] {
        let state = loadState()
        return Array(Set(state.records.map(\.path) + state.files.map(\.path))).sorted()
    }

    /// Owners with at least one record, installed or not (a vanished one reports `orphaned`).
    func ownerIDs() -> [String] { Array(Set(loadState().records.map(\.owner))).sorted() }

    // MARK: helpers

    /// False when state.json exists but does not decode: apply, remove and repair refuse, status writes nothing.
    func stateIsReadable() -> Bool { decodedState() != nil }

    /// nil: the file exists and does not decode. Absent file: an empty state.
    private func decodedState() -> ManagedConfigState? {
        guard let bytes = read(stateURL) else { return ManagedConfigState() }
        return Self.decodeState(bytes)
    }

    private func loadState() -> ManagedConfigState {
        read(stateURL).flatMap(Self.decodeState) ?? ManagedConfigState()
    }

    /// A-INFO-8: a state written by a newer Prosper (version above ours) is unreadable, so nothing
    /// re-saves it and drops the fields this build does not know.
    static func decodeState(_ bytes: [UInt8]) -> ManagedConfigState? {
        guard let state = try? decoder.decode(ManagedConfigState.self, from: Data(bytes)),
              state.version <= ManagedConfigState.currentVersion else { return nil }
        return state
    }

    private func read(_ url: URL) -> [UInt8]? { FileManager.default.contents(atPath: url.path).map { Array($0) } }
    private func hash(_ bytes: [UInt8]?) -> String { bytes.map(OrderedJSON.sha256) ?? "absent" }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
