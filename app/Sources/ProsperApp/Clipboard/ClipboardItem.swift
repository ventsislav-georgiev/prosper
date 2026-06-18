import Foundation

/// Kind of a captured clipboard entry.
///
/// `text` payloads are further classified at capture time into `link`, `email`,
/// and `color` (Raycast-parity content typing). All four are stored as text
/// blobs on disk and copy back as plain strings — the kind only drives the icon,
/// the preview rendering, and the type filter.
enum ClipboardKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case file
    case link
    case email
    case color

    /// Kinds whose payload is a text blob (so they read/copy as a string).
    static let textual: Set<ClipboardKind> = [.text, .link, .email, .color]

    var isTextual: Bool { Self.textual.contains(self) }
}

/// Metadata for one clipboard-history entry. The heavy payload (full text,
/// image PNG, or the referenced file path) lives on disk; this index record
/// stays small so very large clips never bloat memory.
struct ClipboardItem: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let kind: ClipboardKind
    let createdAt: Date
    /// Short human preview: text snippet, "Image 1920×1080", or a filename.
    let preview: String
    /// Total byte size of the payload (text bytes / image bytes / file size).
    let byteCount: Int
    /// On-disk blob filename for textual/image payloads (under the store dir).
    let blobFile: String?
    /// Absolute source path for `file` entries (referenced, not copied).
    let sourcePath: String?
    /// Original filename for `file` entries.
    let fileName: String?
    /// Pinned entries sort to the top and survive history eviction.
    var pinned: Bool
    /// Optional user-supplied title (⌘E rename); falls back to `preview`.
    var title: String?

    init(id: UUID, kind: ClipboardKind, createdAt: Date, preview: String,
         byteCount: Int, blobFile: String?, sourcePath: String?, fileName: String?,
         pinned: Bool = false, title: String? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.preview = preview
        self.byteCount = byteCount
        self.blobFile = blobFile
        self.sourcePath = sourcePath
        self.fileName = fileName
        self.pinned = pinned
        self.title = title
    }

    /// Display title: the user-renamed title if set, else the preview.
    var displayTitle: String { (title?.isEmpty == false) ? title! : preview }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool { lhs.id == rhs.id }
}

extension ClipboardItem {
    /// Backward-compatible decode: `pinned`/`title` were added later, so old
    /// `index.json` records lack them — default rather than fail the whole load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ClipboardKind.self, forKey: .kind)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        preview = try c.decode(String.self, forKey: .preview)
        byteCount = try c.decode(Int.self, forKey: .byteCount)
        blobFile = try c.decodeIfPresent(String.self, forKey: .blobFile)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }
}
