import Foundation

/// #1260: reads the token usage off a relayed reply (Python UsageTap, ccpool_proxy.py 306-351); #1482: every relayed
/// reply, for the usage record, while learn reads it only for a 200 that is not a quota check. Strictly
/// passive: handed a copy of each decoded chunk after it was sent to the client, it never alters, holds or fails
/// the relay. The body is outside data: at most `maxBuffer` bytes are held (a JSON body whole, or one event-stream
/// line); past that the tap gives up for good. Nothing of the body is kept but the five token counts.
struct CCPoolUsageTap: Sendable {
    /// Bound of the held bytes. Python keeps 4 MiB of a JSON body and an unbounded event-stream line.
    static let maxBuffer = 512 << 10

    let stream: Bool
    /// #2006: an OpenAI Responses reply (Codex): `response.completed` ends the stream and its `response.usage` counts.
    let codex: Bool
    private(set) var dead = false
    private var buf = Data()
    /// An event stream counts only once its message_stop arrived: a cut stream learns nothing.
    private var stopped = false
    /// Only the four `keys` below ever enter it: bounded.
    private var counts: [String: Double] = [:]
    static let keys = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
    /// The `cache_creation` object: present = its split replaces the unsplit count (Python dollars()).
    private var split: (w5: Double?, w1: Double?)?

    init(contentType: String?, codex: Bool = false) {
        stream = contentType?.lowercased().contains("event-stream") ?? false
        self.codex = codex
    }

    mutating func feed(_ chunk: Data) {
        guard !dead else { return }
        guard stream else {
            guard buf.count + chunk.count <= Self.maxBuffer else { return giveUp() }
            buf.append(chunk)
            return
        }
        var rest = chunk[...]
        while let nl = rest.firstIndex(of: 10) {
            guard buf.count + (nl - rest.startIndex) <= Self.maxBuffer else { return giveUp() }
            buf.append(rest[rest.startIndex..<nl])
            line(buf)
            buf.removeAll(keepingCapacity: true)
            guard !dead else { return }
            rest = rest[rest.index(after: nl)...]
        }
        guard buf.count + rest.count <= Self.maxBuffer else { return giveUp() }
        buf.append(rest)
    }

    /// The usage of a whole reply, or nil: gave up, no usage, a bad number, a JSON body that does not parse,
    /// an event stream without its message_stop.
    func result() -> CCPoolTokenUsage? {
        var tap = self
        if !tap.dead, !tap.stream {
            guard let obj = try? JSONSerialization.jsonObject(with: tap.buf) as? [String: Any] else { return nil }
            if tap.codex { tap.takeCodex(obj["usage"]) } else { tap.take(obj) }
        }
        guard !tap.dead, !tap.stream || tap.stopped, !tap.counts.isEmpty || tap.split != nil else { return nil }
        let c = tap.counts
        var u = CCPoolTokenUsage(input: c["input_tokens"] ?? 0, output: c["output_tokens"] ?? 0,
                                 cacheRead: c["cache_read_input_tokens"] ?? 0, cacheWrite5m: c["cache_creation_input_tokens"] ?? 0)
        if let s = tap.split {
            u.cacheWrite5m = s.w5 ?? u.cacheWrite5m
            u.cacheWrite1h = s.w1 ?? 0
        }
        return u
    }

    private mutating func giveUp() {
        dead = true
        buf = Data()
    }

    private mutating func line(_ l: Data) {
        let data = Data("data:".utf8)
        if codex {
            guard l.starts(with: data), l.range(of: Data("\"usage\"".utf8)) != nil else { return }
            // Only the completed event counts: usage on an earlier event (in_progress) is not the reply's.
            guard let obj = try? JSONSerialization.jsonObject(with: l.dropFirst(data.count)) as? [String: Any] else { return giveUp() }
            guard obj["type"] as? String == "response.completed" else { return }
            stopped = true
            return takeCodex((obj["response"] as? [String: Any])?["usage"])
        }
        guard l.starts(with: data), l.range(of: Data("\"usage\"".utf8)) != nil || l.range(of: Data("message_stop".utf8)) != nil
        else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: l.dropFirst(data.count)) as? [String: Any] else { return giveUp() }
        if obj["type"] as? String == "message_stop" { stopped = true }
        take(obj)
    }

    /// Python take(): `usage` at the top (message_delta, a JSON reply) or under `message` (message_start);
    /// later values win per key, a null is skipped. A present value that is not a count gives up.
    private mutating func take(_ event: [String: Any]) {
        let top = event["usage"] as? [String: Any]
        guard let u = (top?.isEmpty == false ? top : nil) ?? (event["message"] as? [String: Any])?["usage"] as? [String: Any]
        else { return }
        // .some(nil): absent or null (skipped); nil: present but not a count (give up).
        func field(_ key: String, in d: [String: Any]) -> Double?? {
            guard let v = d[key], !(v is NSNull) else { return .some(nil) }
            guard let n = Self.count(v) else { return nil }
            return .some(n)
        }
        for key in Self.keys {
            guard let c = field(key, in: u) else { return giveUp() }
            if let c { counts[key] = c }
        }
        guard let cc = u["cache_creation"], !(cc is NSNull) else { return }
        guard let d = cc as? [String: Any], let w5 = field("ephemeral_5m_input_tokens", in: d),
              let w1 = field("ephemeral_1h_input_tokens", in: d) else { return giveUp() }
        // R1260-b: Python `cc.get(key, unsplit)` then `w5 or 0`: a null counts 0; only an absent key takes the unsplit count.
        split = (d["ephemeral_5m_input_tokens"] is NSNull ? 0 : w5, w1)
    }

    /// #2006: Responses `usage` -> input (uncached), cacheRead (cached), output; Codex writes no cache. Absent or
    /// null usage counts nothing; a present value that is not a count, or more cached than input, gives up.
    private mutating func takeCodex(_ raw: Any?) {
        guard let raw, !(raw is NSNull) else { return }
        guard let u = raw as? [String: Any], let input = u["input_tokens"].flatMap(Self.count),
              let output = u["output_tokens"].flatMap(Self.count) else { return giveUp() }
        var cached = 0.0
        if let d = u["input_tokens_details"], !(d is NSNull), let c = (d as? [String: Any])?["cached_tokens"], !(c is NSNull) {
            guard let n = Self.count(c) else { return giveUp() }
            cached = n
        }
        guard cached <= input else { return giveUp() }
        counts = ["input_tokens": input - cached, "output_tokens": output, "cache_read_input_tokens": cached]
    }

    /// A token count: a JSON number (not a bool), finite, 0...CCPoolCapacity.maxTokens; anything else is nil.
    static func count(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite && d >= 0 && d <= CCPoolCapacity.maxTokens ? d : nil
    }
}
