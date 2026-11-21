import AppKit
import XCTest
@testable import ProsperApp

/// #1822: an image pasted into the New session prompt becomes a PNG under the prompt images dir and its path at the
/// caret; any number per prompt. Offscreen only (the never-shown form window of AgentWindowNewSessionFormTests); every
/// paste reads a named pasteboard the row creates and releases (never the user's clipboard), through the editor's
/// `paste(from:)` seam; every image is written under the row's own tempDir() (the model's `promptImagesDir`).
extension AgentWindowD1Tests {

    /// A pasteboard of its own, released at teardown.
    @MainActor
    func promptPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.prompt.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    @MainActor
    func promptImageItems(_ pb: NSPasteboard, _ reps: [(Data, NSPasteboard.PasteboardType)]) {
        pb.clearContents()
        pb.writeObjects(reps.map { d, t in
            let item = NSPasteboardItem()
            item.setData(d, forType: t)
            return item
        })
    }

    /// The form with its editor at the end of `prompt`, images going to a fresh temp dir.
    @MainActor
    func promptImageForm(_ prompt: String = "") throws -> (m: AgentWindowModel, win: AgentsNSWindow, host: NSView, tv: AgentComposerTextView, dir: URL) {
        let m = wiringModel(store([mapped("a")]), SpawnCalls())
        let dir = tempDir("promptImages").appendingPathComponent("prompt-images", isDirectory: true)
        m.promptImagesDir = dir
        let (win, host) = formWindow(m, CGSize(width: sz(560), height: sz(800)))
        m.openNewSessionNamed()
        m.setNewSessionPrompt(prompt)
        settle(host)
        let tv = try XCTUnwrap(focusViews(host, AgentComposerTextView.self).first, "the editor")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        return (m, win, host, tv, dir)
    }

    /// Runs the main loop until the form holds `n` images (the write is off main, the insert back on it).
    @MainActor
    func awaitPromptImages(_ m: AgentWindowModel, _ n: Int) {
        let end = Date().addingTimeInterval(10)
        while (m.newSession?.images.count ?? 0) < n && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    func pngs(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
    }

    func isPNG(_ url: URL) -> Bool {
        (try? Data(contentsOf: url)).map { Array($0.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] } ?? false
    }

    /// One PNG on the pasteboard: one PNG file under the dir, its absolute path inserted at the caret after a space,
    /// one chip with its remove button. Red at base: the editor's paste pasted nothing (no image in a plain text view).
    @MainActor
    func testAgentWindowNewSessionPromptImagePasteWritesOnePNGAndInsertsItsPath() throws {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        try withNewSessionPrefs {
            let f = try promptImageForm("Look at")
            defer { f.m.close(); f.win.close() }
            let pb = promptPasteboard()
            promptImageItems(pb, [(try AgentNewSessionPromptImagesTests.png(), .png)])
            f.tv.paste(from: pb)
            awaitPromptImages(f.m, 1)
            let files = pngs(f.dir)
            XCTAssertEqual(files.count, 1, "one PNG written")
            // contentsOfDirectory resolves /var to /private/var: the inserted path is the dir's own spelling.
            let path = f.dir.appendingPathComponent(try XCTUnwrap(files.first?.lastPathComponent)).path
            XCTAssertTrue(isPNG(URL(fileURLWithPath: path)))
            XCTAssertEqual(f.m.newSession?.prompt, "Look at " + path + " ", "the path at the caret")
            XCTAssertEqual(f.m.newSession?.images.map(\.path), [path])
            XCTAssertTrue(f.m.newSession?.images.first?.thumb != nil, "a thumbnail")
            let name = (path as NSString).lastPathComponent
            let tree = AXTreeSupport.poll(f.host) { $0.contains { $0.role == "AXButton" && $0.named("Remove image \(name)") } }
            XCTAssertTrue(tree.contains { $0.role == "AXButton" && $0.named("Remove image \(name)") }, "the chip: \(tree.map(\.name))")
        }
    }

    /// Two pastes: two files with their own names and two paths, in paste order.
    @MainActor
    func testAgentWindowNewSessionPromptImageTwoPastesGiveTwoFilesAndTwoPaths() throws {
        try withNewSessionPrefs {
            let f = try promptImageForm()
            defer { f.m.close(); f.win.close() }
            let pb = promptPasteboard()
            promptImageItems(pb, [(try AgentNewSessionPromptImagesTests.png(), .png)])
            f.tv.paste(from: pb)
            awaitPromptImages(f.m, 1)
            f.tv.paste(from: pb)
            awaitPromptImages(f.m, 2)
            let paths = f.m.newSession?.images.map(\.path) ?? []
            XCTAssertEqual(Set(paths).count, 2, "two unique names: \(paths)")
            XCTAssertEqual(Set(pngs(f.dir).map(\.lastPathComponent)), Set(paths.map { ($0 as NSString).lastPathComponent }), "two files")
            XCTAssertEqual(f.m.newSession?.prompt, paths.map { $0 + " " }.joined(), "both paths, in order")
        }
    }

    /// One paste of several items (a PNG and a TIFF) gives one path each; the TIFF is re-encoded as PNG. Two image file
    /// URLs (a Finder copy) give two copies under the dir, not the source paths.
    @MainActor
    func testAgentWindowNewSessionPromptImageMultiItemPasteGivesOnePathEach() throws {
        try withNewSessionPrefs {
            let f = try promptImageForm()
            defer { f.m.close(); f.win.close() }
            let pb = promptPasteboard()
            promptImageItems(pb, [(try AgentNewSessionPromptImagesTests.png(), .png), (try AgentNewSessionPromptImagesTests.tiff(), .tiff)])
            f.tv.paste(from: pb)
            awaitPromptImages(f.m, 2)
            XCTAssertEqual(f.m.newSession?.images.count, 2)
            XCTAssertEqual(pngs(f.dir).count, 2)
            XCTAssertTrue(pngs(f.dir).allSatisfy(isPNG), "the TIFF is written as PNG")

            let src = tempDir("promptImageSources")
            let a = src.appendingPathComponent("a.png"), b = src.appendingPathComponent("b.png")
            try AgentNewSessionPromptImagesTests.png().write(to: a)
            try AgentNewSessionPromptImagesTests.png().write(to: b)
            pb.clearContents()
            pb.writeObjects([a as NSURL, b as NSURL])
            f.tv.paste(from: pb)
            awaitPromptImages(f.m, 4)
            let paths = f.m.newSession?.images.map(\.path) ?? []
            XCTAssertEqual(paths.count, 4)
            XCTAssertTrue(paths.allSatisfy { $0.hasPrefix(f.dir.path + "/") }, "copies under the dir: \(paths)")
            XCTAssertEqual(pngs(f.dir).count, 4)
            XCTAssertFalse(f.m.newSession?.prompt.contains("a.png") ?? true, "not the names as text")
        }
    }

    /// A text paste stays text: no file, no image, the dir never made.
    @MainActor
    func testAgentWindowNewSessionPromptImageTextPasteStaysText() throws {
        try withNewSessionPrefs {
            let f = try promptImageForm("Fix ")
            defer { f.m.close(); f.win.close() }
            let pb = promptPasteboard()
            pb.clearContents()
            pb.setString("the login bug", forType: .string)
            f.tv.paste(from: pb)
            settle(f.host)
            XCTAssertEqual(f.m.newSession?.prompt, "Fix the login bug")
            XCTAssertEqual(f.m.newSession?.images.count, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.dir.path), "nothing written, not even the dir")
        }
    }

    /// Performance: nothing runs until a paste: opening the form and typing make no dir and no file.
    @MainActor
    func testAgentWindowNewSessionPromptImageNothingRunsBeforeAPaste() throws {
        try withNewSessionPrefs {
            let f = try promptImageForm("Example task")
            defer { f.m.close(); f.win.close() }
            f.m.setNewSessionPrompt("Example task, longer")
            settle(f.host)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.dir.path))
        }
    }

    /// A chip's x takes its path (and the space after it) out of the prompt, and only that chip goes.
    @MainActor
    func testAgentWindowNewSessionPromptImageRemoveTakesItsPathOut() throws {
        try withNewSessionPrefs {
            let f = try promptImageForm("See")
            defer { f.m.close(); f.win.close() }
            let pb = promptPasteboard()
            promptImageItems(pb, [(try AgentNewSessionPromptImagesTests.png(), .png), (try AgentNewSessionPromptImagesTests.png(), .png)])
            f.tv.paste(from: pb)
            awaitPromptImages(f.m, 2)
            let paths = f.m.newSession?.images.map(\.path) ?? []
            XCTAssertEqual(paths.count, 2)
            let first = try XCTUnwrap(paths.first), last = try XCTUnwrap(paths.last)
            f.m.removeNewSessionPromptImage(first)
            XCTAssertEqual(f.m.newSession?.prompt, "See " + last + " ")
            XCTAssertEqual(f.m.newSession?.images.map(\.path), [last])
        }
    }
}

/// #1822: the prompt images' pure parts: what a pasteboard holds, the prune, the inserted text. Named pasteboards only.
final class AgentNewSessionPromptImagesTests: XCTestCase {
    static func rep() throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    }
    static func png() throws -> Data { try XCTUnwrap(rep().representation(using: .png, properties: [:])) }
    static func tiff() throws -> Data { try XCTUnwrap(rep().tiffRepresentation) }

    @MainActor
    func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.prompt.\(UUID().uuidString)"))
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    /// Text alone, text with image bytes (text wins, as in the terminal), image bytes, image files with their names.
    @MainActor
    func testSourcesTakeImagesAndLeaveTextAlone() throws {
        let pb = pasteboard()
        pb.clearContents()
        pb.setString("plain", forType: .string)
        XCTAssertTrue(AgentPromptImages.sources(pb) == nil, "text")
        let png = try Self.png()
        pb.clearContents()
        let both = NSPasteboardItem()
        both.setData(png, forType: .png)
        both.setString("caption", forType: .string)
        pb.writeObjects([both])
        XCTAssertTrue(AgentPromptImages.sources(pb) == nil, "text beside image bytes stays text")
        pb.clearContents()
        let one = NSPasteboardItem(), two = NSPasteboardItem()
        one.setData(png, forType: .png)
        two.setData(try Self.tiff(), forType: .tiff)
        pb.writeObjects([one, two])
        XCTAssertEqual(AgentPromptImages.sources(pb)?.count, 2, "one per item")
        let dir = tempDir("promptSources"), file = dir.appendingPathComponent("shot.png"), doc = dir.appendingPathComponent("notes.txt")
        try png.write(to: file)
        try Data("x".utf8).write(to: doc)
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        XCTAssertEqual(AgentPromptImages.sources(pb), [.file(file)])
        pb.clearContents()
        pb.writeObjects([doc as NSURL])
        XCTAssertTrue(AgentPromptImages.sources(pb) == nil, "a file that is not an image")
    }

    /// The prune removes PNGs older than the age only: a new PNG and an old non-PNG stay.
    func testPruneRemovesOldFilesOnly() throws {
        let dir = tempDir("promptPrune"), now = Date()
        let old = dir.appendingPathComponent("old.png"), fresh = dir.appendingPathComponent("fresh.png")
        let other = dir.appendingPathComponent("old.txt")
        for u in [old, fresh, other] { try Data("x".utf8).write(to: u) }
        let past = now.addingTimeInterval(-AgentPromptImages.maxAge - 3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: other.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: fresh.path)
        XCTAssertEqual(AgentPromptImages.prune(dir: dir, now: now), 1)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: old.path), "old PNG gone")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a fresh PNG stays")
        XCTAssertTrue(fm.fileExists(atPath: other.path), "not a PNG: stays")
        XCTAssertEqual(AgentPromptImages.prune(dir: dir.appendingPathComponent("missing"), now: now), 0, "no dir: nothing")
    }

    /// A paste prunes before it writes (the lazy prune is on paste).
    func testWritePrunesFirst() throws {
        let dir = tempDir("promptWrite"), now = Date()
        let old = dir.appendingPathComponent("old.png")
        try Data("x".utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-AgentPromptImages.maxAge - 60)], ofItemAtPath: old.path)
        let made = AgentPromptImages.write([.data(try Self.png()), .data(Data("not an image".utf8))], dir: dir, now: now)
        XCTAssertEqual(made.count, 1, "the non-image is skipped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testInsertionAndRemoval() {
        XCTAssertEqual(AgentPromptImages.insertion(["/Users/example/a.png"], after: nil), "/Users/example/a.png ")
        XCTAssertEqual(AgentPromptImages.insertion(["/a.png", "/b.png"], after: "t"), " /a.png /b.png ")
        XCTAssertEqual(AgentPromptImages.insertion(["/a.png"], after: "\n"), "/a.png ")
        XCTAssertEqual(AgentPromptImages.removing("/a.png", from: "See /a.png /b.png "), "See /b.png ")
        XCTAssertEqual(AgentPromptImages.removing("/a.png", from: "See /a.png"), "See ")
    }

    /// Under XCTest the default dir is nil: no row can write the real Caches dir.
    func testDefaultDirIsNilUnderXCTest() {
        XCTAssertTrue(AgentPromptImages.defaultDir == nil)
    }
}
