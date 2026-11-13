import AppKit

enum Pasteboard {
    /// The app's one pasteboard; under XCTest a private per-process pasteboard, released at exit,
    /// so a test run never touches the user's clipboard (#316).
    nonisolated(unsafe) static let general: NSPasteboard = {
        guard NSClassFromString("XCTestCase") != nil else { return NSPasteboard.general }
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.\(getpid())"))
        atexit { Pasteboard.general.releaseGlobally() }
        return pb
    }()

    /// #210: macOS's per-app paste setting, read fresh on each call (no change notification is
    /// documented). `.unknown` under XCTest, so tests never read the real one; they inject theirs.
    static func access() -> ClipboardAccess {
        guard NSClassFromString("XCTestCase") == nil else { return .unknown }
        guard #available(macOS 15.4, *) else { return .unknown }
        return ClipboardAccess(general.accessBehavior)
    }
}
