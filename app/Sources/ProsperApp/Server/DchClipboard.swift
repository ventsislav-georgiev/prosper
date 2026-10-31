import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Phone clipboard history sync (#617)

/// Clipboard history both ways: list, pull (streamed), push small text, put text live.
/// The upload is DchClipboardUpload. Gated: history on AND "Sync clipboard history with
/// iPhone" on, else every request is refused and machineInfo advertises no "clipboard".
/// Off the server queue; every request gets exactly one final reply, and a stream's
/// clipboardItemResp and data frames come before it. Concealed and transient clips never
/// reach the store (ClipboardMonitor), so nothing here can serve one.
struct DchClipboardOps: Sendable {
    var enabled: @Sendable () -> Bool = { Preferences.clipboardSyncActive }
    var store: @Sendable @MainActor () -> ClipboardStore = { ClipboardStore.shared }
    /// The received-files folder, ~/Downloads as AirDrop; none under XCTest, so an
    /// unstubbed test writes no file there.
    var receivedDir: @Sendable () -> URL? = {
        NSClassFromString("XCTestCase") == nil
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first : nil
    }
    /// Free bytes on `dir`'s volume; nil = unknown (allowed).
    var freeSpace: @Sendable (_ dir: URL) -> Int64? = {
        (try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
    /// The largest text or image held in memory, then sealed into the store: the Mac's own
    /// capture limits (an image's PNG of maxImagePixels RGBA at most). Anything larger is a file.
    var memoryMax: @Sendable (_ image: Bool) -> Int = { $0 ? ClipboardMonitor.maxImagePixels * 4 : ClipboardMonitor.maxTextBytes }
    var maxPixels = ClipboardMonitor.maxImagePixels

    typealias Reply = DchControlOps.Reply
    /// A stream's non-final frame; false once the connection is gone.
    typealias Send = @Sendable (Data) -> Bool

    static let chunk = 1 << 20
    static let maxItems = 100
    static let listTextChars = 2000
    static let listBlobMax = 1 << 20
    static let smallText = 64 << 10
    /// ponytail: a fixed 5 GB floor on the target volume, not a ratio of the disk; a
    /// setting if a small disk needs less.
    static let minFreeAfter: Int64 = 5 << 30
    static let offMessage = "clipboard sync is off"

    static func error(_ m: String) -> Data { DchControlOps.error(m) }

    /// clipboardList, clipboardItem, addClipboardHistory. `send` carries a stream's frames.
    func handle(_ type: UInt8, _ payload: Data, send: @escaping Send, reply: Reply) {
        guard enabled() else { return reply(Self.error(Self.offMessage)) }
        let o = payload.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard let o else { return reply(Self.error("malformed request: not a JSON object")) }
        switch type {
        case DchFrame.clipboardList: list(o, reply)
        case DchFrame.clipboardItem: item(o, send, reply)
        case DchFrame.addClipboardHistory: addHistory(o, reply)
        default: reply(Self.error("unknown request"))
        }
    }

    /// putClipboardText {text}: the live pasteboard, as "send to Mac now". On the server
    /// queue, as putClipboard: the phone's ctrl-V can be the very next frame.
    func putText(_ payload: Data) -> Data {
        guard enabled() else { return Self.error(Self.offMessage) }
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any], o.count == 1,
              let text = o["text"] as? String else {
            return Self.error("malformed putClipboardText request: send {\"text\": \"…\"}")
        }
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return DchFrame.encode(DchFrame.ok, [])
    }

    // MARK: Main-actor hops

    /// The store's state, read or changed on main. Callers are off main (the server's
    /// global threads, an upload's queue); never the server queue, which main may wait on.
    func onMain<T: Sendable>(_ body: @MainActor (ClipboardStore) -> T) -> T {
        let store = store
        if Thread.isMainThread { return MainActor.assumeIsolated { body(store()) } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body(store()) } }
    }

    // MARK: clipboardList 0x15 → clipboardResp 0x1d

    private func list(_ o: [String: Any], _ reply: Reply) {
        let bad = Self.error("malformed clipboardList request: send {\"limit\"?: 1-100, \"before\"?: id, \"since\"?: ISO8601}")
        var limit = Self.maxItems
        if let v = o["limit"] {
            guard let n = Self.int(v) else { return reply(bad) }
            limit = min(max(n, 1), Self.maxItems)
        }
        var before: UUID?, since: Date?
        if let v = o["before"] {
            guard let id = (v as? String).flatMap(UUID.init(uuidString:)) else { return reply(bad) }
            before = id
        }
        if let v = o["since"] {
            guard let d = (v as? String).flatMap(Self.date) else { return reply(bad) }
            since = d
        }
        let (all, store) = onMain { s in (s.items, s) }
        var rows = all.sorted { $0.createdAt > $1.createdAt }   // newest first, pinned or not
        if let since { rows = rows.filter { Self.ms($0.createdAt) > Self.ms(since) } }
        if let before {
            guard let i = rows.firstIndex(where: { $0.id == before }) else { return reply(Self.error("before: no such item")) }
            rows = Array(rows[(i + 1)...])
        }
        var wire = rows.prefix(limit).map { Self.listWire($0, store) }
        // A short page past the phone's 8 MB frame; it pages on with `before`.
        while true {
            let data = (try? JSONSerialization.data(withJSONObject: wire, options: [.withoutEscapingSlashes])) ?? Data()
            if data.count <= DchFrame.maxFrame || wire.count <= 1 {
                return reply(data.count <= DchFrame.maxFrame ? DchFrame.encode(DchFrame.clipboardResp, [UInt8](data))
                                                             : Self.error("clipboard item too large for one frame"))
            }
            wire.removeLast(wire.count / 2)
        }
    }

    /// ponytail: thumbs cached by id for the process's life, at most 1000; NSCache
    /// evicts under memory pressure too. Persist them if regenerating ever shows up.
    nonisolated(unsafe) static let thumbs: NSCache<NSUUID, NSString> = {
        let c = NSCache<NSUUID, NSString>()
        c.countLimit = 1000
        return c
    }()

    static func listWire(_ it: ClipboardItem, _ store: ClipboardStore) -> [String: Any] {
        var o: [String: Any] = ["id": it.id.uuidString, "date": wireDate(it.createdAt), "kind": wireKind(it.kind),
                                "source": it.wireSource, "size": it.byteCount]
        if it.kind.isTextual {
            // ponytail: past 1 MB the row carries the stored preview, not the blob's first 2000
            // chars (a list would decrypt up to 100 x 100 MB); the phone pulls the full text with 0x16.
            let blob = it.byteCount <= Self.listBlobMax ? it.blobFile.flatMap(store.readBlob) : nil
            let full = blob.map { String(decoding: $0, as: UTF8.self) } ?? it.preview
            o["text"] = String(full.prefix(listTextChars))
        } else if it.kind == .image, let blob = it.blobFile {
            if let t = thumbs.object(forKey: it.id as NSUUID) {
                o["thumb"] = t as String
            } else if let t = store.readBlob(blob).flatMap(thumb) {
                thumbs.setObject(t as NSString, forKey: it.id as NSUUID)
                o["thumb"] = t
            }
        } else if it.kind == .file, let name = it.fileName {
            o["name"] = name
        }
        return o
    }

    /// A base64 JPEG at most 256 px on its long side.
    static func thumb(_ data: Data) -> String? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return (out as Data).base64EncodedString()
    }

    // MARK: clipboardItem 0x16 → clipboardItemResp 0x1a, data frames, ok

    private func item(_ o: [String: Any], _ send: Send, _ reply: Reply) {
        guard let id = (o["id"] as? String).flatMap(UUID.init(uuidString:)), o.count <= 2,
              o.count == 1 || o["offset"] != nil else {
            return reply(Self.error("malformed clipboardItem request: send {\"id\": \"…\", \"offset\"?: n}"))
        }
        var offset = 0
        if let v = o["offset"] {
            guard let n = Self.int(v) else { return reply(Self.error("bad offset")) }
            offset = n
        }
        let (found, store) = onMain { s in (s.item(id), s) }
        guard let it = found else { return reply(Self.error("gone")) }
        if it.kind == .file {
            guard let path = it.sourcePath else { return reply(Self.error("gone")) }
            return streamFile(it, path: path, offset: offset, send, reply)
        }
        guard let blob = it.blobFile else { return reply(Self.error("not stored")) }
        guard let data = store.readBlob(blob) else { return reply(Self.error("gone")) }
        guard offset <= data.count else { return reply(Self.error("bad offset")) }
        guard send(Self.itemHeader(it, size: data.count, sha256: ClipboardStore.sha256(data), mime: Self.mime(it, data))) else {
            return reply(Self.error("gone"))
        }
        var at = offset
        while at < data.count {
            let end = min(at + Self.chunk, data.count)
            guard send(DchFrame.encode(DchFrame.data, [UInt8](data[at..<end]))) else { return reply(Self.error("gone")) }
            at = end
        }
        reply(DchFrame.encode(DchFrame.ok, []))
    }

    /// A file entry's source file: opened O_NONBLOCK and only as a regular file (#608,
    /// #627), hashed in a first pass, then sent from `offset`. A file that changes
    /// between the passes ends in error "changed".
    private func streamFile(_ it: ClipboardItem, path: String, offset: Int, _ send: Send, _ reply: Reply) {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return reply(Self.error(errno == ENOENT ? "gone" : "unreadable")) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return reply(Self.error("not a regular file")) }
        let size = Int(st.st_size)
        var hasher = SHA256(), n = 0
        while let d = try? h.read(upToCount: Self.chunk), !d.isEmpty {
            hasher.update(data: d)
            n += d.count
        }
        guard n == size else { return reply(Self.error("changed")) }
        guard offset <= size else { return reply(Self.error("bad offset")) }
        guard send(Self.itemHeader(it, size: size, sha256: Self.hex(hasher.finalize()), mime: Self.mime(it, nil))) else {
            return reply(Self.error("gone"))
        }
        guard (try? h.seek(toOffset: UInt64(offset))) != nil else { return reply(Self.error("unreadable")) }
        var at = offset
        while at < size {
            guard let d = try? h.read(upToCount: min(Self.chunk, size - at)), !d.isEmpty else { return reply(Self.error("changed")) }
            guard send(DchFrame.encode(DchFrame.data, [UInt8](d))) else { return reply(Self.error("gone")) }
            at += d.count
        }
        reply(DchFrame.encode(DchFrame.ok, []))
    }

    static func itemHeader(_ it: ClipboardItem, size: Int, sha256: String, mime: String?) -> Data {
        var o: [String: Any] = ["id": it.id.uuidString, "date": wireDate(it.createdAt), "kind": wireKind(it.kind),
                                "source": it.wireSource, "size": size, "sha256": sha256]
        if let n = it.fileName { o["name"] = n }
        if let mime { o["mime"] = mime }
        return DchFrame.encode(DchFrame.clipboardItemResp, json: o)
    }

    static func mime(_ it: ClipboardItem, _ data: Data?) -> String? {
        switch it.kind {
        case .file: return it.fileName.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension)?.preferredMIMEType }
        case .image:
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let t = CGImageSourceGetType(src) else { return nil }
            return UTType(t as String)?.preferredMIMEType
        default: return "text/plain; charset=utf-8"
        }
    }

    // MARK: addClipboardHistory 0x22 → ok {added, skipped}

    /// Small text only (<= 64 KB per item, <= 100 items) into HISTORY at each item's date;
    /// never the live pasteboard. Larger text and every image: skipped "use_upload". An item
    /// older than every entry a full history keeps is evicted at once: skipped "too_old".
    private func addHistory(_ o: [String: Any], _ reply: Reply) {
        guard o.count == 1, let arr = o["items"] as? [Any] else {
            return reply(Self.error("malformed addClipboardHistory request: send {\"items\": [...]}"))
        }
        guard arr.count <= Self.maxItems else { return reply(Self.error("too many items (max \(Self.maxItems))")) }
        var added: [String] = [], skipped: [[String: String]] = []
        for e in arr {
            let e = e as? [String: Any] ?? [:]
            let idText = e["id"] as? String ?? ""
            func skip(_ why: String) { skipped.append(["id": idText, "reason": why]) }
            guard let id = UUID(uuidString: idText), let kind = e["kind"] as? String else { skip("bad_item"); continue }
            if kind == "image" || kind == "file" { skip("use_upload"); continue }
            guard kind == "text", let text = e["text"] as? String, let date = (e["date"] as? String).flatMap(Self.date),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { skip("bad_item"); continue }
            guard text.utf8.count <= Self.smallText else { skip("use_upload"); continue }
            let sha = ClipboardStore.sha256(Data(text.utf8))
            let why = onMain { s -> String? in
                if s.item(id) != nil || s.receiving[id] != nil || s.dedupe(sha256: sha, date: date) { return "duplicate" }
                guard s.addRemote(id: id, date: date, source: "iPhone", sha256: sha, .text(text)) else { return "write_failed" }
                return s.item(id) == nil ? "too_old" : nil   // older than the history's cap keeps
            }
            if let why { skip(why) } else { added.append(idText) }
        }
        reply(DchFrame.encode(DchFrame.ok, json: ["added": added, "skipped": skipped]))
    }

    // MARK: clipboardUpload 0x23's header

    struct Upload: Sendable {
        let id: UUID
        let date: Date
        let kind: ClipboardKind   // .text, .image or .file
        let size: Int
        let sha256: String
        let name: String?
        let mime: String?
        let live: Bool
    }

    static let uploadShape = "malformed clipboardUpload request: send {id, date, kind: text|image|file, source: \"iPhone\", size, sha256, name?, mime?, live?}"

    static func upload(_ payload: Data) -> Upload? {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let id = (o["id"] as? String).flatMap(UUID.init(uuidString:)),
              let date = (o["date"] as? String).flatMap(Self.date),
              let kind = (o["kind"] as? String).flatMap(ClipboardKind.init(rawValue:)), [.text, .image, .file].contains(kind),
              let size = int(o["size"]),
              let sha = (o["sha256"] as? String)?.lowercased(), sha.count == 64, sha.allSatisfy(\.isHexDigit),
              o["source"] == nil || o["source"] as? String == "iPhone",
              o["name"] == nil || o["name"] is String, o["mime"] == nil || o["mime"] is String
        else { return nil }
        var live = false
        if let v = o["live"] {
            guard let b = v as? NSNumber, CFGetTypeID(b) == CFBooleanGetTypeID() else { return nil }
            live = b.boolValue
        }
        return Upload(id: id, date: date, kind: kind, size: size, sha256: sha, name: o["name"] as? String,
                      mime: o["mime"] as? String, live: live)
    }

    /// The received file's name: the phone's, as one plain path component, else
    /// "iPhone Clipboard" with an extension from the mime or the kind.
    static func fileName(_ u: Upload) -> String {
        var n = String((u.name ?? "").map { "/:".contains($0) || $0.isNewline ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while n.hasPrefix(".") { n.removeFirst() }
        n = String(n.prefix(200))
        guard n.isEmpty else { return n }
        let ext = u.mime.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            ?? (u.kind == .text ? "txt" : u.kind == .image ? "png" : nil)
        return ext.map { "iPhone Clipboard.\($0)" } ?? "iPhone Clipboard"
    }

    /// Finder's "name 2.ext" for the n-th try.
    static func candidate(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        return ext.isEmpty || base.isEmpty ? "\(name) \(n)" : "\(base) \(n).\(ext)"
    }

    /// Renames `part` into `dir` under the first free candidate, never over a file.
    static func place(_ part: URL, in dir: URL, as name: String) -> URL? {
        for n in 1...10_000 {
            let dest = dir.appendingPathComponent(candidate(name, n))
            if renamex_np(part.path, dest.path, UInt32(RENAME_EXCL)) == 0 { return dest }
            guard errno == EEXIST else { return nil }
        }
        return nil
    }

    /// The live pasteboard once an upload is complete: text as a string, an image as PNG
    /// (and TIFF), a file as its URL. The monitor then records no second copy.
    @MainActor static func setLive(_ it: ClipboardItem, _ s: ClipboardStore) {
        if it.kind == .image, let data = it.blobFile.flatMap(s.readBlob) {
            DchConnection.setPasteboardImage(data)
        } else {
            s.copyToPasteboard(it)
        }
        ClipboardMonitor.shared.ignoreHistory(changeCount: Pasteboard.general.changeCount)
    }

    // MARK: Wire helpers

    /// A non-negative JSON integer; never a bool.
    static func int(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let i = v as? Int, i >= 0 else { return nil }
        return i
    }

    static func wireKind(_ k: ClipboardKind) -> String { k.isTextual ? "text" : k.rawValue }

    static func wireDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// ISO8601 with or without fractional seconds.
    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Milliseconds, the wire date's precision, so `since` = an item's own date excludes it.
    static func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded(.down) }

    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }

    static func skipped(_ id: UUID, _ why: String) -> Data {
        DchFrame.encode(DchFrame.ok, json: ["skipped": [["id": id.uuidString, "reason": why]]])
    }
}

// MARK: - clipboardUpload 0x23 (#617)

/// One phone upload: the 0x23 header, then 0x10 data frames until `size` bytes, then one
/// reply: ok {added} | ok {skipped} | error ("hash mismatch", "short" on an empty data
/// frame before `size`, "too long" past it). Text and images within the Mac's capture
/// limits collect in memory and are sealed into the store; anything larger, and every
/// file, streams to `.prosper-<id>.part` in the received-files folder, hashed as it
/// goes, renamed on a verified completion. The row sits in ClipboardStore.receiving
/// meanwhile; a failure, a cancel or a dropped connection removes it and the .part file.
/// Its work runs on its own serial queue, never the server queue.
final class DchClipboardUpload: @unchecked Sendable {
    private let ops: DchClipboardOps
    private let reply: DchControlOps.Reply
    private let closeConnection: @Sendable () -> Void
    private let q = DispatchQueue(label: "eu.illegible.prosper.clipboard-upload")

    /// Bytes fed but not yet written, under `lock`. Past `backlog` the connection stops
    /// reading the socket until they drain (whenDrained), so a slow disk never queues a
    /// fast phone's whole payload in memory.
    private let lock = NSLock()
    private var pending = 0
    private var resume: (@Sendable () -> Void)?
    static let backlog = 4 << 20

    // On q.
    private var u: DchClipboardOps.Upload?
    private var done = false
    private var received = 0
    private var hasher = SHA256()
    private var memory = Data()
    private var file: FileHandle?
    private var part: URL?

    init(ops: DchClipboardOps, reply: @escaping DchControlOps.Reply, closeConnection: @escaping @Sendable () -> Void) {
        self.ops = ops
        self.reply = reply
        self.closeConnection = closeConnection
    }

    func start(_ header: Data) { q.async { self.begin(header) } }

    /// One 0x10 frame, from the server queue.
    func feed(_ chunk: Data) {
        lock.withLock { pending += chunk.count }
        q.async {
            self.take(chunk)
            let go = self.lock.withLock { () -> (@Sendable () -> Void)? in
                self.pending -= chunk.count
                guard self.pending <= Self.backlog, let r = self.resume else { return nil }
                self.resume = nil
                return r
            }
            go?()
        }
    }

    /// `f` now while the backlog is small, else once it has drained.
    func whenDrained(_ f: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if pending <= Self.backlog { return true }
            resume = f
            return false
        }
        if now { f() }
    }

    /// The connection closed: discard the partial item.
    func cancel() { q.async { self.fail("cancelled") } }

    /// Test seam: runs after everything already queued.
    func sync() { q.sync {} }

    private func begin(_ header: Data) {
        guard ops.enabled() else { return finish(DchClipboardOps.error(DchClipboardOps.offMessage)) }
        guard let u = DchClipboardOps.upload(header) else { return finish(DchClipboardOps.error(DchClipboardOps.uploadShape)) }
        let dup = ops.onMain { s -> Bool in
            if s.receiving[u.id] != nil { return true }
            let kept: ClipboardItem? = s.item(u.id)
                ?? (s.dedupe(sha256: u.sha256, date: u.date) ? s.items.first { $0.sha256 == u.sha256 } : nil)
            guard let kept else { return false }
            if u.live { DchClipboardOps.setLive(kept, s) }
            return true
        }
        if dup { return finish(DchClipboardOps.skipped(u.id, "duplicate")) }
        let toFile = u.kind == .file || u.size > ops.memoryMax(u.kind == .image)
        guard let dir = toFile ? ops.receivedDir() : ops.onMain({ $0.dir }) else {
            return finish(DchClipboardOps.error("no folder for received files"))
        }
        // ponytail: see minFreeAfter.
        if let free = ops.freeSpace(dir), free - Int64(u.size) < DchClipboardOps.minFreeAfter {
            return finish(DchClipboardOps.skipped(u.id, "no_space"))
        }
        if toFile, !openPart(in: dir, u) { return finish(DchClipboardOps.error("cannot write the received file")) }
        self.u = u
        let close = closeConnection
        let r = ClipboardReceiving(id: u.id, kind: u.kind, createdAt: u.date, name: u.name, size: u.size, bytes: 0)
        ops.onMain { $0.beginReceiving(r, cancel: close) }
        if u.size == 0 { complete() }
    }

    private func openPart(in dir: URL, _ u: DchClipboardOps.Upload) -> Bool {
        let url = dir.appendingPathComponent(".prosper-\(u.id.uuidString).part")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = FileHandle(forWritingAtPath: url.path) else { return false }
        (file, part) = (h, url)
        return true
    }

    private func take(_ chunk: Data) {
        guard !done, let u else { return }
        guard !chunk.isEmpty else { return fail("short") }
        guard received + chunk.count <= u.size else { return fail("too long") }
        hasher.update(data: chunk)
        if let file {
            guard (try? file.write(contentsOf: chunk)) != nil else { return fail("cannot write the received file") }
        } else {
            memory.append(chunk)
        }
        received += chunk.count
        let (id, n, store) = (u.id, received, ops.store)
        DispatchQueue.main.async { MainActor.assumeIsolated { store().receivingProgress(id, bytes: n) } }
        if received == u.size { complete() }
    }

    private func complete() {
        guard let u else { return }
        guard DchClipboardOps.hex(hasher.finalize()) == u.sha256 else { return fail("hash mismatch") }
        if file == nil {
            let data = memory
            memory = Data()
            if u.kind == .text {
                guard let s = String(data: data, encoding: .utf8),
                      !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return skip("bad_item") }
                return add(.text(s))
            }
            guard let (w, h) = Self.pixels(data) else { return skip("bad_item") }
            guard w * h > ops.maxPixels else { return add(.image(data, width: w, height: h)) }
            // Past the Mac's own pixel limit: a file, as a big image always is.
            guard let dir = ops.receivedDir(), openPart(in: dir, u), (try? file?.write(contentsOf: data)) != nil else {
                return fail("cannot write the received file")
            }
        }
        try? file?.close()
        file = nil
        guard let part, let dest = DchClipboardOps.place(part, in: part.deletingLastPathComponent(), as: DchClipboardOps.fileName(u)) else {
            return fail("cannot write the received file")
        }
        self.part = nil
        add(.file(dest)) { try? FileManager.default.removeItem(at: dest) }
    }

    /// Inserts the item, ends its receiving row and (live) sets the pasteboard, in one main
    /// hop; a content duplicate that arrived meanwhile is skipped and `undo` runs.
    private func add(_ payload: ClipboardStore.RemotePayload, undo: () -> Void = {}) {
        guard let u else { return }
        let result = ops.onMain { s -> String? in
            defer { s.endReceiving(u.id) }
            if s.dedupe(sha256: u.sha256, date: u.date) {
                if u.live, let kept = s.items.first(where: { $0.sha256 == u.sha256 }) { DchClipboardOps.setLive(kept, s) }
                return "duplicate"
            }
            guard s.addRemote(id: u.id, date: u.date, source: "iPhone", sha256: u.sha256, payload) else { return "write" }
            guard let it = s.item(u.id) else { return "too_old" }   // evicted at once: older than the cap keeps
            if u.live { DchClipboardOps.setLive(it, s) }
            return nil
        }
        switch result {
        case nil: finish(DchFrame.encode(DchFrame.ok, json: ["added": [u.id.uuidString]]))
        case "duplicate", "too_old": undo(); finish(DchClipboardOps.skipped(u.id, result!))
        default: undo(); finish(DchClipboardOps.error("cannot store the item"))
        }
    }

    private func skip(_ why: String) {
        cleanup()
        finish(DchClipboardOps.skipped(u?.id ?? UUID(), why))
    }

    private func fail(_ message: String) {
        guard !done else { return }
        cleanup()
        finish(DchClipboardOps.error(message))
    }

    private func cleanup() {
        try? file?.close()
        file = nil
        if let part { try? FileManager.default.removeItem(at: part) }
        part = nil
        memory = Data()
        if let id = u?.id { ops.onMain { $0.endReceiving(id) } }
    }

    private func finish(_ frame: Data) {
        guard !done else { return }
        done = true
        reply(frame)
    }

    static func pixels(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }
}
