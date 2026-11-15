import Foundation
import TOMLDecoder
import XCTest
@testable import ProsperApp

// #872 P1: neutral fixtures only (dev.example.kit.*, "calm-agent"). Every kit dir is under a
// tempDir(); no test reads the real home, ~/.claude, the Keychain or the network, and no test runs
// a kit script.

enum KitFixture {
    static let head = """
    [extension]
    id          = "dev.example.kit.calm-agent"
    name        = "calm-agent"
    title       = "Calm Agent Kit"
    description = "A neutral fixture kit."
    version     = "1.0.0"
    author      = "Example Author"
    license     = "MIT"

    [extension.host]
    min_version = "2.170.0"
    api_level   = 1

    [extension.entry]
    main = "init.lua"

    """

    /// Every piece kind once; piece indexes: rules 0, tools 1, guard 2, hud 3, perms 4, config 5.
    static let kit = """
    [contributes.kit]
    schema   = 1
    homepage = "https://example.com/calm-agent"
    requires = ["node"]

    [[contributes.kit.pieces]]
    id       = "rules"
    kind     = "claude-md"
    source   = "CLAUDE.md"
    position = "bottom"

    [[contributes.kit.pieces]]
    id   = "tools"
    kind = "tools"
    dir  = "tools"

    [[contributes.kit.pieces]]
    id      = "guard"
    kind    = "hook"
    event   = "PreToolUse"
    matcher = "Bash"
    run     = "hooks/guard.sh"
    timeout = 10

    [[contributes.kit.pieces]]
    id          = "hud"
    kind        = "statusline"
    run         = "statusline/hud.mjs"
    interpreter = "node"

    [[contributes.kit.pieces]]
    id    = "perms"
    kind  = "permissions"
    allow = ["Bash(calm-note:*)"]
    deny  = ["Bash(rm -rf:*)"]
    ask   = []

    [[contributes.kit.pieces]]
    id   = "config"
    kind = "seed"
    from = "seed/"

    [[contributes.kit.settings]]
    key     = "default_repo"
    title   = "Default repo (owner/name)"
    kind    = "string"
    default = ""
    """

    static func manifest(_ kit: String = KitFixture.kit, head: String = KitFixture.head) throws -> ExtensionManifest {
        try TOMLDecoder().decodeGuarded(ExtensionManifest.self, from: head + "\n" + kit + "\n")
    }

    /// `kit` with `old` replaced once; fails loudly when `old` is not there.
    static func kit(replacing old: String, with new: String) -> String {
        if !kit.contains(old) { XCTFail("fixture has no \(old)") }
        return kit.replacingOccurrences(of: old, with: new)
    }

    static var bundled: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }
}

final class KitManifestTests: XCTestCase {
    private func parse(_ kit: String) throws -> (kit: KitManifest, refusals: [KitRefusal]) {
        KitManifest.parse(try XCTUnwrap(KitFixture.manifest(kit).contributes?.kit))
    }

    private func assertRefused(_ kit: String, _ subject: String, _ reason: KitReason, line: UInt = #line) throws {
        let bad = try parse(kit).refusals
        XCTAssertTrue(bad.contains(KitRefusal(subject: subject, reason: reason)), "\(bad)", line: line)
    }

    func testFixtureKitParsesEverySixKinds() throws {
        let (kit, bad) = try parse(KitFixture.kit)
        XCTAssertEqual(bad, [])
        XCTAssertEqual(kit.pieces.map(\.kind), [.claudeMD, .tools, .hook, .statusline, .permissions, .seed])
        XCTAssertEqual(Set(kit.pieces.map(\.kind)), Set(KitManifest.Piece.Kind.allCases))
        XCTAssertEqual(kit.schema, 1)
        XCTAssertEqual(kit.homepage, "https://example.com/calm-agent")
        XCTAssertEqual(kit.requires, ["node"])
        XCTAssertEqual(kit.pieces[2], KitManifest.Piece(id: "guard", kind: .hook, event: "PreToolUse", matcher: "Bash", run: "hooks/guard.sh", timeout: 10))
        XCTAssertEqual(kit.pieces[3].interpreter, "node")
        XCTAssertEqual(kit.pieces[4].allow, ["Bash(calm-note:*)"])
        XCTAssertEqual(kit.pieces[4].ask, [])
        XCTAssertEqual(kit.pieces[5].from, "seed/")
        XCTAssertEqual(kit.settings, [.init(key: "default_repo", title: "Default repo (owner/name)", kind: .string, defaultValue: .string(""))])
    }

    /// A manifest with no kit table decodes as before: kit is nil, every other contribution intact.
    func testBundledManifestsWithoutKitDecodeAsBefore() throws {
        let amber = try TOMLDecoder().decodeGuarded(ExtensionManifest.self, from: String(
            contentsOf: KitFixture.bundled.appendingPathComponent("theme-amber/extension.toml"), encoding: .utf8))
        XCTAssertNil(amber.contributes?.kit)
        XCTAssertEqual(amber.contributes?.allThemes, [ThemeContribution(id: "com.prosper.theme.amber", title: "Amber Terminal", path: "theme.json", appearance: "dark")])
        let calc = try TOMLDecoder().decodeGuarded(ExtensionManifest.self, from: String(
            contentsOf: KitFixture.bundled.appendingPathComponent("calc/extension.toml"), encoding: .utf8))
        XCTAssertNil(calc.contributes?.kit)
        XCTAssertEqual(calc.contributes?.allCommands.first?.id, "calc.eval")
        XCTAssertEqual(calc.extension.id, "com.prosper.calc")
        // the encoded form carries no kit key, as the type without it encoded
        let json = String(decoding: try JSONEncoder().encode(calc), as: UTF8.self)
        XCTAssertFalse(json.contains("\"kit\""))
    }

    func testSchemaMustBeTheIntegerOne() throws {
        for bad in ["schema   = 2", "schema   = 0", "schema   = -1", #"schema   = "1""#, "schema   = 1.0", "schema   = 9223372036854775807"] {
            try assertRefused(KitFixture.kit(replacing: "schema   = 1", with: bad), "schema", .badSchema)
        }
        try assertRefused(KitFixture.kit(replacing: "schema   = 1\n", with: ""), "schema", .badSchema)
    }

    func testUnknownKeysAreRefusedNotSkipped() throws {
        try assertRefused(KitFixture.kit(replacing: "schema   = 1", with: "schema   = 1\ncolour = \"red\""), "colour", .unknownKey)
        try assertRefused(KitFixture.kit(replacing: "timeout = 10", with: "timeout = 10\nonce = true"), "pieces[2].once", .unknownKey)
        // a key of another kind is unknown here: `run` on a claude-md piece
        try assertRefused(KitFixture.kit(replacing: "position = \"bottom\"", with: "position = \"bottom\"\nrun = \"x.sh\""), "pieces[0].run", .unknownKey)
        try assertRefused(KitFixture.kit(replacing: "default = \"\"", with: "default = \"\"\nvalues = [\"a\"]"), "settings[0].values", .unknownKey)
    }

    /// spec 4.12 item 1 "env piece": there is no env kind; any unknown kind is refused with the reason.
    func testUnknownPieceKindRefused() throws {
        try assertRefused(KitFixture.kit(replacing: "kind = \"seed\"", with: "kind = \"env\""), "pieces[5].kind", .unknownKind)
        try assertRefused(KitFixture.kit(replacing: "kind = \"seed\"", with: "kind = \"Seed\""), "pieces[5].kind", .unknownKind)
    }

    func testUnknownHookEventRefused() throws {
        try assertRefused(KitFixture.kit(replacing: "event   = \"PreToolUse\"", with: "event   = \"BeforeToolUse\""), "pieces[2].event", .unknownEvent)
        try assertRefused(KitFixture.kit(replacing: "event   = \"PreToolUse\"", with: "event   = \"pretooluse\""), "pieces[2].event", .unknownEvent)
        // errata A5: the 33 documented events, one constant shared with ManagedConfig
        XCTAssertEqual(ManagedConfigPlanner.hookEvents.count, 33)
        for e in ["SessionStart", "PostToolUseFailure", "ElicitationResult", "SessionEnd"] {
            XCTAssertEqual(try parse(KitFixture.kit(replacing: "event   = \"PreToolUse\"", with: "event   = \"\(e)\"")).refusals, [], e)
        }
    }

    /// Outside value: a TOML integer is bounded before any conversion (1...3600).
    func testTimeoutBounds() throws {
        for bad in ["0", "-1", "3601", "9223372036854775807", "-9223372036854775808", "\"10\"", "1.5"] {
            try assertRefused(KitFixture.kit(replacing: "timeout = 10", with: "timeout = \(bad)"), "pieces[2].timeout", .badTimeout)
        }
        XCTAssertEqual(try parse(KitFixture.kit(replacing: "timeout = 10", with: "timeout = 1")).kit.pieces[2].timeout, 1)
        XCTAssertEqual(try parse(KitFixture.kit(replacing: "timeout = 10", with: "timeout = 3600")).kit.pieces[2].timeout, 3600)
        XCTAssertNil(try parse(KitFixture.kit(replacing: "timeout = 10\n", with: "")).kit.pieces[2].timeout)
    }

    func testInterpreterMustBeRequired() throws {
        try assertRefused(KitFixture.kit(replacing: "requires = [\"node\"]", with: "requires = [\"jq\"]"), "pieces[3].interpreter", .interpreterNotRequired)
        try assertRefused(KitFixture.kit(replacing: "requires = [\"node\"]", with: "requires = []"), "pieces[3].interpreter", .interpreterNotRequired)
        try assertRefused(KitFixture.kit(replacing: "interpreter = \"node\"", with: "interpreter = \"node; rm\""), "pieces[3].interpreter", .badCommandName)
        try assertRefused(KitFixture.kit(replacing: "requires = [\"node\"]", with: "requires = [\"node\", \"-rf\"]"), "requires", .badCommandName)
    }

    func testDuplicatePieceIDRefused() throws {
        try assertRefused(KitFixture.kit(replacing: "id          = \"hud\"", with: "id          = \"guard\""), "guard", .duplicateID)
    }

    func testPieceIDShape() throws {
        for bad in ["Rules", "rules.md", "rules_x", "", String(repeating: "a", count: 65)] {
            try assertRefused(KitFixture.kit(replacing: "id       = \"rules\"", with: "id       = \"\(bad)\""), "pieces[0].id", .badID)
        }
    }

    func testTwoStatuslinesRefused() throws {
        let second = "\n[[contributes.kit.pieces]]\nid = \"hud2\"\nkind = \"statusline\"\nrun = \"statusline/hud.mjs\"\n"
        try assertRefused(KitFixture.kit(replacing: "[[contributes.kit.settings]]", with: second + "\n[[contributes.kit.settings]]"), "pieces", .twoStatuslines)
    }

    func testPieceAndSettingCaps() throws {
        let piece = { (i: Int) in "\n[[contributes.kit.pieces]]\nid = \"p\(i)\"\nkind = \"permissions\"\nallow = [\"Bash(x\(i):*)\"]\n" }
        let pieces58 = (0..<58).map(piece).joined()
        let ok = try parse(KitFixture.kit(replacing: "[[contributes.kit.settings]]", with: pieces58 + "\n[[contributes.kit.settings]]"))
        XCTAssertEqual(ok.refusals, [])
        XCTAssertEqual(ok.kit.pieces.count, 64)
        try assertRefused(KitFixture.kit(replacing: "[[contributes.kit.settings]]", with: pieces58 + piece(99) + "\n[[contributes.kit.settings]]"),
                          "pieces", .tooManyPieces)
        let setting = { (i: Int) in "\n[[contributes.kit.settings]]\nkey = \"k\(i)\"\ntitle = \"K\"\nkind = \"bool\"\ndefault = true\n" }
        XCTAssertEqual(try parse(KitFixture.kit + (0..<31).map(setting).joined()).refusals, [])
        try assertRefused(KitFixture.kit + (0..<32).map(setting).joined(), "settings", .tooManySettings)
    }

    func testSecretSettingRefused() throws {
        try assertRefused(KitFixture.kit(replacing: "kind    = \"string\"", with: "kind    = \"secret\""), "settings[0].kind", .secretSetting)
        try assertRefused(KitFixture.kit(replacing: "kind    = \"string\"", with: "kind    = \"password\""), "settings[0].kind", .unknownSettingKind)
    }

    func testSettingShapes() throws {
        try assertRefused(KitFixture.kit(replacing: "key     = \"default_repo\"", with: "key     = \"Default-Repo\""), "settings[0].key", .badSettingKey)
        try assertRefused(KitFixture.kit(replacing: "default = \"\"", with: "default = true"), "settings[0].default", .badDefault)
        try assertRefused(KitFixture.kit(replacing: "kind    = \"string\"\ndefault = \"\"", with: "kind    = \"choice\"\ndefault = \"b\"\nvalues = [\"a\"]"),
                          "settings[0].default", .choiceNeedsValues)
        try assertRefused(KitFixture.kit(replacing: "kind    = \"string\"\ndefault = \"\"", with: "kind    = \"choice\""), "settings[0].values", .choiceNeedsValues)
        let choice = try parse(KitFixture.kit(replacing: "kind    = \"string\"\ndefault = \"\"", with: "kind    = \"choice\"\ndefault = \"b\"\nvalues = [\"a\", \"b\"]"))
        XCTAssertEqual(choice.refusals, [])
        XCTAssertEqual(choice.kit.settings.first?.values, ["a", "b"])
        XCTAssertEqual(choice.kit.settings.first?.defaultValue, .string("b"))
    }

    func testPermissionsNeedARule() throws {
        try assertRefused(KitFixture.kit(replacing: "allow = [\"Bash(calm-note:*)\"]\ndeny  = [\"Bash(rm -rf:*)\"]", with: "allow = []"), "pieces[4].allow", .emptyPermissions)
        try assertRefused(KitFixture.kit(replacing: "allow = [\"Bash(calm-note:*)\"]", with: "allow = [\"a\\nb\"]"), "pieces[4].allow", .badRule)
        try assertRefused(KitFixture.kit(replacing: "allow = [\"Bash(calm-note:*)\"]", with: "allow = \"Bash(x)\""), "pieces[4].allow", .wrongType)
    }

    /// A TOML date anywhere in the kit table still decodes the manifest; the kit is refused.
    func testDateValueIsAWrongTypeNotADecodeFailure() throws {
        let m = try KitFixture.manifest(KitFixture.kit(replacing: "homepage = \"https://example.com/calm-agent\"", with: "homepage = 1979-05-27"))
        XCTAssertEqual(m.extension.id, "dev.example.kit.calm-agent")
        XCTAssertTrue(KitManifest.parse(try XCTUnwrap(m.contributes?.kit)).refusals.contains(.init(subject: "homepage", reason: .wrongType)))
    }

    func testMissingRequiredKeys() throws {
        try assertRefused(KitFixture.kit(replacing: "run     = \"hooks/guard.sh\"\n", with: ""), "pieces[2].run", .missingKey)
        try assertRefused(KitFixture.kit(replacing: "source   = \"CLAUDE.md\"\n", with: ""), "pieces[0].source", .missingKey)
        try assertRefused(KitFixture.kit(replacing: "kind = \"tools\"\n", with: ""), "pieces[1].kind", .missingKey)
        XCTAssertEqual(KitManifest.parse(.string("kit")).refusals, [.init(subject: "kit", reason: .notATable)])
    }

    /// The reason texts are fixed constants.
    // MARK: round 2 F3: one control / bidi rule on every string, length caps

    /// One case per field: a TOML escape puts the character in the decoded string.
    func testControlCharactersRefusedInEveryString() throws {
        let choice = #"kind    = "choice"\#nvalues  = ["a\nb", "c"]\#ndefault = "c""#
        let cases: [(old: String, new: String, subject: String)] = [
            (#"matcher = "Bash""#, #"matcher = "Bash)\nother: harmless line""#, "pieces[2].matcher"),
            (#"run     = "hooks/guard.sh""#, #"run     = "hooks/guard.sh\n""#, "pieces[2].run"),
            (#"source   = "CLAUDE.md""#, #"source   = "CLAUDE.md\n""#, "pieces[0].source"),
            (#"dir  = "tools""#, #"dir  = "tools\n""#, "pieces[1].dir"),
            (#"from = "seed/""#, #"from = "seed/\r""#, "pieces[5].from"),
            (#"homepage = "https://example.com/calm-agent""#, #"homepage = "https://example.com/\u0085x""#, "homepage"),
            (#"title   = "Default repo (owner/name)""#, #"title   = "Default repo\u2028(owner/name)""#, "settings[0].title"),
            (#"default = """#, #"default = "\u0001""#, "settings[0].default"),
            (#"allow = ["Bash(calm-note:*)"]"#, #"allow = ["Bash(calm-note:*)\u2029"]"#, "pieces[4].allow[0]"),
            (#"kind    = "string"\#ndefault = """#, choice, "settings[0].values[0]"),
            (#"position = "bottom""#, #"position = "bottom"\#n"x\ny" = 1"#, "pieces[0]"),
            (#"interpreter = "node""#, #"interpreter = "node\u007F""#, "pieces[3].interpreter"),
        ]
        for c in cases {
            try assertRefused(KitFixture.kit(replacing: c.old, with: c.new), c.subject, .controlCharacter)
        }
    }

    /// Scalars, not Characters: CR LF is ONE Character of two control scalars, so a check on
    /// single-scalar Characters misses it. (U+200E is grapheme class Control: its own Character.)
    func testBidiMarkAfterALetterRefused() throws {
        XCTAssertEqual("a\r\nb".count, 3)
        try assertRefused(KitFixture.kit(replacing: #"matcher = "Bash""#, with: #"matcher = "a\r\nb""#), "pieces[2].matcher", .controlCharacter)
        try assertRefused(KitFixture.kit(replacing: #"matcher = "Bash""#, with: #"matcher = "a\u200E""#), "pieces[2].matcher", .controlCharacter)
        for u: UInt32 in [0x061C, 0x200E, 0x200F, 0x202A, 0x202E, 0x2066, 0x2069, 0x2028, 0x2029, 0x7F, 0x80, 0x9F, 0x1F, 0x0] {
            XCTAssertFalse(KitManifest.isPlainText("a" + String(Character(Unicode.Scalar(u)!))), String(u, radix: 16))
        }
        for ok in ["Bash(rm -rf:*)", "Edit|Write", "ünïcödé ✓", "a\u{200D}b", "tab-free"] { XCTAssertTrue(KitManifest.isPlainText(ok), ok) }
    }

    func testLengthCaps() throws {
        func s(_ n: Int) -> String { String(repeating: "x", count: n) }
        XCTAssertEqual(try parse(KitFixture.kit(replacing: #"matcher = "Bash""#, with: "matcher = \"\(s(256))\"")).refusals, [])
        try assertRefused(KitFixture.kit(replacing: #"matcher = "Bash""#, with: "matcher = \"\(s(257))\""), "pieces[2].matcher", .tooLong)
        try assertRefused(KitFixture.kit(replacing: #"title   = "Default repo (owner/name)""#, with: "title   = \"\(s(129))\""), "settings[0].title", .tooLong)
        try assertRefused(KitFixture.kit(replacing: #""https://example.com/calm-agent""#, with: "\"\(s(513))\""), "homepage", .tooLong)
        try assertRefused(KitFixture.kit(replacing: #""Bash(calm-note:*)""#, with: "\"\(s(513))\""), "pieces[4].allow", .tooLong)
        try assertRefused(KitFixture.kit(replacing: #"default = """#, with: "default = \"\(s(257))\""), "settings[0].default", .tooLong)
        let many = (0...32).map { "\"v\($0)\"" }.joined(separator: ", ")
        try assertRefused(KitFixture.kit(replacing: #"kind    = "string"\#ndefault = """#, with: "kind    = \"choice\"\nvalues  = [\(many)]"),
                          "settings[0].values", .tooManyValues)
        try assertRefused(KitFixture.kit(replacing: #"kind    = "string"\#ndefault = """#, with: "kind    = \"choice\"\nvalues  = [\"\(s(257))\"]"),
                          "settings[0].values", .tooLong)
        // caps count scalars: 129 flags are 129 Characters but 258 scalars
        try assertRefused(KitFixture.kit(replacing: #"matcher = "Bash""#, with: "matcher = \"\(String(repeating: "🇧🇬", count: 129))\""),
                          "pieces[2].matcher", .tooLong)
    }

    /// round 3 G2: at most 64 rules in each of allow, deny and ask.
    func testRuleCountCap() throws {
        func rules(_ n: Int) -> String { "[" + (0..<n).map { "\"Bash(r\($0):*)\"" }.joined(separator: ", ") + "]" }
        for key in ["allow", "deny", "ask"] {
            let old = key == "allow" ? #"allow = ["Bash(calm-note:*)"]"# : key == "deny" ? #"deny  = ["Bash(rm -rf:*)"]"# : "ask   = []"
            let pad = key == "allow" ? "allow = " : key == "deny" ? "deny  = " : "ask   = "
            XCTAssertEqual(try parse(KitFixture.kit(replacing: old, with: pad + rules(64))).refusals, [], key)
            try assertRefused(KitFixture.kit(replacing: old, with: pad + rules(65)), "pieces[4].\(key)", .tooManyRules)
        }
    }

    func testReasonTextsAreFixed() {
        XCTAssertEqual(KitReason.unknownEvent.rawValue, "hook event is not one of the hook events Claude Code documents")
        XCTAssertEqual(KitReason.interpreterNotRequired.rawValue, "interpreter must be listed in requires")
        XCTAssertEqual(KitReason.badTimeout.rawValue, "timeout must be an integer from 1 to 3600 seconds")
        XCTAssertEqual(KitReason.localImportLast.rawValue, "the kit CLAUDE.md must end with the line @{{kit_config}}/local.md")
        XCTAssertEqual(KitRefusal(subject: "guard", reason: .duplicateID).description, "guard: piece id is used twice")
        XCTAssertEqual(Set(KitReason.allCases.map(\.rawValue)).count, KitReason.allCases.count, "every reason text is distinct")
    }

    // MARK: #917 S1 validator riders

    /// The invisible scalars ruling E-6 lists, written as TOML escapes.
    private static let invisible: [UInt32] = [0x00AD, 0x200B, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xFEFF, 0x180E,
                                              0xE0000, 0xE0001, 0xE0020, 0xE007F]

    /// B1 (ruling E-6): each listed invisible scalar is refused in every string key, keys included.
    func testInvisibleScalarsAreRefusedInEveryStringKey() throws {
        let choice = #"kind    = "choice"\#nvalues  = ["a@Ib", "c"]\#ndefault = "c""#
        let cases: [(old: String, new: String, subject: String)] = [
            (#"matcher = "Bash""#, #"matcher = "Ba@Ish""#, "pieces[2].matcher"),
            (#"run     = "hooks/guard.sh""#, #"run     = "hooks/g@Iuard.sh""#, "pieces[2].run"),
            (#"source   = "CLAUDE.md""#, #"source   = "CLAUDE.m@Id""#, "pieces[0].source"),
            (#"dir  = "tools""#, #"dir  = "to@Iols""#, "pieces[1].dir"),
            (#"from = "seed/""#, #"from = "se@Ied/""#, "pieces[5].from"),
            (#"homepage = "https://example.com/calm-agent""#, #"homepage = "https://example.com/ca@Ilm-agent""#, "homepage"),
            (#"title   = "Default repo (owner/name)""#, #"title   = "Default@I repo""#, "settings[0].title"),
            (#"default = """#, #"default = "@I""#, "settings[0].default"),
            (#"allow = ["Bash(calm-note:*)"]"#, #"allow = ["Bash(calm-@Inote:*)"]"#, "pieces[4].allow[0]"),
            (#"deny  = ["Bash(rm -rf:*)"]"#, #"deny  = ["Bash(rm @I-rf:*)"]"#, "pieces[4].deny[0]"),
            (#"kind    = "string"\#ndefault = """#, choice, "settings[0].values[0]"),
            (#"position = "bottom""#, #"position = "bottom"\#n"x@Iy" = 1"#, "pieces[0]"),
            (#"schema   = 1"#, #"schema   = 1\#n"home@Ipage" = "x""#, "kit"),
            (#"interpreter = "node""#, #"interpreter = "no@Ide""#, "pieces[3].interpreter"),
            (#"requires = ["node"]"#, #"requires = ["node", "j@Iq"]"#, "requires[1]"),
            (#"id       = "rules""#, #"id       = "ru@Iles""#, "pieces[0].id"),
            (#"kind = "seed""#, #"kind = "se@Ied""#, "pieces[5].kind"),
            (#"event   = "PreToolUse""#, #"event   = "Pre@IToolUse""#, "pieces[2].event"),
            (#"position = "bottom""#, #"position = "bot@Itom""#, "pieces[0].position"),
            (#"key     = "default_repo""#, #"key     = "default_@Irepo""#, "settings[0].key"),
            (#"kind    = "string""#, #"kind    = "str@Iing""#, "settings[0].kind"),
        ]
        for u in Self.invisible {
            let esc = u > 0xFFFF ? String(format: "\\U%08X", u) : String(format: "\\u%04X", u)
            for c in cases {
                try assertRefused(KitFixture.kit(replacing: c.old, with: c.new.replacingOccurrences(of: "@I", with: esc)), c.subject, .controlCharacter)
            }
        }
        // the scalars added to the rule are exactly the listed ones (ranges expanded)
        let before: (UInt32) -> Bool = {
            switch $0 {
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
            default: return false
            }
        }
        var added: Set<UInt32> = []
        for v in UInt32(0)...0x10FFFF {
            if let u = Unicode.Scalar(v), KitManifest.isControlScalar(u), !before(v) { added.insert(v) }
        }
        let listed: [UInt32] = [0x00AD, 0x180E, 0x200B, 0xFEFF] + Array(UInt32(0x2060)...0x2064) + Array(UInt32(0xE0000)...0xE007F)
        XCTAssertEqual(added, Set(listed))
    }

    /// Ruling E-6: ZWJ and ZWNJ still pass; so do U+FE0F and U+00A0, which OutsideText.isUnseen refuses: why
    /// the rule is a literal list and not isUnseen.
    func testZeroWidthJoinerAndEmojiSelectorStillPass() throws {
        for u: UInt32 in [0xFE0F, 0x00A0, 0x200C, 0x200D] {
            XCTAssertTrue(OutsideText.isUnseen(try XCTUnwrap(Unicode.Scalar(u))), String(u, radix: 16))
        }
        let title = #"title   = "Theme \u2764\uFE0F: a\u200Db a\u200Cb""#
        XCTAssertEqual(try parse(KitFixture.kit(replacing: #"title   = "Default repo (owner/name)""#, with: title)).refusals, [])
        // S2a (QA r1135): a matcher is strict, U+200D is refused there
        try assertRefused(KitFixture.kit(replacing: #"matcher = "Bash""#, with: #"matcher = "a\u200Db""#), "pieces[2].matcher", .controlCharacter)
    }

    /// Ruling E-10: a piece id may not start with "-".
    func testLeadingDashPieceIDRefused() throws {
        for bad in ["-p", "-", "--rules"] {
            try assertRefused(KitFixture.kit(replacing: "id       = \"rules\"", with: "id       = \"\(bad)\""), "pieces[0].id", .badID)
        }
        XCTAssertEqual(try parse(KitFixture.kit(replacing: "id       = \"rules\"", with: "id       = \"rules-2\"")).refusals, [])
    }

    /// INFO-4: the homepage is an https link; a pure check on the string.
    func testHomepageMustBeHTTPS() throws {
        let old = #"homepage = "https://example.com/calm-agent""#
        for bad in ["http://example.com/kit", "ftp://example.com/kit", "example.com/kit", "https://", "file:///Users/example/kit", ""] {
            try assertRefused(KitFixture.kit(replacing: old, with: "homepage = \"\(bad)\""), "homepage", .badHomepage)
        }
        for ok in ["https://example.com/calm-agent", "HTTPS://example.com/x"] {
            XCTAssertEqual(try parse(KitFixture.kit(replacing: old, with: "homepage = \"\(ok)\"")).refusals, [], ok)
        }
    }

    /// INFO-5: a bad deny or ask rule is reported under its own key, not under allow.
    func testDenyAndAskRulesReportedUnderTheirKey() throws {
        let deny = #"deny  = ["Bash(rm -rf:*)"]"#
        try assertRefused(KitFixture.kit(replacing: deny, with: #"deny  = ["  "]"#), "pieces[4].deny", .badRule)
        try assertRefused(KitFixture.kit(replacing: "ask   = []", with: #"ask   = ["  "]"#), "pieces[4].ask", .badRule)
        try assertRefused(KitFixture.kit(replacing: deny, with: "deny  = [\"\(String(repeating: "x", count: 513))\"]"), "pieces[4].deny", .tooLong)
        let bad = try parse(KitFixture.kit(replacing: deny, with: #"deny  = ["  "]"#)).refusals
        XCTAssertFalse(bad.contains { $0.subject == "pieces[4].allow" }, "\(bad)")
    }

    func testRiderReasonTextsAreFixed() {
        XCTAssertEqual(KitReason.tooManyFiles.rawValue, "the kit has more than 4096 entries or a dir 16 levels deep (15 is the most)")
        XCTAssertEqual(KitReason.controlCharacter.rawValue, "text holds a control, line-separator, bidi-control or invisible character")
        XCTAssertEqual(KitReason.seedUnderHooks.rawValue, "a seed file may not land in the kit config's hooks/ folder: that folder is the user's")
        XCTAssertEqual(KitReason.tooLargeToCheck.rawValue, "executable is over 1 MiB, too large to check as text")
    }

    // MARK: #917 S2a riders (QA ruling r1135)

    /// Display text: the fillers, the combining grapheme joiner, a variation selector and a no-break space are refused in a title.
    func testTitleRefusesFillersAndLookAlikes() throws {
        for u in ["034F", "3164", "FFA0", "206A", "FE00", "00A0", "2003", "0378"] {
            try assertRefused(KitFixture.kit(replacing: #"title   = "Default repo (owner/name)""#, with: "title   = \"Ab\\u\(u)c\""),
                              "settings[0].title", .controlCharacter)
        }
    }

    /// Display text keeps the emoji sequences: a ZWJ family and a heart with U+FE0F pass in a title.
    /// #917 S2b (QA r1144): a default is strict now, so the same text is refused there.
    func testTitleKeepsEmojiSequences() throws {
        let family = #"\U0001F468\u200D\U0001F469\u200D\U0001F467"#
        let heart = #"\u2764\uFE0F"#
        for text in [family, heart] {
            XCTAssertEqual(try parse(KitFixture.kit(replacing: #"title   = "Default repo (owner/name)""#, with: "title   = \"A \(text)\"")).refusals, [], text)
            try assertRefused(KitFixture.kit(replacing: #"default = """#, with: "default = \"\(text)\""), "settings[0].default", .controlCharacter)
        }
    }

    // MARK: #917 S2b (R917-s2a-q1, QA ruling r1144: display text is titles only)

    /// A choice value, a default and the homepage are strict: an invisible scalar there makes a look-alike value or link.
    func testValuesDefaultsAndHomepageAreStrict() throws {
        let setting = "kind    = \"string\"\ndefault = \"\""
        let choice = #"kind    = "choice"\#nvalues  = ["fast", "fa\u200Dst"]\#ndefault = "fast""#
        try assertRefused(KitFixture.kit(replacing: setting, with: choice), "settings[0].values[1]", .controlCharacter)
        let plain = #"kind    = "choice"\#nvalues  = ["fast", "slow"]\#ndefault = "fast""#
        XCTAssertEqual(try parse(KitFixture.kit(replacing: setting, with: plain)).refusals, [])
        try assertRefused(KitFixture.kit(replacing: #"default = """#, with: #"default = "on\uFE0F""#), "settings[0].default", .controlCharacter)
        try assertRefused(KitFixture.kit(replacing: #"homepage = "https://example.com/calm-agent""#, with: #"homepage = "https://example.com\uFE0F/""#),
                          "homepage", .controlCharacter)
        XCTAssertFalse(KitManifest.isDisplayPath("homepage"))
        XCTAssertFalse(KitManifest.isDisplayPath("settings[0].default"))
        XCTAssertFalse(KitManifest.isDisplayPath("settings[0].values[1]"))
        XCTAssertTrue(KitManifest.isDisplayPath("settings[0].title"))
    }

    // MARK: #917 S2b needs (G1)

    private static let guardID = #"id      = "guard""#

    func testNeedsUnknownIDRefused() throws {
        func guardNeeds(_ list: String) -> String { KitFixture.kit(replacing: Self.guardID, with: Self.guardID + "\nneeds   = " + list) }
        let ok = try parse(guardNeeds(#"["tools", "rules"]"#))
        XCTAssertEqual(ok.refusals, [])
        XCTAssertEqual(ok.kit.pieces.first { $0.id == "guard" }?.needs, ["tools", "rules"])
        XCTAssertEqual(ok.kit.pieces.first { $0.id == "tools" }?.needs, [])
        try assertRefused(guardNeeds(#"["nope"]"#), "guard.needs", .unknownNeed)
        try assertRefused(guardNeeds(#"["tools", "tools"]"#), "pieces[2].needs", .duplicateNeed)
        try assertRefused(guardNeeds(#"["-rules"]"#), "pieces[2].needs", .badID)
        try assertRefused(guardNeeds(#"["Rules"]"#), "pieces[2].needs", .badID)
        try assertRefused(guardNeeds(#""tools""#), "pieces[2].needs", .wrongType)
        // strict text: an invisible scalar in a need is refused by the text rule too
        try assertRefused(guardNeeds(#"["to\u200Dols"]"#), "pieces[2].needs[0]", .controlCharacter)
        let many = "[" + (0...64).map { "\"n\($0)\"" }.joined(separator: ", ") + "]"
        try assertRefused(guardNeeds(many), "pieces[2].needs", .tooManyNeeds)
        XCTAssertEqual(KitReason.unknownNeed.rawValue, "needs names a piece id this kit does not have")
        XCTAssertEqual(KitReason.needsCycle.rawValue, "needs form a cycle: a piece needs itself, directly or through other pieces")
        XCTAssertEqual(KitReason.localImportMissing.rawValue, "one claude-md piece must import @{{kit_config}}/local.md as its last line")
        XCTAssertEqual(KitReason.localImportTwice.rawValue, "only one claude-md piece may import @{{kit_config}}/local.md, and only once")
        XCTAssertEqual(KitReason.localPieceStaysOn.rawValue, "the piece that imports local.md stays on while another claude-md piece is on")
    }

    /// a needs b needs a; a needs a; a chain as long as the piece cap passes, closed into a ring it is refused, no trap.
    func testNeedsCycleRefused() throws {
        let hudID = #"id          = "hud""#
        let pair = KitFixture.kit(replacing: Self.guardID, with: Self.guardID + #"\#nneeds   = ["hud"]"#)
            .replacingOccurrences(of: hudID, with: hudID + #"\#nneeds       = ["guard"]"#)
        XCTAssertEqual(Set(try parse(pair).refusals),
                       [KitRefusal(subject: "guard.needs", reason: .needsCycle), KitRefusal(subject: "hud.needs", reason: .needsCycle)])
        XCTAssertEqual(try parse(KitFixture.kit(replacing: Self.guardID, with: Self.guardID + #"\#nneeds   = ["guard"]"#)).refusals,
                       [KitRefusal(subject: "guard.needs", reason: .needsCycle)])
        func chain(ring: Bool) -> String {
            let n = KitManifest.maxPieces
            return "[contributes.kit]\nschema = 1\n" + (0..<n).map { i in
                let next = i + 1 < n ? "p\(i + 1)" : (ring ? "p0" : "")
                return "\n[[contributes.kit.pieces]]\nid = \"p\(i)\"\nkind = \"permissions\"\nallow = [\"Read(*)\"]\n"
                    + (next.isEmpty ? "" : "needs = [\"\(next)\"]\n")
            }.joined()
        }
        let line = try parse(chain(ring: false))
        XCTAssertEqual(line.refusals, [])
        XCTAssertEqual(line.kit.pieces.count, KitManifest.maxPieces)
        let ring = try parse(chain(ring: true)).refusals
        XCTAssertEqual(ring.count, KitManifest.maxPieces)
        XCTAssertTrue(ring.allSatisfy { $0.reason == .needsCycle }, "\(ring)")
    }

    /// Permission rules and matchers: strict, U+00A0 and U+FE0F refused, no allow-list (not even the display one).
    func testRulesAndMatchersAreStrict() throws {
        for u in ["00A0", "FE0F", "200C", "200D", "034F", "3164", "202F"] {
            let esc = "\\u" + u
            try assertRefused(KitFixture.kit(replacing: #"allow = ["Bash(calm-note:*)"]"#, with: "allow = [\"Bash(calm\(esc)note:*)\"]"), "pieces[4].allow[0]", .controlCharacter)
            try assertRefused(KitFixture.kit(replacing: #"deny  = ["Bash(rm -rf:*)"]"#, with: "deny  = [\"Bash(rm\(esc)-rf:*)\"]"), "pieces[4].deny[0]", .controlCharacter)
            try assertRefused(KitFixture.kit(replacing: "ask   = []", with: "ask   = [\"Bash(a\(esc)b)\"]"), "pieces[4].ask[0]", .controlCharacter)
            try assertRefused(KitFixture.kit(replacing: #"matcher = "Bash""#, with: "matcher = \"Ba\(esc)sh\""), "pieces[2].matcher", .controlCharacter)
        }
    }

    /// The classes are exact: display refuses what strict refuses except three scalars; both keep the S1 list.
    func testDisplayAllowListIsThreeScalars() throws {
        XCTAssertEqual(KitManifest.displayAllowed, [0x200C, 0x200D, 0xFE0F])
        var onlyStrict: Set<UInt32> = []
        for v in UInt32(0)...0x10FFFF {
            guard let u = Unicode.Scalar(v) else { continue }
            let s = String(Character(u))
            if KitManifest.isDisplayText(s) != KitManifest.isStrictText(s) { onlyStrict.insert(v) }
            if KitManifest.isControlScalar(u) { XCTAssertFalse(KitManifest.isStrictText(s) || KitManifest.isDisplayText(s), String(v, radix: 16)) }
        }
        XCTAssertEqual(onlyStrict, [0x200C, 0x200D, 0xFE0F])
    }

    /// The homepage must show its host: form -> passes (true) or is refused (false); a pure string check.
    func testHomepageHostIsTheHost() throws {
        let old = #"homepage = "https://example.com/calm-agent""#
        let table: [(String, Bool)] = [
            ("https://example.com", true), ("https://example.com/a?x=1#y", true), ("https://example.com:8443/x", true),
            ("https://example.com:65535", true), ("https://example.com:1", true), ("https://[::1]:443/x", true),
            ("https://example.com/p@th", true), ("https://example.com?q=a@b", true),
            ("https://a.example@b.example", false), ("https://a:pw@b.example", false), ("https://a.example@b.example/x", false),
            ("https://example.com:0", false), ("https://example.com:65536", false), ("https://example.com:", false),
            ("https://example.com:80a", false), ("https://example.com:123456", false), ("https://example.com:99999999999999999999", false),
            ("https:///x", false), ("https://example.com\\\\@evil.example", false),
        ]
        for (form, ok) in table {
            let refusals = try parse(KitFixture.kit(replacing: old, with: "homepage = \"\(form)\"")).refusals
            XCTAssertEqual(refusals.contains(KitRefusal(subject: "homepage", reason: .badHomepage)), !ok, form)
        }
    }
}
