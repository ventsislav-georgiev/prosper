import Foundation

/// Deterministic time-zone conversion for the command runner (Numi parity).
/// Parses queries like:
///   * `2:30 pm HKT in Berlin`  → `8:30`
///   * `14:30 CET to Tokyo`     → `22:30`
///   * `time in Tokyo` / `now in NYC` → current time there
///   * `9am in London`          → source = local zone
/// The source/target may be a zone abbreviation (HKT, CET, PST…), a city from
/// the IANA database (`Europe/Berlin` → "berlin"), or a common alias (NYC, LA).
/// Pure and synchronous; `now` is injectable for tests.
enum TimeConvert {

    struct Result: Equatable {
        /// The converted time, 24-hour `H:mm` — e.g. "8:30". This is what Enter copies.
        let value: String
        /// e.g. "2:30 pm HKT → Berlin".
        let detail: String
    }

    /// Attempts a conversion. Returns nil unless the query is exactly a
    /// `<time> [zone] (in|to) <zone>` shape with resolvable zones, so unit and
    /// currency queries fall through untouched.
    static func convert(_ input: String, now: Date = Date()) -> Result? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split on the LAST " in "/" to " so "2:30 pm HKT in Berlin" keeps the
        // zone on the left ("in" can't appear inside a time).
        let lower = trimmed.lowercased()
        var lhs = "", rhs = ""
        var found = false
        for sep in [" in ", " to ", "->", " → "] {
            if let range = lower.range(of: sep, options: .backwards) {
                lhs = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                rhs = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                found = true
                break
            }
        }
        guard found, !rhs.isEmpty else { return nil }
        guard let target = resolveZone(rhs) else { return nil }

        // LHS: "time"/"now" → current instant; else "<h>[:mm] [am|pm] [zone]".
        let lhsLower = lhs.lowercased()
        if lhsLower.isEmpty || lhsLower == "time" || lhsLower == "now"
            || lhsLower == "what time is it" || lhsLower == "current time" {
            return result(instant: now, sourceLabel: nil, target: target, targetRaw: rhs)
        }

        guard let parsed = parseTime(lhs) else { return nil }
        let source = parsed.zone ?? TimeZone.current
        // The named zone must resolve, otherwise this isn't a time query.
        if parsed.zoneRaw != nil && parsed.zone == nil { return nil }

        // Anchor "today" in the SOURCE zone, then set the given wall-clock time.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = source
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = parsed.hour
        comps.minute = parsed.minute
        guard let instant = cal.date(from: comps) else { return nil }
        return result(instant: instant, sourceLabel: lhs, target: target, targetRaw: rhs)
    }

    private static func result(
        instant: Date, sourceLabel: String?, target: TimeZone, targetRaw: String
    ) -> Result? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = target
        f.dateFormat = "H:mm"
        let value = f.string(from: instant)
        let place = displayName(targetRaw)
        let detail = sourceLabel.map { "\($0) → \(place)" } ?? "now → \(place)"
        return Result(value: value, detail: detail)
    }

    // MARK: - Time parsing

    private struct ParsedTime {
        let hour: Int
        let minute: Int
        /// The trailing zone text, if any ("hkt"), even when unresolvable.
        let zoneRaw: String?
        let zone: TimeZone?
    }

    /// Parses `"<h>[:mm] [am|pm] [zone words]"`. Returns nil unless a valid
    /// hour leads the string.
    private static func parseTime(_ s: String) -> ParsedTime? {
        let lower = s.lowercased().trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(.*)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower))
        else { return nil }

        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: lower) else { return nil }
            return String(lower[r])
        }
        guard let hStr = group(1), var hour = Int(hStr) else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        let meridiem = group(3)
        let zoneRaw = group(4).map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }

        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "pm" && hour != 12 { hour += 12 }
            if meridiem == "am" && hour == 12 { hour = 0 }
        } else {
            guard (0...23).contains(hour) else { return nil }
        }
        guard (0...59).contains(minute) else { return nil }

        return ParsedTime(
            hour: hour, minute: minute,
            zoneRaw: zoneRaw,
            zone: zoneRaw.flatMap(resolveZone)
        )
    }

    // MARK: - Zone resolution

    /// Resolves a zone string: abbreviation (HKT, CET, UTC…), IANA city
    /// ("berlin", "hong kong"), full identifier ("Europe/Berlin"), or alias.
    static func resolveZone(_ raw: String) -> TimeZone? {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }

        // Abbreviations are uppercase by convention; macOS ships the table.
        let upper = key.uppercased()
        if let tz = TimeZone(abbreviation: upper) { return tz }
        if let id = extraAbbreviations[upper], let tz = TimeZone(identifier: id) { return tz }

        // Full identifier ("Europe/Berlin").
        if key.contains("/"), let tz = TimeZone(identifier: raw.trimmingCharacters(in: .whitespaces)) {
            return tz
        }

        if let id = aliases[key] ?? cityIndex[key] { return TimeZone(identifier: id) }
        return nil
    }

    /// "Hong_Kong" → "hong kong": last path component of every known IANA
    /// identifier, lowercased. Built once.
    private static let cityIndex: [String: String] = {
        var idx: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let city = id.split(separator: "/").last else { continue }
            let key = city.replacingOccurrences(of: "_", with: " ").lowercased()
            // First match wins; prefer non-deprecated continents listed first.
            if idx[key] == nil { idx[key] = id }
        }
        return idx
    }()

    /// Common shorthand the IANA last-component index doesn't cover.
    private static let aliases: [String: String] = [
        "nyc": "America/New_York", "new york city": "America/New_York",
        "la": "America/Los_Angeles", "sf": "America/Los_Angeles",
        "san francisco": "America/Los_Angeles",
        "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
        "mumbai": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
        "beijing": "Asia/Shanghai", "sydney": "Australia/Sydney",
        "melbourne": "Australia/Melbourne",
    ]

    /// Abbreviations missing from `TimeZone(abbreviation:)` on some systems.
    private static let extraAbbreviations: [String: String] = [
        "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney",
        "ACST": "Australia/Adelaide", "AWST": "Australia/Perth",
        "PHT": "Asia/Manila", "SGT": "Asia/Singapore",
        "HKT": "Asia/Hong_Kong", "KST": "Asia/Seoul",
        "CEST": "Europe/Paris", "EEST": "Europe/Athens",
        "IST": "Asia/Kolkata",
    ]

    /// Title-cases the user's target text for the detail line ("berlin" →
    /// "Berlin"); leaves abbreviations/identifiers as typed.
    private static func displayName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.contains("/") || t == t.uppercased() { return t }
        return t.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
