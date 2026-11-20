import XCTest
@testable import ProsperApp

/// #917 S7: a kit's tool bins are appended to a spawned session's PATH. Pure function rows over fake paths: no
/// process, no file, no session is made.
final class KitSessionEnvTests: XCTestCase {
    private static let base = ["PATH": "/Users/example/bin:/usr/bin", "DCH_SOCKET_DIR": "/d", "HOME": "/Users/example"]
    private static let binA = "/Users/example/kits/com.example.kit-a/bin"
    private static let binB = "/Users/example/kits/com.example.kit-b/bin"

    private func run(_ bins: [String], _ env: [String: String] = KitSessionEnvTests.base) -> [String: String] {
        KitSessionEnv.contributor { bins }(["claude"], env)
    }

    func testAppendNeverPrepend() {
        let out = run([Self.binA])
        XCTAssertEqual(out["PATH"], "/Users/example/bin:/usr/bin:" + Self.binA)
        XCTAssertTrue(out["PATH"]?.hasPrefix("/Users/example/bin:/usr/bin") == true, "the person's own PATH stays first")
        var rest = out
        rest["PATH"] = Self.base["PATH"]
        XCTAssertEqual(rest, Self.base, "only PATH changes")
    }

    /// #1684: the --revive flag is the contributor's PATH, once; nothing to add (or no PATH) gives no flag.
    func testReviveFlagIsTheContributorsPath() {
        XCTAssertEqual(KitSessionEnv.reviveFlags(kitBins: [Self.binA, Self.binB], env: Self.base),
                       ["--env", "PATH=/Users/example/bin:/usr/bin:" + Self.binA + ":" + Self.binB])
        XCTAssertEqual(KitSessionEnv.reviveFlags(kitBins: [], env: Self.base), [])
        XCTAssertEqual(KitSessionEnv.reviveFlags(kitBins: ["/usr/bin"], env: Self.base), [])
        XCTAssertEqual(KitSessionEnv.reviveFlags(kitBins: [Self.binA], env: ["DCH_SOCKET_DIR": "/d"]), [])
    }

    func testNoKitAddsNothing() {
        XCTAssertEqual(run([]), Self.base, "no bins: byte-identical")
        XCTAssertEqual(run([], ["DCH_SOCKET_DIR": "/d"]), ["DCH_SOCKET_DIR": "/d"], "no bins, no PATH: still none")
        XCTAssertEqual(run([Self.binA], ["DCH_SOCKET_DIR": "/d"]), ["DCH_SOCKET_DIR": "/d"], "no PATH to append to: unchanged")
    }

    /// The contract with the live owner (#1423): a kit that is off is left out of the list, so nothing of it is added.
    func testOffToolsPieceAddsNothing() {
        let kits = [(bin: Self.binA, on: false), (bin: Self.binB, on: true)]
        let out = KitSessionEnv.contributor { kits.filter { $0.on }.map { $0.bin } }(["claude"], Self.base)
        XCTAssertEqual(out["PATH"], "/Users/example/bin:/usr/bin:" + Self.binB)
        XCTAssertFalse(out["PATH"]?.contains(Self.binA) == true, "the off kit's bin is not on PATH")
        let allOff = KitSessionEnv.contributor { kits.filter { _ in false }.map { $0.bin } }(["claude"], Self.base)
        XCTAssertEqual(allOff, Self.base)
    }

    func testOrderIsInstallOrder() {
        XCTAssertEqual(run([Self.binA, Self.binB])["PATH"], "/Users/example/bin:/usr/bin:" + Self.binA + ":" + Self.binB)
        XCTAssertEqual(run([Self.binB, Self.binA])["PATH"], "/Users/example/bin:/usr/bin:" + Self.binB + ":" + Self.binA)
    }

    func testDuplicateAndMalformedBinsAreSkipped() {
        XCTAssertEqual(run(["/usr/bin"]), Self.base, "already on PATH")
        XCTAssertEqual(run([Self.binA, Self.binA])["PATH"], "/Users/example/bin:/usr/bin:" + Self.binA, "listed twice: once")
        XCTAssertEqual(run(["/Users/example/x:/Users/example/y"]), Self.base, "a colon would smuggle a second entry")
        XCTAssertEqual(run(["bin", "./bin", "", "~/bin"]), Self.base, "not absolute")
        XCTAssertEqual(run(["bin", Self.binB, "/a:b"])["PATH"], "/Users/example/bin:/usr/bin:" + Self.binB)
    }

    /// spawnEnv's order: the strip, then the pool's change, then the kit bins.
    func testComposesAfterPoolRouting() {
        let pool: SessionEnvContributor = { _, env in
            var e = env
            e["PATH"] = "/Users/example/pool-bin:" + (env["PATH"] ?? "")
            e["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:41234"
            return e
        }
        let kit = KitSessionEnv.contributor { [Self.binA] }
        let input = Self.base.merging(["CLAUDECODE": "1"]) { $1 }
        let out = AgentIslandController.spawnEnv(input, argv: ["claude"], [pool, kit])
        XCTAssertEqual(out["PATH"], "/Users/example/pool-bin:/Users/example/bin:/usr/bin:" + Self.binA, "the pool's change first, the kit bin last")
        XCTAssertEqual(out["ANTHROPIC_BASE_URL"], "http://127.0.0.1:41234")
        XCTAssertTrue(out["CLAUDECODE"] == nil, "spawnEnv's strip still applies")
    }

    /// The registered default: no bins yet, so a spawn's env is spawnEnv's alone (and the kit piece comes after the pool's).
    @MainActor func testTheRegisteredContributorIsEmptyForNow() {
        let c = AgentIslandController().sessionEnvContributors()
        let out = AgentIslandController.spawnEnv(Self.base, argv: ["claude"], c)
        XCTAssertEqual(out, AgentIsland.spawnEnv(Self.base))
    }

    /// The pool's routing is in the list first (it is never built under XCTest, so the order is read from the source).
    func testRegistrationIsAfterThePoolRouting() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/AgentIsland/AgentIslandController.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let pool = text.range(of: "[$0.routing.contributor]")?.lowerBound, kit = text.range(of: "KitSessionEnv.contributor")?.lowerBound
        XCTAssertTrue(pool != nil && kit != nil, "both registrations are there")
        if let pool, let kit { XCTAssertTrue(pool < kit, "the kit bins come after the pool routing") }
        XCTAssertEqual(text.components(separatedBy: "KitSessionEnv.contributor").count - 1, 1, "registered once")
    }
}
