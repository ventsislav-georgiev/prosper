import AppKit
import Sparkle
import XCTest
@testable import ProsperApp

/// #1108 P3c (design #1105 P3, rider R6): an unattended update waits on unsaved Text Viewer files. Only the
/// driver's `showReady` is fed, with its own TextViewerDirty: no SPUUpdater exists under XCTest, nothing installs.
@MainActor
final class AppUpdaterHoldTests: XCTestCase {

    private func driver(_ dirty: TextViewerDirty) -> SilentUserDriver {
        let d = SilentUserDriver()
        d.dirtyViewers = dirty
        return d
    }

    /// R6: nothing dirty → `.install` at once, as before.
    func testShowReadyInstallsAtOnceWhenClean() {
        let d = driver(TextViewerDirty())
        var replies: [SPUUserUpdateChoice] = []
        d.showReady { replies.append($0) }
        XCTAssertEqual(replies, [.install])
    }

    func testShowReadyHoldsWhileDirtyAndInstallsOnceWhenClean() {
        let dirty = TextViewerDirty(), a = NSObject(), b = NSObject()
        let d = driver(dirty)
        dirty.report(a, dirty: true)
        dirty.report(b, dirty: true)
        var replies: [SPUUserUpdateChoice] = []
        d.showReady { replies.append($0) }
        XCTAssertEqual(replies, [], "held while a file is dirty")
        dirty.report(a, dirty: false)
        XCTAssertEqual(replies, [], "still held: b is dirty")
        dirty.report(b, dirty: false)
        XCTAssertEqual(replies, [.install], "replied when clean")
        dirty.report(b, dirty: false)
        dirty.report(a, dirty: true)
        dirty.report(a, dirty: false)
        XCTAssertEqual(replies, [.install], "exactly once")
    }

    /// R6: the dirty windows say so once while the update waits; a window dirty later says it when it goes dirty.
    func testHeldUpdateIsSaidOncePerDirtyWindow() {
        let dirty = TextViewerDirty(), a = NSObject(), c = NSObject()
        let d = driver(dirty)
        var saidA: [String] = [], saidC: [String] = []
        dirty.report(a, dirty: true, say: { saidA.append($0) })
        XCTAssertEqual(saidA, [], "nothing to say before an update waits")
        var replies: [SPUUserUpdateChoice] = []
        d.showReady { replies.append($0) }
        d.showReady { replies.append($0) }
        XCTAssertEqual(saidA, [TextViewerDirty.updateWaiting], "said once")
        dirty.report(a, dirty: true, say: { saidA.append($0) })
        XCTAssertEqual(saidA.count, 1, "an already dirty window is not told again")
        dirty.report(c, dirty: true, say: { saidC.append($0) })
        XCTAssertEqual(saidC, [TextViewerDirty.updateWaiting])
        dirty.report(a, dirty: false)
        dirty.report(c, dirty: false)
        XCTAssertEqual(replies, [.install, .install], "each held reply answered once")
    }
}
