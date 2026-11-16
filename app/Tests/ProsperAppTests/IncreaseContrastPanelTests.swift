import AppKit
import XCTest
@testable import ProsperApp

/// #1307 (#1076 phase 2C): Increase Contrast reaches the other own non-opaque panels (Footprint,
/// the layout palette and overlay, the autocomplete ghost and accessory panels). Pure rows pass
/// the flag in; source rows read the files. No row reads the Mac's setting and no panel is made.
@MainActor
final class IncreaseContrastPanelTests: XCTestCase {
    private static var savedIC = false

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { Self.savedIC = ThemeRuntime.increaseContrast }
    }

    override func tearDown() {
        MainActor.assumeIsolated { ThemeRuntime.increaseContrast = Self.savedIC }
        super.tearDown()
    }

    private static func source(_ rel: String) throws -> String {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: app.appendingPathComponent("Sources/ProsperApp/" + rel), encoding: .utf8)
    }

    private static func count(_ needle: String, in hay: String) -> Int {
        hay.components(separatedBy: needle).count - 1
    }

    func testContrastAlphaKeepsTheAlphaOffAndIsOpaqueOn() {
        for a in [CGFloat(0.28), 0.45, 0.75, 0.82, 0.85, 0.9, 0.95] {
            XCTAssertEqual(FootprintWindow.contrastAlpha(a, increaseContrast: false), a, "off keeps \(a)")
            XCTAssertEqual(FootprintWindow.contrastAlpha(a, increaseContrast: true), 1, "on is opaque for \(a)")
        }
        XCTAssertEqual(FootprintWindow.contrastAlpha(0, increaseContrast: true), 0, "an edge that is off stays off")
        ThemeRuntime.increaseContrast = true
        XCTAssertEqual(FootprintWindow.contrastAlpha(0.5), 1, "the default argument reads ThemeRuntime")
    }

    /// Ghost text floors at 0.75 under Increase Contrast and never reaches 1 (typed text is opaque).
    func testGhostAlphaFloorsAndNeverReachesOpaque() {
        XCTAssertEqual(SuggestionWindow.ghostAlpha(0.6, increaseContrast: true), 0.75, accuracy: 0.0001)
        XCTAssertEqual(SuggestionWindow.ghostAlpha(0.55, increaseContrast: true), 0.75, accuracy: 0.0001)
        XCTAssertEqual(SuggestionWindow.ghostAlpha(0.9, increaseContrast: true), 0.9, accuracy: 0.0001)
        XCTAssertEqual(SuggestionWindow.ghostAlpha(0.6, increaseContrast: false), 0.6, accuracy: 0.0001)
        for a in [CGFloat(0.6), 0.55] {
            XCTAssertTrue(SuggestionWindow.ghostAlpha(a, increaseContrast: true) < 1, "ghost alpha \(a)")
        }
    }

    func testFootprintIsFlatUnderEitherSystemFlag() {
        for style in [FootprintWindow.Style.vibrancy, .flat] {
            XCTAssertTrue(FootprintWindow.effectiveStyle(style, reduceTransparency: true, increaseContrast: false) == .flat)
            XCTAssertTrue(FootprintWindow.effectiveStyle(style, reduceTransparency: false, increaseContrast: true) == .flat)
            XCTAssertTrue(FootprintWindow.effectiveStyle(style, reduceTransparency: false, increaseContrast: false) == style)
        }
    }

    func testPaletteBackdropAndAccessoryEdgeFollowTheFlag() {
        let off = LayoutPaletteWindow.backgroundColor(increaseContrast: false)
        let on = LayoutPaletteWindow.backgroundColor(increaseContrast: true)
        XCTAssertEqual(off.alphaComponent, 0.82, accuracy: 0.001)
        XCTAssertEqual(on.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(on.usingColorSpace(.sRGB)?.redComponent ?? 1, 0, accuracy: 0.001, "still black")
        XCTAssertTrue(AccessoryButton.borderColor(increaseContrast: false) == NSColor.separatorColor)
        XCTAssertTrue(AccessoryButton.borderColor(increaseContrast: true) == NSColor.labelColor)
    }

    /// Each changed site goes through the helper; Footprint no longer reads Reduce Transparency
    /// from the Mac (its Reduce Motion read is out of this entry).
    func testPanelSitesGoThroughTheContrastHelpers() throws {
        let foot = try Self.source("FootprintWindow.swift")
        let palette = try Self.source("LayoutPaletteWindow.swift")
        let overlay = try Self.source("LayoutOverlayWindow.swift")
        let ghost = try Self.source("Autocomplete/SuggestionWindow.swift")
        let acc = try Self.source("Autocomplete/AccessoryButton.swift")

        XCTAssertEqual(Self.count("accessibilityDisplayShouldReduceTransparency", in: foot), 0)
        XCTAssertEqual(Self.count("accessibilityDisplayShouldIncreaseContrast", in: foot), 0)
        XCTAssertEqual(Self.count("ThemeStore.shared.reduceTransparencyReader()", in: foot), 1)
        XCTAssertEqual(Self.count("increaseContrast: ThemeRuntime.increaseContrast)", in: foot), 1)
        XCTAssertEqual(Self.count("accent.withAlphaComponent(Self.contrastAlpha(0.9)).cgColor", in: foot), 1)
        XCTAssertEqual(Self.count("accent.withAlphaComponent(Self.contrastAlpha(0.85)).cgColor", in: foot), 1)
        XCTAssertEqual(Self.count("NSColor.black.withAlphaComponent(0.82)", in: palette), 0)
        XCTAssertEqual(Self.count("Self.backgroundColor().cgColor", in: palette), 2, "init and every show")
        XCTAssertEqual(Self.count("accent.withAlphaComponent(FootprintWindow.contrastAlpha(on ? 0.95 : 0.45)).cgColor", in: overlay), 1)
        XCTAssertEqual(Self.count("NSColor.secondaryLabelColor.withAlphaComponent(Self.ghostAlpha(0.6))", in: ghost), 1)
        XCTAssertEqual(Self.count("ghostBase.withAlphaComponent(Self.ghostAlpha(ghostAlphaOwn))", in: ghost), 1)
        XCTAssertEqual(Self.count("label.textColor = ghostColor", in: ghost), 2, "adaptColor and the show-time render")
        XCTAssertEqual(Self.count("NSColor.systemGreen.withAlphaComponent(FootprintWindow.contrastAlpha(0.85))", in: ghost), 1)
        XCTAssertEqual(Self.count("NSColor.systemRed.withAlphaComponent(FootprintWindow.contrastAlpha(0.75)).cgColor", in: ghost), 1)
        XCTAssertEqual(Self.count("ghostAlphaOwn = 0.55", in: ghost), 1)
        XCTAssertEqual(Self.count("NSColor.separatorColor.cgColor", in: acc), 0)
        XCTAssertEqual(Self.count("Self.borderColor().cgColor", in: acc), 3, "init, show and showIndicator")
    }
}
