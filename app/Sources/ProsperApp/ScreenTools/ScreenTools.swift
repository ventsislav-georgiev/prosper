import AppKit
import os
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
        VisionOCR.prewarm()
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
        // A cold recognizer takes ~25 s; say so, and take the note down when the read
        // ends, whatever follows (the URL alert shows no HUD of its own). The token
        // leaves a toast another feature showed meanwhile alone. The 60 s self-hide is
        // only a safety net in case the dismiss never runs.
        let coldToast = VisionOCR.isWarm ? nil : hud("Reading text…", seconds: 60)
        let lines = await boundedRecognizeLines(in: image)
        if let coldToast { ExtensionMenuBar.shared.dismissAlert(token: coldToast) }
        let text = ScreenToolsSupport.joinedRecognizedText(lines)
        guard !text.isEmpty else {
            hud("No text found in that region")
            return
        }
        finish(text, open: ScreenToolsSupport.openableURL(from: text))
    }

    /// `.accurate` raced against `deadline` seconds, then `.fast` when it lost or read nothing.
    /// `.accurate` has stalled 28-41 s returning nothing on macOS 27 (#335); a task group
    /// would wait for that hung child (#249), so one continuation is resumed by whichever
    /// finishes first and a late `.accurate` result is dropped.
    nonisolated static func boundedRecognizeLines(
        in image: CGImage, deadline: Double = 5,
        recognize: @escaping @Sendable (CGImage, VNRequestTextRecognitionLevel) async -> [OCRLine]
            = { await VisionOCR.recognizeLines(in: $0, level: $1) }
    ) async -> [OCRLine] {
        let accurateSignpost = Perf.signposter.beginInterval("ocr.accurate", id: Perf.signposter.makeSignpostID())
        let accurate: [OCRLine]? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let once: @Sendable ([OCRLine]?) -> Void = { lines in
                if !resumed.withLock({ defer { $0 = true }; return $0 }) { continuation.resume(returning: lines) }
            }
            Task { once(await recognize(image, .accurate)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) { once(nil) }
        }
        Perf.signposter.endInterval("ocr.accurate", accurateSignpost,
                                    "\(accurate == nil ? "deadline" : "done", privacy: .public)")
        if let accurate, !accurate.isEmpty { return accurate }
        let fastSignpost = Perf.signposter.beginInterval("ocr.fast", id: Perf.signposter.makeSignpostID())
        defer { Perf.signposter.endInterval("ocr.fast", fastSignpost) }
        return await recognize(image, .fast)
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
        Pasteboard.general.clearContents()
        Pasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    private static func hud(_ text: String, seconds: Double = 1.6) -> Int {
        ExtensionMenuBar.shared.alert(text: text, seconds: seconds)
    }
}
