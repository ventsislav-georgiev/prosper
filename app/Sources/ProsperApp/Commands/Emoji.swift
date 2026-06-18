import Foundation

/// Deterministic emoji shortcode lookup (`:smile` → 😄). A curated table of
/// common shortcodes — no network, no LLM. Used by both the command runner and
/// the inline autocomplete engine.
enum Emoji {

    /// shortcode (without colons) → emoji.
    static let table: [String: String] = [
        "smile": "😄", "smiley": "😃", "grin": "😁", "laughing": "😆",
        "joy": "😂", "rofl": "🤣", "sweat_smile": "😅", "wink": "😉",
        "blush": "😊", "slight_smile": "🙂", "upside_down": "🙃",
        "heart_eyes": "😍", "kissing_heart": "😘", "yum": "😋",
        "stuck_out_tongue": "😛", "thinking": "🤔", "neutral": "😐",
        "expressionless": "😑", "no_mouth": "😶", "smirk": "😏",
        "unamused": "😒", "roll_eyes": "🙄", "grimacing": "😬",
        "relieved": "😌", "pensive": "😔", "sleepy": "😪", "sleeping": "😴",
        "mask": "😷", "sunglasses": "😎", "nerd": "🤓", "confused": "😕",
        "worried": "😟", "frowning": "🙁", "cry": "😢", "sob": "😭",
        "scream": "😱", "angry": "😠", "rage": "😡", "triumph": "😤",
        "sweat": "😓", "fearful": "😨", "cold_sweat": "😰", "weary": "😩",
        "tired": "😫", "yawning": "🥱", "exploding_head": "🤯",
        "cowboy": "🤠", "partying": "🥳", "shushing": "🤫", "shrug": "🤷",
        "heart": "❤️", "broken_heart": "💔", "two_hearts": "💕",
        "sparkling_heart": "💖", "blue_heart": "💙", "green_heart": "💚",
        "yellow_heart": "💛", "purple_heart": "💜", "black_heart": "🖤",
        "fire": "🔥", "star": "⭐", "sparkles": "✨", "boom": "💥",
        "100": "💯", "tada": "🎉", "confetti": "🎊", "balloon": "🎈",
        "gift": "🎁", "rocket": "🚀", "zap": "⚡", "sunny": "☀️",
        "cloud": "☁️", "rain": "🌧️", "snowflake": "❄️", "rainbow": "🌈",
        "thumbsup": "👍", "+1": "👍", "thumbsdown": "👎", "-1": "👎",
        "ok_hand": "👌", "clap": "👏", "wave": "👋", "pray": "🙏",
        "muscle": "💪", "point_up": "☝️", "point_down": "👇",
        "point_left": "👈", "point_right": "👉", "raised_hands": "🙌",
        "handshake": "🤝", "writing_hand": "✍️", "eyes": "👀",
        "brain": "🧠", "skull": "💀", "ghost": "👻", "alien": "👽",
        "robot": "🤖", "poop": "💩", "check": "✅", "x": "❌",
        "warning": "⚠️", "question": "❓", "exclamation": "❗",
        "bulb": "💡", "lock": "🔒", "unlock": "🔓", "key": "🔑",
        "mag": "🔍", "bell": "🔔", "hourglass": "⏳", "alarm": "⏰",
        "calendar": "📅", "pushpin": "📌", "paperclip": "📎",
        "pencil": "✏️", "memo": "📝", "book": "📖", "books": "📚",
        "email": "📧", "phone": "📱", "computer": "💻", "keyboard": "⌨️",
        "bug": "🐛", "snake": "🐍", "dog": "🐶", "cat": "🐱",
        "coffee": "☕", "beer": "🍺", "pizza": "🍕", "cake": "🍰",
        "apple": "🍎", "taco": "🌮", "money": "💰", "dollar": "💵",
        "chart_up": "📈", "chart_down": "📉", "hammer": "🔨",
        "wrench": "🔧", "gear": "⚙️", "package": "📦", "trophy": "🏆",
        "medal": "🏅", "soccer": "⚽", "basketball": "🏀", "car": "🚗",
        "airplane": "✈️", "house": "🏠", "office": "🏢", "earth": "🌍",
        "moon": "🌙", "wave_ocean": "🌊", "tree": "🌳", "flower": "🌸",
    ]

    /// Shortcodes whose emoji accept a Fitzpatrick skin-tone modifier (human
    /// body parts / gestures present in `table`).
    static let skinToneCapable: Set<String> = [
        "thumbsup", "+1", "thumbsdown", "-1", "ok_hand", "clap", "wave",
        "pray", "muscle", "point_up", "point_down", "point_left",
        "point_right", "raised_hands", "writing_hand",
    ]

    /// Shortcodes that have explicit gendered variants (neutral / female / male).
    /// Maps name → (female, male); the neutral form stays in `table`.
    static let genderedVariants: [String: (female: String, male: String)] = [
        "shrug": ("🤷\u{200D}♀️", "🤷\u{200D}♂️"),
    ]

    /// Applies the user's preferred skin tone + gender to an emoji for a given
    /// shortcode, per `Preferences`. Returns the original emoji when neither
    /// applies. Skin tone is applied by replacing a trailing VS16 (U+FE0F) with
    /// the modifier, else appending it after the base scalar.
    static func styled(name: String, emoji: String) -> String {
        var result = emoji

        // Gender first (variant selection), then skin tone on top where relevant.
        if let variants = genderedVariants[name] {
            switch Preferences.emojiGender {
            case .neutral: break
            case .female: result = variants.female
            case .male: result = variants.male
            }
        }

        if skinToneCapable.contains(name), let modifier = Preferences.emojiSkinTone.modifier {
            result = applyingSkinTone(result, modifier: modifier)
        }
        return result
    }

    /// Inserts a skin-tone modifier into a single-emoji string.
    private static func applyingSkinTone(_ emoji: String, modifier: String) -> String {
        var scalars = Array(emoji.unicodeScalars)
        // Drop a trailing VS16 (emoji presentation selector) — the tone modifier
        // already implies emoji presentation and the two must not coexist.
        if scalars.last == Unicode.Scalar(0xFE0F) {
            scalars.removeLast()
        }
        guard let base = scalars.first else { return emoji }
        var out = String(base)
        out.unicodeScalars.append(contentsOf: modifier.unicodeScalars)
        // Re-append anything after the base (e.g. ZWJ sequences) untouched.
        if scalars.count > 1 {
            out.unicodeScalars.append(contentsOf: scalars[1...])
        }
        return out
    }

    /// A single best match for a shortcode prefix (exact wins, else first
    /// alphabetical prefix match). Returns nil if none. Applies the user's
    /// preferred skin tone / gender to the result.
    static func best(forPrefix prefix: String) -> (name: String, emoji: String)? {
        let key = prefix.lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = table[key] { return (key, styled(name: key, emoji: exact)) }
        let matches = table.keys.filter { $0.hasPrefix(key) }.sorted()
        guard let name = matches.first, let emoji = table[name] else { return nil }
        return (name, styled(name: name, emoji: emoji))
    }

    /// Up to `limit` matches for a prefix, sorted (exact first, then alpha).
    static func matches(forPrefix prefix: String, limit: Int = 8) -> [(name: String, emoji: String)] {
        let key = prefix.lowercased()
        guard !key.isEmpty else { return [] }
        var names = table.keys.filter { $0.hasPrefix(key) }.sorted()
        // Promote exact match to the front.
        if let idx = names.firstIndex(of: key) {
            names.remove(at: idx)
            names.insert(key, at: 0)
        }
        return names.prefix(limit).compactMap { name in
            table[name].map { (name, styled(name: name, emoji: $0)) }
        }
    }
}
