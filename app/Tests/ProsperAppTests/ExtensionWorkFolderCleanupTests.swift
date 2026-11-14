import Foundation
import XCTest
@testable import ProsperApp

/// #1152: the cleanup after a download removes exactly the work folder the download made. Rows named
/// testGuard* and testWorkFolderTable never delete: they read paths or pass a recorder as the removal.
/// Every other row deletes only inside its own tempDir(). No row downloads.
final class ExtensionWorkFolderCleanupTests: XCTestCase {

    // MARK: - Pure paths and the guard (recorder only)

    /// The work folder for an extension at the repository root, one and two sub-folders down, and from
    /// the Marketplace.
    func testWorkFolderTable() {
        let root = URL(fileURLWithPath: "/Users/example/tmp", isDirectory: true)
        let table: [(String, String?)] = [
            ("/Users/example/tmp/prosper-ext-tools-7/src", "/Users/example/tmp/prosper-ext-tools-7"),
            ("/Users/example/tmp/prosper-ext-tools-7/src/hello", "/Users/example/tmp/prosper-ext-tools-7"),
            ("/Users/example/tmp/prosper-ext-tools-7/src/extensions/hello", "/Users/example/tmp/prosper-ext-tools-7"),
            ("/Users/example/tmp/prosper-market-hello-1.2.0/src", "/Users/example/tmp/prosper-market-hello-1.2.0"),
            ("/Users/example/tmp", nil),
            ("/Users/example", nil),
            ("/Users/example/other/prosper-ext-tools-7/src", nil),
        ]
        for (extDir, want) in table {
            let got = RemoteInstaller.workFolder(of: URL(fileURLWithPath: extDir, isDirectory: true), tempRoot: root)
            XCTAssertTrue(got?.path == want, "\(extDir) -> \(got?.path ?? "nil")")
        }
    }

    /// The temp folder itself, its parent, siblings without the prefix, and paths that reach the temp
    /// folder or a download-looking name only through "..": all refused, nothing handed to the removal.
    func testGuardRefusesEverythingButADownloadFolder() {
        let temp = FileManager.default.temporaryDirectory
        let refused = [
            temp,
            temp.deletingLastPathComponent(),
            temp.appendingPathComponent("other-1", isDirectory: true),
            temp.appendingPathComponent("prosper-tests", isDirectory: true),
            temp.appendingPathComponent("prosper-extension", isDirectory: true),
            temp.appendingPathComponent("prosper-ext-tools-7/..", isDirectory: true),
            temp.appendingPathComponent("prosper-ext-tools-7/../..", isDirectory: true),
            temp.appendingPathComponent("x/../prosper-ext-tools-7", isDirectory: true),
            temp.appendingPathComponent("prosper-ext-tools-7/src", isDirectory: true),
            temp.deletingLastPathComponent().appendingPathComponent("prosper-ext-tools-7", isDirectory: true),
            temp.deletingLastPathComponent().appendingPathComponent("other/prosper-ext-tools-7", isDirectory: true),
        ]
        var recorded: [String] = []
        for path in refused {
            XCTAssertFalse(RemoteInstaller.removeWorkFolder(path, remove: { recorded.append($0.path) }), path.path)
        }
        XCTAssertEqual(recorded, [])
    }

    func testGuardAcceptsDownloadFolders() {
        let temp = FileManager.default.temporaryDirectory
        let accepted = [temp.appendingPathComponent("prosper-ext-tools-7", isDirectory: true),
                        temp.appendingPathComponent("prosper-market-hello-1.2.0", isDirectory: true)]
        var recorded: [String] = []
        for path in accepted {
            XCTAssertTrue(RemoteInstaller.removeWorkFolder(path, remove: { recorded.append($0.path) }), path.path)
        }
        XCTAssertEqual(recorded, accepted.map(\.path))
    }

    // MARK: - Real removal, inside the row's own folder only

    /// A refused archive, and a download name that is not one folder, leave nothing behind.
    func testExtractRefusedArchiveLeavesNothing() throws {
        let tmp = tempDir()
        let archive = ustar(["extension.toml", "../evil"])
        XCTAssertThrowsError(try RemoteInstaller.extract(archive, workName: "prosper-ext-tools-1", tempRoot: tmp,
                                                         stripTopLevel: false))
        XCTAssertThrowsError(try RemoteInstaller.extract(archive, workName: "prosper-ext-tools-2/x", tempRoot: tmp,
                                                         stripTopLevel: false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
    }

    /// A folder the archive leaves without any access refuses the download; the work folder still goes.
    func testExtractUnreadableFolderLeavesNothing() throws {
        let tmp = tempDir()
        let locked = tmp.appendingPathComponent("prosper-ext-tools-1/src/d")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let archive = ustar(["repo-main/extension.toml", "repo-main/d/f"], dirs: [("repo-main/d", "0000000")])
        XCTAssertThrowsError(try RemoteInstaller.extract(archive, workName: "prosper-ext-tools-1", tempRoot: tmp,
                                                         stripTopLevel: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
    }

    /// The installers' cleanup after a good download two sub-folders down, under a read-only folder.
    func testCleanupAfterExtractRemovesTheWholeWorkFolder() throws {
        let tmp = tempDir()
        let readOnly = tmp.appendingPathComponent("prosper-ext-tools-1/src/extensions")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let archive = ustar(["repo-main/extensions/hello/extension.toml"], dirs: [("repo-main/extensions", "0000555")])
        let extDir = try RemoteInstaller.extract(archive, workName: "prosper-ext-tools-1", tempRoot: tmp,
                                                 stripTopLevel: true, subdir: "extensions/hello")
        XCTAssertEqual(extDir.path, tmp.appendingPathComponent("prosper-ext-tools-1/src/extensions/hello").path)
        RemoteInstaller.removeWorkFolder(holding: extDir, tempRoot: tmp)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
    }

    /// Names of 255 bytes are read whole from the directory listing.
    func testLongNamesReadWhole() throws {
        let dir = tempDir()
        let plain = String(repeating: "a", count: 255), hidden = "." + String(repeating: "b", count: 254)
        for name in [plain, hidden, "lib/" + plain, "lib/" + hidden] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try RemoteInstaller.removeHiddenMembers(dir)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), [plain, "lib"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("lib").path), [plain])
    }

    // MARK: - Helpers

    /// A plain ustar archive (tar -xzf reads it uncompressed): each dir a folder member with its octal mode,
    /// then each name a one-byte file. Dirs first: tar keeps the mode of a folder that already exists.
    /// From MarketPackerTests, links left out.
    private func ustar(_ names: [String], dirs: [(name: String, mode: String)] = []) -> Data {
        let members: [(name: [UInt8], type: UInt8, mode: String, size: Int)] =
            dirs.map { (Array($0.name.utf8), UInt8(ascii: "5"), $0.mode, 0) }
            + names.map { (Array($0.utf8), UInt8(ascii: "0"), "0000644", 1) }
        var out: [UInt8] = []
        for m in members {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ at: Int) { h.replaceSubrange(at..<at + s.utf8.count, with: Array(s.utf8)) }
            h.replaceSubrange(0..<m.name.count, with: m.name)
            put(m.mode, 100); put("0000000", 108); put("0000000", 116)
            put(String(format: "%011lo", m.size), 124); put("00000000000", 136); put("        ", 148)
            h[156] = m.type
            put("ustar", 257); put("00", 263)
            put(String(format: "%06lo", h.reduce(0) { $0 + Int($1) }), 148)
            h[154] = 0
            out += h
            if m.size > 0 { out += [UInt8(ascii: "x")] + [UInt8](repeating: 0, count: 511) }
        }
        return Data(out + [UInt8](repeating: 0, count: 1024))
    }
}
