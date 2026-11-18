import AppKit
import SwiftUI

/// #1546: the sub-agents robot, drawn in Apple's SF line style (replaces the U+1F916 emoji): a rounded head, an antenna
/// with a ball, two eyes, two ears; stroke 0.09 of the side, round caps and joins. It takes the surrounding foregroundStyle
/// as an SF Symbol does. `size` is the unscaled font size of the symbols beside it (the view applies ThemeRuntime.scale itself); the glyph's side is 1.15 of it (the preview's 15 at 13 pt).
enum RobotGeometry {
    /// The line parts (head, stem, ears) and the filled parts (antenna ball, eyes) in `r`, top-left origin.
    static func paths(in r: CGRect) -> (line: Path, fill: Path) {
        let w = r.width, h = r.height
        func y(_ up: CGFloat) -> CGFloat { r.minY + (1 - up) * h }   // the drawing's fractions count from the bottom
        var line = Path(), fill = Path()
        line.addRoundedRect(in: CGRect(x: r.minX + w * 0.12, y: y(0.68), width: w * 0.76, height: h * 0.62),
                            cornerSize: CGSize(width: w * 0.2, height: w * 0.2))
        line.move(to: CGPoint(x: r.midX, y: y(0.68)))
        line.addLine(to: CGPoint(x: r.midX, y: y(0.84)))
        let ball = w * 0.13
        fill.addEllipse(in: CGRect(x: r.midX - ball / 2, y: y(0.84) - ball * 0.35 - ball / 2, width: ball, height: ball))
        let eye = w * 0.14
        for x in [0.36, 0.64] {
            fill.addEllipse(in: CGRect(x: r.minX + w * x - eye / 2, y: y(0.36) - eye / 2, width: eye, height: eye))
        }
        for (x, dir) in [(0.12, -1.0), (0.88, 1.0)] {
            let edge = r.minX + w * x, out = edge + dir * w * 0.08
            line.move(to: CGPoint(x: edge, y: y(0.30)))
            line.addLine(to: CGPoint(x: out, y: y(0.30)))
            line.addLine(to: CGPoint(x: out, y: y(0.46)))
            line.addLine(to: CGPoint(x: edge, y: y(0.46)))
        }
        return (line, fill)
    }
    static let strokeFraction: CGFloat = 0.09
    static let sideFactor: CGFloat = 1.15
}

struct RobotGlyph: View {
    let size: CGFloat

    var body: some View {
        let side = size * ThemeRuntime.scale * RobotGeometry.sideFactor   // Neon.font scales its size: so does the glyph
        Canvas { ctx, canvas in
            let p = RobotGeometry.paths(in: CGRect(origin: .zero, size: canvas))
            let style = StrokeStyle(lineWidth: canvas.width * RobotGeometry.strokeFraction, lineCap: .round, lineJoin: .round)
            ctx.stroke(p.line, with: .foreground, style: style)
            ctx.fill(p.fill, with: .foreground)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("sub-agents")
    }

    /// A template image of the glyph for AppKit (menu items), tinted by the menu; `size` is the image's side in points.
    static func nsImage(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let g = NSGraphicsContext.current?.cgContext else { return false }
            let p = RobotGeometry.paths(in: rect)
            g.setStrokeColor(NSColor.black.cgColor); g.setFillColor(NSColor.black.cgColor)
            g.setLineWidth(rect.width * RobotGeometry.strokeFraction); g.setLineCap(.round); g.setLineJoin(.round)
            g.addPath(p.line.cgPath); g.strokePath()
            g.addPath(p.fill.cgPath); g.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "sub-agents"
        return image
    }
}
