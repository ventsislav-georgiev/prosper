import AppKit
import XCTest
@testable import ProsperApp

/// #091. The mixer panel is a popover anchored to the status-item button's
/// bounds, and `NSStatusBarButton` autosizes to whatever image it holds — so
/// while the panel was open, muting or unmuting swapped the menu-bar glyph for
/// one of a different intrinsic height, the button's box moved a point, and the
/// whole panel slid with it. Every glyph now goes through one fixed box.
@MainActor
final class MixerPanelAnchorTests: XCTestCase {
    /// Every state `MixerPanelController.glyph` can land on, muted first.
    private static let states: [(name: String, volume: Double?, muted: Bool?, device: String?)] = [
        ("explicit mute", 0.5, true, nil),
        ("zero volume", 0, false, nil),
        ("one step up", 0.06, false, nil),
        ("half", 0.5, false, nil),
        ("unity", 1, false, nil),
        ("unreadable volume", nil, nil, nil),
        ("AirPods", 0.5, false, "Vents’s AirPods"),
        ("AirPods Pro", 0.5, false, "AirPods Pro"),
        ("AirPods Max", 0.5, false, "AirPods Max"),
        ("AirPods 3", 0.5, false, "AirPods (3rd generation)"),
        ("AirPods 4", 0.5, false, "AirPods (4th generation)"),
        ("muted AirPods", 0.5, true, "AirPods Pro"),
    ]

    private func image(_ state: (name: String, volume: Double?, muted: Bool?, device: String?))
        throws -> NSImage {
        try XCTUnwrap(MixerPanelController.glyphImage(volume: state.volume,
                                                     muted: state.muted,
                                                     outputDeviceName: state.device),
                      "no glyph image for \(state.name)")
    }

    /// The measurement that matters: the rect `NSPopover` is handed. Without the
    /// fixed box this reads 24.5x29 for the slashed speaker and 24.0x28 for the
    /// wave, one point apart in the button's window.
    func testStatusItemButtonBoxIsIdenticalForEveryGlyph() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: 24)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)

        var reference: (bounds: NSRect, inWindow: NSRect)?
        for state in Self.states {
            button.image = try image(state)
            button.superview?.layoutSubtreeIfNeeded()
            let box = (bounds: button.bounds, inWindow: button.convert(button.bounds, to: nil))
            guard let reference else { reference = box; continue }
            XCTAssertEqual(box.bounds, reference.bounds,
                           "\(state.name) resizes the status-item button")
            XCTAssertEqual(box.inWindow, reference.inWindow,
                           "\(state.name) moves the rect the panel is anchored to")
        }
        XCTAssertNotNil(reference)
    }

    /// Guards the box itself: a glyph bigger than `glyphBox` would be scaled
    /// down instead of letterboxed, which is a visible regression rather than a
    /// moving panel.
    func testGlyphBoxHoldsEverySymbolAtItsOwnSize() throws {
        for state in Self.states {
            XCTAssertEqual(try image(state).size, MixerPanelController.glyphBox,
                           "\(state.name) is not stamped into the shared box")
            let bare = MixerPanelController.glyph(volume: state.volume,
                                                 muted: state.muted,
                                                 outputDeviceName: state.device)
            let symbol = try XCTUnwrap(NSImage(systemSymbolName: bare.name,
                                              variableValue: bare.value,
                                              accessibilityDescription: nil))
            XCTAssertLessThanOrEqual(symbol.size.width, MixerPanelController.glyphBox.width,
                                     "\(bare.name) is wider than the box")
            XCTAssertLessThanOrEqual(symbol.size.height, MixerPanelController.glyphBox.height,
                                     "\(bare.name) is taller than the box")
        }
    }

    /// The letterboxing draws the symbol rather than resizing it, so a broken
    /// draw would ship an empty menu-bar icon. Cheapest guard: it has ink.
    func testBoxedGlyphKeepsItsInk() throws {
        for state in Self.states {
            let boxed = try image(state)
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 22,
                                                    pixelsHigh: 16, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            boxed.draw(in: NSRect(origin: .zero, size: MixerPanelController.glyphBox))
            NSGraphicsContext.restoreGraphicsState()
            let inked = (0..<22).flatMap { x in (0..<16).map { y in rep.colorAt(x: x, y: y) } }
                .filter { ($0?.alphaComponent ?? 0) > 0.05 }
            XCTAssertGreaterThan(inked.count, 20, "\(state.name) drew an empty glyph")
        }
    }
}
