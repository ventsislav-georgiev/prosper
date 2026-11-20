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

    /// #1020: the clip a paste path saves before it writes its own text, to put back after the paste.
    struct SavedClip: Equatable {
        var string: String?
        var rtf: Data?
    }

    /// #1020 F3: under `.denied` nothing is read: what a denied read returns (nil, empty or stale) is
    /// undocumented, so the restore must not depend on it. Every snippet and autocomplete paste saves here.
    static func save(_ pb: NSPasteboard, rtf: Bool = false, access: ClipboardAccess) -> SavedClip {
        guard access != .denied else { return SavedClip() }
        return SavedClip(string: pb.string(forType: .string), rtf: rtf ? pb.data(forType: .rtf) : nil)
    }

    /// #1020 F3: Prosper's pasted text never stays behind. What was saved is written back; a clip that
    /// could not be read (denied, or no text on it) leaves the pasteboard empty.
    static func restore(_ saved: SavedClip, to pb: NSPasteboard) {
        pb.clearContents()
        if let rtf = saved.rtf { pb.setData(rtf, forType: .rtf) }
        if let string = saved.string { pb.setString(string, forType: .string) }
    }
}
