import Foundation

/// #1456 (OQ-153): "My Ghostty theme" takes colours only from the user's Ghostty config. The file is a trust
/// boundary: it is read line by line, only the allowlisted colour keys are kept, each value is checked, and
/// nothing else (keybinds, clipboard, shell, command, config-file includes...) ever reaches libghostty.
enum GhosttyUserColours {
    static let keys: Set<String> = ["theme", "palette", "background", "foreground", "cursor-color", "cursor-text",
                                    "selection-background", "selection-foreground", "bold-color"]
    static let maxBytes = 256 * 1024, maxLines = 5000, maxKept = 512

    /// Where Ghostty looks on macOS, in its load order (a later file wins): the XDG file, then Application Support.
    static func files(home: URL, xdgConfigHome: String?) -> [URL] {
        let xdg = xdgConfigHome.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".config")
        let dirs = [xdg.appendingPathComponent("ghostty"), home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")]
        return dirs.flatMap { [$0.appendingPathComponent("config"), $0.appendingPathComponent("config.ghostty")] }
    }

    /// The kept `(key, value)` pairs of every file that reads, capped; a missing, unreadable or oversized file adds none.
    static func read(_ files: [URL]) -> [(key: String, value: String)] {
        var kept: [(key: String, value: String)] = []
        for url in files {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            guard let data = try? h.read(upToCount: maxBytes + 1), data.count <= maxBytes,
                  let text = String(data: data, encoding: .utf8) else { continue }
            kept += lines(text)
        }
        return Array(kept.prefix(maxKept))
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
    static func isLightDarkThemes(_ v: String) -> Bool {
        let parts = v.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return false }
        let sides = parts.compactMap { p -> (String, String)? in
            guard let c = p.firstIndex(of: ":") else { return nil }
            return (String(p[..<c]), p[p.index(after: c)...].trimmingCharacters(in: .whitespaces))
        }
        return sides.count == 2 && Set(sides.map(\.0)) == ["light", "dark"] && sides.allSatisfy { isThemeName($0.1) }
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}
