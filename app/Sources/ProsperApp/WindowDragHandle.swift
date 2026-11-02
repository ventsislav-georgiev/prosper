import AppKit
import SwiftUI

/// #713: a grab area for the borderless SwiftUI panels (runner, clipboard history).
///
/// `isMovableByWindowBackground` alone moves nothing there. The window server starts a
/// background drag only outside the region AppKit marks as blocking, and NSHostingView
/// marks every hit-testable SwiftUI shape there, in any z-order. The neon surface's
/// gradient and hairline span the whole panel, so the whole panel blocks. This view
/// takes the press itself (the hit test does honour z-order) and starts the drag.
///
/// Place it as a bar's `.background`, above any tint. Give non-interactive labels and
/// icons on the bar `.allowsHitTesting(false)` so a press on them falls through to it.
/// (SwiftUI's WindowDragGesture needs macOS 15; the app supports 14.)
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragHandleView { WindowDragHandleView() }
    func updateNSView(_ nsView: WindowDragHandleView, context: Context) {}
}

final class WindowDragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    /// A press on a panel that is not key still drags, like a title bar.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
