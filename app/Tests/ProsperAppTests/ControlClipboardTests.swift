import AppKit
import Foundation
import XCTest
@testable import ProsperApp

/// #1861: clipboard.put over the control channel. Every row writes a named scratch pasteboard of its own (released at the
/// end), swapped in through ControlClipboard.pasteboard; the user's clipboard is never named or written here.
@MainActor
final class ControlClipboardTests: XCTestCase {
    static let raw = NSPasteboard.PasteboardType("eu.illegible.prosper.test.raw")

    /// A fresh scratch pasteboard behind the seams for `body`; the seams and the pasteboard are put back after.
    func withScratch(access: ClipboardAccess = .allowed, _ body: (NSPasteboard) throws -> Void) rethrows {
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.clip.\(UUID().uuidString)"))
        let saved = (ControlClipboard.pasteboard, ControlClipboard.access)
        defer {
            (ControlClipboard.pasteboard, ControlClipboard.access) = saved
            pb.releaseGlobally()
        }
        ControlClipboard.pasteboard = { pb }
        ControlClipboard.access = { access }
        try body(pb)
    }

    /// Two items: text with rich text and an app's raw type, then an image.
    func fill(_ pb: NSPasteboard) {
        let a = NSPasteboardItem(), b = NSPasteboardItem()
        a.setString("the person's copy", forType: .string)
        a.setData(Data("{\\rtf1 copy}".utf8), forType: .rtf)
        a.setData(Data([1, 2, 3, 4]), forType: Self.raw)
        b.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        pb.clearContents()
        pb.writeObjects([a, b])
    }

    func text(_ t: String) -> [String: ControlJSON] { ["text": .string(t)] }

    func refused(_ args: [String: ControlJSON], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ControlClipboard.put(args), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    /// The write replaces the clip with the text alone; undo puts back every item with every type and its bytes.
    func testPutWritesTheTextAndUndoRestoresEveryItemAndType() throws {
        try withScratch { pb in
            fill(pb)
            let before = Pasteboard.save(pb, access: .allowed)
            XCTAssertEqual(before.items.count, 2)
            XCTAssertEqual(before.data(Self.raw), Data([1, 2, 3, 4]))
            let c = try ControlClipboard.put(text("hello\n\tworld"))
            XCTAssertEqual(pb.string(forType: .string), "hello\n\tworld")
            XCTAssertEqual(pb.pasteboardItems?.count, 1)
            XCTAssertTrue(pb.data(forType: Self.raw) == nil)
            XCTAssertEqual(c.verb, "copied to the clipboard")
            XCTAssertEqual(c.summary, "helloworld")
            XCTAssertTrue(c.undo != nil)
            c.undo?()
            XCTAssertEqual(Pasteboard.save(pb, access: .allowed), before)
            // A long text shows at most summaryMax characters in the notice and the log.
            XCTAssertEqual(try ControlClipboard.put(text(String(repeating: "x", count: 500))).summary.count, ControlClipboard.summaryMax)
        }
    }

    /// A copy the person made after the agent's write is never replaced by the undo.
    func testUndoLeavesACopyMadeSinceAlone() throws {
        try withScratch { pb in
            fill(pb)
            let c = try ControlClipboard.put(text("agent text"))
            pb.clearContents()
            pb.setString("copied since", forType: .string)
            c.undo?()
            XCTAssertEqual(pb.string(forType: .string), "copied since")
            XCTAssertEqual(pb.pasteboardItems?.count, 1)
        }
    }

    /// An empty clipboard before: the undo leaves it empty, not holding the agent's text.
    func testUndoOfAPutOnAnEmptyClipboardEmptiesIt() throws {
        try withScratch { pb in
            pb.clearContents()
            let c = try ControlClipboard.put(text("agent text"))
            XCTAssertEqual(pb.string(forType: .string), "agent text")
            c.undo?()
            XCTAssertEqual(pb.pasteboardItems?.count ?? 0, 0)
        }
    }

    /// Under denied paste access nothing is read before the write; the undo empties the clipboard (the seam's rule).
    func testDeniedAccessReadsNothingAndTheUndoEmpties() throws {
        try withScratch(access: .denied) { pb in
            fill(pb)
            let c = try ControlClipboard.put(text("agent text"))
            XCTAssertEqual(pb.string(forType: .string), "agent text")
            c.undo?()
            XCTAssertEqual(pb.pasteboardItems?.count ?? 0, 0)
        }
    }

    /// Empty, over the cap, or holding a control or hidden character: refused whole, the clipboard untouched.
    func testRefusalsLeaveTheClipboardUntouched() throws {
        try withScratch { pb in
            fill(pb)
            let count = pb.changeCount
            let hidden = "text has a control or hidden character: only line breaks (LF) and tabs are allowed"
            refused([:], "argument 'text' is empty")
            refused(text(""), "argument 'text' is empty")
            refused(["text": .number(1)], "argument 'text' is empty")
            refused(text(String(repeating: "a", count: ControlClipboard.maxBytes + 1)),
                    "text is longer than \(ControlClipboard.maxBytes) bytes")
            // The cap counts UTF-8 bytes, not characters: 2-byte é over the cap by one byte.
            refused(text(String(repeating: "\u{E9}", count: ControlClipboard.maxBytes / 2) + "a"),
                    "text is longer than \(ControlClipboard.maxBytes) bytes")
            for bad in ["a\rb", "a\u{1B}[31mb", "a\u{7F}", "a\u{85}b", "a\u{202E}b", "a\u{200B}b", "a\u{0}b"] {
                refused(text(bad), hidden)
            }
            XCTAssertEqual(pb.changeCount, count)
            XCTAssertEqual(pb.string(forType: .string), "the person's copy")
            // At the cap exactly: written.
            let atCap = String(repeating: "a", count: ControlClipboard.maxBytes)
            _ = try ControlClipboard.put(text(atCap))
            XCTAssertEqual(pb.string(forType: .string)?.utf8.count, ControlClipboard.maxBytes)
        }
    }

    /// Through the registry: the change shows the notice with Undo and one log line; the notice's Undo restores.
    func testThroughTheRegistryTheNoticeUndoRestores() async throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.clip.\(UUID().uuidString)"))
        let saved = (ControlClipboard.pasteboard, ControlClipboard.access)
        defer {
            (ControlClipboard.pasteboard, ControlClipboard.access) = saved
            pb.releaseGlobally()
        }
        ControlClipboard.pasteboard = { pb }
        ControlClipboard.access = { .allowed }
        Preferences.defaults.removeObject(forKey: Preferences.agentControlKey)
        var r = ControlRegistry()
        ControlRegistry.registerClipboard(&r)
        let changes = ControlChanges()
        var shown: [(String, (@MainActor () -> Void)?)] = []
        changes.present = { text, undo in shown.append((text, undo)) }
        r.changes = changes
        fill(pb)
        let before = Pasteboard.save(pb, access: .allowed)
        let reply = await r.reply(to: Data(#"{"cmd":"clipboard.put","args":{"text":"from the agent"}}"#.utf8))
        XCTAssertEqual(reply, ControlReply(ok: true, result: .bool(true), error: nil))
        XCTAssertEqual(pb.string(forType: .string), "from the agent")
        XCTAssertEqual(shown.map(\.0), ["Agent copied to the clipboard: from the agent"])
        XCTAssertEqual(changes.entries.count, 1)
        XCTAssertEqual(changes.entries.last?.undoable, true)
        shown.last?.1?()
        XCTAssertEqual(Pasteboard.save(pb, access: .allowed), before)
        XCTAssertEqual(changes.entries.last?.undone, true)
    }

    /// Registered as a change; reading the clipboard or its history is never a command (human-only).
    func testRegistrationHasNoClipboardRead() {
        var r = ControlRegistry()
        ControlRegistry.registerClipboard(&r)
        XCTAssertEqual(Set(r.commands.keys), ["clipboard.put"])
        XCTAssertEqual(r.commands["clipboard.put"]?.mutates, true)
        XCTAssertEqual(r.commands["clipboard.put"]?.args["text"]?.required, true)
        let clipboardCommands = ControlRegistry.standard().commands.keys.filter { $0.lowercased().contains("clipboard") }
        XCTAssertTrue(Set(clipboardCommands).isSubset(of: ["clipboard.put"]), "\(clipboardCommands.sorted())")
    }
}
