// The menu-bar widget for the Calendar item — the four Itsycal-style modes:
// solid day badge (digits knocked out of a filled rounded rect), outlined day
// badge, plain calendar glyph, and a free-form TR35 datetime pattern. Rendered
// as SwiftUI hosted inside the NSStatusItem button, drawn in the menu bar's
// template style (primary label color) so it matches neighbouring items.

import SwiftUI

struct CalendarIconWidget: View {
    @ObservedObject var store: CalendarBarStore

    var body: some View {
        let style = store.style
        Group {
            if style.hideIcon {
                // Item kept alive (position autosave + popup/shortcut anchor);
                // just nothing drawn. Matches Itsycal's nil-image hide.
                Color.clear.frame(width: 8, height: 1)
            } else {
                switch style.iconMode {
                case .solid: badge(filled: true)
                case .outline: badge(filled: false)
                case .glyph:
                    Image(systemName: "calendar")
                        .font(.system(size: 15, weight: .regular))
                case .pattern:
                    if style.datetimePattern.isEmpty {
                        badge(filled: true)
                    } else {
                        Text(Self.patternText(style.datetimePattern, now: store.now))
                            .font(.system(size: 12, weight: style.resolvedIconWeight,
                                          design: style.resolvedIconDesign).monospacedDigit())
                            .lineLimit(1)
                    }
                }
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// The day badge: text inside a rounded rect. Filled mode knocks the digits
    /// out of the fill (Itsycal's XOR draw); outline mode strokes the rect.
    @ViewBuilder
    private func badge(filled: Bool) -> some View {
        let style = store.style
        let text = Self.badgeText(style: style, today: store.today,
                                  calendar: store.calendar)
        // Text drives layout in BOTH modes: a shape with .fill() has no
        // intrinsic width, so shape-first + .fixedSize() collapses to a sliver
        // (the beta.2 "narrow dark pill" bug). Knockout via destinationOut over
        // a background shape instead.
        let label = Text(text)
            .font(.system(size: 11, weight: style.resolvedIconWeight,
                          design: style.resolvedIconDesign).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(height: 16)
        if filled {
            label
                .blendMode(.destinationOut)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.primary)
                )
                .compositingGroup()
                .fixedSize()
        } else {
            label
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(.primary, lineWidth: 1)
                )
                .fixedSize()
        }
    }

    // MARK: - Text builders (static, unit-tested via CalendarGridMath)

    /// Badge text: the day number, optionally with month / day-of-week via a
    /// localized TR35 template.
    static func badgeText(style: CalendarBarStyle, today: Date, calendar: Calendar) -> String {
        if !style.showMonthInIcon && !style.showDayOfWeekInIcon {
            return String(calendar.component(.day, from: today))
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = CalendarGridMath.iconDateFormat(
            showMonth: style.showMonthInIcon,
            showDayOfWeek: style.showDayOfWeekInIcon,
            locale: Locale.current)
        return formatter.string(from: today)
    }

    static func patternText(_ pattern: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter.string(from: now)
    }

    /// True when a TR35 pattern contains time fields (needs the minute tick).
    /// Quoted literals ('at') don't count. Pure string scan — nonisolated so
    /// tests and off-main callers don't inherit the View's MainActor.
    nonisolated static func patternHasTimeFields(_ pattern: String) -> Bool {
        var inQuote = false
        for ch in pattern {
            if ch == "'" { inQuote.toggle(); continue }
            if inQuote { continue }
            if "HhKkmsaSjJ".contains(ch) { return true }
        }
        return false
    }

    /// The width-driving text for the controller's resize memo.
    static func widthKey(style: CalendarBarStyle, today: Date, now: Date,
                         calendar: Calendar) -> String {
        if style.hideIcon { return "hidden" }
        switch style.iconMode {
        case .glyph: return "glyph"
        case .solid, .outline:
            return style.iconMode.rawValue + badgeText(style: style, today: today, calendar: calendar)
        case .pattern:
            return style.datetimePattern.isEmpty
                ? "solid" + badgeText(style: style, today: today, calendar: calendar)
                : patternText(style.datetimePattern, now: now)
        }
    }
}
