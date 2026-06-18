import Foundation

/// Custom slash-commands. Each is a markdown file in
/// `~/.config/prosper/commands/<name>.md`; its body is a prompt template. Typing
/// `/<name> [args]` in the chat composer expands to the body, with `$ARGUMENTS`
/// substituted (or the args appended if the template has no placeholder).
struct SlashCommand: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let body: String
}

enum CommandStore {
    /// `~/.config/prosper/commands`.
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/prosper/commands", isDirectory: true)
    }

    static func all() -> [SlashCommand] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.compactMap { file in
            let name = String(file.dropLast(3))
            guard let body = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            else { return nil }
            return SlashCommand(name: name, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted { $0.name < $1.name }
    }

    /// If `draft` starts with `/<name>` matching a stored command, return the expanded
    /// prompt; otherwise nil (leave the draft untouched). The leading word after `/`
    /// is the command; the remainder is `$ARGUMENTS`.
    static func expand(_ draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return nil }
        let afterSlash = trimmed.dropFirst()
        let parts = afterSlash.split(separator: " ", maxSplits: 1).map(String.init)
        guard let name = parts.first, !name.isEmpty,
              let cmd = all().first(where: { $0.name == name }) else { return nil }
        let argsText = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        if cmd.body.contains("$ARGUMENTS") {
            return cmd.body.replacingOccurrences(of: "$ARGUMENTS", with: argsText)
        }
        return argsText.isEmpty ? cmd.body : "\(cmd.body)\n\n\(argsText)"
    }

    static func bootstrap() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    static func save(name: String, body: String) -> String {
        bootstrap()
        let slug = sanitize(name)
        try? body.write(to: dir.appendingPathComponent("\(slug).md"), atomically: true, encoding: .utf8)
        return slug
    }

    static func delete(name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sanitize(name)).md"))
    }

    static func sanitize(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: " ", with: "-")
        let kept = lowered.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return kept.isEmpty ? "command" : kept
    }
}
