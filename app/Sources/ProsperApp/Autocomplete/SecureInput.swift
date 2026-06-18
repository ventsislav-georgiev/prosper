import AppKit
import Carbon.HIToolbox
import IOKit

/// macOS Secure Event Input: engaged by password fields and password managers to
/// block event taps and keylogging. While it is on, Prosper cannot observe
/// keystrokes (the tap goes silent) and must not try to complete. This helper
/// answers "is it on?" and "who is holding it?" — the latter matters because a
/// crashed/backgrounded app can hold Secure Input indefinitely and silently kill
/// completions everywhere; naming the culprit lets the user fix it.
enum SecureInput {

    /// Whether Secure Event Input is currently engaged by any process.
    static var isActive: Bool {
        IsSecureEventInputEnabled()
    }

    /// Localized name of the app holding Secure Input, when identifiable.
    /// The owning pid is published by the WindowServer in the IOHIDSystem
    /// registry entry (`HIDParameters.kCGSSessionSecureInputPID`).
    static func culpritName() -> String? {
        guard let pid = culpritPID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    private static func culpritPID() -> pid_t? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOHIDSystem")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let params = IORegistryEntryCreateCFProperty(
            service, "HIDParameters" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any],
            let pid = params["kCGSSessionSecureInputPID"] as? Int
        else { return nil }
        return pid_t(pid)
    }
}
