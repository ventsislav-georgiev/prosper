// Fixed-capacity ring buffer for metric history (chart sources).
//
// O(1) append, contiguous-order snapshot. Backs every module's history with a
// bounded footprint — a 1 Hz reader over a 120-sample window is 120 Doubles,
// not an unbounded array. Not thread-safe: the poller owns one queue and
// snapshots under it before handing data to the main actor.

public struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0          // next write index
    private(set) var filled = 0   // count of valid elements (≤ capacity)
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be > 0")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    public var count: Int { filled }
    public var isEmpty: Bool { filled == 0 }

    public mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        if filled < capacity { filled += 1 }
    }

    /// Oldest → newest, exactly `count` elements. The chart/render snapshot.
    public func snapshot() -> [Element] {
        guard filled > 0 else { return [] }
        var out = [Element]()
        out.reserveCapacity(filled)
        // Oldest is `filled` steps behind head (mod capacity).
        let start = (head - filled + capacity) % capacity
        for i in 0..<filled { out.append(storage[(start + i) % capacity]!) }
        return out
    }

    public var last: Element? {
        filled == 0 ? nil : storage[(head - 1 + capacity) % capacity]
    }

    public mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        filled = 0
    }
}
