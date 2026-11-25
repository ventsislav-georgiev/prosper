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
    /// #1944: as present, opened from inside the shown card: that card stays (hidden, its `closed` not run) under this one.
    func push(_ content: AnyView, size: CGSize, anchor: NSView, closed: @escaping @MainActor () -> Void)
    /// #1944: Back or Escape: the shown card goes (its `closed` runs) and the one under it comes back; none under: close().
    func back()
}

extension XrayCardPresenter {
    // Presenters without a stack (the rows' fakes): a push replaces, Back closes.
    func push(_ content: AnyView, size: CGSize, anchor: NSView, closed: @escaping @MainActor () -> Void) {
        present(content, size: size, anchor: anchor, closed: closed)
    }
    func back() { close() }
}

/// #1944: a pushed card's way back to the card under it (nil on the first card): its header's Back and its Escape.
private struct XrayCardBackKey: EnvironmentKey { static var defaultValue: (() -> Void)? { nil } }

extension EnvironmentValues {
    var xrayCardBack: (() -> Void)? {
        get { self[XrayCardBackKey.self] }
        set { self[XrayCardBackKey.self] = newValue }
    }
}

/// #1944: the Back control at the start of a card's header; drawn only on a card opened from another card.
struct XrayCardBackButton: View {
    @Environment(\.xrayCardBack) var back

    var body: some View {
        if let back {
            Button(action: back) {
                Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly)
                    .font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textSecondary)
                    .frame(width: sz(20), height: sz(20)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityHint("Returns to the previous card")
        }
    }
}

/// #1760: the card's window: borderless and clear (the card draws its own rounded surface), the system's soft shadow,
/// no arrow. Key while shown, so Escape and the filter field reach the card; Escape the card does not take closes it.
final class XrayCardPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// #1960: a plain Esc is the card's (back, or close on the first card) whatever took focus in it: a click in the
    /// prompt card's selectable text makes SwiftUI's text view first responder, and that view ate Esc. A text field
    /// (the ref card's filter) keeps it: its Esc clears the filter first.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, takesEscape(event.keyCode, event.modifierFlags) { return cancelOperation(nil) }
        super.sendEvent(event)
    }

    func takesEscape(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 53 && flags.intersection([.command, .option, .control, .shift]).isEmpty
            && (firstResponder as? NSTextView)?.isFieldEditor != true
    }
}

/// #1760: the product's presenter: a Prosper rich card (the X-ray drawer's surface: Neon.card, the card stroke, 14 pt
/// corners) in its own panel, replacing the dropdown-like NSPopover. Placed by `frame` (below the anchor; beside the
/// drawer when the drawer is open); a click outside (the panel resigns key) or Escape closes it. #1944: a card opened from
/// inside the shown card is pushed over it; Back or Escape returns to the card under it, a click outside closes them all.
@MainActor
final class XrayCardPanelPresenter: XrayCardPresenter {
    // Internal, not private: rows read the panel and post its resign-key without ever showing one.
    var panel: XrayCardPanel?
    var closed: (@MainActor () -> Void)?
    private var resign: NSObjectProtocol?
    /// #1944: the cards under the shown one, oldest first: hidden, kept whole (tab, filter, scroll), `closed` not yet run.
    struct Under {
        let panel: XrayCardPanel
        let closed: @MainActor () -> Void
        weak var parent: NSWindow?
    }
    private(set) var under: [Under] = []
    enum Order: Equatable { case showKey, hide }
    /// The seam that shows (key: a click or keyboard open) or hides the card's panel over `parent`; rows put a recorder
    /// here, so no window is ever ordered front or made key by a test.
    var order: @MainActor (XrayCardPanel, NSWindow?, Order) -> Void = { p, parent, o in
        switch o {
        case .showKey:
            parent?.addChildWindow(p, ordered: .above)   // moves with its window
            p.makeKeyAndOrderFront(nil)
            p.invalidateShadow()
        case .hide:
            parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
    }

    var isShown: Bool { panel != nil }

    func present(_ content: AnyView, size: CGSize, anchor: NSView, closed: @escaping @MainActor () -> Void) {
        close()   // one card at a time: the old cards' closed run before the new one is installed (#1432); #1944: the stack goes
        show(content, size: size, anchor: anchor, closed: closed)
    }

    func push(_ content: AnyView, size: CGSize, anchor: NSView, closed: @escaping @MainActor () -> Void) {
        guard let p = panel, let c = self.closed else { return present(content, size: size, anchor: anchor, closed: closed) }
        let parent = p.parent
        unobserve()   // before the hide: its resign key is no click outside
        (panel, self.closed) = (nil, nil)
        under.append(Under(panel: p, closed: c, parent: parent))
        order(p, parent, .hide)
        show(content, size: size, anchor: anchor, closed: closed)
    }

    func back() {
        guard let u = under.popLast() else { return close() }
        hideShown()
        (panel, closed) = (u.panel, u.closed)
        observe(u.panel)
        order(u.panel, u.parent, .showKey)
    }

    private func show(_ content: AnyView, size: CGSize, anchor: NSView, closed: @escaping @MainActor () -> Void) {
        let win = anchor.window
        let screen = (win?.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let at = win.map { $0.convertToScreen(anchor.convert(anchor.bounds, to: nil)) } ?? .zero
        let drawer = XrayDrawerFrame.frame(in: win, near: at)
        let f = Self.frame(size: size, anchor: at, drawer: drawer, window: win?.frame, screen: screen)
        let p = XrayCardPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isExcludedFromWindowsMenu = true
        p.hidesOnDeactivate = true
        p.level = .floating
        let shape = RoundedRectangle(cornerRadius: sz(14), style: .continuous)
        let back: (() -> Void)? = under.isEmpty ? nil : { [weak self] in self?.back() }
        let host = NSHostingView(rootView: Themed {
            content.frame(width: f.width, height: f.height, alignment: .topLeading)
                .environment(\.xrayCardBack, back)
                .background(shape.fill(Neon.card))
                .overlay(shape.strokeBorder(Neon.cardStroke, lineWidth: 1))
                .clipShape(shape)
        })
        host.frame = CGRect(origin: .zero, size: f.size)
        p.contentView = host
        p.onCancel = { [weak self, weak p] in if let self, self.panel === p { self.back() } }   // #1944: Escape goes back
        (panel, self.closed) = (p, closed)
        observe(p)
        order(p, win, .showKey)
    }

    /// A click outside (the shown panel resigns key) closes the whole stack.
    private func observe(_ p: XrayCardPanel) {
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: nil) {
            [weak self, weak p] _ in MainActor.assumeIsolated { if let self, let p, self.panel === p { self.close() } }
        }
    }

    private func unobserve() {
        resign.map { NotificationCenter.default.removeObserver($0) }
        resign = nil
    }

    /// The shown card goes; its closed runs once.
    private func hideShown() {
        guard let p = panel else { return }
        let f = closed
        unobserve()
        (panel, self.closed) = (nil, nil)
        order(p, p.parent, .hide)
        f?()
    }

    /// The shown card, then each card under it (newest first), goes; each closed runs once.
    func close() {
        hideShown()
        while let u = under.popLast() { u.closed() }
    }

    static let gap: CGFloat = 6

    /// #1760: where a card of `size` goes (screen points, y up). `size` is first clamped to the screen less a margin.
    /// No drawer: centred below the anchor (the popover's place), beside it when below has no room, clamped to the
    /// screen. A drawer: beside the drawer on the side away from it in its window (the other side when the first has
    /// no room), top aligned to the anchor; neither side has room: the roomier side, clamped, which may overlap the
    /// drawer's near edge, never more than the overflow.
    static func frame(size: CGSize, anchor: CGRect, drawer: CGRect?, window: CGRect?, screen: CGRect) -> CGRect {
        let m = gap
        let w = min(size.width, max(1, screen.width - 2 * m)), h = min(size.height, max(1, screen.height - 2 * m))
        func clamp(_ r: CGRect) -> CGRect {
            CGRect(x: min(max(r.minX, screen.minX + m), screen.maxX - m - w),
                   y: min(max(r.minY, screen.minY + m), screen.maxY - m - h), width: w, height: h)
        }
        let top = anchor.maxY
        if let d = drawer {
            let left = CGRect(x: d.minX - m - w, y: top - h, width: w, height: h)
            let right = CGRect(x: d.maxX + m, y: top - h, width: w, height: h)
            let leftRoom = left.minX >= screen.minX + m, rightRoom = right.maxX <= screen.maxX - m
            let awayLeft = d.midX >= (window ?? screen).midX
            let pick = awayLeft ? (leftRoom || !rightRoom ? left : right) : (rightRoom || !leftRoom ? right : left)
            if leftRoom || rightRoom { return clamp(pick) }
            return clamp(d.minX - screen.minX >= screen.maxX - d.maxX ? left : right)
        }
        let below = CGRect(x: anchor.midX - w / 2, y: anchor.minY - m - h, width: w, height: h)
        if below.minY >= screen.minY + m { return clamp(below) }
        let beside = CGRect(x: anchor.maxX + m, y: top - h, width: w, height: h)
        return clamp(beside.maxX <= screen.maxX - m ? beside : beside.offsetBy(dx: -(w + 2 * m + anchor.width), dy: 0))
    }
}

/// #1760: the X-ray drawer's view, registered so a card opened while the drawer is open goes beside it, never over it.
struct XrayDrawerFrame: NSViewRepresentable {
    @MainActor static var views: [XrayCardAnchor.WeakAnchor] = []

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        Self.views = Self.views.filter { $0.view != nil } + [XrayCardAnchor.WeakAnchor(v)]
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}

    /// The screen frame of the shown drawer in `window` nearest `anchor` (the one holding its midX first); nil: none.
    @MainActor static func frame(in window: NSWindow?, near anchor: CGRect) -> CGRect? {
        guard let window else { return nil }
        let frames = views.compactMap(\.view).filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
            .map { window.convertToScreen($0.convert($0.bounds, to: nil)) }.filter { $0.width > 0 }
        return frames.first { $0.minX <= anchor.midX && anchor.midX <= $0.maxX }
            ?? frames.min { abs($0.midX - anchor.midX) < abs($1.midX - anchor.midX) }
    }
}

/// The header's "..." in each pane, as an AppKit view the popover can hang from (a background of the button). The
/// pane id comes from the pane area's environment; a pane drawn without one (the gate off) registers as `nil`.
struct XrayCardAnchor: NSViewRepresentable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @Environment(\.agentPaneID) private var pane

    /// The anchors by pane, oldest registered first; weak, so a closed pane's goes with its view. #1951: every live one
    /// is kept, not only the last registered, so an instance SwiftUI updated last and then took out of the window (or
    /// freed) never hides the pane's anchor that is still drawn.
    @MainActor static var views: [UUID?: [WeakAnchor]] = [:]
    final class WeakAnchor { weak var view: NSView?; init(_ v: NSView) { view = v } }

    /// `v` becomes `pane`'s newest anchor; freed ones and an earlier entry for `v` go, so the list holds live views only.
    @MainActor static func register(_ v: NSView, _ pane: UUID?) {
        views[pane] = (views[pane] ?? []).filter { $0.view != nil && $0.view !== v } + [WeakAnchor(v)]
    }

    /// `pane`'s anchors, then the shared (nil) ones, each newest first.
    @MainActor static func candidates(_ pane: UUID) -> [NSView] {
        [pane, nil].flatMap { (views[$0] ?? []).reversed().compactMap(\.view) }
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        Self.register(v, pane)
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { Self.register(v, pane) }

    /// The anchor of `pane`'s header in `window` (the gate-off single pane registers as nil), if drawn there.
    @MainActor static func view(for pane: UUID, in window: NSWindow) -> NSView? {
        candidates(pane).first { $0.window === window }
    }
}
