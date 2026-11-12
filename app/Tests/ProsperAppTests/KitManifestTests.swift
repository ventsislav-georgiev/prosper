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
}
