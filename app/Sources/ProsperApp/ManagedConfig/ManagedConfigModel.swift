import Foundation

// #870 (spec section 2 + errata): the plain value types of the managed-config primitive.
// Every type here is a Sendable value type with no actor isolation.

/// Who owns a set of pieces. The owner id is the extension id, never a caller argument (spec 2.7).
struct ManagedConfigOwner: Sendable, Equatable {
    var id: String
    var version: String
    /// `kitconfig:` resolves to `<configHome>/<kitSlug>/`; `[a-z0-9-]+`.
    var kitSlug: String? = nil
    /// The extension's own dir: the `ext:` root, read-only.
    var extensionDir: URL? = nil
}

/// One managed change. `value` is JSON text (a Lua table is converted to JSON by the P2 bridge).
struct ManagedConfigPiece: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case block, json, seed }
    enum Op: String, Codable, Sendable { case append, union, set }
    enum Position: String, Codable, Sendable { case top, bottom }

    var id: String
    var kind: Kind
    var target: String
    var text: String? = nil
    var position: Position = .bottom
    var path: [String]? = nil
    var op: Op? = nil
    var value: String? = nil
    var source: String? = nil
}

enum ManagedConfigPieceState: String, Codable, Sendable {
    case applied, drifted, missing, replaced, corrupt, unwritable, conflict, adopted, orphaned
    /// errata A3: a block's `@/path` import names a file that does not exist.
    case importMissing
    /// declared by the owner but never applied.
    case notApplied
}

struct ManagedConfigPieceStatus: Equatable, Sendable {
    var id: String
    var state: ManagedConfigPieceState
    var target: String
    var path: String
}

/// Why a piece was refused. `description` names paths, piece ids and line numbers only: never a
/// file value (errata C11).
enum ManagedConfigRefusalReason: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPiece(String)
    case badPath(String)
    case outsideRoot
    case symlinkNotOwned
    case notRegularFile
    case unwritable(String)
    case wrongKind(String)
    case localSettings
    case refusedJSONPath(String)
    case corrupt(String)
    case drifted
    case missing
    case replaced
    case conflict(owner: String)
    case foreignDir
    case unknownPiece
    case stateUnreadable

    var description: String {
        switch self {
        case .invalidPiece(let why): return "invalid piece: \(why)"
        case .badPath(let why): return "refused path: \(why)"
        case .outsideRoot: return "refused path: it leaves its root"
        case .symlinkNotOwned: return "refused path: the symlink points to a file you do not own"
        case .notRegularFile: return "refused path: not a regular file"
        case .unwritable(let why): return "unwritable (\(why))"
        case .wrongKind(let why): return "refused: \(why)"
        case .localSettings: return "refused: settings.local.json is Claude Code's local-scope file; user settings go to settings.json"
        case .refusedJSONPath(let path): return "refused JSON path \(path): not in the managed-key allowlist"
        case .corrupt(let why): return "corrupt: \(why)"
        case .drifted: return "drifted: the block was edited by hand; use Repair or Remove"
        case .missing: return "missing: removed by hand; use Repair or Remove"
        case .replaced: return "replaced: the value was changed by hand; use Repair or Remove"
        case .conflict(let owner): return "conflict: \(owner) already holds this slot"
        case .foreignDir: return "unwritable (foreign dir)"
        case .unknownPiece: return "no such managed piece for this owner"
        case .stateUnreadable: return "Prosper's managed-config state file does not parse"
        }
    }
}

struct ManagedConfigRefusal: Equatable, Sendable, CustomStringConvertible {
    var pieceID: String
    var target: String
    var reason: ManagedConfigRefusalReason
    var description: String { "\(pieceID) (\(target)): \(reason)" }
}

struct ManagedConfigPieceAction: Equatable, Sendable {
    enum Kind: String, Sendable {
        case insert, update, remove, noop
        /// a marker-matched block with no state record is taken over (spec 2.5 step 4).
        case adopt
        /// left on disk as found: a `set` slot someone else changed, or a seed the user edited.
        case keep
        /// the record is dropped; nothing on disk was ours any more.
        case forget
    }
    var id: String
    var action: Kind
}

struct ManagedConfigResult: Equatable, Sendable {
    enum Status: String, Sendable { case done, nothingToDo, denied, refused, fileChanged, failed }
    var status: Status
    var pieces: [ManagedConfigPieceAction] = []
    var refusals: [ManagedConfigRefusal] = []
    var message: String = ""
    var ok: Bool { status == .done || status == .nothingToDo }
}

extension Sequence where Element == String {
    /// A-INFO-3: membership by UTF-8 bytes. Swift's == takes NFC and NFD forms for one string; JSON
    /// (RFC 8259 8.3) and Claude Code compare code units, so a union string is matched as written.
    func containsBytes(_ s: String) -> Bool { contains { $0.utf8.elementsEqual(s.utf8) } }
}

// MARK: - State (Prosper's own file; never a user value beyond what Prosper wrote)

struct ManagedConfigRecord: Codable, Sendable, Equatable {
    var owner: String
    var piece: ManagedConfigPiece
    var target: String
    var path: String // resolved file the write went to
    var written: String // exact block text ("\n"), canonical JSON value, or seed text
    var hash: String
    var hadPrevious: Bool = false
    var previous: String? = nil // `set`: the slot's raw text before ours
    var claimed: [String] = [] // `union`: the strings this piece added or co-owns
    var version: String
    var appliedAt: Date
    var sourceDir: String? = nil
}

struct ManagedConfigFileRecord: Codable, Sendable, Equatable {
    var path: String
    var target: String
    var existed: Bool
    var initial: String? = nil // a whitespace-only original, restored when the last piece leaves
    var firstBackup: String? = nil
    var created: [[String]] = [] // JSON containers Prosper created (any owner)
}

struct ManagedConfigState: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var records: [ManagedConfigRecord] = []
    var files: [ManagedConfigFileRecord] = []
}

// MARK: - Consent (errata C11)

/// The plain model the native consent sheet renders. Lines under `env` or any other path outside
/// the managed-key allowlist are masked, so a secret in the user's settings.json never reaches it.
struct ManagedConfigChangeSet: Equatable, Sendable {
    enum Action: String, Sendable { case apply, remove, repair }

    struct Line: Equatable, Sendable {
        enum Sign: Sendable { case added, removed, context }
        var sign: Sign
        var text: String
        /// the file's last line, with no newline after it
        var noFinalNewline = false
    }

    struct File: Equatable, Sendable {
        var target: String
        var path: String
        var backupDirectory: String
        var lines: [Line]
        var notes: [String]
        /// the file does not exist yet / the change deletes it (a file only Prosper wrote)
        var newFile = false
        var deletesFile = false
    }

    var action: Action
    var owner: String
    var files: [File]
    var pieces: [ManagedConfigPieceAction]

    static let maskedLine = "•••• (hidden: outside the keys Prosper manages)"
    static let elidedLine = "…"
    static let userValueLine = "•••• (your own value: kept in the backup, not shown)"
}

/// The seam every user-file write goes through. The real implementation (P2) is a native SwiftUI
/// sheet; tests use a recording fake. Never "always allow": each non-noop change set asks.
protocol ManagedConfigConsent: Sendable {
    func confirm(_ changes: ManagedConfigChangeSet) async -> Bool
}
