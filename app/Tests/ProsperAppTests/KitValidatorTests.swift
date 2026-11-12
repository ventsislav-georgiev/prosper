import Foundation
import XCTest
@testable import ProsperApp

/// A fixture kit dir with every piece kind, under a tempDir(). Its path has a space on purpose.
struct KitDirFixture {
    let root: URL
    let kit: URL

    static let readme = """
    # Calm Agent Kit

    ## What it changes
    A block in CLAUDE.md, one PreToolUse hook, the status line, two permission rules, one tool.

    ## Requirements
    node, on PATH.

    ## Customise
    Put your own lines in local.md; Claude Code reads it last.

    ## Remove
    Remove in Settings undoes the wiring and leaves your seeded notes.

    """
    static let claudeMD = "# Calm agent rules\n\nKeep answers short. Kit tools live in {{kit_bin}}.\n\n@{{kit_config}}/local.md\n"
    static let guardScript = "#!/bin/sh\n# reads {{kit_dir}} from KIT_DIR; never rendered\nexit 0\n"

    func url(_ rel: String) -> URL { kit.appendingPathComponent(rel) }

    func write(_ rel: String, _ text: String, mode: Int = 0o644) throws { try write(rel, Data(text.utf8), mode: mode) }

    func write(_ rel: String, _ data: Data, mode: Int = 0o644) throws {
        let u = url(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: u.path)
    }

    func remove(_ rel: String) throws { try FileManager.default.removeItem(at: url(rel)) }

    func symlink(_ rel: String, to dest: String) throws {
        try FileManager.default.createDirectory(at: url(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url(rel).path, withDestinationPath: dest)
    }

    func validate(_ kitTOML: String = KitFixture.kit, head: String = KitFixture.head, source: KitInstallSource = .market,
                  others: Set<String> = [], reader: any KitFileReader = KitPOSIXFileReader()) throws -> KitValidation {
        KitValidator.validate(kitDir: kit, manifest: try KitFixture.manifest(kitTOML, head: head), source: source,
                              otherKitSlugs: others, reader: reader)
    }
}

extension XCTestCase {
    func makeKitDir(under root: URL? = nil, label: String = #function) throws -> KitDirFixture {
        let root = root ?? tempDir(label)
        let f = KitDirFixture(root: root, kit: root.appendingPathComponent("kits/calm agent", isDirectory: true))
        try f.write("README.md", KitDirFixture.readme)
        try f.write("CLAUDE.md", KitDirFixture.claudeMD)
        try f.write("init.lua", "return {}\n")
        try f.write("hooks/guard.sh", KitDirFixture.guardScript, mode: 0o755)
        try f.write("statusline/hud.mjs", "console.log('calm')\n")
        try f.write("tools/calm-note", "#!/bin/sh\necho note\n", mode: 0o755)
        try f.write("seed/notes.toml", "# your notes\n")
        return f
    }
}

/// An in-memory kit dir: proves the validator reads only through its seam.
final class KitMemoryReader: KitFileReader, @unchecked Sendable {
    let files: [String: (mode: UInt16, data: Data)]
    let dirs: Set<String>
    private let lock = NSLock()
    private var _touched: Set<String> = []
    var touched: Set<String> { lock.withLock { _touched } }
    private var _reads: [String: Int] = [:]
    /// contents() calls per absolute path
    var reads: [String: Int] { lock.withLock { _reads } }
    /// symlink entries: absolute path -> what realpath resolves it to
    let symlinks: [String: String]
    private var _realPaths: [String: Int] = [:]
    /// realPath() calls per absolute path
    var realPaths: [String: Int] { lock.withLock { _realPaths } }

    /// modes: rel path -> mode, over the hooks/ and tools/ 0o755, else 0o644 default
    init(root: String, files: [String: String], symlinks: [String: String] = [:], modes: [String: UInt16] = [:]) {
        var f: [String: (mode: UInt16, data: Data)] = [:]
        var d: Set<String> = [root]
        for (rel, text) in files {
            f[root + "/" + rel] = (modes[rel] ?? (rel.hasPrefix("hooks/") || rel.hasPrefix("tools/") ? 0o755 : 0o644), Data(text.utf8))
            var parent = ((root + "/" + rel) as NSString).deletingLastPathComponent
            while parent.count > root.count { d.insert(parent); parent = (parent as NSString).deletingLastPathComponent }
        }
        self.files = f
        self.dirs = d
        self.symlinks = Dictionary(uniqueKeysWithValues: symlinks.map { (root + "/" + $0.key, $0.value) })
    }

    private func touch(_ p: String) { _ = lock.withLock { _touched.insert(p) } }

    func kind(_ path: String) -> KitFileKind {
        touch(path)
        if let f = files[path] { return .file(mode: f.mode, size: Int64(f.data.count)) }
        if symlinks[path] != nil { return .symlink }
        return dirs.contains(path) ? .directory : .missing
    }
    func contents(_ path: String) -> Data? {
        touch(path)
        lock.withLock { _reads[path, default: 0] += 1 }
        return files[path]?.data
    }
    func names(_ dir: String) -> [String]? {
        touch(dir)
        guard dirs.contains(dir) else { return nil }
        let all = Array(files.keys) + Array(dirs) + Array(symlinks.keys)
        return Set(all.filter { ($0 as NSString).deletingLastPathComponent == dir }.map { ($0 as NSString).lastPathComponent }).sorted()
    }
    func realPath(_ path: String) -> String? {
        touch(path)
        lock.withLock { _realPaths[path, default: 0] += 1 }
        if let target = symlinks[path] { return target }
        return files[path] != nil || dirs.contains(path) ? path : nil
    }
}

final class KitValidatorTests: XCTestCase {
    private struct Refused: Error {}
    private func refusals(_ v: KitValidation) -> [KitRefusal] {
        if case .refused(let r) = v { return r }
        return []
    }

    private func validated(_ v: KitValidation, file: StaticString = #filePath, line: UInt = #line) throws -> KitValidated {
        guard case .ok(let k) = v else { XCTFail("refused: \(refusals(v))", file: file, line: line); throw Refused() }
        return k
    }

    private func assertRefused(_ v: KitValidation, _ subject: String, _ reason: KitReason, line: UInt = #line) {
        XCTAssertTrue(refusals(v).contains(KitRefusal(subject: subject, reason: reason)), "\(refusals(v))", line: line)
    }

    func testFixtureKitValidates() throws {
        let f = try makeKitDir()
        let v = try validated(f.validate())
        XCTAssertEqual(v.extensionID, "dev.example.kit.calm-agent")
        XCTAssertEqual(v.slug, "calm-agent")
        XCTAssertEqual(v.tools["tools"], [KitFileRef(name: "calm-note", path: "tools/calm-note")])
        XCTAssertEqual(v.seeds["config"], [KitFileRef(name: "notes.toml", path: "seed/notes.toml")])
        XCTAssertEqual(v.warnings, [])
    }

    func testValidatorReadsOnlyThroughItsSeam() throws {
        let root = "/fake/kits/calm agent"
        let reader = KitMemoryReader(root: root, files: [
            "README.md": KitDirFixture.readme, "CLAUDE.md": KitDirFixture.claudeMD, "hooks/guard.sh": KitDirFixture.guardScript,
            "statusline/hud.mjs": "console.log('calm')\n", "tools/calm-note": "#!/bin/sh\n", "seed/notes.toml": "# n\n",
        ])
        let v = KitValidator.validate(kitDir: URL(fileURLWithPath: root), manifest: try KitFixture.manifest(), source: .market,
                                      otherKitSlugs: [], reader: reader)
        XCTAssertEqual(try validated(v).tools["tools"]?.map(\.name), ["calm-note"])
        XCTAssertTrue(reader.touched.allSatisfy { $0.hasPrefix(root) }, "\(reader.touched)")
    }

    // MARK: README (spec 4.3)

    func testMissingReadmeRefused() throws {
        let f = try makeKitDir()
        try f.remove("README.md")
        assertRefused(try f.validate(), "README.md", .noReadme)
        assertRefused(try f.validate(source: .local), "README.md", .noReadme)
    }

    func testReadmeHeadingsAnyOrderAnyCaseOutsideFences() throws {
        let f = try makeKitDir()
        try f.write("README.md", "# Kit\n## remove\n## CUSTOMISE ##\n## Requirements\n## What It Changes\n")
        _ = try validated(f.validate())
        try f.write("README.md", "# Kit\n## remove\n## Customise\n### Requirements\n```\n## Requirements\n```\n## What it changes\n")
        let v = try f.validate()
        assertRefused(v, "README.md ## Requirements", .readmeHeading)
        XCTAssertEqual(refusals(v).count, 1, "\(refusals(v))")
    }

    // MARK: paths (spec 4.2, 2.1 checks 1-2, symlinks)

    func testDotDotInRunRefused() throws {
        let f = try makeKitDir()
        try "#!/bin/sh\n".write(to: f.kit.deletingLastPathComponent().appendingPathComponent("escape.sh"), atomically: true, encoding: .utf8)
        for run in ["../escape.sh", "hooks/../../escape.sh", "./hooks/guard.sh"] {
            assertRefused(try f.validate(KitFixture.kit(replacing: "hooks/guard.sh", with: run)), "guard.run", .badPath)
        }
        assertRefused(try f.validate(KitFixture.kit(replacing: "hooks/guard.sh", with: "/bin/sh")), "guard.run", .badPath)
        assertRefused(try f.validate(KitFixture.kit(replacing: "CLAUDE.md\"", with: "../CLAUDE.md\"")), "rules.source", .badPath)
        assertRefused(try f.validate(KitFixture.kit(replacing: "dir  = \"tools\"", with: "dir  = \"tools/../..\"")), "tools.dir", .badPath)
        assertRefused(try f.validate(KitFixture.kit(replacing: "from = \"seed/\"", with: "from = \"../\"")), "config.from", .badPath)
    }

    func testSymlinkLeavingKitRefused() throws {
        let f = try makeKitDir()
        let outside = f.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: outside.appendingPathComponent("x.sh"), atomically: true, encoding: .utf8)
        try f.symlink("hooks/link.sh", to: outside.appendingPathComponent("x.sh").path)
        assertRefused(try f.validate(KitFixture.kit(replacing: "hooks/guard.sh", with: "hooks/link.sh")), "guard.run", .pathLeaves)
        // through a symlinked parent
        try f.symlink("lib", to: outside.path)
        assertRefused(try f.validate(KitFixture.kit(replacing: "hooks/guard.sh", with: "lib/x.sh")), "guard.run", .pathLeaves)
        assertRefused(try f.validate(KitFixture.kit(replacing: "dir  = \"tools\"", with: "dir  = \"lib\"")), "tools.dir", .pathLeaves)
    }

    func testSymlinkInsideKitRefused() throws {
        let f = try makeKitDir()
        try f.symlink("hooks/alias.sh", to: f.url("hooks/guard.sh").path)
        assertRefused(try f.validate(KitFixture.kit(replacing: "hooks/guard.sh", with: "hooks/alias.sh")), "guard.run", .pathSymlink)
        try f.symlink("seed/linked.toml", to: f.url("seed/notes.toml").path)
        assertRefused(try f.validate(), "seed/linked.toml", .pathSymlink)
    }

    func testPathsNameTheRightKind() throws {
        let f = try makeKitDir()
        assertRefused(try f.validate(KitFixture.kit(replacing: "hooks/guard.sh", with: "hooks")), "guard.run", .needsFile)
        assertRefused(try f.validate(KitFixture.kit(replacing: "dir  = \"tools\"", with: "dir  = \"README.md\"")), "tools.dir", .needsDir)
        assertRefused(try f.validate(KitFixture.kit(replacing: "hooks/guard.sh", with: "hooks/none.sh")), "guard.run", .pathMissing)
        assertRefused(try f.validate(KitFixture.kit(replacing: "CLAUDE.md\"", with: "init.lua\"")), "rules.source", .needsMarkdown)
    }

    // MARK: executables (spec 4.9)

    func testMachOInMarketKitRefusedLocalWarned() throws {
        let f = try makeKitDir()
        try f.write("tools/calm-bin", Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01]), mode: 0o755)
        assertRefused(try f.validate(source: .market), "tools/calm-bin", .binaryExecutable)
        let local = try validated(f.validate(source: .local))
        XCTAssertEqual(local.warnings, [KitRefusal(subject: "tools/calm-bin", reason: .binaryExecutable)])
        // any file with an x bit counts, referenced or not; a mode-less run target counts too
        try f.remove("tools/calm-bin")
        try f.write("bin/helper", Data([0x7F, 0x45, 0x4C, 0x46, 0x00]), mode: 0o755)
        assertRefused(try f.validate(source: .market), "bin/helper", .binaryExecutable)
        try f.remove("bin/helper")
        try f.write("hooks/guard.sh", Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]), mode: 0o644)
        assertRefused(try f.validate(source: .market), "hooks/guard.sh", .binaryExecutable)
        XCTAssertFalse(KitValidator.isText(Data("#!/bin/sh\n\0".utf8)))
        XCTAssertTrue(KitValidator.isText(Data("#!/bin/sh\necho ü\n".utf8)))
    }

    // MARK: slug (spec 2.1, 4.8)

    func testSlugClashAndBadSlug() throws {
        let f = try makeKitDir()
        assertRefused(try f.validate(others: ["calm-agent"]), "extension.name", .slugTaken)
        _ = try validated(f.validate(others: ["other-kit"]))
        let head = KitFixture.head.replacingOccurrences(of: "name        = \"calm-agent\"", with: "name        = \"Calm_Agent\"")
        assertRefused(try f.validate(head: head), "extension.name", .badSlug)
        let badID = KitFixture.head.replacingOccurrences(of: "\"dev.example.kit.calm-agent\"", with: "\"..\"")
        assertRefused(try f.validate(head: badID), "extension.id", .badExtensionID)
        // {{kit_config}} of slug "prosper" would be the runtime's own dir
        let reserved = KitFixture.head.replacingOccurrences(of: "name        = \"calm-agent\"", with: "name        = \"prosper\"")
        assertRefused(try f.validate(head: reserved), "extension.name", .slugReserved)
    }

    // MARK: CLAUDE.md (spec 4.5 item 1, errata A2)

    func testLocalImportMustBeTheLastLine() throws {
        let f = try makeKitDir()
        try f.write("CLAUDE.md", "# rules\n@{{kit_config}}/local.md\n\nMore rules after it.\n")
        assertRefused(try f.validate(), "CLAUDE.md", .localImportLast)
        try f.write("CLAUDE.md", "# rules\r\n@{{kit_config}}/local.md  \r\n\r\n\n")
        _ = try validated(f.validate())
    }

    func testImportChainDeeperThanTwoRefused() throws {
        let f = try makeKitDir()
        // CLAUDE.md -> a.md (1) -> b.md (2): fits. Mentions, code spans and fences are not imports.
        try f.write("CLAUDE.md", "See @a.md and ping @someone.\n`@deep.md`\n```\n@deep.md\n```\n@{{kit_config}}/local.md\n")
        try f.write("a.md", "@{{kit_dir}}/b.md\n")
        try f.write("b.md", "plain\n")
        try f.write("deep.md", "@b.md\n")
        _ = try validated(f.validate())
        // b.md -> c.md (3): too deep
        try f.write("b.md", "@c.md\n")
        try f.write("c.md", "end\n")
        assertRefused(try f.validate(), "CLAUDE.md", .importTooDeep)
        // an import outside the kit counts as a level too
        try f.write("b.md", "@{{home}}/notes.md\n")
        assertRefused(try f.validate(), "CLAUDE.md", .importTooDeep)
        // a cycle is refused by the depth bound
        try f.write("b.md", "@a.md\n")
        assertRefused(try f.validate(), "CLAUDE.md", .importTooDeep)
        XCTAssertEqual(KitValidator.imports(in: "x @a\\ b.md y\n`@no.md` @c.md"), ["a b.md", "c.md"])
    }

    // MARK: round 2 F1: bounded import walk

    private let memRoot = "/fake/kits/calm agent"

    private func memoryKit(_ extra: [String: String], symlinks: [String: String] = [:], modes: [String: UInt16] = [:]) -> KitMemoryReader {
        var files = ["README.md": KitDirFixture.readme, "hooks/guard.sh": KitDirFixture.guardScript, "statusline/hud.mjs": "console.log('calm')\n",
                     "tools/calm-note": "#!/bin/sh\n", "seed/notes.toml": "# n\n"]
        files.merge(extra) { $1 }
        return KitMemoryReader(root: memRoot, files: files, symlinks: symlinks, modes: modes)
    }

    private func validate(_ reader: KitMemoryReader) throws -> KitValidation {
        KitValidator.validate(kitDir: URL(fileURLWithPath: memRoot), manifest: try KitFixture.manifest(), source: .market,
                              otherKitSlugs: [], reader: reader)
    }

    /// 5000 spellings of one file, which a second import (c.md) reaches too: it is read once, the
    /// kit CLAUDE.md once.
    func testImportSpellingsReadEachFileOnce() throws {
        var md = "@a.md @./a.md @{{kit_dir}}/a.md @c.md\n"
        for i in 0..<5000 { md += "@d\(i)/../a.md\n" }
        let reader = memoryKit(["CLAUDE.md": md + "@{{kit_config}}/local.md\n", "a.md": "plain\n", "c.md": "@a.md @x/../a.md\n"])
        _ = try validated(validate(reader))
        XCTAssertEqual(reader.reads[memRoot + "/a.md"], 1)
        XCTAssertEqual(reader.reads[memRoot + "/c.md"], 1)
        XCTAssertEqual(reader.reads[memRoot + "/CLAUDE.md"], 1)
    }

    /// CLAUDE.md -> 60 files -> the same 60 leaf files: every file read once.
    func testImportFanReadsEachFileOnce() throws {
        let bs = (0..<60).map { "@b\($0).md" }.joined(separator: " ") + "\n"
        var files = ["CLAUDE.md": (0..<60).map { "@a\($0).md" }.joined(separator: "\n") + "\n@{{kit_config}}/local.md\n"]
        for i in 0..<60 { files["a\(i).md"] = bs; files["b\(i).md"] = "leaf\n" }
        let reader = memoryKit(files)
        _ = try validated(validate(reader))
        for i in 0..<60 {
            XCTAssertEqual(reader.reads[memRoot + "/a\(i).md"], 1, "a\(i)")
            XCTAssertEqual(reader.reads[memRoot + "/b\(i).md"], 1, "b\(i)")
        }
    }

    /// round 3 G1: 5000 distinct paths under one symlinked dir: realPath asked once for that entry,
    /// one refusal.
    func testSymlinkImportDecidedOncePerEntry() throws {
        var md = "@a.md\n"
        for i in 0..<5000 { md += "@lib/x\(i).md\n" }
        let reader = memoryKit(["CLAUDE.md": md + "@{{kit_config}}/local.md\n", "a.md": "@lib/y.md @lib/x1.md\n"],
                               symlinks: ["lib": "/elsewhere/lib"])
        let r = refusals(try validate(reader))
        XCTAssertEqual(r.filter { $0.subject == "lib" }, [KitRefusal(subject: "lib", reason: .pathLeaves)], "\(r)")
        XCTAssertEqual(reader.realPaths[memRoot + "/lib"], 1)
    }

    func testMoreThan64ImportTargetsRefused() throws {
        func kit(_ n: Int) -> KitMemoryReader {
            var files = ["CLAUDE.md": (0..<n).map { "@t\($0).md" }.joined(separator: "\n") + "\n@{{kit_config}}/local.md\n"]
            for i in 0..<n { files["t\(i).md"] = "leaf\n" }
            return memoryKit(files)
        }
        _ = try validated(validate(kit(64)))
        XCTAssertTrue(refusals(try validate(kit(65))).contains(KitRefusal(subject: "CLAUDE.md", reason: .tooManyImports)))
    }

    /// Claude Code follows a symlinked import, so the walk refuses it rather than skipping it.
    func testSymlinkImportRefused() throws {
        let f = try makeKitDir()
        let outside = f.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "leaf\n".write(to: outside.appendingPathComponent("x.md"), atomically: true, encoding: .utf8)
        try f.write("a.md", "leaf\n")
        try f.symlink("inside.md", to: f.url("a.md").path)
        try f.symlink("out.md", to: outside.appendingPathComponent("x.md").path)
        try f.symlink("lib", to: outside.path)
        let local = "@{{kit_config}}/local.md\n"
        try f.write("CLAUDE.md", "@inside.md\n" + local)
        assertRefused(try f.validate(), "inside.md", .pathSymlink)
        try f.write("CLAUDE.md", "@out.md\n" + local)
        assertRefused(try f.validate(), "out.md", .pathLeaves)
        try f.write("CLAUDE.md", "@a.md\n" + local)
        try f.write("a.md", "@lib/x.md\n")
        assertRefused(try f.validate(), "lib", .pathLeaves)
    }

    // MARK: round 4: setuid and setgid files

    /// A tool file, a seed file and an unreferenced bin/ file: the walk reaches every one.
    func testSetuidOrSetgidFileRefusedWherever() throws {
        for path in ["tools/calm-note", "seed/notes.toml", "bin/helper"] {
            for mode: UInt16 in [0o4755, 0o2755, 0o6755, 0o4644, 0o2644] {
                let reader = memoryKit(["CLAUDE.md": KitDirFixture.claudeMD, "bin/helper": "#!/bin/sh\n"], modes: [path: mode])
                let r = refusals(try validate(reader))
                XCTAssertEqual(r.filter { $0.reason == .setuid }, [KitRefusal(subject: path, reason: .setuid)], "\(path) \(String(mode, radix: 8))")
            }
        }
    }

    func testStickyOrPlainModeNotRefusedForSetuid() throws {
        for mode: UInt16 in [0o1755, 0o755, 0o1644, 0o644] {
            let modes = ["tools/calm-note": mode, "seed/notes.toml": mode, "bin/helper": mode]
            let r = refusals(try validate(memoryKit(["CLAUDE.md": KitDirFixture.claudeMD, "bin/helper": "#!/bin/sh\n"], modes: modes)))
            XCTAssertEqual(r.filter { $0.reason == .setuid }, [], "\(String(mode, radix: 8)): \(r)")
        }
        _ = try validated(validate(memoryKit(["CLAUDE.md": KitDirFixture.claudeMD], modes: ["tools/calm-note": 0o1755])))
    }

    /// The disk reader keeps st_mode & 0o7777, so the bit lstat reports reaches the check.
    func testSetuidFileOnDiskRefused() throws {
        let f = try makeKitDir()
        let p = f.url("tools/calm-note").path
        defer { try? f.remove("tools/calm-note") }
        var stuck: [mode_t] = []
        for bit: mode_t in [0o4000, 0o2000] {
            guard chmod(p, 0o755 | bit) == 0 else { throw XCTSkip("chmod \(String(bit, radix: 8)) refused: errno \(errno)") }
            var st = stat()
            guard lstat(p, &st) == 0 else { throw XCTSkip("lstat: errno \(errno)") }
            // setgid sticks only for a member of the file's group; setuid must stick for the owner
            guard st.st_mode & bit != 0 else { if bit == 0o4000 { throw XCTSkip("the filesystem dropped setuid") }; continue }
            stuck.append(bit)
            let r = refusals(try f.validate())
            XCTAssertEqual(r.filter { $0.reason == .setuid }, [KitRefusal(subject: "tools/calm-note", reason: .setuid)], String(bit, radix: 8))
        }
        XCTAssertEqual(stuck.first, 0o4000)
    }

    // MARK: tools and seeds

    func testToolsDirHoldsOnlyFilesAndSkipsDotfiles() throws {
        let f = try makeKitDir()
        try f.write("tools/.DS_Store", "x")
        let v = try validated(f.validate())
        XCTAssertEqual(v.warnings, [KitRefusal(subject: "tools/.DS_Store", reason: .dotfileSkipped)])
        XCTAssertEqual(v.tools["tools"]?.map(\.name), ["calm-note"])
        try f.write("tools/sub/x", "#!/bin/sh\n", mode: 0o755)
        assertRefused(try f.validate(), "tools/sub", .toolsNotFile)
        try f.remove("tools/sub")
        try f.write("tools/-rf", "#!/bin/sh\n", mode: 0o755)
        assertRefused(try f.validate(), "tools/-rf", .badFileName)
    }

    func testDuplicateToolNameAcrossPiecesRefused() throws {
        let f = try makeKitDir()
        try f.write("more/calm-note", "#!/bin/sh\n", mode: 0o755)
        let second = "\n[[contributes.kit.pieces]]\nid = \"more\"\nkind = \"tools\"\ndir = \"more\"\n"
        assertRefused(try f.validate(KitFixture.kit(replacing: "[[contributes.kit.settings]]", with: second + "\n[[contributes.kit.settings]]")),
                      "more/calm-note", .duplicateTool)
        // one {{kit_bin}} dir on a case-insensitive volume: case variants are one shim
        try f.remove("more/calm-note")
        try f.write("more/Calm-Note", "#!/bin/sh\n", mode: 0o755)
        assertRefused(try f.validate(KitFixture.kit(replacing: "[[contributes.kit.settings]]", with: second + "\n[[contributes.kit.settings]]")),
                      "more/Calm-Note", .duplicateTool)
    }

    func testSeedFilesNestedAndClashing() throws {
        let f = try makeKitDir()
        try f.write("seed/hooks/start.pre", "#!/bin/sh\n")
        try f.write("seed/.hidden/x", "x")
        let v = try validated(f.validate())
        XCTAssertEqual(v.seeds["config"]?.map(\.name), ["hooks/start.pre", "notes.toml"])
        XCTAssertEqual(v.warnings, [KitRefusal(subject: "seed/.hidden", reason: .dotfileSkipped)])
        try f.write("seed/hooks.start.pre", "x")
        assertRefused(try f.validate(), "seed/hooks/start.pre", .seedClash)
        // two seed pieces naming one kitconfig file, case-folded
        try f.remove("seed/hooks.start.pre")
        try f.write("more/NOTES.toml", "x")
        let two = KitFixture.kit(replacing: "\n[[contributes.kit.settings]]",
                                 with: "\n[[contributes.kit.pieces]]\nid   = \"more\"\nkind = \"seed\"\nfrom = \"more\"\n\n[[contributes.kit.settings]]")
        assertRefused(try f.validate(two), "more/NOTES.toml", .seedClash)
    }

    /// spec 4.12 item 1 "env piece", through the whole validator.
    func testEnvPieceRefusedAtInstall() throws {
        let f = try makeKitDir()
        assertRefused(try f.validate(KitFixture.kit(replacing: "kind = \"seed\"", with: "kind = \"env\"")), "pieces[5].kind", .unknownKind)
    }

    /// Text reads stop at 1 MiB before reading: an oversize README or kit CLAUDE.md is not text.
    func testOversizeTextRefused() throws {
        let f = try makeKitDir()
        let big = String(repeating: "x", count: KitValidator.maxTextBytes) + "\n"
        try f.write("README.md", KitDirFixture.readme + big)
        try f.write("CLAUDE.md", big + "@{{kit_config}}/local.md\n")
        let r = refusals(try f.validate())
        XCTAssertTrue(r.contains(KitRefusal(subject: "README.md", reason: .notText)), "\(r)")
        XCTAssertTrue(r.contains(KitRefusal(subject: "CLAUDE.md", reason: .notText)), "\(r)")
    }

    func testManifestWithoutKitIsNotAKit() throws {
        let f = try makeKitDir()
        let v = KitValidator.validate(kitDir: f.kit, manifest: try KitFixture.manifest(""), source: .local, otherKitSlugs: [])
        XCTAssertEqual(refusals(v), [KitRefusal(subject: "kit", reason: .notATable)])
    }
}
