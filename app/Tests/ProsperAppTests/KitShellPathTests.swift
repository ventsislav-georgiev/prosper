import Foundation
import XCTest
@testable import ProsperApp

// #922 (OQ-4): the opt-in shell-path piece. Every home is a scratch dir under the row's own tempDir(), passed through
// ManagedConfigRoots.home (the seam); the real home and its rc files are never named, read or written.

final class KitShellPathTests: XCTestCase {
    static let bin = "/Users/example/.config/prosper/kits/com.example.kit/bin"
    static let userRC = "export EDITOR=vi\n"

    /// makeMCEnv's roots plus a scratch home holding a .zshrc.
    private func shellEnv(label: String = #function) throws -> (env: MCEnv, home: URL, rc: URL, mc: ManagedConfig) {
        let env = makeMCEnv(label: label)
        let home = env.root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let rc = home.appendingPathComponent(".zshrc")
        try Data(Self.userRC.utf8).write(to: rc)
        let roots = ManagedConfigRoots(claude: env.claude, configHome: env.config, stateDir: env.state, home: home)
        let clock = MCClock()
        return (env, home, rc, ManagedConfig(roots: roots, consent: env.consent, writer: env.writer, now: { clock.now() }))
    }

    private func piece(_ text: String? = KitRender.shellPathLine(KitShellPathTests.bin)) -> ManagedConfigPiece {
        ManagedConfigPiece(id: "path", kind: .block, target: KitRender.shellRCTarget, text: text)
    }

    private func text(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }

    private func validated(_ pieces: [KitManifest.Piece]) -> KitValidated {
        KitValidated(extensionID: "com.example.kit", slug: "calm-agent", version: "1.0.0", kit: KitManifest(pieces: pieces))
    }

    // MARK: the rc line

    func testLineAppendsOnceAndQuotes() throws {
        let line = try XCTUnwrap(KitRender.shellPathLine(Self.bin))
        XCTAssertEqual(line, "case \":$PATH:\" in *:'\(Self.bin)':*) ;; *) export PATH=\"$PATH\":'\(Self.bin)' ;; esac")
        // a quote in the path is closed, escaped and reopened
        XCTAssertEqual(KitRender.shellPathLine("/Users/ex'ample/bin"),
                       "case \":$PATH:\" in *:'/Users/ex'\\''ample/bin':*) ;; *) export PATH=\"$PATH\":'/Users/ex'\\''ample/bin' ;; esac")
        for bad in ["/Users/example\n/bin", "/Users/example\r/bin", "/Users/example\0/bin", "/Users/example\r\n/bin"] {
            XCTAssertTrue(KitRender.shellPathLine(bad) == nil, bad.debugDescription)
        }
    }

    // MARK: ManagedConfig: shellrc: root

    func testShellRCBlockIsMarkedBackedUpAndRemovedByteIdentical() async throws {
        let (env, _, rc, mc) = try shellEnv()
        let r = await mc.apply([piece()], owner: env.owner)
        XCTAssertEqual(r.status, .done, "\(r)")
        XCTAssertEqual(env.consent.seen.count, 1, "asked before the write")
        let after = try XCTUnwrap(text(rc))
        XCTAssertTrue(after.hasPrefix(Self.userRC), after)
        XCTAssertTrue(after.contains("\n# >>> prosper:kit-a:path v1.0.0 "), after)
        XCTAssertTrue(after.contains("\n" + (KitRender.shellPathLine(Self.bin) ?? "?") + "\n# <<< prosper:kit-a:path <<<"), after)
        XCTAssertEqual(mc.status(owner: env.owner).map(\.state), [.applied])
        let backups = env.files(under: env.state.appendingPathComponent("backups/shellrc"))
        XCTAssertEqual(backups.count, 1, "\(backups)")
        let removed = await mc.remove(owner: env.owner)
        XCTAssertEqual(removed.status, .done, "\(removed)")
        XCTAssertEqual(text(rc), Self.userRC)
    }

    func testShellRCHandEditIsDrift() async throws {
        let (env, _, rc, mc) = try shellEnv()
        _ = await mc.apply([piece()], owner: env.owner)
        let edited = try XCTUnwrap(text(rc)).replacingOccurrences(of: "export PATH=", with: "export  PATH=")
        try Data(edited.utf8).write(to: rc)
        XCTAssertEqual(mc.status(owner: env.owner).map(\.state), [.drifted])
    }

    func testShellRCRefusals() throws {
        let (env, home, _, mc) = try shellEnv()
        func reason(_ target: String, _ kind: ManagedConfigPiece.Kind = .block, roots: ManagedConfigRoots? = nil) -> ManagedConfigRefusalReason? {
            if case .failure(let r) = ManagedConfigPaths.resolve(target, kind: kind, owner: env.owner, roots: roots ?? mc.roots) { return r }
            return nil
        }
        XCTAssertEqual(reason("shellrc:.profile"), .wrongKind("shellrc: takes a block in .zshrc or .bashrc only"))
        XCTAssertEqual(reason("shellrc:.zshrc", .json), .wrongKind("shellrc: takes a block in .zshrc or .bashrc only"))
        XCTAssertEqual(reason("shellrc:.zshrc", .seed), .wrongKind("shellrc: takes a block in .zshrc or .bashrc only"))
        XCTAssertEqual(reason("shellrc:sub/.zshrc"), .wrongKind("shellrc: takes a block in .zshrc or .bashrc only"))
        XCTAssertEqual(reason("shellrc:../.zshrc"), .badPath("'..' component"))
        let noHome = ManagedConfigRoots(claude: env.claude, configHome: env.config, stateDir: env.state)
        XCTAssertEqual(reason("shellrc:.zshrc", roots: noHome), .unwritable("no home root"))
        XCTAssertTrue(reason("shellrc:.zshrc") == nil)
        XCTAssertTrue(reason("shellrc:.bashrc") == nil, "a missing .bashrc is created")
        XCTAssertEqual(ManagedTextBlock.syntax(for: home.appendingPathComponent(".bashrc")), .hash)
        XCTAssertEqual(ManagedTextBlock.syntax(for: home.appendingPathComponent("zshrc")), .hash, "a dotfile manager's target")
    }

    func testLuaCannotTargetShellRC() {
        let (pieces, bad) = ManagedConfigLua.parsePieces([["id": "p", "kind": "block", "target": "shellrc:.zshrc", "text": "x"]])
        XCTAssertEqual(pieces.count, 0)
        XCTAssertEqual(bad.first?.reason, .wrongKind("shellrc: is for a kit's shell-path piece only"))
    }

    // MARK: kit manifest, plan, summary

    func testManifestParsesShellPathWithNoKeys() {
        let ok = KitManifest.parse(.table(["schema": .integer(1), "pieces": .array([.table(["id": .string("path"), "kind": .string("shell-path")])])]))
        XCTAssertEqual(ok.refusals, [])
        XCTAssertEqual(ok.kit.pieces.map(\.kind), [.shellPath])
        let bad = KitManifest.parse(.table(["schema": .integer(1), "pieces": .array([.table(["id": .string("path"), "kind": .string("shell-path"),
                                                                                          "dir": .string("bin")])])]))
        XCTAssertTrue(bad.refusals.contains(KitRefusal(subject: "pieces[0].dir", reason: .unknownKey)), "\(bad.refusals)")
    }

    func testPlanWritesOneBlockOnlyWhenOn() {
        let v = validated([.init(id: "path", kind: .shellPath)])
        let ctx = KitRenderContext.standard(extensionID: "com.example.kit", slug: "calm-agent", kitDir: URL(fileURLWithPath: "/Users/example/kit"),
                                            home: URL(fileURLWithPath: "/Users/example"), configHome: URL(fileURLWithPath: "/Users/example/.config"))
        XCTAssertEqual(KitRender.plan(v, ctx).pieces, [piece(KitRender.shellPathLine(ctx.kitBin))])
        XCTAssertEqual(KitRender.plan(v, ctx, off: ["path"]).pieces, [])
        XCTAssertEqual(KitRender.summary(v, ctx, off: ["path"]),
                       ["path: only when you switch it on, a block at the bottom of /Users/example/.zshrc appends \(ctx.kitBin) to PATH (off)"])
        var nl = ctx
        nl.kitBin = "/Users/example\n/bin"
        XCTAssertEqual(KitRender.plan(v, nl).refusals, [KitRefusal(subject: "path", reason: .notImportable)])
    }

    // MARK: runtime: opt-in selection

    func testShellPathIsOffUntilSwitchedOn() throws {
        let env = makeMCEnv()
        let rt = KitRuntime(provider: ManagedConfigProvider(env.mc), store: try KitStore(configHome: env.config, extID: "com.example.kit"),
                            isTrusted: { _ in true })
        let v = validated([.init(id: "rules", kind: .permissions, allow: ["Bash(ls:*)"]), .init(id: "path", kind: .shellPath)])
        XCTAssertEqual(KitPieceSelection(v).optIn, ["path"])
        XCTAssertEqual(rt.off(v), ["path"], "no pieces.json: opt-in pieces are off")
        _ = try rt.setSelection(v, off: [])
        XCTAssertEqual(rt.off(v), [], "switched on")
        try rt.setOff(["rules"])
        XCTAssertEqual(rt.off(v), ["rules"], "the raw writer keeps the opt-in answer")
        _ = try rt.setSelection(v, off: ["path"])
        XCTAssertEqual(rt.off(v), ["path"], "switched off again")
    }
}
