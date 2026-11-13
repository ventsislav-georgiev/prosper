import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1095: every shipped tint's three accent hexes, written out. A hue change that keeps
/// contrast and distinctness passes every other theme test (QA #825: Silver Plum blue
/// #5E3A78 to #3A5E78), so the values are pinned here, row by row, and the rows must be
/// exactly the tints the bundled themes ship. The expectation is this literal table, never
/// the theme.json it checks.
@MainActor
final class ThemeTintPinTests: XCTestCase {
    struct Row {
        let theme: String, tint: String, blue: String, blueBright: String, indigo: String
        init(_ theme: String, _ tint: String, blue: String, blueBright: String, indigo: String) {
            self.theme = theme; self.tint = tint
            self.blue = blue; self.blueBright = blueBright; self.indigo = indigo
        }
    }

    static let table: [Row] = [
        Row("theme-contrast-dark", "Lime", blue: "#E0FF00", blueBright: "#F0FF80", indigo: "#66C2FF"),
        Row("theme-contrast-dark", "Cyan", blue: "#00E5FF", blueBright: "#8CF4FF", indigo: "#A98BFF"),
        Row("theme-contrast-dark", "Amber", blue: "#FFB000", blueBright: "#FFD166", indigo: "#66C2FF"),
        Row("theme-contrast-dark", "Violet", blue: "#B58CFF", blueBright: "#D6C2FF", indigo: "#66C2FF"),
        Row("theme-contrast-dark", "White", blue: "#FFFFFF", blueBright: "#FFFFFF", indigo: "#A0A0A0"),
        Row("theme-contrast-light", "Blue", blue: "#0000C2", blueBright: "#2E2EDB", indigo: "#6A00B8"),
        Row("theme-contrast-light", "Lime", blue: "#3D4A00", blueBright: "#566600", indigo: "#0000C2"),
        Row("theme-contrast-light", "Cyan", blue: "#005866", blueBright: "#00707F", indigo: "#6A00B8"),
        Row("theme-contrast-light", "Amber", blue: "#7A4000", blueBright: "#945000", indigo: "#0000C2"),
        Row("theme-contrast-light", "Violet", blue: "#6B12B8", blueBright: "#7F2ED6", indigo: "#0000C2"),
        Row("theme-contrast-light", "Black", blue: "#000000", blueBright: "#262626", indigo: "#595959"),
        Row("theme-daylight", "Blue", blue: "#0062D1", blueBright: "#0065C7", indigo: "#451FE0"),
        Row("theme-daylight", "Violet", blue: "#5B2BD6", blueBright: "#6A3BE0", indigo: "#0062D1"),
        Row("theme-daylight", "Amber", blue: "#8A4F00", blueBright: "#985700", indigo: "#451FE0"),
        Row("theme-daylight", "Ink", blue: "#1F2A3A", blueBright: "#34445A", indigo: "#0062D1"),
        Row("theme-default", "Neon", blue: "#21CCFF", blueBright: "#75EBFF", indigo: "#5C80FF"),
        Row("theme-default", "Violet", blue: "#A98BFF", blueBright: "#CDBDFF", indigo: "#21CCFF"),
        Row("theme-default", "Amber", blue: "#FFB020", blueBright: "#FFD27A", indigo: "#5C80FF"),
        Row("theme-default", "White", blue: "#E8F2FC", blueBright: "#FFFFFF", indigo: "#8FA3BF"),
        Row("theme-graphite", "Steel", blue: "#9CA7B4", blueBright: "#CAD1D8", indigo: "#8794A2"),
        Row("theme-graphite", "Ice", blue: "#6FC0F2", blueBright: "#B5DDF7", indigo: "#8794A2"),
        Row("theme-graphite", "Sand", blue: "#CDB48A", blueBright: "#E6D7B8", indigo: "#8794A2"),
        Row("theme-graphite", "Lilac", blue: "#B3A3D9", blueBright: "#D6CCEE", indigo: "#8794A2"),
        Row("theme-silver", "Slate", blue: "#434E60", blueBright: "#59687D", indigo: "#5C677A"),
        Row("theme-silver", "Navy", blue: "#1F4F8F", blueBright: "#2D5DA0", indigo: "#5C677A"),
        Row("theme-silver", "Plum", blue: "#5E3A78", blueBright: "#6C4787", indigo: "#5C677A"),
        Row("theme-silver", "Bronze", blue: "#6B5020", blueBright: "#7A5C27", indigo: "#5C677A"),
    ]

    static let extensionsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)

    /// Every tint of every bundled theme that declares variants (base first), as the app
    /// resolves it: theme dir, tint label, palette.
    static func shipped() throws -> [(theme: String, tint: String, palette: ThemePalette)] {
        var out: [(theme: String, tint: String, palette: ThemePalette)] = []
        let dirs = try FileManager.default.contentsOfDirectory(at: extensionsDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("theme-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in dirs {
            let spec = try ThemeSpec.decode(Data(contentsOf: dir.appendingPathComponent("theme.json")))
            guard !spec.variants.isEmpty else { continue }
            let name = dir.lastPathComponent
            out.append((theme: name, tint: spec.tintLabel ?? "base", palette: ThemePalette.resolve(spec)))
            out += spec.variants.map { (theme: name, tint: $0.label, palette: ThemePalette.resolve(spec, tint: $0.key)) }
        }
        return out
    }

    static func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        let v = [n.redComponent, n.greenComponent, n.blueComponent].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", v[0], v[1], v[2])
    }

    func testTableIsExactlyTheShippedTints() throws {
        let shipped = try Self.shipped()
        let have = Set(shipped.map { "\($0.theme) \($0.tint)" })
        let want = Set(Self.table.map { "\($0.theme) \($0.tint)" })
        XCTAssertEqual(have, want, "shipped tints missing from the table: \(have.subtracting(want).sorted()); "
                       + "table rows no theme ships: \(want.subtracting(have).sorted())")
        XCTAssertEqual(Self.table.count, want.count, "a row is listed twice")
        XCTAssertEqual(Self.table.count, 27, "HC Dark 5, HC Light 6, Default, Daylight, Graphite and Silver 4 each")
    }

    func testEveryShippedTintHasThePinnedHexes() throws {
        var checked = 0
        for s in try Self.shipped() {
            guard let row = Self.table.first(where: { $0.theme == s.theme && $0.tint == s.tint }) else { continue }
            XCTAssertEqual(Self.hex(s.palette.blue), row.blue, "\(s.theme) \(s.tint): blue")
            XCTAssertEqual(Self.hex(s.palette.blueBright), row.blueBright, "\(s.theme) \(s.tint): blueBright")
            XCTAssertEqual(Self.hex(s.palette.indigo), row.indigo, "\(s.theme) \(s.tint): indigo")
            checked += 1
        }
        XCTAssertEqual(checked, Self.table.count, "every row was compared")
    }

    // MARK: evidence renders (supervisor review; skipped unless PROSPER_RENDER_DIR is set)

    private var saved: (ThemePalette, CGFloat)!
    override func setUp() async throws { saved = (ThemeRuntime.palette, ThemeRuntime.scale) }
    override func tearDown() async throws { (ThemeRuntime.palette, ThemeRuntime.scale) = (saved.0, saved.1) }

    /// The themes whose values #1095 changed, every tint at backing 1 and 2; and the two White
    /// tints next to their base tint under both system appearances (the theme stays dark).
    func testTintEvidenceRenders1095() throws {
        guard let out = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map({ URL(fileURLWithPath: $0) })
        else { throw XCTSkip("#1095 evidence renders: set PROSPER_RENDER_DIR to write them") }
        let all = try Self.shipped()
        var n = 0
        for s in all {
            let spec = try ThemeSpec.decode(Data(contentsOf: Self.extensionsDir.appendingPathComponent("\(s.theme)/theme.json")))
            var appearances = [spec.appearance]
            switch (s.theme, s.tint) {
            case ("theme-daylight", _), ("theme-graphite", _), ("theme-silver", _): break
            case ("theme-default", "White"), ("theme-default", "Neon"),
                 ("theme-contrast-dark", "White"), ("theme-contrast-dark", "Lime"): appearances = [.dark, .light]
            default: continue
            }
            ThemeRuntime.palette = s.palette
            for appearance in appearances {
                for backing in [1, 2] as [CGFloat] {
                    try render(Sheet1095(title: "\(s.theme) · \(s.tint) · system \(appearance.rawValue)"),
                               width: 560, appearance: appearance, backing: backing, to: out,
                               name: "t1095-\(s.theme)-\(s.tint.lowercased())-sys\(appearance.rawValue)-b\(Int(backing))")
                    n += 1
                }
            }
        }
        XCTAssertEqual(n, 12 * 2 + 4 * 2 * 2, "Daylight, Graphite, Silver 4 tints x 2 backings; 4 White/base sheets x 2 x 2")
    }

    private func flush(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
    }

    /// ThemeVariantTests.render with the backing as a parameter: a never-shown window parked
    /// off screen (never ordered front or made key), cached into a bitmap at `backing`.
    private func render<V: View>(_ view: V, width: CGFloat, appearance: ThemeAppearance, backing: CGFloat,
                                 to dir: URL, name: String) throws {
        let root = view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, appearance.colorScheme)
        let h = NSHostingView(rootView: root)
        h.frame = CGRect(origin: .zero, size: CGSize(width: width, height: max(1, h.fittingSize.height)))
        let win = NSWindow(contentRect: h.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: appearance.nsAppearanceName)
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.contentView = h
        defer { win.contentView = NSView(); win.close() }
        flush(h)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((h.bounds.width * backing).rounded()),
            pixelsHigh: Int((h.bounds.height * backing).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = h.bounds.size
        h.cacheDisplay(in: h.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}

/// The accent the ways the app draws it, on each surface token it is drawn on: body text next
/// to accent text, a link, an accented rail title, a selected row with its checkmark.
private struct Sheet1095: View {
    let title: String
    var body: some View {
        ZStack(alignment: .topLeading) {
            SettingsBackground()
            VStack(alignment: .leading, spacing: sz(8)) {
                Text(title).font(Neon.font(15, weight: .bold)).foregroundStyle(Neon.textPrimary)
                NeonSectionLabel(title: "Section label", accent: "Section")
                ForEach(ThemeContrastTests.surfaces.map { $0.0 }, id: \.self) { name in
                    let kp = ThemeContrastTests.surfaces.first { $0.0 == name }?.1 ?? \.bgTop
                    HStack(spacing: sz(10)) {
                        Text(name).font(Neon.font(10, weight: .semibold)).frame(width: sz(58), alignment: .leading)
                            .foregroundStyle(Neon.textSecondary)
                        Text("Body text").foregroundStyle(Neon.textPrimary)
                        Text("You").font(Neon.font(12, weight: .semibold)).foregroundStyle(Neon.blue)
                        Text("A link").underline().foregroundStyle(Neon.blueBright)
                        Text("indigo").foregroundStyle(Neon.indigo)
                        neonAccentedText("QuickLinks", accent: "Links").foregroundStyle(Neon.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, sz(8)).padding(.vertical, sz(6))
                    .background(RoundedRectangle(cornerRadius: sz(7)).fill(ThemeRuntime.palette[keyPath: kp]))
                }
                HStack(spacing: sz(8)) {
                    NeonSelectionBar()
                    Image(systemName: "link").foregroundStyle(Neon.blueBright)
                    Text("Selected row").foregroundStyle(Neon.textPrimary)
                    Text("unselected").foregroundStyle(Neon.textSecondary)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Neon.blueBright)
                }
                .padding(.horizontal, sz(8)).padding(.vertical, sz(6))
                .background(NeonSelectedRowFill(selected: true))
            }
            .padding(sz(16))
        }
    }
}
