import Foundation

/// #1456 (OQ-153): "My Ghostty theme" takes colours only from the user's Ghostty config. The file is a trust
/// boundary: it is read line by line, only the allowlisted colour keys are kept, each value is checked, and
/// nothing else (keybinds, clipboard, shell, command, config-file includes...) ever reaches libghostty.
/// QA r1418 m1: a `theme` line never reaches libghostty either (a theme file is a whole Ghostty config, mostly
/// downloaded): Prosper resolves the theme by its checked name and keeps only that file's colour lines.
enum GhosttyUserColours {
    static let keys: Set<String> = ["theme", "palette", "background", "foreground", "cursor-color", "cursor-text",
                                    "selection-background", "selection-foreground", "bold-color", "window-colorspace"]
    static let maxBytes = 256 * 1024, maxLines = 5000, maxKept = 512

    /// Where Ghostty looks on macOS, in its load order (a later file wins): the XDG file, then Application Support.
    static func files(home: URL, xdgConfigHome: String?) -> [URL] {
        let dirs = [ghosttyDir(home: home, xdgConfigHome: xdgConfigHome),
                    home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")]
        return dirs.flatMap { [$0.appendingPathComponent("config"), $0.appendingPathComponent("config.ghostty")] }
    }

    /// `$XDG_CONFIG_HOME/ghostty` when that is absolute, else `<home>/.config/ghostty`.
    static func ghosttyDir(home: URL, xdgConfigHome: String?) -> URL {
        (xdgConfigHome.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } ?? home.appendingPathComponent(".config"))
            .appendingPathComponent("ghostty")
    }

    static let bundledThemes = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes")

    /// Where a theme name is looked up, first hit wins: the user's themes folder, then Ghostty.app's bundled ones.
    static func themeDirs(home: URL, xdgConfigHome: String?, bundled: URL = bundledThemes) -> [URL] {
        [ghosttyDir(home: home, xdgConfigHome: xdgConfigHome).appendingPathComponent("themes"), bundled]
    }

    /// The kept `(key, value)` pairs of every file that reads, capped; a missing, unreadable or oversized file adds none.
    /// The last `theme` value (Ghostty's rule) is resolved in `themeDirs` and its file's colour lines go first, so the
    /// config's own colour lines win; the output never holds a `theme` pair.
    static func read(_ files: [URL], themeDirs: [URL] = [], appearance: ThemeAppearance = .dark) -> [(key: String, value: String)] {
        var kept: [(key: String, value: String)] = []
        var theme: String?
        for url in files {
            guard let text = readText(url) else { continue }
            for pair in lines(text) {
                if pair.key == "theme" { theme = pair.value } else { kept.append(pair) }
            }
        }
        let themed = theme.flatMap { themeLines($0, in: themeDirs, appearance: appearance) } ?? []
        return Array((themed + kept).prefix(maxKept))
    }

    /// The colour lines of the named theme's file (light:A,dark:B picks the side by Prosper's appearance), minus any
    /// `theme` line of its own (no recursion); nil when the name is refused or no dir holds a readable file.
    static func themeLines(_ value: String, in dirs: [URL], appearance: ThemeAppearance) -> [(key: String, value: String)]? {
        guard let name = isThemeName(value) ? value : lightDarkSides(value)?[appearance == .light ? "light" : "dark"],
              isThemeName(name) else { return nil }
        for dir in dirs {
            if let text = readText(dir.appendingPathComponent(name)) { return lines(text).filter { $0.key != "theme" } }
        }
        return nil
    }

    /// A regular file's text, capped. QA r1418 s1: opened non-blocking and checked with fstat, so a FIFO or tty at a
    /// config path is refused at once instead of hanging the main thread (links are followed: dotfile managers use them).
    static func readText(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maxBytes + 1),
              data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The pure filter: Ghostty config text in, only valid allowlisted colour lines out, in file order.
    static func lines(_ text: String) -> [(key: String, value: String)] {
        var kept: [(key: String, value: String)] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).prefix(maxLines) {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
            var value = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard keys.contains(key), valid(key, value) else { continue }
            kept.append((key, value))
            if kept.count == maxKept { break }
        }
        return kept
    }

    static func valid(_ key: String, _ value: String) -> Bool {
        switch key {
        case "theme": return isThemeName(value) || isLightDarkThemes(value)
        // #1752: how Ghostty reads every colour value (display-p3 draws them as P3, more saturated than sRGB).
        case "window-colorspace": return value == "srgb" || value == "display-p3"
        case "palette":
            let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, (1...3).contains(parts[0].count), parts[0].allSatisfy(\.isASCIIDigit),
                  let n = Int(parts[0]), (0...255).contains(n) else { return false }
            return isHex(String(parts[1]))
        default: return isHex(value) || isColourName(value)
        }
    }

    static func isHex(_ v: String) -> Bool {
        v.count == 7 && v.hasPrefix("#") && v.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// An X11 colour name ("red", "dark slate gray") or a cursor keyword ("cell-foreground"); libghostty refuses an unknown one.
    static func isColourName(_ v: String) -> Bool {
        (1...40).contains(v.count) && v.first?.isASCIILetter == true && v.allSatisfy { $0.isASCIILetter || $0 == " " || $0 == "-" }
    }

    /// A theme by name only: a path (any "/" or "..") would make libghostty load an arbitrary file as a theme.
    static func isThemeName(_ v: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _+.-")
        guard (1...80).contains(v.count), v.allSatisfy(allowed.contains), !v.contains("/"), !v.contains("..") else { return false }
        return true
    }

    /// Ghostty's `light:A,dark:B` form, both names checked.
    static func isLightDarkThemes(_ v: String) -> Bool { lightDarkSides(v) != nil }

    /// ["light": A, "dark": B] for exactly that form (either order), both names checked; nil otherwise.
    static func lightDarkSides(_ v: String) -> [String: String]? {
        let parts = v.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        let sides = parts.compactMap { p -> (String, String)? in
            guard let c = p.firstIndex(of: ":") else { return nil }
            return (String(p[..<c]), p[p.index(after: c)...].trimmingCharacters(in: .whitespaces))
        }
        guard sides.count == 2, Set(sides.map(\.0)) == ["light", "dark"], sides.allSatisfy({ isThemeName($0.1) }) else { return nil }
        return Dictionary(uniqueKeysWithValues: sides)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
