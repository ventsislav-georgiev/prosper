import AppKit
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
        if MenuBarHost.isHosted {
            return await hostedImages(for: items).compactMapValues {
                grayscale9x8(from: $0).map(MenuBarPerceptualHash.dHash(gray9x8:))
            }
        }
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
        if MenuBarHost.isHosted { return await hostedImages(for: items) }
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

    /// Hosted bars (macOS 27+) have no per-item windows to capture: grab each display's
    /// menu-bar strip once and crop every laid-out item's frame out of it. Overflowed
    /// items (`isLaidOut == false`) have no pixels on screen and drop out.
    @available(macOS 14.0, *)
    private static func hostedImages(for items: [MenuBarItem]) async -> [CGWindowID: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [:] }
        var out: [CGWindowID: CGImage] = [:]
        for display in content.displays {
            let wanted = items.filter { $0.isLaidOut && $0.displayID == display.displayID }
            guard let barBottom = wanted.map(\.frame.maxY).max() else { continue }
            let scale = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }?.backingScaleFactor ?? 2
            let strip = CGRect(x: 0, y: 0, width: display.frame.width, height: barBottom - display.frame.minY)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = strip
            cfg.width = Int(strip.width * scale)
            cfg.height = Int(strip.height * scale)
            cfg.showsCursor = false
            guard let img = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: cfg) else { continue }
            for item in wanted {
                let r = CGRect(x: (item.frame.minX - display.frame.minX) * scale,
                               y: (item.frame.minY - display.frame.minY) * scale,
                               width: item.frame.width * scale, height: item.frame.height * scale)
                if let c = img.cropping(to: r.integral) { out[item.windowID] = c }
            }
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
