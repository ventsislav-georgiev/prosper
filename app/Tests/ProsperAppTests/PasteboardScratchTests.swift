import AppKit
import XCTest
@testable import ProsperApp

/// #316: under XCTest the app's one pasteboard is a private per-process pasteboard, never the
/// user's clipboard. `.general` is only read here, never written.
final class PasteboardScratchTests: XCTestCase {
    @MainActor
    func testPasteboardIsAPrivatePerProcessPasteboard() {
        XCTAssertFalse(Pasteboard.general === NSPasteboard.general)
        XCTAssertEqual(Pasteboard.general.name.rawValue, "eu.illegible.prosper.xctest.\(getpid())")
        let probe = "prosper.scratchProbe.\(UUID().uuidString)"
        let before = NSPasteboard.general.changeCount
        Pasteboard.general.clearContents()
        defer { Pasteboard.general.clearContents() }
        Pasteboard.general.setString(probe, forType: .string)
        XCTAssertEqual(Pasteboard.general.string(forType: .string), probe)
        XCTAssertNotEqual(NSPasteboard.general.string(forType: .string), probe)
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }
}
