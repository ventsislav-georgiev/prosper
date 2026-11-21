import AppKit
import Foundation
import XCTest
@testable import ProsperApp

/// #1863: remote.list, remote.resume and sessions.new {host, images}. The window model's own fakes (AgentWindowRemoteRowsTests,
/// AgentWindowRemoteHistoryTests, AgentWindowRemoteSpawnTests, AgentWindowD1Tests): no dch, no host dialled, no window shown,
/// no real island controller. Image files live under tempDir(). ControlSessions' seams are put back after each row.
final class ControlRemoteTests: XCTestCase {
    let base = AgentWindowD1Tests()
    let history = AgentWindowRemoteHistoryTests()
    let spawn = AgentWindowRemoteSpawnTests()
    /// The notices the change log presented (recorded, never shown).
    var notices: [String] = []

    @MainActor
    func withSeams(model: AgentWindowModel?, _ body: (ControlChanges) throws -> Void) rethrows {
        let saved = (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow, ControlSessions.storeImages,
                     ControlSessions.resumeRecord)
        defer {
            (ControlSessions.model, ControlSessions.islandStore, ControlSessions.showWindow, ControlSessions.storeImages,
             ControlSessions.resumeRecord) = saved
        }
        // This Mac's resume is never reached from here: another Mac's goes through the window's verb seam.
        ControlSessions.resumeRecord = { _, _ in XCTFail("this Mac's resume"); return false }
        ControlSessions.model = { model }
        ControlSessions.islandStore = { nil }
        ControlSessions.showWindow = { XCTFail("the window is never shown here"); return nil }
        // The paste path's writer, run in place (its off-main hop is AgentPromptImages.store's own).
        ControlSessions.storeImages = { src, dir, done in done(AgentPromptImages.write(src, dir: dir, now: Date())) }
        notices = []
        let changes = ControlChanges()
        changes.present = { text, _ in self.notices.append(text) }
        try body(changes)
    }

    func args(_ d: [String: String], images: [String]? = nil) -> [String: ControlJSON] {
        var a = d.mapValues { ControlJSON.string($0) }
        if let images { a["images"] = .array(images.map { .string($0) }) }
        return a
    }

    @MainActor
    func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    func hosts(_ j: ControlJSON) -> [String: [String: ControlJSON]] {
        guard case .object(let o) = j, case .array(let a)? = o["hosts"] else { return [:] }
        var out: [String: [String: ControlJSON]] = [:]
        for case .object(let h) in a { if case .string(let n)? = h["host"] { out[n] = h } }
        return out
    }

    func names(_ v: ControlJSON?, _ key: String) -> [String] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { if case .object(let o) = $0, case .string(let s)? = o[key] { s } else { nil } }
    }

    /// A 2x2 PNG written to `url`.
    func png(_ url: URL) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    // MARK: - remote.list

    /// Every host the sidebar names (its "Other machines" rows and History's host rows), sorted, with its sessions and
    /// records as sessions.history gives them; canStart is the form's host picker. No window: refused, never opened.
    @MainActor
    func testRemoteListGivesEachHostItsSessionsAndRecordsAsTheSidebarDoes() throws {
        let (m, _, _) = history.model(AgentWindowRemoteHistoryTests.Lister(AgentWindowRemoteHistoryTests.fixture))
        defer { m.close() }
        history.spin { m.rows.contains { $0.host != nil } && m.rows.contains { $0.remote != nil } }
        try withSeams(model: m) { _ in
            let j = try ControlRemote.list(), h = hosts(j)
            guard case .object(let o) = j else { return XCTFail("not an object") }
            XCTAssertEqual(o["listing"], .bool(true), "the window is visible: its list is live")
            XCTAssertEqual(h.keys.sorted(), ["host-a", "host-b"], "-bad and the refused names are never listed")
            XCTAssertEqual(names(h["host-a"]?["sessions"], "name"), ["web"])
            guard case .array(let web)? = h["host-a"]?["sessions"], case .object(let w)? = web.first else { return XCTFail("no web row") }
            XCTAssertEqual(w["stale"], .bool(true))
            XCTAssertEqual(w["cwd"], .string("/Users/example/web"))
            XCTAssertEqual(w["title"], .string("web"))
            XCTAssertEqual(names(h["host-a"]?["history"], "id").sorted(), ["host-a:api", "host-a:docs"])
            XCTAssertEqual(names(h["host-b"]?["history"], "id"), ["host-b:build"])
            XCTAssertEqual(names(h["host-b"]?["sessions"], "name"), [], "build is filtered out of this list fixture")
            XCTAssertEqual(h["host-a"]?["canStart"], .bool(true))
            XCTAssertFalse(names(.array(h.values.flatMap { v -> [ControlJSON] in
                if case .array(let a)? = v["history"] { a } else { [] } }), "id").contains("old"), "this Mac's record is not another Mac's")
            m.store?.controlDch = DchCommand.Binary(path: "/opt/example/bin/dch", version: [1, 40, 9])
            XCTAssertEqual(hosts(try ControlRemote.list())["host-a"]?["canStart"], .bool(false), "dch 1.40: no remote start")
        }
        try withSeams(model: nil) { _ in refused(try ControlRemote.list(), ControlRemote.notOpen) }
    }

    // MARK: - remote.resume

    /// A remote record by host and name: sessions.resume's path (the gate, resumeRemote on the verb seam once, busy while
    /// it runs). An unknown host or name runs nothing.
    @MainActor
    func testRemoteResumeTakesTheHistoryRowsResumeOnItsHost() throws {
        let verbs = AgentWindowRemoteHistoryTests.Verbs()
        let (m, _, _) = history.model(AgentWindowRemoteHistoryTests.Lister(AgentWindowRemoteHistoryTests.fixture), verbs: verbs)
        defer { m.close() }
        history.spin { m.rows.contains { $0.host != nil } }
        try withSeams(model: m) { _ in
            func a(_ h: String, _ n: String) -> [String: ControlJSON] { ["host": .string(h), "name": .string(n)] }
            refused(try ControlRemote.resume(a("host-z", "api")), "no History records from host-z (remote.list lists them)")
            refused(try ControlRemote.resume(a("host-a", "old")), "no History record old from host-a (remote.list lists them)")
            XCTAssertEqual(verbs.calls.count, 0)
            let ch = try ControlRemote.resume(a("host-a", "api"))
            XCTAssertEqual(verbs.calls.count, 1)
            XCTAssertEqual(verbs.calls.last?.args, ["--host", "host-a", "--revive", "api.json", "--json"])
            XCTAssertEqual(ch.result, .string("api"))
            XCTAssertTrue(ch.undo == nil, "a resume has no undo")
            refused(try ControlRemote.resume(a("host-a", "api")), "api is busy: try again")
            XCTAssertEqual(verbs.calls.count, 1, "running: not run again")
        }
        try withSeams(model: nil) { _ in refused(try ControlRemote.resume(["host": .string("host-a"), "name": .string("api")]), ControlRemote.notOpen) }
    }

    // MARK: - sessions.new {host}

    /// The form's host picker, then its remote start on the verb seam (`--host H --spawn name --cwd`); a free name from
    /// that host's names; a host not listed, a prompt or images for another Mac are refused before the form opens.
    @MainActor
    func testSessionsNewOnAHostTakesTheFormsRemoteStart() throws {
        try spawn.withPrefs {
            let (m, _, calls) = spawn.model()
            defer { m.close() }
            m.cancelNewSession()
            try withSeams(model: m) { changes in
                refused(try ControlSessions.new(args(["agent": "shell", "host": "host-z"]), changes: changes),
                        "no host host-z to start on (remote.list lists them)")
                refused(try ControlSessions.new(args(["agent": "claude", "host": "host-a", "prompt": "hi"]), changes: changes),
                        "A first prompt starts on this Mac only")
                refused(try ControlSessions.new(args(["agent": "claude", "host": "host-a", "prompt": "hi"], images: ["/Users/example/a.png"]),
                                                changes: changes), "A first prompt starts on this Mac only")
                // n173 (d): the form's remote folder check passes a bidi override (only C0 and DEL); the agent's cwd is refused.
                XCTAssertNil(AgentNewSession.remoteFolderError("/Users/example/\u{202E}site"))
                refused(try ControlSessions.new(args(["agent": "shell", "host": "host-a", "cwd": "/Users/example/\u{202E}site"]), changes: changes),
                        "cwd has a control or hidden character")
                XCTAssertTrue(m.newSession == nil, "refused before the form opens")
                XCTAssertEqual(calls.verbs.count, 0)
                let ch = try ControlSessions.new(args(["agent": "shell", "host": "host-a", "name": "site", "cwd": "/Users/example/site"]),
                                                 changes: changes)
                XCTAssertEqual(calls.verbs.count, 1)
                XCTAssertEqual(calls.verbs.last.map { Array($0.args.prefix(7)) },
                               ["--host", "host-a", "--spawn", "site", "--cwd", "/Users/example/site", "--"])
                XCTAssertEqual(calls.local.count, 0, "never this Mac's spawn")
                XCTAssertEqual(ch.result, .string("site"))
                XCTAssertTrue(ch.undo == nil, "another Mac's session: no undo")
                m.cancelNewSession()
                // No name: a free one from the folder, against host-a's names (its History holds docs).
                let docs = try ControlSessions.new(args(["agent": "claude", "host": "host-a", "cwd": "/Users/example/docs"]), changes: changes)
                XCTAssertEqual(calls.verbs.count, 2)
                XCTAssertNotEqual(docs.result, .string("docs"), "docs is taken on host-a")
                XCTAssertEqual(calls.verbs.last?.args.first(where: { $0.hasPrefix("docs") }).map { ControlJSON.string($0) }, docs.result)
                XCTAssertTrue(calls.verbs.last?.args.contains("claude") == true, "plain claude there")
                m.cancelNewSession()
            }
        }
    }

    // MARK: - sessions.new {images}

    /// Image paths are checked before the form opens (absolute, an image type, a capped count, a prompt, claude on this
    /// Mac); then written through the paste path into the form's prompt after the text, and Start runs.
    @MainActor
    func testSessionsNewImagesGoThroughThePromptImagePathThenStart() throws {
        try base.withNewSessionPrefs {
            let st = base.store([]), spawns = AgentWindowD1Tests.SpawnCalls()
            let m = base.newSessionModel(st, spawns)
            defer { m.close() }
            m.sayFirst = { _, _, _ in }
            let dir = tempDir(), out = dir.appendingPathComponent("out", isDirectory: true)
            let a = dir.appendingPathComponent("a.png"), link = dir.appendingPathComponent("link.png")
            try png(a)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
            let ok = ["agent": "claude", "name": "api", "cwd": "/Users/example/api", "prompt": "look"]
            try withSeams(model: m) { changes in
                m.promptImagesDir = nil
                refused(try ControlSessions.new(args(ok, images: [a.path]), changes: changes), "images are not available here")
                m.promptImagesDir = out
                refused(try ControlSessions.new(args(ok, images: []), changes: changes), "images is an empty list")
                refused(try ControlSessions.new(args(ok, images: Array(repeating: a.path, count: AgentPromptImages.maxImages + 1)), changes: changes),
                        "at most \(AgentPromptImages.maxImages) images")
                for bad in ["a.png", "", "/Users/example/a\u{202E}.png"] {
                    refused(try ControlSessions.new(args(ok, images: [bad]), changes: changes),
                            "each image is an absolute file path with no control or hidden character")
                }
                refused(try ControlSessions.new(args(ok, images: ["/Users/example/notes.txt"]), changes: changes),
                        "notes.txt is not an image file (png, jpeg, heic, ...)")
                refused(try ControlSessions.new(args(["agent": "claude", "name": "api", "cwd": "/Users/example/api"], images: [a.path]),
                                                changes: changes), "images need a prompt")
                refused(try ControlSessions.new(args(["agent": "codex", "prompt": "look"], images: [a.path]), changes: changes),
                        "a prompt needs agent claude")
                XCTAssertTrue(m.newSession == nil, "refused before the form opens")
                XCTAssertEqual(spawns.calls.count, 0)
                let ch = try ControlSessions.new(args(ok, images: [a.path, link.path]), changes: changes)
                XCTAssertEqual(ch.result, .string("api"))
                XCTAssertEqual(ch.verb, "is starting a session")
                XCTAssertEqual(spawns.calls.count, 1, "Start ran once the images were written")
                let prompt = m.newSession?.prompt ?? ""
                XCTAssertTrue(prompt.hasPrefix("look /"), prompt)
                let written = (m.newSession?.images ?? []).map(\.path)
                XCTAssertEqual(written.count, 2, "the link is read as its target")
                XCTAssertTrue(written.allSatisfy { $0.hasPrefix(out.path) && prompt.contains($0) && FileManager.default.fileExists(atPath: $0) })
                XCTAssertFalse(prompt.contains(a.path), "the copies are sent, never the agent's own path")
                XCTAssertEqual(m.newSession?.pasting, 0)
                XCTAssertEqual(notices, [])
                m.cancelNewSession()
            }
        }
    }

    /// A file that is missing, not an image or not a regular file (a FIFO: a read would block) fails the write: no Start, the
    /// form cancelled and a notice. A form another hand changed while the write ran is never started.
    @MainActor
    func testSessionsNewImagesThatFailOrMeetAnotherFormStartNothing() throws {
        try base.withNewSessionPrefs {
            let st = base.store([]), spawns = AgentWindowD1Tests.SpawnCalls()
            let m = base.newSessionModel(st, spawns)
            defer { m.close() }
            let dir = tempDir(), fifo = dir.appendingPathComponent("pipe.png"), text = dir.appendingPathComponent("text.png")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            try Data("not an image".utf8).write(to: text)
            m.promptImagesDir = dir.appendingPathComponent("out", isDirectory: true)
            let ok = ["agent": "claude", "name": "api", "cwd": "/Users/example/api", "prompt": "look"]
            try withSeams(model: m) { changes in
                for bad in [fifo.path, text.path, dir.appendingPathComponent("missing.png").path] {
                    _ = try ControlSessions.new(args(ok, images: [bad]), changes: changes)
                    XCTAssertTrue(m.newSession == nil, "\(bad): the form is cancelled")
                }
                XCTAssertEqual(spawns.calls.count, 0)
                XCTAssertEqual(notices.count, 3)
                XCTAssertEqual(notices.first, "Agent's new session api did not start: Could not add 1 image")
                // The write held; meanwhile the person cancels and opens a form of their own.
                var held: (@MainActor @Sendable (AgentPromptImages.Outcome) -> Void)?
                ControlSessions.storeImages = { _, _, done in held = done }
                _ = try ControlSessions.new(args(ok, images: [text.path]), changes: changes)
                m.cancelNewSession()
                m.openNewSession()
                m.setNewSessionName("mine")
                // n173 (c): the person's own paste left its note; the agent's write ending later never clears it.
                m.beginNewSessionPromptPaste()
                m.addNewSessionPromptImages(AgentPromptImages.Outcome(failed: 1))
                XCTAssertEqual(m.newSession?.imageNote, "Could not add 1 image")
                held?(AgentPromptImages.Outcome(made: [.init(path: "/Users/example/x.png", thumb: nil)]))
                XCTAssertEqual(spawns.calls.count, 0, "the person's form is never started")
                XCTAssertEqual(m.newSession?.imageNote, "Could not add 1 image", "nothing of the agent's write reaches the person's form")
                XCTAssertEqual(m.newSession?.images.count, 0)
                XCTAssertEqual(m.newSession?.pasting, 0)
                XCTAssertEqual(m.newSession?.prompt.contains("x.png"), false)
                XCTAssertEqual(notices.last, "Agent's new session api did not start: the New session form changed")
                m.cancelNewSession()
            }
        }
    }

    // MARK: - AgentPromptImages.write (n172, n173)

    /// n172: a FIFO named as an image is failed through the one bounded read, never opened blocking. A writer waits on the
    /// FIFO with a real PNG: a read that opened it would get an image and make one. The row opens the read end itself
    /// (non-blocking) only to release that writer, and waits at most 5 s for it.
    func testPromptImagesWriteFailsAFIFOWithoutOpeningIt() throws {
        let dir = tempDir(), fifo = dir.appendingPathComponent("pipe.png"), image = dir.appendingPathComponent("a.png")
        try png(image)
        let bytes = try Data(contentsOf: image)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let wrote = DispatchSemaphore(value: 0), path = fifo.path
        Thread.detachNewThread {
            let fd = open(path, O_WRONLY)   // blocks until a reader opens the FIFO
            if fd >= 0 {
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                close(fd)
            }
            wrote.signal()
        }
        let out = AgentPromptImages.write([.file(fifo)], dir: dir.appendingPathComponent("out", isDirectory: true), now: Date())
        let release = open(fifo.path, O_RDONLY | O_NONBLOCK)
        XCTAssertEqual(wrote.wait(timeout: .now() + 5), .success, "the writer was released")
        if release >= 0 { close(release) }
        XCTAssertEqual(out.made.count, 0, "the FIFO was never read")
        XCTAssertEqual(out.failed, 1)
        XCTAssertEqual(out.refused, 0)
    }

    /// n173 (a): a link named like an image whose target is not is failed, though the target's bytes are a PNG; the
    /// same bytes under an image name behind a link are made.
    func testPromptImagesWriteChecksTheLinkTargetsName() throws {
        let dir = tempDir(), out = dir.appendingPathComponent("out", isDirectory: true)
        let target = dir.appendingPathComponent("shot.dat"), link = dir.appendingPathComponent("shot.png")
        try png(target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let bad = AgentPromptImages.write([.file(link)], dir: out, now: Date())
        XCTAssertEqual(bad.made.count, 0)
        XCTAssertEqual(bad.failed, 1)
        let named = dir.appendingPathComponent("named.png"), named2 = dir.appendingPathComponent("link2.png")
        try FileManager.default.copyItem(at: target, to: named)
        try FileManager.default.createSymbolicLink(at: named2, withDestinationURL: named)
        XCTAssertEqual(AgentPromptImages.write([.file(named2)], dir: out, now: Date()).made.count, 1)
    }

    /// n173 (b): an image over the pixel cap (read from its header) is failed before it is decoded; at the cap it is made.
    func testPromptImagesWriteFailsAnImageOverThePixelCap() throws {
        let dir = tempDir(), out = dir.appendingPathComponent("out", isDirectory: true), a = dir.appendingPathComponent("a.png")
        try png(a)
        let bytes = try Data(contentsOf: a)
        XCTAssertEqual(AgentPromptImages.maxPixels, 64_000_000)
        for src in [AgentPromptImages.Source.file(a), .data(bytes)] {
            let over = AgentPromptImages.write([src], dir: out, now: Date(), maxPixels: 3)
            XCTAssertEqual(over.made.count, 0, "2x2 is 4 pixels")
            XCTAssertEqual(over.failed, 1)
            XCTAssertEqual(AgentPromptImages.write([src], dir: out, now: Date(), maxPixels: 4).made.count, 1)
        }
    }

    // MARK: - Registration and the wire

    /// remote.list a read, remote.resume a change; sessions.new takes host and images, images checked as an array.
    @MainActor
    func testRegisterRemoteDescribesTheCommands() async throws {
        var r = ControlRegistry()
        ControlRegistry.registerRemote(&r)
        ControlRegistry.registerSessions(&r)
        XCTAssertEqual(r.commands["remote.list"]?.mutates, false)
        XCTAssertEqual(r.commands["remote.resume"]?.mutates, true)
        XCTAssertEqual(r.commands["remote.resume"]?.args["host"]?.required, true)
        XCTAssertEqual(r.commands["sessions.new"]?.args["images"]?.type, "array")
        XCTAssertEqual(r.commands["sessions.new"]?.args["host"]?.type, "string")
        let reply = await r.reply(to: Data(#"{"cmd":"sessions.new","args":{"agent":"claude","images":"/Users/example/a.png"}}"#.utf8))
        XCTAssertEqual(reply.error, "argument 'images' must be array, got string")
    }
}
