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

        var range: Range<UInt64> {
            switch self { case .line(_, let r), .oversized(let r): r }
        }
    }

    var maxLine = 16 << 20
    private var pending = Data()
    private var start: UInt64 = 0
    private var skipping = false

    /// `offset` must be a line start: callers find one first (TranscriptTail.pageStart).
    init(at offset: UInt64 = 0, maxLine: Int = 16 << 20) {
        self.maxLine = maxLine
        start = offset
    }

    mutating func feed(_ d: Data, at offset: UInt64) -> [Line] {
        var out: [Line] = []
        var i = d.startIndex
        var pos = offset
        while i < d.endIndex {
            guard let nl = d[i...].firstIndex(of: 0x0A) else {
                if !skipping {
                    pending.append(d[i...])
                    if pending.count > maxLine { pending = Data(); skipping = true }
                }
                pos += UInt64(d.endIndex - i)
                break
            }
            let end = pos + UInt64(nl - i)
            if skipping {
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
    /// The line start the live tail opened at; 0 = the whole file is in.
    private(set) var earliest: UInt64 = 0
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
            // Open on the last page, from a line start, with at least the last whole line in it
            // (a line longer than the page is taken whole). `last` = where the trailing partial
            // line starts, or `size` when the file ends with a newline.
            var from: UInt64 = 0
            if size > pageBytes, let last = lineStart(before: size), last > 0 { from = pageStart(end: last) ?? 0 }
            offset = from
            earliest = from
            buffer = LineBuffer(at: from, maxLine: maxLine)
        }
        guard size > offset else { return .lines([], more: false) }
        let n = Int(min(size - offset, UInt64(chunkBytes)))
        guard let data = read(offset..<(offset + UInt64(n))), !data.isEmpty else { return .lines([], more: false) }
        let lines = buffer.feed(data, at: offset)
        offset += UInt64(data.count)
        return .lines(lines, more: offset < size)
    }

    /// The page before everything loaded so far: whole lines only, at least one
    /// (a line longer than a page comes whole, or as `.oversized` past `maxLine`).
    mutating func previousPage() -> [LineBuffer.Line] {
        var end = earliestLoaded
        // #797: a line longer than lineStart's bound was shown as `.oversized` from the
        // bound's floor, inside the line. Skip back over the rest of it (a few bounded
        // scans per call) so it never shows twice.
        var scans = 0
        while end > 0, read((end - 1)..<end) != Data([0x0A]) {
            guard scans < 4, let s = lineStart(before: end) else { pagedEarliest = end; return [] }
            end = s
            scans += 1
        }
        if end != earliestLoaded { pagedEarliest = end }
        guard end > 0, let lo = pageStart(end: end) else { return [] }
        var b = LineBuffer(at: lo, maxLine: maxLine)
        var out: [LineBuffer.Line] = []
        var at = lo
        while at < end {
            guard let d = read(at..<min(end, at + UInt64(chunkBytes))), !d.isEmpty else { return [] }
            out += b.feed(d, at: at)
            at += UInt64(d.count)
        }
        pagedEarliest = lo
        return out
    }

    /// The first line start at or after `end - pageBytes` and before `end`, where `end`
    /// is a line start: [result, end) then holds at least one whole line. When the
    /// line before `end` is longer than a page, its own start.
    func pageStart(end: UInt64) -> UInt64? {
        guard end > pageBytes else { return 0 }
        let lo = end - pageBytes
        // From lo - 1: a line starting exactly at lo (its newline at lo - 1) belongs to this page.
        guard let d = read((lo - 1)..<(end - 1)) else { return nil }
        if let nl = d.firstIndex(of: 0x0A) { return lo + UInt64(nl - d.startIndex) }
        return lineStart(before: lo)
    }

    /// The start of the line holding byte `pos - 1` (`pos` itself when that byte is a newline).
    /// #797: the scan goes back at most `maxLine + pageBytes` bytes (64 KiB reads). A line
    /// longer than that is oversized whatever its start, so the scan's floor stands in for
    /// it: reading on from there, LineBuffer passes more than `maxLine` bytes before the
    /// newline and yields one `.oversized` marker.
    func lineStart(before pos: UInt64) -> UInt64? {
        let (cap, over) = UInt64(maxLine).addingReportingOverflow(pageBytes)
        let floor = !over && pos > cap ? pos - cap : 0
        var hi = pos
        while hi > floor {
            let lo = max(floor, hi > 1 << 16 ? hi - (1 << 16) : 0)
            guard let d = read(lo..<hi) else { return nil }
            if let nl = d.lastIndex(of: 0x0A) { return lo + UInt64(nl - d.startIndex) + 1 }
            hi = lo
        }
        return floor
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
