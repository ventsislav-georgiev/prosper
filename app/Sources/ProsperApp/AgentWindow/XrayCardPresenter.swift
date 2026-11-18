import AppKit
import SwiftUI

// #1319 (#832 X1 step B, spec v2.1 8.3): the popover seam the Command-L list uses (and the X2 card later). The window
// asks it to show one surface at a time; rows put a fake here that records and hosts offscreen.

@MainActor
protocol XrayCardPresenter: AnyObject {
    /// Shows `content` at `size` under `anchor`; `closed` runs once when it goes, whoever closed it.
    func present(_ content: AnyView, size: CGSize, anchor: NSView, closed: @escaping @MainActor () -> Void)
    func close()
    var isShown: Bool { get }
}

/// The product's presenter: an NSPopover, transient (a click outside closes it), below the anchor.
@MainActor
final class XrayPopoverPresenter: NSObject, XrayCardPresenter, NSPopoverDelegate {
    // Internal, not private: a row sets a stale-popover state and calls popoverDidClose without showing one (#1432).
    var popover: NSPopover?
    var closed: (@MainActor () -> Void)?

    var isShown: Bool { popover?.isShown == true }

    func present(_ content: AnyView, size: CGSize, anchor: NSView, closed: @escaping @MainActor () -> Void) {
        // Retire the old card here: its did-close may arrive after the new popover is installed (#1432).
        let (old, oldClosed) = (popover, self.closed)
        (popover, self.closed) = (nil, nil)
        old?.delegate = nil
        old?.performClose(nil)
        oldClosed?()
        let p = NSPopover()
        p.behavior = .transient
        p.animates = false
        p.contentSize = size
        p.contentViewController = NSHostingController(rootView: Themed { content })
        p.delegate = self
        popover = p
        self.closed = closed
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() { popover?.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        let f = closed
        (popover, closed) = (nil, nil)
        f?()
    }
}

/// The header's "..." in each pane, as an AppKit view the popover can hang from (a background of the button). The
/// pane id comes from the pane area's environment; a pane drawn without one (the gate off) registers as `nil`.
struct XrayCardAnchor: NSViewRepresentable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @Environment(\.agentPaneID) private var pane

    /// The anchors by pane; weak, so a closed pane's goes with its view.
    @MainActor static var views: [UUID?: WeakAnchor] = [:]
    final class WeakAnchor { weak var view: NSView?; init(_ v: NSView) { view = v } }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        Self.views[pane] = WeakAnchor(v)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { Self.views[pane] = WeakAnchor(v) }

    /// The anchor of `pane`'s header in `window` (the gate-off single pane registers as nil), if drawn there.
    @MainActor static func view(for pane: UUID, in window: NSWindow) -> NSView? {
        [pane, nil].lazy.compactMap { views[$0]?.view }.first { $0.window === window }
    }
}
