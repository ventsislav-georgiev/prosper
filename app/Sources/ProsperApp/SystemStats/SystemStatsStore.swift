// JSON persistence for the System Stats widget style. One UserDefaults key holds
// the whole StatsWidgetStyle blob; a decode failure (schema drift) falls back to
// the default rather than throwing, so a bad blob can never wedge the feature.

import Foundation
import StatsCore

enum SystemStatsStore {
    private static let key = "systemStatsWidgetStyle"
    private static var defaults: UserDefaults { .standard }

    static func load() -> StatsWidgetStyle {
        guard let data = defaults.data(forKey: key),
              var style = try? JSONDecoder().decode(StatsWidgetStyle.self, from: data)
        else { return .default }
        // A blob saved before a module existed carries no slot for it in `order`,
        // and `enabledModules` walks `order` — so the module could be switched on
        // in settings and never reach the menu bar (Disk, added after the first
        // beta, hit exactly this). Keep the user's arrangement, drop stale keys,
        // append anything the current default order has that the blob is missing.
        let known = Set(StatsModule.allCases.map(\.rawValue))
        let kept = style.order.filter(known.contains)
        style.order = kept + StatsWidgetStyle.default.order.filter { !kept.contains($0) }
        return style
    }

    static func save(_ style: StatsWidgetStyle) {
        guard let data = try? JSONEncoder().encode(style) else { return }
        defaults.set(data, forKey: key)
    }
}
