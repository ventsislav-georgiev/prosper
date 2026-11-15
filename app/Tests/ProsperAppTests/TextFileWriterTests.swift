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

    /// Round 7 item 5: the row's own file in a subfolder of its tempDir() chmod'ed 0o555 (restored first thing in the defer, the
    /// restore asserted): the temp's EACCES falls back to the in-place branch: same inode and mode, the new bytes, no temp left.
    func testAnOwnedFileInAReadOnlyFolderIsWrittenInPlace() throws {
        let sub = tempDir("tfw-ro").appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let url = try file("a.txt", Array("old".utf8), in: sub)
        let before = info(url)
        XCTAssertEqual(chmod(sub.path, 0o555), 0)
        defer { XCTAssertEqual(chmod(sub.path, 0o755), 0, "the row's own folder is writable again") }
        let calls = Calls()
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: calls)),
                       .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(calls.all, ["writeTemp"], "a temp tried, no replace")
        XCTAssertEqual(info(url).st_ino, before.st_ino, "same inode: written in place")
        XCTAssertEqual(info(url).st_mode, before.st_mode)
        XCTAssertEqual(bytes(url), Array("new".utf8))
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

    // MARK: round 3 (R1108-a1 the group, a read-only file, the creation date, the access list, a second mark)

    /// Records the writer's calls (no main actor: the save runs on the test's own thread).
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }

    private struct RecordingWriter: ManagedConfigFileWriter {
        let real = ManagedConfigPOSIXWriter()
        let calls: Calls
        func writeTemp(_ data: [UInt8], besides target: URL, mode: mode_t) throws -> URL {
            calls.add("writeTemp")
            return try real.writeTemp(data, besides: target, mode: mode)
        }
        func replace(_ target: URL, with temp: URL) throws { calls.add("replace"); try real.replace(target, with: temp) }
    }

    /// The real lstat with the group of every path but `file` (the folder) made up.
    private func folderOfAnotherGroup(than file: URL) -> W.Stat {
        { p in var s = stat(); guard lstat(p, &s) == 0 else { return (errno, s) }; if p != file.path { s.st_gid &+= 1 }; return (0, s) }
    }

    /// Fact: a new file takes its folder's group with no chown (so the atomic branch hands the folder's group on).
    func testANewFileTakesItsFoldersGroup() throws {
        let sub = tempDir("tfw-newgroup").appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let made = sub.appendingPathComponent("new.txt")
        let fd = open(made.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        _ = close(fd)
        XCTAssertEqual(info(made).st_gid, info(sub).st_gid)
    }

    /// R1108-a1: the file's group is not the folder's: in place (no temp, no replace), group and inode kept;
    /// the same group: the atomic branch as before.
    func testAFileOfAnotherGroupThanItsFolderIsWrittenInPlace() throws {
        let dir = tempDir("tfw-group")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let before = info(url)
        let calls = Calls()
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: calls),
                              stat: folderOfAnotherGroup(than: url)), .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(calls.all, [], "no temp and no replace")
        XCTAssertEqual(info(url).st_ino, before.st_ino, "same inode: written in place")
        XCTAssertEqual(info(url).st_gid, before.st_gid)
        XCTAssertEqual(bytes(url), Array("new".utf8))
        XCTAssertEqual(names(dir), ["a.txt"])

        let same = Calls()
        XCTAssertEqual(W.save("newer", encoding: .utf8, to: url, expected: W.digest(Array("new".utf8)), writer: RecordingWriter(calls: same),
                              stat: seam { _ in }), .success(W.digest(Array("newer".utf8))))
        XCTAssertEqual(same.all, ["writeTemp", "replace"])
        XCTAssertNotEqual(info(url).st_ino, before.st_ino, "the atomic branch renames a new file in")
        XCTAssertEqual(info(url).st_gid, before.st_gid)
        XCTAssertEqual(bytes(url), Array("newer".utf8))
        XCTAssertEqual(names(dir), ["a.txt"])
    }

    /// The belt: file and folder agree (through the seam) but the temp did not get the file's group: the temp is
    /// removed and the file is written in place, never replaced.
    func testATempWithoutTheFilesGroupIsDroppedForTheInPlaceWrite() throws {
        let dir = tempDir("tfw-group-belt")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let before = info(url)
        let calls = Calls()
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: calls),
                              stat: seam { $0.st_gid &+= 1 }), .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(calls.all, ["writeTemp"], "a temp, no replace")
        XCTAssertEqual(info(url).st_ino, before.st_ino, "same inode: written in place")
        XCTAssertEqual(bytes(url), Array("new".utf8))
        XCTAssertEqual(names(dir), ["a.txt"], "the temp is removed")
    }

    /// A file whose owner-write bit is off is never written, by either branch (another owner through the seam),
    /// not even with overwrite: EACCES, bytes and mode unchanged, no temp.
    func testAFileMarkedReadOnlyIsNeverWritten() throws {
        let dir = tempDir("tfw-readonly")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        defer { _ = chmod(url.path, 0o644) }
        let owners: [(String, W.Stat)] = [("mine", seam { _ in }), ("another owner", seam { $0.st_uid = geteuid() &+ 1 })]
        for mode: mode_t in [0o400, 0o444] {
            XCTAssertEqual(chmod(url.path, mode), 0)
            for (label, st) in owners {
                for overwrite in [false, true] {
                    let calls = Calls()
                    XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), overwrite: overwrite,
                                          writer: RecordingWriter(calls: calls), stat: st), .failure(.failed(.open, EACCES)), label)
                    XCTAssertEqual(calls.all, [], label)
                    XCTAssertEqual(bytes(url), Array("old".utf8), label)
                    XCTAssertEqual(info(url).st_mode & 0o7777, mode, label)
                    XCTAssertEqual(names(dir), ["a.txt"], label)
                }
            }
        }
    }

    /// The creation date survives an atomic save: the row's own file is made older first (no wait, no clock).
    func testTheCreationDateIsKeptByTheAtomicBranch() throws {
        let dir = tempDir("tfw-crtime")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: url.path)
        let before = info(url)
        XCTAssertEqual(before.st_birthtimespec.tv_sec, 1_000_000_000)
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8))), .success(W.digest(Array("new".utf8))))
        XCTAssertNotEqual(info(url).st_ino, before.st_ino, "the atomic branch renames a new file in")
        XCTAssertEqual(info(url).st_birthtimespec.tv_sec, 1_000_000_000)
        XCTAssertEqual(info(url).st_birthtimespec.tv_nsec, before.st_birthtimespec.tv_nsec)
        XCTAssertEqual(names(dir), ["a.txt"])
    }

    private func aclText(_ url: URL) -> String {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return "" }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return "" }
        defer { acl_free(text) }
        return String(cString: text)
    }

    /// An access list set in process on the row's own file (uid 1, a system account; read only) is on the saved file.
    func testAnAccessListIsKeptByTheAtomicBranch() throws {
        let dir = tempDir("tfw-acl")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        var acl: acl_t? = acl_init(1)
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var perms: acl_permset_t?
        let who = UUID(uuidString: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000001")!.uuid
        XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
        XCTAssertEqual(acl_set_tag_type(entry, ACL_EXTENDED_ALLOW), 0)
        XCTAssertEqual(withUnsafeBytes(of: who) { acl_set_qualifier(entry, $0.baseAddress) }, 0)
        XCTAssertEqual(acl_get_permset(entry, &perms), 0)
        XCTAssertEqual(acl_add_perm(perms, ACL_READ_DATA), 0)
        XCTAssertEqual(acl_set_permset(entry, perms), 0)
        guard acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else { throw XCTSkip("acl_set_file refused on this file system: errno \(errno)") }
        let want = aclText(url)
        XCTAssertFalse(want.isEmpty)
        let ino = info(url).st_ino
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8))), .success(W.digest(Array("new".utf8))))
        XCTAssertNotEqual(info(url).st_ino, ino, "the atomic branch renames a new file in")
        XCTAssertEqual(aclText(url), want)
        XCTAssertEqual(names(dir), ["a.txt"])
    }

    /// A text whose first scalar is U+FEFF: the encoding's own mark, then the text's (two, both shown by the load).
    /// A file with two marks comes back byte for byte: the load shows the second (R1108-bom2 for UTF-8).
    func testASecondMarkIsWrittenOnlyWhenTheLoadShowedIt() throws {
        XCTAssertEqual(W.encode("\u{FEFF}a", encoding: .utf8), [0xEF, 0xBB, 0xBF, 0x61])
        XCTAssertEqual(W.encode("\u{FEFF}a", encoding: .utf8BOM), [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x61])
        XCTAssertEqual(W.encode("\u{FEFF}a", encoding: .utf16LE), [0xFF, 0xFE, 0xFF, 0xFE, 0x61, 0x00])
        XCTAssertEqual(W.encode("\u{FEFF}a", encoding: .utf16BE), [0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x61])
        let dir = tempDir("tfw-bom2")
        let cases: [(String, [UInt8], TextViewerDocument.Encoding)] = [
            ("le.txt", [0xFF, 0xFE, 0xFF, 0xFE, 0x61, 0x00], .utf16LE),
            ("be.txt", [0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x61], .utf16BE),
        ]
        for (name, original, encoding) in cases {
            let url = try file(name, original, in: dir)
            guard case .success(let doc) = TextViewerDocument.load(url) else { XCTFail("refused \(name)"); continue }
            XCTAssertEqual(doc.encoding, encoding, name)
            XCTAssertEqual(doc.text.unicodeScalars.first, "\u{FEFF}", name)
            XCTAssertEqual(W.save(doc.text, encoding: doc.encoding, to: url, expected: W.digest(original)), .success(W.digest(original)), name)
            XCTAssertEqual(bytes(url), original, name)
        }
        let original: [UInt8] = [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x61]
        let url = try file("u8.txt", original, in: dir)
        guard case .success(let doc) = TextViewerDocument.load(url) else { return XCTFail("refused u8.txt") }
        XCTAssertEqual(doc.encoding, .utf8BOM)
        XCTAssertEqual(doc.text, "\u{FEFF}a", "the second mark is the text's own")
        XCTAssertEqual(W.save(doc.text, encoding: doc.encoding, to: url, expected: W.digest(original)), .success(W.digest(original)))
        XCTAssertEqual(bytes(url), original, "load then save loses no byte")
        XCTAssertEqual(names(dir), ["be.txt", "le.txt", "u8.txt"])
    }

    // MARK: round 4 (R1108-q1 one descriptor, R1108-q4 the link's target, R1108-r3-1 a relative path)

    /// R1108-q1, QA's double swap, in place: between the open and the comparison the row moves its own file off the path
    /// (to moved.txt) and puts a new a.txt there. One descriptor: the bytes compared are the bytes replaced, so newer bytes
    /// in the opened file are never lost; a write that went to the moved file answers "changed on disk", never "saved".
    func testTheInPlaceBranchComparesAndWritesOneDescriptor() throws {
        let dir = tempDir("tfw-one-fd")
        let url = dir.appendingPathComponent("a.txt")
        let moved = dir.appendingPathComponent("moved.txt")
        let other = seam { $0.st_uid = geteuid() &+ 1 }
        let old = Array("old".utf8), theirs = Array("theirs".utf8)
        func swap(_ there: [UInt8]) {
            XCTAssertEqual(rename(url.path, moved.path), 0)
            XCTAssertNotNil(try? file("a.txt", there, in: dir))
        }
        // 1. The opened file holds newer bytes than the load; the path then names a file with the expected ones.
        _ = try file("a.txt", theirs, in: dir)
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(old), stat: other, beforeCompare: { swap(old) }),
                       .failure(.changedOnDisk))
        XCTAssertEqual(bytes(moved), theirs, "the opened file's newer bytes are kept")
        XCTAssertEqual(bytes(url), old)
        XCTAssertEqual(names(dir), ["a.txt", "moved.txt"])
        // 2. The opened file matches; the path then names another file: the bytes go to the file compared, the answer is "changed".
        XCTAssertEqual(unlink(moved.path), 0)
        _ = try file("a.txt", old, in: dir)
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(old), stat: other, beforeCompare: { swap(theirs) }),
                       .failure(.changedOnDisk))
        XCTAssertEqual(bytes(moved), Array("new".utf8), "written to the file that was compared")
        XCTAssertEqual(bytes(url), theirs, "the file now at the path is untouched")
        XCTAssertEqual(names(dir), ["a.txt", "moved.txt"])
        // 3. No swap: saved, the seam called once, the bytes from the start (no hole).
        XCTAssertEqual(unlink(moved.path), 0)
        _ = try file("a.txt", Array("longer-old".utf8), in: dir)
        var calls = 0
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("longer-old".utf8)), stat: other, beforeCompare: { calls += 1 }),
                       .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(bytes(url), Array("new".utf8))
        XCTAssertEqual(names(dir), ["a.txt"])
    }

    /// R1108-q4: a link whose target bytes are not UTF-8 (78 FF 79, made with symlink(2) from a byte array, relative, so inside
    /// tempDir(); never followed by the row): the save answers EILSEQ and creates nothing, at the bytes or at a mangled name.
    func testALinkTargetThatIsNotUTF8IsRefused() throws {
        let dir = tempDir("tfw-link-bytes")
        let link = dir.appendingPathComponent("link.txt")
        let target = ([0x78, 0xFF, 0x79, 0x00] as [UInt8]).map { CChar(bitPattern: $0) }
        XCTAssertEqual(symlink(target, link.path), 0)
        XCTAssertEqual(names(dir), ["link.txt"])
        XCTAssertEqual(W.resolve(link.path), .failure(.failed(.resolve, EILSEQ)))
        for overwrite in [false, true] {
            XCTAssertEqual(W.save("new", encoding: .utf8, to: link, expected: [], overwrite: overwrite), .failure(.failed(.resolve, EILSEQ)))
            XCTAssertEqual(names(dir), ["link.txt"], "nothing created")
        }
        XCTAssertEqual(info(link).st_mode & S_IFMT, S_IFLNK)
    }

    /// R1108-r3-1: a path that does not start with "/" is refused by resolve, before any readlink or stat. A file URL with
    /// no authority keeps a relative path; the folder named is a fresh UUID, so nothing of the kind exists anywhere.
    func testARelativePathIsRefusedBeforeAnyStat() throws {
        let rel = "tfw-relative-\(UUID().uuidString)/a.txt"
        XCTAssertEqual(W.resolve(rel), .failure(.failed(.resolve, EINVAL)))
        // Without the guard (a mutant) the row stops here: no save is ever tried on a path outside tempDir().
        guard W.resolve(rel) == .failure(.failed(.resolve, EINVAL)) else { return }
        let url = try XCTUnwrap(URL(string: "file:" + rel))
        guard !url.path.hasPrefix("/") else { return XCTFail("the URL's path is absolute: \(url.path)") }
        var stats = 0
        let counting: W.Stat = { _ in stats += 1; return (ENOENT, stat()) }
        for overwrite in [false, true] {
            XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: [], overwrite: overwrite, stat: counting), .failure(.failed(.resolve, EINVAL)))
        }
        XCTAssertEqual(stats, 0, "refused before any stat")
    }

    // MARK: round 5 (R1108-r3-b an access list and Locked, R1108-r4-a a file that grows, R1108-q3 the load's identity)

    /// Saves with the default seam (lstat: mine, the atomic branch) or as another owner (the in-place branch).
    private func save(_ text: String, to url: URL, expected: [UInt8], overwrite: Bool = false, inPlace: Bool,
                      flags: UInt32 = 0, writer: any ManagedConfigFileWriter = ManagedConfigPOSIXWriter(),
                      beforeRead: () -> Void = {}) -> Result<W.Fingerprint, W.Failure> {
        guard inPlace || flags != 0 else {
            return W.save(text, encoding: .utf8, to: url, expected: W.digest(expected), overwrite: overwrite, writer: writer, beforeRead: beforeRead)
        }
        let st = seam { if inPlace { $0.st_uid = geteuid() &+ 1 }; $0.st_flags |= flags }
        return W.save(text, encoding: .utf8, to: url, expected: W.digest(expected), overwrite: overwrite, writer: writer, stat: st, beforeRead: beforeRead)
    }

    /// R1108-r3-b: a 0644 file of the row whose access list (set in process) denies writing to everyone: the bit is set but the
    /// kernel says no; never written by either branch, not even with overwrite: EACCES, bytes and the deny entry unchanged, no temp.
    func testAnAccessListThatDeniesWritingIsNeverWritten() throws {
        let dir = tempDir("tfw-acl-deny")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        var acl: acl_t? = acl_init(1)
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var perms: acl_permset_t?
        let everyone = UUID(uuidString: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C")!.uuid   // the everyone group (gid 12)
        XCTAssertEqual(acl_create_entry(&acl, &entry), 0)
        XCTAssertEqual(acl_set_tag_type(entry, ACL_EXTENDED_DENY), 0)
        XCTAssertEqual(withUnsafeBytes(of: everyone) { acl_set_qualifier(entry, $0.baseAddress) }, 0)
        XCTAssertEqual(acl_get_permset(entry, &perms), 0)
        XCTAssertEqual(acl_add_perm(perms, ACL_WRITE_DATA), 0)
        XCTAssertEqual(acl_set_permset(entry, perms), 0)
        guard acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else { return XCTFail("acl_set_file: errno \(errno)") }
        let want = aclText(url)
        XCTAssertTrue(want.contains("deny"), want)
        XCTAssertNotEqual(info(url).st_mode & S_IWUSR, 0, "the owner-write bit is set")
        XCTAssertEqual(faccessat(AT_FDCWD, url.path, W_OK, AT_EACCESS), -1, "the kernel says no")
        for inPlace in [false, true] {
            for overwrite in [false, true] {
                let label = "inPlace \(inPlace) overwrite \(overwrite)"
                let calls = Calls()
                XCTAssertEqual(save("new", to: url, expected: Array("old".utf8), overwrite: overwrite, inPlace: inPlace, writer: RecordingWriter(calls: calls)),
                               .failure(.failed(.open, EACCES)), label)
                XCTAssertEqual(calls.all, [], label)
                XCTAssertEqual(bytes(url), Array("old".utf8), label)
                XCTAssertEqual(aclText(url), want, label)
                XCTAssertEqual(names(dir), ["a.txt"], label)
            }
        }
    }

    /// R1108-r3-b: Finder's Locked (the user immutable flag, set with chflags(2) on the row's own file and cleared in the defer):
    /// "locked", before any temp, by either branch, not even with overwrite; the system flag reaches the code through the seam only.
    func testALockedFileIsNeverWritten() throws {
        let dir = tempDir("tfw-locked")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let before = info(url).st_flags
        XCTAssertEqual(chflags(url.path, before | UInt32(UF_IMMUTABLE)), 0)
        defer { XCTAssertEqual(chflags(url.path, before), 0, "the row's own flag is cleared") }
        XCTAssertNotEqual(info(url).st_flags & UInt32(UF_IMMUTABLE), 0)
        for inPlace in [false, true] {
            for overwrite in [false, true] {
                let label = "inPlace \(inPlace) overwrite \(overwrite)"
                let calls = Calls()
                XCTAssertEqual(save("new", to: url, expected: Array("old".utf8), overwrite: overwrite, inPlace: inPlace, writer: RecordingWriter(calls: calls)),
                               .failure(.locked), label)
                XCTAssertEqual(calls.all, [], label)
                XCTAssertEqual(bytes(url), Array("old".utf8), label)
                XCTAssertEqual(names(dir), ["a.txt"], label)
            }
        }
    }

    func testTheSystemImmutableFlagIsLockedThroughTheSeam() throws {
        let dir = tempDir("tfw-locked-sys")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        for inPlace in [false, true] {
            for overwrite in [false, true] {
                XCTAssertEqual(save("new", to: url, expected: Array("old".utf8), overwrite: overwrite, inPlace: inPlace, flags: UInt32(SF_IMMUTABLE)),
                               .failure(.locked), "inPlace \(inPlace) overwrite \(overwrite)")
                XCTAssertEqual(bytes(url), Array("old".utf8))
                XCTAssertEqual(names(dir), ["a.txt"])
            }
        }
    }

    /// R1108-r4-a: the row appends one byte to its own file between the comparison's fstat and its read: "changed on disk" in both
    /// branches, the appended byte kept, nothing truncated, no temp. A file that did not grow saves; overwrite skips the comparison.
    func testAFileThatGrowsDuringTheComparisonIsChangedOnDisk() throws {
        let dir = tempDir("tfw-grow")
        let url = dir.appendingPathComponent("a.txt")
        let old = Array("old".utf8)
        func append() {
            let fd = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual([UInt8(0x21)].withUnsafeBytes { write(fd, $0.baseAddress, 1) }, 1)
            _ = close(fd)
        }
        for inPlace in [false, true] {
            let label = "inPlace \(inPlace)"
            _ = try file("a.txt", old, in: dir)
            var calls = 0
            XCTAssertEqual(save("new", to: url, expected: old, inPlace: inPlace, beforeRead: { calls += 1; append() }), .failure(.changedOnDisk), label)
            XCTAssertEqual(calls, 1, label)
            XCTAssertEqual(bytes(url), old + [0x21], "the appended byte is kept: \(label)")
            XCTAssertEqual(names(dir), ["a.txt"], label)
            // Not grown: saved, the seam called once.
            _ = try file("a.txt", old, in: dir)
            calls = 0
            XCTAssertEqual(save("new", to: url, expected: old, inPlace: inPlace, beforeRead: { calls += 1 }), .success(W.digest(Array("new".utf8))), label)
            XCTAssertEqual(calls, 1, label)
            XCTAssertEqual(bytes(url), Array("new".utf8), label)
            // Overwrite: no comparison, so no seam call; written.
            calls = 0
            XCTAssertEqual(save("newer", to: url, expected: old, overwrite: true, inPlace: inPlace, beforeRead: { calls += 1 }),
                           .success(W.digest(Array("newer".utf8))), label)
            XCTAssertEqual(calls, 0, label)
            XCTAssertEqual(bytes(url), Array("newer".utf8), label)
            XCTAssertEqual(names(dir), ["a.txt"], label)
        }
    }

    /// R1108-q3: a link loaded at a.txt, then retargeted by the row at its own b.txt or at a missing c.txt: with the load's
    /// identity the save is refused, with and without overwrite, and nothing is written or created. Without it (the control):
    /// today's behaviour, b.txt written and c.txt created.
    func testALinkRetargetedSinceTheLoadIsNeverWritten() throws {
        let dir = tempDir("tfw-retarget")
        let aaa = Array("aaa".utf8), bbb = Array("bbb".utf8)
        let a = try file("a.txt", aaa, in: dir)
        let b = try file("b.txt", bbb, in: dir)
        let link = dir.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink("a.txt", link.path), 0)
        guard case .success(let doc) = TextViewerDocument.load(link), let id = doc.identity else { return XCTFail("no identity") }
        XCTAssertEqual(id.path, a.path)
        func point(_ target: String) {
            XCTAssertEqual(unlink(link.path), 0)
            XCTAssertEqual(symlink(target, link.path), 0)
        }
        for target in ["b.txt", "c.txt"] {
            point(target)
            for overwrite in [false, true] {
                XCTAssertEqual(W.save("new", encoding: .utf8, to: link, expected: W.digest(aaa), overwrite: overwrite, identity: id),
                               .failure(.retargeted), "\(target) overwrite \(overwrite)")
                XCTAssertEqual(bytes(a), aaa)
                XCTAssertEqual(bytes(b), bbb)
                XCTAssertEqual(names(dir), ["a.txt", "b.txt", "link.txt"], "nothing created")
            }
        }
        // The control: no identity, today's behaviour.
        point("b.txt")
        XCTAssertEqual(W.save("new", encoding: .utf8, to: link, expected: W.digest(aaa), overwrite: true), .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(bytes(b), Array("new".utf8), "without the identity the other file is written")
        point("c.txt")
        XCTAssertEqual(W.save("new", encoding: .utf8, to: link, expected: W.digest(aaa)), .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(names(dir), ["a.txt", "b.txt", "c.txt", "link.txt"], "without the identity a file is created where the link points")
        XCTAssertEqual(bytes(a), aaa)
    }

    /// R1108-q3: the same path, another inode (the row renames its own sibling over the file): the identity does not refuse; the byte
    /// comparison decides (changed without overwrite, the same bytes saved) and overwrite writes. Deleted: created again at the path.
    func testAFileReplacedOrDeletedAtTheSamePathKeepsTodaysAnswers() throws {
        let dir = tempDir("tfw-identity-same")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        guard case .success(let doc) = TextViewerDocument.load(url), let id = doc.identity else { return XCTFail("no identity") }
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), identity: id), .success(W.digest(Array("new".utf8))))
        func replace(_ with: [UInt8]) throws {
            let side = try file("side.txt", with, in: dir)
            XCTAssertEqual(rename(side.path, url.path), 0)
            XCTAssertNotEqual(info(url).st_ino, id.inode)
        }
        let saved = W.digest(Array("new".utf8))
        try replace(Array("theirs".utf8))
        XCTAssertEqual(W.save("mine", encoding: .utf8, to: url, expected: saved, identity: id), .failure(.changedOnDisk))
        XCTAssertEqual(bytes(url), Array("theirs".utf8))
        XCTAssertEqual(W.save("mine", encoding: .utf8, to: url, expected: saved, overwrite: true, identity: id), .success(W.digest(Array("mine".utf8))))
        XCTAssertEqual(bytes(url), Array("mine".utf8))
        try replace(Array("same".utf8))
        XCTAssertEqual(W.save("next", encoding: .utf8, to: url, expected: W.digest(Array("same".utf8)), identity: id), .success(W.digest(Array("next".utf8))),
                       "the same bytes under another inode: saved")
        XCTAssertEqual(names(dir), ["a.txt"])
        for overwrite in [false, true] {
            XCTAssertEqual(unlink(url.path), 0)
            XCTAssertEqual(W.save("again", encoding: .utf8, to: url, expected: W.digest(Array("next".utf8)), overwrite: overwrite, identity: id),
                           .success(W.digest(Array("again".utf8))), "deleted: created at the same path")
            XCTAssertEqual(bytes(url), Array("again".utf8))
            XCTAssertEqual(names(dir), ["a.txt"])
        }
    }

    // MARK: round 6 (R1108-r5-b the load's identity names what it read; the append-only flag, a fact)

    /// R1108-r5-b: the row's own link is retargeted from its a.txt to its b.txt inside the load (the load's seam, between its resolve
    /// and its open); a save with overwrite and that document's identity never writes b.txt: retargeted, both files unchanged.
    func testALinkRetargetedDuringTheLoadIsNeverWrittenWithOverwrite() throws {
        let dir = tempDir("tfw-r5b")
        let aaa = Array("aaa".utf8), bbb = Array("bbb".utf8)
        let a = try file("a.txt", aaa, in: dir)
        let b = try file("b.txt", bbb, in: dir)
        let link = dir.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink("a.txt", link.path), 0)
        let loaded = TextViewerDocument.load(link, beforeOpen: {
            XCTAssertEqual(unlink(link.path), 0)
            XCTAssertEqual(symlink("b.txt", link.path), 0)
        })
        guard case .success(let doc) = loaded, let id = doc.identity else { return XCTFail("no identity: \(loaded)") }
        XCTAssertEqual(W.save("new", encoding: .utf8, to: link, expected: W.digest(Array(doc.text.utf8)), overwrite: true, identity: id),
                       .failure(.retargeted))
        XCTAssertEqual(bytes(a), aaa)
        XCTAssertEqual(bytes(b), bbb, "the other file is never written")
        XCTAssertEqual(names(dir), ["a.txt", "b.txt", "link.txt"], "nothing created")
    }

    /// Round 6 item 3, a fact (no product change): the user append-only flag, set with chflags(2) on the row's own file and cleared
    /// in the defer, is refused by the access check before either branch, even with overwrite: EPERM, no temp, the bytes kept.
    func testAnAppendOnlyFileIsRefusedBeforeAnyTemp() throws {
        let dir = tempDir("tfw-append")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let before = info(url).st_flags
        XCTAssertEqual(chflags(url.path, before | UInt32(UF_APPEND)), 0)
        defer { XCTAssertEqual(chflags(url.path, before), 0, "the row's own flag is cleared") }
        XCTAssertNotEqual(info(url).st_flags & UInt32(UF_APPEND), 0)
        for inPlace in [false, true] {
            for overwrite in [false, true] {
                let label = "inPlace \(inPlace) overwrite \(overwrite)"
                let calls = Calls()
                XCTAssertEqual(save("new", to: url, expected: Array("old".utf8), overwrite: overwrite, inPlace: inPlace, writer: RecordingWriter(calls: calls)),
                               .failure(.failed(.open, EPERM)), label)
                XCTAssertEqual(calls.all, [], label)
                XCTAssertEqual(bytes(url), Array("old".utf8), label)
                XCTAssertEqual(names(dir), ["a.txt"], label)
            }
        }
    }

    // MARK: round 7, writer half (R1108-q2 the folder fsync, the mode mask, the flags, the copy step, a read-only folder)

    /// The folder seam: records "sync <folder>" in `calls` and answers `code`.
    private func syncing(_ calls: Calls, _ code: Int32) -> (String) -> Int32 { { calls.add("sync \($0)"); return code } }

    /// R1108-q2: the folder is fsync'd once after a create and once after the rename (after "replace"), never in place; a failed
    /// folder fsync is not a failed save. The default opens a folder only (O_DIRECTORY).
    func testTheFolderIsSyncedAfterACreateAndAfterTheRenameNeverInPlace() throws {
        let dir = tempDir("tfw-fsync")
        let sync = "sync \(dir.path)"
        for code: Int32 in [0, EIO] {
            let url = dir.appendingPathComponent("a\(code).txt")
            let created = Calls()
            XCTAssertEqual(W.save("one", encoding: .utf8, to: url, expected: [], writer: RecordingWriter(calls: created),
                                  syncFolder: syncing(created, code)), .success(W.digest(Array("one".utf8))))
            XCTAssertEqual(created.all, [sync], "once per create")
            XCTAssertEqual(bytes(url), Array("one".utf8))

            let atomic = Calls()
            XCTAssertEqual(W.save("two", encoding: .utf8, to: url, expected: W.digest(Array("one".utf8)), writer: RecordingWriter(calls: atomic),
                                  syncFolder: syncing(atomic, code)), .success(W.digest(Array("two".utf8))))
            XCTAssertEqual(atomic.all, ["writeTemp", "replace", sync], "once per atomic save, after the rename")
            XCTAssertEqual(bytes(url), Array("two".utf8))

            let inPlace = Calls()
            XCTAssertEqual(W.save("three", encoding: .utf8, to: url, expected: W.digest(Array("two".utf8)), writer: RecordingWriter(calls: inPlace),
                                  stat: seam { $0.st_uid = geteuid() &+ 1 }, syncFolder: syncing(inPlace, code)), .success(W.digest(Array("three".utf8))))
            XCTAssertEqual(inPlace.all, [], "never in place")
            XCTAssertEqual(bytes(url), Array("three".utf8))
        }
        XCTAssertEqual(names(dir), ["a0.txt", "a5.txt"])
        XCTAssertEqual(W.syncFolder(dir.path), 0)
        XCTAssertEqual(W.syncFolder(dir.appendingPathComponent("a0.txt").path), ENOTDIR)
    }

    /// Records the mode asked for (octal) and makes the real temp with the permission bits only: no row ever sets a real setuid,
    /// setgid or sticky bit, whatever the code asks.
    private struct ModeWriter: ManagedConfigFileWriter {
        let real = ManagedConfigPOSIXWriter()
        let calls: Calls
        func writeTemp(_ data: [UInt8], besides target: URL, mode: mode_t) throws -> URL {
            calls.add(String(mode, radix: 8))
            return try real.writeTemp(data, besides: target, mode: mode & 0o777)
        }
        func replace(_ target: URL, with temp: URL) throws { try real.replace(target, with: temp) }
    }

    /// The mode mask: setuid, setgid and sticky reach the code through the stat seam only; the temp is asked for the file's
    /// permission bits and the sticky bit (st_mode & 0o1777), never 0o4000 or 0o2000.
    func testTheSetuidAndSetgidBitsAreNeverAskedForAgain() throws {
        let dir = tempDir("tfw-setid")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let perms = info(url).st_mode & 0o777
        let calls = Calls()
        let setid = seam { if $0.st_mode & S_IFMT == S_IFREG { $0.st_mode |= S_ISUID | S_ISGID | S_ISVTX } }
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), writer: ModeWriter(calls: calls), stat: setid),
                       .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(calls.all, [String(perms | 0o1000, radix: 8)])
        XCTAssertEqual(info(url).st_mode & 0o7777, perms)
        XCTAssertEqual(bytes(url), Array("new".utf8))
        XCTAssertEqual(names(dir), ["a.txt"])
    }

    /// The flags the owner sets (R1108-r7-a, round 7b): UF_HIDDEN set with chflags(2) on the row's own file (cleared in the defer,
    /// the clear asserted) is saved ATOMICALLY with the flag on the new inode; a write failure through the writer leaves the old
    /// bytes whole and no temp. UF_NODUMP (and UF_TRACKED) through the stat seam: atomic, the flags seam asked for UF_NODUMP only,
    /// on the sibling temp, after the copy step and the comparison, right before the rename.
    func testAHiddenOrNoDumpFileIsSavedAtomicallyAndKeepsItsFlags() throws {
        let dir = tempDir("tfw-flags")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let before = info(url)
        XCTAssertEqual(chflags(url.path, before.st_flags | UInt32(UF_HIDDEN)), 0)
        defer { XCTAssertEqual(chflags(url.path, before.st_flags), 0, "the row's own flag is cleared") }
        let calls = Calls()
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: calls)),
                       .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(calls.all, ["writeTemp", "replace"], "atomic")
        XCTAssertNotEqual(info(url).st_ino, before.st_ino, "a new inode")
        XCTAssertNotEqual(info(url).st_flags & UInt32(UF_HIDDEN), 0, "the hidden flag is on the new file")
        XCTAssertEqual(bytes(url), Array("new".utf8))
        let failing = Calls()
        XCTAssertEqual(W.save("newer", encoding: .utf8, to: url, expected: W.digest(Array("new".utf8)), writer: FailingTempWriter(code: ENOSPC, calls: failing)),
                       .failure(.failed(.temp, ENOSPC)))
        XCTAssertEqual(failing.all, ["writeTemp"], "never a replace")
        XCTAssertEqual(bytes(url), Array("new".utf8), "the old bytes are whole")
        XCTAssertNotEqual(info(url).st_flags & UInt32(UF_HIDDEN), 0)

        let all = copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
        for flags in [UInt32(UF_NODUMP), UInt32(UF_NODUMP | UF_TRACKED)] {
            let other = try file("b\(flags).txt", Array("old".utf8), in: dir)
            let ino = info(other).st_ino
            let asked = Calls()
            XCTAssertEqual(W.save("new", encoding: .utf8, to: other, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: asked),
                                  stat: seam { $0.st_flags |= flags }, copyAttributes: copying(asked), setFlags: flagging(asked, other, 0),
                                  beforeRead: { asked.add("compare") }), .success(W.digest(Array("new".utf8))))
            XCTAssertEqual(asked.all, ["writeTemp", "copy \(all)", "compare", "flags \(UF_NODUMP)", "replace"], "\(flags)")
            XCTAssertNotEqual(info(other).st_ino, ino, "a new inode: atomic")
            XCTAssertEqual(bytes(other), Array("new".utf8))
        }
        let plain = try file("c.txt", Array("old".utf8), in: dir)
        let none = Calls()
        XCTAssertEqual(W.save("new", encoding: .utf8, to: plain, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: none),
                              setFlags: flagging(none, plain, 0)), .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(none.all, ["writeTemp", "replace"], "no flag: the flags seam is never asked")
        XCTAssertEqual(names(dir), ["a.txt", "b1.txt", "b65.txt", "c.txt"], "no temp left")
    }

    /// An allow-read entry for uid 1 (a system account) set in process on the row's own file. 0 or an errno.
    private func allowRead(_ url: URL) -> Int32 {
        var acl: acl_t? = acl_init(1)
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var perms: acl_permset_t?
        let who = UUID(uuidString: "FFFFEEEE-DDDD-CCCC-BBBB-AAAA00000001")!.uuid
        guard acl_create_entry(&acl, &entry) == 0, acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0,
              withUnsafeBytes(of: who, { acl_set_qualifier(entry, $0.baseAddress) }) == 0, acl_get_permset(entry, &perms) == 0,
              acl_add_perm(perms, ACL_READ_DATA) == 0, acl_set_permset(entry, perms) == 0,
              acl_set_file(url.path, ACL_TYPE_EXTENDED, acl) == 0 else { return errno }
        return 0
    }

    /// The copy step through its seam (no other volume): ENOTSUP or EOPNOTSUPP (a volume without access lists or xattrs) is not
    /// a failed save: in place, which keeps an access list the file has; any other errno fails as before, nothing written.
    func testACopyStepTheVolumeCannotDoIsWrittenInPlace() throws {
        let dir = tempDir("tfw-copy")
        let plain = try file("plain.txt", Array("old".utf8), in: dir)
        let listed = try file("listed.txt", Array("old".utf8), in: dir)
        XCTAssertEqual(allowRead(listed), 0)
        let want = aclText(listed)
        XCTAssertFalse(want.isEmpty)
        for (url, code) in [(plain, ENOTSUP), (listed, EOPNOTSUPP)] {
            let ino = info(url).st_ino
            let calls = Calls()
            XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: calls),
                                  copyAttributes: { _, _, _ in code }), .success(W.digest(Array("new".utf8))), "\(code)")
            XCTAssertEqual(calls.all, ["writeTemp"], "a temp, no replace")
            XCTAssertEqual(info(url).st_ino, ino, "same inode: written in place")
            XCTAssertEqual(bytes(url), Array("new".utf8))
        }
        XCTAssertEqual(aclText(listed), want, "the access list is kept")
        XCTAssertEqual(W.save("newer", encoding: .utf8, to: plain, expected: W.digest(Array("new".utf8)), copyAttributes: { _, _, _ in ENOSPC }),
                       .failure(.failed(.copyAttributes, ENOSPC)))
        XCTAssertEqual(bytes(plain), Array("new".utf8))
        XCTAssertEqual(names(dir), ["listed.txt", "plain.txt"], "no temp left")
    }

    /// Fails writeTemp with `code` (no file made); replace is only recorded.
    private struct FailingTempWriter: ManagedConfigFileWriter {
        let code: Int32
        let calls: Calls
        func writeTemp(_ data: [UInt8], besides target: URL, mode: mode_t) throws -> URL {
            calls.add("writeTemp")
            throw ManagedConfigPOSIXWriter.WriteError(step: "create temp", code: code)
        }
        func replace(_ target: URL, with temp: URL) throws { calls.add("replace") }
    }

    /// Item 5 through the writer seam: the temp's EROFS falls back to in place like EACCES (with or without overwrite); no
    /// other errno does (ENOSPC: failed, nothing written).
    func testOnlyEACCESOrEROFSFromTheTempFallsBackToInPlace() throws {
        let dir = tempDir("tfw-temp-errno")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let ino = info(url).st_ino
        let calls = Calls()
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), writer: FailingTempWriter(code: ENOSPC, calls: calls)),
                       .failure(.failed(.temp, ENOSPC)))
        XCTAssertEqual(bytes(url), Array("old".utf8))
        for overwrite in [false, true] {
            let text = overwrite ? "newer" : "new"
            XCTAssertEqual(W.save(text, encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), overwrite: overwrite,
                                  writer: FailingTempWriter(code: EROFS, calls: calls)), .success(W.digest(Array(text.utf8))))
            XCTAssertEqual(bytes(url), Array(text.utf8))
        }
        XCTAssertEqual(calls.all, ["writeTemp", "writeTemp", "writeTemp"], "never a replace")
        XCTAssertEqual(info(url).st_ino, ino, "same inode: written in place")
        XCTAssertEqual(names(dir), ["a.txt"])
    }

    // MARK: round 7b (R1108-r7-a the flags the owner sets stay atomic, R1108-r7-b the copy retried with the xattrs alone)

    /// The flags seam: records "flags <value>" when asked for a sibling temp of `file` ("flags on <path>" for anything else, the
    /// file itself included) and answers `code`; no real call.
    private func flagging(_ calls: Calls, _ file: URL, _ code: Int32) -> (String, UInt32) -> Int32 {
        let folder = file.deletingLastPathComponent().path, prefix = ".\(file.lastPathComponent).prosper-"
        return { p, v in
            let temp = (p as NSString).deletingLastPathComponent == folder && (p as NSString).lastPathComponent.hasPrefix(prefix)
            calls.add(temp ? "flags \(v)" : "flags on \(p)")
            return code
        }
    }

    /// The copy seam: records "copy <flags>" and answers `answer(flags)`, or the real copy with those flags when that is nil.
    private func copying(_ calls: Calls, _ answer: @escaping (copyfile_flags_t) -> Int32? = { _ in nil }) -> (String, String, copyfile_flags_t) -> Int32 {
        { f, t, flags in calls.add("copy \(flags)"); return answer(flags) ?? W.copyAttributes(f, t, flags) }
    }

    /// The document id (ATTR_CMN_DOCUMENT_ID, a read with getattrlist; it needs FSOPT_ATTR_CMN_EXTENDED). 0: none or unreadable.
    private func documentID(_ url: URL) -> UInt32 {
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_DOCUMENT_ID), volattr: 0,
                            dirattr: 0, fileattr: 0, forkattr: 0)
        var buf: (UInt32, UInt32) = (0, 0)
        guard getattrlist(url.path, &list, &buf, MemoryLayout<(UInt32, UInt32)>.size, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)) == 0 else { return 0 }
        return buf.1
    }

    /// Any other flag (system, compressed, dataless, an unknown bit; through the stat seam only, no real flag is set) goes in
    /// place as round 7 did: no temp, the flags seam never asked, same inode.
    func testAFlagTheOwnerCannotSetIsWrittenInPlace() throws {
        let dir = tempDir("tfw-flags-rest")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let ino = info(url).st_ino
        var last = Array("old".utf8)
        for flags in [UInt32(SF_ARCHIVED), UInt32(UF_COMPRESSED), UInt32(SF_DATALESS), UInt32(UF_HIDDEN | SF_ARCHIVED), UInt32(UF_TRACKED | 0x100)] {
            let calls = Calls()
            let text = "new \(flags)"
            XCTAssertEqual(W.save(text, encoding: .utf8, to: url, expected: W.digest(last), writer: RecordingWriter(calls: calls),
                                  stat: seam { $0.st_flags |= flags }, setFlags: flagging(calls, url, 0)), .success(W.digest(Array(text.utf8))), "\(flags)")
            XCTAssertEqual(calls.all, [], "no temp, no flags: in place, \(flags)")
            XCTAssertEqual(bytes(url), Array(text.utf8))
            last = Array(text.utf8)
        }
        XCTAssertEqual(info(url).st_ino, ino, "same inode: written in place")
        XCTAssertEqual(names(dir), ["a.txt"])
    }

    /// A flags step that fails (EPERM through the seam, no real call) drops the flag and stays ATOMIC (the coordinator's ruling):
    /// the new bytes on a new inode without the hidden flag, no temp left.
    func testAFailedFlagStepDropsTheFlagAndStaysAtomic() throws {
        let dir = tempDir("tfw-flags-eperm")
        let url = try file("a.txt", Array("old".utf8), in: dir)
        let before = info(url)
        XCTAssertEqual(chflags(url.path, before.st_flags | UInt32(UF_HIDDEN)), 0)
        defer { XCTAssertEqual(chflags(url.path, before.st_flags), 0, "the row's own flag is cleared") }
        let calls = Calls()
        XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: calls),
                              setFlags: flagging(calls, url, EPERM)), .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(calls.all, ["writeTemp", "flags \(UF_HIDDEN)", "replace"])
        XCTAssertNotEqual(info(url).st_ino, before.st_ino, "a new inode: atomic")
        XCTAssertEqual(info(url).st_flags & UInt32(UF_HIDDEN), 0, "the flag is dropped")
        XCTAssertEqual(bytes(url), Array("new".utf8))
        XCTAssertEqual(names(dir), ["a.txt"], "no temp left")
    }

    /// The measurement on the row's own file: the owner sets UF_HIDDEN, UF_NODUMP and UF_TRACKED (each cleared, the clear
    /// asserted). A tracked file, and a tracked and hidden one, is saved atomically and keeps UF_TRACKED and its document id (the
    /// kernel carries both over the rename); the real flags call is asked for the hidden flag only, never the tracked one.
    func testTheOwnerSetsHiddenNoDumpAndTrackedAndATrackedFileKeepsItsDocumentID() throws {
        let dir = tempDir("tfw-tracked")
        let probe = try file("probe.txt", Array("old".utf8), in: dir)
        let clean = info(probe).st_flags
        for flag in [UF_HIDDEN, UF_NODUMP, UF_TRACKED] {
            XCTAssertEqual(chflags(probe.path, clean | UInt32(flag)), 0, "the owner sets \(flag)")
            XCTAssertNotEqual(info(probe).st_flags & UInt32(flag), 0)
            XCTAssertEqual(chflags(probe.path, clean), 0, "the row's own flag is cleared")
        }
        let mask = UInt32(UF_NODUMP | UF_HIDDEN | UF_TRACKED)
        for flags in [UInt32(UF_TRACKED), UInt32(UF_TRACKED | UF_HIDDEN)] {
            let url = try file("t\(flags).txt", Array("old".utf8), in: dir)
            let before = info(url).st_flags
            XCTAssertEqual(chflags(url.path, before | flags), 0)
            defer { XCTAssertEqual(chflags(url.path, before), 0, "the row's own flag is cleared") }
            let id = documentID(url)
            XCTAssertNotEqual(id, 0, "a tracked file has a document id")
            let ino = info(url).st_ino
            let calls = Calls()
            XCTAssertEqual(W.save("new", encoding: .utf8, to: url, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: calls),
                                  setFlags: { p, v in calls.add("flags \(v)"); return W.setFlags(p, v) }), .success(W.digest(Array("new".utf8))))
            XCTAssertEqual(calls.all, flags == UInt32(UF_TRACKED) ? ["writeTemp", "replace"] : ["writeTemp", "flags \(UF_HIDDEN)", "replace"])
            XCTAssertNotEqual(info(url).st_ino, ino, "a new inode: atomic")
            XCTAssertEqual(info(url).st_flags & mask, flags, "the flags are on the new file")
            XCTAssertEqual(documentID(url), id, "the document id is kept")
            XCTAssertEqual(bytes(url), Array("new".utf8))
        }
        XCTAssertEqual(names(dir), ["probe.txt", "t32832.txt", "t64.txt"], "no temp left")
    }

    /// R1108-r7-b through the copy seam (no other volume): the first try (xattrs and access list) answers ENOTSUP or EOPNOTSUPP and
    /// the second (the xattrs alone, the same no-follow flags) succeeds: atomic, a new inode, the xattr copied. A file with an
    /// access list (set in process) is never retried: in place, the list kept. Another errno from either try fails, nothing written.
    func testACopyStepRetriedWithTheXattrsAloneStaysAtomic() throws {
        let dir = tempDir("tfw-copy-retry")
        let all = copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
        let xattrs = all & ~copyfile_flags_t(COPYFILE_ACL)
        let plain = try file("plain.txt", Array("old".utf8), in: dir)
        let value: [UInt8] = Array("example".utf8)
        XCTAssertEqual(setxattr(plain.path, "com.example.tag", value, value.count, 0, 0), 0)
        let listed = try file("listed.txt", Array("old".utf8), in: dir)
        XCTAssertEqual(allowRead(listed), 0)
        let want = aclText(listed)
        XCTAssertFalse(want.isEmpty)
        var last = Array("old".utf8)
        for code in [ENOTSUP, EOPNOTSUPP] {
            let ino = info(plain).st_ino
            let calls = Calls()
            let text = "new \(code)"
            XCTAssertEqual(W.save(text, encoding: .utf8, to: plain, expected: W.digest(last), writer: RecordingWriter(calls: calls),
                                  copyAttributes: copying(calls) { $0 & copyfile_flags_t(COPYFILE_ACL) != 0 ? code : nil }),
                           .success(W.digest(Array(text.utf8))), "\(code)")
            XCTAssertEqual(calls.all, ["writeTemp", "copy \(all)", "copy \(xattrs)", "replace"], "\(code)")
            XCTAssertNotEqual(info(plain).st_ino, ino, "a new inode: atomic")
            XCTAssertEqual(getxattr(plain.path, "com.example.tag", nil, 0, 0, 0), value.count, "the xattr is copied by the retry")
            XCTAssertEqual(bytes(plain), Array(text.utf8))
            last = Array(text.utf8)
        }
        let ino = info(listed).st_ino
        let kept = Calls()
        XCTAssertEqual(W.save("new", encoding: .utf8, to: listed, expected: W.digest(Array("old".utf8)), writer: RecordingWriter(calls: kept),
                              copyAttributes: copying(kept) { $0 & copyfile_flags_t(COPYFILE_ACL) != 0 ? ENOTSUP : nil }),
                       .success(W.digest(Array("new".utf8))))
        XCTAssertEqual(kept.all, ["writeTemp", "copy \(all)"], "no retry (it would drop the list), no replace")
        XCTAssertEqual(info(listed).st_ino, ino, "same inode: written in place")
        XCTAssertEqual(aclText(listed), want, "the access list is kept")

        let first = Calls()
        XCTAssertEqual(W.save("newer", encoding: .utf8, to: plain, expected: W.digest(last), writer: RecordingWriter(calls: first),
                              copyAttributes: copying(first) { _ in ENOSPC }), .failure(.failed(.copyAttributes, ENOSPC)))
        XCTAssertEqual(first.all, ["writeTemp", "copy \(all)"], "one try")
        let second = Calls()
        XCTAssertEqual(W.save("newer", encoding: .utf8, to: plain, expected: W.digest(last), writer: RecordingWriter(calls: second),
                              copyAttributes: copying(second) { $0 & copyfile_flags_t(COPYFILE_ACL) != 0 ? ENOTSUP : ENOSPC }),
                       .failure(.failed(.copyAttributes, ENOSPC)))
        XCTAssertEqual(second.all, ["writeTemp", "copy \(all)", "copy \(xattrs)"], "the retry's errno fails, no replace")
        XCTAssertEqual(bytes(plain), last, "the old bytes are whole")
        XCTAssertEqual(W.save("newer", encoding: .utf8, to: listed, expected: W.digest(Array("new".utf8)), copyAttributes: { _, _, _ in ENOSPC }),
                       .failure(.failed(.copyAttributes, ENOSPC)))
        XCTAssertEqual(bytes(listed), Array("new".utf8))
        XCTAssertEqual(W.save("newest", encoding: .utf8, to: listed, expected: W.digest(Array("new".utf8))), .success(W.digest(Array("newest".utf8))))
        XCTAssertEqual(aclText(listed), want, "the access list is kept in every case")
        XCTAssertEqual(names(dir), ["listed.txt", "plain.txt"], "no temp left")
    }
}
