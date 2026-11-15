import Darwin
import XCTest
@testable import ProsperApp

/// #1106 (design #1105 D1, section 3 C1): what the viewer reads. Files are fakes in a tempDir().
final class TextViewerDocumentTests: XCTestCase {

    private func file(_ name: String, _ bytes: [UInt8], in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func doc(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> TextViewerDocument {
        switch TextViewerDocument.load(url) {
        case .success(let d): return d
        case .failure(let r): XCTFail("refused: \(r)", file: file, line: line); throw r
        }
    }

    func testEncodings() throws {
        let dir = tempDir("tv-doc")
        let text = "h\u{E9}llo\nw\u{F6}rld \u{1F600}\n"
        let utf8 = Array(text.utf8)
        func utf16(_ little: Bool) -> [UInt8] {
            text.utf16.flatMap { u in little ? [UInt8(u & 0xFF), UInt8(u >> 8)] : [UInt8(u >> 8), UInt8(u & 0xFF)] }
        }
        let cases: [(String, [UInt8], TextViewerDocument.Encoding)] = [
            ("a.txt", utf8, .utf8),
            ("b.txt", [0xEF, 0xBB, 0xBF] + utf8, .utf8BOM),
            ("c.txt", [0xFF, 0xFE] + utf16(true), .utf16LE),
            ("d.txt", [0xFE, 0xFF] + utf16(false), .utf16BE),
        ]
        for (name, bytes, encoding) in cases {
            let d = try doc(try file(name, bytes, in: dir))
            XCTAssertEqual(d.text, text, name)
            XCTAssertEqual(d.encoding, encoding, name)
            XCTAssertFalse(d.readOnly, name)
        }
    }

    /// R1118-8: UTF-16 edges. The text shown and the label are pinned for each.
    func testUTF16Edges() throws {
        let dir = tempDir("tv-doc")
        let empty = try doc(try file("e.txt", [0xFF, 0xFE], in: dir))
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.encoding, .utf16LE, "an empty body after the mark")
        let odd = try doc(try file("o.txt", [0xFF, 0xFE, 0x61], in: dir))
        XCTAssertEqual(odd.text, "", "an odd last byte is no character")
        XCTAssertEqual(odd.encoding, .lossy)
        XCTAssertTrue(odd.readOnly)
        let odd3 = try doc(try file("o3.txt", [0xFE, 0xFF, 0x00, 0x61, 0x00], in: dir))
        XCTAssertEqual(odd3.text, "a")
        XCTAssertEqual(odd3.encoding, .lossy)
        let lone = try doc(try file("s.txt", [0xFF, 0xFE, 0x00, 0xD8, 0x61, 0x00], in: dir))
        XCTAssertEqual(lone.text, "\u{FFFD}a", "a lone surrogate")
        XCTAssertEqual(lone.encoding, .lossy)
        XCTAssertTrue(lone.readOnly)
        XCTAssertEqual(TextViewerDocument.load(try file("u32.txt", [0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00, 0x00, 0x00], in: dir)),
                       .failure(.binary), "a UTF-32 LE mark reads as UTF-16 with NUL units")
    }

    func testInvalidUTF8IsShownReadOnly() throws {
        let d = try doc(try file("latin1.txt", [0x63, 0x61, 0x66, 0xE9, 0x0A], in: tempDir("tv-doc")))
        XCTAssertEqual(d.encoding, .lossy)
        XCTAssertTrue(d.readOnly)
        XCTAssertEqual(d.text, "caf\u{FFFD}\n")
    }

    /// R1108-bom2: the first UTF-8 mark is the encoding's; a mark after it is the text's own and stays, so a save writes it back.
    /// No mark and one mark decode as before; an invalid byte is still U+FFFD, read-only.
    func testASecondUTF8MarkStaysInTheText() {
        let m: [UInt8] = [0xEF, 0xBB, 0xBF]
        let cases: [([UInt8], String, TextViewerDocument.Encoding)] = [
            ([0x61, 0x0A], "a\n", .utf8),
            (m + [0x61, 0x0A], "a\n", .utf8BOM),
            (m, "", .utf8BOM),
            (m + m + [0x61], "\u{FEFF}a", .utf8BOM),
            (m + m + m, "\u{FEFF}\u{FEFF}", .utf8BOM),
            ([0x61] + m, "a\u{FEFF}", .utf8),
            (m + [0x61, 0xFF], "a\u{FFFD}", .lossy),
        ]
        for (bytes, text, encoding) in cases {
            guard case .success(let d) = TextViewerDocument.decode(Data(bytes)) else { XCTFail("refused \(bytes)"); continue }
            XCTAssertEqual(d.text, text, "\(bytes)")
            XCTAssertEqual(d.encoding, encoding, "\(bytes)")
            XCTAssertEqual(d.readOnly, encoding == .lossy, "\(bytes)")
        }
    }

    /// Section 3 C1: a regular file, at most 16 MiB, not binary. Everything else is refused before
    /// the bytes are read whole, and a FIFO never blocks the open.
    func testRefusals() throws {
        let dir = tempDir("tv-doc")
        XCTAssertEqual(TextViewerDocument.load(try file("nul.md", Array("abc".utf8) + [0] + Array("def".utf8), in: dir)),
                       .failure(.binary))
        XCTAssertEqual(TextViewerDocument.load(try file("nul16.txt", [0xFF, 0xFE, 0x61, 0x00, 0x00, 0x00], in: dir)),
                       .failure(.binary), "a NUL code unit in UTF-16")
        // Past the sniffed head a NUL is text (D1 reads the first 8 KiB only).
        let late = [UInt8](repeating: 0x61, count: TextViewerDocument.sniffBytes) + [0]
        XCTAssertEqual(try doc(try file("late.txt", late, in: dir)).text.utf8.count, late.count)

        let big = dir.appendingPathComponent("big.txt")   // sparse: 16 MiB + 1 byte, no write of the bytes
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(TextViewerDocument.maxBytes + 1))
        try h.close()
        XCTAssertEqual(TextViewerDocument.load(big), .failure(.tooLarge))
        let edge = try file("edge.txt", [UInt8](repeating: 0x61, count: TextViewerDocument.maxBytes), in: dir)
        XCTAssertEqual(try doc(edge).text.utf8.count, TextViewerDocument.maxBytes, "16 MiB exactly is shown")

        let fifo = dir.appendingPathComponent("pipe.md")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertEqual(TextViewerDocument.load(fifo), .failure(.notRegular))
        XCTAssertEqual(TextViewerDocument.load(dir), .failure(.notRegular))
        XCTAssertEqual(TextViewerDocument.load(dir.appendingPathComponent("gone.md")), .failure(.missing))
    }

    func testSymlinkReadsItsTarget() throws {
        let dir = tempDir("tv-doc")
        let target = try file("real.md", Array("# hi\n".utf8), in: dir)
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(try doc(link).text, "# hi\n")
    }

    /// R1162-2: a link changed between two loads (a reload) is followed to what it names at the open, and
    /// the type is the opened file's: a pipe or a folder behind the link is refused without blocking.
    func testRepointedSymlinkIsCheckedAtTheOpen() throws {
        let dir = tempDir("tv-doc")
        let first = try file("first.md", Array("one\n".utf8), in: dir)
        let second = try file("second.md", Array("two\n".utf8), in: dir)
        let fifo = dir.appendingPathComponent("pipe.md")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let sub = dir.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let link = dir.appendingPathComponent("link.md")
        func point(at target: URL) throws {
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }
        try point(at: first)
        XCTAssertEqual(try doc(link).text, "one\n")
        try point(at: second)
        XCTAssertEqual(try doc(link).text, "two\n", "the link the person opened is followed, to its target now")
        try point(at: fifo)
        XCTAssertEqual(TextViewerDocument.load(link), .failure(.notRegular), "a pipe behind the link")
        try point(at: sub)
        XCTAssertEqual(TextViewerDocument.load(link), .failure(.notRegular), "a folder behind the link")
    }

    func testLineEndings() {
        let cases: [(String, TextViewerDocument.LineEnding)] = [
            ("", .none), ("one line", .none), ("a\nb\n", .lf), ("a\r\nb\r\n", .crlf), ("a\rb\r", .cr),
            ("a\nb\r\n", .mixed), ("a\rb\n", .mixed), ("a\r\nb\r", .mixed),
        ]
        for (text, ending) in cases {
            XCTAssertEqual(TextViewerDocument.lineEnding(of: text), ending, text.debugDescription)
        }
        XCTAssertEqual(TextViewerDocument.decode(Data("x\r\ny\r\n".utf8)), .success(
            TextViewerDocument(text: "x\r\ny\r\n", encoding: .utf8, lineEnding: .crlf)))
    }

    /// R1108-q3: the load records what it opened: the row's own lstat of its file; through a link, the target's path and inode,
    /// never the link's. decode alone has none.
    func testLoadGivesTheIdentityOfTheFileItRead() throws {
        let dir = tempDir("tv-doc-identity")
        let url = try file("a.txt", Array("one\n".utf8), in: dir)
        var own = stat()
        XCTAssertEqual(lstat(url.path, &own), 0)
        let want = TextViewerDocument.Identity(path: url.path, device: own.st_dev, inode: own.st_ino)
        XCTAssertEqual(try doc(url).identity, want)
        let link = dir.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink("a.txt", link.path), 0)
        var linkStat = stat()
        XCTAssertEqual(lstat(link.path, &linkStat), 0)
        let viaLink = try doc(link).identity
        XCTAssertEqual(viaLink, want, "the target's path and inode")
        XCTAssertNotEqual(viaLink?.inode, linkStat.st_ino, "not the link's")
        XCTAssertTrue(((try? TextViewerDocument.decode(Data("x".utf8)).get())?.identity) == nil)
    }

    /// R1108-r5-b: the row retargets its own link from its a.txt to its b.txt between the load's resolve and its open (the seam,
    /// called once): the identity names the file whose text was read (path, device and inode), never b.txt beside a.txt's text.
    func testALinkRetargetedDuringTheLoadNeverRecordsTheOtherFile() throws {
        let dir = tempDir("tv-doc-r5b")
        let a = try file("a.txt", Array("aaa".utf8), in: dir)
        let b = try file("b.txt", Array("bbb".utf8), in: dir)
        let link = dir.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink("a.txt", link.path), 0)
        var calls = 0
        let result = TextViewerDocument.load(link, beforeOpen: {
            calls += 1
            XCTAssertEqual(unlink(link.path), 0)
            XCTAssertEqual(symlink("b.txt", link.path), 0)
        })
        XCTAssertEqual(calls, 1, "the seam runs once")
        guard case .success(let d) = result else { return XCTFail("refused: \(result)") }
        XCTAssertEqual(d.text, "aaa", "the file resolved before the retarget is the one read")
        let id = try XCTUnwrap(d.identity, "a link that resolves gets an identity")
        let read = d.text == "aaa" ? a : b
        var st = stat()
        XCTAssertEqual(lstat(read.path, &st), 0)
        XCTAssertEqual(id, TextViewerDocument.Identity(path: read.path, device: st.st_dev, inode: st.st_ino),
                       "the identity names the file whose text was read")
        XCTAssertNotEqual(id.path, (d.text == "aaa" ? b : a).path, "never the other file's path beside this text")
        XCTAssertEqual(try Data(contentsOf: a), Data("aaa".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("bbb".utf8))
    }

    // R1108-r6-a rows. No main actor, no task: nothing crosses to another task. Links live and point only inside the row's tempDir().
    private func lstatOf(_ url: URL) -> stat { var st = stat(); XCTAssertEqual(lstat(url.path, &st), 0); return st }

    /// The seam replaces the resolved end (a.txt) with a link to b.txt on its FIRST call only: the second resolve follows it.
    func testAnEndThatBecameALinkOnceIsResolvedAgainAndTheIdentityNamesTheNewTarget() throws {
        let dir = tempDir("tv-doc-r7a")
        let a = try file("a.txt", Array("aaa".utf8), in: dir)
        let b = try file("b.txt", Array("bbb".utf8), in: dir)
        var calls = 0
        let result = TextViewerDocument.load(a, beforeOpen: {
            calls += 1
            if calls == 1 { XCTAssertEqual(unlink(a.path), 0); XCTAssertEqual(symlink("b.txt", a.path), 0) }
        })
        XCTAssertEqual(calls, 2, "one retry, no third try")
        guard case .success(let d) = result else { return XCTFail("refused: \(result)") }
        XCTAssertEqual(d.text, "bbb")
        let st = lstatOf(b)
        XCTAssertEqual(d.identity, TextViewerDocument.Identity(path: b.path, device: st.st_dev, inode: st.st_ino))
        XCTAssertNotEqual(d.identity?.path, a.path)
        XCTAssertEqual(try Data(contentsOf: b), Data("bbb".utf8))
    }

    /// The seam swaps the resolved end on EVERY call (a.txt, then b.txt, each becomes a link to the next file): both resolved
    /// opens end in ELOOP, the plain open of a.txt follows a -> b -> c, no identity.
    func testAnEndThatBecomesALinkOnEveryTryShowsTheFileWithNoIdentity() throws {
        let dir = tempDir("tv-doc-r7b")
        let a = try file("a.txt", Array("aaa".utf8), in: dir)
        _ = try file("b.txt", Array("bbb".utf8), in: dir)
        _ = try file("c.txt", Array("ccc".utf8), in: dir)
        var calls = 0
        let result = TextViewerDocument.load(a, beforeOpen: {
            calls += 1
            guard calls <= 2 else { return }
            let end = dir.appendingPathComponent(calls == 1 ? "a.txt" : "b.txt").path
            XCTAssertEqual(unlink(end), 0); XCTAssertEqual(symlink(calls == 1 ? "b.txt" : "c.txt", end), 0)
        })
        XCTAssertEqual(calls, 2, "exactly two tries")
        guard case .success(let d) = result else { return XCTFail("refused: \(result)") }
        XCTAssertEqual(d.text, "ccc")
        XCTAssertNil(d.identity)
    }

    /// A plain file calls the seam once.
    func testAPlainFileCallsTheSeamOnce() throws {
        let dir = tempDir("tv-doc-r7c")
        let a = try file("a.txt", Array("aaa".utf8), in: dir)
        var calls = 0
        guard case .success(let d) = TextViewerDocument.load(a, beforeOpen: { calls += 1 }) else { return XCTFail("refused") }
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(d.identity)
    }

    /// FACT: resolve's bound is 32 readlinks: 31 links get an identity, 32 links are refused by resolve (no identity). If the
    /// plain open shows the file, it is shown; if the kernel's own limit refuses it, the refusal is .unreadable (as today).
    func testAChainOfThirtyTwoLinksHasNoIdentity() throws {
        let dir = tempDir("tv-doc-r7d")
        _ = try file("real.txt", Array("rrr".utf8), in: dir)
        for n in [31, 32] {
            var prev = "real.txt"
            for i in 0..<n {
                let name = "c\(n)-\(i).txt"
                XCTAssertEqual(symlink(prev, dir.appendingPathComponent(name).path), 0)
                prev = name
            }
            let head = dir.appendingPathComponent(prev)
            switch TextViewerDocument.load(head) {
            case .success(let d):
                XCTAssertEqual(d.text, "rrr")
                if n == 31 { XCTAssertNotNil(d.identity) } else { XCTAssertNil(d.identity, "resolve refused 32 links") }
            case .failure(let r):
                XCTAssertEqual(r, .unreadable, "only the kernel's own link limit may refuse it")
                XCTAssertEqual(n, 32, "31 links must load")
            }
        }
    }

    /// FACT: a link whose target bytes are not UTF-8 (78 FF 79, made with symlink(2) from a byte array, relative so inside
    /// tempDir()). The volume refuses a file with such a name (EILSEQ), so the target never exists: the link dangles and the
    /// plain open answers missing, as before; no document, so no identity. If a volume did accept the name, the file is shown.
    func testALinkWhoseTargetIsNotUTF8IsRefusedAsMissingOrShownWithNoIdentity() throws {
        let dir = tempDir("tv-doc-r7e")
        let name: [CChar] = ([0x78, 0xFF, 0x79, 0x00] as [UInt8]).map { CChar(bitPattern: $0) }
        let dfd = open(dir.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(dfd, 0)
        let fd = openat(dfd, name, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        let made = fd >= 0
        if made { XCTAssertEqual(write(fd, "ok!", 3), 3); close(fd) }
        close(dfd)
        let link = dir.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink(name, link.path), 0)
        switch TextViewerDocument.load(link) {
        case .success(let d): XCTAssertTrue(made); XCTAssertEqual(d.text, "ok!"); XCTAssertNil(d.identity)
        case .failure(let r): XCTAssertFalse(made); XCTAssertEqual(r, .missing)
        }
    }
}
