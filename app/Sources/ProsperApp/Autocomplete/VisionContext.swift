import AppKit
import CoreGraphics
import CoreImage
import ScreenCaptureKit

/// Screen-capture helpers backing the optional "use screenshots for context"
/// feature (multimodal completion) and the "improve suggestion appearance"
/// feature (sample colors near the caret so the ghost text blends in).
///
/// Capture requires the **Screen Recording** privacy permission. All capture is
/// local; the image is fed only to the in-process VLM (or reduced to a single
/// average color) and never leaves the machine, and is never written to disk.
/// Everything degrades to nil when permission is missing.
enum VisionContext {

    /// Whether the process currently holds Screen Recording permission.
    /// `CGPreflightScreenCaptureAccess` only *checks* — it never prompts.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests Screen Recording permission (shows the system prompt once).
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Captures a box around the caret (in Cocoa screen coordinates) as a
    /// downscaled `CIImage` for the VLM. Returns nil without permission or on
    /// failure. The region is padded so surrounding UI/text is visible.
    static func captureAroundCaret(_ caretRect: CGRect) async -> CIImage? {
        guard hasScreenRecordingPermission() else { return nil }
        guard let cgRect = cgRegion(around: caretRect, padX: 320, padY: 140) else { return nil }
        guard let image = await capture(cgRect) else { return nil }
        return CIImage(cgImage: image)
    }

    /// Samples the average background color in a small box at the caret so the
    /// ghost overlay can adapt (e.g. lighter text on dark UIs). Returns nil
    /// without permission. Async because capture now goes through ScreenCaptureKit.
    static func averageColorAroundCaret(_ caretRect: CGRect) async -> NSColor? {
        guard Preferences.improveAppearanceFromScreenshot,
              hasScreenRecordingPermission() else { return nil }
        guard let cgRect = cgRegion(around: caretRect, padX: 40, padY: 12),
              let image = await capture(cgRect) else { return nil }
        return Self.averageColor(of: image)
    }

    /// On-screen text near the caret, recognized with the Vision framework (ANE),
    /// for use as extra LLM context where the Accessibility API exposes little or
    /// nothing (Electron/Chromium apps). Returns nil without permission or when no
    /// text is found. Captures a wider region than the appearance sampler so a few
    /// surrounding lines are included. The text is used only as prompt context and
    /// is never persisted.
    static func surroundingText(around caretRect: CGRect) async -> String? {
        guard hasScreenRecordingPermission() else { return nil }
        guard let cgRect = cgRegion(around: caretRect, padX: 380, padY: 160),
              let image = await capture(cgRect) else { return nil }
        let lines = await VisionOCR.recognizeLines(in: image)
        guard !lines.isEmpty else { return nil }
        // Reading order: Vision y is bottom-up, so descending midY = top-to-bottom.
        let text = lines
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Conversation history visible on screen, for chat/email/social surfaces.
    /// Unlike `surroundingText` (a thin band hugging the caret), this captures a
    /// tall region reaching far *upward* from the caret — in a messaging or mail UI
    /// the input field sits at the bottom and the dialog scrolls above it — so the
    /// recognized text is the conversation so far, not just the line above the
    /// caret. OCR + reading-order (top-to-bottom) identical to `surroundingText`.
    /// Same permission + privacy story: local-only, fed to the model as context,
    /// never persisted. Returns nil without permission or when no text is found.
    static func conversationText(around caretRect: CGRect) async -> String? {
        guard hasScreenRecordingPermission() else { return nil }
        guard let cgRect = cgRegionAbove(caretRect, padX: 420, padUp: 1100, padDown: 60),
              let image = await capture(cgRect) else { return nil }
        let lines = await VisionOCR.recognizeLines(in: image)
        guard !lines.isEmpty else { return nil }
        // Vision y is bottom-up, so descending midY = top-to-bottom reading order.
        let text = lines
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Internals

    /// Builds a capture rect that extends mostly *upward* from the caret (the chat
    /// history sits above the input field), flipped into CoreGraphics (top-left
    /// origin) coordinates. `capture` clamps an over-tall rect to the display.
    private static func cgRegionAbove(_ caretRect: CGRect, padX: CGFloat,
                                      padUp: CGFloat, padDown: CGFloat) -> CGRect? {
        guard let screens = NSScreen.screens.first else { return nil }
        let globalTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? screens.frame.maxY
        let minX = caretRect.minX - padX
        let width = max(caretRect.width, 1) + padX * 2
        // Cocoa (bottom-left origin): +Y is up, so the history is above the caret.
        let topY = caretRect.maxY + padUp
        let bottomY = caretRect.minY - padDown
        let height = topY - bottomY
        let cgY = globalTop - topY          // flip: CG origin top-left, use top edge.
        return CGRect(x: minX, y: cgY, width: width, height: height)
    }

    /// Converts a Cocoa (bottom-left origin) screen rect into a padded
    /// CoreGraphics (top-left origin) capture rect, clamped to the desktop.
    private static func cgRegion(around caretRect: CGRect, padX: CGFloat, padY: CGFloat) -> CGRect? {
        guard let screens = NSScreen.screens.first else { return nil }
        // Global top edge = max Y across all screens (Cocoa coordinates).
        let globalTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? screens.frame.maxY
        var rect = caretRect.insetBy(dx: -padX, dy: -padY)
        if rect.width < 8 || rect.height < 8 {
            rect = CGRect(x: caretRect.minX - padX, y: caretRect.minY - padY,
                          width: padX * 2, height: padY * 2)
        }
        // Flip Y: CG origin is top-left.
        let cgY = globalTop - rect.maxY
        return CGRect(x: rect.minX, y: cgY, width: rect.width, height: rect.height)
    }

    /// Captures a screen region (`globalRect` is top-left-origin, global, in
    /// points) using ScreenCaptureKit's one-shot screenshot API
    /// (`SCScreenshotManager`, macOS 14+).
    ///
    /// This replaces the deprecated `CGWindowListCreateImage`, which on macOS 15
    /// (Sequoia) triggers a recurring "‘App’ is requesting to … access your
    /// screen and audio" consent dialog on a system timer — even when Screen
    /// Recording permission is already granted. SCK uses the same permission but
    /// does not trip that periodic prompt. No audio is ever captured: this is a
    /// still-image API and Prosper opens no audio or video stream.
    private static func capture(_ globalRect: CGRect) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else { return nil }

        // Pick the display containing the region's centre, else the largest overlap.
        let center = CGPoint(x: globalRect.midX, y: globalRect.midY)
        let display = content.displays.first { $0.frame.contains(center) }
            ?? content.displays.max { overlapArea($0.frame, globalRect) < overlapArea($1.frame, globalRect) }
        guard let display else { return nil }

        // `sourceRect` is display-local, top-left origin, in points.
        let local = globalRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let bounds = CGRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height)
        let clipped = local.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }

        let scale = backingScale(for: display.displayID)
        let config = SCStreamConfiguration()
        config.sourceRect = clipped
        config.width = Int((clipped.width * scale).rounded())
        config.height = Int((clipped.height * scale).rounded())
        config.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Area of the intersection of two rects (0 when they don't overlap).
    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    /// Backing scale (pixels per point) of the display with the given id, so the
    /// captured crop is at native resolution. Defaults to 2 on lookup failure.
    private static func backingScale(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               num.uint32Value == displayID {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Computes the average color of a CGImage by drawing it into a 1×1 context.
    private static func averageColor(of image: CGImage) -> NSColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(
            red: CGFloat(pixel[0]) / 255.0,
            green: CGFloat(pixel[1]) / 255.0,
            blue: CGFloat(pixel[2]) / 255.0,
            alpha: 1.0
        )
    }
}
