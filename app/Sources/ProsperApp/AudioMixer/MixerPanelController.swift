// Owns the volume menu-bar item and its popover. Modelled on StatsController:
// one `.transient` NSPopover, a global outside-click monitor armed only while
// it is open, and the hosting controller dropped on close so the SwiftUI tree
// (and the per-app icon bitmaps it holds) does not idle in memory.

import AppKit
import Combine
import SwiftUI

@MainActor
final class MixerPanelController {
    static let shared = MixerPanelController()

    private let mixer = AppVolumeMixer.shared
    private var item: NSStatusItem?
    private var glyphObservers: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?

    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = false
        p.delegate = popoverDelegate
        return p
    }()

    private lazy var popoverDelegate = MixerPopoverDelegate { [weak self] in
        guard let self else { return }
        self.updateOutsideClickMonitor()
        if !self.popover.isShown {
            // One turn later: AppKit is still unwinding the close when the
            // delegate fires, and clearing the controller inside that unwind
            // yanks the view out from under it.
            DispatchQueue.main.async {
                if !self.popover.isShown { self.popover.contentViewController = nil }
            }
        }
    }

    private init() {}

    /// Bring the feature to match the preference. Idempotent — called at
    /// launch and whenever `Preferences.mixerEnabled` flips.
    func reload() {
        // The service gates itself on the same preference, so sync first and
        // unconditionally: turning the mixer off has to tear the taps down
        // even though the status item is about to disappear.
        mixer.syncWithPreferences()
        AudioInputDeviceManager.shared.syncWithPreferences()
        guard Preferences.mixerEnabled, MixerCore.isSupported else { teardown(); return }
        syncItem()
    }

    // MARK: - Status item

    /// Opens the panel from the runner (`:volume`). Returns false when the mixer
    /// is off or unsupported — the popover anchors on the status item, and there
    /// is none — so the caller can route somewhere useful instead.
    @discardableResult
    func showPanel() -> Bool {
        guard let button = item?.button else { return false }
        if !popover.isShown { itemClicked(button) }
        return true
    }

    private func syncItem() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: Self.itemWidth)
        item.autosaveName = "ProsperVolumeMixer"
        // .content: stays in the menubar-management ordering/preview set.
        ProsperStatusItems.register(item, role: .content, name: "Volume")
        item.button?.target = self
        item.button?.action = #selector(itemClicked(_:))
        item.button?.toolTip = "Volume mixer"
        self.item = item
        updateGlyph()

        // The glyph mirrors the native volume icon, so it has to follow the
        // system output the same way — published state, not a poll.
        mixer.$systemOutputVolume
            .combineLatest(mixer.$systemOutputMuted)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateGlyph() }
            .store(in: &glyphObservers)

        // The default output can change without the level changing (AirPods
        // connect at whatever volume was already set), so the device drives
        // the glyph too.
        mixer.$outputDevices
            .map { $0.first(where: \.isDefault)?.name }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateGlyph() }
            .store(in: &glyphObservers)
    }

    /// speaker.wave.3 renders 24pt wide at every variable value, the slash
    /// glyph 16pt. Pinning the item to the widest keeps mute and every volume
    /// step the same width, so neighbouring menu-bar items never shift. Every
    /// AirPods glyph is narrower than speaker.wave.3, so they fit unchanged.
    private static let itemWidth: CGFloat = 24

    private func updateGlyph() {
        guard let button = item?.button else { return }
        let glyph = Self.glyph(volume: mixer.systemOutputVolume,
                               muted: mixer.systemOutputMuted,
                               outputDeviceName: mixer.outputDevices.first(where: \.isDefault)?.name)
        // A symbol the running system does not carry resolves to nil
        // (airpods.gen4 lands in macOS 15), so the speaker glyph takes over.
        let image = NSImage(systemSymbolName: glyph.name,
                            variableValue: glyph.value,
                            accessibilityDescription: "Volume")
            ?? NSImage(systemSymbolName: "speaker.wave.3.fill",
                       variableValue: mixer.systemOutputVolume ?? 0.66,
                       accessibilityDescription: "Volume")
        image?.isTemplate = true
        button.image = image
    }

    /// Variable rendering draws every wave arc and dims the ones above the
    /// level — what the native menu-bar icon does. An output with no readable
    /// volume (an aggregate device, a HDMI sink) sits at a neutral mid level
    /// rather than pretending to be at zero.
    ///
    /// AirPods replace the speaker outright, the way the native icon does: the
    /// level lives in the slider, not in the glyph (no AirPods symbol supports
    /// variable rendering anyway). Mute still wins over both, because the
    /// slashed speaker is the only unambiguous "you hear nothing".
    nonisolated static func glyph(volume: Double?,
                                  muted: Bool?,
                                  outputDeviceName: String? = nil) -> (name: String, value: Double) {
        if muted == true || (volume ?? 1) <= 0.001 { return ("speaker.slash.fill", 1) }
        if let symbol = airPodsSymbol(outputDeviceName: outputDeviceName) { return (symbol, 1) }
        return ("speaker.wave.3.fill", volume ?? 0.66)
    }

    /// Name matching, the same way `outputLooksLikeHeadphones` does it: no
    /// public CoreAudio property says "these are AirPods", so a pair renamed
    /// past recognition simply keeps the speaker glyph.
    nonisolated static func airPodsSymbol(outputDeviceName: String?) -> String? {
        guard let name = outputDeviceName?
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression),
            name.contains("airpods") else { return nil }
        if name.contains("airpodsmax") { return "airpodsmax" }
        if name.contains("airpodspro") { return "airpodspro" }
        if name.contains("airpods3") { return "airpods.gen3" }
        if name.contains("airpods4") { return "airpods.gen4" }
        return "airpods"
    }

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(sender); return }
        let host = NSHostingController(rootView: MixerPanelView())
        // Let the popover learn the view's real size BEFORE it positions
        // itself, or AppKit anchors a 0×0 popover and then grows it — landing
        // it offscreen above the bar or with a stray gap below.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    /// Arm the monitor while the popover is shown, drop it when closed (no
    /// idle event tap when nothing is open).
    private func updateOutsideClickMonitor() {
        if popover.isShown {
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        } else if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    private func teardown() {
        glyphObservers.removeAll()
        if popover.isShown { popover.performClose(nil) }
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
}

/// Bridges NSPopover open/close to the monitor + content teardown without the
/// controller having to conform to the delegate protocol itself.
private final class MixerPopoverDelegate: NSObject, NSPopoverDelegate {
    let reconcile: () -> Void
    init(_ reconcile: @escaping () -> Void) { self.reconcile = reconcile }
    func popoverDidShow(_ n: Notification) { reconcile() }
    func popoverDidClose(_ n: Notification) { reconcile() }
}
