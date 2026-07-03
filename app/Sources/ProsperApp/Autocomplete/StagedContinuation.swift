import Foundation

/// B4 — a continuation staged for a *future* display, committed only when it is still
/// valid. Formalizes Cotypist's `stagedResult`/`stagedInputLine` + `displayEpoch`
/// gate: a staged result is shown only if the display epoch is unchanged AND the
/// user's current input line still matches what was staged (verbatim, or the user
/// typed forward INTO the staged text, in which case the un-typed remainder shows).
///
/// Prosper already approximates this with `requestToken` (single-flight epoch),
/// `RecentSentences`, and ghost auto-extend; this is the explicit, unit-tested gate
/// those paths were doing implicitly, so an epoch bump or a divergent keystroke can
/// never commit a stale staged continuation.
struct StagedContinuation: Equatable {
    /// The display/request epoch when this was staged (Prosper's `requestToken`).
    let epoch: Int
    /// The user's before-caret text when this was staged.
    let inputLine: String
    /// The continuation to show if still valid at commit time.
    let result: String

    /// The continuation to display now, or nil if the stage is stale: the epoch
    /// changed (a newer request superseded it) or the user's current input diverged
    /// from what was staged. When the user typed forward into the staged result, the
    /// remaining (un-typed) tail is returned.
    func commit(currentEpoch: Int, currentInputLine: String) -> String? {
        guard currentEpoch == epoch else { return nil }
        if currentInputLine == inputLine { return result }
        // Forward typing into the staged continuation: the extra chars must be a
        // prefix of the staged result; show the remainder.
        guard currentInputLine.hasPrefix(inputLine) else { return nil }
        let typed = String(currentInputLine.dropFirst(inputLine.count))
        guard result.hasPrefix(typed) else { return nil }
        let remainder = String(result.dropFirst(typed.count))
        return remainder.isEmpty ? nil : remainder
    }
}
