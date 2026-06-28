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
final class ExtensionMenuBar {

    static let shared = ExtensionMenuBar()

    /// Re-invoke an extension's named Lua handler with a JSON payload. Wired by
    /// the app to `ExtensionRegistry.deliverEvent`. nil before wiring (tests).
    var invoke: ((_ extensionID: String, _ handler: String, _ payloadJSON: String) -> Void)?

    /// Live status items keyed by "extID\u{1}id".
    private var items: [String: NSStatusItem] = [:]
    private var hud: NSPanel?
    private var hudHide: DispatchWorkItem?

    private static func key(_ extID: String, _ id: String) -> String { "\(extID)\u{1}\(id)" }

    // MARK: - Menubar (§M)

    /// Upsert a status item. `json` = { title, icon (SF symbol name), menu:[ {title,
    /// handler, payload} | {separator:true} ] }. Re-rendered on every call so the
    /// extension just re-sets it whenever its state changes.
    func set(extensionID: String, id: String, json: String) {
        guard let obj = Self.object(json) else { return }
        let k = Self.key(extensionID, id)
        let isNew = items[k] == nil
        let item = items[k] ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        items[k] = item
        if isNew { ProsperStatusItems.register(item) }   // self-filter source for the menu-bar manager

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
            let menu = NSMenu()
            for e in entries {
                if (e["separator"] as? Bool) == true {
                    menu.addItem(.separator())
                    continue
                }
                let mi = NSMenuItem(title: (e["title"] as? String) ?? "",
                                    action: #selector(menuClicked(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = MenuAction(
                    extID: extensionID,
                    handler: (e["handler"] as? String) ?? "",
                    payload: Self.encode(e["payload"]))
                if (e["enabled"] as? Bool) == false { mi.isEnabled = false }
                if (e["checked"] as? Bool) == true { mi.state = .on }
                menu.addItem(mi)
            }
            item.menu = menu
        }
    }

    func remove(extensionID: String, id: String) {
        let k = Self.key(extensionID, id)
        if let item = items.removeValue(forKey: k) { NSStatusBar.system.removeStatusItem(item) }
    }

    /// Tear down every status item an extension owns (disable / reset / quit).
    func removeAll(extensionID: String) {
        let prefix = "\(extensionID)\u{1}"
        for (k, item) in items where k.hasPrefix(prefix) {
            NSStatusBar.system.removeStatusItem(item)
            items[k] = nil
        }
    }

    private final class MenuAction: NSObject {
        let extID: String, handler: String, payload: String
        init(extID: String, handler: String, payload: String) {
            self.extID = extID; self.handler = handler; self.payload = payload
        }
    }

    @objc private func menuClicked(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? MenuAction, !a.handler.isEmpty else { return }
        invoke?(a.extID, a.handler, a.payload)
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
    func alert(text: String, seconds: Double) {
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
            if let screen = NSScreen.main {
                let f = screen.frame
                panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h), display: true)
            }
            label.frame = NSRect(x: 24, y: 16, width: w - 48, height: h - 32)
        }
        panel.orderFrontRegardless()
        let hide = DispatchWorkItem { [weak self] in self?.hud?.orderOut(nil) }
        hudHide = hide
        let delay = seconds > 0 ? seconds : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: hide)
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

    private static func encode(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
