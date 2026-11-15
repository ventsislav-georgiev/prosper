import AppKit
import CryptoKit
import os

/// Persistent store for clipboard history. Index records live in `index.json`;
/// payload blobs (full text, image PNG) live as sibling files so huge clips
/// stay off the heap. `file` entries reference the source path (not copied).
///
/// `@MainActor` + `ObservableObject` so the SwiftUI panel observes it directly.
@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipboardItem] = []

    /// Max retained *unpinned* entries; oldest evicted (and blobs deleted)
    /// beyond this. Pinned entries are never evicted and don't count toward it.
    /// User-configurable (Settings → General), defaults to 500.
    private var maxItems: Int { Preferences.clipboardHistoryMaxItems }

    /// #617: uploads from the phone still arriving, by id: the History row's progress (#632).
    /// They join `items` only once complete; a failed or cancelled one just leaves this map.
    @Published private(set) var receiving: [UUID: ClipboardReceiving] = [:]
    private var receivingCancel: [UUID: @Sendable () -> Void] = [:]

    nonisolated let dir: URL
    private let indexURL: URL
    /// #1067 test seam: told each blob name readBlob opens, on the reading thread. @Sendable, so
    /// a closure made in MainActor code is not MainActor-isolated and may run on any queue.
    nonisolated let onBlobRead: (@Sendable (String) -> Void)?
    /// #1100 test seam: told each phone item's id once sealRemote has written its blob, on the sealing thread.
    nonisolated let onSeal: (@Sendable (UUID) -> Void)?

    /// #1285: where the sealing key comes from (tests inject one). While it throws the store
    /// writes nothing: no blob, no index, no sweep; clips are held in memory and the next
    /// persist asks again. The key is kept only once a call succeeded.
    nonisolated let keySource: ClipboardCrypto.KeySource
    nonisolated private let cachedKey = OSAllocatedUnfairLock<SymmetricKey?>(initialState: nil)
    /// #1285: blob bytes captured while the key is unavailable, by blob name; written by persist.
    nonisolated private let held = OSAllocatedUnfairLock(initialState: [String: Data]())
    /// #1285: index.json exists but was not read for want of the key; merged in before it is written.
    private var unreadIndex = false
    /// #1285: a plain line for the panel while history is not being saved; nil otherwise.
    @Published private(set) var notice: String?
    static let keyNotice = "Clipboard history is not being saved: Prosper cannot read its device key. New clips are kept until Prosper quits."

    /// #617: under XCTest a fixed throwaway dir, never the operator's store: ClipboardCrypto's
    /// test key is random per process, so a stray write to `shared` would re-seal the real index.
    static var defaultDir: URL {
        if NSClassFromString("XCTestCase") != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "prosper-xctest-clipboard", directoryHint: .isDirectory)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Prosper", directoryHint: .isDirectory)
            .appending(path: "clipboard", directoryHint: .isDirectory)
    }

    /// `dir` is a seam: tests pass a tempDir(), never the real store.
    init(dir base: URL = ClipboardStore.defaultDir, onBlobRead: (@Sendable (String) -> Void)? = nil,
         onSeal: (@Sendable (UUID) -> Void)? = nil, keySource: @escaping ClipboardCrypto.KeySource = ClipboardCrypto.deviceKey) {
        dir = base
        self.keySource = keySource
        indexURL = base.appending(path: "index.json")
        self.onBlobRead = onBlobRead
        self.onSeal = onSeal
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if load() { sweep() }
    }

    // MARK: - Public API

    /// Adds a text entry, persisting the full text to a blob file. The text is
    /// content-classified (link / email / color / plain) for icon + filtering.
    func addText(_ string: String, encrypt: Bool = true) {
        // Skip duplicates of the most-recent textual entry.
        if let first = items.first, first.kind.isTextual,
           let path = first.blobFile,
           readBlob(path).flatMap({ String(data: $0, encoding: .utf8) }) == string {
            return
        }
        let id = UUID()
        let blob = "\(id.uuidString).txt"
        let bytes = string.utf8.count
        guard writeBlob(Data(string.utf8), to: blob, encrypt: encrypt) else {
            NSLog("prosper: clipboard text write failed")
            return
        }
        let preview = Self.textPreview(string)
        insert(ClipboardItem(id: id, kind: Self.classify(string), createdAt: Date(), preview: preview,
                             byteCount: bytes, blobFile: blob, sourcePath: nil, fileName: nil,
                             sha256: Self.sha256(Data(string.utf8))))
    }

    /// Adds an image entry, persisting PNG bytes to a blob file.
    func addImage(_ image: NSImage, pngData: Data, encrypt: Bool = true) {
        let id = UUID()
        let blob = "\(id.uuidString).png"
        guard writeBlob(pngData, to: blob, encrypt: encrypt) else {
            NSLog("prosper: clipboard image write failed")
            return
        }
        let size = image.size
        let preview = "Image \(Int(size.width))×\(Int(size.height))"
        insert(ClipboardItem(id: id, kind: .image, createdAt: Date(), preview: preview,
                             byteCount: pngData.count, blobFile: blob, sourcePath: nil, fileName: nil,
                             sha256: Self.sha256(pngData)))
    }

    /// Records an oversize image as a metadata-only entry: no blob is decoded or
    /// stored (it would spike memory), so the row shows its dimensions and a
    /// placeholder, and paste-back is unavailable. Keeps the UI fast on huge clips.
    func addOversizeImage(width: Int, height: Int) {
        let preview = width > 0 && height > 0
            ? "Image \(width)×\(height) — too large to store"
            : "Image — too large to store"
        insert(ClipboardItem(id: UUID(), kind: .image, createdAt: Date(), preview: preview,
                             byteCount: 0, blobFile: nil, sourcePath: nil, fileName: nil))
    }

    /// Records oversize text as a metadata-only entry (preview snippet only, no
    /// blob). Avoids persisting/encrypting multi-megabyte payloads.
    func addOversizeText(byteCount: Int, preview: String) {
        let snippet = Self.textPreview(preview)
        let mb = Double(byteCount) / (1024 * 1024)
        let label = snippet.isEmpty
            ? String(format: "Large text — %.1f MB, too large to store", mb)
            : snippet
        insert(ClipboardItem(id: UUID(), kind: .text, createdAt: Date(), preview: label,
                             byteCount: byteCount, blobFile: nil, sourcePath: nil, fileName: nil))
    }

    /// Adds a file reference (the file itself is not copied into the store).
    func addFile(_ url: URL) {
        let path = url.path
        if let first = items.first, first.kind == .file, first.sourcePath == path { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        let name = url.lastPathComponent
        insert(ClipboardItem(id: UUID(), kind: .file, createdAt: Date(), preview: name,
                             byteCount: size, blobFile: nil, sourcePath: path, fileName: name))
    }

    /// Writes the entry back onto the general pasteboard.
    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = Pasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text, .link, .email, .color:
            if let blob = item.blobFile,
               let data = readBlob(blob),
               let text = String(data: data, encoding: .utf8) {
                pb.setString(text, forType: .string)
            }
        case .image:
            if let blob = item.blobFile,
               let data = readBlob(blob),
               let image = NSImage(data: data) {
                pb.writeObjects([image])
            }
        case .file:
            if let path = item.sourcePath {
                pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
            }
        }
    }

    /// Full text of a textual entry (for the preview pane), or nil.
    func text(for item: ClipboardItem) -> String? {
        guard item.kind.isTextual, let blob = item.blobFile,
              let data = readBlob(blob) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decrypted image bytes for a stored image entry (for the preview pane and
    /// thumbnails), or nil. Blobs are encrypted at rest, so callers can't read
    /// the file URL directly — they decode this in-memory `Data` instead.
    func imageData(for item: ClipboardItem) -> Data? {
        guard item.kind == .image, let blob = item.blobFile else { return nil }
        return readBlob(blob)
    }

    func delete(_ item: ClipboardItem) {
        if let blob = item.blobFile { removeBlobFile(blob) }
        items.removeAll { $0.id == item.id }
        persist()
    }

    /// Toggles the pinned flag and re-sorts (pinned first, newest within group).
    func togglePin(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].pinned.toggle()
        sort()
        persist()
    }

    /// Renames an entry (user title). Empty string clears the title.
    func rename(_ item: ClipboardItem, to title: String) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        items[idx].title = trimmed.isEmpty ? nil : trimmed
        persist()
    }

    func clearAll() {
        // Pinned entries are protected from "clear all" too.
        let removed = items.filter { !$0.pinned }
        for item in removed where item.blobFile != nil {
            removeBlobFile(item.blobFile!)
        }
        items.removeAll { !$0.pinned }
        persist()
    }

    // MARK: - From the phone (#617)

    func item(_ id: UUID) -> ClipboardItem? { items.first { $0.id == id } }

    /// Content dedupe: an entry with this sha256 and of this kind (#1100: every textual kind is one,
    /// so a text and a file of the same bytes are two entries) is kept as the one entry, moved to
    /// `date` when that is newer. The kept entry when there was one (the caller skips its item).
    @discardableResult
    func dedupe(sha256: String, kind: ClipboardKind, date: Date) -> ClipboardItem? {
        guard let i = items.firstIndex(where: { $0.sha256 == sha256 && ($0.kind.isTextual ? kind.isTextual : $0.kind == kind) })
        else { return nil }
        guard date > items[i].createdAt else { return items[i] }
        items[i].createdAt = date
        let kept = items[i]
        sort()
        persist()
        return kept
    }

    enum RemotePayload {
        case text(String)
        /// Any ImageIO-decodable bytes, stored as received.
        case image(Data, width: Int, height: Int)
        /// A received file under the received-files folder, referenced like a copied Mac file.
        case file(URL)

        /// The kind dedupe compares (sealRemote classifies a text further; all textual kinds match).
        nonisolated var kind: ClipboardKind {
            switch self {
            case .text: .text
            case .image: .image
            case .file: .file
            }
        }
    }

    /// Inserts a phone item at its own date. Text and image are sealed through writeBlob,
    /// whatever their size (#617: no plaintext in the store dir). False when the write fails.
    @discardableResult
    func addRemote(id: UUID, date: Date, source: String, sha256: String, _ payload: RemotePayload) -> Bool {
        guard let item = sealRemote(id: id, date: date, source: source, sha256: sha256, payload) else { return false }
        insertRemote(item)
        return true
    }

    /// #617 fix round 1: addRemote's half that runs off main: classify, the preview and the
    /// sealed blob, under a fresh blob name so a losing duplicate never touches a kept item's
    /// blob. Nil when the write fails. Then insertRemote on main, or removeBlob if it loses.
    nonisolated func sealRemote(id: UUID, date: Date, source: String, sha256: String, _ payload: RemotePayload) -> ClipboardItem? {
        let item: ClipboardItem
        switch payload {
        case .text(let s):
            let blob = "\(UUID().uuidString).txt"
            guard writeSealing(Data(s.utf8), to: blob) else { return nil }
            item = ClipboardItem(id: id, kind: Self.classify(s), createdAt: date, preview: Self.textPreview(s),
                                 byteCount: s.utf8.count, blobFile: blob, sourcePath: nil, fileName: nil,
                                 source: source, sha256: sha256)
        case .image(let data, let w, let h):
            let blob = "\(UUID().uuidString).png"
            guard writeSealing(data, to: blob) else { return nil }
            item = ClipboardItem(id: id, kind: .image, createdAt: date, preview: "Image \(w)×\(h)",
                                 byteCount: data.count, blobFile: blob, sourcePath: nil, fileName: nil,
                                 source: source, sha256: sha256)
        case .file(let url):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            item = ClipboardItem(id: id, kind: .file, createdAt: date, preview: url.lastPathComponent,
                                 byteCount: size, blobFile: nil, sourcePath: url.path, fileName: url.lastPathComponent,
                                 source: source, sha256: sha256)
        }
        onSeal?(id)
        return item
    }

    func insertRemote(_ item: ClipboardItem) {
        insert(item)
        unseal(item)
    }

    /// A sealed item's blob, off main, once its insert lost.
    nonisolated func removeBlob(_ item: ClipboardItem) {
        if let blob = item.blobFile { removeBlobFile(blob) }
        unseal(item)
    }

    /// #1067: blob names sealRemote wrote and no insertRemote or removeBlob has settled yet,
    /// process-wide. A name is a fresh UUID, so it is unique across stores. The sweep skips them.
    nonisolated private static let sealing = OSAllocatedUnfairLock(initialState: Set<String>())

    /// writeBlob (sealed) for a phone item, its name held in `sealing` from before the file exists.
    nonisolated private func writeSealing(_ data: Data, to name: String) -> Bool {
        Self.sealing.withLock { _ = $0.insert(name) }
        if writeBlob(data, to: name, encrypt: true) { return true }
        Self.sealing.withLock { _ = $0.remove(name) }
        return false
    }

    nonisolated private func unseal(_ item: ClipboardItem) {
        if let blob = item.blobFile { Self.sealing.withLock { _ = $0.remove(blob) } }
    }

    /// An upload starts arriving; `cancel` drops its connection (whose teardown calls endReceiving).
    func beginReceiving(_ r: ClipboardReceiving, cancel: @escaping @Sendable () -> Void) {
        receiving[r.id] = r
        receivingCancel[r.id] = cancel
    }

    /// Bytes so far; ignored once the upload has ended.
    func receivingProgress(_ id: UUID, bytes: Int) {
        guard receiving[id] != nil else { return }
        receiving[id]?.bytes = bytes
    }

    func endReceiving(_ id: UUID) {
        receiving[id] = nil
        receivingCancel[id] = nil
    }

    /// Cancels an upload still arriving (#632's Esc): its connection closes, the partial
    /// payload is discarded and the row leaves `receiving`.
    func cancel(_ id: UUID) {
        let c = receivingCancel[id]
        endReceiving(id)
        c?()
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Internals

    private func insert(_ item: ClipboardItem) {
        items.insert(item, at: 0)
        sort()
        evictIfNeeded()
        persist()
    }

    /// Pinned entries first, then by recency (descending) within each group.
    private func sort() {
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.createdAt > b.createdAt
        }
    }

    private func evictIfNeeded() {
        let unpinned = items.filter { !$0.pinned }
        guard unpinned.count > maxItems else { return }
        // Items are already sorted (pinned first, newest first), so the oldest
        // unpinned sit at the tail — drop everything beyond the cap.
        let victims = unpinned.suffix(unpinned.count - maxItems)
        let victimIDs = Set(victims.map(\.id))
        for item in victims where item.blobFile != nil {
            removeBlobFile(item.blobFile!)
        }
        items.removeAll { victimIDs.contains($0.id) }
    }

    private func persist() {
        // #1285: no key, no write: the index on disk and its blobs stay as they are.
        guard let key = self.key() else { return refuse() }
        if unreadIndex {
            // The key is back: the history on disk joins the clips captured meanwhile.
            if let disk = readIndex(key) {
                let mine = Set(items.map(\.id))
                items += disk.filter { !mine.contains($0.id) }
                sort()
                evictIfNeeded()
            }
            unreadIndex = false
        }
        for (name, data) in held.withLock({ $0 }) where writeBlob(data, to: name, encrypt: true) {
            held.withLock { _ = $0.removeValue(forKey: name) }
        }
        notice = nil
        do {
            let json = try JSONEncoder().encode(items)
            let sealed = try ClipboardCrypto.encrypt(json, key: key)
            try sealed.write(to: indexURL, options: .atomic)
            protect(indexURL)
        } catch {
            NSLog("prosper: clipboard index write failed: \(error.localizedDescription)")
        }
    }

    /// True only when index.json was read and decoded: the sweep runs only then.
    private func load() -> Bool {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return false }
        // #1285: without the key the index is left unread and untouched, and no sweep runs.
        guard let key = self.key() else { unreadIndex = true; refuse(); return false }
        guard let decoded = readIndex(key) else { return false }
        items = decoded
        sort()
        return true
    }

    /// Encrypted index (current), or legacy plaintext JSON written by pre-encryption builds;
    /// either way decoded, and the next persist writes it back encrypted. Nil when unreadable.
    private func readIndex(_ key: SymmetricKey) -> [ClipboardItem]? {
        guard let raw = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode([ClipboardItem].self, from: ClipboardCrypto.decryptOrPlaintext(raw, key: key))
    }

    /// #1285: the key, asking keySource again until one call succeeds; nil while it throws.
    nonisolated private func key() -> SymmetricKey? {
        if let k = cachedKey.withLock({ $0 }) { return k }
        guard let k = try? keySource() else { return nil }
        cachedKey.withLock { $0 = k }
        return k
    }

    /// #1285: the one notice (and one log line) while history is not being saved.
    private func refuse() {
        guard notice == nil else { return }
        notice = Self.keyNotice
        NSLog("prosper: clipboard history not saved: the device key is unavailable")
    }

    /// A blob's file, or its bytes held in memory while the key was unavailable.
    nonisolated private func removeBlobFile(_ name: String) {
        held.withLock { _ = $0.removeValue(forKey: name) }
        try? FileManager.default.removeItem(at: dir.appending(path: name))
    }

    /// #1067: removes the blobs no row references, as a quit between a phone item's seal and its
    /// insert leaves. Once, from init on main, after load() read the index. Only names directly in
    /// `dir` of this store's own pattern, not named by any row nor held in `sealing`; lstat, so
    /// only a regular file (never a link or a folder) unmodified for sweepMinAge; unlink, which never
    /// follows a link.
    private func sweep() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let keep = Set(items.compactMap(\.blobFile) + items.compactMap(\.sourcePath).map { ($0 as NSString).lastPathComponent })
            .union(Self.sealing.withLock { $0 })
        var removed = 0
        for name in names where Self.isBlobName(name) && !keep.contains(name) {
            let path = dir.appending(path: name).path
            var st = stat()
            // Old enough only: `sealing` is per process, so another Prosper on this folder may be mid-seal.
            // The file's mtime is never an arithmetic operand (any value a volume returns compares safely);
            // a clock set back puts the cutoff before the file's mtime: the file stays.
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  st.st_mtimespec.tv_sec <= time(nil) - Self.sweepMinAge, unlink(path) == 0 else { continue }
            removed += 1
        }
        if removed > 0 { NSLog("prosper: clipboard sweep removed \(removed) unreferenced file(s)") }
    }

    /// Seconds an unreferenced blob must sit unmodified before the launch sweep removes it.
    nonisolated static let sweepMinAge = 600

    /// The names this store gives its blobs, and only those: "<UUID().uuidString>.txt" or ".png".
    nonisolated static func isBlobName(_ name: String) -> Bool {
        let ns = name as NSString, stem = ns.deletingPathExtension
        return ["txt", "png"].contains(ns.pathExtension) && UUID(uuidString: stem)?.uuidString == stem
    }

    // MARK: - Encrypted blob I/O

    /// Writes `data` to `name` inside the store dir, marking the file for complete
    /// at-rest protection. Small payloads are AES-GCM encrypted; larger ones are
    /// written as-is (`encrypt: false`) to skip the in-memory ciphertext copy that
    /// sealing a big blob would require — the read path (`decryptOrPlaintext`)
    /// handles either form transparently, so both still restore. Returns false on
    /// failure.
    nonisolated private func writeBlob(_ data: Data, to name: String, encrypt: Bool) -> Bool {
        // #1285: no key, no file (sealed or not): held in memory until persist has the key.
        guard let key = self.key() else {
            held.withLock { $0[name] = data }
            return true
        }
        do {
            let payload = encrypt ? try ClipboardCrypto.encrypt(data, key: key) : data
            let url = dir.appending(path: name)
            try payload.write(to: url, options: .atomic)
            protect(url)
            return true
        } catch {
            return false
        }
    }

    /// Reads and decrypts blob `name`, or nil if missing/unreadable. Bytes
    /// written by a pre-encryption build are returned as-is (legacy migration).
    nonisolated func readBlob(_ name: String) -> Data? {
        onBlobRead?(name)
        if let data = held.withLock({ $0[name] }) { return data }
        guard let raw = try? Data(contentsOf: dir.appending(path: name)), let key = self.key() else { return nil }
        return ClipboardCrypto.decryptOrPlaintext(raw, key: key)
    }

    /// Best-effort OS-level file protection (encrypted at rest while locked),
    /// matching the typing-history store.
    nonisolated private func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    /// Re-applies the (possibly lowered) retention cap after the user changes it
    /// in Settings, evicting now-excess entries immediately.
    func applyMaxItemsChange() {
        evictIfNeeded()
        persist()
    }

    nonisolated private static func textPreview(_ s: String, limit: Int = 140) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    // MARK: - Content classification (Raycast parity)

    /// #617: Sendable (an immutable NSRegularExpression); classify runs off main for phone items.
    nonisolated private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Classifies a string into a textual sub-kind. Order: color → link / email
    /// (a single detector match spanning the whole trimmed string) → plain text.
    nonisolated static func classify(_ raw: String) -> ClipboardKind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // #617: a link, an email or a color is short; a phone's 100 MB text skips the
        // detector, which runs on main.
        guard !s.isEmpty, s.utf8.count <= 64 << 10 else { return .text }
        if isColor(s) { return .color }
        if let detector = linkDetector {
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            let matches = detector.matches(in: s, options: [], range: range)
            if matches.count == 1, matches[0].range == range, let url = matches[0].url {
                return url.scheme == "mailto" ? .email : .link
            }
        }
        return .text
    }

    /// Recognizes CSS-style colors: `#rgb` / `#rgba` / `#rrggbb` / `#rrggbbaa`
    /// hex, and `rgb()/rgba()/hsl()/hsla()` functional forms.
    nonisolated static func isColor(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasPrefix("#") {
            let hex = lower.dropFirst()
            let n = hex.count
            guard n == 3 || n == 4 || n == 6 || n == 8 else { return false }
            return hex.allSatisfy(\.isHexDigit)
        }
        for fn in ["rgb(", "rgba(", "hsl(", "hsla("] where lower.hasPrefix(fn) {
            return lower.hasSuffix(")")
        }
        return false
    }
}

/// #617: one phone upload still arriving (ClipboardStore.receiving).
struct ClipboardReceiving: Equatable, Sendable {
    let id: UUID
    let kind: ClipboardKind
    let createdAt: Date
    let name: String?
    let size: Int
    var bytes: Int
}
