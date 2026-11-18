import AppKit
import XCTest
@testable import ProsperApp

/// #1545 (#1108 P3e, design #1105 D12): a change on disk while the built-in editor is dirty. Offscreen, on
/// TextViewerEditorRig: windows from the build seam, never shown; fake files in a tempDir(); the watcher's fire is the
/// registry's `changed` seam; the overwrite question is the model's seam (no sheet); dirty goes to the rig's own registry.
@MainActor
final class TextViewerDiskChangeTests: XCTestCase {

    /// Opens `text`, types "x" at the start, then writes `theirs` and fires the watcher seam; waits for that load.
    private func dirtyThenChanged(_ rig: TextViewerEditorRig, _ label: String, theirs: String = "theirs\n")
        async throws -> (URL, TextViewerModel) {
        let url = try viewerFile(label, "mine\n")
        let model = try rig.edit(url)
        try rig.type(model, "x")
        try Data(theirs.utf8).write(to: url)
        XCTAssertTrue(rig.windows.changed(model))
        await model.job?.value
        XCTAssertEqual(model.document?.text, theirs)
        return (url, model)
    }

    /// D12, dirty: the banner "Changed on disk"; the buffer, the editor and dirty stay.
    func testDirtyChangeOnDiskShowsTheBanner() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let (_, model) = try await dirtyThenChanged(rig, "tvd-banner")
        XCTAssertEqual(model.diskChange, .changed)
        XCTAssertEqual(TextViewerEditor.banner(.changed), "Changed on disk")
        XCTAssertEqual(model.buffer, "xmine\n")
        XCTAssertEqual(model.editorView?.string, "xmine\n")
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(rig.dirty.isDirty)
    }

    /// D12 Reload: the disk's text replaces the buffer and the editor, the edits are gone, the window reports clean.
    func testReloadDropsTheEditsAndReportsClean() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let (url, model) = try await dirtyThenChanged(rig, "tvd-reload")
        model.reloadFromDisk()
        XCTAssertEqual(model.buffer, "theirs\n")
        XCTAssertEqual(model.editorView?.string, "theirs\n")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(rig.dirty.isDirty, "reported clean")
        XCTAssertTrue(model.diskChange == nil)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n", "nothing written")
        // Clean on the disk's bytes: a save now has nothing to do, and a later edit saves over them without a question.
        try rig.type(model, "y")
        var asked = 0
        model.askToOverwrite = { _, _, answer in asked += 1; answer(false) }
        model.save()
        await model.saving?.value
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "ytheirs\n")
    }

    /// D12 Keep Mine: the banner goes, the buffer stays dirty; the next save asks "Overwrite the newer file on disk?" and,
    /// answered yes, writes the buffer over the disk's version and goes clean.
    func testKeepMineThenSaveWritesTheBuffer() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let (url, model) = try await dirtyThenChanged(rig, "tvd-keep")
        model.keepMine()
        XCTAssertTrue(model.diskChange == nil, "the banner goes")
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(rig.dirty.isDirty)
        var asked: [String] = []
        model.askToOverwrite = { _, name, answer in asked.append(name); answer(true) }
        var saved: [Bool] = []
        model.save { saved.append($0) }
        await model.saving?.value
        XCTAssertEqual(asked, ["notes.txt"], "asked once")
        XCTAssertEqual(saved, [true])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "xmine\n")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(rig.dirty.isDirty, "reported clean")
        XCTAssertTrue(model.saveError == nil)
    }

    /// Keep Mine, then the question answered no: nothing written, still dirty. A newer write on disk after Keep Mine is
    /// still refused (the kept hash is the version seen, not "any").
    func testKeepMineDeclinedOrOvertakenWritesNothing() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let (url, model) = try await dirtyThenChanged(rig, "tvd-keep-no")
        model.keepMine()
        model.askToOverwrite = { _, _, answer in answer(false) }
        var saved: [Bool] = []
        model.save { saved.append($0) }
        await model.saving?.value
        XCTAssertEqual(saved, [false])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n", "declined: nothing written")
        XCTAssertTrue(model.isDirty)

        try Data("third\n".utf8).write(to: url)   // no reload: the save itself must see it
        model.askToOverwrite = { _, _, answer in answer(true) }
        model.save { saved.append($0) }
        await model.saving?.value
        XCTAssertEqual(saved, [false, false])
        XCTAssertEqual(model.saveError, TextViewerEditor.message(.changedOnDisk))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "third\n", "the newer write is kept")
        XCTAssertTrue(rig.dirty.isDirty)
    }

    /// D12 Deleted: the banner "Deleted on disk", no Reload; the content stays; Save writes the file anew and goes clean.
    func testDeletedOnDiskShowsTheBannerAndSaveCreatesTheFile() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tvd-deleted", "mine\n")
        let model = try rig.edit(url)
        try rig.type(model, "x")
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(rig.windows.changed(model))
        await model.job?.value
        XCTAssertTrue(model.state == .failure(.missing))
        XCTAssertEqual(model.diskChange, .deleted)
        XCTAssertEqual(TextViewerEditor.banner(.deleted), "Deleted on disk")
        XCTAssertEqual(model.editorView?.string, "xmine\n", "the content stays")
        model.reloadFromDisk()   // no Reload for a deleted file: nothing happens
        XCTAssertEqual(model.buffer, "xmine\n")
        XCTAssertTrue(model.isDirty)
        var asked = 0
        model.askToOverwrite = { _, _, answer in asked += 1; answer(false) }
        var saved: [Bool] = []
        model.save { saved.append($0) }
        await model.saving?.value
        XCTAssertEqual(saved, [true])
        XCTAssertEqual(asked, 0, "nothing to overwrite: no question")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "xmine\n", "written anew")
        XCTAssertTrue(model.diskChange == nil)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(rig.dirty.isDirty)
    }

    /// D12, not dirty: no banner; the existing reload takes the new text.
    func testNoBannerWhileClean() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tvd-clean", "mine\n")
        let model = try rig.edit(url)
        try Data("theirs\n".utf8).write(to: url)
        XCTAssertTrue(rig.windows.changed(model))
        await model.job?.value
        XCTAssertEqual(model.editorView?.string, "theirs\n")
        XCTAssertTrue(model.diskChange == nil)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(rig.dirty.isDirty)
    }

    /// A reload of the unchanged file while dirty (Read renders the preview) asks nothing.
    func testUnchangedDiskWhileDirtyHasNoBanner() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let model = try rig.edit(viewerFile("tvd-same", "mine\n"))
        try rig.type(model, "x")
        model.showRead()
        await model.job?.value
        XCTAssertTrue(model.diskChange == nil)
        XCTAssertTrue(model.isDirty)
    }

    /// Undoing back to the loaded text while the banner is up: clean, so D12's clean case takes the disk's text.
    func testUndoingBackToCleanTakesTheDiskText() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let (_, model) = try await dirtyThenChanged(rig, "tvd-undo")
        XCTAssertEqual(model.diskChange, .changed)
        let undo = try XCTUnwrap(model.editorView?.undoManager)
        undo.undo()
        XCTAssertFalse(model.isDirty)
        await model.job?.value
        XCTAssertEqual(model.editorView?.string, "theirs\n")
        XCTAssertTrue(model.diskChange == nil)
        XCTAssertFalse(rig.dirty.isDirty)
    }
}
