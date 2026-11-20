import AppKit
import XCTest
@testable import ProsperApp

/// #1020: macOS's "Paste from Other Apps" setting. The access state is injected (never the real one),
/// the monitor polls the XCTest-private `Pasteboard.general`, the save/restore rows use a uniquely named
/// pasteboard released in tearDown, and no history store is written.
@MainActor
final class ClipboardPasteProtectionTests: XCTestCase {
    private final class Box { var access = ClipboardAccess.allowed; var payloads: [String] = [] }

    private var monitors: [ClipboardMonitor] = []
    private var boards: [NSPasteboard] = []

    override func tearDown() {
        monitors.forEach { $0.stop() }
        monitors = []
        boards.forEach { $0.releaseGlobally() }
        boards = []
        super.tearDown()
    }

    private func monitor(_ box: Box) -> ClipboardMonitor {
        let m = ClipboardMonitor(workspaceCenter: NotificationCenter(), distributedCenter: NotificationCenter())
        m.captureHistory = false
        m.access = { box.access }
        m.emitChange = { box.payloads.append($0) }
        monitors.append(m)
        return m
    }

    private func board() -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        boards.append(pb)
        return pb
    }

    private func copySomething() {
        Pasteboard.general.clearContents()
        Pasteboard.general.setString("example text \(UUID().uuidString)", forType: .string)
    }

    // MARK: F1, the monitor

    /// Denied: a copy is not read, the timer drops to the slow cadence, and the clip on the
    /// pasteboard when access comes back is captured then.
    func testDeniedReadsNothingAndSlowsTheTimerUntilAccessReturns() {
        let box = Box()
        box.access = .denied
        let m = monitor(box)
        m.start()
        copySomething()
        m.poll()
        XCTAssertEqual(box.payloads.count, 0, "denied: the pasteboard is not read")
        XCTAssertTrue(m.accessDenied)
        XCTAssertEqual(m.timer?.timeInterval, ClipboardMonitor.deniedPollInterval)

        box.access = .allowed
        m.poll()
        XCTAssertEqual(box.payloads.count, 1, "access back: the waiting clip is captured")
        XCTAssertFalse(m.accessDenied)
        XCTAssertEqual(m.timer?.timeInterval, 1.0)
    }

    /// An idle tick (change count unchanged) reads neither the pasteboard nor the access state.
    func testIdleTicksReadNoAccessState() {
        let box = Box()
        let m = monitor(box)
        m.start()
        for _ in 0..<5 { m.poll() }
        XCTAssertEqual(m.accessReads, 0)
        copySomething()
        m.poll()
        m.poll()
        XCTAssertEqual(m.accessReads, 1, "one access read per copy")
    }

    /// Allow (and every state that is not denied): a copy is captured at once on the 1 s timer, as before.
    func testNotDeniedCapturesAsBefore() {
        for state in [ClipboardAccess.allowed, .asks, .systemDefault, .unknown] {
            let box = Box()
            box.access = state
            let m = monitor(box)
            m.start()
            copySomething()
            m.poll()
            XCTAssertEqual(box.payloads.count, 1, "\(state)")
            XCTAssertFalse(m.accessDenied, "\(state)")
            XCTAssertEqual(m.timer?.timeInterval, 1.0, "\(state)")
            m.stop()
        }
    }

    // MARK: F3, the paste paths' save and restore

    /// Denied: nothing is read, and the restore clears what the paste put there.
    func testDeniedSaveReadsNothingAndRestoreClearsThePastedText() {
        let pb = board()
        pb.clearContents()
        pb.setString("the user's clip", forType: .string)
        let saved = Pasteboard.save(pb, access: .denied)
        XCTAssertEqual(saved, Pasteboard.SavedClip())
        pb.clearContents()
        pb.setString("snippet text", forType: .string)
        XCTAssertTrue(Pasteboard.restore(saved, to: pb, ifChangeCount: pb.changeCount))
        XCTAssertTrue(pb.string(forType: .string) == nil, "the snippet must not stay on the clipboard")
        XCTAssertEqual(pb.types?.count ?? 0, 0)
    }

    /// Readable: string and RTF go back exactly.
    func testReadableSaveRestoresStringAndRTF() {
        let pb = board()
        let rtf = Data("{\\rtf1 example}".utf8)
        pb.clearContents()
        pb.setData(rtf, forType: .rtf)
        pb.setString("the user's clip", forType: .string)
        for state in [ClipboardAccess.allowed, .asks, .systemDefault, .unknown] {
            let saved = Pasteboard.save(pb, access: state)
            XCTAssertEqual(saved.string, "the user's clip", "\(state)")
            XCTAssertEqual(saved.data(.rtf), rtf, "\(state)")
            pb.clearContents()
            pb.setString("snippet text", forType: .string)
            XCTAssertTrue(Pasteboard.restore(saved, to: pb, ifChangeCount: pb.changeCount), "\(state)")
            XCTAssertEqual(pb.string(forType: .string), "the user's clip", "\(state)")
            XCTAssertEqual(pb.data(forType: .rtf), rtf, "\(state)")
        }
    }

    /// #1691: a non-text clip (an image item and a file item) goes back item by item, every type's bytes exact.
    func testImageAndFileItemsSurviveTheRestore() {
        let pb = board()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: UInt8(7), count: 64))
        let fileURL = Data("file:///Users/example/report.pdf".utf8)
        let image = NSPasteboardItem(), file = NSPasteboardItem()
        image.setData(png, forType: .png)
        file.setData(fileURL, forType: .fileURL)
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([image, file]))
        let saved = Pasteboard.save(pb, access: .allowed)
        XCTAssertEqual(saved.items.count, 2)
        pb.clearContents()
        pb.setString("snippet text", forType: .string)
        XCTAssertTrue(Pasteboard.restore(saved, to: pb, ifChangeCount: pb.changeCount))
        let back = pb.pasteboardItems ?? []
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back.first?.data(forType: .png), png)
        XCTAssertEqual(back.last?.data(forType: .fileURL), fileURL)
        XCTAssertTrue(pb.string(forType: .string) == nil, "the snippet must not stay on the clipboard")
    }

    /// #1691: a copy the user makes between Prosper's write and the delayed restore is kept; with no copy
    /// in between the restore runs.
    func testRestoreSkipsWhenTheUserCopiedAfterOurWrite() {
        let pb = board()
        pb.clearContents()
        pb.setString("the user's old clip", forType: .string)
        let saved = Pasteboard.save(pb, access: .allowed)
        pb.clearContents()
        pb.setString("snippet text", forType: .string)
        let written = pb.changeCount
        pb.clearContents()
        pb.setString("the user's new copy", forType: .string)
        XCTAssertFalse(Pasteboard.restore(saved, to: pb, ifChangeCount: written))
        XCTAssertEqual(pb.string(forType: .string), "the user's new copy")

        pb.clearContents()
        pb.setString("snippet text", forType: .string)
        XCTAssertTrue(Pasteboard.restore(saved, to: pb, ifChangeCount: pb.changeCount))
        XCTAssertEqual(pb.string(forType: .string), "the user's old clip")
    }

    /// #1691: the save counts the bytes it copies and stops reading at the cap: under a large cap it reads
    /// exactly the bytes the pasteboard holds; under a small one the representation that crosses the cap is
    /// dropped and nothing after it is read.
    func testSaveCountsBytesCopiedAndStopsAtTheCap() {
        let pb = board()
        let types = ["a", "b", "c", "d"].map { NSPasteboard.PasteboardType("com.example.prosper-test.\($0)") }
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setData(Data(count: 100), forType: types[0])
        first.setData(Data(count: 100), forType: types[1])
        second.setData(Data(count: 100), forType: types[2])
        second.setData(Data(count: 100), forType: types[3])
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([first, second]))

        let all = Pasteboard.save(pb, access: .allowed)
        XCTAssertEqual(all.bytesRead, 400, "only the bytes the pasteboard holds")
        XCTAssertEqual(all.items.count, 2)

        let capped = Pasteboard.save(pb, access: .allowed, cap: 250)
        XCTAssertEqual(capped.bytesRead, 300, "the read that crosses the cap is the last one")
        XCTAssertEqual(capped.items.count, 1)
        XCTAssertEqual(capped.items.first?.count, 2)
        XCTAssertTrue(capped.data(types[2]) == nil && capped.data(types[3]) == nil)
        XCTAssertLessThanOrEqual(capped.items.flatMap { $0 }.reduce(0) { $0 + $1.data.count }, 250)
        XCTAssertEqual(Pasteboard.saveByteCap, 32 << 20)

        // The cap crossed by the second representation of an item: the first one of that item is kept.
        let mid = Pasteboard.save(pb, access: .allowed, cap: 150)
        XCTAssertEqual(mid.bytesRead, 200)
        XCTAssertEqual(mid.items.count, 1)
        XCTAssertEqual(mid.items.first?.count, 1)
    }

    /// #1694: a clip with synthesized dyn.* types is read once per concrete type and never per dyn type;
    /// the concrete bytes are all kept. A counting row, not a timing one.
    func testSaveReadsEachConcreteTypeOnceAndNeverADynType() {
        final class CountingItem: NSPasteboardItem {
            nonisolated(unsafe) var reads: [NSPasteboard.PasteboardType] = []
            nonisolated(unsafe) var declared: [NSPasteboard.PasteboardType] = []
            override var types: [NSPasteboard.PasteboardType] { declared }
            override func data(forType type: NSPasteboard.PasteboardType) -> Data? {
                reads.append(type)
                return Data(count: 10)
            }
        }
        let item = CountingItem()
        item.declared = [NSPasteboard.PasteboardType("dyn.ah62d4rv4gu8y63n2nuuhg5pbsm4ca6dbsr4gnkduqf31k3pcr7u1e3basv61a3k"),
                         .png, NSPasteboard.PasteboardType("dyn.age80g55"), .tiff]
        let saved = Pasteboard.save(items: [item])
        XCTAssertEqual(item.reads, [.png, .tiff], "no dyn type read, each concrete type once")
        XCTAssertEqual(saved.items.first?.map(\.type), [.png, .tiff])
        XCTAssertEqual(saved.bytesRead, 20)
    }

    /// #1695: an item whose only types are dyn.* (an app type with no UTI) is kept, each type read once.
    func testSaveKeepsAnItemOfOnlyDynTypes() {
        final class DynItem: NSPasteboardItem {
            nonisolated(unsafe) var reads: [NSPasteboard.PasteboardType] = []
            nonisolated(unsafe) var declared: [NSPasteboard.PasteboardType] = []
            override var types: [NSPasteboard.PasteboardType] { declared }
            override func data(forType type: NSPasteboard.PasteboardType) -> Data? {
                reads.append(type)
                return Data(count: 10)
            }
        }
        let only = DynItem()
        let a = NSPasteboard.PasteboardType("dyn.age80g55"), b = NSPasteboard.PasteboardType("dyn.ah62d4rv4ge80e5pe")
        only.declared = [a, b]
        let mixed = DynItem()
        mixed.declared = [a, .png]
        let saved = Pasteboard.save(items: [only, mixed])
        XCTAssertEqual(only.reads, [a, b])
        XCTAssertEqual(mixed.reads, [.png], "beside a concrete type the dyn type is not read")
        XCTAssertEqual(saved.items.count, 2)
        XCTAssertEqual(saved.items.first?.map(\.type), [a, b])
        XCTAssertEqual(saved.items.last?.map(\.type), [.png])
        XCTAssertEqual(saved.bytesRead, 30)
    }

    /// The snippet (plain and rich) and autocomplete paste paths all save and restore through the seam,
    /// so the three agree on the end state.
    func testEveryPastePathSavesAndRestoresThroughTheSeam() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp")
        func count(_ needle: String, in file: String) throws -> Int {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            return text.components(separatedBy: needle).count - 1
        }
        XCTAssertEqual(try count("Pasteboard.save(pb", in: "Snippets/SnippetExpander.swift"), 2)
        XCTAssertEqual(try count("Pasteboard.restore(", in: "Snippets/SnippetExpander.swift"), 1)
        XCTAssertEqual(try count("Pasteboard.save(pb", in: "Autocomplete/AutocompleteEngine.swift"), 1)
        XCTAssertEqual(try count("Pasteboard.restore(", in: "Autocomplete/AutocompleteEngine.swift"), 1)
        XCTAssertEqual(try count("let written = pb.changeCount", in: "Snippets/SnippetExpander.swift"), 2)
        XCTAssertEqual(try count("let written = pb.changeCount", in: "Autocomplete/AutocompleteEngine.swift"), 1)
        XCTAssertEqual(try count("if let previous {", in: "Autocomplete/AutocompleteEngine.swift"), 0,
                       "an unreadable clip is restored (cleared), not skipped")
    }
}
