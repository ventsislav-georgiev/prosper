#!/usr/bin/env swift
// Generates a modern macOS app icon for Prosper v2.
//
// Concept (kept from v1): the Vulcan salute 🖖 — "Live long and prosper".
// Modernized: Big Sur-style continuous-corner squircle, a vibrant
// violet→fuchsia diagonal gradient (richer evolution of v1's flat pink), a
// soft white medallion for depth, and the hand rendered crisp with a subtle
// drop shadow.
//
// Output: scripts/AppIcon-1024.png  (master). The surrounding shell step
// downsamples it into an .iconset and runs iconutil to produce AppIcon.icns.
//
// Headless-safe: draws into an explicit CGBitmapContext (no app/window).

import AppKit
import CoreText

let SIZE = 1024.0
let scriptDir = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent()
let outURL = scriptDir.appendingPathComponent("AppIcon-1024.png")

func hex(_ s: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    return NSColor(
        red: CGFloat((v >> 16) & 0xff) / 255,
        green: CGFloat((v >> 8) & 0xff) / 255,
        blue: CGFloat(v & 0xff) / 255,
        alpha: 1)
}

// Bitmap context (sRGB, premultiplied alpha).
guard let ctx = CGContext(
    data: nil,
    width: Int(SIZE), height: Int(SIZE),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("cannot create CGContext") }

let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = ns

let rect = NSRect(x: 0, y: 0, width: SIZE, height: SIZE)

// --- Squircle background (continuous corners ≈ 0.2237 * width) -------------
let r = SIZE * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
squircle.addClip()

// Diagonal gradient: violet → fuchsia (modern evolution of v1's pink).
let gradLocs: [CGFloat] = [0.0, 0.55, 1.0]
let grad = gradLocs.withUnsafeBufferPointer {
    NSGradient(colors: [hex("7C3AED"), hex("C026D3"), hex("EC4899")],
               atLocations: $0.baseAddress,
               colorSpace: .sRGB)!
}
grad.draw(in: rect, angle: -45)

// Subtle top sheen for depth.
let sheen = NSGradient(starting: NSColor.white.withAlphaComponent(0.22),
                       ending: NSColor.white.withAlphaComponent(0.0))!
sheen.draw(in: rect, angle: -90)

// --- White medallion (soft circle behind the hand) -------------------------
let medD = SIZE * 0.62
let medRect = NSRect(x: (SIZE - medD) / 2, y: (SIZE - medD) / 2, width: medD, height: medD)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -SIZE * 0.012),
              blur: SIZE * 0.05,
              color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor.white.withAlphaComponent(0.96).setFill()
NSBezierPath(ovalIn: medRect).fill()
ctx.restoreGState()

// --- Vulcan salute emoji ----------------------------------------------------
let glyph = "🖖" as NSString
let fontSize = SIZE * 0.40
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: fontSize)
]
let textSize = glyph.size(withAttributes: attrs)
let origin = NSPoint(x: (SIZE - textSize.width) / 2,
                     y: (SIZE - textSize.height) / 2 + SIZE * 0.005)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -SIZE * 0.008),
              blur: SIZE * 0.03,
              color: NSColor.black.withAlphaComponent(0.22).cgColor)
glyph.draw(at: origin, withAttributes: attrs)
ctx.restoreGState()

// --- Write PNG --------------------------------------------------------------
guard let cgImg = ctx.makeImage() else { fatalError("makeImage failed") }
let rep = NSBitmapImageRep(cgImage: cgImg)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
try png.write(to: outURL)
print("wrote \(outURL.path)")
