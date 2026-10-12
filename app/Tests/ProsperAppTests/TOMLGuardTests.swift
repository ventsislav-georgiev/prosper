import CryptoKit
import TOMLDecoder
import XCTest
@testable import ProsperApp

/// QA #107, #125: dduan/TOMLDecoder recurses without a depth limit, so deep nesting
/// SIGSEGVs the process. Every trapping text here is checked against `TOMLGuard`
/// FIRST and the routing tests bail before calling a site if the guard would let
/// it through — handing one to the real decoder would kill the whole xctest run.
/// No test here calls `TOMLDecoder` on a text the guard rejects.
final class TOMLGuardTests: XCTestCase {

    // Generated trapping shapes (sizes from the QA report).
    private let inlineTables = "a = " + String(repeating: "{b = ", count: 3000) + "1" + String(repeating: "}", count: 3000)
    private let arrays = "a = " + String(repeating: "[", count: 5000) + "1" + String(repeating: "]", count: 5000)
    private let dottedKey = Array(repeating: "a", count: 5000).joined(separator: ".") + " = 1"
    private let unclosed = "a = " + String(repeating: "[", count: 5000)
    private let oversized = "a = \"" + String(repeating: "x", count: 1 << 20) + "\""

    private var trapping: [(String, String)] {
        [("inline tables", inlineTables), ("arrays", arrays), ("dotted key", dottedKey),
         ("unclosed", unclosed), ("over 1 MiB", oversized)] + Self.qa125.map { ($0.name, $0.text) }
    }

    // QA #125's four crashing inputs, regenerated in code with gen-inputs.py's shapes; size
    // and sha256 are the ones in QA's inputs-sha256.txt (checked in testReplaysQA125Inputs).
    private static func key(_ dots: Int) -> String { Array(repeating: "a", count: dots + 1).joined(separator: ".") }
    private static func inlineCombo(levels: Int, dots: Int) -> String {
        "{" + String(repeating: key(dots) + " = {", count: levels - 1) + key(dots) + " = 1" + String(repeating: "}", count: levels)
    }
    /// `"""x\\"""` closes for a guard that skips `\\` as a pair; TOMLDecoder runs on to `b = """`.
    private static let desync = "\"\"\"x\\\\\"\"\"\nb = \"\"\"\n"
    private static let arrays5000 = "c = " + String(repeating: "[", count: 5000) + "1" + String(repeating: "]", count: 5000) + "\n"
    private static let qa125: [(name: String, text: String, bytes: Int, sha256: String)] = [
        ("d_a1_combo64x48", key(48) + " = " + inlineCombo(levels: 64, dots: 48) + "\n", 6630,
         "6df429209691262480451aad1daedee12d9287f28edac8490c8e6886192ec5d8"),
        ("d_a1_combo64x64", key(64) + " = " + inlineCombo(levels: 64, dots: 64) + "\n", 8710,
         "e0ca1e263915f1aa1eb7ef993aaf4a8289a08a633aa2bdc3264ba996c877b063"),
        ("d_b12_bypass_arrays5000", "a = " + desync + arrays5000, 10028,
         "a6f89e1f3e4a4800b9a98c7392e41f7b05cd168d2106ec2996b5fb248afe680a"),
        ("d_b12_bypass_ext_manifest", "id = " + desync + arrays5000, 10029,
         "a7b9cb8d98e947ec3d1018e83d598eec48fc3bb5764d664112de92f660eed391"),
    ]

    func testReplaysQA125Inputs() {
        for row in Self.qa125 {
            let data = Data(row.text.utf8)
            XCTAssertEqual(data.count, row.bytes, row.name)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), row.sha256, row.name)
            XCTAssertFalse(TOMLGuard.accepts(row.text), row.name)
        }
    }

    func testRejectsTrappingShapes() {
        for (name, text) in trapping {
            XCTAssertFalse(TOMLGuard.accepts(text), name)
        }
    }

    func testAcceptsLegitDocuments() {
        let d = TOMLGuard.maxDepth
        let cases: [(String, String)] = [
            ("64-deep arrays", "a = " + String(repeating: "[", count: d) + "1.5" + String(repeating: "]", count: d)),
            ("64-segment dotted key", Array(repeating: "a", count: d + 1).joined(separator: ".") + " = 1"),
            ("brackets in strings", "a = \"[[[[[[{{{{\"\nb = 'x[[[['\nc = \"\"\"\n[[[[\n{{{{\n\"\"\"\nd = '''\n[[[['''"),
            ("brackets in comment", "# {{{{ [[[[\na = 1 # ]]]] [[[["),
            ("escaped quote", "a = \"\\\"[[[[\"\nb = 1"),
            ("floats and dates", "a = [1.5, 2.25, 3.0]\nb = 1979-05-27T07:32:00.999Z"),
        ]
        for (name, text) in cases {
            XCTAssertTrue(TOMLGuard.accepts(text), name)
        }
        // Strings must actually hide their brackets: the same text with 65 of them in a string.
        XCTAssertTrue(TOMLGuard.accepts("a = \"" + String(repeating: "[", count: d + 1) + "\""))
        XCTAssertFalse(TOMLGuard.accepts("a = " + String(repeating: "[", count: d + 1)))
        // One budget: a dotted key's frames stay open under its value (QA #125).
        XCTAssertTrue(TOMLGuard.accepts(Self.key(d - 1) + " = {a = 1}"))
        XCTAssertFalse(TOMLGuard.accepts(Self.key(d) + " = {a = 1}"))
        // `,` and a newline end a value: the next key's dots count again.
        XCTAssertFalse(TOMLGuard.accepts("t = {a = 1, " + Self.key(d) + " = 1}"))
        XCTAssertFalse(TOMLGuard.accepts("a = 1\n" + Self.key(d + 1) + " = 1"))
        XCTAssertFalse(TOMLGuard.accepts("a = " + String(repeating: "{a.b = ", count: d / 2 + 1) + "1" + String(repeating: "}", count: d / 2 + 1)))
    }

    /// QA #160: a `}` restores the enclosing base, so a sibling key after a nested table's pop
    /// gets the whole budget back (a pop leaving base at the inner level over-rejects it).
    func testSiblingAfterNestedPopKeepsItsBudget() {
        let sibling = Array(repeating: "k", count: TOMLGuard.maxDepth).joined(separator: ".")   // 63 dots + the `{`: 64 frames
        let text = "t = {a = {b = 1}, " + sibling + " = 1}\n"
        XCTAssertTrue(TOMLGuard.accepts(text))
        XCTAssertNoThrow(try TOMLDecoder().decode(Empty.self, from: text))
    }

    /// Every bundled and example extension.toml passes the guard.
    func testAcceptsShippedManifests() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found = 0
        for root in ["Sources/ProsperApp/Resources/extensions", "Examples/extensions"] {
            let base = app.appendingPathComponent(root)
            let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard url.lastPathComponent == "extension.toml" else { continue }
                found += 1
                XCTAssertTrue(TOMLGuard.accepts(try String(contentsOf: url, encoding: .utf8)), url.path)
            }
        }
        XCTAssertGreaterThan(found, 5)
    }

    func testAcceptsStoreFixtures() {
        XCTAssertTrue(TOMLGuard.accepts("""
        model = "gemma"
        model_provider = "prosper"

        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]
        default_tools_approval_mode = "auto"

        [mcp_servers.remote_api]
        url = "https://api.example.com/mcp"
        bearer_token_env_var = "EXAMPLE_TOKEN"
        """))
        XCTAssertTrue(TOMLGuard.accepts("""
        model = "gemma"

        [[hooks.PreToolUse]]
        matcher = "Bash"

        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = "echo hi"
        timeout = 10
        """))
    }

    // MARK: Differential — the guard ends strings and comments where TOMLDecoder does

    private struct Empty: Decodable {}
    private static func dq(_ n: Int) -> String { String(repeating: "\"", count: n) }

    /// QA #125's quote, escape and comment shapes (gen-inputs.py s_b01..s_c02 with their
    /// 100-deep tail cut off), unterminated strings, and one-line rows that must not
    /// accumulate. `parses`: TOMLDecoder's verdict on the item alone.
    private static let corpus: [(name: String, text: String, parses: Bool)] = [
        ("s_b01 literal ends in backslash", "a = 'x\\'\n", true),
        ("s_b02 basic escaped backslash", "a = \"\\\\\" \n", true),
        ("s_b03 ml literal quotes inside", "a = '''x'y''z'''\n", true),
        ("s_b03b ml literal 4-quote close", "a = '''x''''\n", true),
        ("s_b03c ml literal 5-quote close", "a = '''x'''''\n", true),
        ("s_b04 ml basic 4-quote close", "a = " + dq(3) + "x" + dq(4) + "\n", true),
        ("s_b05 ml basic 5-quote close", "a = " + dq(3) + "x" + dq(5) + "\n", true),
        ("s_b05b ml basic 6-quote close", "a = " + dq(3) + "x" + dq(6) + "\n", true),
        ("s_b06 ml basic line-ending backslash", "a = " + dq(3) + "x \\\n   y" + dq(3) + "\n", true),
        ("s_b07 bare CR", "a = 1\r", false),
        ("s_b08 hash in quoted key", "\"k#x\" = 1\n", true),
        ("s_b09 unicode escape quote", "a = \"\\u0022\"\n", true),
        ("s_b09b unicode escape big", "a = \"\\U0001F600\"\n", true),
        ("s_b10 NUL in string", "a = \"x\u{0}\"\n", true),
        ("s_b10b NUL in code", "a = 1\u{0}\n", false),
        ("s_b11 BOM", "\u{FEFF}", false),
        ("s_b12 ml basic escaped backslash close", "a = " + TOMLGuardTests.desync, true),
        ("s_b12b same, then a closed string", "a = " + TOMLGuardTests.desync + "z = " + dq(3) + "\n" + dq(3) + "\n", true),
        ("s_c01 closers inside the desynced string", "c = " + String(repeating: "[", count: 60) + dq(3) + "x\\\\" + dq(3)
            + String(repeating: "]", count: 60) + dq(3) + String(repeating: "]", count: 60) + "\n", true),
        ("s_c02 empty prefix", "", true),
        ("escaped quote", "a = \"\\\"\"\n", true),
        ("comment with apostrophes", "# it's a comment\na = 1 # don't\n", true),
        ("comment with a triple quote", "# " + dq(3) + "\n", true),
        ("70 floats on one line", "a = [" + (0..<70).map { "\($0).5" }.joined(separator: ", ") + "]\n", true),
        ("70 dotted keys in one inline table", "t = {" + (0..<70).map { "k\($0).x = \($0)" }.joined(separator: ", ") + "}\n", true),
        ("unterminated basic", "a = \"x\nb = 1\n", false),
        ("unterminated basic at EOF after backslash", "a = \"x\\", false),
        ("unterminated literal", "a = 'x\nb = 1\n", false),
        ("unterminated ml basic", "a = " + dq(3) + "x\n", false),
        ("unterminated ml literal", "a = '''x\n", false),
        // QA #160: a bare triple quote at EOF, where the multi-line open condition differs per quote.
        ("bare ml basic open at EOF", "a = " + dq(3), false),
        ("bare ml literal open at EOF", "a = '''", false),
    ]

    /// Every corpus item the parser decodes, the guard accepts; every corpus item with a
    /// 200-deep tail, the guard rejects. After an item that decodes, TOMLDecoder is in code,
    /// so the tail is code to it, and the item again after the tail closes anything a
    /// desynced guard opened. TOMLDecoder only ever sees a shallow item the guard accepted.
    func testGuardAgreesWithParserOnStringsAndComments() {
        let tail = "z = " + String(repeating: "[", count: 200) + "1" + String(repeating: "]", count: 200) + "\n"
        for (name, text, parses) in Self.corpus {
            XCTAssertFalse(TOMLGuard.accepts(text + tail), "\(name) + deep tail")
            if parses { XCTAssertFalse(TOMLGuard.accepts(text + tail + text), "\(name) + deep tail + \(name)") }
            if TOMLGuard.accepts(text) {
                let decoded = (try? TOMLDecoder().decode(Empty.self, from: text)) != nil
                XCTAssertEqual(decoded, parses, "\(name): parser verdict")
            } else {
                XCTAssertFalse(parses, "\(name): guard rejects a text the parser decodes")
            }
        }
    }

    /// True when `source` builds a TOML parser some way other than `TOMLDecoder().decodeGuarded(`,
    /// or takes or returns a decoder (a parameter or return type), which hides where it decodes.
    private static func hasRawDecode(_ source: String) -> Bool {
        func count(_ pattern: String) -> Int {
            (try? NSRegularExpression(pattern: pattern))?
                .numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) ?? 0
        }
        return count(#"TOMLDecoder\s*(\.init)?\s*\("#) != count(#"TOMLDecoder\(\)\.decodeGuarded\("#)
            || count(#"TOMLTable\s*(\.init)?\s*\("#) > 0
            || count(#"(:|->)\s*(inout\s+)?TOMLDecoder\b"#) > 0
    }

    func testRawDecodeScanCatchesEveryShape() {
        for raw in ["TOMLDecoder().decode(T.self, from: s)", "let d = TOMLDecoder()\nlet x = try d.decode(T.self, from: s)",
                    "TOMLDecoder.init().decode(T.self, from: s)", "TOMLDecoder(isLenient: false).decode(T.self, from: s)",
                    "try TOMLTable(source: s)", "try TOMLTable.init(source: s)",
                    "func load(_ d: TOMLDecoder) throws -> T { try d.decode(T.self, from: s) }",
                    "func load(d: inout TOMLDecoder) {}", "func make() -> TOMLDecoder { shared }"] {
            XCTAssertTrue(Self.hasRawDecode(raw), raw)
        }
        XCTAssertFalse(Self.hasRawDecode("try TOMLDecoder().decodeGuarded(T.self, from: s) // dduan/TOMLDecoder"))
    }

    /// Scans every Swift file under Sources/ (any target) that imports the decoder: files
    /// calling the raw decoder, and the count of guarded calls.
    private func decodeSites() throws -> (raw: [String], guarded: Int) {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var raw: [String] = [], guarded = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "TOMLGuard.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.range(of: #"import\s+TOMLDecoder\b"#, options: .regularExpression) != nil else { continue }
            if Self.hasRawDecode(text) { raw.append(url.path.replacingOccurrences(of: sources.path + "/", with: "")) }
            guarded += text.components(separatedBy: "TOMLDecoder().decodeGuarded(").count - 1
        }
        return (raw, guarded)
    }

    /// Precondition of every routing test: the guard rejects the text AND no site calls
    /// the raw decoder. Either failing means the site would hand trapping text to
    /// `TOMLDecoder` and SIGSEGV the run, so the test fails instead of calling it.
    private func safeToCallSites() throws -> Bool {
        for (name, text) in trapping where TOMLGuard.accepts(text) {
            XCTFail("guard let \(name) through; not calling the sites")
            return false
        }
        let sites = try decodeSites()
        guard sites.raw.isEmpty, sites.guarded == 3 else {
            XCTFail("unguarded decode in \(sites.raw), guarded=\(sites.guarded); not calling the sites")
            return false
        }
        return true
    }

    /// Structural: no app source calls the raw decoder, so a site that drops the guard
    /// fails here without any trapping text ever reaching `TOMLDecoder`.
    func testNoSourceBypassesTheGuard() throws {
        let sites = try decodeSites()
        XCTAssertEqual(sites.raw, [])
        XCTAssertEqual(sites.guarded, 3)
    }

    // MARK: Routing — each site takes its malformed-TOML path

    func testMCPImportRoutesRejectedTextToMalformedPath() throws {
        guard try safeToCallSites() else { return }
        for (name, text) in trapping {
            XCTAssertTrue(MCPConfigStore.importServers(from: text).isEmpty, name)
        }
    }

    func testHooksImportRoutesRejectedTextToMalformedPath() throws {
        guard try safeToCallSites() else { return }
        for (name, text) in trapping {
            XCTAssertTrue(HooksConfigStore.importHooks(from: text).isEmpty, name)
        }
    }

    func testExtensionLoaderRoutesRejectedTextToParseError() throws {
        guard try safeToCallSites() else { return }
        let dir = tempDir("prosper-tomlguard")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in trapping {
            try text.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ExtensionLoader.load(directory: dir, isSystem: false, hostVersion: "2.0.0"), name) { error in
                guard case .parse? = error as? ExtensionLoadError else { return XCTFail("\(name): \(error)") }
            }
        }
    }
}
