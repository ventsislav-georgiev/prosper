import Foundation
import XCTest
@testable import ProsperApp

/// #1564 (X7 b, spec v2.1 2.6): `[[contributes.xrefs]]` decode, the load-time refusals, live-only rules with
/// rulesVersion, and the pure matcher. Every fixture is a literal manifest under a tempDir(); no shipped extension.toml,
/// no Lua run, no window.
@MainActor
final class XrayExtensionRefsTests: XCTestCase {

    private func manifest(_ id: String, _ contributes: String) -> String {
        """
        [extension]
        id = "\(id)"
        name = "fixture"
        title = "Fixture"
        description = "xrefs fixture"
        version = "1.0.0"
        author = "Example"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        \(contributes)
        """
    }

    /// Writes each (id, contributes) as a user extension folder under `root`.
    private func write(_ root: URL, _ exts: [(String, String)]) throws {
        for (id, contributes) in exts {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try manifest(id, contributes).write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            try "".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        }
    }

    private func load(_ id: String, _ contributes: String) throws -> LoadedExtension {
        let root = tempDir("xrefs-load")
        try write(root, [(id, contributes)])
        return try ExtensionLoader.load(directory: root.appendingPathComponent(id), isSystem: false, hostVersion: "2.0.0")
    }

    private func registry(_ exts: [(String, String)], trusted: [String]) throws -> ExtensionRegistry {
        let root = tempDir("xrefs-registry")
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("system"), withIntermediateDirectories: true)
        try write(user, exts)
        let defaults = scratchDefaults("xrefs-registry")
        defaults.set(trusted, forKey: "trustedExtensionIDs")   // present, so nothing is grandfathered in
        let registry = ExtensionRegistry(systemDir: root.appendingPathComponent("system", isDirectory: true), userDir: user,
                                         hostVersion: "2.0.0", defaults: defaults, services: LaunchRecordingServices())
        registry.discover()
        return registry
    }

    private static let refusing = """
        [[contributes.xrefs]]
        id = "good"
        template = "DEMO-{n}"
        label = "Demo tracker"
        in_code = "whole"
        handler = "resolve_demo"
        timeout = 5

        [[contributes.xrefs]]
        id = "adjacent"
        template = "{id}{n}"

        [[contributes.xrefs]]
        id = "in-class"
        template = "{id}a{id}"

        [[contributes.xrefs]]
        id = "folded"
        template = "{KEY}x{n}"

        [[contributes.xrefs]]
        id = "four"
        template = "A{n}-{n}-{n}-{n}"

        [[contributes.xrefs]]
        id = "long"
        template = "LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL-{n}"

        [[contributes.xrefs]]
        id = "literal"
        template = "DEMO-1"

        [[contributes.xrefs]]
        id = "dup"
        template = "DEMO-{n}"

        [[contributes.xrefs]]
        id = "builtin"
        template = "{sha}"

        [[contributes.xrefs]]
        id = "slow"
        template = "SLOW-{n}"
        timeout = 11

        [[contributes.xrefs]]
        id = "where"
        template = "WHERE-{n}"
        in_code = "always"

        [[contributes.xrefs]]
        id = "typed"
        template = "TYPED-{n}"
        timeout = "3"

        [[contributes.xrefs]]
        id = "listy"
        template = "LIST-{n}"
        handler = ["a"]

        [[contributes.xrefs]]
        template = "NOID-{n}"

        [[contributes.xrefs]]
        id = "plain"
        template = "{repo}#{n}"
        """

    /// Each refusal is one line, names its rule and reason, and skips only that rule: the extension loads and its two
    /// good rules are kept with their fields (timeout and in_code defaults on the second).
    func testEachRefusalIsOneLineAndTheExtensionLoads() throws {
        let ext = "com.example.kit.refuse"
        let loaded = try load(ext, Self.refusing)
        XCTAssertEqual(loaded.manifest.contributes?.xrefs?.rows.count, 15)
        let c = XrayExtensionRefs.compile([(ext, loaded.manifest.contributes?.xrefs)])
        let p = "extension \(ext): xref "
        XCTAssertEqual(c.refusals, [
            p + "adjacent refused (two placeholders with no literal between them)",
            p + "in-class refused (a literal after {id} starts with a char it takes)",
            p + "folded refused (a literal after {KEY} starts with a char it takes)",
            p + "four refused (more than 3 placeholders)",
            p + "long refused (template over 64 chars)",
            p + "literal refused (literals only)",
            p + "dup refused (duplicate of a loaded rule)",
            p + "builtin refused (unknown placeholder {sha})",
            p + "slow refused (timeout must be 1..10)",
            p + "where refused (in_code must be \"never\" or \"whole\")",
            p + "typed refused (timeout must be 1..10)",
            p + "listy refused (unreadable handler)",
            p + "#14 refused (no id)",
        ])
        XCTAssertEqual(c.rules.map(\.id), ["good", "plain"])
        let good = try XCTUnwrap(c.rules.first)
        XCTAssertEqual(good.extensionID, ext)
        XCTAssertEqual(good.template, "DEMO-{n}")
        XCTAssertEqual(good.label, "Demo tracker")
        XCTAssertEqual(good.inCode, .whole)
        XCTAssertEqual(good.handler, "resolve_demo")
        XCTAssertEqual(good.timeout, 5)
        let plain = try XCTUnwrap(c.rules.last)
        XCTAssertEqual(plain.label, "plain")
        XCTAssertEqual(plain.inCode, .never)
        XCTAssertTrue(plain.handler == nil)
        XCTAssertEqual(plain.timeout, 3)
    }

    /// The template boundary: exactly 64 chars loads, 65 is refused.
    func testTemplateLengthBoundary() throws {
        let at64 = String(repeating: "L", count: 60) + "-{n}"
        XCTAssertEqual(at64.count, 64)
        XCTAssertEqual(try XrayExtensionRefs.pieces(at64).count, 2)
        XCTAssertThrowsError(try XrayExtensionRefs.pieces("L" + at64))
        XCTAssertEqual(try XrayExtensionRefs.pieces("A{n}-{n}-{n}").count, 6)
    }

    /// `xrefs` that is not an array refuses with one line and the extension still loads.
    func testXrefsNotAnArrayKeepsTheExtension() throws {
        let ext = "com.example.kit.notlist"
        let loaded = try load(ext, "[contributes]\nxrefs = \"x\"")
        let c = XrayExtensionRefs.compile([(ext, loaded.manifest.contributes?.xrefs)])
        XCTAssertEqual(c.refusals, ["extension \(ext): xrefs ignored (not an array of tables)"])
        XCTAssertTrue(c.rules.isEmpty)
    }

    /// 17 rules in one extension keep 16; 5 extensions of 16 keep 64; each overflow row is one line.
    func testCapsPerExtensionAndInTotal() throws {
        func rows(_ prefix: String, _ n: Int) throws -> XrefList? {
            let toml = (0..<n).map { "[[contributes.xrefs]]\nid = \"r\($0)\"\ntemplate = \"\(prefix)R\($0)-{n}\"\n" }.joined(separator: "\n")
            return try load("com.example.kit.\(prefix.lowercased())", toml).manifest.contributes?.xrefs
        }
        let one = XrayExtensionRefs.compile([("com.example.kit.a", try rows("A", 17))])
        XCTAssertEqual(one.rules.count, 16)
        XCTAssertEqual(one.refusals, ["extension com.example.kit.a: xref r16 refused (more than 16 rules in this extension)"])

        let five = XrayExtensionRefs.compile(try ["B", "C", "D", "E", "F"].map { ("com.example.kit.\($0.lowercased())", try rows($0, 16)) })
        XCTAssertEqual(five.rules.count, 64)
        XCTAssertEqual(five.refusals.count, 16)
        XCTAssertEqual(five.refusals.first, "extension com.example.kit.f: xref r0 refused (more than 64 rules in total)")
        XCTAssertEqual(Set(five.rules.map(\.extensionID)), ["com.example.kit.b", "com.example.kit.c", "com.example.kit.d",
                                                            "com.example.kit.e"])
    }

    // MARK: - Registry

    private static let oneRule = "[[contributes.xrefs]]\nid = \"demo\"\ntemplate = \"DEMO-{n}\"\nhandler = \"resolve_demo\"\n"

    /// An untrusted extension adds no rule; trusting it adds its rule, untrusting takes it away.
    func testUntrustedExtensionAddsNoRule() throws {
        let ext = "com.example.kit.untrusted"
        let reg = try registry([(ext, Self.oneRule)], trusted: [])
        XCTAssertEqual(reg.record(id: ext)?.enabled, true)
        XCTAssertEqual(reg.record(id: ext)?.trusted, false)
        XCTAssertTrue(reg.xrefRules.isEmpty)
        try reg.trust(id: ext)
        XCTAssertEqual(reg.xrefRules.map(\.id), ["demo"])
        try reg.untrust(id: ext)
        XCTAssertTrue(reg.xrefRules.isEmpty)
    }

    /// rulesVersion bumps on disable, enable and reload (discover); a disabled extension adds no rule; a refused row
    /// leaves the trusted extension live with its good rule.
    func testRulesVersionBumpsOnEnableDisableAndReload() throws {
        let ext = "com.example.kit.live"
        let reg = try registry([(ext, Self.oneRule + "\n[[contributes.xrefs]]\nid = \"bad\"\ntemplate = \"{id}{n}\"\n")],
                               trusted: [ext])
        XCTAssertEqual(reg.record(id: ext)?.isLive, true)
        XCTAssertEqual(reg.xrefRules.map(\.id), ["demo"])
        let v0 = reg.rulesVersion
        try reg.setEnabled(false, id: ext)
        let v1 = reg.rulesVersion
        XCTAssertGreaterThan(v1, v0)
        XCTAssertTrue(reg.xrefRules.isEmpty)
        try reg.setEnabled(true, id: ext)
        let v2 = reg.rulesVersion
        XCTAssertGreaterThan(v2, v1)
        XCTAssertEqual(reg.xrefRules.map(\.id), ["demo"])
        reg.discover()
        XCTAssertGreaterThan(reg.rulesVersion, v2)
        XCTAssertEqual(reg.xrefRules.map(\.id), ["demo"])
    }

    // MARK: - Matcher

    private func rule(_ template: String, inCode: XrayExtensionRule.InCode = .never) throws -> XrayExtensionRule {
        XrayExtensionRule(extensionID: "com.example.kit", id: "r", template: template, label: "r", inCode: inCode,
                          handler: "resolve", timeout: 3, pieces: try XrayExtensionRefs.pieces(template))
    }

    /// Spans, parts and ranges; literals ignore case, placeholders keep theirs; a span never touches a letter, number
    /// or `_`; `{n}` takes at most 7 digits.
    func testMatcherSpansPartsAndWordBoundaries() throws {
        let oq = try rule("OQ-{n}")
        let line = "see oq-245, OQ-7 and xOQ-8 or OQ-12a _OQ-3 OQ-12345678 (OQ-9)"
        let m = XrayExtensionRefs.matches(of: oq, in: line)
        XCTAssertEqual(m.map(\.text), ["oq-245", "OQ-7", "OQ-9"])
        XCTAssertEqual(m.map(\.parts), [["245"], ["7"], ["9"]])
        XCTAssertEqual(m.map { String(line[$0.range]) }, ["oq-245", "OQ-7", "OQ-9"])
        XCTAssertTrue(m.allSatisfy { $0.rule == oq })

        let repo = try rule("{repo}#{n}")
        let r = XrayExtensionRefs.matches(of: repo, in: "acme/web#12, web#3 and é#4")
        XCTAssertEqual(r.map(\.parts), [["acme/web", "12"], ["web", "3"]])

        let key = try rule("{KEY}-{n}")
        XCTAssertEqual(XrayExtensionRefs.matches(of: key, in: "PAY-12 utf-8 Pay-3 ABCDEFGHIJK-1").map(\.text), ["PAY-12"])

        // a template ending in a literal: the boundary after it holds too
        let rc = try rule("RC{n}-x")
        XCTAssertEqual(XrayExtensionRefs.matches(of: rc, in: "RC1-x RC2-xy rc3-X.").map(\.text), ["RC1-x", "rc3-X"])
    }

    /// The last placeholder backs off to a word boundary as a regex would: 63 letters then "-b" match the letters.
    func testLastPlaceholderBacksOffToABoundary() throws {
        let t = try rule("T-{id}")
        let letters = String(repeating: "a", count: 63)
        let m = XrayExtensionRefs.matches(of: t, in: "T-" + letters + "-b")
        XCTAssertEqual(m.map(\.parts), [[letters]])
        XCTAssertEqual(XrayExtensionRefs.matches(of: t, in: "T-x.y end").map(\.text), ["T-x.y"])
    }

    /// In a code line a "never" rule finds nothing; a "whole" rule only the whole trimmed line.
    func testInCode() throws {
        let never = try rule("DEMO-{n}"), whole = try rule("DEMO-{n}", inCode: .whole)
        XCTAssertTrue(XrayExtensionRefs.matches(of: never, in: "DEMO-5", isCode: true).isEmpty)
        XCTAssertEqual(XrayExtensionRefs.matches(of: never, in: "DEMO-5").map(\.text), ["DEMO-5"])
        XCTAssertEqual(XrayExtensionRefs.matches(of: whole, in: "  DEMO-5 ", isCode: true).map(\.text), ["DEMO-5"])
        XCTAssertTrue(XrayExtensionRefs.matches(of: whole, in: "run DEMO-5", isCode: true).isEmpty)
    }
}
