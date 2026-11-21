import Foundation

/// #1862: the agent-control writes ccpool.hold and ccpool.release (registered by Control/ControlCCPool.swift). Both go
/// through the pane's own `hold` and `release` (the Hold and Release buttons), so the store's bench rules are the pane's.
/// Labels only: no token, Keychain id or path. Undo puts the account's cooldowns, hold and refusal back as they were, so
/// release undoes hold and hold undoes release. On demand only: no observer, no poll, no proxy call.
extension CCPoolControl {
    /// The longest hold: the store's bench cap (CCPoolCore.maxBench), in hours. A longer ask is refused, never cut short.
    nonisolated static let maxHours = Double(CCPoolCore.maxBench) / 3600
    static let badHours = "hours must be above 0 and at most \(Int(maxHours))"

    /// The account's cooldown state: what hold and release change, and what their undo puts back.
    private struct Bench {
        var cooldown: [String: Int]
        var held: Int?
        var refused: Int?
        init(_ a: CCPoolState.Account) { (cooldown, held, refused) = (a.cooldown, a.held, a.refused) }
    }

    /// The pane model and the account named `label` (exact, trimmed); the store must be readable (the pane refuses
    /// account changes then too).
    private static func target(_ label: String) throws -> (CCPoolPaneModel, String, Bench) {
        let m = try loaded()
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw ControlError("argument 'label' is empty") }
        if let why = m.storeProblem { throw ControlError(why) }
        guard let a = m.store.snapshot.accounts[label] else {
            throw ControlError("no ccpool account named \(OutsideText.shown(label, max: 64)) (ccpool.status lists them)")
        }
        return (m, label, Bench(a))
    }

    private static func undo(_ m: CCPoolPaneModel, _ label: String, _ b: Bench) -> @MainActor () -> Void {
        { [weak m] in
            guard let m else { return }
            m.store.mutate { st in
                guard st.accounts[label] != nil else { return }   // the account was removed meanwhile
                st.accounts[label]?.cooldown = b.cooldown
                st.accounts[label]?.held = b.held
                st.accounts[label]?.refused = b.refused
            }
            m.objectWillChange.send()
        }
    }

    /// Hold the account out of rotation for `hours` (the Hold buttons).
    static func hold(label: String, hours: Double) throws -> ControlChange {
        guard hours.isFinite, hours > 0, hours <= maxHours else { throw ControlError(badHours) }
        let (m, label, before) = try target(label)
        m.hold(label, hours: hours)
        guard m.store.snapshot.accounts[label]?.held != before.held else { throw ControlError("the hold was not applied") }
        let shown = OutsideText.shown(label, max: 64)
        return ControlChange(summary: "hold \(shown) for \(hours) h", result: .string(label), verb: "held a ccpool account",
                             undo: undo(m, label, before))
    }

    /// Release the account: every cooldown, a hold and a token refusal go (the Release button).
    static func release(label: String) throws -> ControlChange {
        let (m, label, before) = try target(label)
        let now = m.clock()
        guard before.refused != nil || before.held.map({ Double($0) > now }) == true
                || before.cooldown.values.contains(where: { Double($0) > now }) else {
            throw ControlError("\(OutsideText.shown(label, max: 64)) has no hold or limit to release")
        }
        m.release(label)
        return ControlChange(summary: "release \(OutsideText.shown(label, max: 64))", result: .string(label),
                             verb: "released a ccpool account", undo: undo(m, label, before))
    }
}
