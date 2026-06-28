import Foundation
import CoreGraphics
@preconcurrency import ScreenCaptureKit

// Menu-bar item indexer — Phase 3. The only Screen-Recording surface in the
// ordering engine, and the only thing that makes multi-icon apps orderable on
// macOS 26 (Tahoe), where the OS reports every third-party item's title as
// "Menu Item". We rebuild a stable per-item discriminator by capturing the item's
// rendered image and reducing it to a perceptual hash (see MenuBarPerceptualHash).
//
// On-demand only: runs when the user explicitly indexes / applies order while the
// items are revealed — never a background stream. Fail-open and never throws; any
// capture miss just drops that item from the map (it stays unresolved → left in
// place rather than mis-ordered).

@MainActor
enum MenuBarItemIndexer {
    /// Whether Screen Recording is already granted. Indexing is the ONLY part of
    /// the whole menu-bar feature that needs it — hide/show/spacing never do.
    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Prompt for Screen Recording (system dialog, once). Returns current grant.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Perceptual hash per item window. Items must be on-screen (revealed) so the
    /// window server has pixels to hand us. Missing permission / capture failures
    /// drop that item silently. Caller throttles via `MenuBarCircuitBreaker`.
    static func hashes(for items: [MenuBarItem]) async -> [CGWindowID: UInt64] {
        guard !items.isEmpty, hasPermission() else { return [:] }
        guard #available(macOS 14.0, *) else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [:] }

        var windowByID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { windowByID[w.windowID] = w }

        var out: [CGWindowID: UInt64] = [:]
        for item in items {
            guard let win = windowByID[item.windowID],
                  let cg = await screenshot(of: win),
                  let gray = grayscale9x8(from: cg) else { continue }
            out[item.windowID] = MenuBarPerceptualHash.dHash(gray9x8: gray)
        }
        return out
    }

    /// Live cropped image per item window — for the Settings preview, NOT a hash.
    /// On Tahoe every third-party item reports owner pid = Control Center, so
    /// `NSRunningApplication(pid).icon` is dead; capturing the rendered item is the
    /// only way to show a real icon. Same on-screen + permission constraints as
    /// `hashes`; items we can't capture (off-screen / permission) just drop out and
    /// the caller falls back to a placeholder glyph.
    static func images(for items: [MenuBarItem]) async -> [CGWindowID: CGImage] {
        guard !items.isEmpty, hasPermission() else { return [:] }
        guard #available(macOS 14.0, *) else { return [:] }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [:] }

        var windowByID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { windowByID[w.windowID] = w }

        var out: [CGWindowID: CGImage] = [:]
        for item in items {
            guard let win = windowByID[item.windowID],
                  let cg = await screenshot(of: win) else { continue }
            out[item.windowID] = cg
        }
        return out
    }

    @available(macOS 14.0, *)
    private static func screenshot(of window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        // Capture near native size; the 9×8 reduction happens in grayscale9x8.
        cfg.width = max(1, Int(window.frame.width.rounded()))
        cfg.height = max(1, Int(window.frame.height.rounded()))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Downsample any CGImage to a 9×8 single-channel grayscale buffer (72 bytes,
    /// row-major) by letting CoreGraphics resample into a tiny gray context. This
    /// is the bridge between captured pixels and the pure dHash. nil on alloc fail.
    static func grayscale9x8(from image: CGImage) -> [UInt8]? {
        let w = MenuBarPerceptualHash.sampleWidth, h = MenuBarPerceptualHash.sampleHeight
        var buf = [UInt8](repeating: 0, count: w * h)
        let gray = CGColorSpaceCreateDeviceGray()
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w, space: gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low   // box-ish filter is fine for a hash; faster
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}
