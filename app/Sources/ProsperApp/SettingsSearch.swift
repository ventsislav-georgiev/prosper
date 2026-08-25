import Foundation

/// Settings search: the index every settings pane and section is findable through.
///
/// Two halves. Native panes come from `nativeSettingsIndex` in
/// `SettingsIndex.generated.swift`, scraped out of the pane sources by
/// `app/scripts/gen-settings-index.py` so nobody hand-maintains a keyword table.
/// Extension panes come from `extensionSettingsIndex(registry:)`, read straight off
/// the manifests at runtime so they appear and vanish with the extension.
///
/// Idea (folded substring matching, section-level anchors) from vorssaint-utils
/// `UI/Settings/`; reimplemented, no lines copied.

/// A scroll target: a pane, and optionally one section inside it.
struct SettingsAnchor: Hashable {
    let pane: String
    /// `NeonSection` title, or `""` for the pane itself.
    let section: String
}

/// One searchable row: a pane, or a section within a pane.
struct SettingsIndexEntry: Hashable {
    /// `"general"`, `"audio-mixer"`, `"ext:com.prosper.calendar|main"`.
    let paneID: String
    /// Sidebar label for the pane, shown as the result's subtitle.
    let paneTitle: String
    /// `NeonSection` title, or `""` when this row *is* the pane.
    let section: String
    /// Extra terms that should match this row but appear nowhere in its titles.
    var keywords: [String] = []

    var anchor: SettingsAnchor { SettingsAnchor(pane: paneID, section: section) }
}

/// Escape hatch for panes whose visible text does not contain what people type.
/// Keyed by pane id, matched against the pane row only. Keep it short — a growing
/// list here means the section titles themselves are the thing to fix.
let extraSettingsKeywords: [String: [String]] = [
    "shortcuts": ["hotkey", "keybinding"],
    "agent-permissions": ["fda", "full disk access"],
    "audio-mixer": ["volume", "sound", "audio"],
    "general": ["clipboard history", "launch at login"],
]

enum SettingsSearch {
    /// Case- and accent-insensitive form used on both sides of every comparison.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    static func matches(_ query: String, _ entry: SettingsIndexEntry) -> Bool {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return false }
        if fold(entry.paneTitle).contains(needle) { return true }
        if fold(entry.section).contains(needle) { return true }
        var extras = entry.keywords
        if entry.section.isEmpty { extras += extraSettingsKeywords[entry.paneID] ?? [] }
        return extras.contains { fold($0).contains(needle) }
    }

    /// Matching rows in index order, which is sidebar order. Empty query → no rows,
    /// so the caller can keep showing the normal grouped rail.
    static func results(_ query: String, index: [SettingsIndexEntry]) -> [SettingsIndexEntry] {
        index.filter { matches(query, $0) }
    }
}

/// Everything the sidebar search field searches: the generated native table plus
/// the live extension one, narrowed to the panes `groups` is actually showing.
///
/// The narrowing is the point. `nativeSettingsIndex` is generated from the sources
/// and so lists every pane that *can* exist, including ones the rail hides right now
/// (a disabled feature category, a disabled extension). Offering those as results
/// would select a pane the user cannot navigate back to.
@MainActor
func settingsSearchIndex(registry: ExtensionRegistry?,
                         groups: [(String, [SettingsTab])]) -> [SettingsIndexEntry] {
    let visible = Set(groups.flatMap { $0.1.map(\.id) })
    let ext = registry.map { extensionSettingsIndex(registry: $0) } ?? []
    return (nativeSettingsIndex + ext).filter { visible.contains($0.paneID) }
}

/// Searchable rows for every sidebar-placed extension settings section.
///
/// One row for the pane, then one per `group` control — those are exactly the
/// `NeonSection`s `ExtensionSettingsPane` renders. The non-group controls under a
/// group ride along as its keywords: free recall, zero work for extension authors.
/// Dynamic sections are indexed at pane granularity only; rendering them means
/// running the extension's Lua, and typing in a search field must not do that.
@MainActor
func extensionSettingsIndex(registry: ExtensionRegistry) -> [SettingsIndexEntry] {
    var out: [SettingsIndexEntry] = []
    for (record, section) in registry.settingsSections(placement: "sidebar") {
        let paneID = "ext:\(record.id)|\(section.id)"
        out.append(SettingsIndexEntry(paneID: paneID, paneTitle: section.title, section: ""))
        guard !section.isDynamic else { continue }

        var group: SettingsIndexEntry?
        func flush() {
            if let group, !group.section.isEmpty { out.append(group) }
        }
        for control in section.allControls {
            if control.kind == .group {
                flush()
                group = SettingsIndexEntry(
                    paneID: paneID, paneTitle: section.title, section: control.title ?? "")
            } else if group != nil, let title = control.title {
                group?.keywords.append(title)
            }
        }
        flush()
    }
    return out
}
