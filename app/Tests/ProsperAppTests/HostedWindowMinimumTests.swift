import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1933: does the SwiftUI hosting controller of each hosted window overwrite the window's contentMinSize on its update
/// pass (#1925 found it did for Agent Sessions)? Windows are built and never shown; a run loop turn plus a layout, then
/// the minimum is compared with what the product set. No events are posted.
@MainActor
final class HostedWindowMinimumTests: XCTestCase {
    private func settle(_ win: NSWindow) {
        XCTAssertFalse(win.isVisible, "never on screen")
        win.contentView?.layoutSubtreeIfNeeded()
        win.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))   // SwiftUI's own update pass
        win.contentView?.needsLayout = true
        win.layoutIfNeeded()
    }

    /// Red when the hosting controller writes its own minimum over the window's after a layout pass.
    private func assertKeepsMinimum(_ win: NSWindow, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        defer { win.contentViewController = nil }
        let want = win.contentMinSize
        XCTAssertTrue(want.width > 0 && want.height > 0, "\(name) sets a minimum", file: file, line: line)
        settle(win)
        XCTAssertEqual(win.contentMinSize, want, "\(name): a layout pass leaves the minimum", file: file, line: line)
    }

    func testSettingsWindowKeepsItsMinimum() {
        let win = SettingsWindow.makeWindow(autosave: nil)
        // sizingOptions is [] in the product (SettingsWindow.swift:111); the probe below is what proves it enough.
        assertKeepsMinimum(win, "Settings")
    }

    func testChatWindowKeepsItsMinimum() {
        assertKeepsMinimum(ChatWindow.makeWindow(autosave: nil), "Chat")
    }

    func testTextViewerWindowKeepsItsMinimum() {
        let url = URL(fileURLWithPath: "/Users/example/Notes.md")
        let actions = TextViewerActions(defaultApp: { _ in nil }, openWith: { _, _ in }, reveal: { _ in }, openURL: { _ in }, view: { _ in })
        let model = TextViewerModel(url: url, resolved: url, actions: actions, imageLoader: { _, _, _ in nil },
                                    read: { _ in .failure(.missing) })
        assertKeepsMinimum(TextViewerWindows.makeWindow(model, autosave: nil), "TextViewer")
        withExtendedLifetime(model) {}
    }

    /// The Marketplace window needs the live registry, so its shape (no sizing options, MinimumKeepingWindow, a minimum
    /// set after the content controller) is probed with a stand-in root.
    func testMarketplaceShapeKeepsItsMinimum() {
        let hosting = NSHostingController(rootView: Themed { Color.clear.frame(minWidth: 100, minHeight: 100) })
        hosting.sizingOptions = []   // as MarketplaceWindow.show sets
        let win = MinimumKeepingWindow(contentViewController: hosting)
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 760, height: 720))
        win.contentMinSize = NSSize(width: 520, height: 460)
        let want = win.contentMinSize
        settle(win)
        XCTAssertEqual(win.contentMinSize, want)
        win.contentViewController = nil
    }

    /// Red when a zero write (what the hosting controller does) lowers the minimum, or when the owner can no longer set it.
    func testZeroWriteIsIgnoredAndOwnerWritesStick() {
        let win = MinimumKeepingWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        win.contentMinSize = NSSize(width: 500, height: 400)
        win.contentMinSize = .zero
        XCTAssertEqual(win.contentMinSize, NSSize(width: 500, height: 400))
        win.contentMinSize = NSSize(width: 300, height: 200)   // a scale change lowers it
        XCTAssertEqual(win.contentMinSize, NSSize(width: 300, height: 200))
    }
}
