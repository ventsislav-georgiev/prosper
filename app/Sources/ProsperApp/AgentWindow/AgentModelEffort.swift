import Foundation

/// #1198 (P1a of #1192): the model and effort of a session's last answer, read from the tail of
/// its transcript. The file is outside data: the read is bounded (64 KiB steps, 1 MiB in all),
/// every offset is derived from the stat'd size, and a line that is too long, does not parse,
/// holds a NUL or is not UTF-8 reads as nothing. No model id is spelled here.
struct AgentModelEffort: Equatable, Sendable {
    let model: String
    /// One of `levels`, or nil.
    let effort: String?

    static let window: UInt64 = 1 << 20
    static let step: UInt64 = 1 << 16
    static let levels: Set<String> = ["low", "medium", "high", "xhigh", "max"]
    static let maxModelLength = 128

    /// The two outside reads, as a seam so rows count them. Runs on whatever queue the list runs on.
    struct IO: Sendable {
        /// Size of the file, nil when it cannot be stat'd. One call per row per list tick at most.
        var size: @Sendable (_ path: String) -> UInt64?
        /// `length` bytes at `offset`, nil on any failure.
        var read: @Sendable (_ path: String, _ offset: UInt64, _ length: Int) -> Data?

        static let live = IO(
            size: { path in
                var st = stat()
                guard stat(path, &st) == 0, st.st_size >= 0 else { return nil }
                return UInt64(st.st_size)
            },
            read: { path, offset, length in
                guard length > 0, let h = FileHandle(forReadingAtPath: path) else { return nil }
                defer { try? h.close() }
                do {
                    try h.seek(toOffset: offset)
                    return try h.read(upToCount: length)
                } catch { return nil }
            })
    }

    // MARK: - Reader

    /// The newest main-thread assistant line with a string model in the last `window` bytes of a
    /// file of `size` bytes; `read(offset, length)` returns those bytes.
    static func read(size: UInt64, read: (_ offset: UInt64, _ length: Int) -> Data?) -> AgentModelEffort? {
        guard size > 0 else { return nil }
        let floor = size > window ? size - window : 0
        var end = size
        var carry = Data()   // the bytes after the first newline of what is read so far
        while end > floor {
            // end > floor here, so the difference is positive and at most `window`.
            let start = end - floor > step ? end - step : floor
            let length = Int(end - start)   // <= step
            guard let chunk = read(start, length), chunk.count == length else { return nil }
            var lines = (chunk + carry).split(separator: 0x0A, maxSplits: Int.max, omittingEmptySubsequences: false)
            guard let first = lines.first else { return nil }
            lines.removeFirst()
            for line in lines.reversed() {
                if let found = parse(Data(line)) { return found }
            }
            // The first piece is a whole line only when the read reached the file start; at the
            // bound it was cut (a line longer than the window reads as nothing).
            if start == 0 { return parse(Data(first)) }
            carry = Data(first)
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
        guard let model = TranscriptKeys.str(TranscriptKeys.obj(o, "message"), "model"),
              !model.isEmpty, model.utf8.count <= maxModelLength,
              !model.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
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
    /// read last, read again for a new row, a new path, a file that shrank, or a row whose state left
    /// working (a growing file under a working row is not read: the answer is not over). The
    /// read size is kept even when nothing was found, so an empty result is cached too.
    static func resolve(_ row: AgentSession, previous: AgentSession?, io: IO) -> AgentSession {
        guard let path = row.transcriptPath, !path.isEmpty, let size = io.size(path) else { return row }
        var s = row
        if let p = previous, p.transcriptPath == path, let seen = p.modelReadSize {
            let leftWorking = p.state == .working && row.state != .working
            if seen == size || (size > seen && !leftWorking) {
                s.model = p.model; s.effort = p.effort; s.modelReadSize = seen
                return s
            }
        }
        let found = read(size: size) { io.read(path, $0, $1) }
        s.model = found?.model; s.effort = found?.effort; s.modelReadSize = size
        return s
    }
}
