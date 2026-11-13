import Darwin
import Foundation

// #1106 (design #1105 D1): load, decode and detect one text file. A document is untrusted input:
// the limits are checked on the opened descriptor before the bytes are read whole, a FIFO or a
// directory is refused without a blocking open, and nothing is written.

struct TextViewerDocument: Equatable {
    enum Encoding: Equatable { case utf8, utf8BOM, utf16LE, utf16BE, lossy }
    enum LineEnding: Equatable { case none, lf, crlf, cr, mixed }
    enum Refusal: Error, Equatable {
        case missing, unreadable, notRegular, tooLarge, binary

        var message: String {
            switch self {
            case .missing: "This file is not there any more."
            case .unreadable: "Prosper cannot read this file."
            case .notRegular: "This is not a regular file (a folder, a pipe or a device)."
            case .tooLarge: "This file is over 16 MiB."
            case .binary: "This file looks binary (it holds a NUL byte)."
            }
        }
    }

    static let maxBytes = 16 << 20
    /// D1: a NUL in this many leading bytes (code units for UTF-16) means binary.
    static let sniffBytes = 8 << 10

    let text: String
    let encoding: Encoding
    let lineEnding: LineEnding
    /// Invalid UTF-8, shown through a lossy decode: read-only (D1).
    var readOnly: Bool { encoding == .lossy }

    /// Reads `url` (following a symlink to its target). Never blocks on a FIFO: O_NONBLOCK on the
    /// open, then the type and size from fstat on that same descriptor, before any read.
    static func load(_ url: URL) -> Result<TextViewerDocument, Refusal> {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(.unreadable) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegular) }
        guard st.st_size >= 0, st.st_size <= Int64(maxBytes) else { return .failure(.tooLarge) }
        guard let data = readAll(fd, size: Int(st.st_size)) else { return .failure(.unreadable) }
        return decode(data)
    }

    /// At most `size` bytes (the fstat size, already checked to be in 0...maxBytes): a file that grows
    /// while it is read (a log) is cut at the size it had, never read past the limit.
    private static func readAll(_ fd: Int32, size: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: size)
        var total = 0
        while total < size {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + total, size - total) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }   // shrank since the fstat
            total += n
        }
        return Data(buf[0..<total])
    }

    /// Pure: bytes to a document or the binary refusal.
    static func decode(_ data: Data) -> Result<TextViewerDocument, Refusal> {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let little = bytes[0] == 0xFF
            let body = Array(bytes.dropFirst(2))
            let units = stride(from: 0, to: body.count - 1, by: 2).map { i in
                little ? UInt16(body[i]) | UInt16(body[i + 1]) << 8 : UInt16(body[i]) << 8 | UInt16(body[i + 1])
            }
            // The NUL rule on code units: a UTF-16 file has a zero byte in every ASCII character.
            if units.prefix(sniffBytes / 2).contains(0) { return .failure(.binary) }
            let valid = body.count % 2 == 0
                && String(data: Data(body), encoding: little ? .utf16LittleEndian : .utf16BigEndian) != nil
            return .success(make(String(decoding: units, as: UTF16.self), valid ? (little ? .utf16LE : .utf16BE) : .lossy))
        }
        if bytes.prefix(sniffBytes).contains(0) { return .failure(.binary) }
        let bom = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let body = bom ? Array(bytes.dropFirst(3)) : bytes
        if let s = String(data: Data(body), encoding: .utf8) { return .success(make(s, bom ? .utf8BOM : .utf8)) }
        return .success(make(String(decoding: body, as: UTF8.self), .lossy))
    }

    private static func make(_ text: String, _ encoding: Encoding) -> TextViewerDocument {
        TextViewerDocument(text: text, encoding: encoding, lineEnding: lineEnding(of: text))
    }

    /// LF, CRLF, CR, mixed, or none; read on the decoded text.
    static func lineEnding(of text: String) -> LineEnding {
        var lf = false, crlf = false, cr = false
        var prevCR = false
        for b in text.utf8 {
            if b == 0x0A { if prevCR { crlf = true } else { lf = true } }
            else if prevCR { cr = true }
            prevCR = b == 0x0D
        }
        if prevCR { cr = true }
        switch (lf, crlf, cr) {
        case (false, false, false): return .none
        case (true, false, false): return .lf
        case (false, true, false): return .crlf
        case (false, false, true): return .cr
        default: return .mixed
        }
    }
}
