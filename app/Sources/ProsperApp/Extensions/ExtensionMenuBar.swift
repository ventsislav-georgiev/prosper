import AppKit
import Foundation

/// Host-owned UI primitives an extension reaches through `host.menubar`,
/// `host.dialog`, and `host.alert` — the surface the Hammerspoon openlid spoon
/// needs to render its status item + menu and prompt the user, WITHOUT a
/// resident Lua VM. The host owns every NSStatusItem/NSAlert; menu clicks
/// dispatch back into the extension by re-invoking a NAMED Lua handler (same
/// stateless event model as timers / system watchers).
///
/// See .omc/plans/hammerspoon-parity-host-api.md §M (menubar) and §N (dialog/alert).
@MainActor
final class ExtensionMenuBar: NSObject, NSMenuDelegate {

    static let shared = ExtensionMenuBar()

    /// Re-invoke an extension's named Lua handler with a JSON payload. Wired by
    /// the app to `ExtensionRegistry.deliverEvent` through `route`. nil before wiring (tests).
    var invoke: ((_ extensionID: String, _ handler: String, _ payloadJSON: String) -> Void)?

    /// Wire `invoke` to `deliver` as a MainActor job. A stay row's handler runs while
    /// its menu tracks (.eventTracking), so the hop must not wait for the default mode.
    func route(_ deliver: @escaping @MainActor @Sendable (_ extensionID: String, _ handler: String, _ payloadJSON: String) async -> Void) {
        invoke = { extID, handler, payload in
            Task { @MainActor in await deliver(extID, handler, payload) }
        }
    }

    /// The extension status menu being tracked now, if any (one menu tracks at a time).
    private weak var openMenu: NSMenu?
    func menuWillOpen(_ menu: NSMenu) { openMenu = menu }
    func menuDidClose(_ menu: NSMenu) { if openMenu === menu { openMenu = nil } }

    /// Ask the open extension menu to close. Tracking unwinds only after the caller's
    /// main-thread job returns, so whatever must run outside the menu (a modal) has to
    /// hop to the default run-loop mode. Returns false when no menu was open.
    func cancelOpenMenu() -> Bool {
        guard let menu = openMenu else { return false }
        menu.cancelTracking()
        return true
    }

    /// Live status items keyed by "extID\u{1}id". Readable for tests.
    private(set) var items: [String: NSStatusItem] = [:]
    /// QA OQ-6: tests swap in a private `NSStatusBar()` so nothing lands on the real menu bar.
    var statusBar: NSStatusBar = .system
    /// The app-wide toast panel and its pending auto-hide. Readable for tests.
    private(set) var hud: NSPanel?
    private(set) var hudHide: DispatchWorkItem?
    /// Token of the toast on screen now; `alert` bumps it, `dismissAlert(token:)` checks it.
    private var hudToken = 0
    /// QA #228: tests park the toast in a far-offscreen rect; nil centers it on `NSScreen.main`.
    var hudScreenFrame: NSRect?

    private static func key(_ extID: String, _ id: String) -> String { "\(extID)\u{1}\(id)" }

    /// Stable status-item autosave name per (extension, item), each part cleaned to [A-Za-z0-9._-]
    /// and joined with ":" (outside that set, so "com.x"+"ext.main" and "com.x.ext"+"main" differ).
    nonisolated static func autosaveName(extensionID: String, id: String) -> String {
        func clean(_ s: String) -> String {
            String(s.unicodeScalars.map { c in
                (c.isASCII && (CharacterSet.alphanumerics.contains(c) || "._-".unicodeScalars.contains(c)))
                    ? Character(c) : "_"
            })
        }
        return "ProsperExt:\(clean(extensionID)):\(clean(id))"
    }

    // MARK: - Menubar (§M)

    /// Upsert a status item. `json` = { title, icon (SF symbol name), menu:[ {title,
    /// handler, payload, enabled, checked, stay} | {separator:true} ] }. A row with no
    /// handler or enabled:false is disabled; stay:true runs the handler on a click
    /// without closing the menu (Return still closes it). Re-rendered on every
    /// call so the extension just re-sets it whenever its state changes.
    func set(extensionID: String, id: String, json: String) {
        // Debug guard for #199: status items and menus are AppKit state; every
        // caller must already be on main (LiveExtensionHostServices hops there).
        assert(Thread.isMainThread, "ExtensionMenuBar mutated off the main thread")
        guard let obj = Self.object(json) else { return }
        let k = Self.key(extensionID, id)
        let isNew = items[k] == nil
        let item = items[k] ?? statusBar.statusItem(withLength: NSStatusItem.variableLength)
        items[k] = item
        // .content: extension icons are user-facing data icons — keep them orderable/
        // previewable, named by the extension's title (else the extension id).
        if isNew {
            // #333: a named slot keeps the icon's position across launches; unnamed
            // items persist under "Item-N", which drifts with creation order.
            item.autosaveName = Self.autosaveName(extensionID: extensionID, id: id)
            let name = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? extensionID
            ProsperStatusItems.register(item, role: .content, name: name)
        }

        if let button = item.button {
            button.title = (obj["title"] as? String) ?? ""
            if let icon = obj["icon"] as? String, !icon.isEmpty {
                button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            } else {
                button.image = nil
            }
        }

        let entries = obj["menu"] as? [[String: Any]] ?? []
        if entries.isEmpty {
            item.menu = nil
        } else {
            // #482: refill the existing menu in place, so a re-render from a `stay`
            // row's handler reaches the menu the user still has open.
            let menu = item.menu ?? NSMenu()
            // Autoenable turned on every row (all share one target/action), so
            // `enabled = false` was ignored and status rows looked clickable.
            menu.autoenablesItems = false
            menu.delegate = self
            menu.removeAllItems()
            let stateColumn = entries.contains { ($0["checked"] as? Bool) == true }
            for e in entries {
                if (e["separator"] as? Bool) == true {
                    menu.addItem(.separator())
                    continue
                }
                let handler = (e["handler"] as? String) ?? ""
                let mi = NSMenuItem(title: (e["title"] as? String) ?? "",
                                    action: #selector(menuClicked(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = MenuAction(
                    extID: extensionID, handler: handler, payload: Self.encode(e["payload"]))
                // A row with nothing to run is inert, not a dead clickable row.
                mi.isEnabled = !handler.isEmpty && Self.bool(e["enabled"]) != false
                if (e["checked"] as? Bool) == true { mi.state = .on }
                if Self.bool(e["stay"]) == true { mi.view = StayItemView(title: mi.title, stateColumn: stateColumn) }
                menu.addItem(mi)
            }
            item.menu = menu
        }
    }

    func remove(extensionID: String, id: String) {
        assert(Thread.isMainThread, "ExtensionMenuBar mutated off the main thread")
        let k = Self.key(extensionID, id)
        if let item = items.removeValue(forKey: k) { statusBar.removeStatusItem(item) }
    }

    /// Tear down every status item an extension owns (disable / reset / quit).
    func removeAll(extensionID: String) {
        assert(Thread.isMainThread, "ExtensionMenuBar mutated off the main thread")
        let prefix = "\(extensionID)\u{1}"
        for (k, item) in items where k.hasPrefix(prefix) {
            statusBar.removeStatusItem(item)
            items[k] = nil
        }
    }

    private final class MenuAction: NSObject {
        let extID: String, handler: String, payload: String
        init(extID: String, handler: String, payload: String) {
            self.extID = extID; self.handler = handler; self.payload = payload
        }
    }

    /// A JSON boolean only: `as? Bool` also takes the numbers 0 and 1, so a Lua
    /// `enabled = 0` (truthy in Lua) would disable a row and `stay = 1` would stick.
    private static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    @objc private func menuClicked(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? MenuAction, !a.handler.isEmpty else { return }
        invoke?(a.extID, a.handler, a.payload)
    }

    /// #482: a `stay` row. A plain NSMenuItem always ends menu tracking on click; a
    /// click on an item's view does not, so the handler runs and the menu stays
    /// open. Drawn like a native row (menu font, 24 pt high, same paddings as
    /// measured from `NSMenu.size`, accent highlight while hovered or arrowed to).
    /// The item keeps its target/action, so Return still runs it through AppKit.
    private final class StayItemView: NSView {
        static let height: CGFloat = 24, leading: CGFloat = 14, trailing: CGFloat = 19, check: CGFloat = 14
        private let stateColumn: Bool

        init(title: String, stateColumn: Bool) {
            self.stateColumn = stateColumn
            let w = (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
            super.init(frame: NSRect(x: 0, y: 0, width: ceil(w) + Self.leading + Self.trailing
                                     + (stateColumn ? Self.check : 0), height: Self.height))
            autoresizingMask = .width
        }
        required init?(coder: NSCoder) { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let mi = enclosingMenuItem else { return }
            let lit = mi.isHighlighted && mi.isEnabled
            if lit {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: !mi.isEnabled ? NSColor.disabledControlTextColor
                    : lit ? .selectedMenuItemTextColor : .labelColor]
            let title = mi.title as NSString
            let y = (bounds.height - title.size(withAttributes: attrs).height) / 2
            if mi.state == .on { ("\u{2713}" as NSString).draw(at: NSPoint(x: Self.leading - 2, y: y), withAttributes: attrs) }
            title.draw(at: NSPoint(x: Self.leading + (stateColumn ? Self.check : 0), y: y), withAttributes: attrs)
        }

        override func mouseUp(with event: NSEvent) { press() }

        /// Same path as a click on a plain row, minus the end of tracking. A view left
        /// over from before a re-render keeps its detached item (menu nil): inert.
        @discardableResult
        private func press() -> Bool {
            guard let mi = enclosingMenuItem, mi.menu != nil, mi.isEnabled else { return false }
            (mi.target as? ExtensionMenuBar)?.menuClicked(mi)
            return true
        }

        // VoiceOver: a pressable menu item whose press behaves like the click.
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .menuItem }
        override func accessibilityTitle() -> String? { enclosingMenuItem?.title }
        override func isAccessibilityEnabled() -> Bool { enclosingMenuItem?.isEnabled ?? false }
        override func accessibilityPerformPress() -> Bool { press() }
    }

    // MARK: - Dialogs (§N) — modal, main-thread

    /// Text prompt. Returns the entered string, or nil if cancelled.
    func prompt(json: String) -> String? {
        let obj = Self.object(json) ?? [:]
        let alert = NSAlert()
        alert.messageText = (obj["title"] as? String) ?? ""
        if let m = obj["message"] as? String { alert.informativeText = m }
        alert.addButton(withTitle: (obj["ok"] as? String) ?? "OK")
        alert.addButton(withTitle: (obj["cancel"] as? String) ?? "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = (obj["default"] as? String) ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// Yes/No confirmation. Returns true when the primary button is chosen.
    func confirm(json: String) -> Bool {
        let obj = Self.object(json) ?? [:]
        let alert = NSAlert()
        alert.messageText = (obj["title"] as? String) ?? ""
        if let m = obj["message"] as? String { alert.informativeText = m }
        alert.addButton(withTitle: (obj["ok"] as? String) ?? "OK")
        alert.addButton(withTitle: (obj["cancel"] as? String) ?? "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Alert HUD (§N) — transient centered on-screen toast

    /// Show a transient borderless HUD with `text`, auto-dismissed after `seconds`
    /// (0 → default 1.5s). Replaces any visible HUD. The Hammerspoon `hs.alert` feel.
    /// Returns a token that lets the caller take down this toast, and only this one.
    @discardableResult
    func alert(text: String, seconds: Double) -> Int {
        hudHide?.cancel()
        let panel = hud ?? Self.makeHUD()
        hud = panel
        // The bg NSVisualEffectView is inserted below the label, so `subviews.first`
        // is the bg, not the label — find the text field by type.
        let label = panel.contentView?.subviews.first(where: { $0 is NSTextField }) as? NSTextField
        label?.stringValue = text
        label?.sizeToFit()
        if let label {
            let w = max(120, label.frame.width + 48), h = label.frame.height + 32
            if let f = hudScreenFrame ?? NSScreen.main?.frame {
                panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
            }
            label.frame = NSRect(x: 24, y: 16, width: w - 48, height: h - 32)
        }
        panel.orderFrontRegardless()
        let hide = DispatchWorkItem { [weak self] in self?.hud?.orderOut(nil) }
        hudHide = hide
        let delay = seconds > 0 ? seconds : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: hide)
        hudToken += 1
        return hudToken
    }

    /// Hides the HUD now and cancels its pending auto-hide, but only while the toast
    /// that returned `token` is still the one showing: a later toast from another
    /// feature stays up.
    func dismissAlert(token: Int) {
        guard token == hudToken else { return }
        hudHide?.cancel()
        hudHide = nil
        hud?.orderOut(nil)
    }

    private static func makeHUD() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let bg = NSVisualEffectView(frame: panel.contentView!.bounds)
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.maskImage = NSImage(size: bg.bounds.size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill(); return true
        }
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .white
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(bg, positioned: .below, relativeTo: label)
        return panel
    }

    // MARK: - JSON helpers

    private static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static func encode(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
