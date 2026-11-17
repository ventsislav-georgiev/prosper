import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1429: the Recent folders menu's chevron is an NSImage described by the menu's title (VoiceOver read the bare
/// symbol's "go down"); it must draw exactly as the old `Image(systemName:)` label did. Offscreen only: one host in a
/// borderless window that is never shown, drawn with cacheDisplay into memory; no menu is opened, nothing is written.
final class AgentRecentFoldersChevronTests: XCTestCase {

    /// The menu as the form builds it, around `chevron`, on a plain canvas of whole points.
    @MainActor
    private func menu(_ chevron: Image, disabled: Bool) -> AnyView {
        AnyView(ZStack {
            Color.black
            Menu { Button("~/example") {} } label: { AgentNewSession.recentFoldersLabel(chevron) }
                .recentFoldersMenuStyle(disabled: disabled)
        }
        .frame(width: 40, height: 40)
        .environment(\.colorScheme, .dark))
    }

    @MainActor
    private func draw(_ host: NSHostingView<AnyView>, _ view: AnyView) throws -> NSBitmapImageRep {
        host.rootView = view
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels of `a` that differ from `b` (sizes must match), and pixels of `a` that differ from its own corner.
    private func compare(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (differ: Int, ink: Int) {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let bg = a.colorAt(x: 0, y: 0) else { return (-1, 0) }
        var differ = 0, ink = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { differ += 1; continue }
                if p != q { differ += 1 }
                if p != bg { ink += 1 }
            }
        }
        return (differ, ink)
    }

    /// At UI scales 0.85, 1.0 and 1.25, enabled and disabled: the button's bitmap is pixel for pixel the one the old
    /// label drew, in the same host at the same scale, and the chevron is drawn at all (ink).
    @MainActor
    func testRecentFoldersChevronDrawsLikeTheSymbolImage() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let (win, host) = AXTreeSupport.hosted(AnyView(Color.clear), CGSize(width: 40, height: 40))
        defer { win.close() }
        for scale in [0.85, 1.0, 1.25] as [CGFloat] {
            ThemeRuntime.scale = scale
            for disabled in [false, true] {
                let old = try draw(host, menu(Image(systemName: "chevron.down"), disabled: disabled))
                let new = try draw(host, menu(Image(nsImage: AgentNewSession.recentFoldersChevron()), disabled: disabled))
                let (differ, ink) = compare(new, old)
                XCTAssertTrue(ink > 0, "scale \(scale) disabled \(disabled): the chevron is drawn")
                XCTAssertEqual(differ, 0, "scale \(scale) disabled \(disabled): \(ink) ink pixels")
            }
        }
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// The image carries the menu's title as its description, never the symbol's own text.
    @MainActor
    func testRecentFoldersChevronIsDescribedByTheMenuTitle() {
        XCTAssertEqual(AgentNewSession.recentFoldersChevron().accessibilityDescription, "Recent folders")
    }
}
