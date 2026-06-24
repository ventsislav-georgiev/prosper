import CoreGraphics
import Foundation

/// What a drag-to-edge does: classic edge/corner halves (`edges`, the default,
/// unchanged behavior) or drop-into-zone of the active custom layout (`layouts`).
enum SnapMode: String, CaseIterable, Sendable {
    case edges, layouts, palette

    var title: String {
        switch self {
        case .edges: return "Edges & corners"
        case .layouts: return "Layout zones"
        case .palette: return "Layout palette"
        }
    }
}

/// A single tile in a window layout. `rect` is normalized 0…1 over a screen's
/// VISIBLE frame (Dock/menu-bar excluded) — never the full frame, so the drag
/// preview and the dropped window land in the same place. `label` is an optional
/// editor hint ("Main", "Side"…); it has no runtime effect.
struct LayoutZone: Codable, Equatable, Identifiable {
    var id: UUID
    var rect: CGRect          // normalized, over the visible frame
    var label: String?

    init(id: UUID = UUID(), rect: CGRect, label: String? = nil) {
        self.id = id
        self.rect = rect
        self.label = label
    }
}

/// A named set of tiles. Built-ins tile the screen without overlap; the editor
/// does NOT force this for custom layouts, so any overlap is resolved at hit-test
/// time (later zone wins — see `hitZone`). The drag overlay shows exactly these
/// zones and a drop places the dragged window into whichever zone the pointer is over.
struct WindowLayout: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var zones: [LayoutZone]
    /// Quick Positions: when true, a drop keeps the window's current size and only
    /// moves its origin to the zone anchor (clamped to the visible frame) instead
    /// of resizing it to fill the zone. Optional so layouts saved before this field
    /// decode cleanly — nil reads as false.
    var moveOnly: Bool?

    var isMoveOnly: Bool { moveOnly ?? false }

    init(id: UUID = UUID(), name: String, zones: [LayoutZone], moveOnly: Bool? = nil) {
        self.id = id
        self.name = name
        self.zones = zones
        self.moveOnly = moveOnly
    }
}

/// An organizational collection of layouts (e.g. "Work", "Coding"). Groups exist
/// only to browse/organize in the editor — the drag runtime resolves a single
/// active layout (`LayoutStore.activeLayoutId`) regardless of grouping.
struct LayoutGroup: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var layouts: [WindowLayout]

    init(id: UUID = UUID(), name: String, layouts: [WindowLayout]) {
        self.id = id
        self.name = name
        self.layouts = layouts
    }
}

/// Persisted root. The `schemaVersion` envelope means a future incompatible shape
/// can be detected and fall back to built-ins instead of silently wiping the
/// user's layouts (a bare `[LayoutGroup]` JSON has no version to gate on).
struct LayoutStore: Codable, Equatable {
    var schemaVersion: Int
    var groups: [LayoutGroup]
    var activeLayoutId: UUID?

    static let currentSchema = 1

    init(schemaVersion: Int = LayoutStore.currentSchema,
         groups: [LayoutGroup],
         activeLayoutId: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.activeLayoutId = activeLayoutId
    }

    /// Every layout across every group, flattened — for resolving the active one
    /// and for editor enumeration.
    var allLayouts: [WindowLayout] { groups.flatMap(\.layouts) }

    /// The layout the drag overlay shows. Falls back to the first available layout
    /// if the stored id is missing (deleted layout, fresh install).
    var activeLayout: WindowLayout? {
        if let id = activeLayoutId, let m = allLayouts.first(where: { $0.id == id }) { return m }
        return allLayouts.first
    }
}

// MARK: - Built-ins

extension LayoutStore {
    /// Default store used on a fresh install and whenever the persisted JSON fails
    /// to decode (corrupt / future schema). UUIDs are FIXED so `activeLayoutId`
    /// stays valid across launches — built-ins regenerated with random ids each
    /// launch would orphan the active selection.
    static var builtins: LayoutStore {
        LayoutStore(groups: [defaultGroup], activeLayoutId: uuid("00000000-0000-0000-0000-00000000a001"))
    }

    private static func uuid(_ s: String) -> UUID { UUID(uuidString: s)! }

    private static func zone(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                             _ label: String? = nil, _ id: String) -> LayoutZone {
        LayoutZone(id: uuid(id), rect: CGRect(x: x, y: y, width: w, height: h), label: label)
    }

    private static var defaultGroup: LayoutGroup {
        let third = CGFloat(1) / 3
        return LayoutGroup(
            id: uuid("00000000-0000-0000-0000-000000009001"),
            name: "Built-in",
            layouts: [
                // Halves
                WindowLayout(id: uuid("00000000-0000-0000-0000-00000000a001"), name: "Halves", zones: [
                    zone(0, 0, 0.5, 1, "Left",  "00000000-0000-0000-0000-00000000b001"),
                    zone(0.5, 0, 0.5, 1, "Right", "00000000-0000-0000-0000-00000000b002"),
                ]),
                // Thirds — mirrors the Lua window extension's thirds fractions exactly.
                WindowLayout(id: uuid("00000000-0000-0000-0000-00000000a002"), name: "Thirds", zones: [
                    zone(0, 0, third, 1, nil, "00000000-0000-0000-0000-00000000b003"),
                    zone(third, 0, third, 1, nil, "00000000-0000-0000-0000-00000000b004"),
                    zone(2 * third, 0, third, 1, nil, "00000000-0000-0000-0000-00000000b005"),
                ]),
                // Grid 2×2
                WindowLayout(id: uuid("00000000-0000-0000-0000-00000000a003"), name: "Grid 2×2", zones: [
                    zone(0, 0, 0.5, 0.5, nil, "00000000-0000-0000-0000-00000000b006"),
                    zone(0.5, 0, 0.5, 0.5, nil, "00000000-0000-0000-0000-00000000b007"),
                    zone(0, 0.5, 0.5, 0.5, nil, "00000000-0000-0000-0000-00000000b008"),
                    zone(0.5, 0.5, 0.5, 0.5, nil, "00000000-0000-0000-0000-00000000b009"),
                ]),
                // Main + side
                WindowLayout(id: uuid("00000000-0000-0000-0000-00000000a004"), name: "Main + side", zones: [
                    zone(0, 0, 2 * third, 1, "Main", "00000000-0000-0000-0000-00000000b00a"),
                    zone(2 * third, 0, third, 1, "Side", "00000000-0000-0000-0000-00000000b00b"),
                ]),
            ])
    }
}

// MARK: - Hit testing (pure)

extension LayoutStore {
    /// Which zone a normalized cursor (0…1 over the visible frame) lands in, or nil
    /// when the cursor is outside the screen's visible area. Iterates in reverse so
    /// a later (visually on-top) zone wins any overlap — harmless for clean tilings,
    /// correct if a custom layout ever overlaps.
    static func hitZone(_ zones: [LayoutZone], normCursor p: CGPoint) -> Int? {
        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
        for i in zones.indices.reversed() where zones[i].rect.contains(p) { return i }
        return nil
    }
}
