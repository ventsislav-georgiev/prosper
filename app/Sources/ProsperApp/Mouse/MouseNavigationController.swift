import AppKit
import Carbon
import CoreGraphics

/// Side button → keystroke mapping. Pure, so the table is testable without a tap.
enum MouseNavigation {
    /// `.mouseEventButtonNumber` numbering: 0 left, 1 right, 2 middle, then the
    /// side buttons — every 5-button mouse reports Back as 3 and Forward as 4.
    /// Anything higher (thumb wheels, sniper buttons) is left to the app.
    static func chord(forButton button: Int64) -> KeyChord? {
        switch button {
        case 3: return KeyChord(keyCode: Int64(kVK_ANSI_LeftBracket), cmd: true)    // ⌘[  Back
        case 4: return KeyChord(keyCode: Int64(kVK_ANSI_RightBracket), cmd: true)   // ⌘]  Forward
        default: return nil
        }
    }
}

@MainActor
final class MouseNavigationController {
    static let shared = MouseNavigationController()

    /// Defaults false, like the scroll controller: rewriting mouse input
    /// system-wide fails closed when the gate state is unknown.
    var mouseExtLive = false

    private var tap: EventTap?
    private var enabled = false

    var isTapped: Bool { tap != nil }

    private init() {}

    func reconcile() {
        enabled = Preferences.mouseSideButtonNavigation
        if mouseExtLive, enabled, PermissionsManager.isAccessibilityTrusted() {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard tap == nil else { tap?.enable(); return }
        // Head-insert, unlike the scroll tap's tail-append: a mapped button has to
        // be swallowed before anything downstream — including an app that already
        // handles button 3 itself — gets to see it.
        let t = EventTap(label: "mouse-nav", options: .defaultTap, location: .hid,
                         place: .headInsertEventTap,
                         types: [.otherMouseDown, .otherMouseUp, .otherMouseDragged]) { proxy, type, event in
            MouseNavigationController.shared.handle(proxy, type, event)
        }
        t.enable()
        // `EventTap.machPort` is private, so a failed tapCreate shows up as a tap
        // that won't enable; leave `tap` nil and let the next reconcile retry.
        guard t.isEnabled else { return }
        tap = t
    }

    private func stop() {
        tap?.disable()
        tap = nil
    }

    /// Hot path — cheapest gate first, no allocation, no AX.
    ///
    /// There is deliberately no own-synthetic guard: what this posts is a
    /// KEYBOARD event, which a mouse-only mask can never deliver back here.
    /// `KeyInjector.stroke` still stamps the shared 'PROS' marker for the
    /// keystroke taps that DO see it.
    private func handle(_ proxy: EventTap.Proxy, _ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            proxy.enable()
            return event
        }
        guard enabled else { return event }
        guard let chord = MouseNavigation.chord(forButton: event.getIntegerValueField(.mouseEventButtonNumber))
        else { return event }
        // The keystroke lands on the frontmost app, so the frontmost app decides —
        // not whatever window happens to be under the pointer.
        guard !MouseExceptions.shared.excludesActionTarget(.navigation) else { return event }

        // Down synthesizes; up and dragged are swallowed too, so no app ever sees
        // the back half of a click it was never given the front half of.
        if type == .otherMouseDown { KeyInjector.stroke(chord) }
        return nil
    }
}
