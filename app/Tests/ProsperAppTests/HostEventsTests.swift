import AppKit
import XCTest
@testable import ProsperApp

/// Host events added in #040: `screen.locked`, `clipboard.changed`, and the
/// `host.clipboard.write("")` clear.
final class HostEventsTests: XCTestCase {

    // MARK: screen.locked

    @MainActor
    func testScreenLockedPayloadCarriesBothEdges() {
        let w = SystemEventWatchers()
        var emitted: [(String, String)] = []
        w.emit = { emitted.append(($0, $1)) }

        w.emitScreenLocked(true)
        w.emitScreenLocked(false)

        XCTAssertEqual(emitted.map(\.0), ["screen.locked", "screen.locked"])
        XCTAssertEqual(Self.boolField("locked", emitted[0].1), true)
        XCTAssertEqual(Self.boolField("locked", emitted[1].1), false)
    }

    // MARK: clipboard.changed

    /// One event per pasteboard changeCount — a poll that sees no delta is silent,
    /// which is what stops the 0.6 s timer from re-announcing the same clip forever.
    @MainActor
    func testClipboardChangedEmitsOncePerChangeCount() {
        let pb = Self.scratchPasteboard()
        let monitor = ClipboardMonitor()
        monitor.captureHistory = false          // event-only mode: no history writes

        pb.clearContents()
        pb.setString("one", forType: .string)
        monitor.poll(pb)                        // priming poll syncs the change count

        var payloads: [String] = []
        monitor.emitChange = { payloads.append($0) }

        pb.clearContents()
        pb.setString("two", forType: .string)
        monitor.poll(pb)
        monitor.poll(pb)                        // no delta → no second event
        monitor.poll(pb)

        XCTAssertEqual(payloads.count, 1)
        let obj = Self.json(payloads[0])
        XCTAssertEqual(obj?["kind"] as? String, "text")
        XCTAssertEqual(obj?["text"] as? String, "two")
    }

    /// A host-originated write is announced to nobody: without this an extension
    /// that rewrites the clipboard in its own handler loops forever.
    @MainActor
    func testSuppressNextChangeDropsExactlyOneEvent() {
        let pb = Self.scratchPasteboard()
        let monitor = ClipboardMonitor()
        monitor.captureHistory = false

        pb.clearContents()
        pb.setString("seed", forType: .string)
        monitor.poll(pb)

        var payloads: [String] = []
        monitor.emitChange = { payloads.append($0) }

        monitor.suppressNextChange()
        pb.clearContents()
        pb.setString("written by the host", forType: .string)
        monitor.poll(pb)
        XCTAssertTrue(payloads.isEmpty, "host-originated write must not re-fire clipboard.changed")

        // Suppression is one-shot: the NEXT user copy is announced again.
        pb.clearContents()
        pb.setString("copied by the user", forType: .string)
        monitor.poll(pb)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(Self.json(payloads[0])?["text"] as? String, "copied by the user")
    }

    @MainActor
    func testClipboardChangedGateSkipsEmitWhenNothingSubscribes() {
        let pb = Self.scratchPasteboard()
        let monitor = ClipboardMonitor()
        monitor.captureHistory = false
        pb.clearContents()
        pb.setString("seed", forType: .string)
        monitor.poll(pb)

        var payloads: [String] = []
        monitor.emitChange = { payloads.append($0) }
        monitor.shouldEmitChange = { false }

        pb.clearContents()
        pb.setString("nobody is listening", forType: .string)
        monitor.poll(pb)

        XCTAssertTrue(payloads.isEmpty)
    }

    /// The payload crosses a JSON boundary into Lua — a 40 MB paste must not.
    @MainActor
    func testChangePayloadCapsTextAtEightKilobytes() {
        let long = String(repeating: "é", count: 20_000)   // 2 bytes per char
        let payload = ClipboardMonitor.changePayload(kind: "text", text: long)
        let text = Self.json(payload)?["text"] as? String
        XCTAssertNotNil(text)
        XCTAssertLessThanOrEqual(text!.utf8.count, 8 * 1024)
        XCTAssertEqual(text, String(repeating: "é", count: 4096), "must cut on a character boundary")

        // Non-text kinds carry no text at all.
        XCTAssertNil(Self.json(ClipboardMonitor.changePayload(kind: "image", text: nil))?["text"])
        XCTAssertEqual(Self.json(ClipboardMonitor.changePayload(kind: "image", text: nil))?["kind"] as? String,
                       "image")
    }

    // MARK: host.clipboard.write("")

    /// `write("")` is a CLEAR — `setString("")` would leave an empty-string item on
    /// the pasteboard, which pastes as nothing but still reads back as a string.
    @MainActor
    func testClipboardWriteEmptyStringClearsPasteboard() {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        defer {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }

        let services = LiveExtensionHostServices.shared
        services.clipboardWrite("hello")
        XCTAssertEqual(pb.string(forType: .string), "hello")

        services.clipboardWrite("")
        XCTAssertNil(pb.string(forType: .string), "write(\"\") must leave the pasteboard empty")
    }

    // MARK: helpers

    private static func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.prosper.tests.clipboard"))
    }

    private static func json(_ s: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
    }

    private static func boolField(_ key: String, _ s: String) -> Bool? {
        json(s)?[key] as? Bool
    }
}
