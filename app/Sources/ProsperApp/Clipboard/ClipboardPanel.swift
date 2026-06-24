import AppKit
import SwiftUI

/// Floating clipboard-history panel (⇧⌥A), Raycast-style: searchable list on
/// the left, preview on the right. Enter / click pastes the selected entry into
/// the previously focused app; ⌘⌫ removes an entry; ⌘. pins; ⌘E renames;
/// ⌘P cycles the type filter; Esc dismisses.
@MainActor
final class ClipboardPanel {

    private let panel: KeyablePanel
    private let store = ClipboardStore.shared
    private let model = ClipboardPanelModel()
    private var previousApp: NSRunningApplication?

    var isShown: Bool { panel.isVisible }

    init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let root = ClipboardView(
            store: store,
            model: model,
            onCommit: { [weak self] item in self?.commit(item) },
            onCopy: { [weak self] item in self?.copyOnly(item) },
            onCancel: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: Themed { root })
        // The SwiftUI root fixes width (750) and has an intrinsic height (search bar
        // + pinned list viewport + action bar). Size the borderless panel to that
        // fitting height so the list viewport stays an exact pitch multiple.
        let fitH = hosting.fittingSize.height
        let contentH = fitH > 100 ? fitH : 520
        panel.setContentSize(NSSize(width: 750, height: contentH))
        hosting.frame = NSRect(x: 0, y: 0, width: 750, height: contentH)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        // masksToBounds OFF: clipping the host layer forces offscreen compositing,
        // which kills the Frost backdrop's `.behindWindow` sampling (same lesson as
        // FootprintWindow). `neonPanelSurface().clipShape` already rounds the content.
        hosting.layer?.masksToBounds = false
        panel.contentView = hosting
    }

    func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        model.reset(selecting: store.items.first?.id)
        positionRelativeToRunner()
        DockPolicy.windowDidShow(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.focusRequested = false
        DispatchQueue.main.async { [weak self] in self?.model.focusRequested = true }
    }

    /// Opens centered on the command runner's remembered position (so both panels
    /// live in the same spot), clamped to the runner's screen. Falls back to
    /// screen-center when the runner has never been moved.
    private func positionRelativeToRunner() {
        let size = panel.frame.size
        guard let tl = RunnerPanel.savedTopLeft() else { panel.center(); return }

        let runnerCenterX = tl.x + RunnerPanel.runnerWidth / 2
        // Horizontally centered on the runner; raised by 30% of its height above
        // the runner's top edge so it sits higher than the runner.
        var origin = NSPoint(x: runnerCenterX - size.width / 2, y: tl.top - size.height * 0.7)

        let probe = NSPoint(x: runnerCenterX, y: tl.top - 1)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    func dismiss() {
        panel.orderOut(nil)
        DockPolicy.windowDidHide(panel)
    }

    /// ⌘C: copy the selected entry to the system pasteboard and close, WITHOUT
    /// pasting into the previous app (that's Enter's job). Raycast-parity.
    private func copyOnly(_ item: ClipboardItem) {
        store.copyToPasteboard(item)
        dismiss()
    }

    private func commit(_ item: ClipboardItem) {
        store.copyToPasteboard(item)
        dismiss()
        let target = previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            target?.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Self.pasteViaCmdV()
            }
        }
    }

    private static func pasteViaCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }
}

// MARK: - View model

@MainActor
final class ClipboardPanelModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedId: UUID?
    @Published var focusRequested: Bool = false
    /// Active type filter; `nil` = all kinds.
    @Published var typeFilter: ClipboardKind?

    /// Live map of each rendered row's y-span in the scroll viewport. Deliberately
    /// NOT @Published: the ⌃-digit slots are a fixed overlay, so updating this on
    /// every scroll frame must not invalidate the row list (that caused the lag).
    /// Read on demand by the ⌃1…⌃0 paste handler to resolve which row sits under
    /// a slot.
    var rowFrames: [UUID: RowSpan] = [:]
    /// Scroll viewport height, captured alongside `rowFrames`. Same non-published
    /// rationale; used by the paste handler to rank visible rows.
    var viewportHeight: CGFloat = 0

    func reset(selecting id: UUID?) {
        query = ""
        typeFilter = nil
        selectedId = id
    }

    /// Cycles: all → text → link → email → color → image → file → all.
    func cycleFilter() {
        let order: [ClipboardKind?] = [nil, .text, .link, .email, .color, .image, .file]
        let i = order.firstIndex(of: typeFilter) ?? 0
        typeFilter = order[(i + 1) % order.count]
    }
}

// MARK: - Scroll-position tracking

/// A row's vertical extent within the scroll view's coordinate space. Negative
/// `minY` means the row has scrolled above the visible top edge.
struct RowSpan: Equatable {
    var minY: CGFloat
    var maxY: CGFloat
}

/// Collects each visible row's `RowSpan`, keyed by item id, so the view model can
/// derive which row sits at the top of the viewport.
private struct RowFrameKey: PreferenceKey {
    // Computed (get-only) rather than a stored `static var`: a mutable static is
    // nonisolated global shared mutable state under Swift 6 strict concurrency.
    static var defaultValue: [UUID: RowSpan] { [:] }
    static func reduce(value: inout [UUID: RowSpan], nextValue: () -> [UUID: RowSpan]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Section model

private enum ClipboardSection: String, CaseIterable {
    case pinned = "Pinned"
    case today = "Today"
    case yesterday = "Yesterday"
    case previous7 = "Previous 7 Days"
    case previous30 = "Previous 30 Days"
    case older = "Older"
}

private struct SectionedItems {
    struct Group: Identifiable {
        var id: ClipboardSection { section }
        let section: ClipboardSection
        var items: [ClipboardItem]
    }
    var groups: [Group]
}

private func bucket(_ items: [ClipboardItem]) -> SectionedItems {
    let cal = Calendar.current
    let now = Date()
    var pinned: [ClipboardItem] = []
    var today: [ClipboardItem] = []
    var yesterday: [ClipboardItem] = []
    var prev7: [ClipboardItem] = []
    var prev30: [ClipboardItem] = []
    var older: [ClipboardItem] = []

    for item in items {
        if item.pinned {
            pinned.append(item)
            continue
        }
        let days = cal.dateComponents([.day], from: item.createdAt, to: now).day ?? 0
        if cal.isDateInToday(item.createdAt) {
            today.append(item)
        } else if cal.isDateInYesterday(item.createdAt) {
            yesterday.append(item)
        } else if days < 7 {
            prev7.append(item)
        } else if days < 30 {
            prev30.append(item)
        } else {
            older.append(item)
        }
    }

    var groups: [SectionedItems.Group] = []
    if !pinned.isEmpty { groups.append(.init(section: .pinned, items: pinned)) }
    if !today.isEmpty { groups.append(.init(section: .today, items: today)) }
    if !yesterday.isEmpty { groups.append(.init(section: .yesterday, items: yesterday)) }
    if !prev7.isEmpty { groups.append(.init(section: .previous7, items: prev7)) }
    if !prev30.isEmpty { groups.append(.init(section: .previous30, items: prev30)) }
    if !older.isEmpty { groups.append(.init(section: .older, items: older)) }
    return SectionedItems(groups: groups)
}

// MARK: - SwiftUI

private struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var model: ClipboardPanelModel
    let onCommit: (ClipboardItem) -> Void
    let onCopy: (ClipboardItem) -> Void
    let onCancel: () -> Void

    @FocusState private var searchFocused: Bool

    private var filtered: [ClipboardItem] {
        let q = model.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.items.filter { item in
            if let kind = model.typeFilter, item.kind != kind { return false }
            guard !q.isEmpty else { return true }
            return item.preview.lowercased().contains(q)
                || (item.title?.lowercased().contains(q) ?? false)
                || (item.fileName?.lowercased().contains(q) ?? false)
        }
    }

    private var sectioned: SectionedItems { bucket(filtered) }

    /// The list flattened in the exact top-to-bottom order it renders (pinned
    /// first, then the date buckets). Drives both the position-key badges and the
    /// ⌃1…⌃0 shortcuts so the digit always matches the row's visual position.
    private var orderedItems: [ClipboardItem] { sectioned.groups.flatMap(\.items) }

    private static let scrollSpace = "clipScroll"
    /// Scroll id of the zero-height anchor above the first section — the target
    /// for "reveal the very first item" (see the selection-change handler).
    private static let topAnchorId = "clipTop"

    // ── ⌃-digit slots (fixed grid) ───────────────────────────────────────────
    // Rows AND section headers are forced to the same `rowPitch`, so the list is
    // a perfectly uniform stack starting at `topInset`. The badges sit on a fixed
    // ladder of constant viewport-Y cell centers (`topInset + pitch/2 + i·pitch`)
    // — they never move on scroll; rows slide underneath. Each cell is matched to
    // the row whose measured center currently falls in its ±pitch/2 band; header
    // cells contain no row and are skipped, so ⌃1…⌃0 stay sequential over real
    // items and ⌃0 always renders once a tenth row is on screen. `.viewAligned`
    // scroll snapping keeps rows resting on this same grid, so at rest every badge
    // sits exactly on its row. Both the overlay and the ⌃1…⌃0 paste handler call
    // this, so digit and row always agree.

    /// Row/header pitch. Rows and headers are pinned to this height so every
    /// element lands on a single uniform grid the badge ladder shares.
    static let rowPitch: CGFloat = 38
    /// Top padding inside the scroll view. Zero so a `.top`-aligned reveal lands a
    /// row at grid phase 0 (no fractional offset against the fixed badge ladder).
    private static let topInset: CGFloat = 0
    /// Header (1 cell) + ten item rows. The scroll viewport is pinned to exactly
    /// this many cells so a single-row reveal scrolls by exactly one pitch, keeping
    /// every row on the fixed badge grid after keyboard navigation.
    private static let visibleCells = 11
    /// Pinned scroll-viewport height = an exact pitch multiple. This is what makes
    /// `scrollTo` reveals land on the grid (no half-row drift).
    static let listViewportH: CGFloat = topInset + CGFloat(visibleCells) * rowPitch
    /// A cell whose center is above this is behind the pinned top section header,
    /// so it gets no badge.
    private static let headerCutoff: CGFloat = 26

    /// Fixed badge slots, top-to-bottom. Slot `centerY` values come from the
    /// constant grid (never the scrolled row position), so badges hold their
    /// viewport Y while rows scroll beneath. Each returned slot is a grid cell
    /// that currently has a row in it; header cells are skipped so digits stay
    /// sequential over items. Capped at ten (⌃1…⌃0).
    private static func visibleSlots(_ frames: [UUID: RowSpan], height: CGFloat)
        -> [(id: UUID?, centerY: CGFloat)] {
        guard height > topInset else { return [] }
        let centers = frames.map { (id: $0.key, c: ($0.value.minY + $0.value.maxY) / 2) }
        var slots: [(id: UUID?, centerY: CGFloat)] = []
        var cell = 0
        while true {
            let cellCenter = topInset + rowPitch / 2 + CGFloat(cell) * rowPitch
            if cellCenter > height - 4 { break }
            cell += 1
            // Top cell sits behind the pinned section header — no badge there.
            if cellCenter < headerCutoff { continue }
            // The row whose measured center falls in this cell's band owns the
            // slot. Header cells have no such row → skipped (no badge, no digit).
            if let row = centers.first(where: { abs($0.c - cellCenter) <= rowPitch / 2 }) {
                slots.append((id: Optional(row.id), centerY: cellCenter))
                if slots.count == 10 { break }
            }
        }
        return slots
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Search + filter bar ──────────────────────────────────────────
            HStack(spacing: sz(8)) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Neon.blue)
                    .font(Neon.font(14))
                TextField("Type to filter entries\u{2026}", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(Neon.font(14))
                    .focused($searchFocused)
                Spacer()
                typeFilterMenu
            }
            .padding(.horizontal, sz(14))
            .padding(.vertical, sz(10))

            Divider()

            if store.items.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    listPane
                    Divider()
                    previewPane
                }
                // Scroll viewport pinned to an exact pitch multiple so reveals land
                // on the badge grid (see `listViewportH`).
                .frame(maxWidth: .infinity, minHeight: Self.listViewportH,
                       maxHeight: Self.listViewportH)
            }

            Divider()
            actionBar
        }
        // Width fixed; height is intrinsic (search bar + pinned `listViewportH` +
        // action bar) and the hosting window is sized to match in `ClipboardPanel`.
        .frame(width: 750)
        .neonPanelSurface()
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequested) { _, req in
            if req { searchFocused = true; model.focusRequested = false }
        }
        .background(ClipboardKeyHandling(
            onCancel: onCancel,
            onEnter: { commitSelected() },
            onCopy: { copySelected() },
            onDelete: { deleteSelected() },
            onMove: { move($0) },
            onPin: { pinSelected() },
            onRename: { renameSelected() },
            onFilter: { model.cycleFilter() },
            onNumber: { commitAt($0) },
            onClear: { model.query = "" }
        ))
    }

    // MARK: - Type-filter dropdown

    private var typeFilterMenu: some View {
        Menu {
            Button {
                model.typeFilter = nil
            } label: {
                HStack {
                    Text("All Types")
                    if model.typeFilter == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            ForEach(ClipboardKind.allCases, id: \.self) { kind in
                Button {
                    model.typeFilter = kind
                } label: {
                    HStack {
                        Label(kind.rawValue.capitalized, systemImage: icon(for: kind))
                        if model.typeFilter == kind {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: sz(4)) {
                if let kind = model.typeFilter {
                    Image(systemName: icon(for: kind)).font(Neon.font(.caption2))
                    Text(kind.rawValue.capitalized).font(Neon.font(.caption))
                } else {
                    Text("All Types").font(Neon.font(.caption))
                }
                Image(systemName: "chevron.down").font(Neon.font(9, weight: .semibold))
            }
            .padding(.horizontal, sz(8))
            .padding(.vertical, sz(4))
            .background(
                RoundedRectangle(cornerRadius: sz(6))
                    .fill(model.typeFilter != nil ? Neon.blue.opacity(0.16) : Neon.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: sz(6))
                            .strokeBorder(Neon.blue.opacity(model.typeFilter != nil ? 0.5 : 0.15), lineWidth: 1))
            )
            .foregroundColor(model.typeFilter != nil ? Neon.blueBright : Neon.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by type  ⌘P to cycle")
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: sz(10)) {
            Image(systemName: "clipboard")
                .font(Neon.font(36, weight: .light))
                .foregroundColor(Neon.blue.opacity(0.6))
            Text("No clipboard history yet")
                .font(Neon.font(.headline))
                .foregroundColor(Neon.textPrimary)
            Text("Copy text, images, or files and they'll appear here.")
                .font(Neon.font(.caption))
                .foregroundColor(Neon.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: Self.listViewportH,
               maxHeight: Self.listViewportH)
    }

    // MARK: - List pane (left)

    private var listPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    // Zero-height top anchor: scrolling here puts the first section
                    // header in cell 0 and the first ITEM in the first badge cell.
                    // Top-aligning the first item directly would hide it behind the
                    // pinned header (headers float over the row at y 0).
                    Color.clear.frame(height: 0).id(Self.topAnchorId)
                    ForEach(sectioned.groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                // A dedicated struct (NOT an inline `listRow(item)`
                                // method) so SwiftUI tracks `isSelected` as a per-row
                                // dependency and re-renders the row when selection
                                // moves. With a method-returned view the LazyVStack
                                // keeps the realized row (keyed by `.id(item.id)`) and
                                // the captured highlight went stale — the previously
                                // selected row kept its card while selection moved on.
                                ClipRowView(store: store, item: item,
                                            isSelected: item.id == model.selectedId) {
                                    model.selectedId = item.id
                                    onCommit(item)
                                }
                                .id(item.id)
                                .background(rowFrameReporter(item.id))
                            }
                        } header: {
                            sectionHeader(group.section)
                        }
                    }
                }
                .scrollTargetLayout()
                // Top padding 0 (grid phase 0); small bottom pad for scroll comfort.
                .padding(.bottom, sz(4))
            }
            // Snap rows onto the badge grid at rest: a free trackpad fling settles
            // with rows aligned to the fixed ⌃-digit ladder (transient offset only
            // mid-fling). Arrow-key nav already lands row-by-row via `scrollTo`.
            .scrollTargetBehavior(.viewAligned)
            .coordinateSpace(name: Self.scrollSpace)
            // Always show the scrollbar so there's a persistent hint that more rows
            // exist above/below the fold.
            .scrollIndicators(.visible)
            .onChange(of: model.selectedId) { _, id in
                guard let id else { return }
                let frames = model.rowFrames
                let h = model.viewportHeight
                // No geometry yet, or the row isn't measured (far off-screen) →
                // minimal default reveal.
                guard h > 0, let span = frames[id] else { proxy.scrollTo(id); return }
                if span.minY < Self.headerCutoff {
                    // Selected row sits in the top cell, behind the pinned section
                    // header. Top-align the PREVIOUS item so the header takes the
                    // top cell and the selection drops to the first full slot below
                    // it. Scrolls by whole pitches → grid phase preserved.
                    // First item overall has no previous item: top-aligning it would
                    // park it at y 0 BEHIND the pinned header (invisible). Scroll to
                    // the absolute top instead — header lands in cell 0, the item in
                    // the first badge cell.
                    if let prev = prevItemId(before: id) {
                        proxy.scrollTo(prev, anchor: .top)
                    } else {
                        proxy.scrollTo(Self.topAnchorId, anchor: .top)
                    }
                } else if span.maxY > h {
                    // Below the fold → reveal at the bottom edge. The viewport is an
                    // exact pitch multiple, so this scrolls exactly one pitch and the
                    // row lands on the grid (badges stay fixed AND aligned).
                    proxy.scrollTo(id)
                }
                // Else fully visible → leave the list put (no recentering).
            }
            // ⌃-digit overlay: a fixed ladder of badges at constant viewport Y —
            // they don't move on scroll; rows slide beneath. Reads frames from the
            // preference (no @Published write → no list rebuild on scroll) only to
            // map each fixed slot to the row currently under it + the paste handler.
            .overlayPreferenceValue(RowFrameKey.self) { frames in
                slotOverlay(frames)
            }
        }
        .frame(width: sz(300))
    }

    private func slotOverlay(_ frames: [UUID: RowSpan]) -> some View {
        GeometryReader { geo in
            // The ladder lives in its own view so badge re-renders never touch the
            // row list (which must not rebuild on scroll). Positions are fixed;
            // only the highlight + the labeled row under each slot change.
            SlotLadderOverlay(slots: Self.visibleSlots(frames, height: geo.size.height),
                              width: geo.size.width,
                              selectedId: model.selectedId)
            // Capture frames + viewport height for the keyboard paste handler.
            // Non-published store, so these assignments don't trigger a view rebuild.
            // `initial: true` is required: without it the capture only happens on a
            // frame CHANGE (i.e. first scroll), leaving viewportHeight at 0 — which
            // made ⌃-digit paste a silent no-op until the user scrolled.
            Color.clear.onChange(of: frames, initial: true) { _, f in
                model.rowFrames = f
                model.viewportHeight = geo.size.height
            }
        }
    }

    /// Transparent overlay that reports a row's y-span in the scroll coordinate
    /// space, feeding `RowFrameKey` for slot-to-row resolution.
    private func rowFrameReporter(_ id: UUID) -> some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(Self.scrollSpace))
            Color.clear.preference(
                key: RowFrameKey.self,
                value: [id: RowSpan(minY: frame.minY, maxY: frame.maxY)])
        }
    }

    private func sectionHeader(_ section: ClipboardSection) -> some View {
        Text(section.rawValue)
            .font(Neon.font(11, weight: .bold))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundColor(Neon.textSecondary)
            .padding(.horizontal, sz(14))
            // Header occupies exactly one grid cell so rows below it stay on the
            // fixed ⌃-digit grid (a sub-pitch header would shove them off-ladder).
            .frame(maxWidth: .infinity, minHeight: Self.rowPitch, maxHeight: Self.rowPitch,
                   alignment: .leading)
            // Opaque so a row scrolling up underneath the pinned header is fully
            // occluded rather than ghosting through it.
            .background(Neon.bgTop)
            // Hairline so the header reads as separate from the first row instead
            // of the row's selection card blending into it.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Neon.blue.opacity(0.18))
                    .frame(height: 1)
            }
    }


    // MARK: - Preview pane (right)

    @ViewBuilder
    private var previewPane: some View {
        if let item = filtered.first(where: { $0.id == model.selectedId }) ?? filtered.first {
            VStack(spacing: 0) {
                // Content preview area
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        contentPreview(item)
                            .padding(sz(16))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Information section
                informationSection(item)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func contentPreview(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .text, .link, .email:
            SelectableText(text: store.text(for: item) ?? item.preview)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .color:
            colorPreviewContent(item)

        case .image:
            if let data = store.imageData(for: item), let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .cornerRadius(sz(8))
            } else {
                imagePlaceholder
            }

        case .file:
            HStack(spacing: sz(12)) {
                if let path = item.sourcePath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: sz(40), height: sz(40))
                }
                VStack(alignment: .leading, spacing: sz(4)) {
                    Text(item.fileName ?? item.preview)
                        .font(Neon.font(14, weight: .medium))
                        .foregroundColor(Neon.textPrimary)
                    if let path = item.sourcePath {
                        Text(path)
                            .font(Neon.font(.caption2))
                            .foregroundColor(Neon.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func colorPreviewContent(_ item: ClipboardItem) -> some View {
        let value = store.text(for: item) ?? item.preview
        VStack(alignment: .leading, spacing: sz(10)) {
            RoundedRectangle(cornerRadius: sz(10))
                .fill(ClipboardView.swatch(value).map(Color.init) ?? Color.gray.opacity(0.2))
                .frame(height: sz(100))
                .overlay(RoundedRectangle(cornerRadius: sz(10)).strokeBorder(Color.secondary.opacity(0.2)))
            Text(value)
                .font(Neon.font(13, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: sz(8))
            .fill(Color.secondary.opacity(0.1))
            .frame(height: sz(80))
            .overlay(
                Image(systemName: "photo")
                    .foregroundColor(.secondary.opacity(0.4))
                    .font(Neon.font(24))
            )
    }

    // MARK: - Information section

    private func informationSection(_ item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Information")
                    .font(Neon.font(11, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundColor(Neon.textSecondary)
                Spacer()
            }
            .padding(.horizontal, sz(14))
            .padding(.top, sz(10))
            .padding(.bottom, sz(6))

            VStack(spacing: 0) {
                infoRow("Content Type", value: item.kind.rawValue.capitalized)
                if let src = item.sourcePath {
                    infoRow("Source", value: (item.fileName ?? URL(fileURLWithPath: src).lastPathComponent))
                } else if let name = item.fileName {
                    infoRow("Source", value: name)
                }
                infoRow("Size", value: formattedSize(item))
                if item.kind == .image, let dims = imageDimensions(item) {
                    infoRow("Dimensions", value: dims)
                }
                infoRow("Date Copied", value: formattedDate(item.createdAt))
                infoRow("Pinned", value: item.pinned ? "Yes" : "No")
            }
            .padding(.horizontal, sz(14))
            .padding(.bottom, sz(10))
        }
        .background(Neon.bgBottom.opacity(0.5))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: sz(8)) {
            Text(label)
                .font(Neon.font(11))
                .foregroundColor(Neon.textSecondary)
                .frame(width: sz(90), alignment: .trailing)
            Text(value)
                .font(Neon.font(11))
                .foregroundColor(Neon.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(.vertical, sz(3))
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            // LEFT: app icon + "Clipboard History" label
            HStack(spacing: sz(6)) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: sz(16), height: sz(16))
                    .cornerRadius(sz(3))
                Text("Clipboard History")
                    .font(Neon.font(11, weight: .medium))
                    .foregroundColor(Neon.textSecondary)
            }

            Spacer()

            // RIGHT: "Paste to <frontApp>  ↩"  |  "Actions  ⌘K"
            HStack(spacing: 0) {
                // Paste button
                Button(action: { commitSelected() }) {
                    HStack(spacing: sz(5)) {
                        Text("Paste")
                            .font(Neon.font(11, weight: .medium))
                            .foregroundColor(Neon.blueBright)
                        Text("↩")
                            .font(Neon.font(11))
                            .foregroundColor(Neon.textSecondary)
                    }
                    .padding(.horizontal, sz(8))
                    .padding(.vertical, sz(4))
                    .background(
                        RoundedRectangle(cornerRadius: sz(5))
                            .fill(Neon.blue.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: sz(5))
                                .strokeBorder(Neon.blue.opacity(0.4), lineWidth: 1)))
                }
                .buttonStyle(.plain)

                // Divider
                Rectangle()
                    .fill(Neon.stroke)
                    .frame(width: 1, height: sz(14))
                    .padding(.horizontal, sz(6))

                // Actions ⌘K menu
                if let item = filtered.first(where: { $0.id == model.selectedId }) ?? filtered.first {
                    Menu {
                        Button { onCopy(item) } label: {
                            Label("Copy to Clipboard", systemImage: "doc.on.doc")
                        }
                        Button {
                            pinSelected()
                        } label: {
                            Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin")
                        }
                        Button { renameSelected() } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) { deleteSelected() } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        HStack(spacing: sz(5)) {
                            Text("Actions")
                                .font(Neon.font(11, weight: .medium))
                                .foregroundColor(Neon.blueBright)
                            Text("⌘K")
                                .font(Neon.font(11))
                                .foregroundColor(Neon.textSecondary)
                        }
                        .padding(.horizontal, sz(8))
                        .padding(.vertical, sz(4))
                        .background(
                            RoundedRectangle(cornerRadius: sz(5))
                                .fill(Neon.blue.opacity(0.14))
                                .overlay(RoundedRectangle(cornerRadius: sz(5))
                                    .strokeBorder(Neon.blue.opacity(0.4), lineWidth: 1)))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, sz(14))
        .padding(.vertical, sz(8))
    }

    // MARK: - Helpers

    private func icon(for kind: ClipboardKind) -> String { clipboardKindIcon(kind) }

    private func formattedSize(_ item: ClipboardItem) -> String {
        if item.kind.isTextual {
            let chars = item.byteCount  // UTF-8 bytes ≈ chars for ASCII; good enough as label
            let size = ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)
            return "\(chars) chars · \(size)"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)
    }

    private func formattedDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private func imageDimensions(_ item: ClipboardItem) -> String? {
        guard item.kind == .image,
              let data = store.imageData(for: item),
              let img = NSImage(data: data) else { return nil }
        let size = img.size
        return "\(Int(size.width)) × \(Int(size.height)) px"
    }

    /// Parses a hex color string (`#rgb`/`#rrggbb`/`#rrggbbaa`) into an NSColor
    /// for the swatch. Functional `rgb()/hsl()` forms aren't parsed (nil → gray).
    static func swatch(_ s: String) -> NSColor? {
        var hex = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        func expand(_ c: Substring) -> String { c.map { "\($0)\($0)" }.joined() }
        switch hex.count {
        case 3: hex = expand(hex[...]) + "ff"
        case 4: hex = expand(hex[...])
        case 6: hex += "ff"
        case 8: break
        default: return nil
        }
        guard let v = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((v >> 24) & 0xff) / 255
        let g = CGFloat((v >> 16) & 0xff) / 255
        let b = CGFloat((v >> 8) & 0xff) / 255
        let a = CGFloat(v & 0xff) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Keyboard actions

    private func commitSelected() {
        guard let item = filtered.first(where: { $0.id == model.selectedId }) ?? filtered.first else { return }
        onCommit(item)
    }

    /// The item immediately above `id` in visual order (nil if it's the first).
    /// Used to top-align the predecessor so a header-occluded selection drops into
    /// the first full slot below the pinned header.
    private func prevItemId(before id: UUID) -> UUID? {
        let items = orderedItems
        guard let idx = items.firstIndex(where: { $0.id == id }), idx > 0 else { return nil }
        return items[idx - 1].id
    }

    /// ⌃1…⌃0: paste the `position`-th visible row (0-based, top-to-bottom),
    /// matching the badge overlay's row resolution exactly.
    private func commitAt(_ position: Int) {
        let slots = Self.visibleSlots(model.rowFrames, height: model.viewportHeight)
        guard position < slots.count, let id = slots[position].id,
              let item = orderedItems.first(where: { $0.id == id }) else { return }
        model.selectedId = item.id
        onCommit(item)
    }

    private func copySelected() {
        guard let item = filtered.first(where: { $0.id == model.selectedId }) ?? filtered.first else { return }
        onCopy(item)
    }

    private func deleteSelected() {
        guard let item = filtered.first(where: { $0.id == model.selectedId }) else { return }
        let nextId = filtered.drop(while: { $0.id != item.id }).dropFirst().first?.id
            ?? filtered.first(where: { $0.id != item.id })?.id
        store.delete(item)
        model.selectedId = nextId
    }

    private func pinSelected() {
        guard let item = filtered.first(where: { $0.id == model.selectedId }) else { return }
        store.togglePin(item)
    }

    private func renameSelected() {
        guard let item = filtered.first(where: { $0.id == model.selectedId }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename clipboard entry"
        alert.informativeText = "Set a custom title (leave empty to clear)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = item.title ?? ""
        field.placeholderString = item.preview
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            store.rename(item, to: field.stringValue)
        }
    }

    private func move(_ delta: Int) {
        // Visual order (pinned first, then date buckets) — same order the rows and
        // the ⌃-digit ladder use, so ↑/↓ step through rows exactly as shown rather
        // than recency order (which diverges once any item is pinned).
        let ids = orderedItems.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(where: { $0 == model.selectedId }) ?? 0
        let next = min(max(current + delta, 0), ids.count - 1)
        model.selectedId = ids[next]
    }
}

// MARK: - Position key cap

/// A small neon keycap shown on the first ten rows: "⌃" + the row's digit
/// (⌃1…⌃9, ⌃0). Brightens when its row is selected.
/// Renders the fixed ⌃1…⌃0 badge ladder. Slot positions are constant; on scroll
/// the labeled row under each slot changes but the badge never moves. The
/// highlight marks whichever fixed slot currently sits over the selected row —
/// since scrolling no longer re-centers the selection, the active badge simply
/// stays put (and tracks the selected row across slots) without any animation.
/// SF Symbol for a clipboard kind. Free function so both `ClipboardView` and the
/// extracted `ClipRowView` share one definition.
func clipboardKindIcon(_ kind: ClipboardKind) -> String {
    switch kind {
    case .text: return "doc.plaintext"
    case .image: return "photo"
    case .file: return "doc"
    case .link: return "link"
    case .email: return "envelope"
    case .color: return "paintpalette"
    }
}

// MARK: - List row

/// One clipboard row. A standalone `View` struct (not a method on `ClipboardView`)
/// on purpose: `isSelected` is a stored property, so SwiftUI tracks it as a per-row
/// dependency and re-renders exactly the rows whose selection changed. When the row
/// was an inline method-returned view, the `LazyVStack` reused the realized row
/// (keyed by `.id(item.id)`) without re-invoking the builder on a selection change,
/// so a previously-selected row kept its highlight card while selection moved away.
private struct ClipRowView: View {
    @ObservedObject var store: ClipboardStore
    let item: ClipboardItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: sz(8)) {
            // Leading thumbnail / icon / swatch — 28×28
            leading
                .frame(width: sz(28), height: sz(28))

            Text(item.displayTitle)
                .lineLimit(1)
                .font(Neon.font(13))
                .foregroundColor(isSelected ? Neon.textPrimary : Neon.textSecondary)

            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(Neon.font(9))
                    .foregroundColor(Neon.blue)
            }
            // ⌃-digit badge is drawn by the fixed `slotOverlay`, not per-row, so it
            // stays anchored to a screen position while rows scroll underneath.
        }
        .padding(.horizontal, sz(8))
        // Selection card is inset inside the cell so it floats with a gap above
        // and below instead of filling the full pitch. Without this the card butts
        // flush against the pinned header (and the next row), making the first item
        // look tucked under TODAY.
        .frame(height: ClipboardView.rowPitch - 8)
        .background(
            RoundedRectangle(cornerRadius: sz(6))
                .fill(isSelected ? Neon.blue.opacity(0.16) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: sz(6))
                        .strokeBorder(Neon.blue.opacity(isSelected ? 0.45 : 0), lineWidth: 1))
        )
        // Outer frame keeps the uniform pitch so every row stays on the fixed
        // ⌃-digit grid; the inset card is centred within it.
        .frame(height: ClipboardView.rowPitch)
        // Leave a right gutter so the ⌃-digit badge (drawn by `slotOverlay`) sits
        // outside the selection card, not on top of its highlight.
        .padding(.leading, sz(4))
        .padding(.trailing, sz(52))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var leading: some View {
        switch item.kind {
        case .color:
            RoundedRectangle(cornerRadius: sz(5))
                .fill(ClipboardView.swatch(item.preview).map(Color.init) ?? Color.gray.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: sz(5))
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
        case .image:
            ImageThumbnail(data: store.imageData(for: item))
        case .file:
            if let path = item.sourcePath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: clipboardKindIcon(item.kind))
                    .font(Neon.font(14))
                    .foregroundColor(Neon.textSecondary)
            }
        default:
            Image(systemName: clipboardKindIcon(item.kind))
                .font(Neon.font(14))
                .foregroundColor(.secondary)
        }
    }
}

private struct SlotLadderOverlay: View {
    let slots: [(id: UUID?, centerY: CGFloat)]
    let width: CGFloat
    let selectedId: UUID?

    var body: some View {
        ZStack {
            // Keyed by slot index (stable) — positions are fixed, only the labeled
            // row changes — so badges never re-position when the row id under a
            // slot changes during scroll.
            ForEach(Array(slots.enumerated()), id: \.offset) { idx, slot in
                PositionKeyCap(digit: idx == 9 ? "0" : "\(idx + 1)",
                               active: slot.id != nil && slot.id == selectedId)
                    // Left of the always-visible scrollbar, with a small gap.
                    .position(x: width - sz(34), y: slot.centerY)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct PositionKeyCap: View {
    let digit: String
    let active: Bool

    var body: some View {
        HStack(spacing: sz(1)) {
            Text(Preferences.quickSelectModifier.glyph)  // ⌘ / ⌃ per Preferences
            Text(digit)
        }
        .font(Neon.font(10, weight: .bold, design: .rounded))
        // Solid, higher-contrast chip: filled blue when its row is selected (dark
        // glyph), otherwise a dark slate fill with a bright cyan glyph + border, so
        // the badge reads clearly against any thumbnail underneath.
        .foregroundColor(active ? Neon.bgTop : Neon.blueBright)
        .padding(.horizontal, sz(5))
        .padding(.vertical, sz(2))
        .background(
            RoundedRectangle(cornerRadius: sz(4))
                .fill(active ? Neon.blueBright : Neon.bgBottom)
                .overlay(
                    RoundedRectangle(cornerRadius: sz(4))
                        .strokeBorder(Neon.blue.opacity(active ? 0.9 : 0.6), lineWidth: 1))
        )
    }
}

// MARK: - Image thumbnail (async, cached)

private struct ImageThumbnail: View {
    /// Decrypted PNG bytes (blobs are encrypted at rest, so we decode in-memory
    /// data rather than reading the file URL directly).
    let data: Data?

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: sz(28), height: sz(28))
                    .clipShape(RoundedRectangle(cornerRadius: sz(5)))
            } else {
                RoundedRectangle(cornerRadius: sz(5))
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        Image(systemName: "photo")
                            .font(Neon.font(11))
                            .foregroundColor(.secondary.opacity(0.5))
                    )
                    .frame(width: sz(28), height: sz(28))
            }
        }
        // Hairline border so dark / low-contrast thumbnails don't blend into the
        // panel background.
        .overlay(
            RoundedRectangle(cornerRadius: sz(5))
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
        .task(id: data) {
            guard let data else { return }
            // Decode on a background thread via CGImage (Sendable) then wrap on main
            let cgThumb: CGImage? = await Task.detached(priority: .utility) {
                guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                let side = 56 // 28pt @2x
                let scale = min(CGFloat(side) / CGFloat(cg.width),
                                CGFloat(side) / CGFloat(cg.height))
                let w = max(1, Int(CGFloat(cg.width) * scale))
                let h = max(1, Int(CGFloat(cg.height) * scale))
                guard let ctx = CGContext(data: nil, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return ctx.makeImage()
            }.value
            if let cgThumb {
                let rep = NSBitmapImageRep(cgImage: cgThumb)
                let img = NSImage(size: rep.size)
                img.addRepresentation(rep)
                thumbnail = img
            }
        }
    }
}

/// Bridges arrow keys, Enter, ⌘⌫, ⌘., ⌘E, ⌘P, and Esc to closures.
///
/// Uses a window-scoped local `NSEvent` monitor instead of `NSView.keyDown`:
/// the search `TextField` is always first responder, so a background view never
/// receives key events. The monitor sees `keyDown` before the field editor and
/// consumes navigation/commit keys (returns nil) while letting typing fall
/// through. Scoped to this panel's window so it never touches other windows.
/// A read-only, user-selectable text view for the preview pane. SwiftUI's
/// `.textSelection(.enabled)` cannot copy here: the panel's search field always
/// holds first responder, so ⌘C dispatches `copy:` to the (empty) field editor
/// instead of the preview. An `NSTextView` becomes first responder when the user
/// clicks to select and handles `copy:` itself, so partial selections copy.
///
/// It lives inside a SwiftUI `ScrollView`, so it must NOT add its own scroller;
/// `SelfSizingTextView` reports its laid-out height as its intrinsic content size
/// and lets the surrounding `ScrollView` handle overflow.
private struct SelectableText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> SelfSizingTextView {
        let tv = SelfSizingTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 13 * ThemeRuntime.scale, weight: .regular)
        tv.textColor = .labelColor
        tv.textContainerInset = .zero
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        return tv
    }

    func updateNSView(_ tv: SelfSizingTextView, context: Context) {
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.invalidateIntrinsicContentSize()
        }
    }
}

/// `NSTextView` that reports its laid-out height as its intrinsic size so it can
/// sit inside a SwiftUI `ScrollView` without its own scroller, wrapping text to
/// the available width.
final class SelfSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        let height = lm.usedRect(for: tc).height + textContainerInset.height * 2
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        // Width is driven by SwiftUI; recompute height whenever it changes.
        invalidateIntrinsicContentSize()
    }
}

private struct ClipboardKeyHandling: NSViewRepresentable {
    let onCancel: () -> Void
    let onEnter: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    let onPin: () -> Void
    let onRename: () -> Void
    let onFilter: () -> Void
    /// ⌃1…⌃0 → paste the row at this 0-based visual position.
    let onNumber: (Int) -> Void
    /// ⌃C → clear the filter field.
    let onClear: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.handlers = handlers
        context.coordinator.start()
        // Resolve the host window once the view is in the hierarchy.
        DispatchQueue.main.async { [weak v] in context.coordinator.window = v?.window }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handlers = handlers
        if context.coordinator.window == nil { context.coordinator.window = nsView.window }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private var handlers: Coordinator.Handlers {
        .init(cancel: onCancel, enter: onEnter, copy: onCopy, delete: onDelete,
              move: onMove, pin: onPin, rename: onRename, filter: onFilter,
              number: onNumber, clear: onClear)
    }

    final class Coordinator {
        struct Handlers {
            let cancel: () -> Void
            let enter: () -> Void
            let copy: () -> Void
            let delete: () -> Void
            let move: (Int) -> Void
            let pin: () -> Void
            let rename: () -> Void
            let filter: () -> Void
            let number: (Int) -> Void
            let clear: () -> Void
        }
        var handlers: Handlers?
        weak var window: NSWindow?
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ e: NSEvent) -> NSEvent? {
            guard let h = handlers else { return e }
            // Only act on events destined for our panel window.
            guard let w = window, e.window === w else { return e }
            let cmd = e.modifierFlags.contains(.command)
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⌘A → select all in the filter field (the borderless panel doesn't
            // route the standard selectAll: key equivalent on its own).
            if mods == .command, e.keyCode == 0 {  // A
                if let editor = w.firstResponder as? NSText { editor.selectAll(nil); return nil }
                return e
            }
            // ⌃C → clear the filter field. (⌘C below copies the selected entry.)
            if mods == .control, e.keyCode == 8 {  // C
                h.clear(); return nil
            }
            // ⌘1…⌘0 (or ⌃1…⌃0, per Preferences) paste by visual position. Match the
            // chosen modifier exactly among the real modifiers (so ⌘⌥1 / ⌃⇧1 fall
            // through) but ignore Caps Lock / fn; plain digits are NOT intercepted
            // so they keep filtering the search field.
            let quickFlag: NSEvent.ModifierFlags =
                Preferences.quickSelectModifier == .command ? .command : .control
            if QuickSelect.modifierMatches(e.modifierFlags, expected: quickFlag),
               let pos = QuickSelect.slot(forKeyCode: e.keyCode) {
                h.number(pos); return nil
            }
            switch e.keyCode {
            case 53: h.cancel(); return nil           // Esc
            case 125: h.move(1); return nil           // ↓
            case 126: h.move(-1); return nil          // ↑
            case 36, 76: h.enter(); return nil        // Return / keypad Enter
            case 8 where cmd:                         // ⌘C — copy selected entry
                // If the user has an active text selection (e.g. clicked into the
                // preview text view), let the native `copy:` copy that selection.
                // Otherwise copy the whole selected history entry to the clipboard.
                if let tv = w.firstResponder as? NSTextView, tv.selectedRange().length > 0 {
                    return e
                }
                h.copy(); return nil
            case 51 where cmd: h.delete(); return nil // ⌘⌫
            case 47 where cmd: h.pin(); return nil    // ⌘.
            case 14 where cmd: h.rename(); return nil // ⌘E
            case 35 where cmd: h.filter(); return nil // ⌘P
            default: return e
            }
        }

        deinit { stop() }
    }
}
