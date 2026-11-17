import Foundation

/// #1480: a file path in a terminal link (Cmd-click) opens in the Text Viewer, never in another app.
/// `resolve` is pure (text + the session's folder + a home seam -> a standardized file URL);
/// `isViewable` is the one disk check (an existing regular file, symlinks followed, a text document, not executable).
enum AgentTerminalFileLink {
    private static let trailing = CharacterSet(charactersIn: ".,;:)]'\"\u{2019}\u{201D}")

    static func resolve(_ link: String, cwd: String?, home: String) -> URL? {
        var text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("file:") {
            // URL.path decodes the percent-encoding once.
            guard let u = URL(string: text), u.isFileURL else { return nil }
            text = u.path
        }
        text = strip(text)
        if let r = text.range(of: #"(:\d+){1,2}$"#, options: .regularExpression) { text.removeSubrange(r) }
        text = strip(text)
        guard !text.isEmpty, !text.unicodeScalars.contains("\0") else { return nil }
        let path: String
        if text == "~" || text.hasPrefix("~/") {
            guard home.hasPrefix("/") else { return nil }
            path = home + text.dropFirst()
        } else if text.hasPrefix("/") {
            path = text
        } else {
            guard let cwd, cwd.hasPrefix("/") else { return nil }   // never Prosper's own folder
            path = cwd + "/" + text
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func strip(_ s: String) -> String {
        var t = Substring(s)
        while let l = t.unicodeScalars.last, trailing.contains(l) { t = t.dropLast() }
        return String(t)
    }

    static func isViewable(_ url: URL) -> Bool {
        let real = url.resolvingSymlinksInPath()
        guard let v = try? real.resourceValues(forKeys: [.isRegularFileKey]), v.isRegularFile == true,
              !FileManager.default.isExecutableFile(atPath: real.path) else { return false }
        return TextViewerRouting.isDocument(real)   // the target decides, never the link name (QA s1)
    }
}
