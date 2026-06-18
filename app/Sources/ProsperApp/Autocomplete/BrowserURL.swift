import AppKit
import ApplicationServices

/// Best-effort extraction of the active browser tab's host via Accessibility,
/// for per-domain completion scoping. Returns nil for non-browser apps or when
/// the URL can't be read (no AppleScript / automation permission needed).
enum BrowserURL {

    /// Bundle ids treated as browsers. Most expose the document URL via AX.
    static let browserBundleIds: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    /// The host (e.g. `example.com`) of the frontmost browser's active tab,
    /// or nil if the frontmost app isn't a browser / URL unavailable.
    @MainActor
    static func currentHost() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier,
              browserBundleIds.contains(bundleId) else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let urlString = documentURL(of: axApp) else { return nil }
        return URL(string: urlString)?.host
    }

    /// Reads `AXDocument` (a URL string) from the app's focused window, falling
    /// back to a shallow search of the focused element's web area.
    private static func documentURL(of axApp: AXUIElement) -> String? {
        // 1. Focused window's AXDocument (Safari/Chrome set this to the page URL).
        if let window = copyElement(axApp, kAXFocusedWindowAttribute),
           let doc = copyString(window, kAXDocumentAttribute), !doc.isEmpty {
            return doc
        }
        // 2. App-level AXDocument.
        if let doc = copyString(axApp, kAXDocumentAttribute), !doc.isEmpty {
            return doc
        }
        // 3. Focused UI element → ancestor web area exposing AXURL.
        if let focused = copyElement(axApp, kAXFocusedUIElementAttribute),
           let url = copyString(focused, "AXURL"), !url.isEmpty {
            return url
        }
        return nil
    }

    // MARK: - AX helpers

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() { return (value as! CFString) as String }
        if CFGetTypeID(value) == CFURLGetTypeID() { return ((value as! CFURL) as URL).absoluteString }
        return nil
    }
}
