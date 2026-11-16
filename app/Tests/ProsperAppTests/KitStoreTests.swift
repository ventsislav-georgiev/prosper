import Darwin
import Darwin.membership
import Foundation
import XCTest
@testable import ProsperApp

/// #917 S5a: the kit store's staging half. Every path is under the row's tempDir(): the config home is
/// <tempDir>/config, the kit source is the KitDirFixture under <tempDir>/kits. Nothing of a kit runs.
final class KitStoreTests: XCTestCase {
    static let ext = "com.example.kit"
    static let tree0 = String(repeating: "0", count: 64)

    private func scene(_ label: String = #function) throws -> (KitDirFixture, URL, KitStore) {
        let root = tempDir(label)
        let f = try makeKitDir(under: root, label: label)
        let home = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (f, home, try KitStore(configHome: home, extID: Self.ext))
    }

    private func mode(_ path: String) -> Int {
        var st = stat()
        guard lstat(path, &st) == 0 else { return -1 }
        return Int(st.st_mode & 0o7777)
    }

    private func list(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() }

    private func stage(_ store: KitStore, _ source: URL, _ version: String = "1.0.0", tree: String = KitStoreTests.tree0,
                       cap: Int = KitStore.localByteCap) throws -> KitStaged {
        try store.stageCopy(from: source.path, version: version, tree: tree, byteCap: cap)
    }

    func testStageRefusesSymlinkRoot() throws {
        let (f, _, store) = try scene()
        let link = f.root.appendingPathComponent("linked-kit")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: f.kit.path)
        XCTAssertThrowsError(try stage(store, link)) { XCTAssertEqual($0 as? KitStoreError, .link("")) }
        XCTAssertEqual(list(store.layout.staged), [])
        // a file as the root is refused too; the real dir behind the link stages
        XCTAssertThrowsError(try stage(store, f.url("README.md"))) { XCTAssertEqual($0 as? KitStoreError, .notADirectory("")) }
        XCTAssertEqual(try stage(store, f.kit).path, store.layout.staged + "/1.0.0+" + Self.tree0)
    }

    func testStageNeverFollowsAnInnerLink() throws {
        let (f, _, store) = try scene()
        let outside = f.root.appendingPathComponent("outside.txt") // the row's own file, outside the kit source
        let bytes = Data("outside bytes\n".utf8)
        try bytes.write(to: outside)
        let before = mode(outside.path)
        try f.symlink("seed/linked.toml", to: outside.path)
        XCTAssertThrowsError(try stage(store, f.kit)) { XCTAssertEqual($0 as? KitStoreError, .link("seed/linked.toml")) }
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
        XCTAssertEqual(mode(outside.path), before)
        XCTAssertEqual(list(store.layout.staged), [])
        XCTAssertEqual(list(store.layout.tmp), [])
        // a link to a dir inside the source is refused the same way
        try f.remove("seed/linked.toml")
        try f.symlink("hooks-again", to: f.url("hooks").path)
        XCTAssertThrowsError(try stage(store, f.kit)) { XCTAssertEqual($0 as? KitStoreError, .link("hooks-again")) }
        XCTAssertEqual(list(store.layout.staged), [])
    }

    func testValidatorRunsOnStagedCopy() throws {
        let (f, _, store) = try scene()
        let s = try stage(store, f.kit)
        try f.remove("README.md") // the source changes after the copy: the source alone is now refused
        guard case .refused = try f.validate() else { return XCTFail("the changed source must be refused") }
        let reader = KitStoreRecordingReader()
        guard case .ok(let v) = store.validate(s, manifest: try KitFixture.manifest(), source: .market, otherKitSlugs: [], reader: reader) else {
            return XCTFail("the staged copy holds the README")
        }
        XCTAssertEqual(v.extensionID, "dev.example.kit.calm-agent")
        XCTAssertTrue(reader.paths.contains(s.path + "/README.md"))
        XCTAssertEqual(reader.paths.filter { $0 != s.path && !$0.hasPrefix(s.path + "/") }, [])
    }

    func testRenderTouchesOnlyMarkdown() throws {
        let (f, home, store) = try scene()
        let s = try stage(store, f.kit)
        let ctx = KitRenderContext.standard(extensionID: Self.ext, slug: "calm-agent", kitDir: URL(fileURLWithPath: store.layout.live),
                                            home: URL(fileURLWithPath: "/Users/example"), configHome: home)
        let names = list(s.path)
        try store.render(s, ctx)
        var same = 0
        for rel in ["README.md", "hooks/guard.sh", "tools/calm-note", "statusline/hud.mjs", "init.lua", "seed/notes.toml"] {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: s.path + "/" + rel)), try Data(contentsOf: f.url(rel)), rel)
            same += 1
        }
        XCTAssertEqual(same, 6)
        XCTAssertTrue(try String(contentsOfFile: s.path + "/hooks/guard.sh", encoding: .utf8).contains("{{kit_dir}}"))
        let md = try Data(contentsOf: f.url("CLAUDE.md"))
        let rendered = try Data(contentsOf: URL(fileURLWithPath: s.path + "/CLAUDE.md"))
        XCTAssertEqual(rendered, KitRender.renderFile("CLAUDE.md", md, ctx))
        XCTAssertNotEqual(rendered, md)
        XCTAssertEqual(mode(s.path + "/CLAUDE.md"), 0o600)
        XCTAssertEqual(list(s.path), names, "no temp file left in the copy")
    }

    func testModesAfterStage() throws {
        let (f, _, store) = try scene()
        try FileManager.default.createDirectory(atPath: store.layout.root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.layout.root)
        try f.write("extra/gx", "x\n", mode: 0o654) // group x only: still an executable for the validator
        let s = try stage(store, f.kit)
        XCTAssertEqual(mode(store.layout.root), 0o700, "a wider kit dir is narrowed")
        var dirs = 0
        for d in store.layout.dirs + [s.path, s.path + "/hooks", s.path + "/extra"] {
            XCTAssertEqual(mode(d), 0o700, d)
            dirs += 1
        }
        XCTAssertEqual(dirs, 8)
        let want = ["CLAUDE.md": 0o600, "README.md": 0o600, "seed/notes.toml": 0o600, "hooks/guard.sh": 0o700, "tools/calm-note": 0o700, "extra/gx": 0o700]
        for (rel, m) in want { XCTAssertEqual(mode(s.path + "/" + rel), m, rel) }
        XCTAssertEqual(try store.recordSlug("calm-agent"), "calm-agent")
        XCTAssertEqual(mode(store.layout.kitEnv), 0o600)
        XCTAssertEqual(try String(contentsOfFile: store.layout.kitEnv, encoding: .utf8), "KIT_SLUG='calm-agent'\n")
        // E-2: the slug recorded at first apply wins over a later manifest
        XCTAssertEqual(try store.recordSlug("renamed-kit"), "calm-agent")
        XCTAssertEqual(store.recordedSlug(), "calm-agent")
        XCTAssertEqual(try String(contentsOfFile: store.layout.kitEnv, encoding: .utf8), "KIT_SLUG='calm-agent'\n")
        XCTAssertThrowsError(try store.recordSlug("-dash")) { XCTAssertEqual($0 as? KitStoreError, .badSlug) }
        XCTAssertEqual(list(store.layout.root), ["bin", "fired", "kit.env", "staged", "state", "tmp"]) // live, previous: by the swap only
    }

    func testByteCapStopsCopy() throws {
        let (f, _, store) = try scene()
        XCTAssertEqual(KitStore.marketByteCap, 262_144)
        XCTAssertEqual(KitStore.localByteCap, 16_777_216)
        let total = try store.walk(f.kit.path, byteCap: KitStore.localByteCap).reduce(0) { $0 + $1.data.count }
        XCTAssertGreaterThan(total, 100)
        XCTAssertThrowsError(try stage(store, f.kit, cap: total - 1)) { XCTAssertEqual($0 as? KitStoreError, .tooLarge) }
        XCTAssertEqual(list(store.layout.staged), [])
        XCTAssertEqual(list(store.layout.tmp), [])
        XCTAssertThrowsError(try stage(store, f.kit, cap: -1)) { XCTAssertEqual($0 as? KitStoreError, .tooLarge) }
        XCTAssertEqual(try stage(store, f.kit, cap: total).path, store.layout.staged + "/1.0.0+" + Self.tree0)
    }

    private func memory(_ entries: [String: KitFileKind], _ label: String = #function) throws -> (KitStore, KitStoreMemorySourceFS) {
        let root = tempDir(label)
        let fs = KitStoreMemorySourceFS(root: root.appendingPathComponent("memory-src").path, entries: entries)
        return (try KitStore(configHome: root, extID: Self.ext, fs: fs), fs)
    }

    func testEntryAndDepthBoundsDuringCopy() throws {
        var flat: [String: KitFileKind] = [:]
        for i in 0..<4096 { flat[String(format: "f%04d", i)] = .file(mode: 0o644, size: 0) }
        let (ok, okFS) = try memory(flat)
        let s = try ok.stageCopy(from: okFS.root, version: "1.0.0", tree: Self.tree0, byteCap: 0)
        XCTAssertEqual(list(s.path).count, 4096)
        XCTAssertEqual(okFS.writes.filter { !$0.hasPrefix(ok.layout.root + "/") && $0 != ok.layout.root && $0 != ok.layout.kits && $0 != ok.layout.prosper }, [])

        flat["f4096"] = .file(mode: 0o644, size: 0)
        let (over, overFS) = try memory(flat)
        XCTAssertThrowsError(try over.stageCopy(from: overFS.root, version: "1.0.0", tree: Self.tree0, byteCap: 0)) {
            XCTAssertEqual($0 as? KitStoreError, .tooManyFiles)
        }
        XCTAssertLessThanOrEqual(overFS.kinds, 4097, "the walk stops at the bound")
        XCTAssertEqual(overFS.writes, [], "nothing is written for a refused tree")

        func chain(_ n: Int) -> [String: KitFileKind] {
            var out: [String: KitFileKind] = [:]
            var rel = ""
            for i in 1...n { rel += (rel.isEmpty ? "" : "/") + "d\(i)"; out[rel] = .directory }
            out[rel + "/leaf"] = .file(mode: 0o644, size: 0)
            return out
        }
        let (deep15, deep15FS) = try memory(chain(15))
        XCTAssertNoThrow(try deep15.stageCopy(from: deep15FS.root, version: "1.0.0", tree: Self.tree0, byteCap: 0))
        let (deep16, deep16FS) = try memory(chain(16))
        XCTAssertThrowsError(try deep16.stageCopy(from: deep16FS.root, version: "1.0.0", tree: Self.tree0, byteCap: 0)) {
            XCTAssertEqual($0 as? KitStoreError, .tooDeep)
        }
        XCTAssertEqual(deep16FS.writes, [])
        // the fake says setuid and "special"; no such entry is created on disk
        let (su, suFS) = try memory(["run": .file(mode: 0o4755, size: 0)])
        XCTAssertThrowsError(try su.stageCopy(from: suFS.root, version: "1.0.0", tree: Self.tree0, byteCap: 0)) {
            XCTAssertEqual($0 as? KitStoreError, .setuid("run"))
        }
        let (sp, spFS) = try memory(["pipe": .other])
        XCTAssertThrowsError(try sp.stageCopy(from: spFS.root, version: "1.0.0", tree: Self.tree0, byteCap: 0)) {
            XCTAssertEqual($0 as? KitStoreError, .special("pipe"))
        }
    }

    func testTreeHashVerifies() throws {
        let root = tempDir()
        let store = try KitStore(configHome: root.appendingPathComponent("config"), extID: Self.ext)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        let t = KitDirFixture(root: root, kit: root.appendingPathComponent("tree", isDirectory: true))
        try t.write("d/a.txt", "hi\n", mode: 0o644)
        try t.write("run", "x", mode: 0o755)
        // framing pinned by a hash computed outside Swift (python hashlib, the framing of KitStore.treeHash)
        let h = "cc643140e9b67e07fc3f29d55332c469c8015fa91522dcf94eb8add1c7601899"
        XCTAssertEqual(try store.treeHash(of: t.kit.path), h)
        let same = try stage(store, t.kit, "1.0.0", tree: h)
        XCTAssertTrue(store.verify(same) == nil)
        XCTAssertEqual(try store.treeHash(of: same.path), h)

        try t.write("d/a.txt", "hj\n", mode: 0o644) // one byte
        XCTAssertEqual(store.verify(try stage(store, t.kit, "1.0.1", tree: h)), .validationRefused("1.0.1", tree: h))
        try t.write("d/a.txt", "hi\n", mode: 0o644)
        try FileManager.default.moveItem(at: t.url("run"), to: t.url("run2")) // a renamed file
        XCTAssertEqual(store.verify(try stage(store, t.kit, "1.0.2", tree: h)), .validationRefused("1.0.2", tree: h))
        try FileManager.default.moveItem(at: t.url("run2"), to: t.url("run"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: t.url("run").path) // the x bit
        XCTAssertEqual(store.verify(try stage(store, t.kit, "1.0.3", tree: h)), .validationRefused("1.0.3", tree: h))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t.url("run").path)
        XCTAssertTrue(store.verify(try stage(store, t.kit, "1.0.4", tree: h)) == nil, "the same tree again")

        // "ab"+"c" and "a"+"bc": one byte string under naive concatenation, two trees here
        let t1 = KitDirFixture(root: root, kit: root.appendingPathComponent("t1", isDirectory: true))
        let t2 = KitDirFixture(root: root, kit: root.appendingPathComponent("t2", isDirectory: true))
        try t1.write("ab", "c")
        try t2.write("a", "bc")
        XCTAssertNotEqual(try store.treeHash(of: t1.kit.path), try store.treeHash(of: t2.kit.path))
    }

    func testPartialReaddirRefuses() throws {
        let (f, home, _) = try scene()
        let failing = KitFailingDirStream(failIn: f.kit.path)
        XCTAssertEqual(KitStore.listNames(f.kit.path, KitPOSIXDirStream()),
                       ["CLAUDE.md", "README.md", "hooks", "init.lua", "seed", "statusline", "tools"])
        XCTAssertTrue(KitStore.listNames(f.kit.path, failing) == nil, "EIO after one name is not a short list")
        let store = try KitStore(configHome: home, extID: Self.ext, fs: KitPOSIXFS(stream: failing))
        XCTAssertThrowsError(try stage(store, f.kit)) { XCTAssertEqual($0 as? KitStoreError, .unreadableDir("")) }
        XCTAssertEqual(list(store.layout.staged), [])
        XCTAssertEqual(list(store.layout.tmp), [])
        let deeper = try KitStore(configHome: home, extID: Self.ext, fs: KitPOSIXFS(stream: KitFailingDirStream(failIn: f.url("hooks").path)))
        XCTAssertThrowsError(try stage(deeper, f.kit)) { XCTAssertEqual($0 as? KitStoreError, .unreadableDir("hooks")) }
        XCTAssertEqual(list(store.layout.staged), [])
        // the validator's reader lists through the same seam (rider: kit917e m5 gets its row)
        XCTAssertEqual(KitPOSIXFileReader().names(f.kit.path), KitStore.listNames(f.kit.path, KitPOSIXDirStream()))
        XCTAssertTrue(KitPOSIXFileReader(stream: failing).names(f.kit.path) == nil, "the validator's reader: no short list")
        guard case .refused = try f.validate(reader: KitPOSIXFileReader(stream: failing)) else {
            return XCTFail("a folder that cannot be listed whole is refused")
        }
    }

    func testLateDropOfAnOldTreeKeepsTheNewOne() throws {
        let (f, _, store) = try scene()
        XCTAssertEqual(KitStore.stagedName("1.0.0", Self.tree0), "1.0.0+0000000000000000000000000000000000000000000000000000000000000000")
        let h1 = try store.treeHash(of: f.kit.path)
        _ = try stage(store, f.kit, "1.0.0", tree: h1)
        // cancel: the machine emits dropStaged("1.0.0") for h1; it is carried out only after A/h2 is staged
        try f.write("CLAUDE.md", KitDirFixture.claudeMD + "\nOne more line.\n")
        let h2 = try store.treeHash(of: f.kit.path)
        XCTAssertNotEqual(h1, h2)
        let s2 = try stage(store, f.kit, "1.0.0", tree: h2)
        XCTAssertEqual(list(store.layout.staged), ["1.0.0+" + h1, "1.0.0+" + h2].sorted())
        try store.dropStaged(version: "1.0.0", tree: h1) // the late drop names h1
        XCTAssertEqual(list(store.layout.staged), ["1.0.0+" + h2])
        XCTAssertTrue(store.verify(s2) == nil, "A/h2 intact")
        try store.dropStaged(version: "1.0.0", tree: String(repeating: "a", count: 64)) // a tree never staged
        try store.dropStaged(version: "../x", tree: h2) // not a version: nothing
        XCTAssertEqual(list(store.layout.staged), ["1.0.0+" + h2])
        try store.dropStaged(version: "1.0.0", tree: h2)
        XCTAssertEqual(list(store.layout.staged), [])
    }

    func testLayoutRefusesALinkInPlaceOfTheKitDir() throws {
        let root = tempDir()
        let home = root.appendingPathComponent("config", isDirectory: true)
        let store = try KitStore(configHome: home, extID: Self.ext)
        XCTAssertEqual(store.layout.root, home.standardizedFileURL.path + "/prosper/kits/com.example.kit")
        for bad in ["-x.example", "..", ".", "a/b", ""] {
            XCTAssertThrowsError(try KitStore.layout(configHome: home, extID: bad), bad)
        }
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: elsewhere.path)
        try FileManager.default.createDirectory(atPath: store.layout.kits, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: store.layout.root, withDestinationPath: elsewhere.path)
        let refusedHere: (String) -> (Error) -> Void = { p in { e in
            XCTAssertTrue((e as? KitStoreError).map { [KitStoreError.link(p), .notADirectory(p)].contains($0) } ?? false, "\(e)")
        } }
        XCTAssertThrowsError(try store.ensureLayout(), "kit dir", refusedHere(store.layout.root))
        XCTAssertEqual(list(elsewhere.path), [])
        XCTAssertEqual(mode(elsewhere.path), 0o755)
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.root), .symlink)
        // a link in place of staged/ is refused the same way
        try FileManager.default.removeItem(atPath: store.layout.root) // the row's own link
        try store.ensureLayout()
        try FileManager.default.removeItem(atPath: store.layout.staged)
        try FileManager.default.createSymbolicLink(atPath: store.layout.staged, withDestinationPath: elsewhere.path)
        XCTAssertThrowsError(try store.ensureLayout(), "staged", refusedHere(store.layout.staged))
        XCTAssertEqual(list(elsewhere.path), [])
        XCTAssertEqual(mode(elsewhere.path), 0o755)
        // the store's remove never leaves kits/<ext-id>/
        for p in [home.path, store.layout.root, store.layout.root + "/", store.layout.staged + "/../../x", elsewhere.path] {
            XCTAssertThrowsError(try store.removeTree(p), p) { XCTAssertEqual($0 as? KitStoreError, .outsideStore) }
        }
        try store.removeTree(store.layout.staged) // the link itself goes, its target stays
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.staged), .missing)
        XCTAssertEqual(KitPOSIXFS().kind(elsewhere.path), .directory)
    }

    // MARK: S5b-1: directory-relative walks (R917-s5a-q1), write n == 0 (R917-s5a-n1), swap, sweep

    /// A canary dir OUTSIDE the store and the source: b/file with known bytes.
    private func canary(_ root: URL) throws -> (dir: URL, file: URL, bytes: Data) {
        let dir = root.appendingPathComponent("canary", isDirectory: true)
        let file = dir.appendingPathComponent("b/file")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("canary bytes\n".utf8)
        try bytes.write(to: file)
        return (dir, file, bytes)
    }

    func testWalkStaysInTheOpenedDirAfterASwap() throws {
        let root = tempDir()
        let home = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let src = KitDirFixture(root: root, kit: root.appendingPathComponent("src", isDirectory: true))
        try src.write("a/b/file", "kit bytes\n")
        let c = try canary(root)
        // after a/ is listed, a/ is moved aside inside the source and a link to the canary takes its name:
        // a joined path a/b would now read the canary; the walk holds a/ open and reads the original
        let swapDir = KitSwapAfterListing(label: src.url("a").path) {
            try? FileManager.default.moveItem(at: src.url("a"), to: src.url("a-moved"))
            try? FileManager.default.createSymbolicLink(atPath: src.url("a").path, withDestinationPath: c.dir.path)
        }
        let store = try KitStore(configHome: home, extID: Self.ext, fs: KitPOSIXFS(stream: swapDir))
        let s = try store.stageCopy(from: src.kit.path, version: "1.0.0", tree: Self.tree0, byteCap: 1024)
        XCTAssertTrue(swapDir.fired)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: s.path + "/a/b/file")), Data("kit bytes\n".utf8))
        XCTAssertEqual(list(s.path), ["a"], "the moved dir was never listed")
        XCTAssertEqual(try Data(contentsOf: c.file), c.bytes)

        // the listed CHILD swapped for a link before its kind is read: refused, nothing staged
        let src2 = KitDirFixture(root: root, kit: root.appendingPathComponent("src2", isDirectory: true))
        try src2.write("a/b/file", "kit bytes\n")
        let swapChild = KitSwapAfterListing(label: src2.url("a").path) {
            try? FileManager.default.moveItem(at: src2.url("a/b"), to: src2.url("a/b-moved"))
            try? FileManager.default.createSymbolicLink(atPath: src2.url("a/b").path, withDestinationPath: c.dir.appendingPathComponent("b").path)
        }
        let store2 = try KitStore(configHome: home, extID: Self.ext, fs: KitPOSIXFS(stream: swapChild))
        XCTAssertThrowsError(try store2.stageCopy(from: src2.kit.path, version: "1.0.1", tree: Self.tree0, byteCap: 1024)) {
            XCTAssertEqual($0 as? KitStoreError, .link("a/b"))
        }
        XCTAssertTrue(swapChild.fired)
        XCTAssertEqual(list(store2.layout.staged), ["1.0.0+" + Self.tree0])
        XCTAssertEqual(list(store2.layout.tmp), [])
        XCTAssertEqual(try Data(contentsOf: c.file), c.bytes)
    }

    func testRemoveTreeStaysInsideAfterASwap() throws {
        let (f, home, store) = try scene()
        let c = try canary(f.root)
        try f.write("a/b/file", "kit bytes\n")
        let s = try stage(store, f.kit)
        let fm = FileManager.default
        // after staged/<copy>/a is listed, it is moved aside inside the store and a link to the canary takes its name
        let swap = KitSwapAfterListing(label: s.path + "/a") {
            try? FileManager.default.moveItem(atPath: s.path + "/a", toPath: s.path + "/a-moved")
            try? FileManager.default.createSymbolicLink(atPath: s.path + "/a", withDestinationPath: c.dir.path)
        }
        let swapping = try KitStore(configHome: home, extID: Self.ext, fs: KitPOSIXFS(stream: swap))
        XCTAssertThrowsError(try swapping.dropStaged(version: "1.0.0", tree: Self.tree0), "a link where a/ was is not rmdir'd")
        XCTAssertTrue(swap.fired)
        XCTAssertEqual(try Data(contentsOf: c.file), c.bytes, "nothing outside kits/<ext-id> is removed")
        XCTAssertEqual(list(c.dir.path), ["b"])
        XCTAssertEqual(list(s.path + "/a-moved"), [], "the original a/ was emptied through its own descriptor")
        // a link in place of a dir ON THE WAY is refused, its target untouched
        try fm.removeItem(atPath: s.path + "/a") // the row's own link
        try fm.moveItem(atPath: s.path, toPath: s.path + "-real")
        try fm.createSymbolicLink(atPath: s.path, withDestinationPath: c.dir.path)
        XCTAssertThrowsError(try store.removeTree(s.path + "/b")) { XCTAssertEqual($0 as? KitStoreError, .link(s.path)) }
        XCTAssertEqual(try Data(contentsOf: c.file), c.bytes)
    }

    func testWriteReturningZeroFails() throws {
        let root = tempDir()
        let once = KitZeroWriteOnce()
        var fs = KitPOSIXFS()
        fs.writeBytes = { fd, p, n in once.take() ? 0 : Darwin.write(fd, p, n) }
        let path = root.appendingPathComponent("f").path
        XCTAssertThrowsError(try fs.create(path, Data("abc".utf8), mode: 0o600)) { XCTAssertEqual($0 as? KitStoreError, .io("write", EIO)) }
        XCTAssertNoThrow(try KitPOSIXFS().create(path + "2", Data("abc".utf8), mode: 0o600))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path + "2")), Data("abc".utf8))
    }

    /// A tiny source whose only file `marker` holds `v`, staged as v + tree0.
    private func stageMarked(_ store: KitStore, _ root: URL, _ v: String) throws {
        let src = KitDirFixture(root: root, kit: root.appendingPathComponent("src-" + v, isDirectory: true))
        try src.write("marker", v)
        _ = try store.stageCopy(from: src.kit.path, version: v, tree: Self.tree0, byteCap: 1024)
    }

    private func marker(_ dir: String) -> String? { try? String(contentsOfFile: dir + "/marker", encoding: .utf8) }

    func testFirstApplyRenames() throws {
        let (f, _, store) = try scene()
        try stageMarked(store, f.root, "1.0.0")
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.live), .missing, "ensureLayout makes no empty live")
        try store.swap(version: "1.0.0", tree: Self.tree0)
        XCTAssertEqual(marker(store.layout.live), "1.0.0")
        XCTAssertEqual(mode(store.layout.live), 0o700)
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.previous), .missing, "no previous on the first apply")
        XCTAssertEqual(list(store.layout.staged), [])
        // a version that is not staged is refused and changes nothing
        XCTAssertThrowsError(try store.swap(version: "9.9.9", tree: Self.tree0)) {
            XCTAssertEqual($0 as? KitStoreError, .notADirectory(store.stagedPath("9.9.9", Self.tree0)))
        }
        XCTAssertThrowsError(try store.swap(version: "../x", tree: Self.tree0)) { XCTAssertEqual($0 as? KitStoreError, .badVersion) }
        XCTAssertEqual(marker(store.layout.live), "1.0.0")
    }

    func testPreviousIsOne() throws {
        let (f, _, store) = try scene()
        for v in ["1.0.0", "1.0.1", "1.0.2"] {
            try stageMarked(store, f.root, v)
            try store.swap(version: v, tree: Self.tree0)
        }
        XCTAssertEqual(marker(store.layout.live), "1.0.2")
        XCTAssertEqual(marker(store.layout.previous), "1.0.1")
        XCTAssertEqual(mode(store.layout.previous), 0o700)
        XCTAssertEqual(list(store.layout.staged), [], "the older previous is kept as retiring, not parked under staged/")
        XCTAssertEqual(list(store.layout.root), ["bin", "fired", "live", "previous", "retiring", "staged", "state", "tmp"])
        XCTAssertEqual(list(store.layout.previous), ["marker"])
    }

    /// Ruling r-917s5b1a: the older previous is the machine's `retiring` (KitUpdate .swapped) until dropRetiring; one
    /// retiring only: a stale one is removed by the next swap that has a previous to retire.
    func testSwapKeepsTheOlderPreviousAsRetiring() throws {
        let (f, _, store) = try scene()
        let retiring = store.layout.root + "/retiring"
        for v in ["1.0.0", "1.0.1"] {
            try stageMarked(store, f.root, v)
            try store.swap(version: v, tree: Self.tree0)
        }
        XCTAssertEqual(KitPOSIXFS().kind(retiring), .missing, "no previous before the second swap: nothing retires")
        try stageMarked(store, f.root, "1.0.2")
        try store.swap(version: "1.0.2", tree: Self.tree0)
        XCTAssertEqual(marker(store.layout.live), "1.0.2")
        XCTAssertEqual(marker(store.layout.previous), "1.0.1")
        XCTAssertEqual(marker(retiring), "1.0.0")
        XCTAssertEqual(mode(retiring), 0o700)
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.root + "/incoming"), .missing)
        // no dropRetiring in between: the stale retiring (1.0.0) goes, the previous (1.0.1) retires
        try stageMarked(store, f.root, "1.0.3")
        try store.swap(version: "1.0.3", tree: Self.tree0)
        XCTAssertEqual(marker(store.layout.live), "1.0.3")
        XCTAssertEqual(marker(store.layout.previous), "1.0.2")
        XCTAssertEqual(marker(retiring), "1.0.1")
        XCTAssertEqual(list(retiring), ["marker"])
        XCTAssertEqual(list(store.layout.staged), [], "nothing parked under staged/")
        XCTAssertEqual(list(store.layout.root), ["bin", "fired", "live", "previous", "retiring", "staged", "state", "tmp"])
    }

    /// dropRetiring is the machine's dropPrevious after wiringApplied; restoreRetiring is the disk half of a failed shim
    /// write or wiring AFTER swapBack (KitUpdate .shimsFailed / .wiringFailed: previous = retiring).
    func testDropAndRestoreRetiring() throws {
        let (f, _, store) = try scene()
        let retiring = store.layout.root + "/retiring"
        for v in ["1.0.0", "1.0.1", "1.0.2"] {
            try stageMarked(store, f.root, v)
            try store.swap(version: v, tree: Self.tree0)
        }
        try store.dropRetiring()
        XCTAssertEqual(KitPOSIXFS().kind(retiring), .missing)
        XCTAssertEqual(marker(store.layout.live), "1.0.2", "dropRetiring removes only retiring")
        XCTAssertEqual(marker(store.layout.previous), "1.0.1", "dropRetiring removes only retiring")
        try store.dropRetiring() // absent: a no-op
        XCTAssertEqual(marker(store.layout.previous), "1.0.1")
        // a failed apply of 1.0.3: swap, swapBack, restoreRetiring
        try stageMarked(store, f.root, "1.0.3")
        try store.swap(version: "1.0.3", tree: Self.tree0)
        XCTAssertEqual(marker(retiring), "1.0.1")
        try store.swapBack()
        XCTAssertEqual(marker(store.layout.previous), "1.0.3")
        try store.restoreRetiring()
        XCTAssertEqual(marker(store.layout.live), "1.0.2")
        XCTAssertEqual(marker(store.layout.previous), "1.0.1", "previous is the older one again, the failed new is gone")
        XCTAssertEqual(KitPOSIXFS().kind(retiring), .missing)
        XCTAssertEqual(list(store.layout.root), ["bin", "fired", "live", "previous", "staged", "state", "tmp"])
        // no retiring (the second apply ever fails): restoreRetiring leaves no previous
        let (g, _, fresh) = try scene(#function + "-fresh")
        for v in ["2.0.0", "2.0.1"] {
            try stageMarked(fresh, g.root, v)
            try fresh.swap(version: v, tree: Self.tree0)
        }
        try fresh.swapBack()
        try fresh.restoreRetiring()
        XCTAssertEqual(marker(fresh.layout.live), "2.0.0")
        XCTAssertEqual(KitPOSIXFS().kind(fresh.layout.previous), .missing)
        XCTAssertEqual(KitPOSIXFS().kind(fresh.layout.root + "/retiring"), .missing)
    }

    /// Review r-917s5b1b: a leftover retiring with NO previous (a crash left it) goes at the next swap: the machine's
    /// retiring is nil there, so no dropPrevious would ever come and a restore would make it an unknown previous.
    func testSwapRemovesAStaleRetiringWithoutAPrevious() throws {
        let (f, _, store) = try scene()
        let retiring = store.layout.root + "/retiring"
        try stageMarked(store, f.root, "1.0.0")
        try store.swap(version: "1.0.0", tree: Self.tree0)
        try FileManager.default.createDirectory(atPath: retiring, withIntermediateDirectories: false)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: retiring + "/marker"))
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.previous), .missing)
        try stageMarked(store, f.root, "1.0.1")
        try store.swap(version: "1.0.1", tree: Self.tree0)
        XCTAssertEqual(KitPOSIXFS().kind(retiring), .missing, "the stale retiring is gone")
        XCTAssertEqual(marker(store.layout.live), "1.0.1")
        XCTAssertEqual(marker(store.layout.previous), "1.0.0")
        // the failed apply: swapBack + restoreRetiring leaves no previous (the machine's previous is nil)
        try store.swapBack()
        try store.restoreRetiring()
        XCTAssertEqual(marker(store.layout.live), "1.0.0")
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.previous), .missing)
        XCTAssertEqual(KitPOSIXFS().kind(retiring), .missing)
    }

    /// Ruling r-917s5b1a L2: the swap stopped after any one of its steps (the fake fails the Nth rename, the state a crash
    /// there leaves) never leaves a staged <version>+<tree> name holding other content, never loses a copy, and live,
    /// once it exists, is never missing. The next swap removes the stale `incoming` (its own first step).
    func testACrashBetweenSwapStepsNeverMislabels() throws {
        let (f, home, _) = try scene()
        func ownVersions(_ store: KitStore, _ n: Int) {
            for s in list(store.layout.staged) {
                XCTAssertEqual(marker(store.layout.staged + "/" + s), String(s.prefix { $0 != "+" }), "rename \(n): \(s) holds its own version")
            }
        }
        func copies(_ store: KitStore) -> [String] {
            ["live", "previous", "retiring", "incoming"].compactMap { marker(store.layout.root + "/" + $0) }
                + list(store.layout.staged).compactMap { marker(store.layout.staged + "/" + $0) }
        }
        var completed = 0
        for n in 1...6 {
            let ext = "com.example.crash\(n)"
            let store = try KitStore(configHome: home, extID: ext)
            for v in ["1.0.0", "1.0.1"] {
                try stageMarked(store, f.root, v)
                try store.swap(version: v, tree: Self.tree0)
            }
            try stageMarked(store, f.root, "1.0.2")
            let crashing = try KitStore(configHome: home, extID: ext, fs: KitFailNthRename(n))
            if (try? crashing.swap(version: "1.0.2", tree: Self.tree0)) != nil { completed += 1 }
            let live = marker(store.layout.live)
            XCTAssertTrue(live == "1.0.1" || live == "1.0.2", "rename \(n): live is never missing (\(live ?? "none"))")
            ownVersions(store, n)
            XCTAssertEqual(copies(store).sorted(), ["1.0.0", "1.0.1", "1.0.2"], "rename \(n): every copy once, none lost")
            // the next swap goes through: a stale incoming is removed first
            try stageMarked(store, f.root, "1.0.3")
            try store.swap(version: "1.0.3", tree: Self.tree0)
            XCTAssertEqual(marker(store.layout.live), "1.0.3", "rename \(n)")
            XCTAssertEqual(KitPOSIXFS().kind(store.layout.root + "/incoming"), .missing, "rename \(n)")
            ownVersions(store, n)
        }
        XCTAssertEqual(completed, 2, "four renames with live and previous present: the 5th and 6th never come")
        // the first apply: two renames (staged -> incoming, incoming -> live)
        for n in 1...2 {
            let store = try KitStore(configHome: home, extID: "com.example.first\(n)")
            try stageMarked(store, f.root, "1.0.0")
            let crashing = try KitStore(configHome: home, extID: "com.example.first\(n)", fs: KitFailNthRename(n))
            XCTAssertThrowsError(try crashing.swap(version: "1.0.0", tree: Self.tree0))
            XCTAssertEqual(KitPOSIXFS().kind(store.layout.live), .missing, "first apply, rename \(n): no live yet")
            ownVersions(store, n)
            XCTAssertEqual(copies(store), ["1.0.0"], "first apply, rename \(n)")
            if n == 2 { try stageMarked(store, f.root, "1.0.0") } // the staged copy went to incoming
            try store.swap(version: "1.0.0", tree: Self.tree0)
            XCTAssertEqual(marker(store.layout.live), "1.0.0")
            XCTAssertEqual(KitPOSIXFS().kind(store.layout.root + "/incoming"), .missing)
        }
    }

    /// R1393-i1: a stale `.swap-incoming` naming live's inode (a failed cleanup that recovery could not remove either) is
    /// removed by the swap's prepare. A crash after the retire and before the stamp (the stamp write fails) then leaves no
    /// stamp, so recovery never makes the NEW copy at incoming the previous; the true previous waits at retiring.
    func testStaleStampIsClearedAtPrepareSoACrashNeverMakesTheNewCopyPrevious() throws {
        let (f, home, store) = try scene()
        for v in ["1.0.0", "1.0.1"] {
            try stageMarked(store, f.root, v)
            try store.swap(version: v, tree: Self.tree0)
        }
        let ino = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: store.layout.live)[.systemFileNumber] as? UInt64)
        let stamp = store.layout.root + "/" + KitStore.swapStamp
        try Data("\(ino)\n".utf8).write(to: URL(fileURLWithPath: stamp))
        try stageMarked(store, f.root, "1.0.2")
        let crashing = try KitStore(configHome: home, extID: Self.ext, fs: KitEffectFailRenames([], failStamp: true))
        XCTAssertThrowsError(try crashing.swap(version: "1.0.2", tree: Self.tree0)) {
            XCTAssertEqual(($0 as? KitSwapError)?.step, .exchange)
        }
        XCTAssertEqual(KitPOSIXFS().kind(stamp), .missing, "prepare removed the stale stamp")
        XCTAssertEqual(marker(store.layout.live), "1.0.1")
        XCTAssertEqual(marker(store.layout.root + "/retiring"), "1.0.0")
        XCTAssertEqual(marker(store.layout.root + "/incoming"), "1.0.2")
        XCTAssertFalse(try store.recoverIncoming(), "no stamp: nothing is moved")
        XCTAssertEqual(marker(store.layout.previous), nil, "the new copy is never made previous")
        XCTAssertEqual(marker(store.layout.root + "/incoming"), "1.0.2")
        try store.restoreRetiring()
        XCTAssertEqual(marker(store.layout.previous), "1.0.0", "the true previous comes back from retiring")
    }

    func testSwapBackRestoresTheOldLive() throws {
        let (f, _, store) = try scene()
        XCTAssertThrowsError(try store.swapBack(), "nothing to swap back to")
        try stageMarked(store, f.root, "1.0.0")
        try store.swap(version: "1.0.0", tree: Self.tree0)
        XCTAssertThrowsError(try store.swapBack()) { XCTAssertEqual($0 as? KitStoreError, .rollbackCopyGone) }
        XCTAssertEqual(marker(store.layout.live), "1.0.0")
        try stageMarked(store, f.root, "1.0.1")
        try store.swap(version: "1.0.1", tree: Self.tree0)
        try store.swapBack()
        XCTAssertEqual(marker(store.layout.live), "1.0.0")
        XCTAssertEqual(marker(store.layout.previous), "1.0.1")
        try store.swapBack() // and forth again: one swap each way
        XCTAssertEqual(marker(store.layout.live), "1.0.1")
        XCTAssertEqual(marker(store.layout.previous), "1.0.0")
    }

    func testSwapRefusesALinkInPlaceOfLive() throws {
        let (f, _, store) = try scene()
        let elsewhere = f.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("theirs\n".utf8).write(to: elsewhere.appendingPathComponent("marker"))
        try stageMarked(store, f.root, "1.0.0")
        try FileManager.default.createSymbolicLink(atPath: store.layout.live, withDestinationPath: elsewhere.path)
        XCTAssertThrowsError(try store.swap(version: "1.0.0", tree: Self.tree0)) { XCTAssertEqual($0 as? KitStoreError, .link(store.layout.live)) }
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.live), .symlink)
        XCTAssertEqual(list(elsewhere.path), ["marker"])
        XCTAssertEqual(marker(elsewhere.path), "theirs\n")
        XCTAssertEqual(list(store.layout.staged), ["1.0.0+" + Self.tree0], "the staged copy stays")
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.previous), .missing)
        // swapBack refuses a link at live the same way
        try FileManager.default.createDirectory(atPath: store.layout.previous, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.swapBack()) { XCTAssertEqual($0 as? KitStoreError, .link(store.layout.live)) }
        XCTAssertEqual(marker(elsewhere.path), "theirs\n")
    }

    func testSwapLeavesNoMissingWindow() throws {
        let (f, _, store) = try scene()
        for i in 0...50 { try stageMarked(store, f.root, "1.0.\(i)") }
        try store.swap(version: "1.0.0", tree: Self.tree0)
        let watcher = KitLiveWatcher(path: store.layout.live)
        watcher.start()
        let t0 = Date()
        var swapped = 0
        for i in 1...50 {
            do { try store.swap(version: "1.0.\(i)", tree: Self.tree0); swapped += 1 } catch { XCTFail("swap \(i): \(error)"); break }
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let seen = watcher.stop()
        print("testSwapLeavesNoMissingWindow: 50 swaps in \(ms) ms, \(seen.looks) lstat calls")
        XCTAssertEqual(swapped, 50)
        XCTAssertTrue(seen.stopped, "the watcher thread ended")
        XCTAssertGreaterThan(seen.looks, 0)
        XCTAssertEqual(seen.misses, 0, "live was never missing")
        XCTAssertEqual(marker(store.layout.live), "1.0.50")
        XCTAssertEqual(marker(store.layout.previous), "1.0.49")
        XCTAssertEqual(list(store.layout.staged), [])
    }

    func testSweepRemovesOldTempOnly() throws {
        let (f, _, store) = try scene()
        try store.ensureLayout()
        let fm = FileManager.default
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let oldTemp = UUID().uuidString, oldFile = UUID().uuidString, fresh = UUID().uuidString, link = UUID().uuidString
        let lower = UUID().uuidString.lowercased() // a UUID, but not as stageCopy names it (its own UUID: APFS folds case)
        try fm.createDirectory(atPath: store.layout.tmp + "/" + oldTemp + "/inner", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: store.layout.tmp + "/" + oldTemp + "/inner/f"))
        try Data("y".utf8).write(to: URL(fileURLWithPath: store.layout.tmp + "/" + oldFile))
        try fm.createDirectory(atPath: store.layout.tmp + "/" + fresh, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: store.layout.tmp + "/notes", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: store.layout.tmp + "/" + lower, withIntermediateDirectories: true)
        // the link's target is the row's own old dir OUTSIDE the store, with a file in it
        let c = try canary(f.root)
        try fm.createSymbolicLink(atPath: store.layout.tmp + "/" + link, withDestinationPath: c.dir.path)
        for n in [oldTemp, oldFile, "notes", lower] {
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: store.layout.tmp + "/" + n)
        }
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: c.dir.path)
        let removed = try store.sweepStaleTemps(now: now)
        XCTAssertEqual(removed.sorted(), [oldTemp, oldFile].sorted())
        XCTAssertEqual(list(store.layout.tmp), [fresh, link, "notes", lower].sorted())
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.tmp + "/" + link), .symlink)
        XCTAssertEqual(list(c.dir.path), ["b"], "the link's target is untouched")
        XCTAssertEqual(try Data(contentsOf: c.file), c.bytes)
        // the same entries a minute later than their age: the fresh one goes too, nothing else
        XCTAssertEqual(try store.sweepStaleTemps(now: now.addingTimeInterval(KitStore.staleTempAge + 5)), [fresh])
        XCTAssertEqual(list(store.layout.tmp), [link, "notes", lower].sorted())
        // no store yet: nothing to sweep, nothing made
        let bare = try KitStore(configHome: f.root.appendingPathComponent("none"), extID: Self.ext)
        XCTAssertEqual(try bare.sweepStaleTemps(now: now), [])
        XCTAssertEqual(KitPOSIXFS().kind(bare.layout.prosper), .missing)
    }

    // MARK: S5b-2b: shims, the runner, kit.env, .settings.env, the wider sweep

    private func context(_ home: URL, _ store: KitStore) -> KitRenderContext {
        KitRenderContext.standard(extensionID: Self.ext, slug: "example-kit", kitDir: URL(fileURLWithPath: store.layout.live),
                                  home: URL(fileURLWithPath: "/Users/example"), configHome: home)
    }

    private func shim(_ c: KitRenderContext, _ name: String, script: String = "tool.sh") -> KitShimPlan {
        KitShimPlan(pieceID: "tools", name: name, target: c.kitBin + "/" + name,
                    text: KitRender.shimText(c, pieceID: "tools", name: name, target: c.kitDir + "/bin/" + script))
    }

    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    private func inode(_ path: String) -> (ino: UInt64, sec: Int, nsec: Int)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (UInt64(st.st_ino), st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec)
    }

    /// any extended ACL entry on the path itself (no follow)
    private func hasACL(_ path: String) -> Bool {
        guard let a = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(a)) }
        var e: acl_entry_t?
        return acl_get_entry(a, 0, &e) == 0 // 0 = ACL_FIRST_ENTRY
    }

    /// An inheritable read-only ACL entry (uid 1, a system account), set in process on the row's own dir, as
    /// TextFileWriterTests does: everything made below it inherits it, unless dropped. The precondition is asserted (a
    /// probe dir made by FileManager carries it), so the row never passes vacuously.
    private func inheritableACL(on dir: URL) throws {
        var acl: acl_t? = acl_init(1)
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var perms: acl_permset_t?
        var flags: acl_flagset_t?
        let who = UUID(uuidString: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000001")!.uuid
        XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
        XCTAssertEqual(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW), 0)
        XCTAssertEqual(withUnsafeBytes(of: who) { acl_set_qualifier(entry, $0.baseAddress) }, 0)
        XCTAssertEqual(acl_get_permset(entry, &perms), 0)
        XCTAssertEqual(acl_add_perm(perms, ACL_READ_DATA), 0)
        XCTAssertEqual(acl_set_permset(entry, perms), 0)
        XCTAssertEqual(acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags), 0)
        XCTAssertEqual(acl_add_flag_np(flags, ACL_ENTRY_FILE_INHERIT), 0)
        XCTAssertEqual(acl_add_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT), 0)
        XCTAssertEqual(acl_set_flagset_np(UnsafeMutableRawPointer(entry), flags), 0)
        guard acl_set_file(dir.path, ACL_TYPE_EXTENDED, acl) == 0 else { throw XCTSkip("acl_set_file refused on this file system: errno \(errno)") }
        let probe = dir.appendingPathComponent("acl-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        XCTAssertTrue(hasACL(probe.path), "the probe dir inherits the ACL")
    }

    func testShimsWrittenAndStaleOnesRemovedOnlyFromRecord() throws {
        let (_, home, store) = try scene()
        let c = context(home, store)
        let bin = store.layout.bin
        XCTAssertEqual(try store.writeShims([shim(c, "alpha"), shim(c, "beta")]), [])
        XCTAssertEqual(list(bin), [".prosper-shims", "alpha", "beta"])
        XCTAssertEqual(text(bin + "/alpha"), shim(c, "alpha").text)
        XCTAssertEqual(mode(bin + "/alpha"), 0o755)
        XCTAssertEqual(mode(bin + "/beta"), 0o755)
        XCTAssertEqual(text(bin + "/.prosper-shims"), "alpha\nbeta\n")
        XCTAssertEqual(mode(bin + "/.prosper-shims"), 0o600)
        // a file of the user's own in bin/: never in the record
        try Data("mine".utf8).write(to: URL(fileURLWithPath: bin + "/mine"))
        // the plan drops beta: beta is in the record and goes by its literal name; mine stays
        XCTAssertEqual(try store.writeShims([shim(c, "alpha", script: "other.sh")]), ["beta"])
        XCTAssertEqual(list(bin), [".prosper-shims", "alpha", "mine"])
        XCTAssertEqual(text(bin + "/alpha"), shim(c, "alpha", script: "other.sh").text)
        XCTAssertEqual(text(bin + "/mine"), "mine")
        XCTAssertEqual(text(bin + "/.prosper-shims"), "alpha\n")
        // a planned name that exists and is not in the record is refused: nothing written, nothing removed
        XCTAssertThrowsError(try store.writeShims([shim(c, "gamma"), shim(c, "mine")])) {
            XCTAssertEqual($0 as? KitStoreError, .shimsNotOurs(["mine"]))
        }
        XCTAssertEqual(list(bin), [".prosper-shims", "alpha", "mine"])
        XCTAssertEqual(text(bin + "/mine"), "mine")
        XCTAssertEqual(text(bin + "/.prosper-shims"), "alpha\n")
        // an empty plan removes every recorded shim and nothing else
        XCTAssertEqual(try store.writeShims([]), ["alpha"])
        XCTAssertEqual(list(bin), [".prosper-shims", "mine"])
        XCTAssertEqual(text(bin + "/mine"), "mine")
    }

    func testRunnerWrittenOnlyOnChange() throws {
        let (_, _, store) = try scene()
        let path = store.layout.runner
        let script = Data(KitRunner.script.utf8)
        XCTAssertTrue(try store.installRunner())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), script)
        XCTAssertEqual(mode(path), 0o755)
        XCTAssertEqual(mode(store.layout.kitRuntime), 0o700)
        let first = inode(path)
        XCTAssertTrue(first != nil)
        // the same bytes and mode: nothing written, the same file (inode and mtime)
        XCTAssertFalse(try store.installRunner())
        let second = inode(path)
        XCTAssertTrue(first?.ino == second?.ino && first?.sec == second?.sec && first?.nsec == second?.nsec)
        // changed bytes are rewritten
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(try store.installRunner())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), script)
        XCTAssertEqual(mode(path), 0o755)
        // a changed mode alone is put back too
        XCTAssertEqual(chmod(path, 0o700), 0)
        XCTAssertTrue(try store.installRunner())
        XCTAssertEqual(mode(path), 0o755)
        XCTAssertEqual(list(store.layout.kitRuntime), ["prosper-kit-run"], "no temp is left behind")
    }

    func testKitEnvIs0600() throws {
        let (_, home, store) = try scene()
        try inheritableACL(on: home)
        let c = context(home, store)
        // no recorded slug yet: nothing written
        XCTAssertThrowsError(try store.writeKitEnv(c)) { XCTAssertEqual($0 as? KitStoreError, .noSlug) }
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.prosper), .missing)
        XCTAssertEqual(try store.recordSlug("example-kit"), "example-kit")
        try store.writeKitEnv(c)
        let env = store.layout.kitEnv
        XCTAssertEqual(text(env), "KIT_SLUG='example-kit'\n" + (KitRunner.kitEnvText(c, stateDir: store.layout.state) ?? "nil"))
        XCTAssertEqual(mode(env), 0o600)
        XCTAssertEqual(store.recordedSlug(), "example-kit")
        // every parent the store made is 0700 and carries no ACL, though the config home's ACL is inheritable
        for d in [store.layout.prosper, store.layout.kits, store.layout.root] + store.layout.dirs {
            XCTAssertEqual(mode(d), 0o700, d)
            XCTAssertFalse(hasACL(d), d)
        }
        XCTAssertFalse(hasACL(env))
        // a nil text (a path that cannot be one line) writes nothing and says which file
        var bad = c
        bad.kitDir = "/Users/example/kit\nX"
        XCTAssertThrowsError(try store.writeKitEnv(bad)) { XCTAssertEqual($0 as? KitStoreError, .envText("kit.env")) }
        XCTAssertEqual(text(env), "KIT_SLUG='example-kit'\n" + (KitRunner.kitEnvText(c, stateDir: store.layout.state) ?? "nil"))
        XCTAssertEqual(list(store.layout.root).filter { $0.hasPrefix(".") }, [], "no temp is left behind")
    }

    func testSettingsEnvIs0600InA0700ParentWithNoACL() throws {
        let (_, home, store) = try scene()
        try inheritableACL(on: home)
        XCTAssertThrowsError(try store.writeSettingsEnv(["theme": "dark"])) { XCTAssertEqual($0 as? KitStoreError, .noSlug) }
        XCTAssertEqual(try store.recordSlug("example-kit"), "example-kit")
        try store.writeSettingsEnv(["theme": "dark", "level": "2"])
        let dir = home.path + "/example-kit"
        let se = dir + "/.settings.env"
        XCTAssertEqual(text(se), KitRunner.settingsEnvText(["theme": "dark", "level": "2"]) ?? "nil")
        XCTAssertEqual(mode(se), 0o600)
        XCTAssertEqual(mode(dir), 0o700)
        XCTAssertFalse(hasACL(dir))
        XCTAssertFalse(hasACL(se))
        // a nil text (a key that cannot be a variable) writes nothing and says which file
        XCTAssertThrowsError(try store.writeSettingsEnv(["bad key": "x"])) { XCTAssertEqual($0 as? KitStoreError, .envText(".settings.env")) }
        XCTAssertEqual(text(se), KitRunner.settingsEnvText(["theme": "dark", "level": "2"]) ?? "nil")
        XCTAssertEqual(list(dir), [".settings.env"])
        // the slug dir is the user's: an inheritable ACL put on it later is kept there, never on the file written in it
        try inheritableACL(on: URL(fileURLWithPath: dir))
        try store.writeSettingsEnv(["theme": "light"])
        XCTAssertEqual(text(se), KitRunner.settingsEnvText(["theme": "light"]) ?? "nil")
        XCTAssertEqual(mode(se), 0o600)
        XCTAssertFalse(hasACL(se))
        XCTAssertTrue(hasACL(dir))
    }

    func testReplaceRefusedWhenNotWritable() throws {
        let (_, home, store) = try scene()
        let c = context(home, store)
        XCTAssertEqual(try store.recordSlug("example-kit"), "example-kit")
        try store.writeKitEnv(c)
        let env = store.layout.kitEnv
        let before = text(env)
        XCTAssertEqual(chmod(env, 0o400), 0)
        var other = c
        other.kitDir = "/Users/example/other-kit"
        XCTAssertThrowsError(try store.writeKitEnv(other)) { XCTAssertEqual($0 as? KitStoreError, .notWritable(env)) }
        XCTAssertEqual(text(env), before)
        XCTAssertEqual(mode(env), 0o400)
        // the runner: a read-only one with the wrong mode is not replaced
        XCTAssertTrue(try store.installRunner())
        XCTAssertEqual(chmod(store.layout.runner, 0o500), 0)
        XCTAssertThrowsError(try store.installRunner()) { XCTAssertEqual($0 as? KitStoreError, .notWritable(store.layout.runner)) }
        XCTAssertEqual(mode(store.layout.runner), 0o500)
        // a shim
        try store.writeShims([shim(c, "alpha")])
        XCTAssertEqual(chmod(store.layout.bin + "/alpha", 0o500), 0)
        XCTAssertThrowsError(try store.writeShims([shim(c, "alpha", script: "other.sh")])) {
            XCTAssertEqual($0 as? KitStoreError, .notWritable(store.layout.bin + "/alpha"))
        }
        XCTAssertEqual(text(store.layout.bin + "/alpha"), shim(c, "alpha").text)
        let temps = (list(store.layout.root) + list(store.layout.bin)).filter { $0.contains(".prosper-") && $0 != ".prosper-shims" }
        XCTAssertEqual(temps, [], "no temp is left behind")
    }

    /// #1396: render writes through replace(in:). A link that takes the place of a rendered .md after the walk read it
    /// is refused and its target (a file of the row's own) is untouched.
    func testRenderRefusesALinkThatReplacesARenderedFile() throws {
        let (f, home, store) = try scene()
        let s = try stage(store, f.kit)
        let ctx = context(home, store)
        let victim = f.root.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: victim)
        let (sp, md) = (s.path, s.path + "/CLAUDE.md")
        let hooked = try KitStore(configHome: home, extID: Self.ext, fs: KitHookFS(afterRead: { dir, name in
            guard dir == sp, name == "CLAUDE.md" else { return }
            _ = unlink(md)
            _ = symlink(victim.path, md)
        }))
        XCTAssertThrowsError(try hooked.render(s, ctx)) { XCTAssertEqual($0 as? KitStoreError, .link(md)) }
        XCTAssertEqual(text(victim.path), "keep")
        var st = stat()
        XCTAssertEqual(lstat(md, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK, "the link is still there")
        XCTAssertEqual(list(s.path).filter { $0.contains(".prosper-") }, [], "no temp is left behind")
    }

    func testRenderRefusesAReadOnlyRenderedFile() throws {
        let (f, home, store) = try scene()
        let s = try stage(store, f.kit)
        let md = s.path + "/CLAUDE.md"
        let before = text(md)
        XCTAssertEqual(chmod(md, 0o400), 0)
        XCTAssertThrowsError(try store.render(s, context(home, store))) { XCTAssertEqual($0 as? KitStoreError, .notWritable(md)) }
        XCTAssertEqual(text(md), before)
        XCTAssertEqual(mode(md), 0o400)
        XCTAssertEqual(list(s.path).filter { $0.contains(".prosper-") }, [], "no temp is left behind")
    }

    /// #1409: runtime.json round-trips at 0600; a file over the cap, of another schema or not JSON reads as nil.
    func testRuntimeStateRoundTripAndBounds() throws {
        let (_, _, store) = try scene()
        XCTAssertTrue(store.readRuntimeState() == nil, "no file")
        var s = KitUpdateState(live: KitRef(version: "2.0.0", treeHash: Self.tree0, slug: "example-kit"))
        s.previous = KitRef(version: "1.0.0", treeHash: Self.tree0, slug: "example-kit")
        try store.writeRuntimeState(s)
        XCTAssertEqual(store.runtimeStatePath, store.layout.root + "/runtime.json")
        XCTAssertEqual(mode(store.runtimeStatePath), 0o600)
        XCTAssertTrue(store.readRuntimeState() == s)
        let good = try Data(contentsOf: URL(fileURLWithPath: store.runtimeStatePath))
        let text = try XCTUnwrap(String(data: good, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schema\":1"), text)
        let bad: [Data] = [Data(text.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2").utf8),
                           good + Data(repeating: 0x20, count: KitStore.runtimeStateCap + 1 - good.count),
                           Data("{ not json".utf8)]
        for d in bad {
            try d.write(to: URL(fileURLWithPath: store.runtimeStatePath))
            XCTAssertTrue(store.readRuntimeState() == nil, String(decoding: d.prefix(80), as: UTF8.self))
        }
        // at the cap exactly it still reads
        try (good + Data(repeating: 0x20, count: KitStore.runtimeStateCap - good.count)).write(to: URL(fileURLWithPath: store.runtimeStatePath))
        XCTAssertTrue(store.readRuntimeState() == s)
    }

    /// #1396: recordSlug writes through replace(in:). The existence check is made to see "missing" (a link that appears
    /// after it), so the write itself must refuse the link.
    func testRecordSlugRefusesALinkInPlaceOfKitEnv() throws {
        let (f, home, _) = try scene()
        let victim = f.root.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: victim)
        let layout = try KitStore.layout(configHome: home, extID: Self.ext)
        let store = try KitStore(configHome: home, extID: Self.ext, fs: KitHookFS(missing: [layout.kitEnv]))
        try store.ensureLayout()
        XCTAssertEqual(symlink(victim.path, layout.kitEnv), 0)
        XCTAssertThrowsError(try store.recordSlug("example-kit")) { XCTAssertEqual($0 as? KitStoreError, .link(layout.kitEnv)) }
        XCTAssertEqual(text(victim.path), "keep")
        XCTAssertEqual(list(layout.root).filter { $0.contains(".prosper-") }, [], "no temp is left behind")
    }

    /// R1391-s1 (QA r1322): kit.env keeps mode 0600 but an access list (set in process on the row's own file, no chflags)
    /// denies writing its data to the current user: only faccessat(AT_EACCESS) sees that; a mode-bit check would not.
    func testReplaceRefusedByAnACLDenyWhileTheModeAllowsIt() throws {
        let (_, home, store) = try scene()
        let c = context(home, store)
        XCTAssertEqual(try store.recordSlug("example-kit"), "example-kit")
        try store.writeKitEnv(c)
        let env = store.layout.kitEnv
        let before = text(env)
        var who = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(mbr_uid_to_uuid(geteuid(), &who), 0)
        var acl: acl_t? = acl_init(1)
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var perms: acl_permset_t?
        XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
        XCTAssertEqual(acl_set_tag_type(entry, ACL_EXTENDED_DENY), 0)
        XCTAssertEqual(who.withUnsafeBytes { acl_set_qualifier(entry, $0.baseAddress) }, 0)
        XCTAssertEqual(acl_get_permset(entry, &perms), 0)
        XCTAssertEqual(acl_add_perm(perms, ACL_WRITE_DATA), 0)
        XCTAssertEqual(acl_set_permset(entry, perms), 0)
        guard acl_set_file(env, ACL_TYPE_EXTENDED, acl) == 0 else { return XCTFail("acl_set_file: errno \(errno)") }
        XCTAssertEqual(mode(env), 0o600, "the mode still allows the owner to write")
        XCTAssertTrue(hasACL(env))
        XCTAssertEqual(faccessat(AT_FDCWD, env, W_OK, AT_EACCESS), -1, "the kernel says no")
        var other = c
        other.kitDir = "/Users/example/other-kit"
        XCTAssertThrowsError(try store.writeKitEnv(other)) { XCTAssertEqual($0 as? KitStoreError, .notWritable(env)) }
        XCTAssertEqual(text(env), before)
        XCTAssertEqual(mode(env), 0o600)
        XCTAssertTrue(hasACL(env), "the deny entry stays")
        XCTAssertEqual(list(store.layout.root).filter { $0.contains(".prosper-") }, [], "no temp is left behind")
    }

    /// R1391-s2 (QA r1322): a shim renamed by case only ("Tool" -> "tool") is the same file on APFS: never stale, never
    /// removed after it is written; the record then holds the new name.
    func testShimRenamedByCaseOnlyIsKept() throws {
        let (_, home, store) = try scene()
        let c = context(home, store)
        XCTAssertEqual(try store.writeShims([shim(c, "Tool")]), [])
        XCTAssertEqual(text(store.layout.bin + "/.prosper-shims"), "Tool\n")
        XCTAssertEqual(try store.writeShims([shim(c, "tool", script: "other.sh")]), [])
        XCTAssertEqual(text(store.layout.bin + "/tool"), shim(c, "tool", script: "other.sh").text)
        XCTAssertEqual(list(store.layout.bin).map { $0.lowercased() }, [".prosper-shims", "tool"])
        XCTAssertEqual(text(store.layout.bin + "/.prosper-shims"), "tool\n")
    }

    private func aged(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    func testSweepRemovesStaleStdinTemps() throws {
        let (_, _, store) = try scene()
        try store.ensureLayout()
        let fm = FileManager.default
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let tmp = store.layout.tmp + "/"
        for n in ["stdin.Ab3dE9", "stdin.Zz9yX1", "stdin.short", "stdin.Ab3dE9x"] { try Data("{}".utf8).write(to: URL(fileURLWithPath: tmp + n)) }
        try fm.createDirectory(atPath: tmp + "stdin.Qq1wE2", withIntermediateDirectories: false)
        try fm.createSymbolicLink(atPath: tmp + "stdin.Lk1nK2", withDestinationPath: store.layout.state)
        for n in ["stdin.Ab3dE9", "stdin.short", "stdin.Ab3dE9x", "stdin.Qq1wE2"] { try aged(tmp + n, old) }
        // old stdin.XXXXXX (a SIGKILL skipped the runner's trap) goes; a fresh one, a dir or link named like one and
        // a name off the pattern stay
        XCTAssertEqual(try store.sweepStaleTemps(now: now), ["stdin.Ab3dE9"])
        XCTAssertEqual(list(store.layout.tmp), ["stdin.Ab3dE9x", "stdin.Lk1nK2", "stdin.Qq1wE2", "stdin.Zz9yX1", "stdin.short"])
        XCTAssertEqual(KitPOSIXFS().kind(store.layout.state), .directory, "the link's target is untouched")
        XCTAssertEqual(try store.sweepStaleTemps(now: now.addingTimeInterval(KitStore.staleTempAge + 5)), ["stdin.Zz9yX1"])
    }

    func testSweepRemovesStaleWriterTemps() throws {
        let (_, home, store) = try scene()
        try store.installRunner()
        try store.writeShims([shim(context(home, store), "alpha")])
        let fm = FileManager.default
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let id = { UUID().uuidString }
        let inRoot = ".kit.env.prosper-" + id(), inBin = ".alpha.prosper-" + id(), inRuntime = ".prosper-kit-run.prosper-" + id()
        let fresh = ".beta.prosper-" + id(), bare = ".prosper-" + id(), lower = ".alpha.prosper-" + id().lowercased()
        let asDir = ".gamma.prosper-" + id(), noDot = "alpha.prosper-" + id()
        for p in [store.layout.root + "/" + inRoot, store.layout.bin + "/" + inBin, store.layout.kitRuntime + "/" + inRuntime,
                  store.layout.bin + "/" + fresh, store.layout.bin + "/" + bare, store.layout.bin + "/" + lower, store.layout.bin + "/" + noDot] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: p))
        }
        try fm.createDirectory(atPath: store.layout.bin + "/" + asDir, withIntermediateDirectories: false)
        for p in [store.layout.root + "/" + inRoot, store.layout.bin + "/" + inBin, store.layout.kitRuntime + "/" + inRuntime,
                  store.layout.bin + "/" + bare, store.layout.bin + "/" + lower, store.layout.bin + "/" + asDir,
                  store.layout.bin + "/" + noDot, store.layout.bin + "/alpha", store.layout.bin + "/.prosper-shims", store.layout.runner] {
            try aged(p, old)
        }
        XCTAssertEqual(try store.sweepStaleTemps(now: now).sorted(), [inRoot, inBin, inRuntime].sorted())
        XCTAssertEqual(list(store.layout.bin), [".prosper-shims", asDir, bare, fresh, lower, "alpha", noDot].sorted())
        XCTAssertEqual(list(store.layout.kitRuntime), ["prosper-kit-run"])
        XCTAssertEqual(list(store.layout.root).filter { $0.hasPrefix(".") }, [])
    }

    // #918 S2 (L1): the slug dir is the user's own layer: only writeSettingsEnv's own temp is ever swept there
    func testSweepRemovesOnlyStaleSettingsEnvTempsInTheSlugDir() throws {
        let (_, home, store) = try scene()
        XCTAssertEqual(try store.recordSlug("example-kit"), "example-kit")
        let dir = home.path + "/example-kit/"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "sub", withIntermediateDirectories: true)
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        let id = { UUID().uuidString }
        let stale = "..settings.env.prosper-" + id(), fresh = "..settings.env.prosper-" + id()
        let notes = "notes.prosper-" + id(), localMD = ".local.md.prosper-" + id(), lower = "..settings.env.prosper-" + id().lowercased()
        let twice = "..settings.env.prosper-" + id() + ".prosper-" + id(), asDir = "..settings.env.prosper-" + id()
        let nested = "sub/..settings.env.prosper-" + id()
        for n in [stale, fresh, notes, localMD, lower, twice, nested] { try Data("x".utf8).write(to: URL(fileURLWithPath: dir + n)) }
        try fm.createDirectory(atPath: dir + asDir, withIntermediateDirectories: false)
        for n in [stale, notes, localMD, lower, twice, asDir, nested, "sub"] { try aged(dir + n, old) }
        XCTAssertEqual(try store.sweepStaleTemps(now: now), [stale])
        XCTAssertEqual(list(dir), [asDir, fresh, localMD, lower, twice, notes, "sub"].sorted())
        XCTAssertEqual(list(dir + "sub").count, 1, "never recursive")
        XCTAssertEqual(try store.sweepStaleTemps(now: now.addingTimeInterval(KitStore.staleTempAge + 5)), [fresh])
    }

    func testSweepNeverFollowsALinkAtTheSlugDir() throws {
        let (_, home, store) = try scene()
        XCTAssertEqual(try store.recordSlug("example-kit"), "example-kit")
        let elsewhere = home.path + "/elsewhere"
        let temp = elsewhere + "/..settings.env.prosper-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: temp))
        let now = Date()
        try aged(temp, now.addingTimeInterval(-3600))
        try FileManager.default.createSymbolicLink(atPath: home.path + "/example-kit", withDestinationPath: elsewhere)
        XCTAssertEqual(try store.sweepStaleTemps(now: now), [])
        XCTAssertEqual(list(elsewhere).count, 1, "the link's target is untouched")
    }

    func testWriteSettingsEnvSweepsItsOwnStaleTemps() throws {
        let (_, home, store) = try scene()
        XCTAssertEqual(try store.recordSlug("example-kit"), "example-kit")
        let dir = home.path + "/example-kit/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        let now = Date()
        let stale = "..settings.env.prosper-" + UUID().uuidString, localMD = ".local.md.prosper-" + UUID().uuidString
        for n in [stale, localMD] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: dir + n))
            try aged(dir + n, now.addingTimeInterval(-3600))
        }
        try store.writeSettingsEnv(["theme": "dark"], now: now)
        XCTAssertEqual(list(dir), [".settings.env", localMD].sorted())
    }

    func testSettingsEnvRoundTripsThroughTheParserAndNothingIsExpanded() throws {
        let (_, _, store) = try scene()
        XCTAssertEqual(store.readSettingsEnv(), [:], "no slug recorded")
        let settings = ["theme": "it's a 'dark' one", "level": "2", "Path": "/Users/example/My Kit", "empty": "", "cmd": "$(example)",
                        "quotes": "'''", "wide": "caf\u{E9} \u{1F600}"]
        let expected = Dictionary(uniqueKeysWithValues: settings.map { ("KIT_" + $0.key.uppercased(), $0.value) })
        let text = try XCTUnwrap(KitRunner.settingsEnvText(settings))
        XCTAssertEqual(KitRunner.parseSettingsEnv(Data(text.utf8)), expected)
        XCTAssertEqual(try store.recordSlug("example-kit"), "example-kit")
        XCTAssertEqual(store.readSettingsEnv(), [:], "no file yet")
        try store.writeSettingsEnv(settings)
        XCTAssertEqual(store.readSettingsEnv(), expected)
        // hand-edited lines are skipped, never run or expanded; a quoted "$(...)" is literal text; a later line wins
        let hand = "KIT_A=$(example)\nKIT_B=plain\nKIT_C=\"dq\"\nKIT_D='a'b'\nKIT_E='ok'\r\nkit_f='x'\nKIT_='x'\nKIT_DIR='/x'\n"
            + "export KIT_G='x'\nKIT_H='kept'\nKIT_I='$(example)'\n# KIT_J='x'\nKIT_K='x'=''\nKIT_H='later'"
        XCTAssertEqual(KitRunner.parseSettingsEnv(Data(hand.utf8)), ["KIT_H": "later", "KIT_I": "$(example)"])
        let line = "KIT_H='x'\n"
        let over = String(repeating: line, count: KitRunner.settingsEnvCap / line.utf8.count + 1)
        XCTAssertGreaterThan(over.utf8.count, KitRunner.settingsEnvCap)
        XCTAssertEqual(KitRunner.parseSettingsEnv(Data(over.utf8)), [:], "over the cap: nothing is read")
    }
}

/// The stream seam's swap fake: when readdir of `label` reaches the end of the list, `action` runs once (it swaps
/// a dir for a link between the listing and the walk's next step). Every path it touches is the row's own.
final class KitSwapAfterListing: KitDirStream, @unchecked Sendable {
    let label: String
    private let action: @Sendable () -> Void
    private let lock = NSLock()
    private var _fired = false
    var fired: Bool { lock.withLock { _fired } }

    init(label: String, action: @escaping @Sendable () -> Void) {
        self.label = label
        self.action = action
    }

    func open(_ dir: String, fd: Int32) -> (any KitDirHandle)? {
        guard let h = KitPOSIXDirStream().open(dir, fd: fd) else { return nil }
        return dir == label ? Hooked(h, self) : h
    }

    fileprivate func fireOnce() {
        let first = lock.withLock { () -> Bool in defer { _fired = true }; return !_fired }
        if first { action() }
    }

    final class Hooked: KitDirHandle {
        let inner: any KitDirHandle
        let owner: KitSwapAfterListing
        init(_ inner: any KitDirHandle, _ owner: KitSwapAfterListing) { self.inner = inner; self.owner = owner }
        func next() -> (name: [UInt8]?, error: Int32) {
            let r = inner.next()
            if r.name == nil, r.error == 0 { owner.fireOnce() }
            return r
        }
    }
}

/// write(2) returns 0 the first time only, then writes for real (a mutant that loops on 0 then finishes, never hangs).
final class KitZeroWriteOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.withLock { defer { used = true }; return !used } }
}

/// A thread that lstat()s `path` in a loop until stopped; counts every failed lstat.
final class KitLiveWatcher: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var stopFlag = false
    private var looks = 0
    private var misses = 0
    private let done = DispatchSemaphore(value: 0)

    init(path: String) { self.path = path }

    func start() { Thread { self.loop() }.start() }

    private func loop() {
        var st = stat()
        while !lock.withLock({ stopFlag }) {
            let r = lstat(path, &st)
            lock.withLock { looks += 1; if r != 0 { misses += 1 } }
        }
        done.signal()
    }

    func stop() -> (looks: Int, misses: Int, stopped: Bool) {
        lock.withLock { stopFlag = true }
        let stopped = done.wait(timeout: .now() + 10) == .success
        return lock.withLock { (looks, misses, stopped) }
    }
}

/// A validator reader that records every path it is given.
final class KitStoreRecordingReader: KitFileReader, @unchecked Sendable {
    private let base = KitPOSIXFileReader()
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.withLock { _paths } }
    private func note(_ p: String) { lock.withLock { _paths.append(p) } }
    func kind(_ path: String) -> KitFileKind { note(path); return base.kind(path) }
    func contents(_ path: String) -> Data? { note(path); return base.contents(path) }
    func names(_ dir: String) -> [String]? { note(dir); return base.names(dir) }
    func realPath(_ path: String) -> String? { note(path); return base.realPath(path) }
}

/// A source tree held in memory under `root` (which does not exist on disk); everything else goes to the POSIX
/// store, and every write, rename and remove is recorded.
final class KitStoreMemorySourceFS: KitFS, @unchecked Sendable {
    let root: String
    let entries: [String: KitFileKind]
    private let base = KitPOSIXFS()
    private let lock = NSLock()
    private var _kinds = 0
    private var _writes: [String] = []
    var kinds: Int { lock.withLock { _kinds } }
    var writes: [String] { lock.withLock { _writes } }
    var writer: any ManagedConfigFileWriter { base.writer }

    init(root: String, entries: [String: KitFileKind]) {
        self.root = root
        self.entries = entries
    }

    private func inside(_ p: String) -> String? { p == root ? "" : p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : nil }
    private func note(_ p: String) { lock.withLock { _writes.append(p) } }

    func kind(_ path: String) -> KitFileKind {
        guard let rel = inside(path) else { return base.kind(path) }
        return kind(rel: rel)
    }

    fileprivate func kind(rel: String) -> KitFileKind {
        lock.withLock { _kinds += 1 }
        return rel.isEmpty ? .directory : entries[rel] ?? .missing
    }

    func openDir(_ path: String) throws -> any KitDir {
        guard let rel = inside(path) else { return try base.openDir(path) }
        guard rel.isEmpty || entries[rel] == .directory else { throw KitStoreError.notADirectory(path) }
        return Dir(self, rel)
    }

    /// The memory source as a held dir: children by name relative to it, as the POSIX dir does.
    final class Dir: KitDir {
        let fs: KitStoreMemorySourceFS
        let rel: String
        init(_ fs: KitStoreMemorySourceFS, _ rel: String) { self.fs = fs; self.rel = rel }
        var path: String { rel.isEmpty ? fs.root : fs.root + "/" + rel }
        private func child(_ n: String) -> String { rel.isEmpty ? n : rel + "/" + n }
        func names() -> [String]? { fs.names(path) }
        func kind(_ name: String) -> KitFileKind { fs.kind(rel: child(name)) }
        func modified(_ name: String) -> Date? { nil }
        func dir(_ name: String) throws -> any KitDir {
            guard fs.entries[child(name)] == .directory else { throw KitStoreError.notADirectory(child(name)) }
            return Dir(fs, child(name))
        }
        func read(_ name: String, limit: Int) -> Data? { fs.read(path + "/" + name, limit: limit) }
        func remove(_ name: String, dir: Bool) throws { throw KitStoreError.io("remove", EPERM) }
        func rename(_ name: String, to other: any KitDir, _ newName: String, swap: Bool) throws { throw KitStoreError.io("rename", EPERM) }
        func writable(_ name: String) -> Bool { false }
        func write(_ name: String, _ data: Data, mode: mode_t) throws { throw KitStoreError.io("create", EPERM) }
    }

    func names(_ dir: String) -> [String]? {
        guard let rel = inside(dir) else { return base.names(dir) }
        let prefix = rel.isEmpty ? "" : rel + "/"
        return entries.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .map { String($0.dropFirst(prefix.count)) }.sorted()
    }

    func read(_ path: String, limit: Int) -> Data? {
        guard let rel = inside(path) else { return base.read(path, limit: limit) }
        guard case .file(_, let size)? = entries[rel], size <= Int64(limit), size >= 0 else { return nil }
        return Data(count: Int(size))
    }

    func ensureDir(_ path: String, narrow: Bool) throws { note(path); try base.ensureDir(path, narrow: narrow) }
    func create(_ path: String, _ data: Data, mode: mode_t) throws { note(path); try base.create(path, data, mode: mode) }
    func rename(_ from: String, _ to: String) throws { note(from); note(to); try base.rename(from, to) }
}

/// The directory-stream seam's fake: in `failIn`, readdir gives one real name, then NULL with EIO.
struct KitFailingDirStream: KitDirStream {
    let failIn: String

    func open(_ dir: String, fd: Int32) -> (any KitDirHandle)? {
        guard let h = KitPOSIXDirStream().open(dir, fd: fd) else { return nil }
        return dir == failIn ? FailAfterOne(h) : h
    }

    final class FailAfterOne: KitDirHandle {
        let inner: any KitDirHandle
        var calls = 0
        init(_ inner: any KitDirHandle) { self.inner = inner }
        func next() -> (name: [UInt8]?, error: Int32) {
            calls += 1
            guard calls == 1 else { return (nil, EIO) }
            while true {
                let r = inner.next()
                guard let n = r.name else { return r }
                if n != Array(".".utf8), n != Array("..".utf8) { return (n, 0) }
            }
        }
    }
}

/// The POSIX store disk, except that the Nth dir-relative rename (counted from 1) throws EIO and renames nothing: the
/// state a crash between two steps of the swap leaves behind. Every path it touches is the row's own.
final class KitFailNthRename: KitFS, @unchecked Sendable {
    let n: Int
    private let base = KitPOSIXFS()
    private let lock = NSLock()
    private var renames = 0
    init(_ n: Int) { self.n = n }

    var writer: any ManagedConfigFileWriter { base.writer }
    func openDir(_ path: String) throws -> any KitDir { Dir(self, try base.openDir(path)) }
    func kind(_ path: String) -> KitFileKind { base.kind(path) }
    func names(_ dir: String) -> [String]? { base.names(dir) }
    func read(_ path: String, limit: Int) -> Data? { base.read(path, limit: limit) }
    func ensureDir(_ path: String, narrow: Bool) throws { try base.ensureDir(path, narrow: narrow) }
    func create(_ path: String, _ data: Data, mode: mode_t) throws { try base.create(path, data, mode: mode) }
    func rename(_ from: String, _ to: String) throws { try base.rename(from, to) }
    fileprivate func failsNow() -> Bool { lock.withLock { renames += 1; return renames == n } }

    final class Dir: KitDir {
        let fs: KitFailNthRename
        let inner: any KitDir
        init(_ fs: KitFailNthRename, _ inner: any KitDir) { self.fs = fs; self.inner = inner }
        var path: String { inner.path }
        func names() -> [String]? { inner.names() }
        func kind(_ name: String) -> KitFileKind { inner.kind(name) }
        func modified(_ name: String) -> Date? { inner.modified(name) }
        func dir(_ name: String) throws -> any KitDir { Dir(fs, try inner.dir(name)) }
        func read(_ name: String, limit: Int) -> Data? { inner.read(name, limit: limit) }
        func remove(_ name: String, dir: Bool) throws { try inner.remove(name, dir: dir) }
        func rename(_ name: String, to other: any KitDir, _ newName: String, swap: Bool) throws {
            if fs.failsNow() { throw KitStoreError.io("rename", EIO) }
            try inner.rename(name, to: (other as? Dir)?.inner ?? other, newName, swap: swap)
        }
        func writable(_ name: String) -> Bool { inner.writable(name) }
        func write(_ name: String, _ data: Data, mode: mode_t) throws { try inner.write(name, data, mode: mode) }
    }
}

/// A KitFS over the real one: `afterRead(dirPath, name)` runs after a dir handle reads a file (a swap between the
/// walk's read and the write), and `missing` paths report .missing from kind(path). Every path is the row's own.
final class KitHookFS: KitFS, @unchecked Sendable {
    private let base = KitPOSIXFS()
    let afterRead: @Sendable (String, String) -> Void
    let missing: Set<String>
    init(afterRead: @escaping @Sendable (String, String) -> Void = { _, _ in }, missing: Set<String> = []) {
        self.afterRead = afterRead
        self.missing = missing
    }

    var writer: any ManagedConfigFileWriter { base.writer }
    func openDir(_ path: String) throws -> any KitDir { Dir(self, try base.openDir(path)) }
    func kind(_ path: String) -> KitFileKind { missing.contains(path) ? .missing : base.kind(path) }
    func names(_ dir: String) -> [String]? { base.names(dir) }
    func read(_ path: String, limit: Int) -> Data? { base.read(path, limit: limit) }
    func ensureDir(_ path: String, narrow: Bool) throws { try base.ensureDir(path, narrow: narrow) }
    func create(_ path: String, _ data: Data, mode: mode_t) throws { try base.create(path, data, mode: mode) }
    func rename(_ from: String, _ to: String) throws { try base.rename(from, to) }

    final class Dir: KitDir {
        let fs: KitHookFS
        let inner: any KitDir
        init(_ fs: KitHookFS, _ inner: any KitDir) { self.fs = fs; self.inner = inner }
        var path: String { inner.path }
        func names() -> [String]? { inner.names() }
        func kind(_ name: String) -> KitFileKind { inner.kind(name) }
        func modified(_ name: String) -> Date? { inner.modified(name) }
        func dir(_ name: String) throws -> any KitDir { Dir(fs, try inner.dir(name)) }
        func read(_ name: String, limit: Int) -> Data? {
            let d = inner.read(name, limit: limit)
            fs.afterRead(inner.path, name)
            return d
        }
        func remove(_ name: String, dir: Bool) throws { try inner.remove(name, dir: dir) }
        func rename(_ name: String, to other: any KitDir, _ newName: String, swap: Bool) throws {
            try inner.rename(name, to: (other as? Dir)?.inner ?? other, newName, swap: swap)
        }
        func writable(_ name: String) -> Bool { inner.writable(name) }
        func write(_ name: String, _ data: Data, mode: mode_t) throws { try inner.write(name, data, mode: mode) }
    }
}
