import Foundation

/// Agent personas: selectable system-prompt presets (like opencode's plan/build
/// agents). Two are built in; users can drop more as markdown files in
/// `~/.config/prosper/agents/<id>.md` — first `# Heading` line (if any) is the
/// display title, the rest is the system prompt appended to the agent's
/// developer instructions. The selected persona id lives in `Preferences.agentPersona`.
struct AgentPersona: Identifiable, Equatable {
    let id: String
    let title: String
    let prompt: String
    let isBuiltIn: Bool
}

enum AgentPersonaStore {
    /// `~/.config/prosper/agents`.
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/prosper/agents", isDirectory: true)
    }

    /// The two shipped personas. `build` carries no extra prompt (the agent's
    /// default behavior); `plan` constrains it to investigate-and-propose.
    static let builtIns: [AgentPersona] = [
        AgentPersona(id: "build", title: "Build", prompt: "", isBuiltIn: true),
        AgentPersona(id: "plan", title: "Plan", prompt: """
        You are in PLAN mode. Investigate the request and produce a concrete, \
        step-by-step plan. Do NOT modify files, create commits, or run mutating \
        commands — read-only exploration only. End with the proposed plan for the \
        user to approve before any changes are made.
        """, isBuiltIn: true)
    ]

    /// Built-ins first, then custom personas sorted by title. Custom files whose id
    /// collides with a built-in override the built-in.
    static func all() -> [AgentPersona] {
        var byID: [String: AgentPersona] = [:]
        for p in builtIns { byID[p.id] = p }
        for p in custom() { byID[p.id] = p }
        let builtInOrder = builtIns.map(\.id)
        return byID.values.sorted {
            let a = builtInOrder.firstIndex(of: $0.id) ?? Int.max
            let b = builtInOrder.firstIndex(of: $1.id) ?? Int.max
            return a != b ? a < b : $0.title < $1.title
        }
    }

    static func persona(for id: String) -> AgentPersona? {
        all().first { $0.id == id }
    }

    /// The system-prompt text for the selected persona (empty when none/built-in build).
    static func prompt(for id: String) -> String {
        persona(for: id)?.prompt ?? ""
    }

    // MARK: - Custom personas (files)

    private static func custom() -> [AgentPersona] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.compactMap { name in
            let id = String(name.dropLast(3))
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            else { return nil }
            return AgentPersona(id: id, title: title(from: text, fallback: id),
                                prompt: body(from: text), isBuiltIn: false)
        }
    }

    /// `# Heading` first line → title; otherwise the id.
    private static func title(from text: String, fallback: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if first.hasPrefix("# ") { return String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return fallback
    }

    private static func body(from text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.hasPrefix("# ") == true { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Mutation

    static func bootstrap() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Write/overwrite a custom persona. `id` is sanitized to a filename-safe slug.
    @discardableResult
    static func save(id: String, title: String, prompt: String) -> String {
        bootstrap()
        let slug = sanitize(id)
        let text = "# \(title)\n\n\(prompt)\n"
        try? text.write(to: dir.appendingPathComponent("\(slug).md"), atomically: true, encoding: .utf8)
        return slug
    }

    static func delete(id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sanitize(id)).md"))
    }

    /// Lowercase, spaces→`-`, strip anything outside [a-z0-9-_].
    static func sanitize(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: " ", with: "-")
        let kept = lowered.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return kept.isEmpty ? "persona" : kept
    }
}
