import AppKit
import XCTest
@testable import ProsperApp

/// #1738: the Window menu (NSApp.windowsMenu) lists only the user's own windows. Helper panels set
/// isExcludedFromWindowsMenu; user windows leave it false. Windows are built offscreen and deferred,
/// never ordered front or made key.
final class WindowMenuExclusionTests: XCTestCase {
    private let rect = NSRect(x: 0, y: 0, width: 100, height: 60)

    @MainActor func testHelperPanelClassesAreExcluded() {
        let style: NSWindow.StyleMask = [.titled, .nonactivatingPanel]
        XCTAssertTrue(KeyablePanel(contentRect: rect, styleMask: style, backing: .buffered, defer: true).isExcludedFromWindowsMenu)
        XCTAssertTrue(KeyableOverlayPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: true).isExcludedFromWindowsMenu)
        XCTAssertTrue(AgentIslandPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: true).isExcludedFromWindowsMenu)
    }

    @MainActor func testUserWindowClassesAreListed() {
        let style: NSWindow.StyleMask = [.titled, .closable]
        XCTAssertFalse(AgentsNSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: true).isExcludedFromWindowsMenu)
        XCTAssertFalse(TextViewerNSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: true).isExcludedFromWindowsMenu)
    }

    /// Every `NSPanel(` / `NSWindow(` created under Sources (E2EHost is a test host) sets the flag within
    /// the next 16 lines; the user windows are built through their own subclasses and are not matched.
    func testEveryDirectPanelOrWindowCreationExcludesItself() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp")
        let urls = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        var sites = 0, bad: [String] = []
        for url in urls where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where l.range(of: #"(^|[^A-Za-z])NS(Panel|Window)\("#, options: .regularExpression) != nil {
                if l.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                sites += 1
                if !lines[i..<min(i + 16, lines.count)].contains(where: { $0.contains("isExcludedFromWindowsMenu = true") }) {
                    bad.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(sites, 8)
        XCTAssertTrue(bad.isEmpty, "not excluded: \(bad)")
    }
}
