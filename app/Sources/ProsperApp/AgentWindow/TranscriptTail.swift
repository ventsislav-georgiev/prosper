import Foundation

// #786 rule 9 (bounded cost): read a transcript incrementally from the last offset,
// never re-parse the file; start from the last page of a long one; re-open on an
// inode change or a shrink (rule 6). Read-only: files are opened for reading only.

/// Splits bytes into JSONL lines, buffering a partial trailing line until its
/// newline (rule 1). A line longer than `maxLine` is dropped as it streams in and
/// comes out as one `.oversized` marker, so a pasted image cannot balloon memory.
struct LineBuffer {
    enum Line: Equatable {
        case line(Data, Range<UInt64>)
        case oversized(Range<UInt64>)
    }

    var maxLine = 16 << 20
    private var pending = Data()
    private var start: UInt64 = 0
    private var skipping = false
    /// Mid-line start (paging): drop bytes up to the first newline silently.
    private var discarding = false
    /// File offset where the first whole line began; nil until known.
    private(set) var firstLineStart: UInt64?

    init(at offset: UInt64 = 0, discardFirst: Bool = false, maxLine: Int = 16 << 20) {
        self.maxLine = maxLine
        start = offset
        discarding = discardFirst
        firstLineStart = discardFirst ? nil : offset
    }

    mutating func feed(_ d: Data, at offset: UInt64) -> [Line] {
        var out: [Line] = []
        var i = d.startIndex
        var pos = offset
        while i < d.endIndex {
            guard let nl = d[i...].firstIndex(of: 0x0A) else {
                if !discarding && !skipping {
                    pending.append(d[i...])
                    if pending.count > maxLine { pending = Data(); skipping = true }
                }
                pos += UInt64(d.endIndex - i)
                break
            }
            let end = pos + UInt64(nl - i)
            if discarding {
                discarding = false
                firstLineStart = end + 1
            } else if skipping {
                out.append(.oversized(start..<end))
                skipping = false
            } else {
                pending.append(d[i..<nl])
                if pending.count > maxLine {
                    out.append(.oversized(start..<end))
                } else if pending.contains(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0D) }) {
                    out.append(.line(pending, start..<end))
                }
            }
            pending = Data()
            pos = end + 1
            start = pos
            i = d.index(after: nl)
        }
        return out
    }
}

/// One transcript file followed from an offset. Value type; the model owns it.
struct TranscriptTail {
    enum Poll: Equatable {
        case missing
        /// The file was replaced (inode) or shrank: the caller starts over.
        case reopened
        case lines([LineBuffer.Line], more: Bool)
    }

    let path: String
    /// A long file opens on its last `pageBytes`; earlier pages load on demand.
    var pageBytes: UInt64 = 1 << 20
    /// Bytes read per poll, so one poll never stalls the main thread on a huge append.
    var chunkBytes = 4 << 20
    var maxLine = 16 << 20
    private(set) var offset: UInt64 = 0
    private(set) var inode: UInt64?
    private var buffer = LineBuffer()
    /// The first byte of the earliest line decoded so far; 0 = the whole file is in.
    var earliest: UInt64 { buffer.firstLineStart ?? offset }
    private var pagedEarliest: UInt64?

    init(path: String, pageBytes: UInt64 = 1 << 20) {
        self.path = path
        self.pageBytes = pageBytes
    }

    var earliestLoaded: UInt64 { pagedEarliest ?? earliest }

    mutating func poll() -> Poll {
        var st = stat()
        guard stat(path, &st) == 0 else { return .missing }
        let ino = UInt64(st.st_ino), size = UInt64(max(0, st.st_size))
        if let inode {
            if ino != inode || size < offset { return .reopened }
        } else {
            inode = ino
            let from = size > pageBytes ? size - pageBytes : 0
            offset = from
            buffer = LineBuffer(at: from, discardFirst: from > 0, maxLine: maxLine)
        }
        guard size > offset else { return .lines([], more: false) }
        let n = Int(min(size - offset, UInt64(chunkBytes)))
        guard let data = read(offset..<(offset + UInt64(n))), !data.isEmpty else { return .lines([], more: false) }
        let lines = buffer.feed(data, at: offset)
        offset += UInt64(data.count)
        return .lines(lines, more: offset < size)
    }

    /// The page before everything loaded so far: complete lines only.
    mutating func previousPage() -> [LineBuffer.Line] {
        let end = earliestLoaded
        guard end > 0 else { return [] }
        var span = pageBytes
        while true {
            let lo = end > span ? end - span : 0
            guard let data = read(lo..<end) else { return [] }
            var b = LineBuffer(at: lo, discardFirst: lo > 0, maxLine: maxLine)
            let lines = b.feed(data, at: lo)
            if let first = b.firstLineStart {
                pagedEarliest = first
                return lines
            }
            // No newline in the span: one line longer than a page.
            if span >= UInt64(maxLine) {
                pagedEarliest = lo
                return [.oversized(lo..<end)]
            }
            span *= 2
        }
    }

    /// Bytes at `range`, read-only; nil when the file cannot be read.
    func read(_ range: Range<UInt64>) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        do {
            try h.seek(toOffset: range.lowerBound)
            return try h.read(upToCount: Int(range.upperBound - range.lowerBound)) ?? Data()
        } catch { return nil }
    }
}

/// A kqueue (DispatchSource) watch on one file; fires on the main queue. Cancelled
/// on deinit, so dropping it stops all work (nothing runs while the view is closed).
final class TranscriptWatch {
    private let source: DispatchSourceFileSystemObject

    init?(path: String, onChange: @escaping @MainActor () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
