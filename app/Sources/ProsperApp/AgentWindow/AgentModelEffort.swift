import Foundation

/// #1198 (P1a of #1192): the model and effort of a session's last answer, read from the tail of
/// its transcript. The file is outside data: the read is bounded (64 KiB steps, `budget` in all),
/// every offset is derived from the stat'd size, and a line that is too long (stepped over, #1372),
/// does not parse, holds a NUL or is not UTF-8 reads as nothing. No model id is spelled here.
struct AgentModelEffort: Equatable, Sendable {
    let model: String
    /// One of `levels`, or nil.
    let effort: String?

    /// #1372: bytes read per pass at most, back from the end; a line longer than `maxLine` is stepped over (its
    /// bytes are dropped, not kept) and the scan goes on before it.
    static let budget: UInt64 = 16 << 20
    static let maxLine = 1 << 20
    static let step: UInt64 = 1 << 16
    static let levels: Set<String> = ["low", "medium", "high", "xhigh", "max"]
    static let maxModelLength = 128
    private static let allowedModelScalars: Set<UInt32> = Set(
        Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:@/-".unicodeScalars).map { $0.value })

    /// The two outside reads, as a seam so rows count them. Runs on whatever queue the list runs on.
    struct IO: Sendable {
        /// Size of the file, nil when it cannot be stat'd. One call per row per list tick at most.
        var size: @Sendable (_ path: String) -> UInt64?
        /// `length` bytes at `offset`, nil on any failure.
        var read: @Sendable (_ path: String, _ offset: UInt64, _ length: Int) -> Data?

        static let live = IO(
            size: { path in
                var st = stat()
                // Only a regular file: a folder, FIFO, device or socket is never read (#1209).
                guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0 else { return nil }
                return UInt64(st.st_size)
            },
            read: { path, offset, length in
                // Non-blocking open, then the type is checked on the opened descriptor: whatever sits at
                // the path now, only a regular file is read, and the open never waits on a writer (#1216).
                guard length > 0 else { return nil }
                let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { return nil }
                var st = stat()
                guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0,
                      offset <= UInt64(st.st_size) else { close(fd); return nil }
                let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                defer { close(fd) }
                do {
                    try h.seek(toOffset: offset)
                    return try h.read(upToCount: length)
                } catch { return nil }
            })
    }

    // MARK: - Reader

    /// The newest main-thread assistant line with a string model in the last `budget` bytes of a
    /// file of `size` bytes; `read(offset, length)` returns those bytes. Held at once: one step plus at most
    /// `maxLine` bytes of a line not yet whole.
    static func read(size: UInt64, read: (_ offset: UInt64, _ length: Int) -> Data?) -> AgentModelEffort? {
        guard size > 0 else { return nil }
        let floor = size > budget ? size - budget : 0
        var end = size
        var carry = Data()   // the bytes after the first newline of what is read so far, at most maxLine
        var skipping = false   // #1372: inside a line longer than maxLine, whose bytes are dropped up to its newline
        while end > floor {
            // end > floor here, so the difference is positive and at most `budget`.
            let start = end - floor > step ? end - step : floor
            let length = Int(end - start)   // <= step
            guard let chunk = read(start, length), chunk.count == length else { return nil }
            let buffer: Data
            if skipping {
                // Still inside the long line: nothing of it is kept; the bytes before its start are lines again.
                guard let newline = chunk.lastIndex(of: 0x0A) else { end = start; continue }
                buffer = chunk.prefix(upTo: newline)
                skipping = false
            } else {
                buffer = chunk + carry
            }
            var lines = buffer.split(separator: 0x0A, maxSplits: Int.max, omittingEmptySubsequences: false)
            guard let first = lines.first else { return nil }
            lines.removeFirst()
            for line in lines.reversed() {
                if let found = parse(Data(line)) { return found }
            }
            // The first piece is a whole line only when the read reached the file start; at the
            // bound it was cut (a line longer than the budget reads as nothing).
            if start == 0 { return parse(Data(first)) }
            carry = Data(first)
            if carry.count > maxLine { carry = Data(); skipping = true }
            end = start
        }
        return nil
    }

    static func parse(_ line: Data) -> AgentModelEffort? {
        guard !line.isEmpty, !line.contains(0), String(data: line, encoding: .utf8) != nil,
              let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              TranscriptKeys.str(o, "type") == "assistant" else { return nil }
        if let side = TranscriptKeys.get(o, "isSidechain") {
            guard let n = side as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), !n.boolValue else { return nil }
        }
        // The id reaches row text, so only ASCII letters, digits and . _ : @ / - are kept (checked per
        // scalar); any other id reads as no model, never as a cleaned or cut one (#1216).
        guard let model = TranscriptKeys.str(TranscriptKeys.obj(o, "message"), "model"),
              !model.isEmpty, model.utf8.count <= maxModelLength,
              model.unicodeScalars.allSatisfy({ allowedModelScalars.contains($0.value) }) else { return nil }
        let effort = TranscriptKeys.str(o, "effort").flatMap { levels.contains($0) ? $0 : nil }
        return AgentModelEffort(model: model, effort: effort)
    }

    // MARK: - Short name

    /// `claude-<family>-<major>[-<minor>][-<8-digit date>]` -> "Family major[.minor]"; anything
    /// else is returned as given (the view cuts it later).
    static func shortName(_ id: String) -> String {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func digits(_ s: String, _ n: ClosedRange<Int>) -> Bool {
            n.contains(s.utf8.count) && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
        }
        guard parts.count >= 3, parts[0] == "claude",
              !parts[1].isEmpty, parts[1].utf8.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return id }
        var rest = Array(parts.dropFirst(2))
        if let last = rest.last, digits(last, 8...8) { rest.removeLast() }
        guard (1...2).contains(rest.count), rest.allSatisfy({ digits($0, 1...3) }) else { return id }
        return parts[1].prefix(1).uppercased() + parts[1].dropFirst() + " " + rest.joined(separator: ".")
    }

    // MARK: - List path

    /// `row` with its model and effort: carried from `previous` while the transcript size is the one
    /// read last, read again for a new row, a new path, a file that shrank, or a file that grew under a
    /// row that is not working now (a growing file under a working row is not read: the answer is not
    /// over; an answer seen only as idle before and after is read, #1209). The
    /// read size is kept even when nothing was found, so an empty result is cached too. #1372: a read that finds
    /// nothing keeps the model already known for the same Claude session id; another id is never carried.
    static func resolve(_ row: AgentSession, previous: AgentSession?, io: IO) -> AgentSession {
        guard let path = row.transcriptPath, !path.isEmpty, let size = io.size(path) else { return row }
        var s = row
        if let p = previous, p.transcriptPath == path, let seen = p.modelReadSize {
            // #1267: a nil cached under a working row is read again (once per list answer while nil), so a read
            // before the first answer of a stretch does not hide the model until the row stops working.
            if seen == size || (size > seen && row.state == .working && p.model != nil) {
                s.model = p.model; s.effort = p.effort; s.modelReadSize = seen
                return s
            }
        }
        let found = read(size: size) { io.read(path, $0, $1) }
        s.model = found?.model; s.effort = found?.effort; s.modelReadSize = size
        if found == nil, let p = previous, p.model != nil, let sid = row.claudeSessionID, p.claudeSessionID == sid {
            s.model = p.model; s.effort = p.effort
        }
        return s
    }

    /// #1267: list answers in a row with no transcript mapping that keep the label (dch answers null whenever unsure).
    static let carryAnswers = 3

    /// #1267: `row` (already resolved) with no mapping in this answer keeps `previous`'s model, effort and slot (same
    /// key) for at most `carryAnswers` answers in a row, then drops as before. Display only: the path and the Claude
    /// id stay nil (the pane, auto-allow and the phone keep today's rule), and modelReadSize too, so a mapping that
    /// returns is read afresh.
    static func carry(_ row: AgentSession, previous: AgentSession?) -> AgentSession {
        guard row.transcriptPath == nil, let p = previous, p.key == row.key,
              p.transcriptPath != nil || p.modelCarried > 0, p.modelCarried < carryAnswers else { return row }
        var s = row
        s.model = p.model; s.effort = p.effort; s.modelCarried = p.modelCarried + 1
        return s
    }
}
