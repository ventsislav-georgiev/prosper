import AppKit
import XCTest
@testable import ProsperApp

/// #1692: a suppress armed while access was denied must not swallow the user's next copy once access returns.
@MainActor final class ClipboardMonitorSuppressTests: XCTestCase {
    private final class Box { var access = ClipboardAccess.allowed; var payloads: [String] = [] }

    func testSuppressArmedWhileDeniedDoesNotSkipTheNextCopyAfterAccessReturns() {
        let box = Box()
        let m = ClipboardMonitor(workspaceCenter: NotificationCenter(), distributedCenter: NotificationCenter())
        m.captureHistory = false
        m.access = { box.access }
        m.emitChange = { box.payloads.append($0) }
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        box.access = .denied
        pb.clearContents(); pb.setString("example paste", forType: .string)
        m.suppressNextChange()
        m.poll(pb)
        XCTAssertTrue(box.payloads.isEmpty, "denied: nothing read")

        box.access = .allowed
        pb.clearContents(); pb.setString("example user copy", forType: .string)
        m.poll(pb)
        XCTAssertEqual(box.payloads.count, 1, "the user's copy after access returns is captured")
    }
}
