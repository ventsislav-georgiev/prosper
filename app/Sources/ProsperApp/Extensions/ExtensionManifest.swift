import Foundation

/// Parsed `extension.toml` — the static contract an extension declares before any
/// of its Lua code runs. Everything the host needs to populate the palette,
/// settings UI, and keybindings lives here. See docs/ADR-002-extensibility.md.
struct ExtensionManifest: Codable, Sendable, Equatable {
    let `extension`: ExtensionMeta
    let contributes: Contributes?

    enum CodingKeys: String, CodingKey {
        case `extension`
        case contributes
    }
}

/// `[extension]` table — identity + lifecycle.
struct ExtensionMeta: Codable, Sendable, Equatable {
    let id: String            // reverse-DNS unique id, e.g. "com.prosper.calc"
    let name: String          // short slug
    let title: String         // display name
    let description: String
    let version: String       // semver
    let author: String
    let icon: String?
    let license: String?
    /// System extension: bundled, editable + resettable, disable-not-uninstall.
    let system: Bool?
    /// macOS privacy grants this extension can make use of, surfaced in
    /// Settings › Extensions so the user can grant them (see PermissionsManager).
    /// Currently only `"full-disk-access"` is recognized — required by the
    /// bookmarks extension's Safari source and optional for everything else.
    let permissions: [String]?
    /// Where auto-update polls for a newer version. An author can declare it; if
    /// absent and the extension was installed from GitHub, the host writes the
    /// origin URL here on install so update checks know where to look. A pinned
    /// ref (e.g. `/tree/v1.2.3`) never updates; a branch/root install tracks it.
    let update_url: String?
    let host: HostRequirement
    let entry: EntryPoint
    let activation: Activation?

    var isSystem: Bool { system ?? false }
    var updateURL: String? { update_url }

    /// macOS privacy grants this extension declares it can use ([] when none).
    var declaredPermissions: [String] { permissions ?? [] }

    /// True when this extension can make use of Full Disk Access (e.g. to read
    /// Safari's TCC-protected bookmarks). The grant stays optional — the
    /// extension degrades gracefully without it.
    var requiresFullDiskAccess: Bool { declaredPermissions.contains("full-disk-access") }
}

/// `[extension.host]` — version gating.
struct HostRequirement: Codable, Sendable, Equatable {
    let min_version: String   // semver floor; host refuses to load if below
    let api_level: Int        // integer API level the extension targets
}

/// `[extension.entry]` — Lua entry point, loaded lazily on first activation.
struct EntryPoint: Codable, Sendable, Equatable {
    let main: String          // e.g. "init.lua"
}

/// `[extension.activation]` — lazy-load triggers.
struct Activation: Codable, Sendable, Equatable {
    /// Non-command triggers (commands/settings auto-generate implicit triggers).
    let on_event: [String]?
    /// Eager load at startup (reserved for core; discouraged).
    let eager: Bool?

    var events: [String] { on_event ?? [] }
    var isEager: Bool { eager ?? false }
}

/// `[contributes]` — declarative contribution points.
struct Contributes: Codable, Sendable, Equatable {
    let commands: [CommandContribution]?
    let keybindings: [KeybindingContribution]?
    let palette_entries: [PaletteEntry]?
    let views: [ViewContribution]?
    /// Pluggable Settings sections (own sidebar entry or inline), rendered natively
    /// from a declarative spec — static manifest `controls` and/or a dynamic render
    /// hook. See EXTENSION_SETTINGS_SPEC.md.
    let settings_sections: [SettingsSection]?
    /// Dynamic-placeholder names this extension supplies to the snippet engine.
    let placeholders: [PlaceholderContribution]?

    var allCommands: [CommandContribution] { commands ?? [] }
    var allKeybindings: [KeybindingContribution] { keybindings ?? [] }
    var allPaletteEntries: [PaletteEntry] { palette_entries ?? [] }
    var allViews: [ViewContribution] { views ?? [] }
    var allSettingsSections: [SettingsSection] { settings_sections ?? [] }
    var allPlaceholders: [PlaceholderContribution] { placeholders ?? [] }
}

/// A custom dynamic-placeholder an extension contributes to the snippet engine
/// (e.g. `{weather}`). When a snippet contains a `{name …}` token the native
/// engine doesn't recognize, the host routes it to this extension's `handler`
/// (a Lua global, invoked with the raw token spec) on the async lane; the
/// returned string replaces the token. Resolved off the keystroke hot path —
/// only when a snippet actually uses the placeholder.
struct PlaceholderContribution: Codable, Sendable, Equatable {
    let name: String          // token name, without braces (e.g. "weather")
    let title: String?
    let handler: String       // Lua global invoked with the raw token spec
}

/// How a command surfaces and what the host prepares before running it.
enum CommandMode: String, Codable, Sendable {
    case view                       // pushes a declarative view
    case noView = "no-view"         // side effect only
    case background                 // scheduled/background job
}

struct CommandContribution: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let description: String?
    let mode: CommandMode
    let icon: String?
    let keywords: [String]?
    /// Cheap router pre-filter: a regex the query must match before the
    /// extension's Lua handler is invoked (keeps hot dispatch native).
    let match: String?
    /// Optional runner-mode trigger. When the user types this leading prefix in
    /// the universal launcher (e.g. `"ql "`), the runner locks into this command
    /// as a mode — showing `title`/`icon` as the mode chip and stripping the
    /// prefix from the visible query, exactly like the built-in `l `/`o ` modes.
    /// Manifest-declared so extensions own their trigger without host code edits.
    let prefix: String?
    /// Additional runner-mode prefixes that all lock this same command (aliases of
    /// `prefix`, e.g. Translate's `l ` primary + `t ` alias). Each produces its own
    /// mode trigger; `prefix` remains the canonical one restored before the handler.
    let prefixes: [String]?
    /// Context expression controlling palette visibility (empty = always).
    let when: String?
    /// Host capabilities this command needs before it can run. Currently only
    /// `"model"` is recognized: a command that declares it is excluded from the
    /// command runner until the local AI model is downloaded AND loaded — without
    /// touching the extension's enabled state. Once the model is ready the command
    /// surfaces automatically.
    let requires: [String]?
    /// When true this command does not produce an inline result — it OPENS a window
    /// (via `host.window.open`). The runner surfaces it as a selectable launcher row
    /// and only invokes the handler on Enter, instead of auto-running it on every
    /// keystroke. Lets an extension ship a "command that launches a UI" (ADR-002).
    let launches_window: Bool?

    /// True when this command depends on the local AI model (`host.llm`).
    var requiresModel: Bool { (requires ?? []).contains("model") }

    /// True when invoking this command opens its own window rather than returning
    /// an inline result (see `launches_window`).
    var launchesWindow: Bool { launches_window ?? false }

    /// All runner-mode prefixes for this command: the canonical `prefix` plus any
    /// `prefixes` aliases. Empty when the command declares no prefix.
    var allPrefixes: [String] { (prefix.map { [$0] } ?? []) + (prefixes ?? []) }
}

struct KeybindingContribution: Codable, Sendable, Equatable {
    let command: String
    let key: String
    let when: String?
}

/// A pluggable Settings section an extension contributes. Either a list of static
/// `controls` (host-rendered + host-persisted to `host.prefs`) and/or `dynamic`
/// to drive it from the extension's `settings_render`/`settings_action` handlers.
struct SettingsSection: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let icon: String?
    let accent: String?
    let subtitle: String?
    let placement: String?            // "sidebar" (default) | "inline"
    let dynamic: Bool?
    let controls: [SettingsControl]?

    var isInline: Bool { (placement ?? "sidebar") == "inline" }
    var isDynamic: Bool { dynamic ?? false }
    var allControls: [SettingsControl] { controls ?? [] }
}

/// One control in a Tier-A (static) settings section.
enum SettingsControlKind: String, Codable, Sendable {
    case group, toggle, text, secret, number, stepper
    case enumeration = "enum"
    case path, info, permission, button, link
}

struct SettingsControl: Codable, Sendable, Equatable {
    let kind: SettingsControlKind
    let key: String?                  // host.prefs key (value controls)
    let title: String?
    let subtitle: String?
    let `default`: TOMLValue?
    let values: [String]?
    let value_labels: [String]?
    let placeholder: String?
    let footer: String?               // group footer
    let id: String?                   // button action id (dispatched to Lua)
    let action: String?               // button native verb: "reveal" | "open-url" | "lua"
    let url: String?                  // link / open-url target
    let file: String?                 // reveal target path
    let name: String?                 // permission name
    let style: String?                // "neon" | "borderless" | "destructive"
    let min: Double?
    let max: Double?
    let step: Double?
    let visible_when: String?         // pref key (truthy) gating this control's visibility

    var controlStyle: String { style ?? "neon" }

    enum CodingKeys: String, CodingKey {
        case kind, key, title, subtitle, `default`, values, value_labels
        case placeholder, footer, id, action, url, file, name, style
        case min, max, step, visible_when
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(SettingsControlKind.self, forKey: .kind)
        key = try c.decodeIfPresent(String.self, forKey: .key)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        `default` = try c.decodeIfPresent(TOMLValue.self, forKey: .default)
        values = try c.decodeIfPresent([String].self, forKey: .values)
        value_labels = try c.decodeIfPresent([String].self, forKey: .value_labels)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        footer = try c.decodeIfPresent(String.self, forKey: .footer)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        style = try c.decodeIfPresent(String.self, forKey: .style)
        // TOML has distinct int/float literals and dduan/TOMLDecoder won't coerce
        // an integer (`min = 0`) into a Double — accept either so authors can write
        // whole numbers without a trailing `.0`.
        min = Self.lenientDouble(c, .min)
        max = Self.lenientDouble(c, .max)
        step = Self.lenientDouble(c, .step)
        visible_when = try c.decodeIfPresent(String.self, forKey: .visible_when)
    }

    private static func lenientDouble(_ c: KeyedDecodingContainer<CodingKeys>,
                                      _ key: CodingKeys) -> Double? {
        if let d = try? c.decode(Double.self, forKey: key) { return d }
        if let i = try? c.decode(Int.self, forKey: key) { return Double(i) }
        return nil
    }
}

struct PaletteEntry: Codable, Sendable, Equatable {
    let title: String
    let keywords: [String]?
    let url: String?
    let command: String?
}

enum ViewKind: String, Codable, Sendable {
    case sidebar, panel, overlay
    case menuBar = "menu-bar"
}

struct ViewContribution: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let kind: ViewKind
    let icon: String?
    let when: String?
}

/// A heterogeneous default value for a setting (string / number / bool).
enum TOMLValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported TOML default value type")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        }
    }

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        }
    }
}
