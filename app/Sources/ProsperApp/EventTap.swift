import AppKit
import CoreGraphics

// MARK: - Minimal event tap (port of Ice's EventTap essentials)

/// A listen-or-default CGEvent tap with enable/disable + timeout. Self-owns its
/// mach port + runloop source and tears them down on `deinit`.
///
/// Backs the mouse module's long-lived scroll/navigation taps.
@MainActor
final class EventTap {
    enum Location {
        case session, hid
    }

    // CF handles: accessed from the (nonisolated) deinit for teardown, so marked
    // unsafe. Only ever touched on the main thread in practice.
    private nonisolated(unsafe) let runLoop = CFRunLoopGetCurrent()
    private let mode: CFRunLoopMode = .commonModes
    private let callback: @MainActor (_ proxy: Proxy, _ type: CGEventType, _ event: CGEvent) -> CGEvent?
    private nonisolated(unsafe) var machPort: CFMachPort?
    private nonisolated(unsafe) var source: CFRunLoopSource?
    private var isAdded = false   // guards against double CFRunLoopAddSource
    let label: String

    var isEnabled: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    @MainActor
    struct Proxy {
        fileprivate let tap: EventTap
        func enable() { tap.enable() }
    }

    init(label: String,
         options: CGEventTapOptions,
         location: Location,
         place: CGEventTapPlacement = .tailAppendEventTap,
         types: [CGEventType],
         callback: @MainActor @escaping (_ proxy: Proxy, _ type: CGEventType, _ event: CGEvent) -> CGEvent?) {
        self.label = label
        self.callback = callback
        let mask = types.reduce(into: CGEventMask(0)) { $0 |= 1 << $1.rawValue }
        guard let machPort = Self.createMachPort(location: location, options: options,
                                                 place: place, mask: mask,
                                                 userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, machPort, 0) else {
            NSLog("prosper: failed to create event tap \(label)")
            return
        }
        self.machPort = machPort
        self.source = source
    }

    deinit {
        guard let machPort else { return }
        CFRunLoopRemoveSource(runLoop, source, mode)
        CGEvent.tapEnable(tap: machPort, enable: false)
        CFMachPortInvalidate(machPort)
    }

    private static func createMachPort(location: Location, options: CGEventTapOptions,
                                       place: CGEventTapPlacement,
                                       mask: CGEventMask, userInfo: UnsafeMutableRawPointer?) -> CFMachPort? {
        let tap: CGEventTapLocation = location == .hid ? .cghidEventTap : .cgSessionEventTap
        return CGEvent.tapCreate(tap: tap, place: place, options: options,
                                 eventsOfInterest: mask, callback: eventTapHandler, userInfo: userInfo)
    }

    /// Called from the C tap handler. The tap is installed on the main run loop, so
    /// the handler fires on the main thread — assume the isolation rather than hop
    /// (a hop would break the synchronous return the C API requires).
    ///
    /// The callback's return is the tap verdict and is honoured: `nil` swallows the
    /// event, a non-nil event is passed back to the system (return the same event to
    /// pass through, possibly after mutating it in place). Callbacks that only
    /// observe must `return nil`.
    nonisolated static func dispatch(_ tap: EventTap, _ type: CGEventType,
                                     _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // CGEvent isn't Sendable, but the C handler fires synchronously on the main
        // run loop where the tap was installed — the hand-off is real-thread-safe.
        let signpost = Perf.signposter.beginInterval("tap.callback")
        defer { Perf.signposter.endInterval("tap.callback", signpost) }
        nonisolated(unsafe) let event = event
        // Same reason the result is carried out through an `unsafe` var rather than
        // returned from the closure: CGEvent isn't Sendable, but nothing here ever
        // leaves the main thread.
        nonisolated(unsafe) var verdict: CGEvent?
        MainActor.assumeIsolated {
            verdict = tap.callback(Proxy(tap: tap), type, event)
        }
        // Unretained: every real tap returns the event it was handed, whose lifetime
        // the caller owns — which is what passUnretained models.
        return verdict.map { Unmanaged.passUnretained($0) }
    }

    func enable() {
        guard let source, let machPort else { return }
        if !isAdded { CFRunLoopAddSource(runLoop, source, mode); isAdded = true }
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    func disable() {
        guard let source, let machPort else { return }
        if isAdded { CFRunLoopRemoveSource(runLoop, source, mode); isAdded = false }
        CGEvent.tapEnable(tap: machPort, enable: false)
    }
}

private func eventTapHandler(proxy: CGEventTapProxy, type: CGEventType,
                             event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    return EventTap.dispatch(tap, type, event)
}
