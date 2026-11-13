import AppKit

/// #210: what macOS lets Prosper read from other apps' copies (`NSPasteboard.accessBehavior`,
/// macOS 15.4+). Read through `Pasteboard.access()`; the Clipboard settings section shows a
/// line for `.denied` and `.asks` and nothing otherwise.
enum ClipboardAccess: Equatable {
    case allowed, asks, denied
    /// `.default`: no paste alert was ever raised, so Prosper is not listed in System Settings yet.
    case systemDefault
    /// Older macOS, the test host, or a behaviour newer than this build knows.
    case unknown

    @available(macOS 15.4, *)
    init(_ behavior: NSPasteboard.AccessBehavior) {
        switch behavior {
        case .alwaysAllow: self = .allowed
        case .ask: self = .asks
        case .alwaysDeny: self = .denied
        case .default: self = .systemDefault
        @unknown default: self = .unknown
        }
    }

    /// The System Settings pane's name (SecurityPrivacyExtension, PASTEBOARD_ACCESS).
    static let paneName = "System Settings › Privacy & Security › Paste from Other Apps"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!

    /// Only denied is the warning row (with the System Settings link); asks is a quiet line.
    var warns: Bool {
        switch self {
        case .denied: true
        case .allowed, .asks, .systemDefault, .unknown: false
        }
    }

    /// The Clipboard settings line; nil = nothing is shown.
    var settingsNote: String? {
        switch self {
        case .denied: "Clipboard history can't see what other apps copy. Open \(Self.paneName) to allow Prosper."
        case .asks: "macOS asks before Prosper reads what other apps copy. Allow Prosper in \(Self.paneName) to stop the prompts."
        case .allowed, .systemDefault, .unknown: nil
        }
    }
}
