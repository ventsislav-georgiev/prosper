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

    func testInvalidUTF8IsShownReadOnly() throws {
        let d = try doc(try file("latin1.txt", [0x63, 0x61, 0x66, 0xE9, 0x0A], in: tempDir("tv-doc")))
        XCTAssertEqual(d.encoding, .lossy)
        XCTAssertTrue(d.readOnly)
        XCTAssertEqual(d.text, "caf\u{FFFD}\n")
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
}
