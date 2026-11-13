import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO
import os
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
    /// #701: one line per request (and the handshake's flag): its type, counts and reasons,
    /// never a clip's content, text or name. A seam, so tests read the lines.
    var log: @Sendable (OSLogType, String) -> Void = { level, line in
        DchClipboardOps.logger.log(level: level, "\(line, privacy: .public)")
    }
    static let logger = Logger(subsystem: "eu.illegible.prosper", category: "clipboard")

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
        let name = type == DchFrame.clipboardList ? "clipboardList" : type == DchFrame.clipboardItem ? "clipboardItem"
            : type == DchFrame.addClipboardHistory ? "addClipboardHistory" : "0x\(String(type, radix: 16))"
        @Sendable func done(_ f: Data) { reply(logRefusal(name, f)) }
        guard enabled() else { return done(Self.error(Self.offMessage)) }
        let o = payload.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard let o else { return done(Self.error("malformed request: not a JSON object")) }
        switch type {
        case DchFrame.clipboardList: list(o, done)
        case DchFrame.clipboardItem: item(o, send, done)
        case DchFrame.addClipboardHistory: addHistory(o, done)
        default: done(Self.error("unknown request"))
        }
    }

    /// #701: `frame`, a request's final reply; a refusal (error 0x13) is logged with its
    /// message, which is always one of this file's fixed strings, never a clip's content.
    @discardableResult
    func logRefusal(_ request: String, _ frame: Data) -> Data {
        guard frame.first == DchFrame.error else { return frame }
        let o = (try? JSONSerialization.jsonObject(with: frame.dropFirst(5))) as? [String: Any]
        log(.error, "\(request) refused: \(o?["message"] as? String ?? "")")
        return frame
    }

    /// putClipboardText {text}: the live pasteboard, as "send to Mac now". On the server
    /// queue, as putClipboard: the phone's ctrl-V can be the very next frame.
    func putText(_ payload: Data) -> Data {
        guard enabled() else { return logRefusal("putClipboardText", Self.error(Self.offMessage)) }
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any], o.count == 1,
              let text = o["text"] as? String else {
            return logRefusal("putClipboardText", Self.error("malformed putClipboardText request: send {\"text\": \"…\"}"))
        }
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log(.default, "putClipboardText: \(text.utf8.count) bytes")
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
                if data.count <= DchFrame.maxFrame {
                    log(.default, "clipboardList: \(wire.count) of \(rows.count) rows, \(data.count) bytes"
                        + (since == nil ? "" : ", since") + (before == nil ? "" : ", before"))
                }
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
        let start = Date()
        guard let id = (o["id"] as? String).flatMap(UUID.init(uuidString:)),
              Set(o.keys).isSubset(of: ["id", "offset", "max_side"]) else {
            return reply(Self.error("malformed clipboardItem request: send {\"id\": \"…\", \"offset\"?: n, \"max_side\"?: px}"))
        }
        var offset = 0
        if let v = o["offset"] {
            guard let n = Self.int(v) else { return reply(Self.error("bad offset")) }
            offset = n
        }
        // #707: a positive integer, else the original as before (never an error).
        let maxSide = Self.int(o["max_side"]).flatMap { $0 > 0 ? $0 : nil }
        let (found, store) = onMain { s in (s.item(id), s) }
        guard let it = found else { return reply(Self.error("gone")) }
        if it.kind == .file {
            guard let path = it.sourcePath else { return reply(Self.error("gone")) }
            return streamFile(it, path: path, offset: offset, maxSide: maxSide, start: start, send, reply)
        }
        guard let blob = it.blobFile else { return reply(Self.error("not stored")) }
        guard let original = store.readBlob(blob) else { return reply(Self.error("gone")) }
        let data = it.kind == .image ? maxSide.flatMap { Self.downsample(original, maxSide: $0) } ?? original : original
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
        logItem(it, bytes: data.count - offset, offset: offset, start: start, maxSide: maxSide, before: original.count, after: data.count)
        reply(DchFrame.encode(DchFrame.ok, []))
    }

    /// #707: `data` with its long side cut to `maxSide` px, in its own format (alpha kept,
    /// EXIF orientation applied to the pixels); nil = send the original: already small
    /// enough, animated, unreadable, a format ImageIO cannot write, or a re-encode no smaller. The same input
    /// encodes to the same bytes, so a resumed pull's offset and sha256 still hold.
    static func downsample(_ data: Data, maxSide: Int) -> Data? {
        guard let (w, h) = DchClipboardUpload.pixels(data), max(w, h) > maxSide,
              let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) == 1,
              let type = CGImageSourceGetType(src) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        // ponytail: one fixed JPEG/HEIC quality; PNG and other lossless formats ignore it.
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        // A low-quality JPEG/HEIC just over maxSide can grow at 0.85 (QA #524 LOW-1).
        return CGImageDestinationFinalize(dst) && out.length < data.count ? out as Data : nil
    }

    /// A file entry's source file: opened O_NONBLOCK and only as a regular file (#608,
    /// #627), hashed in a first pass, then sent from `offset`. A file that changes
    /// between the passes ends in error "changed".
    private func streamFile(_ it: ClipboardItem, path: String, offset: Int, maxSide: Int?, start: Date, _ send: Send, _ reply: Reply) {
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
        logItem(it, bytes: size - offset, offset: offset, start: start, maxSide: maxSide, before: size, after: size)
        reply(DchFrame.encode(DchFrame.ok, []))
    }

    /// #707: a request's max_side adds the item's bytes before and after it (equal when
    /// nothing was cut: text, a file, a small image).
    private func logItem(_ it: ClipboardItem, bytes: Int, offset: Int, start: Date, maxSide: Int?, before: Int, after: Int) {
        log(.default, "clipboardItem: \(Self.wireKind(it.kind)), \(bytes) bytes from \(offset), "
            + (maxSide.map { "max_side \($0), \(before) to \(after) bytes, " } ?? "")
            + String(format: "%.1f s", Date().timeIntervalSince(start)))
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
        let store = onMain { $0 }
        for e in arr {
            let e = e as? [String: Any] ?? [:]
            let idText = e["id"] as? String ?? ""
            func skip(_ why: String) { skipped.append(["id": idText, "reason": why]) }
            guard let id = UUID(uuidString: idText), let kind = e["kind"] as? String else { skip("bad_item"); continue }
            if kind == "image" || kind == "file" { skip("use_upload"); continue }
            guard kind == "text", let text = e["text"] as? String, let date = (e["date"] as? String).flatMap(Self.itemDate),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { skip("bad_item"); continue }
            guard text.utf8.count <= Self.smallText else { skip("use_upload"); continue }
            let sha = ClipboardStore.sha256(Data(text.utf8))
            // #1067: decided on main before the seal, so a re-sent batch seals nothing. Then sealed
            // here, off main; the insert hop decides again (another connection can land the same id
            // or content in between); a losing blob goes off main.
            if onMain({ Self.known($0, id, sha256: sha, date: date) }) { skip("duplicate"); continue }
            guard let sealed = store.sealRemote(id: id, date: date, source: "iPhone", sha256: sha, .text(text)) else {
                skip("write_failed"); continue
            }
            let why = onMain { s -> String? in
                if Self.known(s, id, sha256: sha, date: date) { return "duplicate" }
                s.insertRemote(sealed)
                return s.item(id) == nil ? "too_old" : nil   // older than the history's cap keeps
            }
            if let why { store.removeBlob(sealed); skip(why) } else { added.append(idText) }
        }
        let reasons = Dictionary(skipped.map { ($0["reason"] ?? "", 1) }, uniquingKeysWith: +)
            .sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        log(.default, "addClipboardHistory: \(arr.count) items, \(added.count) added, \(skipped.count) skipped"
            + (reasons.isEmpty ? "" : " (\(reasons))"))
        reply(DchFrame.encode(DchFrame.ok, json: ["added": added, "skipped": skipped]))
    }

    /// A 0x22 item already held: its id is in history or still receiving, or its content (the
    /// Mac's own hash) is, which dedupe moves to `date` when newer.
    @MainActor static func known(_ s: ClipboardStore, _ id: UUID, sha256: String, date: Date) -> Bool {
        s.item(id) != nil || s.receiving[id] != nil || s.dedupe(sha256: sha256, date: date)
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
              let date = (o["date"] as? String).flatMap(Self.itemDate),
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

    /// APFS caps a name at 255 UTF-16 units; " 10000" is the longest suffix `place` adds.
    static let nameUnits = 255 - 6

    /// The received file's name: the phone's, as one plain path component (NUL, "/" and ":"
    /// become "-"), cut to 200 Characters and `nameUnits` UTF-16 units keeping a short
    /// extension (or .tar.gz/.bz2/.xz), else "iPhone Clipboard" with an extension from the
    /// mime or the kind.
    static func fileName(_ u: Upload) -> String {
        var n = String((u.name ?? "").map { "/:\u{0}".contains($0) || $0.isNewline ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // #1067: one pass (removeFirst in a loop was quadratic); by scalar, so no name starts with a "." byte.
        n = String(n.unicodeScalars.drop { $0 == "." })
        if n.count > 200 || n.utf16.count > nameUnits {
            let (base, tail) = split(n)
            let b = fit(base, chars: 200 - tail.count, units: nameUnits - tail.utf16.count)
            n = b.isEmpty ? "" : b + tail
        }
        guard n.isEmpty else { return n }
        let ext = u.mime.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
            ?? (u.kind == .text ? "txt" : u.kind == .image ? "png" : nil)
        return ext.map { "iPhone Clipboard.\($0)" } ?? "iPhone Clipboard"
    }

    /// #1067: the longest prefix of whole Characters of `s`, at most `chars` of them and `units`
    /// UTF-16 units, in one pass (it cut one Character at a time and recounted). Never cuts inside
    /// a Character: a surrogate pair, or a base and its combining marks. Generic, so a test counts
    /// the Characters it takes.
    static func fit<S: Sequence<Character>>(_ s: S, chars: Int, units: Int) -> String {
        var out = "", used = 0
        for c in s.prefix(max(chars, 0)) {
            used += c.utf16.count   // used <= units (< 256) before this add, so it cannot overflow
            guard used <= units else { break }
            out.append(c)
        }
        return out
    }

    /// A name as base and a kept extension: 1-16 Characters, with a ".tar" before gz/bz2/xz.
    static func split(_ n: String) -> (String, String) {
        let ext = (n as NSString).pathExtension
        guard (1...16).contains(ext.count) else { return (n, "") }
        var base = (n as NSString).deletingPathExtension, tail = "." + ext
        if ["gz", "bz2", "xz"].contains(ext.lowercased()), (base as NSString).pathExtension.lowercased() == "tar" {
            tail = "." + (base as NSString).pathExtension + tail
            base = (base as NSString).deletingPathExtension
        }
        return (base, tail)
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
            let err = errno
            guard err == EEXIST else {
                // A name the volume still finds too long saves as "iPhone Clipboard.<ext>".
                let fallback = "iPhone Clipboard" + split(name).1
                return err == ENAMETOOLONG && name != fallback ? place(part, in: dir, as: fallback) : nil
            }
        }
        return nil
    }

    /// #1067: a kept item's own bytes as setLive's payload, read and opened on the caller's
    /// thread (an upload's queue), so main only sets the pasteboard. Nil: a file, or no readable blob.
    static func livePayload(_ it: ClipboardItem, _ s: ClipboardStore) -> ClipboardStore.RemotePayload? {
        guard let data = it.blobFile.flatMap(s.readBlob) else { return nil }
        if it.kind == .image { return .image(data, width: 0, height: 0) }
        return it.kind.isTextual ? String(data: data, encoding: .utf8).map { .text($0) } : nil
    }

    /// The live pasteboard once an upload is complete: text as a string, an image as PNG
    /// (and TIFF), a file as its URL. The monitor then records no second copy.
    /// `payload`, when the caller still holds it, spares main the blob's read and decrypt.
    @MainActor static func setLive(_ it: ClipboardItem, _ s: ClipboardStore, _ payload: ClipboardStore.RemotePayload? = nil) {
        switch payload {
        case .text(let t)?:
            Pasteboard.general.clearContents()
            Pasteboard.general.setString(t, forType: .string)
        case .image(let data, _, _)?:
            DchConnection.setPasteboardImage(data)
        default:
            if it.kind == .image, let data = it.blobFile.flatMap(s.readBlob) {
                DchConnection.setPasteboardImage(data)
            } else {
                s.copyToPasteboard(it)
            }
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

    /// A phone item's date, never later than now (#617 fix round 1): a future date would
    /// keep it above every later copy, and re-date a kept duplicate on dedupe.
    static func itemDate(_ s: String) -> Date? { date(s).map { min($0, Date()) } }

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
    private var store: ClipboardStore?
    private var done = false
    private var received = 0
    private var hasher = SHA256()
    private var memory = Data()
    private var file: FileHandle?
    private var part: URL?
    private let start = Date()
    /// The parsed header, for the log line: `u` is set only once this upload owns its row.
    private var header: DchClipboardOps.Upload?

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
        self.header = u
        let close = closeConnection
        let r = ClipboardReceiving(id: u.id, kind: u.kind, createdAt: u.date, name: u.name, size: u.size, bytes: 0)
        // One hop: the id check and the row, so no second upload of this id gets past here.
        // #1067: no content dedupe here: the header's sha256 is the phone's claim until the bytes
        // hash to it (complete()); add() dedupes then.
        let begun = ops.onMain { s -> (ClipboardStore, kept: ClipboardItem?)? in
            if s.receiving[u.id] != nil { return nil }
            if let kept = s.item(u.id) { return (s, kept) }
            s.beginReceiving(r, cancel: close)
            return (s, nil)
        }
        guard let begun else { return finish(DchClipboardOps.skipped(u.id, "duplicate"), "skipped duplicate") }
        let store = begun.0
        if let kept = begun.kept {
            // The same id again: live, its blob is read and opened here, off main (#1067).
            if u.live {
                let p = DchClipboardOps.livePayload(kept, store)
                // The row may have been deleted during the read: live only while the store still holds it.
                ops.onMain { if $0.item(u.id) != nil { DchClipboardOps.setLive(kept, $0, p) } }
            }
            return finish(DchClipboardOps.skipped(u.id, "duplicate"), "skipped duplicate")
        }
        (self.u, self.store) = (u, store)   // from here a refusal ends the row (cleanup)
        let toFile = u.kind == .file || u.size > ops.memoryMax(u.kind == .image)
        guard let dir = toFile ? ops.receivedDir() : store.dir else { return fail("no folder for received files") }
        guard hasRoom(dir, u.size) else { return skip("no_space") }
        if toFile, !openPart(in: dir, u) { return fail("cannot write the received file") }
        if u.size == 0 { complete() }
    }

    /// ponytail: see minFreeAfter.
    private func hasRoom(_ dir: URL, _ size: Int) -> Bool {
        guard let free = ops.freeSpace(dir) else { return true }
        return free - Int64(size) >= DchClipboardOps.minFreeAfter
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
            // Past the Mac's own pixel limit: a file, as a big image always is. Its room was
            // checked on the store's volume; the received folder can be another one.
            guard let dir = ops.receivedDir() else { return fail("no folder for received files") }
            guard hasRoom(dir, data.count) else { return skip("no_space") }
            guard openPart(in: dir, u), (try? file?.write(contentsOf: data)) != nil else {
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

    /// The bytes have hashed to u.sha256 (complete()). One main hop decides first (#1067), so a
    /// duplicate or a cancelled item is never sealed; then the item is sealed here, off main
    /// (classify, preview, encrypt, write), and one main hop decides again (another upload can
    /// land the same content in between), inserts it, ends its receiving row and (live) sets the
    /// pasteboard. A loser - cancelled, a content duplicate, or older than the history keeps -
    /// has its blob removed back here, `undo` runs, and it is skipped.
    private func add(_ payload: ClipboardStore.RemotePayload, undo: () -> Void = {}) {
        guard let u, let store else { return }
        let live = u.live ? payload : nil
        func lose(_ why: String) {
            undo()
            finish(why == "cancelled" ? DchClipboardOps.error(why) : DchClipboardOps.skipped(u.id, why), "skipped \(why)")
        }
        if let why = ops.onMain({ Self.lost(u, $0, live) }) { return lose(why) }
        guard let item = store.sealRemote(id: u.id, date: u.date, source: "iPhone", sha256: u.sha256, payload) else {
            undo()
            return fail("cannot store the item")
        }
        let result = ops.onMain { s -> String? in
            if let why = Self.lost(u, s, live) { return why }
            defer { s.endReceiving(u.id) }
            s.insertRemote(item)
            guard let it = s.item(u.id) else { return "too_old" }   // evicted at once: older than the cap keeps
            if let live { DchClipboardOps.setLive(it, s, live) }
            return nil
        }
        guard let result else { return finish(DchFrame.encode(DchFrame.ok, json: ["added": [u.id.uuidString]]), "added") }
        store.removeBlob(item)   // too_old: eviction already removed it
        lose(result)
    }

    /// A verified upload that does not land, on main: cancelled (#632's Esc) while it ran, or its
    /// content already held, which ends its row and, live, puts the kept item on the pasteboard
    /// from the bytes just received (the same sha256, so the same bytes) when the kinds match:
    /// main never reads and opens the kept blob for it (#1067).
    @MainActor private static func lost(_ u: DchClipboardOps.Upload, _ s: ClipboardStore, _ live: ClipboardStore.RemotePayload?) -> String? {
        guard s.receiving[u.id] != nil else { return "cancelled" }
        guard s.dedupe(sha256: u.sha256, date: u.date) else { return nil }
        defer { s.endReceiving(u.id) }   // after setLive, as before
        if u.live, let kept = s.items.first(where: { $0.sha256 == u.sha256 }) {
            let same: Bool
            switch live {
            case .text?: same = kept.kind.isTextual
            case .image?: same = kept.kind == .image
            default: same = false
            }
            DchClipboardOps.setLive(kept, s, same ? live : nil)
        }
        return "duplicate"
    }

    private func skip(_ why: String) {
        cleanup()
        finish(DchClipboardOps.skipped(u?.id ?? UUID(), why), "skipped \(why)")
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

    /// The one reply, and its one log line (#701): a refusal with its message, else the
    /// kind, the bytes taken and `outcome`. Never the item's content or name.
    private func finish(_ frame: Data, _ outcome: String = "") {
        guard !done else { return }
        done = true
        if frame.first != DchFrame.error, let u = header {
            ops.log(.default, "clipboardUpload: \(u.kind.rawValue), \(received) of \(u.size) bytes, "
                + String(format: "%.1f s", Date().timeIntervalSince(start)) + ": \(outcome)")
        }
        reply(ops.logRefusal("clipboardUpload", frame))
    }

    static func pixels(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }
}
