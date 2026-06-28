// JSON persistence for the System Stats widget style. One UserDefaults key holds
// the whole StatsWidgetStyle blob; a decode failure (schema drift) falls back to
// the default rather than throwing, so a bad blob can never wedge the feature.

import Foundation

enum SystemStatsStore {
    private static let key = "systemStatsWidgetStyle"
    private static var defaults: UserDefaults { .standard }

    static func load() -> StatsWidgetStyle {
        guard let data = defaults.data(forKey: key),
              let style = try? JSONDecoder().decode(StatsWidgetStyle.self, from: data)
        else { return .default }
        return style
    }

    static func save(_ style: StatsWidgetStyle) {
        guard let data = try? JSONEncoder().encode(style) else { return }
        defaults.set(data, forKey: key)
    }
}
