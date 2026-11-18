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

/// #919 S3: why a downloaded package is not installed against its Marketplace listing. Each is a refusal of what was
/// downloaded, except `versionMovedOn` (the listing changed during the install: a later try can pass).
enum KitListingRefusal: Equatable, Sendable {
    case kitListedAsOther          // the archive is a kit, the listing is not of kind "kit"
    case listedKitNotKit           // the listing is a kit, the archive is not
    case versionMovedOn            // the listing's version is no longer the one downloaded
    case notActive                 // the listing is withdrawn
    case noPreview                 // the listing has no kit preview to check against
    case validator(String)         // the kit validator refused the archive (its reasons, joined)
    case previewMismatch           // the archive's summary or README differs from what the listing shows

    var isRefusal: Bool { self != .versionMovedOn }

    var sentence: String {
        switch self {
        case .kitListedAsOther: return "the package is an agent kit, but the Marketplace does not list it as one."
        case .listedKitNotKit: return "the Marketplace lists an agent kit, but the package is not one."
        case .versionMovedOn: return "the Marketplace listing changed while it was downloading. Try again."
        case .notActive: return "the Marketplace no longer offers this version."
        case .noPreview: return "the Marketplace listing has no kit preview to check the package against."
        case .validator(let why): return "the kit is refused: " + why
        case .previewMismatch: return "the package does not match what its Marketplace listing shows."
        }
    }
}

enum KitListingCheck {
    /// nil when the downloaded package (`tarballKit`: its validation, nil = not a kit; `readme`: its README text) may be
    /// installed against `listing`, fetched after the download of `version`. A kit must be listed as a kit at that
    /// version, active, with a preview equal (summary and README) to the one recomputed from the archive.
    static func verify(tarballKit: KitValidation?, readme: String, listing: MarketClient.PackageDetail,
                       version: String) -> KitListingRefusal? {
        let listedKit = listing.kind == "kit"
        guard let tarballKit else { return listedKit ? .listedKitNotKit : nil }
        guard listedKit else { return .kitListedAsOther }
        guard listing.latest_version == version else { return .versionMovedOn }
        guard listing.status == "active" else { return .notActive }
        guard let shown = listing.preview?.kit else { return .noPreview }
        switch tarballKit {
        case .refused(let why):
            return .validator(OutsideText.shown(why.map(\.description).joined(separator: "; "), max: 400))
        case .ok(let v):
            return KitListingPreview.make(v, readme: readme) == shown ? nil : .previewMismatch
        }
    }
}
