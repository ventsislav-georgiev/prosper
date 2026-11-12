import Foundation

// #870 P2: the host side of the managed-config primitive. The core (ManagedConfig/) stays free of
// actor isolation; this directory holds its callers: the Lua `host.config` bridge (this file), the
// consent sheet, and the status refresh.

/// `host.config` (spec 2.7): JSON in from Lua, JSON out. The owner is always the calling extension,
/// handed in by `ExtensionHost`, never read from the Lua arguments. Results never carry a file value
/// beyond the masked consent lines (errata C11).
///
/// Isolation: a caseless enum of static, nonisolated functions. `call` runs on whatever thread the
/// host bridge's detached task uses (never main: `ExtensionHost` refuses write calls made on it).
enum ManagedConfigLua {
    static let operations: Set<String> = ["plan", "apply", "status", "remove", "repair"]

    /// apply / remove / repair wait for the consent sheet.
    static func writes(_ op: String) -> Bool { op == "apply" || op == "remove" || op == "repair" }

    /// What an untrusted extension (and a host without the service) gets: the shape of a real
    /// answer, with nothing done.
    static func inert(_ op: String, message: String = "not permitted") -> String {
        switch op {
        case "plan": return encode(["ok": false, "files": [Any](), "pieces": [Any](), "refused": [Any](), "message": message])
        case "status": return "[]"
        default: return encode(["ok": false, "status": "refused", "applied": [Any](), "removed": [Any](), "refused": [Any](),
                                "pieces": [Any](), "message": message])
        }
    }

    static func call(_ op: String, json: String, owner: ManagedConfigOwner, config: ManagedConfig) async -> String {
        let opts = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        switch op {
        case "plan", "apply":
            let (pieces, bad) = parsePieces(opts["pieces"])
            if !bad.isEmpty { return op == "plan" ? encodePlanRefusal(bad) : encodeResult(.init(status: .refused, refusals: bad, message: "invalid pieces")) }
            if op == "plan" { return encodePlan(config.plan(pieces, owner: owner)) }
            return encodeResult(await config.apply(pieces, owner: owner))
        case "remove", "repair":
            let ids: [String]?
            if opts["all"] as? Bool == true {
                ids = nil
            } else if let list = opts["ids"] as? [Any] {
                ids = list.compactMap { $0 as? String }
            } else if let empty = opts["ids"] as? [String: Any], empty.isEmpty {
                ids = [] // an empty Lua table encodes as {}
            } else {
                return inert(op, message: "\(op) needs ids = { … } or all = true")
            }
            if ids?.isEmpty == true { return encodeResult(.init(status: .nothingToDo)) }
            let result = op == "remove" ? await config.remove(owner: owner, ids: ids) : await config.repair(owner: owner, ids: ids)
            return encodeResult(result)
        case "status":
            // A-INFO-3: an unreadable state would read as "nothing applied"; say so instead.
            guard config.stateIsReadable() else {
                return encode(["error": "state_unreadable", "message": ManagedConfigRefusalReason.stateUnreadable.description])
            }
            let (declared, _) = parsePieces(opts["pieces"])
            let rows: [[String: Any]] = config.status(owner: owner, declared: declared).map {
                ["id": $0.id, "state": $0.state.rawValue, "target": $0.target, "path": $0.path]
            }
            return encode(rows)
        default:
            return inert(op, message: "unknown host.config call")
        }
    }

    // MARK: Lua -> pieces

    /// `{ id=, kind=, target=, text=, position=, path={…}, op=, value=, source= }`. `value` is any Lua
    /// value, carried on as JSON text with sorted keys. Any other key (an `owner` above all) is ignored.
    static func parsePieces(_ raw: Any?) -> ([ManagedConfigPiece], [ManagedConfigRefusal]) {
        let list: [Any]
        if let a = raw as? [Any] { list = a } else if let d = raw as? [String: Any], d.isEmpty { list = [] } else if raw == nil { list = [] } else {
            return ([], [.init(pieceID: "*", target: "*", reason: .invalidPiece("pieces must be a list"))])
        }
        var pieces: [ManagedConfigPiece] = []
        var bad: [ManagedConfigRefusal] = []
        for (i, item) in list.enumerated() {
            guard let d = item as? [String: Any] else {
                bad.append(.init(pieceID: "#\(i + 1)", target: "*", reason: .invalidPiece("a piece is a table"))); continue
            }
            let id = d["id"] as? String ?? "#\(i + 1)"
            let target = d["target"] as? String ?? "*"
            guard d["id"] is String, d["target"] is String,
                  let kind = (d["kind"] as? String).flatMap(ManagedConfigPiece.Kind.init(rawValue:)) else {
                bad.append(.init(pieceID: id, target: target, reason: .invalidPiece("id, target and kind (block, json, seed) are required"))); continue
            }
            var piece = ManagedConfigPiece(id: id, kind: kind, target: target)
            piece.text = d["text"] as? String
            piece.source = d["source"] as? String
            if let p = d["position"] as? String {
                guard let pos = ManagedConfigPiece.Position(rawValue: p) else {
                    bad.append(.init(pieceID: id, target: target, reason: .invalidPiece("position is top or bottom"))); continue
                }
                piece.position = pos
            }
            if let o = d["op"] as? String {
                guard let op = ManagedConfigPiece.Op(rawValue: o) else {
                    bad.append(.init(pieceID: id, target: target, reason: .invalidPiece("op is append, union or set"))); continue
                }
                piece.op = op
            }
            if let p = d["path"] {
                guard let parts = p as? [Any], parts.allSatisfy({ $0 is String }) else {
                    bad.append(.init(pieceID: id, target: target, reason: .invalidPiece("path is a list of keys"))); continue
                }
                piece.path = parts.compactMap { $0 as? String }
            }
            if let v = d["value"] {
                piece.value = String(decoding: (try? JSONSerialization.data(
                    withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8), as: UTF8.self)
            }
            pieces.append(piece)
        }
        return (pieces, bad)
    }

    // MARK: results -> Lua

    static func encodePlan(_ plan: ManagedConfigPlan) -> String {
        let files: [[String: Any]] = plan.changes.files.map { f in
            ["target": f.target, "path": f.path, "backup": f.backupDirectory, "notes": f.notes,
             "new_file": f.newFile, "deletes_file": f.deletesFile,
             // r2: added and removed lines only; context lines are the user's text, for the sheet alone
             "diff": f.lines.filter { $0.sign != .context }.map { line in
                 (line.sign == .added ? "+" : line.sign == .removed ? "-" : " ") + line.text + (line.noFinalNewline ? " (no newline at end of file)" : "")
             }.joined(separator: "\n")]
        }
        return encode(["ok": plan.refusals.isEmpty, "files": files, "pieces": plan.actions.map(action), "refused": plan.refusals.map(refusal)])
    }

    private static func encodePlanRefusal(_ bad: [ManagedConfigRefusal]) -> String {
        encode(["ok": false, "files": [Any](), "pieces": [Any](), "refused": bad.map(refusal)])
    }

    /// P1 note "maps 1:1": ok = result.ok, applied = insert/update/adopt, refused = {id, why}.
    static func encodeResult(_ r: ManagedConfigResult) -> String {
        let applied = r.pieces.filter { [.insert, .update, .adopt].contains($0.action) }.map(\.id)
        let removed = r.pieces.filter { [.remove, .forget, .keep].contains($0.action) }.map(\.id)
        return encode(["ok": r.ok, "status": r.status.rawValue, "message": r.message, "applied": applied, "removed": removed,
                       "refused": r.refusals.map(refusal), "pieces": r.pieces.map(action)])
    }

    private static func action(_ a: ManagedConfigPieceAction) -> [String: Any] { ["id": a.id, "action": a.action.rawValue] }
    private static func refusal(_ r: ManagedConfigRefusal) -> [String: Any] { ["id": r.pieceID, "target": r.target, "why": r.reason.description] }

    static func encode(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The one `ManagedConfig` the host uses, built on first use. Building it reads Prosper's login env
/// (CLAUDE_CONFIG_DIR, errata A11) through the LoginPath probe, which can block for seconds: `get()`
/// never runs on main. A failure is not cached, so the next call retries.
///
/// Isolation: `@unchecked Sendable`, the cache and the hook guarded by `lock`; the closures are `@Sendable`.
final class ManagedConfigProvider: @unchecked Sendable {
    typealias Make = @Sendable () -> Result<ManagedConfig, ManagedConfigRefusalReason>

    private let lock = NSLock()
    private var cached: ManagedConfig?
    private var firstSuccess: (@Sendable (ManagedConfig) -> Void)?
    private let make: Make
    /// r2 (R2-1): the state alone, for "does this owner have records" while `get()` fails. The state
    /// dir does not depend on the login env. nil: no such view (that question then has no answer).
    let stateOnly: @Sendable () -> ManagedConfig?

    init(make: @escaping Make, stateOnly: @escaping @Sendable () -> ManagedConfig? = { nil }) {
        self.make = make
        self.stateOnly = stateOnly
    }
    convenience init(_ config: ManagedConfig) { self.init(make: { .success(config) }, stateOnly: { config }) }

    /// Production: the user's real roots, the native consent sheet. Unavailable under XCTest, so no
    /// test can reach the real ~/.claude or run a login shell through it.
    static let live = ManagedConfigProvider(make: {
        guard NSClassFromString("XCTestCase") == nil else { return .failure(.invalidPiece("managed config is off under tests")) }
        guard let dir = LoginPath.value(of: "CLAUDE_CONFIG_DIR") else {
            return .failure(.unwritable("Prosper could not read CLAUDE_CONFIG_DIR from your login shell"))
        }
        return ManagedConfigRoots.production(loginEnvironment: ["CLAUDE_CONFIG_DIR": dir])
            .map { ManagedConfig(roots: $0, consent: ManagedConfigSheetConsent.live) }
    }, stateOnly: {
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        // No login env: only state questions are asked of it, never a write or a claude: path.
        return (try? ManagedConfigRoots.production(loginEnvironment: [:]).get())
            .map { ManagedConfig(roots: $0, consent: ManagedConfigSheetConsent.live) }
    })

    /// r2 (R2-3), r3 (R3-1): `hook` runs exactly once. With a config already cached it runs now, on
    /// the caller's thread; otherwise the first `get()` that succeeds runs it. The choice is made
    /// under the lock and the call happens outside it, so a racing `get()` cannot run it twice.
    func onFirstSuccess(_ hook: @escaping @Sendable (ManagedConfig) -> Void) {
        let now = lock.withLock { () -> ManagedConfig? in
            if let cached { return cached }
            firstSuccess = hook
            return nil
        }
        if let now { hook(now) }
    }

    /// Blocks while the login env is probed the first time.
    func get() -> Result<ManagedConfig, ManagedConfigRefusalReason> {
        if let hit = lock.withLock({ cached }) { return .success(hit) }
        let made = make()
        guard case .success(let fresh) = made else { return made }
        let (config, hook) = lock.withLock { () -> (ManagedConfig, (@Sendable (ManagedConfig) -> Void)?) in
            if let cached { return (cached, nil) }
            cached = fresh
            defer { firstSuccess = nil }
            return (fresh, firstSuccess)
        }
        hook?(config)
        return .success(config)
    }

    /// `get()` off the caller's thread, for MainActor callers.
    func resolve() async -> Result<ManagedConfig, ManagedConfigRefusalReason> { await Task.detached { self.get() }.value }
}

extension LoadedExtension {
    /// The owner every managed piece of this extension carries (spec 2.7): its id, manifest version,
    /// its `name` as the `kitconfig:` slug, its dir as the `ext:` root.
    var managedConfigOwner: ManagedConfigOwner {
        ManagedConfigOwner(id: id, version: manifest.extension.version, kitSlug: manifest.extension.name, extensionDir: directory)
    }
}
