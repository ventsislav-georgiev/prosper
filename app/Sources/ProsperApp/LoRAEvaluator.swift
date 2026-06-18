import Foundation

// A/B auto-disable guard for the on-device LoRA adapter (WS6). Tracks rolling
// acceptance counts for two arms — completions shown while the adapter was active
// vs. while it was inactive (base model) — and decides when the adapter is
// underperforming the baseline enough to be auto-disabled.
//
// The decision logic (`shouldDisable`) is a PURE static helper taking counts as
// parameters so it is fully unit-testable with no I/O. The instance methods just
// read/write the rolling counters in `Preferences`.

enum LoRAEvaluator {

    /// Default margin: the adapter must beat the baseline acceptance rate by at least
    /// this much to stay; if `adapterRate + margin < baselineRate` it is disabled.
    static let defaultMargin = 0.02

    /// Fraction of sessions held out as baseline (adapter NOT served) so the baseline
    /// arm keeps accruing samples even while serving is active. Without a holdout the
    /// baseline counters never grow and `shouldDisable` can never fire.
    static let baselineHoldoutFraction = 0.20

    /// Per-session A/B arm, decided ONCE per launch. `true` → this session serves the
    /// adapter; `false` → baseline holdout (or serving is off entirely). The model-init
    /// gate (`CoreBridge.ensureModel`) loads the adapter only when this is true, and the
    /// accept/shown hooks tag their outcomes with this arm — so both arms accrue and the
    /// rates stay comparable. Computed lazily; stable for the process lifetime.
    static let sessionServesAdapter: Bool = {
        guard Preferences.loraServingActive else { return false }
        return Double.random(in: 0 ..< 1) >= baselineHoldoutFraction
    }()

    /// Record that a completion was SHOWN under the given arm. Paired with
    /// `recordAccepted`; acceptance rate = accepted / shown ∈ [0, 1] per arm. This funnel
    /// signal needs no noisy "reject" event from dismissals (which fire on focus change,
    /// app switch, supersede — none of which is a clean rejection).
    static func recordShown(adapterActive: Bool) {
        if adapterActive { Preferences.loraAdapterShown += 1 }
        else { Preferences.loraBaselineShown += 1 }
    }

    /// Record that a shown completion was ACCEPTED under the given arm, then run the A/B
    /// auto-disable check. If the adapter now underperforms the baseline beyond the
    /// margin, serving is turned off and the adapter is unloaded from the live engine.
    /// Returns true iff this call just auto-disabled the adapter.
    @discardableResult
    static func recordAccepted(adapterActive: Bool) -> Bool {
        if adapterActive { Preferences.loraAdapterAccepted += 1 }
        else { Preferences.loraBaselineAccepted += 1 }
        guard shouldDisableAdapter() else { return false }
        Preferences.loraServingActive = false
        Task { await MLXEngine.shared.unloadAdapter() }
        NSLog("prosper-lora: adapter auto-disabled (A/B) adapter=%d/%d baseline=%d/%d",
              Preferences.loraAdapterAccepted, Preferences.loraAdapterShown,
              Preferences.loraBaselineAccepted, Preferences.loraBaselineShown)
        return true
    }

    /// Record one combined completion outcome into the rolling A/B counters.
    /// `adapterActive` selects the arm; `accepted` whether the user accepted. Retained
    /// for unit tests and callers recording a single combined event; the live engine
    /// uses the `recordShown` + `recordAccepted` funnel pair instead.
    static func recordOutcome(adapterActive: Bool, accepted: Bool) {
        if adapterActive {
            Preferences.loraAdapterShown += 1
            if accepted { Preferences.loraAdapterAccepted += 1 }
        } else {
            Preferences.loraBaselineShown += 1
            if accepted { Preferences.loraBaselineAccepted += 1 }
        }
    }

    /// Reads the current counters and decides whether the adapter should be disabled,
    /// using the configured A/B minimum-sample threshold and the default margin.
    static func shouldDisableAdapter() -> Bool {
        shouldDisable(
            adapterShown: Preferences.loraAdapterShown,
            adapterAccepted: Preferences.loraAdapterAccepted,
            baselineShown: Preferences.loraBaselineShown,
            baselineAccepted: Preferences.loraBaselineAccepted,
            minSamples: Preferences.loraABMinSamples,
            margin: defaultMargin
        )
    }

    /// PURE decision logic (no I/O). Returns true when BOTH arms have at least
    /// `minSamples` shown AND the adapter's acceptance rate is worse than the
    /// baseline's by more than `margin` (i.e. `adapterRate + margin < baselineRate`).
    /// Below the sample threshold on either arm → false (cold-start: never disable).
    static func shouldDisable(
        adapterShown: Int,
        adapterAccepted: Int,
        baselineShown: Int,
        baselineAccepted: Int,
        minSamples: Int,
        margin: Double
    ) -> Bool {
        guard adapterShown >= minSamples, baselineShown >= minSamples else { return false }
        guard adapterShown > 0, baselineShown > 0 else { return false }
        let adapterRate = Double(adapterAccepted) / Double(adapterShown)
        let baselineRate = Double(baselineAccepted) / Double(baselineShown)
        return adapterRate + margin < baselineRate
    }
}
