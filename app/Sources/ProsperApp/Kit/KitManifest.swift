import Foundation

// #872 P1 (spec 4.2, errata A2-A10): the `[contributes.kit]` table. Plain Sendable value types,
// no actor isolation. Nothing here reads a file: the validator (KitValidator.swift) does, through
// its seam, and the render step (KitRender.swift) is pure.

/// The `[contributes.kit]` table as TOML gave it, before any schema rule. Decoding it never
/// throws, so a kit with a bad key, an unknown kind or a date value still loads as an extension and
/// the validator refuses it with a reason (never a decode failure, never a silent skip).
enum KitTOML: Codable, Sendable, Equatable {
    case table([String: KitTOML])
    case array([KitTOML])
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    /// a TOML date or time, or a value the decoder would not hand over: no kit key takes one.
    case unsupported

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// TOMLDecoder 0.4.5 hands a scalar to the parent's decoder with its token set (a single-value
    /// container), and a table or array to a fresh decoder whose single-value container throws.
    init(from decoder: Decoder) throws {
        // #883 second line: TOMLGuard caps a header at 64 segments, but a `[[a]]` `[[a.a]]` … chain nests an
        // array and a table per segment (up to 128 levels), and other decoders have no guard. No kit key is this deep.
        guard decoder.codingPath.count <= TOMLGuard.maxDepth else { self = .unsupported; return }
        if let c = try? decoder.singleValueContainer() {
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let i = try? c.decode(Int64.self) { self = .integer(i) }
            else if let d = try? c.decode(Double.self) { self = .double(d) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else { self = .unsupported }
            return
        }
        if let c = try? decoder.container(keyedBy: Key.self) {
            var table: [String: KitTOML] = [:]
            for k in c.allKeys { table[k.stringValue] = (try? c.decode(KitTOML.self, forKey: k)) ?? .unsupported }
            self = .table(table)
            return
        }
        if var c = try? decoder.unkeyedContainer() {
            var items: [KitTOML] = []
            while !c.isAtEnd {
                guard let v = try? c.decode(KitTOML.self) else { items.append(.unsupported); break }
                items.append(v)
            }
            self = .array(items)
            return
        }
        self = .unsupported
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .table(let t):
            var c = encoder.container(keyedBy: Key.self)
            for (k, v) in t { try c.encode(v, forKey: Key(stringValue: k)) }
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .integer(let i): var c = encoder.singleValueContainer(); try c.encode(i)
        case .double(let d): var c = encoder.singleValueContainer(); try c.encode(d)
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .unsupported: var c = encoder.singleValueContainer(); try c.encodeNil()
        }
    }
}

/// Every reason a kit is refused (or warned about), as fixed text. Tests compare these by equality.
enum KitReason: String, Sendable, CaseIterable {
    // manifest (KitManifest.parse)
    case notATable = "[contributes.kit] must be a table"
    case badSchema = "schema must be the integer 1"
    case unknownKey = "unknown key: the kit schema does not list it"
    case wrongType = "wrong value type for this key"
    case missingKey = "a required key is missing"
    case unknownKind = "unknown piece kind: use claude-md, tools, hook, statusline, permissions or seed"
    case badID = "piece id must be [a-z0-9-]+, at most 64 characters"
    case duplicateID = "piece id is used twice"
    case tooManyPieces = "a kit has at most 64 pieces"
    case tooManySettings = "a kit has at most 32 settings"
    case tooManyRequires = "a kit has at most 32 requires entries"
    case badCommandName = "a requires entry or interpreter is a command name [A-Za-z0-9._+-]+, at most 64 characters"
    case badPosition = "position must be top or bottom"
    case badTimeout = "timeout must be an integer from 1 to 3600 seconds"
    case unknownEvent = "hook event is not one of the hook events Claude Code documents"
    case interpreterNotRequired = "interpreter must be listed in requires"
    case twoStatuslines = "a kit has at most one statusline piece"
    case emptyPermissions = "a permissions piece lists at least one rule"
    case badRule = "a permission rule is a non-empty single-line string"
    case secretSetting = "no secret settings: name a Keychain item in the README and let the tool read it"
    case unknownSettingKind = "setting kind must be string, path, bool or choice"
    case badSettingKey = "setting key must be [a-z][a-z0-9_]*, at most 64 characters"
    case duplicateSettingKey = "setting key is used twice"
    case badDefault = "setting default does not match its kind"
    case choiceNeedsValues = "a choice setting lists its values, and its default is one of them"
    case controlCharacter = "text holds a control, line-separator or bidi-control character"
    case tooLong = "text is too long: matcher and choice values or defaults 256, title 128, homepage and rules 512"
    case tooManyValues = "a choice setting has at most 32 values"
    case tooManyRules = "a permissions piece lists at most 64 rules in each of allow, deny and ask"
    // kit dir (KitValidator)
    case badExtensionID = "the extension id must be [A-Za-z0-9._-]+, at most 128 characters, and not only dots"
    case badSlug = "the extension name (the kit slug) must be [a-z0-9-]+, at most 64 characters"
    case slugTaken = "another installed kit already uses this slug"
    case slugReserved = "this slug is reserved for Prosper's own files"
    case noReadme = "README.md is missing at the kit root"
    case readmeHeading = "README.md lacks a required level-2 heading"
    case badPath = "path must be relative, with no '..', '.' or empty component and at most 4 components"
    case pathLeaves = "path leaves the kit dir"
    case pathSymlink = "path goes through a symlink"
    case pathMissing = "path names nothing in the kit"
    case needsFile = "path must name a regular file"
    case needsDir = "path must name a directory"
    case needsMarkdown = "a claude-md source is a .md file"
    case notText = "file is not UTF-8 text"
    case localImportLast = "the kit CLAUDE.md must end with the line @{{kit_config}}/local.md"
    case importTooDeep = "the kit's import chain is deeper than 2 below its CLAUDE.md"
    case tooManyImports = "a file imports more than 64 distinct kit files"
    case binaryExecutable = "executable is a Mach-O or other non-text file"
    case setuid = "file has the setuid or setgid bit"
    case toolsNotFile = "a tools dir holds only regular files"
    case badFileName = "file name must be [A-Za-z0-9][A-Za-z0-9._-]*"
    case duplicateTool = "two tools pieces ship the same tool name"
    case seedClash = "two seed files map to one managed piece id or one kitconfig file"
    case tooManyFiles = "the kit has more than 4096 entries or dirs nested deeper than 16"
    case dotfileSkipped = "dotfile skipped"
    // render (KitRender)
    case notImportable = "the path holds a newline, carriage return or NUL and cannot be imported"
}

struct KitRefusal: Equatable, Sendable, CustomStringConvertible {
    /// where: a piece id, a key path ("pieces[2].colour"), a kit-relative path, or "kit".
    var subject: String
    var reason: KitReason
    var description: String { "\(subject): \(reason.rawValue)" }
}

/// The checked kit table (spec 4.2).
struct KitManifest: Sendable, Equatable {
    struct Piece: Sendable, Equatable {
        enum Kind: String, Sendable, CaseIterable {
            case claudeMD = "claude-md", tools, hook, statusline, permissions, seed
        }
        var id: String
        var kind: Kind
        var source: String? = nil // claude-md
        var position: ManagedConfigPiece.Position = .bottom // claude-md
        var dir: String? = nil // tools
        var event: String? = nil // hook
        var matcher: String? = nil // hook
        var run: String? = nil // hook, statusline
        var timeout: Int? = nil // hook, seconds
        var interpreter: String? = nil // hook, statusline
        var allow: [String] = [] // permissions
        var deny: [String] = []
        var ask: [String] = []
        var from: String? = nil // seed
    }

    struct Setting: Sendable, Equatable {
        enum Kind: String, Sendable { case string, path, bool, choice }
        var key: String
        var title: String
        var kind: Kind
        var defaultValue: TOMLValue? = nil
        var values: [String] = [] // choice
    }

    static let schemaVersion: Int64 = 1
    static let maxPieces = 64
    static let maxSettings = 32
    static let maxRequires = 32
    static let timeoutRange: ClosedRange<Int64> = 1...3600
    static let maxChoiceValues = 32
    /// rules in each of allow, deny and ask (the summary prints one line per rule)
    static let maxRules = 64
    /// caps in Unicode scalars
    static let maxMatcher = 256, maxTitle = 128, maxHomepage = 512, maxRule = 512, maxValue = 256

    /// No C0 control, DEL, C1 control, U+2028/U+2029 or bidi control. Scalars, never Characters:
    /// U+200E after a letter joins that letter's Character.
    static func isPlainText(_ s: String) -> Bool { !s.unicodeScalars.contains(where: isControlScalar) }
    static func isControlScalar(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    static let topKeys: Set<String> = ["schema", "homepage", "requires", "pieces", "settings"]
    static let pieceKeys: [Piece.Kind: Set<String>] = [
        .claudeMD: ["source", "position"],
        .tools: ["dir"],
        .hook: ["event", "matcher", "run", "timeout", "interpreter"],
        .statusline: ["run", "interpreter"],
        .permissions: ["allow", "deny", "ask"],
        .seed: ["from"],
    ]
    static let settingKeys: Set<String> = ["key", "title", "kind", "default", "values"]

    var schema: Int64 = 1
    var homepage: String? = nil
    var requires: [String] = []
    var pieces: [Piece] = []
    var settings: [Setting] = []

    private static let idChars = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    private static let commandChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
    private static let settingChars = Set("abcdefghijklmnopqrstuvwxyz0123456789_")

    static func isValidPieceID(_ s: String) -> Bool { !s.isEmpty && s.count <= 64 && s.allSatisfy { idChars.contains($0) } }
    static func isValidCommand(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.first != "-" && s.allSatisfy { commandChars.contains($0) }
    }
    static func isValidSettingKey(_ s: String) -> Bool {
        guard let f = s.first, f.isASCII, f.isLetter else { return false }
        return s.count <= 64 && s.allSatisfy { settingChars.contains($0) }
    }

    /// Schema check of the raw table. Every problem is collected; nothing is skipped silently.
    /// The kit is usable only when the refusal list is empty.
    static func parse(_ raw: KitTOML) -> (kit: KitManifest, refusals: [KitRefusal]) {
        var p = Parser()
        let kit = p.kit(raw)
        return (kit, p.refusals)
    }

    private struct Parser {
        var refusals: [KitRefusal] = []

        mutating func refuse(_ subject: String, _ reason: KitReason) { refusals.append(.init(subject: subject, reason: reason)) }

        /// One rule for every string of the kit table, keys included (TOML allows quoted keys).
        mutating func plainText(_ v: KitTOML, _ at: String) {
            switch v {
            case .string(let s): if !KitManifest.isPlainText(s) { refuse(at, .controlCharacter) }
            case .table(let t):
                for (k, x) in t.sorted(by: { $0.key < $1.key }) {
                    guard KitManifest.isPlainText(k) else { refuse(at.isEmpty ? "kit" : at, .controlCharacter); continue }
                    plainText(x, at.isEmpty ? k : "\(at).\(k)")
                }
            case .array(let a): for (i, x) in a.enumerated() { plainText(x, "\(at)[\(i)]") }
            default: break
            }
        }

        mutating func cap(_ s: String?, _ n: Int, _ subject: String) {
            if let s, s.unicodeScalars.count > n { refuse(subject, .tooLong) }
        }

        mutating func unknownKeys(_ t: [String: KitTOML], allowed: Set<String>, at prefix: String) {
            for k in t.keys.sorted() where !allowed.contains(k) { refuse("\(prefix)\(k)", .unknownKey) }
        }

        mutating func string(_ t: [String: KitTOML], _ k: String, _ prefix: String, required: Bool = false) -> String? {
            switch t[k] {
            case .string(let s)?: return s
            case nil: if required { refuse("\(prefix)\(k)", .missingKey) }; return nil
            default: refuse("\(prefix)\(k)", .wrongType); return nil
            }
        }

        mutating func strings(_ t: [String: KitTOML], _ k: String, _ prefix: String) -> [String] {
            switch t[k] {
            case nil: return []
            case .array(let items)?:
                var out: [String] = []
                for item in items {
                    guard case .string(let s) = item else { refuse("\(prefix)\(k)", .wrongType); return [] }
                    out.append(s)
                }
                return out
            default: refuse("\(prefix)\(k)", .wrongType); return []
            }
        }

        mutating func tables(_ t: [String: KitTOML], _ k: String) -> [[String: KitTOML]] {
            switch t[k] {
            case nil: return []
            case .array(let items)?:
                var out: [[String: KitTOML]] = []
                for (i, item) in items.enumerated() {
                    guard case .table(let row) = item else { refuse("\(k)[\(i)]", .wrongType); continue }
                    out.append(row)
                }
                return out
            default: refuse(k, .wrongType); return []
            }
        }

        mutating func kit(_ raw: KitTOML) -> KitManifest {
            var kit = KitManifest()
            guard case .table(let t) = raw else { refuse("kit", .notATable); return kit }
            plainText(raw, "")
            unknownKeys(t, allowed: KitManifest.topKeys, at: "")
            // outside value: compared as Int64, never converted
            if case .integer(let n)? = t["schema"], n == KitManifest.schemaVersion { kit.schema = n } else { refuse("schema", .badSchema) }
            kit.homepage = string(t, "homepage", "")
            cap(kit.homepage, KitManifest.maxHomepage, "homepage")
            kit.requires = strings(t, "requires", "")
            if kit.requires.count > KitManifest.maxRequires { refuse("requires", .tooManyRequires) }
            for r in kit.requires where !KitManifest.isValidCommand(r) { refuse("requires", .badCommandName) }

            let rows = tables(t, "pieces")
            if rows.count > KitManifest.maxPieces { refuse("pieces", .tooManyPieces) }
            var seen: Set<String> = []
            for (i, row) in rows.prefix(KitManifest.maxPieces).enumerated() {
                guard let piece = self.piece(row, index: i, requires: kit.requires) else { continue }
                if !seen.insert(piece.id).inserted { refuse(piece.id, .duplicateID) }
                kit.pieces.append(piece)
            }
            if kit.pieces.filter({ $0.kind == .statusline }).count > 1 { refuse("pieces", .twoStatuslines) }

            let settingRows = tables(t, "settings")
            if settingRows.count > KitManifest.maxSettings { refuse("settings", .tooManySettings) }
            var keys: Set<String> = []
            for (i, row) in settingRows.prefix(KitManifest.maxSettings).enumerated() {
                guard let s = setting(row, index: i) else { continue }
                if !keys.insert(s.key).inserted { refuse("settings.\(s.key)", .duplicateSettingKey) }
                kit.settings.append(s)
            }
            return kit
        }

        mutating func piece(_ t: [String: KitTOML], index i: Int, requires: [String]) -> Piece? {
            let at = "pieces[\(i)]."
            let before = refusals.count
            let id = string(t, "id", at, required: true)
            if let id, !KitManifest.isValidPieceID(id) { refuse("\(at)id", .badID) }
            let kindText = string(t, "kind", at, required: true)
            guard let kindText else { return nil }
            guard let kind = Piece.Kind(rawValue: kindText) else { refuse("\(at)kind", .unknownKind); return nil }
            unknownKeys(t, allowed: KitManifest.pieceKeys[kind, default: []].union(["id", "kind"]), at: at)
            var p = Piece(id: id ?? "", kind: kind)
            switch kind {
            case .claudeMD:
                p.source = string(t, "source", at, required: true)
                if let pos = string(t, "position", at) {
                    if let v = ManagedConfigPiece.Position(rawValue: pos) { p.position = v } else { refuse("\(at)position", .badPosition) }
                }
            case .tools:
                p.dir = string(t, "dir", at, required: true)
            case .hook, .statusline:
                p.run = string(t, "run", at, required: true)
                if kind == .hook {
                    p.event = string(t, "event", at, required: true)
                    if let e = p.event, !ManagedConfigPlanner.hookEvents.contains(e) { refuse("\(at)event", .unknownEvent) }
                    p.matcher = string(t, "matcher", at)
                    cap(p.matcher, KitManifest.maxMatcher, "\(at)matcher")
                    switch t["timeout"] {
                    case nil: break
                    // outside value: bounded as Int64 first, so Int(n) cannot trap
                    case .integer(let n)? where KitManifest.timeoutRange.contains(n): p.timeout = Int(n)
                    default: refuse("\(at)timeout", .badTimeout)
                    }
                }
                p.interpreter = string(t, "interpreter", at)
                if let interp = p.interpreter {
                    if !KitManifest.isValidCommand(interp) { refuse("\(at)interpreter", .badCommandName) }
                    else if !requires.contains(interp) { refuse("\(at)interpreter", .interpreterNotRequired) }
                }
            case .permissions:
                p.allow = strings(t, "allow", at)
                p.deny = strings(t, "deny", at)
                p.ask = strings(t, "ask", at)
                let all = p.allow + p.deny + p.ask
                if all.isEmpty { refuse("\(at)allow", .emptyPermissions) }
                for r in all where r.trimmingCharacters(in: .whitespaces).isEmpty || r.contains(where: \.isNewline) || r.contains("\0") {
                    refuse("\(at)allow", .badRule)
                }
                for r in all { cap(r, KitManifest.maxRule, "\(at)allow") }
                for (k, list) in [("allow", p.allow), ("deny", p.deny), ("ask", p.ask)] where list.count > KitManifest.maxRules {
                    refuse("\(at)\(k)", .tooManyRules)
                }
            case .seed:
                p.from = string(t, "from", at, required: true)
            }
            return refusals.count == before ? p : nil
        }

        mutating func setting(_ t: [String: KitTOML], index i: Int) -> Setting? {
            let at = "settings[\(i)]."
            let before = refusals.count
            unknownKeys(t, allowed: KitManifest.settingKeys, at: at)
            let key = string(t, "key", at, required: true)
            if let key, !KitManifest.isValidSettingKey(key) { refuse("\(at)key", .badSettingKey) }
            let title = string(t, "title", at, required: true)
            cap(title, KitManifest.maxTitle, "\(at)title")
            let kindText = string(t, "kind", at, required: true)
            var kind: Setting.Kind?
            if let kindText {
                if kindText == "secret" { refuse("\(at)kind", .secretSetting) }
                else if let k = Setting.Kind(rawValue: kindText) { kind = k }
                else { refuse("\(at)kind", .unknownSettingKind) }
            }
            var s = Setting(key: key ?? "", title: title ?? "", kind: kind ?? .string)
            if kind != .choice, t["values"] != nil { refuse("\(at)values", .unknownKey) }
            if kind == .choice {
                s.values = strings(t, "values", at)
                if s.values.isEmpty { refuse("\(at)values", .choiceNeedsValues) }
                if s.values.count > KitManifest.maxChoiceValues { refuse("\(at)values", .tooManyValues) }
                for v in s.values { cap(v, KitManifest.maxValue, "\(at)values") }
            }
            if case .string(let d)? = t["default"] { cap(d, KitManifest.maxValue, "\(at)default") }
            switch (kind, t["default"]) {
            case (_, nil): break
            case (.string?, .string(let v)?), (.path?, .string(let v)?): s.defaultValue = .string(v)
            case (.bool?, .bool(let v)?): s.defaultValue = .bool(v)
            case (.choice?, .string(let v)?):
                if s.values.contains(v) { s.defaultValue = .string(v) } else { refuse("\(at)default", .choiceNeedsValues) }
            case (nil, _): break // the kind is already refused
            default: refuse("\(at)default", .badDefault)
            }
            return refusals.count == before ? s : nil
        }
    }
}
