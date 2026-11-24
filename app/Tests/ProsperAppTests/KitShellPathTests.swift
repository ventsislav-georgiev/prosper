import Foundation
import XCTest
@testable import ProsperApp

// #922 (OQ-4): the opt-in shell-path piece. Every home is a scratch dir under the row's own tempDir(), passed through
// ManagedConfigRoots.home (the seam); the real home and its rc files are never named, read or written.

final class KitShellPathTests: XCTestCase {
    static let bin = "/Users/example/.config/prosper/kits/com.example.kit/bin"
    static let userRC = "export EDITOR=vi\n"
    static let refusal = "shellrc: takes a block in .zshrc, .bashrc, .bash_profile or the kit's own .config/fish/conf.d/<slug>.fish only"

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
        XCTAssertEqual(reason("shellrc:.profile"), .wrongKind(Self.refusal))
        XCTAssertEqual(reason("shellrc:.zshrc", .json), .wrongKind(Self.refusal))
        XCTAssertEqual(reason("shellrc:.zshrc", .seed), .wrongKind(Self.refusal))
        XCTAssertEqual(reason("shellrc:sub/.zshrc"), .wrongKind(Self.refusal))
        XCTAssertEqual(reason("shellrc:../.zshrc"), .badPath("'..' component"))
        let noHome = ManagedConfigRoots(claude: env.claude, configHome: env.config, stateDir: env.state)
        XCTAssertEqual(reason("shellrc:.zshrc", roots: noHome), .unwritable("no home root"))
        XCTAssertTrue(reason("shellrc:.zshrc") == nil)
        XCTAssertTrue(reason("shellrc:.bashrc") == nil, "a missing .bashrc is created")
        XCTAssertEqual(ManagedTextBlock.syntax(for: home.appendingPathComponent(".bashrc")), .hash)
        // #1918: the kit's bash target (a login shell reads only .bash_profile)
        XCTAssertTrue(reason("shellrc:.bash_profile") == nil, "a missing .bash_profile is created")
        XCTAssertEqual(ManagedTextBlock.syntax(for: home.appendingPathComponent(".bash_profile")), .hash)
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

    // MARK: #1918: the rc follows the login shell

    private func ctx(_ shell: String) -> KitRenderContext {
        KitRenderContext.standard(extensionID: "com.example.kit", slug: "calm-agent", kitDir: URL(fileURLWithPath: "/Users/example/kit"),
                                  home: URL(fileURLWithPath: "/Users/example"), configHome: URL(fileURLWithPath: "/Users/example/.config"),
                                  loginShell: shell)
    }

    func testLoginShellPicksTheRC() {
        XCTAssertEqual(KitRender.loginShellName("/bin/zsh"), "zsh")
        XCTAssertEqual(KitRender.loginShellName("/opt/homebrew/bin/fish"), "fish")
        XCTAssertEqual(KitRender.loginShellName(nil), "")
        let v = validated([.init(id: "path", kind: .shellPath)])
        let bin = ctx("zsh").kitBin
        let posix = "case \":$PATH:\" in *:'\(bin)':*) ;; *) export PATH=\"$PATH\":'\(bin)' ;; esac"
        let fish = "contains -- '\(bin)' $PATH; or set -gx PATH $PATH '\(bin)'"
        let table: [(shell: String, target: String?, text: String?)] = [
            ("zsh", "shellrc:.zshrc", posix), ("bash", "shellrc:.bash_profile", posix),
            ("fish", "shellrc:.config/fish/conf.d/calm-agent.fish", fish),
            ("sh", nil, nil), ("tcsh", nil, nil), ("", nil, nil),
        ]
        for row in table {
            let plan = KitRender.plan(v, ctx(row.shell))
            XCTAssertEqual(plan.refusals, [], row.shell)
            XCTAssertEqual(plan.pieces, row.target.map { [ManagedConfigPiece(id: "path", kind: .block, target: $0, text: row.text)] } ?? [], row.shell)
            let note = KitRender.shellPathNote(kitBin: bin, shell: row.shell, slug: "calm-agent") ?? "?"
            let summary = KitRender.summary(v, ctx(row.shell)).first ?? "?"
            if let target = row.target {
                let rc = String(target.dropFirst("shellrc:".count))
                XCTAssertEqual(note, "~/\(rc) gets: " + (row.text ?? "?"), "the pane names the real file")
                XCTAssertEqual(summary, "path: only when you switch it on, a block at the bottom of /Users/example/\(rc) appends \(bin) to PATH")
            } else {
                let name = row.shell.isEmpty ? "unknown" : row.shell
                XCTAssertEqual(note, "your login shell (\(name)) is not zsh, bash or fish, so Prosper writes no block; "
                               + "add this line to its startup file yourself: " + posix, "the POSIX line to add by hand")
                XCTAssertEqual(summary, "path: your login shell (\(name)) is not zsh, bash or fish: nothing is written; add \(bin) to PATH yourself")
            }
        }
    }

    /// A zsh install plans the bytes it planned before #1918: same target, same block text, same summary line.
    func testZshInstallIsUnchanged() {
        let v = validated([.init(id: "path", kind: .shellPath)])
        let bin = "/Users/example/.config/prosper/kits/com.example.kit/bin"
        let before = [ManagedConfigPiece(id: "path", kind: .block, target: "shellrc:.zshrc",
                                         text: "case \":$PATH:\" in *:'\(bin)':*) ;; *) export PATH=\"$PATH\":'\(bin)' ;; esac")]
        for c in [ctx("zsh"), KitRenderContext.standard(extensionID: "com.example.kit", slug: "calm-agent", kitDir: URL(fileURLWithPath: "/Users/example/kit"),
                                                        home: URL(fileURLWithPath: "/Users/example"), configHome: URL(fileURLWithPath: "/Users/example/.config"))] {
            XCTAssertEqual(KitRender.plan(v, c).pieces, before)
            XCTAssertEqual(KitRender.summary(v, c), ["path: only when you switch it on, a block at the bottom of /Users/example/.zshrc appends \(bin) to PATH"])
        }
    }

    func testFishLineQuotes() {
        // fish single quotes: a backslash and a quote are escaped, a space is literal
        XCTAssertEqual(KitRender.fishQuote("/Users/ex ample/it's\\bin"), "'/Users/ex ample/it\\'s\\\\bin'")
        XCTAssertEqual(KitRender.fishPathLine("/Users/ex ample/it's"),
                       "contains -- '/Users/ex ample/it\\'s' $PATH; or set -gx PATH $PATH '/Users/ex ample/it\\'s'")
        for bad in ["/Users/example\n/bin", "/Users/example\r/bin", "/Users/example\0/bin"] {
            XCTAssertTrue(KitRender.fishPathLine(bad) == nil, bad.debugDescription)
        }
    }

    /// Both lines only append, and only when the dir is not on PATH already (so a nested shell reads them as no-ops); the
    /// POSIX line parses under zsh and bash (-n: syntax only, -f: no rc file is read; fish is never run).
    func testLinesAppendOnceAndParse() throws {
        let bin = "/Users/ex ample/it's"
        let posix = try XCTUnwrap(KitRender.shellPathLine(bin))
        let q = KitRender.shellQuote(bin)
        XCTAssertTrue(posix.hasPrefix("case \":$PATH:\" in *:\(q):*) ;; "), "already on PATH: nothing")
        XCTAssertTrue(posix.hasSuffix("*) export PATH=\"$PATH\":\(q) ;; esac"), "appended, never prepended")
        let fish = try XCTUnwrap(KitRender.fishPathLine(bin))
        let fq = KitRender.fishQuote(bin)
        XCTAssertTrue(fish.hasPrefix("contains -- \(fq) $PATH; or "), "already on PATH: nothing")
        XCTAssertTrue(fish.hasSuffix("set -gx PATH $PATH \(fq)"), "appended, never prepended")
        let dir = tempDir(#function)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("line.sh")
        try Data((posix + "\n").utf8).write(to: file)
        for argv in [["/bin/zsh", "-f", "-n"], ["/bin/bash", "--norc", "--noprofile", "-n"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst()) + [file.path]
            p.environment = ["PATH": "/usr/bin:/bin"]
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, argv[0])
        }
    }

    func testFishTargetIsTheKitsOwnConfDFileOnly() async throws {
        let (env, home, _, mc) = try shellEnv()
        func reason(_ target: String, owner: ManagedConfigOwner? = nil) -> ManagedConfigRefusalReason? {
            if case .failure(let r) = ManagedConfigPaths.resolve(target, kind: .block, owner: owner ?? env.owner, roots: mc.roots) { return r }
            return nil
        }
        XCTAssertTrue(reason("shellrc:.config/fish/conf.d/kit-a.fish") == nil, "the owner's slug; a missing dir is created")
        XCTAssertEqual(reason("shellrc:.config/fish/conf.d/other.fish"), .wrongKind(Self.refusal))
        XCTAssertEqual(reason("shellrc:.config/fish/config.fish"), .wrongKind(Self.refusal))
        XCTAssertEqual(reason("shellrc:.config/fish/conf.d/kit-a.sh"), .wrongKind(Self.refusal))
        var noSlug = env.owner
        noSlug.kitSlug = nil
        XCTAssertEqual(reason("shellrc:.config/fish/conf.d/kit-a.fish", owner: noSlug), .wrongKind(Self.refusal))
        let line = try XCTUnwrap(KitRender.fishPathLine(Self.bin))
        let r = await mc.apply([ManagedConfigPiece(id: "path", kind: .block, target: "shellrc:.config/fish/conf.d/kit-a.fish", text: line)], owner: env.owner)
        XCTAssertEqual(r.status, .done, "\(r)")
        let fishFile = home.appendingPathComponent(".config/fish/conf.d/kit-a.fish")
        let after = try XCTUnwrap(text(fishFile))
        XCTAssertTrue(after.contains("# >>> prosper:kit-a:path v1.0.0 "), after)
        XCTAssertTrue(after.contains("\n" + line + "\n# <<< prosper:kit-a:path <<<"), after)
        XCTAssertEqual(text(home.appendingPathComponent(".zshrc")), Self.userRC, "the zsh rc is not touched")
        let removed = await mc.remove(owner: env.owner)
        XCTAssertEqual(removed.status, .done, "\(removed)")
        XCTAssertFalse((text(fishFile) ?? "").contains("prosper:kit-a"), "Remove takes the block out")
    }

    /// #1918: the planner moves a piece whose target changed: the old block leaves its file in the same plan (one consent),
    /// the new one is written; an old block it cannot take out (broken markers) refuses the move and writes nothing.
    func testTargetChangeMovesTheBlockInOnePlan() async throws {
        let (env, home, rc, mc) = try shellEnv()
        let fishTarget = "shellrc:.config/fish/conf.d/kit-a.fish"
        let fishFile = home.appendingPathComponent(".config/fish/conf.d/kit-a.fish")
        let line = try XCTUnwrap(KitRender.fishPathLine(Self.bin))
        _ = await mc.apply([piece()], owner: env.owner)
        let r = await mc.apply([ManagedConfigPiece(id: "path", kind: .block, target: fishTarget, text: line)], owner: env.owner)
        XCTAssertEqual(r.status, .done, "\(r)")
        XCTAssertEqual(env.consent.seen.count, 2, "one sheet per apply: the move is one plan")
        XCTAssertEqual(text(rc), Self.userRC, "the zsh block left byte for byte")
        XCTAssertTrue((text(fishFile) ?? "").contains("\n" + line + "\n"), text(fishFile) ?? "")
        XCTAssertEqual(mc.status(owner: env.owner).map(\.target), [fishTarget], "one record, on the new target")

        // back to zsh, then a hand-broken zsh block: the move to fish is refused and the fish file is not written again
        _ = await mc.apply([piece()], owner: env.owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fishFile.path) && (text(fishFile) ?? "").contains("prosper:kit-a"), "moved back")
        let broken = (text(rc) ?? "").replacingOccurrences(of: "# <<< prosper:kit-a:path <<<", with: "")
        try Data(broken.utf8).write(to: rc)
        let refused = await mc.apply([ManagedConfigPiece(id: "path", kind: .block, target: fishTarget, text: line)], owner: env.owner)
        XCTAssertEqual(refused.status, .refused, "\(refused)")
        XCTAssertFalse((text(fishFile) ?? "").contains("prosper:kit-a"), "nothing written beside the block it could not remove")
        XCTAssertEqual(text(rc), broken, "the broken file is left as it is")
    }

    /// A user who switches login shells: the next apply removes the old block and writes the new one (one PATH line in
    /// all), and a shell with no rc removes it without writing another. KitRuntime over a real ManagedConfig, all roots
    /// under the row's tempDir().
    func testShellSwitchMovesTheBlock() async throws {
        let root = tempDir(#function)
        defer { try? FileManager.default.removeItem(at: root) }
        let roots = ManagedConfigRoots(claude: root.appendingPathComponent("claude home", isDirectory: true),
                                       configHome: root.appendingPathComponent("config", isDirectory: true),
                                       stateDir: root.appendingPathComponent("state", isDirectory: true), home: root)
        for d in [roots.claude, roots.configHome] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("{}\n".utf8).write(to: roots.claude.appendingPathComponent("settings.json"))
        let zshrc = root.appendingPathComponent(".zshrc")
        try Data(Self.userRC.utf8).write(to: zshrc)
        let clock = MCClock()
        let provider = ManagedConfigProvider(ManagedConfig(roots: roots, consent: KitRTConsent(), writer: ManagedConfigPOSIXWriter(), now: { clock.now() }))
        let ext = "com.example.kit"
        let kit = "[contributes.kit]\nschema = 1\n\n[[contributes.kit.pieces]]\nid   = \"path\"\nkind = \"shell-path\"\n"
        // a same-version apply is a no-op (KitUpdateMachine): the move lands at the next update, or at Repair
        func source(_ version: String) throws -> LoadedExtension {
            let head = KitFixture.head.replacingOccurrences(of: "\"dev.example.kit.calm-agent\"", with: "\"\(ext)\"")
                .replacingOccurrences(of: "\"1.0.0\"", with: "\"\(version)\"").replacingOccurrences(of: "\"2.170.0\"", with: "\"0.0.1\"")
            let dir = root.appendingPathComponent("sources/shell-kit-\(version)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (rel, body) in ["extension.toml": head + "\n" + kit, "README.md": KitDirFixture.readme, "init.lua": "return {}\n"] {
                try Data(body.utf8).write(to: dir.appendingPathComponent(rel))
            }
            return LoadedExtension(manifest: try KitFixture.manifest(kit, head: head), directory: dir, isSystem: false)
        }
        func runtime(_ shell: String) throws -> KitRuntime {
            KitRuntime(provider: provider, store: try KitStore(configHome: roots.configHome, extID: ext), isTrusted: { _ in true }, loginShell: shell)
        }
        let v = KitValidated(extensionID: ext, slug: "calm-agent", version: "1.0.0", kit: KitManifest(pieces: [.init(id: "path", kind: .shellPath)]))
        let fishFile = root.appendingPathComponent(".config/fish/conf.d/calm-agent.fish")
        func blocks() -> Int {
            [zshrc, fishFile].map { (text($0) ?? "").components(separatedBy: "# >>> prosper:\(ext):path ").count - 1 }.reduce(0, +)
        }

        let zsh = try runtime("zsh")
        _ = try zsh.setSelection(v, off: [])
        let first = await zsh.apply(try source("1.0.0"))
        XCTAssertEqual(first.failures, [], "\(first)")
        XCTAssertTrue((text(zshrc) ?? "").contains("export PATH="), text(zshrc) ?? "")
        XCTAssertEqual(blocks(), 1)

        let fishRT = try runtime("fish")
        let moved = await fishRT.apply(try source("1.0.1"))
        XCTAssertEqual(moved.failures, [], "\(moved)")
        XCTAssertTrue(moved.configRefusals.isEmpty, "\(moved.configRefusals)")
        XCTAssertEqual(text(zshrc), Self.userRC, "the old block left the zsh rc byte for byte")
        XCTAssertTrue((text(fishFile) ?? "").contains("; or set -gx PATH $PATH "), text(fishFile) ?? "")
        XCTAssertEqual(blocks(), 1, "one PATH block, never two")

        let zshAgain = try runtime("zsh")
        let repaired = await zshAgain.repair(try source("1.0.1"))
        XCTAssertEqual(repaired.config?.status, .done, "\(repaired)")
        XCTAssertTrue((text(zshrc) ?? "").contains("export PATH="), "Repair moves it back to the zsh rc")
        XCTAssertFalse((text(fishFile) ?? "").contains("set -gx PATH"), text(fishFile) ?? "")
        XCTAssertEqual(blocks(), 1)

        let tcshRT = try runtime("tcsh")
        let none = await tcshRT.apply(try source("1.0.2"))
        XCTAssertEqual(none.failures, [], "\(none)")
        XCTAssertEqual(blocks(), 0, "a shell with no rc: the block is removed, none is written")
        XCTAssertEqual(text(zshrc), Self.userRC)
    }

    // MARK: runtime: opt-in selection

    func testShellPathIsOffUntilSwitchedOn() throws {
        let env = makeMCEnv()
        // makeMCEnv names config/ but never makes it; KitStore makes prosper/ under an existing config home (as KitRuntimePaneTests does)
        try FileManager.default.createDirectory(at: env.config, withIntermediateDirectories: true)
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
