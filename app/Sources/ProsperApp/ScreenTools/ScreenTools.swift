import AppKit
import Vision

/// The two user-facing screen tools: copy text out of a dragged screen region,
/// and sample a colour anywhere on screen.
///
/// Both write to the general pasteboard, so results land in Prosper's clipboard
/// history like any other copy — intended, and noted in the changelog.
@MainActor
enum ScreenTools {

    /// Drags a region, then copies the barcode payload it holds, or failing that
    /// the text Vision reads out of it.
    ///
    /// The Screen Recording check happens *before* the overlay appears: a denied
    /// user gets one HUD and the privacy pane, never a dim screen that then does
    /// nothing.
    static func copyScreenText() {
        guard VisionContext.hasScreenRecordingPermission() else {
            hud("Screen Recording permission is needed to read the screen")
            PermissionsManager.openScreenRecordingSettings()
            return
        }
        RegionSelector.begin { outcome in
            guard case .region(let rect) = outcome else { return }
            Task { @MainActor in await readRegion(rect) }
        }
    }

    /// Barcode first (a QR beats OCR on the same pixels), then `.accurate` OCR
    /// with a `.fast` retry — `.fast` genuinely reads some rendered UI text the
    /// accurate recognizer returns nothing for.
    private static func readRegion(_ rect: CGRect) async {
        guard let image = await VisionContext.capture(rect, excludingOwnWindows: true) else {
            hud("Could not capture that region")
            return
        }
        if let reading = BarcodeDetector.read(image) {
            // `reading.url` is nil when several barcodes were joined: no open action then.
            finish(reading.payload, open: reading.url)
            return
        }
        var lines = await VisionOCR.recognizeLines(in: image)
        if lines.isEmpty { lines = await VisionOCR.recognizeLines(in: image, level: .fast) }
        let text = ScreenToolsSupport.joinedRecognizedText(lines)
        guard !text.isEmpty else {
            hud("No text found in that region")
            return
        }
        finish(text, open: ScreenToolsSupport.openableURL(from: text))
    }

    /// Copies `text`, then offers to open it when the whole result is one URL.
    private static func finish(_ text: String, open url: URL?) {
        copy(text)
        guard let url else {
            hud("Copied")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Copied to the clipboard"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Copy")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }

    /// Retained for the lifetime of the pick: `NSColorSampler` deallocates its
    /// loupe with itself.
    private static var sampler: NSColorSampler?

    /// Samples one pixel anywhere on screen and copies its sRGB hex. Needs no
    /// permission — the sampler is a system service, not a capture.
    static func pickColor() {
        let sampler = NSColorSampler()
        Self.sampler = sampler
        sampler.show { color in
            MainActor.assumeIsolated {
                Self.sampler = nil
                guard let color else { return }
                let hex = ScreenToolsSupport.hexString(for: color)
                copy(hex)
                hud("Copied \(hex)")
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func hud(_ text: String) {
        ExtensionMenuBar.shared.alert(text: text, seconds: 1.6)
    }
}
