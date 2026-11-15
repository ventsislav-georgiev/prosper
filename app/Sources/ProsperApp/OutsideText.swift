import Foundation

/// The tree's rule for showing an outside string (a name, a link target): unseen scalars dropped, then cut.
enum OutsideText {
    private static let unseenCategories: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator,
                                                                         .privateUse, .surrogate, .unassigned]

    /// A scalar no label may hold: a control, format, separator, private-use, surrogate, unassigned
    /// or default-ignorable code point (U+3164, U+034F, U+FE0F, ...), or whitespace other than U+0020.
    static func isUnseen(_ s: Unicode.Scalar) -> Bool {
        unseenCategories.contains(s.properties.generalCategory) || s.properties.isDefaultIgnorableCodePoint
            || (s.properties.isWhitespace && s != " ")
            || s == "\u{2800}"   // QA #751 INFO-7: BRAILLE PATTERN BLANK is a symbol that renders blank
    }

    /// Review INFO 2: an outside string (a symbolic link's target) as the pane may show it: every
    /// scalar the label rule refuses dropped, each character's combining marks capped (#1251), then at most `max` characters.
    static func shown(_ outside: String, max: Int = 160) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: outside.unicodeScalars.lazy.filter { !isUnseen($0) })
        // capped after the drop: a dropped scalar between two groups of marks joins them on one character
        let s = capMarks(String(view))
        return s.count <= max ? s : String(s.prefix(Swift.max(0, max - 1))) + "…"
    }

    /// #1251 (B1235-1): at most `max` nonspacing or enclosing marks (Mn, Me) per Character, so one character's
    /// ink stays near its own line; the base and every other scalar stay.
    static func capMarks(_ s: String, max: Int = 2) -> String {
        var out = String.UnicodeScalarView()
        for ch in s {
            var marks = 0
            for u in ch.unicodeScalars {
                let c = u.properties.generalCategory
                if c == .nonspacingMark || c == .enclosingMark {
                    marks += 1
                    if marks > max { continue }
                }
                out.append(u)
            }
        }
        return String(out)
    }
}
