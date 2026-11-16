import AppKit
import SwiftUI

/// #923 (design rule 10): the sidebar "..." Diagnostics pane: the compat log for a bug report. Versions, tier counts
/// and the last parse errors only: no transcript content, no path, no session name.
enum AgentDiagnostics {
    static let menuLabel = "Diagnostics\u{2026}"

    /// The pane's text, which Copy puts on the pasteboard as is. `version`: the session's newest Claude Code version
    /// (nil: none read); `errors`: oldest first, as the assembler keeps them.
    static func text(prosper: String, dch: String, version: String?, counts: [String: TierCounts],
                     errors: [String]) -> String {
        let v = ClaudeCodeCompat.sanitized(version)
        let c = counts.values.reduce(TierCounts(), +)
        var lines = [
            "Prosper \(OutsideText.shown(prosper, max: 32))",
            "dch \(ClaudeCodeCompat.sanitized(dch))",
            "Claude Code tested: \(ClaudeCodeCompat.lower)-\(ClaudeCodeCompat.upper)",
            "Claude Code (session): \(v)\(ClaudeCodeCompat.isNewer(v) ? " (newer than tested)" : "")",
            "Tiers: specific=\(c.specific) generic=\(c.generic) degraded=\(c.degraded) failed=\(c.failed) hidden=\(c.hidden)",
            "Last parse errors:",
        ]
        let last = errors.suffix(TranscriptAssembler.maxParseErrors).reversed()
        lines += last.isEmpty ? ["  none"] : last.map { "  " + OutsideText.shown($0, max: 120) }
        return lines.joined(separator: "\n")
    }

    /// The window's focused transcript: the selected session's, or the window's own (empty) when none is selected.
    @MainActor
    static func text(_ m: AgentTranscriptModel) -> String {
        text(prosper: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
             dch: m.source?.dchVersion ?? "", version: m.latestVersion, counts: m.counts, errors: m.parseErrors)
    }

    /// Copy: through the app's one pasteboard (tests hand a private one).
    static func copy(_ text: String, to pb: NSPasteboard = Pasteboard.general) {
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

/// The small read-only pane the sidebar "..." Diagnostics item pops over.
struct AgentDiagnosticsView: View {
    let text: String
    var copy: (String) -> Void = { AgentDiagnostics.copy($0) }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(10)) {
            Text(verbatim: text).font(Neon.font(11)).foregroundStyle(Neon.textPrimary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Copy") { copy(text) }
            }
        }
        .padding(sz(14))
        .frame(width: sz(380))
    }
}
