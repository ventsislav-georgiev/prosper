import SwiftUI

/// Editor for custom window layouts and their groups. Left: a group/layout list
/// with CRUD. Right: a paint-on-a-grid canvas — drag across cells to add a zone,
/// tap a zone to remove it. Zones are stored as normalized rects (0…1 over the
/// visible frame); the grid is only an input device, so its rows/cols are editor
/// state, not persisted.
struct LayoutEditorView: View {
    @Binding var store: LayoutStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedLayoutId: UUID?
    @State private var cols = 6
    @State private var rows = 4
    @State private var dragStart: Cell?
    @State private var dragCurrent: Cell?
    @State private var dragMoved = false

    private struct Cell: Equatable { var c: Int; var r: Int }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 240)
                Divider()
                canvas.frame(minWidth: 420, minHeight: 320)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(minWidth: 700, minHeight: 420)
        .onAppear { if selectedLayoutId == nil { selectedLayoutId = store.allLayouts.first?.id } }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedLayoutId) {
                ForEach(store.groups) { group in
                    Section(group.name) {
                        ForEach(group.layouts) { layout in
                            HStack {
                                Text(layout.name)
                                Spacer()
                                if layout.id == store.activeLayout?.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                }
                            }
                            .tag(layout.id)
                            .contextMenu {
                                Button("Set Active") { store.activeLayoutId = layout.id }
                                Button("Duplicate") { duplicate(layout, in: group.id) }
                                Button("Delete", role: .destructive) { deleteLayout(layout.id) }
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button { addLayout() } label: { Image(systemName: "plus") }
                    .help("New layout")
                Button { addGroup() } label: { Image(systemName: "folder.badge.plus") }
                    .help("New group")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    // MARK: - Canvas

    @ViewBuilder private var canvas: some View {
        if let layout = boundLayout {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Layout name", text: layout.name).textFieldStyle(.roundedBorder)
                Toggle("Move only (keep window size, just reposition)", isOn: Binding(
                    get: { layout.wrappedValue.isMoveOnly },
                    set: { layout.wrappedValue.moveOnly = $0 ? true : nil }))
                HStack {
                    Stepper("Cols: \(cols)", value: $cols, in: 1...12)
                    Stepper("Rows: \(rows)", value: $rows, in: 1...12)
                    Spacer()
                    Button("Clear zones") { layout.wrappedValue.zones.removeAll() }
                        .disabled(layout.wrappedValue.zones.isEmpty)
                }
                grid(layout)
                Text("\(layout.wrappedValue.zones.count) zone(s) · drag to add · tap to remove")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        } else {
            VStack { Text("Select or create a layout").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func grid(_ layout: Binding<WindowLayout>) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                // Cell grid background.
                Path { p in
                    for c in 0...cols { let x = w * CGFloat(c) / CGFloat(cols); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h)) }
                    for r in 0...rows { let y = h * CGFloat(r) / CGFloat(rows); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) }
                }
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)

                // Existing zones.
                ForEach(Array(layout.wrappedValue.zones.enumerated()), id: \.element.id) { idx, zone in
                    let r = zone.rect
                    Rectangle()
                        .fill(zoneColor(idx).opacity(0.35))
                        .overlay(Rectangle().stroke(zoneColor(idx), lineWidth: 2))
                        .frame(width: r.width * w, height: r.height * h)
                        .offset(x: r.minX * w, y: r.minY * h)
                }

                // Live drag selection.
                if let sel = selectionRect(w: w, h: h) {
                    Rectangle().fill(Color.accentColor.opacity(0.25))
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: sel.width, height: sel.height)
                        .offset(x: sel.minX, y: sel.minY)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            // Single gesture, no child tap: a parent DragGesture(minimumDistance:0)
            // plus a per-zone .onTapGesture would BOTH fire on a tap (default
            // arbitration), so deleting a zone also painted a 1-cell zone in its
            // place. One gesture decides: real drag → paint; zero-movement tap →
            // toggle the cell (delete the zone under it, else paint a 1-cell zone).
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    dragStart = dragStart ?? cell(at: v.startLocation, w: w, h: h)
                    dragCurrent = cell(at: v.location, w: w, h: h)
                    if abs(v.translation.width) > 4 || abs(v.translation.height) > 4 { dragMoved = true }
                }
                .onEnded { _ in
                    if dragMoved { commitZone(into: layout) }
                    else if let s = dragStart { toggleCell(s, into: layout) }
                    dragStart = nil; dragCurrent = nil; dragMoved = false
                })
        }
        .frame(height: 280)
    }

    // MARK: - Grid math

    private func cell(at p: CGPoint, w: CGFloat, h: CGFloat) -> Cell {
        let c = min(cols - 1, max(0, Int(p.x / (w / CGFloat(cols)))))
        let r = min(rows - 1, max(0, Int(p.y / (h / CGFloat(rows)))))
        return Cell(c: c, r: r)
    }

    private func selectionRect(w: CGFloat, h: CGFloat) -> CGRect? {
        guard let s = dragStart, let e = dragCurrent else { return nil }
        let c0 = min(s.c, e.c), c1 = max(s.c, e.c), r0 = min(s.r, e.r), r1 = max(s.r, e.r)
        let cw = w / CGFloat(cols), ch = h / CGFloat(rows)
        return CGRect(x: CGFloat(c0) * cw, y: CGFloat(r0) * ch,
                      width: CGFloat(c1 - c0 + 1) * cw, height: CGFloat(r1 - r0 + 1) * ch)
    }

    private func commitZone(into layout: Binding<WindowLayout>) {
        guard let s = dragStart, let e = dragCurrent else { return }
        let c0 = min(s.c, e.c), c1 = max(s.c, e.c), r0 = min(s.r, e.r), r1 = max(s.r, e.r)
        let rect = CGRect(x: CGFloat(c0) / CGFloat(cols), y: CGFloat(r0) / CGFloat(rows),
                          width: CGFloat(c1 - c0 + 1) / CGFloat(cols),
                          height: CGFloat(r1 - r0 + 1) / CGFloat(rows))
        layout.wrappedValue.zones.append(LayoutZone(rect: rect))
    }

    /// Zero-movement tap on cell `s`: remove the topmost zone under it, or — if the
    /// cell is empty — paint a 1-cell zone there. Pure id/rect math, testable via
    /// the same LayoutStore.hitZone the drag overlay uses.
    private func toggleCell(_ s: Cell, into layout: Binding<WindowLayout>) {
        let center = CGPoint(x: (CGFloat(s.c) + 0.5) / CGFloat(cols),
                             y: (CGFloat(s.r) + 0.5) / CGFloat(rows))
        if let hit = LayoutStore.hitZone(layout.wrappedValue.zones, normCursor: center) {
            layout.wrappedValue.zones.remove(at: hit)
        } else {
            layout.wrappedValue.zones.append(LayoutZone(rect: CGRect(
                x: CGFloat(s.c) / CGFloat(cols), y: CGFloat(s.r) / CGFloat(rows),
                width: 1 / CGFloat(cols), height: 1 / CGFloat(rows))))
        }
    }

    private func zoneColor(_ i: Int) -> Color {
        [.blue, .green, .orange, .purple, .pink, .teal, .red, .yellow][i % 8]
    }

    // MARK: - CRUD

    private var boundLayout: Binding<WindowLayout>? {
        guard let id = selectedLayoutId,
              store.allLayouts.contains(where: { $0.id == id }) else { return nil }
        // Resolve by id INSIDE get/set (not a captured index): a delete elsewhere in
        // the same render cycle would invalidate a captured index → out-of-range.
        return Binding(
            get: {
                for g in store.groups where g.layouts.contains(where: { $0.id == id }) {
                    return g.layouts.first { $0.id == id }!
                }
                return WindowLayout(name: "", zones: [])   // unreachable: guarded above
            },
            set: { newVal in
                for gi in store.groups.indices {
                    if let li = store.groups[gi].layouts.firstIndex(where: { $0.id == id }) {
                        store.groups[gi].layouts[li] = newVal; return
                    }
                }
            })
    }

    private func addGroup() {
        store.groups.append(LayoutGroup(name: "Group \(store.groups.count + 1)", layouts: []))
    }

    private func addLayout() {
        let gi = groupIndexForSelection()
        guard store.groups.indices.contains(gi) else { return }
        let new = WindowLayout(name: "Layout \(store.groups[gi].layouts.count + 1)", zones: [])
        store.groups[gi].layouts.append(new)
        selectedLayoutId = new.id
    }

    private func duplicate(_ layout: WindowLayout, in groupId: UUID) {
        guard let gi = store.groups.firstIndex(where: { $0.id == groupId }) else { return }
        var copy = layout
        copy.id = UUID()
        copy.name += " copy"
        copy.zones = copy.zones.map { LayoutZone(rect: $0.rect, label: $0.label) }
        store.groups[gi].layouts.append(copy)
        selectedLayoutId = copy.id
    }

    private func deleteLayout(_ id: UUID) {
        for gi in store.groups.indices {
            store.groups[gi].layouts.removeAll { $0.id == id }
        }
        if selectedLayoutId == id { selectedLayoutId = store.allLayouts.first?.id }
        if store.activeLayoutId == id { store.activeLayoutId = store.allLayouts.first?.id }
    }

    /// The group that should receive a new layout: the one holding the current
    /// selection, else the first group (creating one if the store is empty).
    private func groupIndexForSelection() -> Int {
        if let id = selectedLayoutId,
           let gi = store.groups.firstIndex(where: { $0.layouts.contains { $0.id == id } }) {
            return gi
        }
        if store.groups.isEmpty { store.groups.append(LayoutGroup(name: "Group 1", layouts: [])) }
        return 0
    }
}
