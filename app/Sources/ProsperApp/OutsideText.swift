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
    /// scalar the label rule refuses dropped, each base's combining marks capped at three (#1251), then at most `max` characters.
    static func shown(_ outside: String, max: Int = 160) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: outside.unicodeScalars.lazy.filter { !isUnseen($0) })
        // capped after the drop: a dropped scalar between two groups of marks joins them on one character
        let s = capMarks(String(view))
        return s.count <= max ? s : String(s.prefix(Swift.max(0, max - 1))) + "…"
    }

    /// #1251 R1251-s1a (OQ-150): the marks one base may carry and still be drawn as marks: three, so ordinary Hindi,
    /// Tibetan and pointed Hebrew words stay whole. The one number of capMarks and of the card (AgentPrompt.maxMarks).
    static let maxMarks = 3

    /// #1251 (B1235-1): at most `max` (three) nonspacing or enclosing marks (Mn, Me) per BASE, so one glyph's ink stays
    /// near its own line; every other scalar stays. B1251-2: the count starts again at every scalar that is not such a
    /// mark, so each consonant of an Indic conjunct (one Character) carries its own marks and ordinary words stay whole.
    static func capMarks(_ s: String, max: Int = maxMarks) -> String {
        var out = String.UnicodeScalarView(), marks = 0
        for u in s.unicodeScalars {
            let c = u.properties.generalCategory
            marks = c == .nonspacingMark || c == .enclosingMark ? marks + 1 : 0
            if marks <= max { out.append(u) }
        }
        return String(out)
    }
}
