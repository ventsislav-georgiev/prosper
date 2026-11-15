import Darwin
import XCTest
@testable import ProsperApp

/// #1108 P3a (design #1105 D11 steps 1-4, D12 Deleted): the save path. Every file, link and folder is a
/// fake the row makes in its own tempDir(); a pipe, a device or another owner reaches the code only through
/// the stat seam. No row needs the main actor (TextFileWriter has no isolation).
final class TextFileWriterTests: XCTestCase {
    private typealias W = TextFileWriter

    private func file(_ name: String, _ bytes: [UInt8], in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func bytes(_ url: URL) -> [UInt8] { (try? Data(contentsOf: url)).map { [UInt8]($0) } ?? [] }
    private func names(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
    private func info(_ url: URL) -> stat { var s = stat(); _ = lstat(url.path, &s); return s }

    /// The real lstat with one field made up.
    private func seam(_ edit: @escaping (inout stat) -> Void) -> W.Stat {
        { p in var s = stat(); guard lstat(p, &s) == 0 else { return (errno, s) }; edit(&s); return (0, s) }
    }

    /// Wraps the real writer and runs `hook` after the temp file exists, before the rename (errata C9 style).
    private struct InterleaveWriter: ManagedConfigFileWriter {
        let real = ManagedConfigPOSIXWriter()
        let hook: @Sendable (URL) -> Void
        func writeTemp(_ data: [UInt8], besides target: URL, mode: mode_t) throws -> URL {
            let temp = try real.writeTemp(data, besides: target, mode: mode)
            hook(target)
            return temp
        }
        func replace(_ target: URL, with temp: URL) throws { try real.replace(target, with: temp) }
    }

    func testFingerprintIsSHA256() {
        let fp = W.digest([])
        XCTAssertEqual(fp.count, 32)
        XCTAssertEqual(Array(fp.prefix(4)), [0xE3, 0xB0, 0xC4, 0x42])
    }

    /// Item 1: load, then save with no edit, gives the file's bytes back for every encoding and line ending.
    func testLoadThenSaveGivesTheFileBackByteForByte() throws {
        let dir = tempDir("tfw-round")
        let cases: [(String, [UInt8], TextViewerDocument.Encoding, TextViewerDocument.LineEnding)] = [
            ("lf.txt", [0x68, 0xC3, 0xA9, 0x0A, 0x62, 0x0A], .utf8, .lf),
            ("crlf.txt", [0x61, 0x0D, 0x0A, 0x62, 0x0D, 0x0A], .utf8, .crlf),
            ("cr.txt", [0x61, 0x0D, 0x62, 0x0D], .utf8, .cr),
            ("mixed.txt", [0x61, 0x0D, 0x0A, 0x62, 0x0A, 0x63, 0x0D], .utf8, .mixed),
            ("none.txt", [0x61, 0x62], .utf8, .none),
            ("empty.txt", [], .utf8, .none),
            ("bom-lf.txt", [0xEF, 0xBB, 0xBF, 0x61, 0x0A, 0x62], .utf8BOM, .lf),
            ("bom-crlf.txt", [0xEF, 0xBB, 0xBF, 0x61, 0x0D, 0x0A], .utf8BOM, .crlf),
            ("bom-only.txt", [0xEF, 0xBB, 0xBF], .utf8BOM, .none),
            ("le-crlf.txt", [0xFF, 0xFE, 0x61, 0x00, 0x0D, 0x00, 0x0A, 0x00, 0xE9, 0x00], .utf16LE, .crlf),
            ("le-cr.txt", [0xFF, 0xFE, 0x61, 0x00, 0x0D, 0x00], .utf16LE, .cr),
            ("be-mixed.txt", [0xFE, 0xFF, 0x00, 0x61, 0x00, 0x0D, 0x00, 0x0A, 0x00, 0x62, 0x00, 0x0A, 0xD8, 0x3D, 0xDE, 0x00], .utf16BE, .mixed),
            ("be-lf.txt", [0xFE, 0xFF, 0x00, 0x61, 0x00, 0x0A], .utf16BE, .lf),
        ]
        for (name, original, encoding, ending) in cases {
            let url = try file(name, original, in: dir)
            guard case .success(let doc) = TextViewerDocument.load(url) else { XCTFail("refused \(name)"); continue }
            XCTAssertEqual(doc.encoding, encoding, name)
            XCTAssertEqual(doc.lineEnding, ending, name)
            XCTAssertEqual(W.encode(doc.text, encoding: doc.encoding), original, name)
            let fp = W.digest(original)
            XCTAssertEqual(W.save(doc.text, encoding: doc.encoding, to: url, expected: fp), .success(fp), name)
            XCTAssertEqual(bytes(url), original, name)
        }
        XCTAssertEqual(names(dir).count, cases.count, "no temp file left")
    }

    func testAnEditKeepsTheBOMAndCRLF() throws {
        let dir = tempDir("tfw-bom")
        let original: [UInt8] = [0xEF, 0xBB, 0xBF, 0x61, 0x0D, 0x0A]
        let url = try file("a.txt", original, in: dir)
        guard case .success(let doc) = TextViewerDocument.load(url) else { return XCTFail("refused") }
        let saved = W.save(doc.text + "b\r\n", encoding: doc.encoding, to: url, expected: W.digest(original))
        let expected: [UInt8] = [0xEF, 0xBB, 0xBF, 0x61, 0x0D, 0x0A, 0x62, 0x0D, 0x0A]
        XCTAssertEqual(saved, .success(W.digest(expected)))
        XCTAssertEqual(bytes(url), expected)
    }

    func testModes0600And0755AreKept() throws {
        let dir = tempDir("tfw-mode")
        for mode: mode_t in [0o600, 0o755] {
            let url = try file("m\(mode).txt", Array("old".utf8), in: dir)
            XCTAssertEqual(chmod(url.path, mode), 0)
            defer { _ = chmod(url.path, 0o644) }
            let before = info(url).st_ino
            XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8))), .success(W.digest(Array("new".utf8))))
            XCTAssertEqual(info(url).st_mode & 0o7777, mode)
            XCTAssertNotEqual(info(url).st_ino, before, "the atomic branch renames a new file in")
            XCTAssertEqual(bytes(url), Array("new".utf8))
        }
    }

    func testSymlinkStaysALinkAndItsTargetChanges() throws {
        let dir = tempDir("tfw-link")
        let real = try file("real.txt", Array("old".utf8), in: dir)
        let link = dir.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink("real.txt", link.path), 0)
        XCTAssertEqual(W.save("new", encoding: .utf8, to: link, expected: W.digest(Array("old".utf8))), .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(info(link).st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? "", "real.txt")
        XCTAssertEqual(bytes(real), Array("new".utf8))
        XCTAssertEqual(names(dir), ["link.txt", "real.txt"])
    }

    func testHardLinkTakesTheInPlaceBranch() throws {
        let dir = tempDir("tfw-hard")
        let a = try file("a.txt", Array("old".utf8), in: dir)
        let b = dir.appendingPathComponent("b.txt")
        XCTAssertEqual(link(a.path, b.path), 0)
        let before = info(a).st_ino
        XCTAssertEqual(W.save("new!", encoding: .utf8, to: a, expected: W.digest(Array("old".utf8))), .success(W.digest(Array("new!".utf8))))
        XCTAssertEqual(info(a).st_nlink, 2)
        XCTAssertEqual(info(a).st_ino, before)
        XCTAssertEqual(bytes(b), Array("new!".utf8), "the other name reads the new bytes")
        XCTAssertEqual(names(dir), ["a.txt", "b.txt"])
    }

    func testExtendedAttributeIsKeptByTheAtomicBranch() throws {
        let dir = tempDir("tfw-xattr")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let value: [UInt8] = Array("example".utf8)
        XCTAssertEqual(setxattr(url.path, "com.example.tag", value, value.count, 0, 0), 0)
        let before = info(url).st_ino
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8))), .success(W.digest(Array("new".utf8))))
        XCTAssertNotEqual(info(url).st_ino, before)
        var got = [UInt8](repeating: 0, count: 64)
        let n = getxattr(url.path, "com.example.tag", &got, got.count, 0, 0)
        XCTAssertEqual(n, value.count)
        XCTAssertEqual(Array(got.prefix(max(n, 0))), value)
    }

    func testAWriteBeforeSaveIsChangedOnDiskThenOverwriteWrites() throws {
        let dir = tempDir("tfw-race")
        let url = try file("a.txt", Array("mine-old".utf8), in: dir)
        let fp = W.digest(Array("mine-old".utf8))
        try Data("theirs".utf8).write(to: url)
        XCTAssertEqual(W.save("mine-new", encoding: .utf8, to: url, expected: fp), .failure(.changedOnDisk))
        XCTAssertEqual(bytes(url), Array("theirs".utf8))
        XCTAssertEqual(names(dir), ["a.txt"])
        XCTAssertEqual(W.save("mine-new", encoding: .utf8, to: url, expected: fp, overwrite: true), .success(W.digest(Array("mine-new".utf8))))
        XCTAssertEqual(bytes(url), Array("mine-new".utf8))
    }

    func testAWriteBeforeAnInPlaceSaveIsChangedOnDisk() throws {
        let dir = tempDir("tfw-race-inplace")
        let url = try file("a.txt", Array("mine-old".utf8), in: dir)
        XCTAssertEqual(link(url.path, dir.appendingPathComponent("b.txt").path), 0)
        // Through the other name, in place (same inode), so a.txt keeps its two links.
        let fd = open(dir.appendingPathComponent("b.txt").path, O_WRONLY | O_TRUNC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(Array("theirs".utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, 6)
        _ = close(fd)
        XCTAssertEqual(info(url).st_nlink, 2)
        XCTAssertEqual(W.save("mine-new", encoding: .utf8, to: url, expected: W.digest(Array("mine-old".utf8))), .failure(.changedOnDisk))
        XCTAssertEqual(bytes(url), Array("theirs".utf8))
        XCTAssertEqual(names(dir), ["a.txt", "b.txt"])
    }

    /// The comparison sits after writeTemp and copyfile, right before the rename: a write inside writeTemp is caught.
    func testAWriteBetweenTempAndRenameIsChangedOnDisk() throws {
        let dir = tempDir("tfw-interleave")
        let url = try file("a.txt", Array("mine-old".utf8), in: dir)
        let theirs = Array("theirs".utf8)
        let writer = InterleaveWriter { target in _ = try? Data(theirs).write(to: target) }
        XCTAssertEqual(W.save("mine-new", encoding: .utf8, to: url, expected: W.digest(Array("mine-old".utf8)), writer: writer), .failure(.changedOnDisk))
        XCTAssertEqual(bytes(url), theirs)
        XCTAssertEqual(names(dir), ["a.txt"], "the temp file is removed")
    }

    func testReadOnlyFolderFailsAndLeavesNothing() throws {
        let sub = tempDir("tfw-ro").appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = try file("a.txt", Array("old".utf8), in: sub)
        XCTAssertEqual(chmod(sub.path, 0o555), 0)
        defer { _ = chmod(sub.path, 0o755) }
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8))), .failure(.failed(.temp, EACCES)))
        XCTAssertEqual(bytes(url), Array("old".utf8))
        XCTAssertEqual(names(sub), ["a.txt"])
    }

    func testAnotherOwnerTakesTheInPlaceBranch() throws {
        let dir = tempDir("tfw-owner")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let before = info(url)
        let other = seam { $0.st_uid = geteuid() &+ 1 }
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), stat: other), .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(info(url).st_ino, before.st_ino, "same inode: written in place")
        XCTAssertEqual(info(url).st_mode, before.st_mode)
        XCTAssertEqual(bytes(url), Array("new".utf8))
        XCTAssertEqual(names(dir), ["a.txt"])
    }

    func testAFolderOrAPipeOrADeviceIsRefused() throws {
        let dir = tempDir("tfw-type")
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(W.save("new", encoding: .utf8, to: sub, expected: []), .failure(.notRegular))
        XCTAssertEqual(names(sub), [])
        let url = try file("a.txt", Array("old".utf8), in: dir)
        for kind in [S_IFIFO, S_IFCHR, S_IFLNK] {
            let fake = seam { $0.st_mode = kind | 0o644 }
            XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), stat: fake), .failure(.notRegular))
            XCTAssertEqual(bytes(url), Array("old".utf8))
        }
        XCTAssertEqual(names(dir), ["a.txt", "sub"])
    }

    /// D12 Deleted: written anew with the umask's mode, read from a probe this row makes with 0o666.
    func testDeletedFileIsWrittenAnewWithTheUmaskMode() throws {
        let dir = tempDir("tfw-deleted")
        let probe = dir.appendingPathComponent("probe")
        let pfd = open(probe.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
        XCTAssertGreaterThanOrEqual(pfd, 0)
        _ = close(pfd)
        let mode = info(probe).st_mode & 0o7777
        let url = dir.appendingPathComponent("gone.txt")
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8))), .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(bytes(url), Array("new".utf8))
        XCTAssertEqual(info(url).st_mode & 0o7777, mode)
        // A dangling link: the link stays, its target is made.
        let link = dir.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink("target.txt", link.path), 0)
        XCTAssertEqual(W.save("via", encoding: .utf8, to: link, expected: []), .success(W.digest(Array("via".utf8))))
        XCTAssertEqual(info(link).st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(bytes(dir.appendingPathComponent("target.txt")), Array("via".utf8))
        XCTAssertEqual(names(dir), ["gone.txt", "link.txt", "probe", "target.txt"])
    }

    /// The stat says missing, but a file appeared before the create: O_EXCL answers changed on disk.
    func testAFileThatAppearedIsNeverOverwrittenByTheDeletedCase() throws {
        let dir = tempDir("tfw-appeared")
        let url = try file("a.txt", Array("theirs".utf8), in: dir)
        let missing: W.Stat = { _ in (ENOENT, stat()) }
        XCTAssertEqual(W.save("mine", encoding: .utf8, to: url, expected: [], overwrite: true, stat: missing), .failure(.changedOnDisk))
        XCTAssertEqual(bytes(url), Array("theirs".utf8))
    }

    func testLossyIsNeverSaved() throws {
        let dir = tempDir("tfw-lossy")
        let original: [UInt8] = [0x61, 0xFF, 0x62]
        let url = try file("a.txt", original, in: dir)
        guard case .success(let doc) = TextViewerDocument.load(url) else { return XCTFail("refused") }
        XCTAssertEqual(doc.encoding, .lossy)
        XCTAssertTrue(W.encode(doc.text, encoding: .lossy) == nil)
        XCTAssertEqual(W.save(doc.text, encoding: doc.encoding, to: url, expected: W.digest(original), overwrite: true), .failure(.lossy))
        XCTAssertEqual(bytes(url), original)
        XCTAssertEqual(names(dir), ["a.txt"])
    }

    /// A file swapped in between the stat and the in-place open (another inode) is refused, not truncated.
    func testASwapBeforeTheInPlaceOpenIsRefused() throws {
        let dir = tempDir("tfw-swap")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let swapped = seam { $0.st_nlink = 2; $0.st_ino = $0.st_ino &+ 1 }
        for overwrite in [false, true] {
            XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), overwrite: overwrite, stat: swapped), .failure(.swapped))
            XCTAssertEqual(bytes(url), Array("old".utf8))
        }
    }

    /// Past the viewer's 16 MiB limit the comparison reads nothing: a sparse file made with ftruncate (no real bytes).
    func testAFileOverTheLimitIsChangedOnDiskWithoutARead() throws {
        let dir = tempDir("tfw-big")
        let url = try file("a.txt", [], in: dir)
        let fd = open(url.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(TextViewerDocument.maxBytes) + 1), 0)
        _ = close(fd)
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest([])), .failure(.changedOnDisk))
        XCTAssertEqual(info(url).st_size, off_t(TextViewerDocument.maxBytes) + 1)
        XCTAssertEqual(names(dir), ["a.txt"])
    }
}
