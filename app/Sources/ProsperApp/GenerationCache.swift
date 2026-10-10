/// A cached value refreshed by off-main tasks where only the newest refresh may publish
/// (#236). Lives in a static beside its pane, so a walk started by a since-closed pane
/// instance cannot land last and overwrite a newer value.
struct GenerationCache<Value> {
    private(set) var value: Value
    private var generation = 0

    init(_ value: Value) { self.value = value }

    /// Starts a refresh; pass the returned generation to `publish`.
    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    /// Stores `value` only if no newer `begin()` happened since `gen`.
    mutating func publish(_ value: Value, from gen: Int) -> Bool {
        guard gen == generation else { return false }
        self.value = value
        return true
    }
}
