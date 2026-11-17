import SwiftUI

/// #1108 P3b (design D10): the Text viewer's two modes. `read` is first and is what a window always opens in; nothing
/// is saved. Used by nothing else yet (the window step adopts it).
enum TextViewerMode: Int, CaseIterable {
    case read, edit
    var title: String { self == .read ? "Read" : "Edit" }
}

/// A Read | Edit style segmented switch, drawn as the Agent Sessions pane-mode toggle's `.labels` style was (values copied,
/// never shared; that toggle is gone, #1471). The selection is an index (the smallest form); no state of its own. No fixed frame:
/// every label is fixedSize, so the natural width is the same at every UI scale and never depends on the selection.
struct CapsuleSwitch: View {
    let titles: [String]
    let selected: Int
    /// Called on the main actor (a Button action), only for a segment other than the selected one.
    let set: (Int) -> Void
    var help: String?
    /// Why the switch is off; the caller adds .disabled(off != nil). It replaces the help text.
    var off: String?

    /// The glyph is written in the source, as the old pane-mode toggle's help had it.
    static let textViewerHelp = "Switch between Read and Edit (⌘T)"

    static func choose(_ index: Int, selected: Int, set: (Int) -> Void) { if index != selected { set(index) } }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                Button { Self.choose(i, selected: selected, set: set) } label: {
                    Text(title)
                        .font(Neon.font(10.5, weight: .medium))
                        .foregroundStyle(i == selected ? Neon.textPrimary : Neon.textSecondary)
                        .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
                        .background(Capsule().fill(i == selected ? Neon.blue.opacity(0.2) : .clear))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help(off ?? help ?? title)
                .accessibilityLabel(title)
                .accessibilityAddTraits(i == selected ? .isSelected : [])
            }
        }
        .padding(sz(2))
        .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
        .fixedSize()
    }
}
