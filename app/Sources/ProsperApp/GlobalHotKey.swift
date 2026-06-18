import Carbon
import Foundation

/// Carbon-based global hotkey wrapper. Registers a single hotkey and invokes a
/// Swift callback when pressed.
///
/// IMPORTANT — single shared event handler. Carbon delivers `kEventHotKeyPressed`
/// to handlers installed on `GetApplicationEventTarget()`. Installing a SEPARATE
/// handler per hotkey using the same C callback does NOT chain: Carbon keeps only
/// the last-installed one, so every press reaches a single handler that then only
/// recognizes its own id — every other shortcut silently dies. We therefore
/// install ONE process-wide handler and dispatch to a shared id → closure map.
final class GlobalHotKey {

    // Unique signature shared by all Prosper hotkeys.
    private static let signature: OSType = 0x50525350 // 'PRSP'

    // Process-wide dispatch state. Touched only on the main thread (registration
    // happens on the main actor; the Carbon callback is pumped by the main run
    // loop), so unsynchronized access is safe.
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var sharedHandler: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private let hotKeyID: UInt32

    /// The keycode + Carbon modifier mask this instance claimed (kept for
    /// diagnostics so callers can describe a failed binding to the user).
    let keyCode: UInt32
    let modifiers: UInt32

    /// `false` when `RegisterEventHotKey` rejected the combo — almost always
    /// `eventHotKeyExistsErr` (-9878) because another app (Raycast, Spotlight,
    /// Alfred…) already owns it. A non-registered hotkey never fires, so callers
    /// surface this to the user rather than failing silently.
    private(set) var isRegistered = false

    /// Creates the hotkey for the given keycode + Carbon modifier mask.
    /// Defaults to Option+L (kVK_ANSI_L = 37, optionKey). `id` must be unique
    /// across concurrently registered hotkeys.
    init(keyCode: UInt32 = UInt32(kVK_ANSI_L),
         modifiers: UInt32 = UInt32(optionKey),
         id: UInt32 = 1,
         handler: @escaping () -> Void) {
        self.hotKeyID = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        Self.installSharedHandlerIfNeeded()
        Self.handlers[id] = handler
        register(keyCode: keyCode, modifiers: modifiers)
    }

    deinit {
        unregister()
    }

    /// Installs the one process-wide Carbon event handler that dispatches every
    /// hotkey press to the registered closure for that id. Idempotent.
    private static func installSharedHandlerIfNeeded() {
        guard sharedHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                guard let eventRef else { return noErr }
                var hkID = EventHotKeyID()
                let s = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard s == noErr, hkID.signature == GlobalHotKey.signature else { return noErr }
                // Pumped by the main run loop → already on the main thread.
                GlobalHotKey.handlers[hkID.id]?()
                return noErr
            },
            1,
            &eventType,
            nil,
            &sharedHandler
        )
        if status != noErr {
            NSLog("prosper: failed to install shared hotkey handler (status \(status))")
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        let hkID = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus == noErr {
            isRegistered = true
        } else {
            // eventHotKeyExistsErr (-9878) → another running app already claimed
            // this combo. Leave isRegistered false so the caller can report it.
            NSLog("prosper: failed to register hotkey id=\(hotKeyID) keyCode=\(keyCode) modifiers=\(modifiers) (status \(registerStatus))")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        GlobalHotKey.handlers[hotKeyID] = nil
    }
}
