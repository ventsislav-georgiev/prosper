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
    /// #1691: every item the pasteboard holds (image, files, rich text), each as its types and data in order.
    struct SavedClip: Equatable {
        struct Representation: Equatable { var type: NSPasteboard.PasteboardType; var data: Data }
        var items: [[Representation]] = []
        /// Bytes copied off the pasteboard by the save, the representation that hit the cap included.
        var bytesRead = 0

        var string: String? { data(.string).flatMap { String(data: $0, encoding: .utf8) } }
        func data(_ type: NSPasteboard.PasteboardType) -> Data? {
            items.lazy.flatMap { $0 }.first { $0.type == type }?.data
        }
    }

    /// #1691: what one save copies at most. A clip past it keeps the representations read before the cap
    /// (the source's preferred ones come first); the rest are not read.
    static let saveByteCap = 32 << 20

    /// #1020 F3: under `.denied` nothing is read: what a denied read returns (nil, empty or stale) is
    /// undocumented, so the restore must not depend on it. Every snippet and autocomplete paste saves here.
    /// #1691: copies the bytes each item holds, as they are (no conversion), until `cap` is reached.
    static func save(_ pb: NSPasteboard, access: ClipboardAccess, cap: Int = saveByteCap) -> SavedClip {
        guard access != .denied else { return SavedClip() }
        return save(items: pb.pasteboardItems ?? [], cap: cap)
    }

    /// #1694: the read loop, over the items (a seam for the call-counting row). `dyn.*` types are conversions
    /// macOS synthesizes on each read and the restore re-synthesizes them, so they are never read; every
    /// concrete type is read exactly once.
    static func save(items: [NSPasteboardItem], cap: Int = saveByteCap) -> SavedClip {
        var saved = SavedClip()
        for item in items {
            var reps: [SavedClip.Representation] = []
            for type in item.types where !type.rawValue.hasPrefix("dyn.") {
                guard let data = item.data(forType: type) else { continue }
                saved.bytesRead += data.count
                guard saved.bytesRead <= cap else {
                    if !reps.isEmpty { saved.items.append(reps) }
                    return saved
                }
                reps.append(.init(type: type, data: data))
            }
            if !reps.isEmpty { saved.items.append(reps) }
        }
        return saved
    }

    /// #1020 F3: Prosper's pasted text never stays behind. What was saved is written back; a clip that
    /// could not be read (denied, or empty) leaves the pasteboard empty.
    /// #1691: only while the pasteboard still holds Prosper's own write (`changeCount` as it was right
    /// after that write); a copy the user made in between is left alone. Returns whether it restored.
    @discardableResult
    static func restore(_ saved: SavedClip, to pb: NSPasteboard, ifChangeCount written: Int) -> Bool {
        guard pb.changeCount == written else { return false }
        pb.clearContents()
        let items = saved.items.map { reps -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for rep in reps { item.setData(rep.data, forType: rep.type) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        return true
    }
}
