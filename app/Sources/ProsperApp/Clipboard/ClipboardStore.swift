import AppKit

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

    private let dir: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Prosper", directoryHint: .isDirectory)
            .appending(path: "clipboard", directoryHint: .isDirectory)
        dir = base
        indexURL = base.appending(path: "index.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
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
                             byteCount: bytes, blobFile: blob, sourcePath: nil, fileName: nil))
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
                             byteCount: pngData.count, blobFile: blob, sourcePath: nil, fileName: nil))
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
        let pb = NSPasteboard.general
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
        if let blob = item.blobFile { try? FileManager.default.removeItem(at: dir.appending(path: blob)) }
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
            try? FileManager.default.removeItem(at: dir.appending(path: item.blobFile!))
        }
        items.removeAll { !$0.pinned }
        persist()
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
            try? FileManager.default.removeItem(at: dir.appending(path: item.blobFile!))
        }
        items.removeAll { victimIDs.contains($0.id) }
    }

    private func persist() {
        do {
            let json = try JSONEncoder().encode(items)
            let sealed = try ClipboardCrypto.encrypt(json)
            try sealed.write(to: indexURL, options: .atomic)
            protect(indexURL)
        } catch {
            NSLog("prosper: clipboard index write failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let raw = try? Data(contentsOf: indexURL) else { return }
        // Encrypted index (current) → fall back to legacy plaintext JSON written
        // by pre-encryption builds; either way decode, then re-persist so the
        // index lands back encrypted on the next write.
        let json = ClipboardCrypto.decryptOrPlaintext(raw)
        guard let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: json) else { return }
        items = decoded
        sort()
    }

    // MARK: - Encrypted blob I/O

    /// Writes `data` to `name` inside the store dir, marking the file for complete
    /// at-rest protection. Small payloads are AES-GCM encrypted; larger ones are
    /// written as-is (`encrypt: false`) to skip the in-memory ciphertext copy that
    /// sealing a big blob would require — the read path (`decryptOrPlaintext`)
    /// handles either form transparently, so both still restore. Returns false on
    /// failure.
    private func writeBlob(_ data: Data, to name: String, encrypt: Bool) -> Bool {
        do {
            let payload = encrypt ? try ClipboardCrypto.encrypt(data) : data
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
    private func readBlob(_ name: String) -> Data? {
        guard let raw = try? Data(contentsOf: dir.appending(path: name)) else { return nil }
        return ClipboardCrypto.decryptOrPlaintext(raw)
    }

    /// Best-effort OS-level file protection (encrypted at rest while locked),
    /// matching the typing-history store.
    private func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    /// Re-applies the (possibly lowered) retention cap after the user changes it
    /// in Settings, evicting now-excess entries immediately.
    func applyMaxItemsChange() {
        evictIfNeeded()
        persist()
    }

    private static func textPreview(_ s: String, limit: Int = 140) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    // MARK: - Content classification (Raycast parity)

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Classifies a string into a textual sub-kind. Order: color → link / email
    /// (a single detector match spanning the whole trimmed string) → plain text.
    static func classify(_ raw: String) -> ClipboardKind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .text }
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
    static func isColor(_ s: String) -> Bool {
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
