import Darwin
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
        XCTAssertEqual(dirs, 10)
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
        XCTAssertEqual(list(store.layout.root), ["bin", "fired", "kit.env", "live", "previous", "staged", "state", "tmp"])
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
        lock.withLock { _kinds += 1 }
        return rel.isEmpty ? .directory : entries[rel] ?? .missing
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
    func remove(_ path: String, dir: Bool) throws { note(path); try base.remove(path, dir: dir) }
}

/// The directory-stream seam's fake: in `failIn`, readdir gives one real name, then NULL with EIO.
struct KitFailingDirStream: KitDirStream {
    let failIn: String

    func open(_ dir: String) -> (any KitDirHandle)? {
        guard let h = KitPOSIXDirStream().open(dir) else { return nil }
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
