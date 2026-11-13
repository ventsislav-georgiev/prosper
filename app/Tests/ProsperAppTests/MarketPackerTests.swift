import Foundation
import XCTest
@testable import ProsperApp

/// #1131: what a Marketplace publish packs, and what an install keeps. Every fixture is built in the
/// test's own temp dir; nothing here touches the network or the installed extensions folder.
final class MarketPackerTests: XCTestCase {

    // MARK: - The rules (pure)

    func testHiddenRuleTable() {
        let names = ["init.lua", "extension.toml", "themes/dark.json", ".", "./init.lua", "a..b/c", "lib/x.",
                     "a\n.x", ".omc", ".omc/state/x.json", "./.omc/x", ".DS_Store", "lib/.DS_Store",
                     "lib/sub/.hidden.lua", "._init.lua", "lib/._util.lua", "...", "a/../.x", "..",
                     ".gitignore", ".github/workflows/ci.yml"]
        let hidden: Set = [".omc", ".omc/state/x.json", "./.omc/x", ".DS_Store", "lib/.DS_Store",
                           "lib/sub/.hidden.lua", "._init.lua", "lib/._util.lua", "...", "a/../.x", "..",
                           ".gitignore", ".github/workflows/ci.yml"]
        XCTAssertEqual(Set(names.filter(RemoteInstaller.isHiddenMember)), hidden)
    }

    func testPublishRuleTable() {
        let names = ["init.lua", "lib/util.lua", "lib/mytests.lua", "lib/testsx/a.lua", "tests/a.lua",
                     "lib/tests/t.lua", "tests", "a.test.lua", "lib/a.test.lua", ".omc/state/x.json",
                     "lib/sub/.hidden.lua"]
        let leftOut: Set = ["tests/a.lua", "lib/tests/t.lua", "tests", "a.test.lua", "lib/a.test.lua",
                            ".omc/state/x.json", "lib/sub/.hidden.lua"]
        XCTAssertEqual(Set(names.filter(RemoteInstaller.isLeftOutOfPublish)), leftOut)
    }

    // MARK: - Pack

    func testPackLeavesOutHiddenTestsAndMacMetadata() throws {
        let tmp = tempDir()
        let ext = tmp.appendingPathComponent("ext")
        for rel in ["extension.toml", "init.lua", "lib/util.lua", "lib/mytests.lua", "themes/dark.json",
                    ".omc/state/x.json", ".DS_Store", "lib/sub/.hidden.lua", "lib/.cache/c", "._init.lua",
                    "tests/a.lua", "lib/tests/t.lua", "lib/a.test.lua"] {
            try write(ext, rel)
        }
        // An extended attribute makes macOS tar add a "._init.lua" AppleDouble member unless told not to.
        let value = Array("1".utf8)
        XCTAssertEqual(setxattr(ext.appendingPathComponent("init.lua").path, "com.example.test", value,
                                value.count, 0, 0), 0)

        let blob = try RemoteInstaller.packageForPublish(ext)
        let tgz = tmp.appendingPathComponent("out.tgz")
        try XCTUnwrap(Data(base64Encoded: blob)).write(to: tgz)
        // bsdtar zero-pads the gzip stream to its 10 KB block; gzip warns "trailing garbage" and exits 2.
        let raw = try run("/usr/bin/gzip", ["-dc", tgz.path], okStatus: [0, 2])

        XCTAssertEqual(rawMembers(raw), ["./extension.toml", "./init.lua", "./lib/util.lua", "./lib/mytests.lua",
                                         "./themes/dark.json"])
        XCTAssertNil(raw.range(of: Data("com.example.test".utf8)), "an xattr record was packed")
    }

    /// Every header carries fixed owner fields, never the publisher's account or group.
    func testPackWritesFixedOwnerFields() throws {
        let tmp = tempDir()
        let ext = tmp.appendingPathComponent("ext")
        for rel in ["extension.toml", "init.lua", "lib/util.lua"] { try write(ext, rel) }
        let tgz = tmp.appendingPathComponent("out.tgz")
        try XCTUnwrap(Data(base64Encoded: try RemoteInstaller.packageForPublish(ext))).write(to: tgz)
        let raw = try run("/usr/bin/gzip", ["-dc", tgz.path], okStatus: [0, 2])

        XCTAssertEqual(rawMembers(raw).count, 3)
        for h in rawHeaders(raw) {
            XCTAssertEqual([h.uid, h.gid, h.uname, h.gname], ["0", "0", "", ""], h.name)
        }
        let user = NSUserName()
        if user.count >= 3 {
            XCTAssertNil(raw.range(of: Data(user.utf8)), "the packing user's name is in the archive")
        } else {
            print("testPackWritesFixedOwnerFields: user name shorter than 3 characters, needle check skipped")
        }
    }

    /// The archive format is pinned (the server refuses any owner name): paths over 100 and over 255
    /// bytes go into pax records, never GNU 'L'/'K' headers, and no header or record names an owner.
    func testPackFormatLongNamesCarryNoOwner() throws {
        let tmp = tempDir()
        let ext = tmp.appendingPathComponent("ext")
        let a = String(repeating: "a", count: 90), b = String(repeating: "b", count: 90)
        let c = String(repeating: "c", count: 90)
        let long1 = "lib/\(a)/\(b).lua", long2 = "lib/\(a)/\(b)/\(c)/d.lua"
        XCTAssertGreaterThan(long1.utf8.count, 100)
        XCTAssertGreaterThan(long2.utf8.count, 255)
        for rel in ["extension.toml", long1, long2] { try write(ext, rel) }
        let tgz = tmp.appendingPathComponent("out.tgz")
        try XCTUnwrap(Data(base64Encoded: try RemoteInstaller.packageForPublish(ext))).write(to: tgz)
        let raw = try run("/usr/bin/gzip", ["-dc", tgz.path], okStatus: [0, 2])

        let headers = rawHeaders(raw)
        XCTAssertFalse(headers.contains { $0.type == UInt8(ascii: "L") || $0.type == UInt8(ascii: "K") })
        XCTAssertTrue(headers.contains { $0.type == UInt8(ascii: "x") }, "the 282-byte path needs a pax record")
        for h in headers {
            XCTAssertEqual([h.uid, h.gid, h.uname, h.gname], ["0", "0", "", ""], "type \(h.type) \(h.name)")
        }
        let keys = Set(headers.flatMap { $0.pax.map { $0.key } })
        XCTAssertTrue(keys.isDisjoint(with: ["uname", "gname", "uid", "gid"]), "\(keys)")
        let user = NSUserName()
        if user.count >= 3 {
            XCTAssertFalse(headers.contains { $0.pax.contains { $0.value.contains(user) } })
            XCTAssertNil(raw.range(of: Data(user.utf8)), "the packing user's name is in the archive")
        }
        XCTAssertEqual(rawMembers(raw), ["./extension.toml", "./" + long1, "./" + long2])
    }

    // MARK: - GitHub URL parse

    func testParseRefusesDotAndEmptyParts() {
        typealias S = RemoteInstaller.Source
        let table: [(String, S?)] = [
            ("https://github.com/acme/tools", S(owner: "acme", repo: "tools", ref: "HEAD", subdir: "")),
            ("https://github.com/acme/tools/tree/main", S(owner: "acme", repo: "tools", ref: "main", subdir: "")),
            ("https://github.com/acme/tools/tree/main/extensions/hello",
             S(owner: "acme", repo: "tools", ref: "main", subdir: "extensions/hello")),
            ("https://github.com/acme/tools/tree/main/extensions/hello/",
             S(owner: "acme", repo: "tools", ref: "main", subdir: "extensions/hello")),
            ("https://github.com/acme/tools/tree/main/.config/ext",
             S(owner: "acme", repo: "tools", ref: "main", subdir: ".config/ext")),
            ("https://github.com/acme/tools/tree/main/..config/ext",
             S(owner: "acme", repo: "tools", ref: "main", subdir: "..config/ext")),
            ("https://github.com/acme/tools/tree/main/../x", nil),
            ("https://github.com/acme/tools/tree/main/a/../../x", nil),
            ("https://github.com/acme/tools/tree/main/ext/..", nil),
            ("https://github.com/acme/tools/tree/main/./ext", nil),
            ("https://github.com/acme/tools/tree/main/ext/.", nil),
            ("https://github.com/acme/tools/tree/../ext", nil),
            ("https://github.com/../tools", nil),
        ]
        for (url, want) in table {
            XCTAssertTrue(RemoteInstaller.parse(url) == want, "\(url) -> \(String(describing: RemoteInstaller.parse(url)))")
        }
    }

    /// URL.pathComponents decodes per part after splitting (%2e%2e -> "..", %2F stays inside its part
    /// as "a/../b") and collapses "//" (seen in the round-2 log); each form's exact result.
    func testParsePercentAndDoubledSlashForms() {
        typealias S = RemoteInstaller.Source
        let table: [(String, S?)] = [
            ("https://github.com/acme/tools/tree/main/%2e%2e/x", nil),
            ("https://github.com/acme/tools/tree/main/%2E%2E/x", nil),
            ("https://github.com/acme/tools/tree/main/%2e/x", nil),
            ("https://github.com/acme/tools/tree/main/a%2F..%2Fb", nil),
            ("https://github.com/acme/tools/tree/main/a//b", S(owner: "acme", repo: "tools", ref: "main", subdir: "a/b")),
        ]
        for (url, want) in table {
            XCTAssertTrue(RemoteInstaller.parse(url) == want, "\(url) -> \(String(describing: RemoteInstaller.parse(url)))")
        }
    }

    // MARK: - Install

    /// An archive packed the old way (everything under the folder) installs without its hidden members.
    func testUnpackMarketDropsHiddenMembers() throws {
        let tmp = tempDir()
        let ext = tmp.appendingPathComponent("ext")
        for rel in ["extension.toml", "init.lua", "lib/util.lua", ".omc/state/x.json", ".DS_Store",
                    "lib/sub/.hidden.lua"] {
            try write(ext, rel)
        }
        let tgz = tmp.appendingPathComponent("market.tgz")
        try run("/usr/bin/tar", ["-czf", tgz.path, "--exclude", "*.test.lua", "--exclude", "tests",
                                 "-C", ext.path, "."])
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let extDir = try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: false)
        XCTAssertEqual(extDir.path, out.path)
        XCTAssertEqual(try tree(out), ["extension.toml", "init.lua", "lib", "lib/util.lua", "lib/sub"])
    }

    /// A GitHub repo keeps installing: .gitignore/.github are left out, not refused.
    func testUnpackGitHubDropsHiddenMembers() throws {
        let tmp = tempDir()
        let repo = tmp.appendingPathComponent("repo-main")
        for rel in [".gitignore", ".github/workflows/ci.yml", "extension.toml", "init.lua", "lib/.hidden.lua",
                    "lib/util.lua"] {
            try write(repo, rel)
        }
        let tgz = tmp.appendingPathComponent("gh.tgz")
        try run("/usr/bin/tar", ["-czf", tgz.path, "-C", tmp.path, "repo-main"])
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let extDir = try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: true)
        XCTAssertEqual(extDir.path, out.path)
        XCTAssertEqual(try tree(out), ["extension.toml", "init.lua", "lib", "lib/util.lua"])
    }

    /// A GitHub subdir under a hidden folder still installs: only the resolved extension dir is
    /// swept; hidden files outside it are not touched (they stay in the temp tree, never installed).
    func testUnpackGitHubSubdirUnderHiddenFolder() throws {
        let tmp = tempDir()
        let repo = tmp.appendingPathComponent("repo-main")
        for rel in [".gitignore", "README.md", ".config/notes.txt", ".config/.secret",
                    ".config/ext/extension.toml", ".config/ext/init.lua", ".config/ext/.DS_Store",
                    ".config/ext/.omc/state/x.json", ".config/ext/lib/util.lua", ".config/ext/lib/.hidden.lua"] {
            try write(repo, rel)
        }
        let tgz = tmp.appendingPathComponent("gh.tgz")
        try run("/usr/bin/tar", ["-czf", tgz.path, "--no-mac-metadata", "-C", tmp.path, "repo-main"])
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let extDir = try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: true, subdir: ".config/ext")
        XCTAssertEqual(extDir.path, out.appendingPathComponent(".config/ext").path)
        XCTAssertEqual(try tree(extDir), ["extension.toml", "init.lua", "lib", "lib/util.lua"])
        XCTAssertEqual(try tree(out), [".gitignore", "README.md", ".config", ".config/notes.txt", ".config/.secret",
                                       ".config/ext", ".config/ext/extension.toml", ".config/ext/init.lua",
                                       ".config/ext/lib", ".config/ext/lib/util.lua"])
    }

    /// A symlink refuses the archive even when its name is hidden (checked before the sweep, as the
    /// parent did for every symlink).
    func testUnpackRefusesHiddenSymlink() throws {
        let tmp = tempDir()
        let ext = tmp.appendingPathComponent("ext")
        try write(ext, "extension.toml")
        try write(ext, "init.lua")
        try FileManager.default.createSymbolicLink(atPath: ext.appendingPathComponent(".evil").path,
                                                   withDestinationPath: "init.lua")
        let tgz = tmp.appendingPathComponent("link.tgz")
        try run("/usr/bin/tar", ["-czf", tgz.path, "--no-mac-metadata", "-C", ext.path, "."])
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: false)) { err in
            guard case .unsafeArchive? = err as? RemoteInstaller.InstallError else {
                return XCTFail("expected unsafeArchive, got \(err)")
            }
        }
    }

    /// "._x" names are hidden names; the sweep sees them although FileManager listings omit them.
    func testRemoveHiddenMembersSeesAppleDoubleNames() throws {
        let dir = tempDir()
        for rel in ["init.lua", "._init.lua", "lib/util.lua", "lib/._util.lua"] { try write(dir, rel) }
        try RemoteInstaller.removeHiddenMembers(dir)
        XCTAssertEqual(try tree(dir), ["init.lua", "lib", "lib/util.lua"])
    }

    /// Names that are hidden only after normalisation, a name of dots, a newline in a name.
    func testUnpackOddNames() throws {
        let tmp = tempDir()
        let tgz = tmp.appendingPathComponent("odd.tar.gz")
        try ustar(["extension.toml", "./.omc/x", "...", "a\n.x"].map { Array($0.utf8) }).write(to: tgz)
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        _ = try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: false)
        XCTAssertEqual(try tree(out), ["extension.toml", "a\n.x"])
    }

    /// Refused before anything is extracted: "a/../.x", an absolute name, and a "../" next to a
    /// non-UTF-8 name (that one name used to blank the whole listing the zip-slip check reads).
    func testUnpackRefusesTraversalAbsoluteAndNonUTF8Cover() throws {
        let cases: [[[UInt8]]] = [
            [Array("extension.toml".utf8), Array("a/../.x".utf8)],
            [Array("extension.toml".utf8), Array("/abs/x".utf8)],
            [Array("extension.toml".utf8), Array("caf".utf8) + [0xE9], Array("../evil".utf8)],
        ]
        for (i, names) in cases.enumerated() {
            let tmp = tempDir("refuse\(i)")
            let tgz = tmp.appendingPathComponent("bad.tar.gz")
            try ustar(names).write(to: tgz)
            let out = tmp.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            XCTAssertThrowsError(try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: false)) { err in
                guard case .unsafeArchive? = err as? RemoteInstaller.InstallError else {
                    return XCTFail("case \(i): expected unsafeArchive, got \(err)")
                }
            }
            XCTAssertEqual(try tree(out), [], "case \(i) extracted something")
        }
    }

    /// A non-UTF-8 name cannot land on APFS: the install fails instead of keeping a half tree.
    func testUnpackNonUTF8HiddenNameFails() throws {
        let tmp = tempDir()
        let tgz = tmp.appendingPathComponent("nonutf.tar.gz")
        try ustar([Array("extension.toml".utf8), Array(".".utf8) + [0xE9] + Array("hidden".utf8)]).write(to: tgz)
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: false))
    }

    // MARK: - Links with hidden names (round 3)

    /// A "._x" symlink used as the GitHub sub-folder: FileManager walks never list "._" names, so the
    /// link must still refuse the archive, and nothing behind it is swept.
    func testUnpackRefusesAppleDoubleNamedLinkAsSubdir() throws {
        let tmp = tempDir()
        let outside = try outsideFixture(tmp)
        let archive = ustar([Array("repo-main/README.md".utf8)], links: [("repo-main/._x", "../outside")])
        XCTAssertTrue(hasLink(archive, "repo-main/._x"))
        try expectRefused(archive, in: tmp, strip: true, subdir: "._x", "root")
        assertOutsideIntact(outside, "root")
    }

    func testUnpackRefusesDeeperAppleDoubleNamedLink() throws {
        let tmp = tempDir()
        let outside = try outsideFixture(tmp)
        let archive = ustar([Array("repo-main/a/keep.lua".utf8)], links: [("repo-main/a/._l", "../../outside")])
        XCTAssertTrue(hasLink(archive, "repo-main/a/._l"))
        try expectRefused(archive, in: tmp, strip: true, subdir: "a/._l", "deep")
        try expectRefused(archive, in: tmp, strip: true, subdir: "a/._l/inner", "deepinner")
        assertOutsideIntact(outside, "deep")
    }

    /// Marketplace: no sub-folder, nothing would be swept through the link, still refused.
    func testUnpackMarketRefusesAppleDoubleNamedLink() throws {
        let tmp = tempDir()
        let outside = try outsideFixture(tmp)
        let archive = ustar(["extension.toml", "init.lua"].map { Array($0.utf8) }, links: [("._x", "../outside")])
        XCTAssertTrue(hasLink(archive, "._x"))
        try expectRefused(archive, in: tmp, strip: false, "market")
        assertOutsideIntact(outside, "market")
    }

    func testUnpackRefusesAppleDoubleNamedLinkInHiddenFolder() throws {
        let tmp = tempDir()
        let outside = try outsideFixture(tmp)
        let archive = ustar(["repo-main/extension.toml", "repo-main/.git/HEAD"].map { Array($0.utf8) },
                            links: [("repo-main/.git/._x", "../../outside")])
        XCTAssertTrue(hasLink(archive, "repo-main/.git/._x"))
        try expectRefused(archive, in: tmp, strip: true, "gitdir")
        assertOutsideIntact(outside, "gitdir")
    }

    /// The hole round 2 really had: a folder the archive marks traverse-only (mode 0111, bsdtar keeps
    /// it) cannot be listed, so a FileManager walk skips the link inside it, while a path through it
    /// still resolves. Any name, not only "._".
    func testUnpackRefusesLinkInUnlistableFolder() throws {
        let tmp = tempDir()
        let outside = try outsideFixture(tmp)
        let archive = ustar([Array("repo-main/e/extension.toml".utf8)], dirs: [("repo-main/d", "0000111")],
                            links: [("repo-main/d/l", "../../outside")])
        XCTAssertTrue(hasLink(archive, "repo-main/d/l"))
        // Folders made traverse-only by the archive, opened again so tempDir() can remove them.
        defer {
            for label in ["through", "beside"] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: tmp.appendingPathComponent("out-\(label)/d").path)
            }
        }
        // The sub-folder goes through the link: round 2 swept the outside folder here.
        try expectRefused(archive, in: tmp, strip: true, subdir: "d/l", anyError: true, "through")
        assertOutsideIntact(outside, "through")
        // The link sits beside the extension: refused as any link in the download is.
        try expectRefused(archive, in: tmp, strip: true, subdir: "e", anyError: true, "beside")
        assertOutsideIntact(outside, "beside")
    }

    /// The second line: the resolved extension dir must stay under the extraction root even if a
    /// link got past the walk.
    func testExtensionDirMustStayUnderRoot() throws {
        let tmp = tempDir()
        _ = try outsideFixture(tmp)
        let root = tmp.appendingPathComponent("root")
        try write(root, "real/extension.toml")
        for name in ["._x", "plain"] {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path,
                                                       withDestinationPath: "../outside")
        }
        XCTAssertEqual(try RemoteInstaller.extensionDir(in: root, subdir: "real").path,
                       root.appendingPathComponent("real").path)
        for sub in ["._x", "plain", "plain/inner"] {
            XCTAssertThrowsError(try RemoteInstaller.extensionDir(in: root, subdir: sub)) { err in
                guard case .unsafeArchive? = err as? RemoteInstaller.InstallError else {
                    return XCTFail("\(sub): expected unsafeArchive, got \(err)")
                }
            }
        }
    }

    /// The sweep removes or skips a link, never enters it.
    func testRemoveHiddenMembersNeverEntersALink() throws {
        let tmp = tempDir()
        let outside = try outsideFixture(tmp)
        let dir = tmp.appendingPathComponent("dir")
        try write(dir, "init.lua")
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("lib").path,
                                                   withDestinationPath: "../outside")
        try RemoteInstaller.removeHiddenMembers(dir)
        assertOutsideIntact(outside, "sweep")
        XCTAssertEqual(try tree(dir), ["init.lua", "lib"])
    }

    // MARK: - Helpers

    private func write(_ root: URL, _ rel: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String], in dir: URL? = nil, okStatus: Set<Int32> = [0]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertTrue(okStatus.contains(p.terminationStatus), "\(tool) \(args) exited \(p.terminationStatus)")
        return data
    }

    /// Every path under `dir`, relative. find, not FileManager: FileManager omits "._*" names.
    private func tree(_ dir: URL) throws -> Set<String> {
        let out = try run("/usr/bin/find", [".", "-mindepth", "1", "-print0"], in: dir)
        return Set(out.split(separator: 0).map { String(decoding: $0.dropFirst(2), as: UTF8.self) })
    }

    /// Member names, a long name taken from the pax "path" record that precedes its header.
    private func rawMembers(_ raw: Data) -> Set<String> {
        var names: Set<String> = []
        var pending: String?
        for h in rawHeaders(raw) {
            if h.type == UInt8(ascii: "x") { pending = h.pax.last(where: { $0.key == "path" })?.value; continue }
            if h.type == UInt8(ascii: "g") { continue }
            names.insert(pending ?? h.name)
            pending = nil
        }
        return names
    }

    private struct TarHeader {
        let type: UInt8
        let name, uid, gid, uname, gname: String
        let pax: [(key: String, value: String)]
    }

    /// EVERY header straight from the tar stream, pax ones included: macOS `tar -t` hides a "._x"
    /// member placed before "x", and never shows pax records.
    private func rawHeaders(_ raw: Data) -> [TarHeader] {
        let bytes = [UInt8](raw)
        func field(_ at: Int, _ len: Int) -> String {
            String(decoding: bytes[at..<at + len].prefix { $0 != 0 }, as: UTF8.self)
        }
        func num(_ at: Int) -> String {
            String(Int(field(at, 8).trimmingCharacters(in: .whitespaces), radix: 8) ?? -1)
        }
        var headers: [TarHeader] = []
        var off = 0
        while off + 512 <= bytes.count, bytes[off] != 0 {
            guard let size = Int(field(off + 124, 12).trimmingCharacters(in: .whitespaces), radix: 8),
                  size >= 0, size <= bytes.count - off - 512 else {
                XCTFail("bad tar header at \(off)")
                break
            }
            let type = bytes[off + 156]
            let prefix = field(off + 345, 155)
            let isPax = type == UInt8(ascii: "x") || type == UInt8(ascii: "g")
            headers.append(TarHeader(type: type, name: prefix.isEmpty ? field(off, 100) : prefix + "/" + field(off, 100),
                                     uid: num(off + 108), gid: num(off + 116),
                                     uname: field(off + 265, 32), gname: field(off + 297, 32),
                                     pax: isPax ? paxRecords(Array(bytes[off + 512 ..< off + 512 + size])) : []))
            off += 512 + (size + 511) / 512 * 512
        }
        return headers
    }

    /// The "<len> <key>=<value>\n" records of a pax header body.
    private func paxRecords(_ body: [UInt8]) -> [(key: String, value: String)] {
        var out: [(key: String, value: String)] = []
        var i = 0
        while i < body.count, body[i] != 0 {
            guard let sp = body[i...].firstIndex(of: UInt8(ascii: " ")),
                  let len = Int(String(decoding: body[i..<sp], as: UTF8.self)),
                  len >= sp - i + 2, len <= body.count - i else {
                XCTFail("bad pax record at \(i)")
                break
            }
            let kv = String(decoding: body[(sp + 1)..<(i + len - 1)], as: UTF8.self).split(separator: "=", maxSplits: 1)
            out.append((String(kv.first ?? ""), kv.dropFirst().first.map(String.init) ?? ""))
            i += len
        }
        return out
    }

    /// A plain ustar archive (tar -xzf reads it uncompressed): each name a one-byte file, then each
    /// dir a folder member with its octal mode (typeflag '5'), then each link a symlink member
    /// (typeflag '2'), written last so macOS tar cannot take a "._" one as metadata of a following member.
    private func ustar(_ names: [[UInt8]], dirs: [(name: String, mode: String)] = [],
                       links: [(name: String, target: String)] = []) -> Data {
        let members: [(name: [UInt8], type: UInt8, mode: String, target: String, size: Int)] =
            names.map { ($0, UInt8(ascii: "0"), "0000644", "", 1) }
            + dirs.map { (Array($0.name.utf8), UInt8(ascii: "5"), $0.mode, "", 0) }
            + links.map { (Array($0.name.utf8), UInt8(ascii: "2"), "0000755", $0.target, 0) }
        var out: [UInt8] = []
        for m in members {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ at: Int) { h.replaceSubrange(at..<at + s.utf8.count, with: Array(s.utf8)) }
            h.replaceSubrange(0..<m.name.count, with: m.name)
            put(m.mode, 100); put("0000000", 108); put("0000000", 116)
            put(String(format: "%011lo", m.size), 124); put("00000000000", 136); put("        ", 148)
            h[156] = m.type
            put(m.target, 157)
            put("ustar", 257); put("00", 263)
            put(String(format: "%06lo", h.reduce(0) { $0 + Int($1) }), 148)
            h[154] = 0
            out += h
            if m.size > 0 { out += [UInt8(ascii: "x")] + [UInt8](repeating: 0, count: 511) }
        }
        return Data(out + [UInt8](repeating: 0, count: 1024))
    }

    /// A folder outside the extraction that a link could lead to: a manifest (top and inner) and
    /// hidden files a sweep through the link would delete.
    private func outsideFixture(_ tmp: URL) throws -> URL {
        let outside = tmp.appendingPathComponent("outside")
        for rel in ["extension.toml", ".hid/keep", ".env", "inner/extension.toml", "inner/.env"] { try write(outside, rel) }
        return outside
    }

    private func assertOutsideIntact(_ outside: URL, _ label: String) {
        for rel in [".hid/keep", ".env", "inner/.env"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent(rel).path),
                          "\(label): \(rel) outside the extraction was deleted")
        }
    }

    /// Writes `archive`, unpacks it into a fresh tmp/out-<label>, expects .unsafeArchive (any error
    /// when `anyError`).
    private func expectRefused(_ archive: Data, in tmp: URL, strip: Bool, subdir: String = "", anyError: Bool = false,
                               _ label: String) throws {
        let tgz = tmp.appendingPathComponent("\(label).tar.gz")
        try archive.write(to: tgz)
        let out = tmp.appendingPathComponent("out-\(label)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: strip, subdir: subdir)) { err in
            guard anyError || { if case .unsafeArchive? = err as? RemoteInstaller.InstallError { return true }; return false }() else {
                return XCTFail("\(label): expected unsafeArchive, got \(err)")
            }
        }
    }

    private func hasLink(_ archive: Data, _ name: String) -> Bool {
        rawHeaders(archive).contains { $0.name == name && $0.type == UInt8(ascii: "2") }
    }
}
