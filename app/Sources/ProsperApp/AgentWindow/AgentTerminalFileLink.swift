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

    /// #1724: a link-shaped token on a viewport line: its text and its cells (a wide character takes two).
    struct Token: Equatable {
        let text: String
        let col: Int
        let cells: Int
    }

    /// Extensions a bare name needs to count as a path ("CHANGELOG.md"); a name with a "/" needs none.
    static let textExtensions: Set<String> = TextViewerRouting.markdownExtensions.union([
        "txt", "log", "json", "jsonl", "toml", "yaml", "yml", "xml", "csv", "ini", "conf", "env", "diff", "patch", "sql",
        "swift", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "sh", "zsh", "c", "h", "cpp", "java", "kt", "css",
    ])
    private static let opening = CharacterSet(charactersIn: "([{<'\"`\u{2018}\u{201C}")
    private static let closing = trailing.union(CharacterSet(charactersIn: "}>`"))
    private static let pathChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/~+@%:_"))

    /// #1724: the link under grid column `col` of a viewport line, by shape only (no disk): a web, mail or file URL, or a
    /// path (a "/" in it, or a name with a known text extension), quotes and trailing punctuation off. Nil on prose. Pure.
    static func token(atColumn col: Int, in line: String) -> Token? {
        guard col >= 0 else { return nil }
        var n = 0, lo = line.startIndex, loCol = 0, hi = line.endIndex
        for i in line.indices {
            let w = XrayRefSpans.cells(line[i...i])
            if line[i].isWhitespace {
                if n > col { hi = i; break }   // the word before this space covers col (or col was a space: loCol > col)
                (lo, loCol) = (line.index(after: i), n + w)
            }
            n += w
        }
        while lo < hi, let u = line[lo].unicodeScalars.first, opening.contains(u) {
            loCol += XrayRefSpans.cells(line[lo...lo]); lo = line.index(after: lo)
        }
        while lo < hi, let u = line[line.index(before: hi)].unicodeScalars.last, closing.contains(u) { hi = line.index(before: hi) }
        let text = String(line[lo..<hi]), cells = XrayRefSpans.cells(line[lo..<hi])
        guard col >= loCol, col < loCol + cells, shaped(text) else { return nil }
        return Token(text: text, col: loCol, cells: cells)
    }

    /// A URL, a rooted path, a path with an extension in its last name, or a bare name with a known text extension.
    static func shaped(_ t: String) -> Bool {
        let l = t.lowercased()
        for p in ["http://", "https://", "file://", "mailto:"] where l.hasPrefix(p) { return l.count > p.count }
        guard t.unicodeScalars.allSatisfy(pathChars.contains), t.contains(where: \.isLetter), !t.contains("//") else { return false }
        let name = t.replacingOccurrences(of: #"(:\d+){1,2}$"#, with: "", options: .regularExpression)
        let last = (name as NSString).lastPathComponent, ext = (last as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, last.count > ext.count + 1 else {   // no extension: only a rooted path ("and/or" is prose)
            return ["/", "~/", "./", "../"].contains { name.hasPrefix($0) } && !name.hasSuffix("/")
        }
        return name.contains("/") || textExtensions.contains(ext)
    }

    static func isViewable(_ url: URL) -> Bool {
        let real = url.resolvingSymlinksInPath()
        guard let v = try? real.resourceValues(forKeys: [.isRegularFileKey]), v.isRegularFile == true,
              !FileManager.default.isExecutableFile(atPath: real.path) else { return false }
        return TextViewerRouting.isDocument(real)   // the target decides, never the link name (QA s1)
    }
}
