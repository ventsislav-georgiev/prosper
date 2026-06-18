import Foundation

/// The declarative UI contract between an extension and the host (ADR-002 §D7).
///
/// A `mode = "view"` command returns a JSON-encoded component **tree**; the host
/// decodes it into these value types and renders them as native SwiftUI — the
/// extension describes *structure*, never pixels, and ships no UI code. Inspired
/// by Raycast's component model and VSCode's strict contribution surface.
///
/// The supported root components are `list`, `detail`, `form`, and `grid`. This
/// is the entire v1 (api_level 1) UI surface — intentionally small, native, and
/// strictly typed so the look stays consistent and fast.
enum ExtensionViewNode: Decodable, Equatable {
    case list(ListNode)
    case detail(DetailNode)
    case form(FormNode)
    case grid(GridNode)
    case loading(LoadingNode)
    case converter(ConverterNode)

    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let tag = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch tag {
        case "list":      self = .list(try ListNode(from: decoder))
        case "detail":    self = .detail(try DetailNode(from: decoder))
        case "form":      self = .form(try FormNode(from: decoder))
        case "grid":      self = .grid(try GridNode(from: decoder))
        case "loading":   self = .loading(try LoadingNode(from: decoder))
        case "converter": self = .converter(try ConverterNode(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: try decoder.container(keyedBy: TypeKey.self),
                debugDescription: "unknown view component \"\(tag)\"")
        }
    }

    /// Decode a JSON component tree returned by an extension's view handler.
    static func decode(json: String) throws -> ExtensionViewNode {
        try JSONDecoder().decode(ExtensionViewNode.self, from: Data(json.utf8))
    }

    /// A built-in indeterminate spinner shown by the host while an async view
    /// command or action runs. Extensions never have to build this themselves.
    static func spinner(_ title: String? = nil, subtitle: String? = nil) -> ExtensionViewNode {
        .loading(LoadingNode(title: title, subtitle: subtitle, progress: nil))
    }

    var title: String? {
        switch self {
        case .list(let n):      return n.title
        case .detail(let n):    return n.title
        case .form(let n):      return n.title
        case .grid(let n):      return n.title
        case .loading(let n):   return n.title
        case .converter(let n): return n.title
        }
    }

    /// The text the runner's Enter key copies when this tree is shown inline (e.g.
    /// the primary translation). First list/grid item title, or the detail body.
    var primaryCopyText: String {
        switch self {
        case .list(let n):    return n.items.first?.title ?? ""
        case .grid(let n):    return n.items.first?.title ?? ""
        case .detail(let n):  return n.markdown
        case .converter(let n): return n.right.value ?? ""
        case .form, .loading: return ""
        }
    }
}

/// A button the user can trigger on an item, a form, or a detail view. When
/// fired, the host calls the extension's action handler with `id` (and, for
/// forms, the collected field values).
struct ExtensionAction: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let icon: String?
    /// Optional opaque value passed back to the extension (e.g. an item key).
    let value: String?
}

struct ListNode: Decodable, Equatable {
    let title: String?
    /// Optional trailing header text (e.g. Translate's "Detected: EN"), shown as a
    /// chip beside the title. Purely informational — not an item.
    let subtitle: String?
    let searchable: Bool?
    let items: [ListItem]
    /// Visual style of the inline list. `"cards"` (default) = stacked
    /// reading-focused cards with full wrapped text (Translate). `"rows"` =
    /// compact Raycast launcher rows with a leading icon and a trailing category
    /// label (the `open` app launcher — matches the native `o ` results 1:1).
    let style: String?

    var isSearchable: Bool { searchable ?? false }
    /// True when the extension asked for compact launcher rows rather than cards.
    var isRowStyle: Bool { style == "rows" }
}

struct ListItem: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String?
    /// Trailing accessory text (e.g. a shortcut, a count).
    let accessory: String?
    let actions: [ExtensionAction]?
    /// Absolute file path whose Finder icon is shown as the leading glyph instead
    /// of an SF Symbol (e.g. an app bundle's real icon in the `open` launcher).
    let image: String?
    /// Absolute file path / URL the host opens natively when this row is
    /// committed (Enter / click) — e.g. an app bundle to launch. Lets a declarative
    /// extension list trigger a native side-effect without a Lua action round-trip.
    let launch: String?
    /// A web/deeplink URL the host opens natively when this row is committed
    /// (e.g. a bookmark). Routed through the same URL-open + favicon path as
    /// Quicklinks, so http(s) rows show the page's favicon. Distinct from
    /// `launch` (which is treated as a file/app-bundle path).
    let url: String?

    var allActions: [ExtensionAction] { actions ?? [] }
}

struct DetailNode: Decodable, Equatable {
    let title: String?
    /// Markdown body, rendered natively.
    let markdown: String
    let actions: [ExtensionAction]?

    var allActions: [ExtensionAction] { actions ?? [] }
}

struct GridNode: Decodable, Equatable {
    let title: String?
    let columns: Int?
    let items: [ListItem]

    var columnCount: Int { max(1, columns ?? 3) }
}

/// A loading state. `progress` absent / null → an indeterminate (infinite)
/// spinner; a value in 0…1 → a determinate (progressive) bar with a percentage.
/// Built by `host.ui.loading{ title=, subtitle=, progress= }`, and also shown
/// automatically by the host while an async view command or action is in flight.
struct LoadingNode: Decodable, Equatable {
    let title: String?
    let subtitle: String?
    let progress: Double?

    /// Clamped to 0…1; nil stays nil (indeterminate).
    var clampedProgress: Double? { progress.map { min(max($0, 0), 1) } }
}

struct FormNode: Decodable, Equatable {
    let title: String?
    let fields: [FormField]
    let actions: [ExtensionAction]?

    var allActions: [ExtensionAction] { actions ?? [] }
}

enum FormFieldKind: String, Decodable, Equatable {
    case text, password, toggle, dropdown, number, textarea
}

struct FormField: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let kind: FormFieldKind
    let value: String?
    let options: [String]?
    let placeholder: String?

    var allOptions: [String] { options ?? [] }
    var defaultValue: String { value ?? "" }
}

/// One side of a `converter`: a labelled, editable text pane.
struct ConverterPane: Decodable, Equatable {
    let label: String?
    let placeholder: String?
    let value: String?
}

/// A live, bidirectional two-pane transform window (e.g. Base64 encode/decode).
/// Editing the LEFT pane runs the `forward` extension function over its text and
/// writes the result into the RIGHT pane; editing the RIGHT pane runs `backward`
/// into the LEFT. `forward`/`backward` are the names of global Lua functions in
/// the owning extension's VM — each takes the edited text and returns the
/// transformed string. This is the canonical "window with predefined controls"
/// an extension opens via `host.window.open` (ADR-002 §D7).
struct ConverterNode: Decodable, Equatable {
    let title: String?
    let left: ConverterPane
    let right: ConverterPane
    /// Global Lua function name: left text → right text.
    let forward: String
    /// Global Lua function name: right text → left text.
    let backward: String
    /// Render the panes with a monospaced font (default true — most converters
    /// deal in code-like text such as Base64 / hex / JSON).
    let mono: Bool?

    var isMonospaced: Bool { mono ?? true }
}
