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
        let saved = Pasteboard.save(pb, rtf: true, access: .denied)
        XCTAssertEqual(saved, Pasteboard.SavedClip())
        pb.clearContents()
        pb.setString("snippet text", forType: .string)
        Pasteboard.restore(saved, to: pb)
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
            let saved = Pasteboard.save(pb, rtf: true, access: state)
            XCTAssertEqual(saved.string, "the user's clip", "\(state)")
            XCTAssertEqual(saved.rtf, rtf, "\(state)")
            pb.clearContents()
            pb.setString("snippet text", forType: .string)
            Pasteboard.restore(saved, to: pb)
            XCTAssertEqual(pb.string(forType: .string), "the user's clip", "\(state)")
            XCTAssertEqual(pb.data(forType: .rtf), rtf, "\(state)")
        }
        XCTAssertTrue(Pasteboard.save(pb, access: .allowed).rtf == nil, "plain save reads no RTF")
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
        XCTAssertEqual(try count("if let previous {", in: "Autocomplete/AutocompleteEngine.swift"), 0,
                       "an unreadable clip is restored (cleared), not skipped")
    }
}
