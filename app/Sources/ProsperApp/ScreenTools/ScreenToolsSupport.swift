// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from vorssaint-utils (github.com/vorssaint/vorssaint-utils, GPL-3.0):
//   - `selectionRect`, `clamp`, `clickDragThreshold`, `isClick`
//     from `Sources/Vorssaint/Services/QuickTools/ScreenshotSupport.swift`
//   - the row-bucketed reading order behind `joinedRecognizedText`, and
//     `openableURL`, from `Sources/Vorssaint/Services/QuickTools/QuickToolsSupport.swift`
//     (`hexString` is the hex branch of its `colorString`)
//
// `globalCGRect(fromViewRect:screenFrame:primaryTop:)` and `primaryTop` are
// Prosper-new — no upstream equivalent.

import AppKit
import CoreGraphics

/// Pure geometry, ordering and formatting helpers for the screen tools. No
/// Vision, no ScreenCaptureKit, no pasteboard — everything here is unit-testable.
enum ScreenToolsSupport {

    // MARK: - Selection geometry

    /// Rectangle between two drag points. `square` constrains to the largest
    /// square that fits the drag; `fromCenter` treats the origin as the center
    /// (Option held).
    static func selectionRect(from origin: CGPoint,
                              to current: CGPoint,
                              square: Bool = false,
                              fromCenter: Bool = false) -> CGRect {
        var dx = current.x - origin.x
        var dy = current.y - origin.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter {
            return CGRect(x: origin.x - abs(dx), y: origin.y - abs(dy),
                          width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(x: min(origin.x, origin.x + dx),
                      y: min(origin.y, origin.y + dy),
                      width: abs(dx), height: abs(dy))
    }

    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let result = rect.intersection(bounds)
        return result.isNull ? .zero : result
    }

    /// A press that never travelled beyond this is a click, not a region drag.
    static let clickDragThreshold: CGFloat = 4

    static func isClick(from origin: CGPoint, to end: CGPoint) -> Bool {
        abs(end.x - origin.x) < clickDragThreshold && abs(end.y - origin.y) < clickDragThreshold
    }

    // MARK: - Coordinates

    /// CoreGraphics' global origin: the TOP-LEFT of the PRIMARY display.
    ///
    /// Deliberately `screens[0]` (the primary) and NOT `screens.map(\.frame.maxY).max()`.
    /// The `max` form diverges the moment a secondary display is arranged *above*
    /// the primary, which puts every converted capture rect at the wrong Y.
    /// `VisionContext.cgRegion` / `cgRegionAbove` still use the `max` form; that
    /// is a separate, out-of-scope fix — do not copy it here.
    @MainActor
    static var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// A rect in a flipped (top-left origin) view covering `screenFrame` exactly,
    /// into the global top-left-origin points rect `VisionContext.capture` wants.
    static func globalCGRect(fromViewRect viewRect: CGRect,
                             screenFrame: CGRect,
                             primaryTop: CGFloat) -> CGRect {
        CGRect(x: screenFrame.minX + viewRect.minX,
               y: (primaryTop - screenFrame.maxY) + viewRect.minY,
               width: viewRect.width,
               height: viewRect.height)
    }

    // MARK: - Reading order

    /// Top-down by row, left-to-right within a row. `y` is bottom-left-origin
    /// normalized (Vision's convention): rows land within 0.5 of each other on a
    /// 50-row grid are treated as the same row.
    static func joinedInReadingOrder(_ items: [(text: String, x: Double, y: Double)]) -> String {
        items
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                let rowA = (1 - $0.y) * 50
                let rowB = (1 - $1.y) * 50
                if abs(rowA - rowB) >= 0.5 { return rowA < rowB }
                return $0.x < $1.x
            }
            .map(\.text)
            .joined(separator: "\n")
    }

    /// Vision returns lines in its own order, which is not reading order.
    static func joinedRecognizedText(_ lines: [OCRLine]) -> String {
        joinedInReadingOrder(lines.map {
            (text: $0.text, x: Double($0.boundingBox.minX), y: Double($0.boundingBox.midY))
        })
    }

    // MARK: - Payload safety

    /// A scanned code must never be able to launch an arbitrary URL scheme:
    /// http/https only, parseable, no whitespace, non-empty host. Anything else
    /// is copy-only.
    static func openableURL(from payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: - Color

    /// Uppercase `#RRGGBB` in sRGB, out-of-gamut components clamped.
    static func hexString(for color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X",
                      byte(srgb.redComponent),
                      byte(srgb.greenComponent),
                      byte(srgb.blueComponent))
    }
}
