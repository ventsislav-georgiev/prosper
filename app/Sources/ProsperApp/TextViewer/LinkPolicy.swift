import Foundation

// #1118 (design #1105 D6, rider R4): the one rule for every link in a rendered document. A document
// is untrusted input. Pure: it reads no file and no setting, so the renderer asks it about every link
// without touching the disk (a link to /net/... is never stat'ed: that would automount).

enum LinkPolicy {
    enum Action: Hashable {
        /// http, https, mailto: the user's default browser or mail app, on a click only.
        case open(URL)
        /// A text document (a script too, R4): another viewer window in Read mode, never run.
        case view(URL)
        /// "#fragment": scroll to the heading with that GitHub-style slug.
        case scroll(String)
        /// Any other local target: selected in Finder, never opened.
        case reveal(URL)
        /// Every other scheme, a host on a file link, a control character, an encoded slash: plain text.
        case none
    }

    /// The action for `link` in the document at `document` (relative links resolve against its folder).
    nonisolated static func action(_ link: URL, document: URL) -> Action {
        let raw = link.absoluteString
        guard !hasControl(raw), !hasControl(raw.removingPercentEncoding ?? raw) else { return .none }
        let host = link.host ?? ""
        switch link.scheme.map(asciiLowercased) {
        case "http"?, "https"?: return host.isEmpty ? .none : .open(link)
        case "mailto"?: return .open(link)
        case "file"?: return host.isEmpty ? local(link, raw: raw, document: document) : .none
        case nil:
            guard host.isEmpty else { return .none }   // "//host/x" names another machine
            if raw.hasPrefix("#") { return .scroll(String(raw.dropFirst()).removingPercentEncoding?.lowercased() ?? "") }
            return local(link, raw: raw, document: document)
        default: return .none
        }
    }

    /// A path on this Mac: a text document is viewed, anything else revealed. Decided by the name
    /// only, so an extensionless target (a folder, LICENSE) is revealed and never stat'ed.
    private nonisolated static func local(_ link: URL, raw: String, document: URL) -> Action {
        let path = link.path
        // An encoded slash would split one name into two folders after decoding.
        // When "%FF" makes decoding the whole link fail, URL.path is "" (macOS 27, Round 2 fact): refused
        // as empty. The decoded path is checked for controls too, should another Foundation decode it.
        guard !path.isEmpty, !hasControl(path), raw.range(of: "%2f", options: .caseInsensitive) == nil else { return .none }
        let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path)
                      : document.deletingLastPathComponent().appendingPathComponent(path)).standardizedFileURL
        if !target.pathExtension.isEmpty, TextViewerRouting.isDocument(target) { return .view(target) }
        return .reveal(target)
    }

    /// C0, DEL and C1 controls: never part of a link a person meant (a tab or newline spoofs the
    /// tooltip and splits a scheme).
    nonisolated static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// Lowercases A-Z by byte range only (never the locale's rules).
    nonisolated static func asciiLowercased(_ s: String) -> String {
        String(decoding: s.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }
}
