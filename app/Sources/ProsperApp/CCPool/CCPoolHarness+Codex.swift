import Foundation

/// #2005 (design #2003, phase 2): Codex in ChatGPT mode against chatgpt.com/backend-api/codex, auth and upstream only.
/// A request under `/codex` uses it; Claude stays at the root. Limits, claims, pins, the usage tap and prices are Phase 3.
struct CCPoolCodexHarness: PoolHarness {
    static let id = "codex"
    /// The one login kind Phase 2 routes (the operator ruled out API-key accounts).
    static let chatgptKind = "codex-chatgpt"
    static let upstream = URL(string: "https://chatgpt.com/backend-api/codex")!
    static let pathPrefix = "/codex"
    /// Today's set plus the client's OpenAI credential and account headers. originator, version, session_id,
    /// OpenAI-Beta and User-Agent pass through untouched.
    static let stripRequest = ClaudeHarness.stripRequest.union(["chatgpt-account-id", "openai-organization", "openai-project", "cookie"])

    /// The path (and query) under the Codex upstream when `path` is `/codex` or under `/codex/` (or `/codex?...`),
    /// else nil: the request is not Codex's.
    static func rest(of path: String) -> String? {
        guard path.hasPrefix(pathPrefix) else { return nil }
        let rest = String(path.dropFirst(pathPrefix.count))
        return rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("?") ? rest : nil
    }

    /// The Keychain item of a `codex-chatgpt` account (design section 4); Phase 2 reads only these two fields.
    /// Never logged or described.
    private struct ChatGPTItem: Decodable {
        let access_token: String
        let account_id: String
    }

    var id: String { Self.id }
    var upstream: URL { Self.upstream }
    var stripRequest: Set<String> { Self.stripRequest }
    // shortcut: P2 stub, Phase 3 (#2006) fills it
    var displayOrder: [String] { [] }
    // shortcut: P2 stub, Phase 3 (#2006) fills it
    var display: [String: String] { [:] }
    // shortcut: P2 stub, Phase 3 (#2006) fills it
    var prices: [(family: String, input: Double, output: Double, read: Double)] { [] }
    // shortcut: P2 stub, Phase 6 routes codex sessions by argv (design section 9); nothing reads this rule yet
    var env: (key: String, programs: Set<String>) { ("", []) }

    func accepts(kind: String?) -> Bool { kind == Self.chatgptKind }

    /// False (nothing set) for an item that does not decode or lacks either field: the caller skips the account as
    /// it does a missing token, so no empty or raw bearer goes out.
    func authorize(_ req: inout URLRequest, token: String) -> Bool {
        guard let item = try? JSONDecoder().decode(ChatGPTItem.self, from: Data(token.utf8)),
              !item.access_token.isEmpty, !item.account_id.isEmpty else { return false }
        req.setValue("Bearer \(item.access_token)", forHTTPHeaderField: "Authorization")
        req.setValue(item.account_id, forHTTPHeaderField: "chatgpt-account-id")
        return true
    }

    // shortcut: P2 stub, Phase 3 (#2006) fills it
    func parseLimits(_ headers: [String: String]) -> (limits: [String: CCPoolLimit], unknown: [String]) { ([:], []) }
    // shortcut: P2 stub, Phase 3 (#2006) fills it (no claims: eligibility rests on holds and refusal only)
    func claims(for model: String?) -> [String] { [] }
    // shortcut: P2 stub, Phase 3 (#2006) fills it
    func isKnownModel(_ model: String?) -> Bool { false }
    // shortcut: P2 stub, Phase 3 (#2006) fills it
    func pinKey(_ head: CCPoolRequestHead) -> String? { nil }
    // shortcut: P2 stub, Phase 3 (#2006) fills it (an idle tap: no Anthropic parsing of an OpenAI stream)
    func usageTap(contentType: String?) -> CCPoolUsageTap { .idle }
    // shortcut: P2 stub, Phase 3 (#2006) fills it
    func isQuotaCheck(_ obj: [String: Any]?) -> Bool { false }
    // shortcut: P2 stub, Phase 7 adds the wham/usage probe
    func probe(token: String, base: URL, timeout: TimeInterval) async -> CCPoolUsage.Probe? { nil }
}
