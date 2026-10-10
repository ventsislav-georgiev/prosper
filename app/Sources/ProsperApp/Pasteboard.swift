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
}
