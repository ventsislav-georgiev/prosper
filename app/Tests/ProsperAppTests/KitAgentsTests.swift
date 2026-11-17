import Foundation
import XCTest
@testable import ProsperApp

// #920: the agents piece kind. KitRuntime over the real KitStore and a real ManagedConfig, every root (the claude: home
// the agents land in, the config home, the state dir, the kit source) under the row's own tempDir(). Fakes only: the
// agent files are example workers; no kit file is ever run.

final class KitAgentsTests: XCTestCase {
    static let ext = "com.example.kit"

    /// name, description, model, effort, tools (a comma-separated string), then an unknown key; em dashes; no final newline
    static let high = "---\nname: worker-example-high\ndescription: Example worker for heavy tasks \u{2014} a fake.\nmodel: opus\n"
        + "effort: high\ntools: Read, Grep, Glob, Bash\nomitClaudeMd: true\n---\n\nYou are an example worker \u{2014} fakes only."
    static let low = "---\nname: worker-example-low\ndescription: Example worker for light tasks.\nmodel: haiku\neffort: low\n"
        + "tools: Read, Grep\n---\n\nYou are a light example worker.\n"

    static let kit = """
    [contributes.kit]
    schema = 1

    [[contributes.kit.pieces]]
    id    = "perms"
    kind  = "permissions"
    allow = ["Bash(ls:*)"]

    [[contributes.kit.pieces]]
    id   = "workers"
    kind = "agents"
    """

    struct Env {
        let root: URL
        let roots: ManagedConfigRoots
        let provider: ManagedConfigProvider
        var agents: URL { roots.claude.appendingPathComponent("agents", isDirectory: true) }
        func agent(_ name: String) -> URL { agents.appendingPathComponent(name + ".md") }
    }

    private func env(label: String = #function) throws -> Env {
        let root = tempDir(label)
        let roots = ManagedConfigRoots(claude: root.appendingPathComponent("claude home", isDirectory: true),
                                       configHome: root.appendingPathComponent("config", isDirectory: true),
                                       stateDir: root.appendingPathComponent("state", isDirectory: true))
        for d in [roots.claude, roots.configHome] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("{}\n".utf8).write(to: roots.claude.appendingPathComponent("settings.json"))
        let clock = MCClock()
        let mc = ManagedConfig(roots: roots, consent: KitRTConsent(), writer: ManagedConfigPOSIXWriter(), now: { clock.now() })
        return Env(root: root, roots: roots, provider: ManagedConfigProvider(mc))
    }

    private func runtime(_ e: Env) throws -> KitRuntime {
        KitRuntime(provider: e.provider, store: try KitStore(configHome: e.roots.configHome, extID: Self.ext), isTrusted: { _ in true }, now: { Date() })
    }

    /// A kit source with a permissions piece and an agents piece shipping `agents` (file name -> text).
    private func source(_ e: Env, agents: [String: String] = ["worker-example-high.md": high, "worker-example-low.md": low]) throws -> LoadedExtension {
        let dir = e.root.appendingPathComponent("sources/agents-kit", isDirectory: true)
        let head = KitFixture.head.replacingOccurrences(of: "\"dev.example.kit.calm-agent\"", with: "\"\(Self.ext)\"")
            .replacingOccurrences(of: "\"2.170.0\"", with: "\"0.0.1\"") // any host the test bundle reports loads it
        var files = ["extension.toml": head + "\n" + Self.kit + "\n", "README.md": KitDirFixture.readme, "init.lua": "return {}\n"]
        for (name, text) in agents { files["agents/" + name] = text }
        for (rel, text) in files {
            let u = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
        return LoadedExtension(manifest: try KitFixture.manifest(Self.kit, head: head), directory: dir, isSystem: false)
    }

    private func sha(_ u: URL) -> String? { (try? Data(contentsOf: u)).map { OrderedJSON.sha256(Array($0)) } }
    private func exists(_ u: URL) -> Bool { KitPOSIXFS().kind(u.path) != .missing }

    // MARK: install

    func testTwoAgentFilesInstallAndHashEqual() async throws {
        let e = try env()
        let rt = try runtime(e)
        let ext = try source(e)
        let r = await rt.apply(ext)
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        for name in ["worker-example-high", "worker-example-low"] {
            let piece = ext.directory.appendingPathComponent("agents/\(name).md")
            XCTAssertTrue(sha(e.agent(name)) != nil, "\(name) installed")
            XCTAssertEqual(sha(e.agent(name)), sha(piece), "\(name): the installed file hashes as the kit's piece")
        }
        XCTAssertEqual(rt.status(ext)?.agents, ["workers": "installed"])

        let removed = await rt.remove(ext)
        XCTAssertEqual(removed.config?.status, .done, removed.config?.message ?? "")
        XCTAssertFalse(exists(e.agent("worker-example-high")), "uninstall removes the kit's file")
        XCTAssertFalse(exists(e.agent("worker-example-low")))
    }

    func testEmDashesAndAnUnknownKeySurviveByteForByte() async throws {
        let e = try env()
        let rt = try runtime(e)
        let ext = try source(e, agents: ["worker-example-high.md": Self.high])
        let r = await rt.apply(ext)
        XCTAssertEqual(r.failures, [])
        let installed = try Data(contentsOf: e.agent("worker-example-high"))
        XCTAssertEqual(installed, Data(Self.high.utf8), "every key in its order, the em dashes, no newline added")
        XCTAssertEqual(installed.last, UInt8(ascii: "."), "no trailing newline appended")
        XCTAssertTrue(String(decoding: installed, as: UTF8.self).contains("\nomitClaudeMd: true\n---\n"))
    }

    // MARK: collision and uninstall

    func testACollisionIsRefusedAndTheUsersFileUntouched() async throws {
        let e = try env()
        let mine = Data("---\nname: worker-example-high\ndescription: my own\n---\nmine\n".utf8)
        try FileManager.default.createDirectory(at: e.agents, withIntermediateDirectories: true)
        try mine.write(to: e.agent("worker-example-high"))
        let rt = try runtime(e)
        let ext = try source(e)
        let r = await rt.apply(ext)
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "1.0.0", "the other pieces apply")
        XCTAssertEqual(try Data(contentsOf: e.agent("worker-example-high")), mine, "the user's file is never overwritten")
        XCTAssertTrue(r.notes.contains { $0.hasPrefix("workers: refused ") && $0.contains("worker-example-high.md") }, "\(r.notes)")
        XCTAssertEqual(sha(e.agent("worker-example-low")), sha(ext.directory.appendingPathComponent("agents/worker-example-low.md")))
        XCTAssertTrue(rt.status(ext)?.agents["workers"]?.contains("worker-example-high.md refused") == true, "\(String(describing: rt.status(ext)?.agents))")

        _ = await rt.remove(ext)
        XCTAssertEqual(try Data(contentsOf: e.agent("worker-example-high")), mine, "uninstall never takes the user's file")
        XCTAssertFalse(exists(e.agent("worker-example-low")))
    }

    func testUninstallRemovesOwnFilesOnlyAndKeepsAnEditedOne() async throws {
        let e = try env()
        let rt = try runtime(e)
        let ext = try source(e)
        _ = await rt.apply(ext)
        let edited = Data((Self.low + "my own line\n").utf8)
        try edited.write(to: e.agent("worker-example-low"))
        let other = Data("---\nname: other-agent\n---\nnot the kit's\n".utf8)
        try other.write(to: e.agent("other-agent"))
        XCTAssertTrue(rt.status(ext)?.agents["workers"]?.contains("worker-example-low.md edited") == true)

        let r = await rt.remove(ext)
        XCTAssertEqual(r.config?.status, .done, r.config?.message ?? "")
        XCTAssertFalse(exists(e.agent("worker-example-high")), "the unchanged kit file goes")
        XCTAssertEqual(try Data(contentsOf: e.agent("worker-example-low")), edited, "the edited one is kept")
        XCTAssertTrue(r.notes.contains { $0.contains("kept ") && $0.contains("worker-example-low.md") }, "\(r.notes)")
        XCTAssertEqual(try Data(contentsOf: e.agent("other-agent")), other, "a file the kit never wrote stays")
    }

    // MARK: validator

    private func refusals(_ v: KitValidation) -> [KitRefusal] {
        if case .refused(let r) = v { return r }
        return []
    }

    func testTheValidatorRefusals() throws {
        let f = try makeKitDir()
        let kit = KitFixture.kit(replacing: "\n[[contributes.kit.settings]]",
                                 with: "\n[[contributes.kit.pieces]]\nid   = \"workers\"\nkind = \"agents\"\n\n[[contributes.kit.settings]]")
        try f.write("agents/worker-example-high.md", Self.high)
        // each alone is fine: the kit validates
        guard case .ok(let v) = try f.validate(kit) else { return XCTFail("refused: \(refusals(try f.validate(kit)))") }
        XCTAssertEqual(v.agents["workers"]?.map(\.name), ["worker-example-high"])

        try f.write("agents/Worker-Bad.md", "---\nname: Worker-Bad\n---\n")
        try f.write("agents/worker-other.md", "---\nname: worker-example-low\n---\n")
        try f.write("agents/worker-nofm.md", "name: worker-nofm\n")
        try f.write("agents/worker-big.md", "---\nname: worker-big\n---\n" + String(repeating: "x", count: KitValidator.maxAgentBytes))
        try f.write("agents/worker-home.md", "---\nname: worker-home\n---\nsee {{home}}\n")
        try f.symlink("agents/worker-link.md", to: "../README.md")
        let got = refusals(try f.validate(kit))
        for (subject, reason) in [("agents/Worker-Bad.md", KitReason.badAgentName), ("agents/worker-other.md", .agentNameMismatch),
                                  ("agents/worker-nofm.md", .agentNoFrontmatter), ("agents/worker-big.md", .agentTooLarge),
                                  ("agents/worker-home.md", .agentPlaceholder), ("agents/worker-link.md", .pathSymlink)] {
            XCTAssertTrue(got.contains(KitRefusal(subject: subject, reason: reason)), "\(subject) \(reason): \(got)")
        }
        XCTAssertFalse(got.contains { $0.subject == "agents/worker-example-high.md" }, "the good file is not refused: \(got)")
    }

    func testAgentNameReadsOnlyTheFrontmatter() {
        func fm(_ s: String) -> String { let r = KitValidator.agentName(s); return "\(r.frontmatter) \(r.name ?? "nil")" }
        XCTAssertEqual(fm("---\nname: a-b\n---\n"), "true a-b")
        XCTAssertEqual(fm("---\r\nname: \"a-b\"\r\n---\r\n"), "true a-b", "CRLF and quotes")
        XCTAssertEqual(fm("---\nmodel: x\n---\nname: a-b\n"), "true nil", "a body line is no name")
        XCTAssertEqual(fm("---\nname: a-b\n"), "false nil", "no closing line")
        XCTAssertEqual(fm("\u{FEFF}---\nname: a-b\n---\n"), "false nil", "a BOM is no frontmatter")
    }
}
