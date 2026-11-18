import Foundation

// #919 S2: what a kit's Marketplace listing shows before anyone installs it. Pure: the caller hands in a
// validated kit and its README text; nothing is read or written here.

struct KitListingPreview: Codable, Sendable, Equatable {
    var schema = 1
    var summary: [String]
    var readme: String

    static let readmeMaxBytes = 2048

    /// The "What will change" lines with placeholders for paths (no path of this Mac) and the README's first section.
    static func make(_ v: KitValidated, readme: String) -> KitListingPreview {
        KitListingPreview(summary: KitRender.summary(v, .listing(extensionID: v.extensionID), off: []),
                          readme: firstSection(readme))
    }

    /// The text before the first "## " heading; when that is blank, the first "## " section. Trimmed, then cut
    /// to `readmeMaxBytes` UTF-8 bytes on a character boundary.
    static func firstSection(_ readme: String) -> String {
        let lines = readme.components(separatedBy: "\n")
        let heads = lines.indices.filter { lines[$0].hasPrefix("## ") }
        let start = heads.first ?? lines.count
        var part = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if part.isEmpty, let h = heads.first {
            part = lines[h..<(heads.dropFirst().first ?? lines.count)].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = "", bytes = 0
        for ch in part {
            bytes += ch.utf8.count
            if bytes > readmeMaxBytes { break }
            out.append(ch)
        }
        return out
    }
}
