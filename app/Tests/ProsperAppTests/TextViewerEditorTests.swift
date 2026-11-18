import AppKit
import XCTest
@testable import ProsperApp

/// #1544 (#1108 P3d, design #1105 D11): one window's built-in editor, offscreen. Windows come from the build seam and
/// are never shown, ordered or made key; the editor's view sits in its own window's Edit pane, as in the app (that
/// window's undo manager keeps its history); typing is insertText on the view, no event is posted; files are fakes in a tempDir();
/// dirty goes to the rig's own TextViewerDirty, never the app's; the close sheet is the model's seam.
@MainActor
final class TextViewerEditorRig {
    let windows = TextViewerWindows()
    let dirty = TextViewerDirty()

    init() {
        windows.build = { TextViewerWindows.makeWindow($0, autosave: nil) }
        windows.present = { _ in }
        windows.dismissed = { _ in }
        windows.actions = {
            TextViewerActions(defaultApp: { _ in nil }, openWith: { _, _ in }, reveal: { _ in }, openURL: { _ in }, view: { _ in })
        }
        windows.imageLoader = { _, _, _ in nil }
        windows.isRemote = { _ in false }
        var builtin = TerminalEditorSeams.current
        builtin.settings = { TerminalEditor.Settings(terminal: false, command: "") }
        windows.editorSeams = { builtin }
        windows.dirty = { [dirty] in dirty }
    }

    static func waitUntil(_ what: String, _ done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done(), "not within 5 s: \(what)", file: file, line: line)
    }

    /// The same wait for an async row. Its body runs as a main-queue job, and a run loop spun inside one does not drain
    /// the main queue, so a main-actor hop or a DispatchQueue.main block never ran there: this one suspends between checks.
    static func waitUntilAsync(_ what: String, _ done: () -> Bool, file: StaticString = #filePath,
                               line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(done(), "not within 5 s: \(what)", file: file, line: line)
    }

    /// Opens `url`, waits for its first load, enters Edit and waits for the window's Edit pane to hold the editor.
    func edit(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> TextViewerModel {
        windows.open(url)
        let model = try XCTUnwrap(windows.entries.last?.model, file: file, line: line)
        Self.waitUntil("loaded", { model.state != nil }, file: file, line: line)
        let mounted = try enter(model, file: file, line: line)
        Self.waitUntil("the Edit pane", mounted, file: file, line: line)
        return model
    }

    /// `edit` for an async row (see waitUntilAsync).
    func editAsync(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws -> TextViewerModel {
        windows.open(url)
        let model = try XCTUnwrap(windows.entries.last?.model, file: file, line: line)
        await Self.waitUntilAsync("loaded", { model.state != nil }, file: file, line: line)
        let mounted = try enter(model, file: file, line: line)
        await Self.waitUntilAsync("the Edit pane", mounted, file: file, line: line)
        return model
    }

    /// Edit, and the check that the window's SwiftUI made the Edit pane (laid out on each check: the window is never shown).
    /// A view hosted anywhere else is taken into that pane on a later turn, and its undo history stays behind.
    private func enter(_ model: TextViewerModel, file: StaticString, line: UInt) throws -> () -> Bool {
        model.edit()
        XCTAssertEqual(model.mode, .edit, file: file, line: line)
        let window = try XCTUnwrap(windows.entries.last?.window, file: file, line: line)
        return {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.editorView?.window === window
        }
    }

    /// Types `text` at the caret, as the key path's insertText does.
    func type(_ model: TextViewerModel, _ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let view = try XCTUnwrap(model.editorView, file: file, line: line)
        view.insertText(text, replacementRange: view.selectedRange())
    }

    func closeAll() {
        for e in windows.entries { e.window.close() }
    }
}

extension XCTestCase {
    /// #1544: a fake text file in its own tempDir().
    func viewerFile(_ label: String, _ text: String, name: String = "notes.txt") throws -> URL {
        let url = tempDir(label).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}

@MainActor
final class TextViewerEditorTests: XCTestCase {

    /// D11: dirty after a typed character, reported once; undoing back to the loaded text is clean, reported too.
    func testDirtyAfterATypedCharacterCleanAfterUndoingBack() throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let model = try rig.edit(viewerFile("tve-dirty", "one\n"))
        XCTAssertFalse(model.isDirty, "Edit alone is clean")
        XCTAssertFalse(rig.dirty.isDirty)
        try rig.type(model, "x")
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.buffer, "xone\n")
        XCTAssertTrue(rig.dirty.isDirty, "reported to the registry")
        XCTAssertFalse(TextViewerDirty.shared.isDirty, "never the app's")
        let undo = try XCTUnwrap(model.editorView?.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(model.editorView?.string, "one\n")
        XCTAssertFalse(model.isDirty, "back to the loaded text is clean")
        XCTAssertFalse(rig.dirty.isDirty)
    }

    /// D11: Read while edited renders the buffer (a live preview); the file itself is untouched, and its state stays.
    func testReadRendersTheBuffer() throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tve-preview", "on disk\n")
        let model = try rig.edit(url)
        try rig.type(model, "typed ")
        model.showRead()
        XCTAssertEqual(model.mode, .read)
        TextViewerEditorRig.waitUntil("the preview", { model.output?.text.string.contains("typed on disk") == true })
        XCTAssertEqual(model.document?.text, "on disk\n", "the file's state is the disk's")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "on disk\n", "nothing written")
        XCTAssertTrue(model.isDirty, "Read keeps the buffer")
        model.edit()
        XCTAssertEqual(model.mode, .edit)
        XCTAssertEqual(model.editorView?.string, "typed on disk\n", "the same buffer again")
    }

    /// D11: every substitution that would change the file's bytes is off; plain, editable, undo, the find bar.
    func testEverySubstitutionIsOff() {
        let (_, view) = TextViewerEditor.makeEditor("\"a\" -- b")
        XCTAssertTrue(view.isEditable)
        XCTAssertFalse(view.isRichText)
        XCTAssertTrue(view.allowsUndo)
        XCTAssertTrue(view.usesFindBar)
        XCTAssertTrue(view.isIncrementalSearchingEnabled)
        XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(view.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(view.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(view.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.smartInsertDeleteEnabled)
        XCTAssertEqual(view.string, "\"a\" -- b")
        XCTAssertEqual(view.font?.isFixedPitch, true, "monospaced")
    }

    /// D11: Save writes the buffer in the file's encoding and goes clean; the window reports clean.
    func testSaveWritesTheBufferAndGoesClean() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tve-save", "a\r\nb\r\n")
        let model = try await rig.editAsync(url)
        try rig.type(model, "z")
        var saved: [Bool] = []
        model.save { saved.append($0) }
        await model.saving?.value
        XCTAssertEqual(saved, [true])
        XCTAssertEqual(try Data(contentsOf: url), Data("za\r\nb\r\n".utf8), "CRLF kept byte for byte")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(rig.dirty.isDirty)
        XCTAssertTrue(model.saveError == nil)
    }

    /// D11 step 3: a write between load and save is refused; the window says why and the buffer stays dirty.
    func testChangedOnDiskIsNotOverwrittenAndStaysDirty() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tve-race", "mine\n")
        let model = try await rig.editAsync(url)
        try rig.type(model, "x")
        try Data("theirs\n".utf8).write(to: url)
        model.save()
        await model.saving?.value
        XCTAssertEqual(model.saveError, TextViewerEditor.message(.changedOnDisk))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs\n", "the other write is kept")
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(rig.dirty.isDirty)
        XCTAssertEqual(model.buffer, "xmine\n", "the buffer is kept")
    }

    /// #1601: opened through a symlinked folder, Save writes the real file (the load read it resolved; the save used to resolve
    /// only the last component and refused as retargeted). The folder link stays a link.
    func testSaveThroughASymlinkedFolderWritesTheRealFile() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let root = tempDir("tve-1601-folder")
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try Data("one\n".utf8).write(to: real.appendingPathComponent("notes.txt"))
        XCTAssertEqual(symlink("real", root.appendingPathComponent("linked").path), 0)
        let model = try await rig.editAsync(root.appendingPathComponent("linked/notes.txt"))
        try rig.type(model, "x")
        var saved: [Bool] = []
        model.save { saved.append($0) }
        await model.saving?.value
        XCTAssertEqual(saved, [true])
        XCTAssertTrue(model.saveError == nil, "\(model.saveError ?? "")")
        XCTAssertEqual(try String(contentsOf: real.appendingPathComponent("notes.txt"), encoding: .utf8), "xone\n")
        XCTAssertFalse(model.isDirty)
        var st = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent("linked").path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK, "the folder link is still a link")
    }

    /// #1601: opened through a link whose relative target climbs (../b/notes.txt), Save writes that target; the link stays.
    func testSaveThroughADotDotLinkWritesTheTarget() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let root = tempDir("tve-1601-dotdot")
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
        try Data("one\n".utf8).write(to: b.appendingPathComponent("notes.txt"))
        let link = a.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink("../b/notes.txt", link.path), 0)
        let model = try await rig.editAsync(link)
        try rig.type(model, "x")
        var saved: [Bool] = []
        model.save { saved.append($0) }
        await model.saving?.value
        XCTAssertEqual(saved, [true])
        XCTAssertTrue(model.saveError == nil, "\(model.saveError ?? "")")
        XCTAssertEqual(try String(contentsOf: b.appendingPathComponent("notes.txt"), encoding: .utf8), "xone\n")
        var st = stat()
        XCTAssertEqual(lstat(link.path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK, "the link is still a link")
    }

    /// #1601 keeps R1108-q3: a model that reads through its own link (resolved: the link), loaded at a.txt, the link then
    /// retargeted at b.txt: Save is refused as retargeted, both files unchanged, the buffer kept dirty.
    func testSaveThroughALinkRetargetedAfterTheLoadIsRefused() async throws {
        let root = tempDir("tve-1601-retarget")
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data("a1\n".utf8).write(to: a)
        try Data("b1\n".utf8).write(to: b)
        let link = root.appendingPathComponent("link.txt")
        XCTAssertEqual(symlink("a.txt", link.path), 0)
        let model = TextViewerModel(url: link, resolved: link, actions: TextViewerActions(
            defaultApp: { _ in nil }, openWith: { _, _ in }, reveal: { _ in }, openURL: { _ in }, view: { _ in }),
            imageLoader: { _, _, _ in nil })
        var builtin = TerminalEditorSeams.current
        builtin.settings = { TerminalEditor.Settings(terminal: false, command: "") }
        model.editor = builtin
        model.dirtyRegistry = TextViewerDirty()
        await TextViewerEditorRig.waitUntilAsync("loaded", { model.state != nil })
        model.edit()
        XCTAssertEqual(model.mode, .edit)
        model.edited("xa1\n")
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(unlink(link.path), 0)
        XCTAssertEqual(symlink("b.txt", link.path), 0)
        var saved: [Bool] = []
        model.save { saved.append($0) }
        await model.saving?.value
        XCTAssertEqual(saved, [false])
        XCTAssertEqual(model.saveError, TextViewerEditor.message(.retargeted))
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a1\n")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b1\n")
        XCTAssertTrue(model.isDirty)
    }

    /// #1601 rider: a viewer window never joins a window tab group (a tab's close would skip performClose's dirty check).
    func testViewerWindowsDisallowTabbing() throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        rig.windows.open(try viewerFile("tve-1601-tabs", "one\n"))
        let window = try XCTUnwrap(rig.windows.entries.last?.window)
        XCTAssertEqual(window.tabbingMode, .disallowed)
    }

    /// D12, not dirty: an edited window takes the file's new text, the caret clamped to it.
    func testCleanEditorTakesTheChangeOnDisk() throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tve-reload", "a long first line\n")
        let model = try rig.edit(url)
        let view = try XCTUnwrap(model.editorView)
        view.setSelectedRange(NSRange(location: 15, length: 0))
        try Data("new\n".utf8).write(to: url)
        XCTAssertTrue(rig.windows.changed(model))
        TextViewerEditorRig.waitUntil("the new text", { view.string == "new\n" })
        XCTAssertEqual(view.selectedRange().location, 4, "clamped")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.buffer, "new\n")
    }

    /// D12, dirty: a change on disk never replaces the buffer (#1545 brings the banner); the save then refuses it.
    func testDirtyEditorKeepsItsBufferOnAChangeOnDisk() async throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = try viewerFile("tve-keep", "mine\n")
        let model = try await rig.editAsync(url)
        try rig.type(model, "x")
        try Data("theirs\n".utf8).write(to: url)
        XCTAssertTrue(rig.windows.changed(model))
        await TextViewerEditorRig.waitUntilAsync("the load landed", { model.document?.text == "theirs\n" })
        XCTAssertEqual(model.buffer, "xmine\n")
        XCTAssertEqual(model.editorView?.string, "xmine\n")
        XCTAssertTrue(model.isDirty)
    }

    /// A window that goes away without the sheet (Quit Without Saving closes nothing; a close() from code) still reports
    /// clean before it goes, so no update waits on a gone window.
    func testClosedWindowReportsClean() throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let model = try rig.edit(viewerFile("tve-gone", "a\n"))
        try rig.type(model, "x")
        XCTAssertTrue(rig.dirty.isDirty)
        var installs = 0
        rig.dirty.holdUpdate { installs += 1 }
        try XCTUnwrap(rig.windows.entries.last?.window).close()
        XCTAssertTrue(rig.windows.entries.isEmpty)
        XCTAssertFalse(rig.dirty.isDirty)
        XCTAssertEqual(installs, 1, "the held update goes on")
    }

    /// Rider from #1107: Screenshot is in Read only.
    func testScreenshotIsHiddenInEdit() {
        XCTAssertTrue(TextViewerHeader.showsScreenshot(.read))
        XCTAssertFalse(TextViewerHeader.showsScreenshot(.edit))
        XCTAssertFalse(TextViewerHeader.showsScreenshot(.terminal))
    }

    /// A lossy file never enters Edit (D1).
    func testLossyFileNeverEntersEdit() throws {
        let rig = TextViewerEditorRig()
        defer { rig.closeAll() }
        let url = tempDir("tve-lossy").appendingPathComponent("b.txt")
        try Data([0x61, 0xFF, 0x0A]).write(to: url)
        rig.windows.open(url)
        let model = try XCTUnwrap(rig.windows.entries.last?.model)
        TextViewerEditorRig.waitUntil("loaded", { model.state != nil })
        model.edit()
        XCTAssertEqual(model.mode, .read)
        XCTAssertTrue(model.editorView == nil)
    }

    /// The save's failure texts: one per case, each says it was not saved.
    func testEveryFailureSaysNotSaved() {
        let all: [TextFileWriter.Failure] = [.lossy, .notRegular, .changedOnDisk, .swapped, .locked, .retargeted,
                                             .failed(.write, EACCES), .incomplete(.write, ENOSPC)]
        let texts = all.map(TextViewerEditor.message)
        XCTAssertEqual(Set(texts).count, all.count)
        XCTAssertTrue(texts.allSatisfy { $0.contains("Not saved") || $0.contains("Save failed") }, "\(texts)")
    }
}
