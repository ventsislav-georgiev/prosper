import Foundation

/// Fetches metadata for a Hugging Face model from a URL or `owner/name` id, so the
/// AI Models pane can name + size a user-added custom agent model without the user
/// typing those by hand. Best-effort: it confirms the repo is an MLX checkpoint
/// (`*.safetensors` present) and sums the download size; whether it actually *loads*
/// is only known when the agent first runs it (architecture support varies).
enum HFModelImporter {
    struct Imported: Equatable {
        let id: String              // canonical "owner/name"
        let label: String           // derived display name
        let sizeBytes: Int64        // summed *.safetensors size (0 if unknown)
        let toolFormat: ToolCallFormat
    }

    enum ImportError: LocalizedError {
        case badURL
        case notFound
        case notMLX
        case network(String)

        var errorDescription: String? {
            switch self {
            case .badURL:   return "Enter a Hugging Face model URL or an owner/name id."
            case .notFound: return "That model wasn't found on Hugging Face (check the URL)."
            case .notMLX:   return "No .safetensors weights found — this isn't an MLX-format model. Look for an `mlx-community` (or other MLX) conversion."
            case .network(let m): return "Couldn't reach Hugging Face: \(m)"
            }
        }
    }

    /// Parse `owner/name` out of a HF URL or a bare id. Returns nil if it can't.
    static func repoId(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Strip scheme + host if a full URL was pasted.
        if let r = s.range(of: "huggingface.co/", options: .caseInsensitive) {
            s = String(s[r.upperBound...])
        } else if s.contains("://") {
            return nil // some other URL
        }
        // Drop query/fragment and any /tree/... /blob/... suffix.
        s = s.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? s
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Guess a model's tool-call syntax from its id (same families as the built-in
    /// catalog). Defaults to Qwen XML — the most common MLX agent format. The user can
    /// correct it in the add sheet.
    static func guessToolFormat(_ id: String) -> ToolCallFormat {
        let l = id.lowercased()
        if l.contains("qwen") || l.contains("mimo") { return .qwenXML }
        if l.contains("gpt-oss") || l.contains("harmony") { return .harmony }
        if l.contains("mistral") || l.contains("devstral") { return .mistral }
        if l.contains("nemotron") { return .nemotron }
        if l.contains("glm") { return .glm }
        if l.contains("kimi") { return .kimi }
        if l.contains("minimax") { return .minimax }
        return .qwenXML
    }

    /// Human display name from the repo name: "mlx-community/Qwen3-8B-4bit-DWQ" → "Qwen3 8B 4bit DWQ".
    static func deriveLabel(_ id: String) -> String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        return name.replacingOccurrences(of: "-", with: " ")
                   .replacingOccurrences(of: "_", with: " ")
    }

    /// One sibling file in the HF model index. `?blobs=true` adds `size` / `lfs.size`.
    private struct Sibling: Decodable {
        let rfilename: String
        let size: Int64?
        struct LFS: Decodable { let size: Int64? }
        let lfs: LFS?
    }
    private struct ModelInfo: Decodable { let siblings: [Sibling]? }

    static func fetch(_ input: String,
                      session: URLSession = .shared) async throws -> Imported {
        guard let id = repoId(from: input) else { throw ImportError.badURL }
        guard let url = URL(string: "https://huggingface.co/api/models/\(id)?blobs=true") else {
            throw ImportError.badURL
        }
        // Bounded so a stalled network can't leave "Fetching…" spinning for 60s (default).
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw ImportError.network(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 404 { throw ImportError.notFound }
            // 401 (gated), 429 (rate-limited), 5xx, or an HTML error page would otherwise
            // fall through to a JSON decode failure reported as the misleading "not found".
            guard (200..<300).contains(http.statusCode) else {
                throw ImportError.network("HTTP \(http.statusCode)")
            }
        }
        guard let info = try? JSONDecoder().decode(ModelInfo.self, from: data),
              let siblings = info.siblings else { throw ImportError.notFound }

        let weights = siblings.filter { $0.rfilename.hasSuffix(".safetensors") }
        guard !weights.isEmpty else { throw ImportError.notMLX }
        let total = weights.reduce(Int64(0)) { $0 + ($1.lfs?.size ?? $1.size ?? 0) }

        return Imported(id: id,
                        label: deriveLabel(id),
                        sizeBytes: total,
                        toolFormat: guessToolFormat(id))
    }
}
