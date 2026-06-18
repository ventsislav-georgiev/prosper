import AppKit

/// Read-only inspection of the Chromium private pasteboard flavors that
/// Electron/Chromium apps (Slack, Notion, VS Code, Discord…) write alongside the
/// plain-text flavor when content is copied or dragged.
///
/// Chromium stamps the originating page/app URL onto `org.chromium.source-url`.
/// Reading it lets us recover a *source host* for Electron apps — which expose no
/// `AXDocument`/`AXURL` the way real browsers do — so per-domain completion
/// scoping (the denylist) can apply there too, not just in Safari/Chrome.
///
/// ## Strictly non-destructive
/// Everything here only *reads* `NSPasteboard.general`. It never calls
/// `clearContents()` / `setString` / `declareTypes`, never triggers a synthetic
/// ⌘C, and never mutates the user's clipboard. The system pasteboard is shared
/// global state; clobbering it to fish for context would be hostile.
///
/// ## Caveat: staleness
/// The Chromium flavors reflect the *last copy/drag*, not necessarily the
/// frontmost tab or app. We therefore only consult this for an Electron
/// frontmost app and only for the (opt-in, default-empty) domain denylist, where
/// an occasional stale match merely suppresses one suggestion — low harm. We do
/// NOT use it as positive text context for the model.
///
/// We deliberately do not parse `org.chromium.web-custom-data` (a length-prefixed
/// UTF-16 mime→payload map): brittle to decode, app-specific, and of marginal
/// value next to the AX/text-marker and OCR text paths.
enum ChromiumPasteboard {

    /// Chromium's source-URL pasteboard flavor.
    private static let sourceURLType = NSPasteboard.PasteboardType("org.chromium.source-url")

    /// Whether the general pasteboard currently carries Chromium private flavors
    /// (i.e. the last copy came from a Chromium/Electron surface).
    static func hasChromiumFlavors() -> Bool {
        NSPasteboard.general.types?.contains(sourceURLType) ?? false
    }

    /// Host of `org.chromium.source-url` on the general pasteboard, or nil when the
    /// flavor is absent or unparseable. Read-only; does not mutate the pasteboard.
    static func sourceHost() -> String? {
        guard let raw = NSPasteboard.general.string(forType: sourceURLType),
              !raw.isEmpty else { return nil }
        return URL(string: raw)?.host
    }
}
