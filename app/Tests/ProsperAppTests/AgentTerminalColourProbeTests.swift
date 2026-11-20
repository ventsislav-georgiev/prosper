import AppKit
import CoreImage
import GhosttyTerminal
import IOSurface
import XCTest
@testable import ProsperApp

/// #1752 (operator: "prosper has washed out colours, ghostty has better contrast"): what libghostty draws into its own
/// IOSurface for full-width coloured rows, read offscreen (the rig's window is never ordered in): the raw bytes, and the
/// sRGB the surface's colour space tag maps them to (what the compositor shows). Cell centres only, no glyph edges.
extension AgentTerminalTests {
    /// One full row per SGR, top to bottom: 7 = reverse (the default foreground as a fill).
    static let probeRows = ["7", "48;5;1", "48;2;215;119;87", "48;5;3", "48;5;6", "48;2;153;153;153", "48;5;15",
                            "48;5;245", "48;2;255;0;0", "48;2;0;0;255"]
    /// Each row's configured colour after the foreground (Ghostty's default palette 1, 3, 6, 15, the 256 cube's 245).
    static let probeTail = ["#cc6666", "#d77757", "#f0c674", "#8abeb7", "#999999", "#eaeaea", "#8a8a8a", "#ff0000", "#0000ff"]

    struct Drawn { var raw: [Int]; var srgb: [Int]; var alpha: Int }

    @MainActor
    func probeText(_ v: ViewRig) -> String {
        let fill = String(repeating: " ", count: v.rig.c.grid?.cols ?? 80)
        return "\u{1b}[2J\u{1b}[H" + Self.probeRows.map { "\u{1b}[0;\($0)m\(fill)\u{1b}[0m" }.joined(separator: "\r\n")
    }

    /// The IOSurface libghostty presents into, and the layer holding it.
    @MainActor
    static func surfaceRef(_ view: NSView) -> (IOSurfaceRef, CALayer)? {
        var layers = [view.layer].compactMap { $0 }
        while let l = layers.popLast() {
            if let c = l.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() {
                return (unsafeBitCast(c as AnyObject, to: IOSurfaceRef.self), l)
            }
            layers += l.sublayers ?? []
        }
        return nil
    }

    /// Runs of equal pixels down the surface's middle column, top first (runs under 4 px, a glyph or 1x padding, dropped),
    /// each with its raw RGBA and the sRGB its colour space tag maps it to.
    static func drawnRuns(_ s: IOSurfaceRef) -> [Drawn] {
        guard IOSurfaceGetBytesPerElement(s) == 4 else { return [] }   // BGRA8, what libghostty allocates
        var runs: [(raw: [Int], y: Int, len: Int)] = []
        IOSurfaceLock(s, .readOnly, nil)
        let w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s)
        let base = IOSurfaceGetBaseAddress(s).assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let p = base + y * bpr + (w / 2) * 4
            let px = [Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3])]
            if let last = runs.last, last.raw == px { runs[runs.count - 1].len += 1 } else { runs.append((px, y, 1)) }
        }
        IOSurfaceUnlock(s, .readOnly, nil)
        let image = CIImage(ioSurface: s)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return [] }
        let rep = NSBitmapImageRep(cgImage: cg)
        return runs.filter { $0.len >= 4 }.map { r in
            let c = rep.colorAt(x: rep.pixelsWide / 2, y: r.y + r.len / 2)?.usingColorSpace(.sRGB)
            let srgb = c.map { [$0.redComponent, $0.greenComponent, $0.blueComponent].map { Int(($0 * 255).rounded()) } } ?? []
            return Drawn(raw: Array(r.raw.prefix(3)), srgb: srgb, alpha: r.raw[3])
        }
    }

    static func rgb(_ hex: String) -> [Int] {
        let n = Int(hex.dropFirst(), radix: 16) ?? 0
        return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
    }

    static func near(_ a: [Int], _ b: [Int]) -> Bool { a.count == 3 && b.count == 3 && zip(a, b).allSatisfy { abs($0 - $1) <= 1 } }

    /// The probe rows drawn: the background, then one entry per row (from the foreground row on), then the background.
    @MainActor
    func drawnRows(_ v: ViewRig, _ what: String, bg: String, fg: String, raw: Bool = false) -> [Drawn] {
        v.output(probeText(v), self)
        var rows: [Drawn] = []
        let pick: (Drawn) -> [Int] = { raw ? $0.raw : $0.srgb }
        wait(what) {
            let runs = Self.surfaceRef(v.host).map { Self.drawnRuns($0.0) } ?? []
            guard let first = runs.firstIndex(where: { Self.near(pick($0), Self.rgb(fg)) }) else { return false }
            rows = Array(runs[first...])
            return rows.count == Self.probeRows.count + 1 && Self.near(pick(runs.last!), Self.rgb(bg))
        }
        return rows
    }

    /// The cells libghostty draws are the configured colours (within 1/255 at the cell centre, after the surface's
    /// colour space tag), opaque, under Prosper's look and under "My Ghostty theme" (a fixture config): the surface
    /// itself washes nothing out (#1752 H1-H3: colour space, blending, translucency all measured clean).
    @MainActor
    func testTheSurfaceDrawsEachCellInItsConfiguredColour() throws {
        let v = startedView()
        defer { v.tearDown() }
        XCTAssertEqual(Self.surfaceRef(v.host).map { $0.1.isOpaque }, true, "an opaque layer: nothing behind shows through")
        func check(_ name: String, bg: String, fg: String) {
            let rows = drawnRows(v, name, bg: bg, fg: fg)
            let want = [fg] + Self.probeTail + [bg]
            XCTAssertEqual(rows.count, want.count, name)
            for (d, w) in zip(rows, want) {
                XCTAssertTrue(Self.near(d.srgb, Self.rgb(w)), "\(name): drawn \(d.srgb) for \(w)")
                XCTAssertEqual(d.alpha, 255, "\(name): \(w) opaque")
            }
        }
        check("prosper", bg: AgentTerminalLook.hex(Neon.bgBottom), fg: AgentTerminalLook.hex(Neon.textPrimary))
        let file = tempDir().appendingPathComponent("config")
        try "background = #000000\nforeground = #ffffff\n".write(to: file, atomically: true, encoding: .utf8)
        AgentTerminalLook.refresh(v.app, colours: AgentTerminalLook.userColours(choice: "ghostty", files: [file], themeDirs: [],
                                                                                 appearance: .dark))
        check("my ghostty theme", bg: "#000000", fg: "#ffffff")
    }

    /// #1752: a user's `window-colorspace = display-p3` reaches the surface under "My Ghostty theme", as in Ghostty:
    /// each colour's numbers are drawn as Display P3 (raw bytes = the configured numbers), more saturated than sRGB.
    /// Red on the parent: the allowlist dropped the line, so the orange row was drawn as sRGB (raw #ca7c5e).
    @MainActor
    func testMyGhosttyThemeCarriesWindowColorspaceToTheSurface() throws {
        let v = startedView()
        defer { v.tearDown() }
        let file = tempDir().appendingPathComponent("config")
        try "background = #000000\nforeground = #ffffff\nwindow-colorspace = display-p3\n".write(to: file, atomically: true, encoding: .utf8)
        AgentTerminalLook.refresh(v.app, colours: AgentTerminalLook.userColours(choice: "ghostty", files: [file], themeDirs: [],
                                                                                 appearance: .dark))
        let rows = drawnRows(v, "display-p3", bg: "#000000", fg: "#ffffff", raw: true)
        let orange = rows.dropFirst(2).first
        XCTAssertTrue(orange.map { Self.near($0.raw, [215, 119, 87]) } ?? false, "P3 numbers as given: \(String(describing: orange?.raw))")
        XCTAssertFalse(orange.map { Self.near($0.srgb, [215, 119, 87]) } ?? true, "so in sRGB terms it is not the sRGB orange")
    }
}
