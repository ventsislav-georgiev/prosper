import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// #1118 (design #1105 D7, section 3 C2 and N5): which images a document may draw. A document is
// untrusted input: no network, nothing outside the document's own folder tree, nothing that is not a
// regular raster file of at most 20 MiB, and no decode larger than the header says is safe.

/// The renderer's image loader (a seam: tests record every request). Called off the main thread,
/// only for a local image (`ImagePolicy.isLocal`); a remote image never reaches it.
typealias TextViewerImageLoader = @Sendable (_ source: URL, _ document: URL, _ maxPixelSize: Int) -> CGImage?

enum ImagePolicy {
    static let maxBytes = 20 << 20
    /// Width x height from the header, checked before any decode: ImageIO decodes a PNG whole before
    /// it scales, and a small file can claim 100,000 x 100,000 pixels.
    static let maxSourcePixels = 64 << 20
    static let maxSymlinkHops = 32
    /// D7's raster types; a PDF, an SVG or an icon file is refused whatever its name says.
    nonisolated static let rasterTypes: Set<String> = Set([UTType.png, .jpeg, .gif, .heic, .heif, .tiff, .webP, .bmp].map(\.identifier))

    /// A relative path or a host-less file URL. Anything else (http, data:, //host/x) is remote and
    /// never loaded.
    nonisolated static func isLocal(_ src: URL) -> Bool {
        guard (src.host ?? "").isEmpty else { return false }
        return src.scheme.map { LinkPolicy.asciiLowercased($0) == "file" } ?? true
    }

    /// The live loader: the image inside the tree, regular, at most 20 MiB, a raster type within the
    /// pixel cap, decoded as a thumbnail at most `maxPixelSize` on its long side. Nil for anything else.
    nonisolated static func load(_ src: URL, document: URL, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, let path = inside(src, document: document) else { return nil }
        // O_NONBLOCK: a FIFO never blocks the open; O_NOFOLLOW: no symlink swapped in after the walk.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_size > 0, st.st_size <= Int64(maxBytes),
              let data = TextViewerDocument.readAll(fd, size: Int(st.st_size)) else { return nil }
        return decode(data, maxPixelSize: maxPixelSize)
    }

    /// Bytes to a capped thumbnail: the type and the pixel size come from the header first.
    nonisolated static func decode(_ data: Data, maxPixelSize: Int, maxSourcePixels: Int = ImagePolicy.maxSourcePixels) -> CGImage? {
        let header = [kCGImageSourceShouldCache: false] as [CFString: Any] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, header),
              let type = CGImageSourceGetType(source) as String?, rasterTypes.contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, header) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let (pixels, overflow) = w.multipliedReportingOverflow(by: h)
        guard !overflow, pixels <= maxSourcePixels else { return nil }
        let thumb = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                     kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                     kCGImageSourceCreateThumbnailWithTransform: true,
                     kCGImageSourceShouldCacheImmediately: true] as [CFString: Any] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumb)
    }

    /// The path of `src` inside the document's folder tree, or nil. Lexical first: an absolute path
    /// elsewhere, a /net path or ../ out of the tree is refused before any file-system call. Then the
    /// path is walked from the tree's root one name at a time with lstat; a symlink's target is checked
    /// the same way before it is followed, so no call ever touches a path outside the tree.
    /// shortcut: an absolute symlink target must be spelled under the canonical root (realpath, e.g.
    /// /private/var/...); one spelled through another symlink (/var/...) is refused, the safe side.
    nonisolated static func inside(_ src: URL, document: URL) -> String? {
        let raw = src.absoluteString
        let rel = src.path
        guard isLocal(src), !rel.isEmpty, !LinkPolicy.hasControl(raw), !LinkPolicy.hasControl(rel),
              raw.range(of: "%2f", options: .caseInsensitive) == nil else { return nil }
        let folder = document.deletingLastPathComponent().path
        guard let canonical = realpath(folder, nil) else { return nil }
        let root = String(cString: canonical)
        free(canonical)
        let rootParts = parts(root)
        var pending: [Substring]
        if rel.hasPrefix("/") {
            // Absolute: only when it names a place under the folder (as opened, or canonical).
            let p = parts(rel)
            guard let base = [parts(folder), rootParts].first(where: { p.count > $0.count && p.starts(with: $0) })
            else { return nil }
            pending = Array(p.dropFirst(base.count))
        } else {
            pending = parts(rel)
        }
        pending.reverse()
        var at: [Substring] = []   // resolved names below the root
        var hops = 0
        while let name = pending.popLast() {
            if name == "." { continue }
            if name == ".." {
                guard !at.isEmpty else { return nil }   // out of the tree
                at.removeLast()
                continue
            }
            let path = "/" + (rootParts + at + [name]).joined(separator: "/")
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            guard st.st_mode & S_IFMT == S_IFLNK else { at.append(name); continue }
            hops += 1
            guard hops <= maxSymlinkHops, let target = readLink(path) else { return nil }
            if target.hasPrefix("/") {
                let t = parts(target)
                guard t.starts(with: rootParts) else { return nil }   // a link out of the tree
                at = []
                pending.append(contentsOf: t.dropFirst(rootParts.count).reversed())
            } else {
                pending.append(contentsOf: parts(target).reversed())   // relative to the link's folder
            }
        }
        return at.isEmpty ? nil : "/" + (rootParts + at).joined(separator: "/")
    }

    private nonisolated static func parts(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    private nonisolated static func readLink(_ path: String) -> String? {
        var buf = [UInt8](repeating: 0, count: Int(PATH_MAX))
        let n = buf.withUnsafeMutableBytes { readlink(path, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) }
        guard n > 0, n <= buf.count else { return nil }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }
}
