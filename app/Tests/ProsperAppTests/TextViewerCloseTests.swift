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

    // MARK: #1544: a window's close while dirty (the sheet seam; no NSAlert, no sheet)

    /// The sheet's calls (the shown name each time); each answers what the row set.
    private func ask(_ model: TextViewerModel, _ answer: TextViewerEditor.CloseAnswer, into asked: @escaping @MainActor (String) -> Void) {
        model.askToClose = { _, name, reply in
            asked(name)
            reply(answer)
        }
    }

    /// D11: a dirty close (the close button and ⌘W both call performClose) asks the sheet seam; Cancel keeps the window,
    /// the buffer and the dirty report.
    func testDirtyCloseAsksAndCancelKeepsTheWindow() throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let model = try rig.edit(viewerFile("tvc-cancel", "a\n"))
        try rig.type(model, "x")
        var asked: [String] = []
        ask(model, .cancel) { asked.append($0) }
        let win = try XCTUnwrap(rig.windows.entries.last?.window)
        win.performClose(nil)
        XCTAssertEqual(asked, ["notes.txt"], "asked once, with the name")
        XCTAssertEqual(rig.windows.entries.count, 1, "Cancel keeps the window")
        XCTAssertTrue(model.isDirty && rig.dirty.isDirty)
        XCTAssertEqual(model.buffer, "xa\n")
    }

    /// Don't Save drops the edits, reports clean before the window goes, and writes nothing.
    func testDontSaveClosesAndReportsClean() throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tvc-discard", "a\n")
        let model = try rig.edit(url)
        try rig.type(model, "x")
        var asked: [String] = []
        ask(model, .discard) { asked.append($0) }
        try XCTUnwrap(rig.windows.entries.last?.window).performClose(nil)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(rig.windows.entries.isEmpty, "closed")
        XCTAssertFalse(rig.dirty.isDirty, "reported clean")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\n", "nothing written")
    }

    /// Save from the sheet writes the buffer, then closes; a failed save keeps the window open and dirty.
    func testSaveFromTheSheetWritesThenCloses() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tvc-save", "a\n")
        let model = try rig.edit(url)
        try rig.type(model, "x")
        ask(model, .save) { _ in }
        try XCTUnwrap(rig.windows.entries.last?.window).performClose(nil)
        await model.saving?.value
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "xa\n")
        XCTAssertTrue(rig.windows.entries.isEmpty, "closed after the save")
        XCTAssertFalse(rig.dirty.isDirty)
    }

    func testFailedSaveFromTheSheetKeepsTheWindow() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tvc-save-fail", "a\n")
        let model = try rig.edit(url)
        try rig.type(model, "x")
        try Data("other\n".utf8).write(to: url)
        ask(model, .save) { _ in }
        try XCTUnwrap(rig.windows.entries.last?.window).performClose(nil)
        await model.saving?.value
        XCTAssertEqual(rig.windows.entries.count, 1, "not closed")
        XCTAssertTrue(model.isDirty && rig.dirty.isDirty)
        XCTAssertNotNil(model.saveError)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "other\n")
    }

    /// A clean close asks nothing.
    func testCleanCloseAsksNothing() throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let model = try rig.edit(viewerFile("tvc-clean", "a\n"))
        var asked = 0, closed = 0
        ask(model, .cancel) { _ in asked += 1 }
        model.closeRequested(nil) { closed += 1 }
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(closed, 1)
    }

    /// The live sheet shows nothing under XCTest and answers Cancel.
    func testLiveCloseSheetCancelsUnderXCTest() {
        var got: [TextViewerEditor.CloseAnswer] = []
        TextViewerEditor.liveCloseSheet(nil, "a.txt") { got.append($0) }
        XCTAssertEqual(got, [.cancel])
    }

    /// P3 with P3c: Quit while a window is dirty answers .terminateLater and Cancel cancels; an update waits, the window
    /// says so once, and Save releases it exactly once.
    func testDirtyWindowHoldsQuitAndTheUpdate() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let model = try rig.edit(viewerFile("tvc-quit", "a\n"))
        try rig.type(model, "x")
        var answer: (@MainActor (Bool) -> Void)?
        rig.dirty.prompt = { _, a in answer = a }
        var replies: [Bool] = []
        XCTAssertEqual(rig.dirty.terminateReply(endSessions: {}, reply: { replies.append($0) }), .terminateLater)
        answer?(false)
        XCTAssertEqual(replies, [false], "Cancel → .terminateCancel")
        var installs = 0
        rig.dirty.holdUpdate { installs += 1 }
        XCTAssertEqual(installs, 0, "held while dirty")
        XCTAssertEqual(model.notice, TextViewerDirty.updateWaiting)
        model.save()
        await model.saving?.value
        XCTAssertEqual(installs, 1, "released once on save")
    }

    /// #1544: windows report to the shared registry, but every row hands in its own, so the app's Quit never waits on a test.
    func testNoRowReportsToTheSharedRegistry() {
        XCTAssertFalse(TextViewerDirty.shared.isDirty)
    }
}
