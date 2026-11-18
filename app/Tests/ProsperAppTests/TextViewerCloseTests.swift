import AppKit
import XCTest
@testable import ProsperApp

/// #1108 P3c (design #1105 P3, rider R6): Quit waits on unsaved Text Viewer files. Each row uses its own
/// TextViewerDirty with a fake prompt: no alert is shown, nothing terminates, no session is really ended.
@MainActor
final class TextViewerCloseTests: XCTestCase {

    /// The prompt's calls (the dirty count each time) and its answers, held until the row gives them.
    @MainActor
    private final class Rig {
        let dirty = TextViewerDirty()
        var prompted: [Int] = []
        var answer: (@MainActor (Bool) -> Void)?
        var replies: [Bool] = []
        var ends = 0

        init() {
            dirty.prompt = { [unowned self] count, answer in
                prompted.append(count)
                self.answer = answer
            }
        }

        func terminate() -> NSApplication.TerminateReply {
            dirty.terminateReply(endSessions: { [unowned self] in ends += 1 }) { [unowned self] in replies.append($0) }
        }
    }

    /// R6: nothing dirty → `.terminateNow` at once, no prompt; the edit sessions end (Quit, Restart and update unchanged).
    func testTerminateIsNowWhenNothingIsDirty() {
        let rig = Rig()
        XCTAssertEqual(rig.terminate(), .terminateNow)
        XCTAssertEqual(rig.prompted, [])
        XCTAssertEqual(rig.replies, [], "no later reply for a terminateNow")
        XCTAssertEqual(rig.ends, 1)
    }

    func testTerminateWhileDirtyIsLaterThenCancelOnCancel() {
        let rig = Rig(), a = NSObject(), b = NSObject()
        rig.dirty.report(a, dirty: true)
        rig.dirty.report(b, dirty: true)
        XCTAssertEqual(rig.terminate(), .terminateLater)
        XCTAssertEqual(rig.prompted, [2], "asked once, with the count")
        XCTAssertEqual(rig.replies, [], "no reply before the answer")
        rig.answer?(false)
        XCTAssertEqual(rig.replies, [false], "Cancel → .terminateCancel")
        XCTAssertEqual(rig.ends, 0, "a cancelled quit ends no edit session")
    }

    func testQuitWithoutSavingRepliesTerminateAndEndsTheSessions() {
        let rig = Rig(), a = NSObject()
        rig.dirty.report(a, dirty: true)
        XCTAssertEqual(rig.terminate(), .terminateLater)
        XCTAssertEqual(rig.ends, 0)
        rig.answer?(true)
        XCTAssertEqual(rig.replies, [true])
        XCTAssertEqual(rig.ends, 1)
    }

    /// A viewer that went clean again holds nothing; reporting clean twice, or an unknown viewer clean, changes nothing.
    func testCleanAgainTerminatesNow() {
        let rig = Rig(), a = NSObject(), b = NSObject()
        rig.dirty.report(a, dirty: true)
        rig.dirty.report(a, dirty: true)
        rig.dirty.report(b, dirty: false)
        XCTAssertTrue(rig.dirty.isDirty)
        rig.dirty.report(a, dirty: false)
        rig.dirty.report(a, dirty: false)
        XCTAssertFalse(rig.dirty.isDirty)
        XCTAssertEqual(rig.terminate(), .terminateNow)
        XCTAssertEqual(rig.prompted, [])
    }

    /// The live prompt shows nothing under XCTest: it cancels.
    func testLivePromptCancelsUnderXCTest() {
        var got: [Bool] = []
        TextViewerDirty.livePrompt(1) { got.append($0) }
        XCTAssertEqual(got, [false])
    }

    /// Until P3d (#1544) no viewer reports, so the app's Quit never waits.
    func testNothingReportsToTheSharedRegistryYet() {
        XCTAssertFalse(TextViewerDirty.shared.isDirty)
    }
}
