import Foundation

/// Lightweight, dependency-free usage statistics for accepted completions.
/// Persists running totals + a per-day count in UserDefaults (no GRDB/SQLite).
/// Counts are local-only and never transmitted.
enum CompletionStats {
    private static var defaults: UserDefaults { UserDefaults.standard }

    private enum Keys {
        static let totalCompletions = "stats.totalCompletions"
        static let totalWords = "stats.totalWords"
        static let totalChars = "stats.totalChars"
        static let perDay = "stats.perDayCompletions" // [yyyy-MM-dd: Int]
        static let perDayWords = "stats.perDayWords"   // [yyyy-MM-dd: Int]
        static let perDayChars = "stats.perDayChars"   // [yyyy-MM-dd: Int]
    }

    /// Metric selectable in the Statistics bar chart.
    enum Metric: String, CaseIterable, Sendable {
        case completions, words, chars
        var title: String {
            switch self {
            case .completions: return "Completions"
            case .words: return "Words"
            case .chars: return "Characters"
            }
        }
    }

    /// Records one accepted completion (full or single-word).
    static func recordAccept(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let words = trimmed.split { $0.isWhitespace }.count
        let chars = trimmed.count

        defaults.set(totalCompletions + 1, forKey: Keys.totalCompletions)
        defaults.set(totalWords + words, forKey: Keys.totalWords)
        defaults.set(totalChars + chars, forKey: Keys.totalChars)

        let key = Self.dayKey()
        var perDay = perDayCounts
        perDay[key, default: 0] += 1
        defaults.set(perDay, forKey: Keys.perDay)

        var perWords = perDayWords
        perWords[key, default: 0] += words
        defaults.set(perWords, forKey: Keys.perDayWords)

        var perChars = perDayChars
        perChars[key, default: 0] += chars
        defaults.set(perChars, forKey: Keys.perDayChars)
    }

    static var totalCompletions: Int { defaults.integer(forKey: Keys.totalCompletions) }
    static var totalWords: Int { defaults.integer(forKey: Keys.totalWords) }
    static var totalChars: Int { defaults.integer(forKey: Keys.totalChars) }

    static var perDayCounts: [String: Int] {
        (defaults.dictionary(forKey: Keys.perDay) as? [String: Int]) ?? [:]
    }

    static var perDayWords: [String: Int] {
        (defaults.dictionary(forKey: Keys.perDayWords) as? [String: Int]) ?? [:]
    }

    static var perDayChars: [String: Int] {
        (defaults.dictionary(forKey: Keys.perDayChars) as? [String: Int]) ?? [:]
    }

    /// One day's value in a metric series.
    struct DayPoint: Identifiable, Sendable {
        var id: String { day }
        let day: String
        let value: Int
    }

    /// Per-day series for `metric` over the last `days` days, oldest→newest,
    /// with zero-filled gaps.
    static func series(metric: Metric, days: Int) -> [DayPoint] {
        let source: [String: Int]
        switch metric {
        case .completions: source = perDayCounts
        case .words: source = perDayWords
        case .chars: source = perDayChars
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [DayPoint] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = dayKey(for: date)
            out.append(DayPoint(day: key, value: source[key] ?? 0))
        }
        return out
    }

    /// Completions accepted today (local time).
    static var todayCount: Int { perDayCounts[dayKey()] ?? 0 }

    /// Mean completions/day across days with any activity (0 if none).
    static var dailyAverage: Double {
        let counts = perDayCounts.values
        guard !counts.isEmpty else { return 0 }
        return Double(counts.reduce(0, +)) / Double(counts.count)
    }

    static func reset() {
        defaults.removeObject(forKey: Keys.totalCompletions)
        defaults.removeObject(forKey: Keys.totalWords)
        defaults.removeObject(forKey: Keys.totalChars)
        defaults.removeObject(forKey: Keys.perDay)
        defaults.removeObject(forKey: Keys.perDayWords)
        defaults.removeObject(forKey: Keys.perDayChars)
    }

    /// `yyyy-MM-dd` in the local calendar. Stable across formatter locales.
    static func dayKey(for date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
