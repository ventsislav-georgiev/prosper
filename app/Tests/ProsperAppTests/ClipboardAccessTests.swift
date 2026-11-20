import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #210: macOS's per-app paste setting, mapped and shown in the Clipboard settings section.
/// Offscreen only: windows are never ordered front or made key, nothing is clicked, and the
/// real pasteboard is never read (`Pasteboard.access()` is `.unknown` under XCTest; the
/// section gets a fake reader).
@MainActor
final class ClipboardAccessTests: XCTestCase {
    private final class Reader {
        var count = 0
        var value = ClipboardAccess.unknown
    }

    /// #1292: the return-to-Prosper notification is read from this private center, so posting it
    /// reaches only the section under test (not the real center's observers).
    private let activation = NotificationCenter()

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private func flush(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        v.layoutSubtreeIfNeeded()
    }

    /// The section in a window that is never shown; returns the host after `onAppear` ran.
    private func host(_ reader: Reader) -> NSHostingView<ClipboardSettingsSection> {
        let host = NSHostingView(rootView: ClipboardSettingsSection(model: SettingsModel(), readAccess: {
            reader.count += 1
            return reader.value
        }, activationCenter: activation))
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 600)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = host
        windows.append(w)
        flush(host)
        return host
    }

    func testEveryBehaviourMapsExplicitly() throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("NSPasteboard.accessBehavior is macOS 15.4+") }
        XCTAssertEqual(ClipboardAccess(.alwaysAllow), .allowed)
        XCTAssertEqual(ClipboardAccess(.ask), .asks)
        XCTAssertEqual(ClipboardAccess(.alwaysDeny), .denied)
        XCTAssertEqual(ClipboardAccess(.default), .systemDefault)
        // A behaviour a later macOS adds is neither allowed nor denied.
        let future = try XCTUnwrap(NSPasteboard.AccessBehavior(rawValue: 99))
        XCTAssertEqual(ClipboardAccess(future), .unknown)
    }

    func testTheLiveReadNeverRunsUnderXCTest() {
        XCTAssertEqual(Pasteboard.access(), .unknown)
    }

    func testOnlyDeniedWarns() {
        XCTAssertTrue(ClipboardAccess.denied.warns)
        XCTAssertFalse(ClipboardAccess.asks.warns)
        XCTAssertFalse(ClipboardAccess.allowed.warns)
        XCTAssertFalse(ClipboardAccess.systemDefault.warns)
        XCTAssertFalse(ClipboardAccess.unknown.warns)
    }

    func testSettingsNoteForEachState() throws {
        let denied = try XCTUnwrap(ClipboardAccess.denied.settingsNote)
        XCTAssertTrue(denied.contains("can't see what other apps copy"), denied)
        XCTAssertTrue(denied.contains("Privacy & Security › Paste from Other Apps"), denied)
        let asks = try XCTUnwrap(ClipboardAccess.asks.settingsNote)
        XCTAssertTrue(asks.contains("Clipboard history waits until Prosper is allowed"), asks)
        XCTAssertTrue(asks.contains("Paste from Other Apps"), asks)
        for quiet in [ClipboardAccess.allowed, .systemDefault, .unknown] {
            XCTAssertTrue(quiet.settingsNote == nil, "\(quiet) shows nothing")
        }
        XCTAssertEqual(ClipboardAccess.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }

    /// The line is in the section only for denied and asks; the quiet states leave the section
    /// exactly as tall as before (no empty child adding the stack's spacing).
    func testSectionShowsTheLineOnlyWhenDeniedOrAsks() {
        func height(_ state: ClipboardAccess) -> CGFloat {
            let reader = Reader()
            reader.value = state
            return host(reader).fittingSize.height
        }
        let allowed = height(.allowed)
        XCTAssertGreaterThan(allowed, 0)
        XCTAssertEqual(height(.systemDefault), allowed)
        XCTAssertEqual(height(.unknown), allowed)
        let asks = height(.asks), denied = height(.denied)
        XCTAssertGreaterThan(asks, allowed, "asks adds its line")
        XCTAssertGreaterThan(denied, allowed, "denied adds its warning")
        // The warning row (title + message beside an icon) is taller than the one quiet line;
        // swapping which state warns makes asks the taller one.
        XCTAssertGreaterThan(denied, asks, "denied is the warning row, asks the quiet line")
    }

    /// Re-read when the section appears and each time Prosper becomes active (the user changes the
    /// setting in System Settings and comes back); nothing re-reads on its own.
    func testReReadOnAppearAndOnBecomingActive() {
        let reader = Reader()
        reader.value = .allowed
        let view = self.host(reader)
        let allowed = view.fittingSize.height
        XCTAssertGreaterThanOrEqual(reader.count, 1, "read on appear")
        let afterAppear = reader.count
        flush(view)
        XCTAssertEqual(reader.count, afterAppear, "no re-read without a trigger")

        reader.value = .denied
        activation.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        flush(view)
        XCTAssertEqual(reader.count, afterAppear + 1, "re-read on becoming active")
        XCTAssertGreaterThan(view.fittingSize.height, allowed, "the new state is shown")
    }

    /// #1292: both lines (denied and asks) open the one URL through the one helper.
    func testOpenSettingsOpensTheSettingsURL() {
        var opened: [URL] = []
        ClipboardAccess.openSettings(using: { opened.append($0); return true })
        XCTAssertEqual(opened, [ClipboardAccess.settingsURL])
    }

    /// #1292: the asks line is a button, like the denied row; allowed shows neither. Read from the AX
    /// tree of a view that is never shown, with a denied control so a tree that shows no buttons at all fails here.
    func testAsksLineIsAButtonLikeTheDeniedRow() {
        func buttons(_ state: ClipboardAccess) -> [String] {
            let reader = Reader()
            reader.value = state
            let restore = AXTreeSupport.axOn()
            defer { restore() }
            let (win, view) = AXTreeSupport.hosted(ClipboardSettingsSection(model: SettingsModel(), readAccess: { reader.value },
                                                                            activationCenter: activation), CGSize(width: 520, height: 600))
            defer { win.close() }
            let want = state == .allowed ? "" : (state == .denied ? "macOS blocks clipboard reading" : "Clipboard history waits until Prosper is allowed")
            let tree = AXTreeSupport.poll(view) { t in
                want.isEmpty || t.contains { $0.role == "AXButton" && $0.names.contains { $0.contains(want) } }
            }
            XCTAssertFalse(win.isVisible, "never shown")
            return tree.filter { $0.role == "AXButton" }.flatMap(\.names)
        }
        XCTAssertTrue(buttons(.denied).contains { $0.contains("macOS blocks clipboard reading") }, "control: the denied row is a button")
        XCTAssertTrue(buttons(.asks).contains { $0.contains("Clipboard history waits until Prosper is allowed") }, "the asks line is a button")
        XCTAssertFalse(buttons(.allowed).contains { $0.contains("Clipboard history waits until Prosper is allowed") || $0.contains("macOS blocks") })
    }
}
