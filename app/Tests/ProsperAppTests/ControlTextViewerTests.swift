import Foundation
import XCTest
@testable import ProsperApp

/// #1857: textviewer.open on a recorder seam (no window is built or shown) and temp files under tempDir().
@MainActor
final class ControlTextViewerTests: XCTestCase {
    final class Recorder { var urls: [URL] = [] }

    @MainActor
    func withRecorder(_ body: (URL, Recorder) async throws -> Void) async throws {
        let saved = (ControlTextViewer.open, ControlTextViewer.home)
        defer { (ControlTextViewer.open, ControlTextViewer.home) = saved }
        let dir = tempDir("ctv")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = Recorder()
        ControlTextViewer.open = { rec.urls.append($0) }
        ControlTextViewer.home = { dir.path }
        try await body(dir, rec)
    }

    func put(_ dir: URL, _ rel: String, _ text: String = "hi") throws -> URL {
        let u = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    @MainActor
    func refused(_ path: String, _ part: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ControlTextViewer.run(["path": .string(path)]), file: file, line: line) {
            let m = ($0 as? ControlError)?.message ?? ""
            XCTAssertTrue(m.contains(part), "\(path): \(m)", file: file, line: line)
        }
    }

    @MainActor
    func testOpensARegularFileOnceThroughTheSeam() async throws {
        try await withRecorder { dir, rec in
            let f = try put(dir, "notes/a.txt")
            let r = try ControlTextViewer.run(["path": .string(f.path)])
            XCTAssertEqual(rec.urls.map(\.path), [f.standardizedFileURL.path])
            guard case .object(let o) = r.result else { return XCTFail("object") }
            XCTAssertNotNil(o["opened"])
            _ = try ControlTextViewer.run(["path": .string("~/notes/a.txt")])
            XCTAssertEqual(rec.urls.count, 2, "~ is the seam's home")
        }
    }

    @MainActor
    func testSecretPathsAreRefusedAndNothingOpens() async throws {
        try await withRecorder { dir, rec in
            for rel in [".ssh/config", ".aws/config", ".gnupg/x", ".config/my-token/a", "a.pem", "a.KEY", ".env", ".env.local",
                        "Library/Keychains/login.keychain-db", "app/credentials.json", "id_ed25519", ".netrc"] {
                let f = try put(dir, rel)
                refused(f.path, "refused")
            }
            XCTAssertTrue(rec.urls.isEmpty)
            XCTAssertNoThrow(try ControlTextViewer.run(["path": .string(try put(dir, ".config/app/a.txt").path)]))
        }
    }

    @MainActor
    func testSymlinkIntoARefusedPlaceIsRefused() async throws {
        try await withRecorder { dir, rec in
            let target = try put(dir, ".ssh/known_hosts")
            let link = dir.appendingPathComponent("innocent.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            refused(link.path, "refused")
            XCTAssertTrue(rec.urls.isEmpty)
        }
    }

    @MainActor
    func testNonRegularMissingRelativeHiddenAndOversizedAreRefused() async throws {
        try await withRecorder { dir, rec in
            refused(dir.path, "not a regular file")
            refused(dir.appendingPathComponent("nope.txt").path, "no such file")
            refused("relative/a.txt", "absolute")
            refused("/tmp/a\u{202E}.txt", "hidden character")
            let big = dir.appendingPathComponent("big.bin")
            XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
            let h = try FileHandle(forWritingTo: big)
            try h.truncate(atOffset: UInt64(TextViewerDocument.maxBytes) + 1)   // sparse
            try h.close()
            refused(big.path, "limit")
            XCTAssertTrue(rec.urls.isEmpty)
        }
    }

    @MainActor
    func testCommandShapeIsReadOnlyWithARequiredPath() {
        let c = ControlTextViewer.command
        XCTAssertEqual(c.name, "textviewer.open")
        XCTAssertTrue(c.mutates, "a window is a visible effect: gated by the Settings switch")
        XCTAssertEqual(c.args["path"]?.required, true)
        XCTAssertThrowsError(try c.validate([:]))
    }

    @MainActor
    func testSwitchOffRefusesAndTheSeamIsNotCalled() async throws {
        Preferences.defaults.removeObject(forKey: Preferences.agentControlKey)
        addTeardownBlock { Preferences.defaults.removeObject(forKey: Preferences.agentControlKey) }
        try await withRecorder { dir, rec in
            let f = try put(dir, "a.txt")
            var reg = ControlRegistry()
            let changes = ControlChanges()
            var notices: [String] = []
            changes.present = { text, _ in notices.append(text) }
            reg.changes = changes
            reg.register(ControlTextViewer.command)
            let line = Data(#"{"cmd":"textviewer.open","args":{"path":"\#(f.path)"}}"#.utf8)
            Preferences.agentControlEnabled = false
            let off = await reg.reply(to: line)
            XCTAssertEqual(off.error, ControlChanges.offError)
            XCTAssertTrue(rec.urls.isEmpty)
            Preferences.agentControlEnabled = true
            let on = await reg.reply(to: line)
            XCTAssertTrue(on.ok)
            XCTAssertEqual(rec.urls.count, 1)
            XCTAssertEqual(notices.count, 1)
            XCTAssertTrue(notices.last?.hasPrefix("Agent opened a file in Text Viewer: ") == true)
            XCTAssertTrue(changes.entries.last?.undoable == false)
        }
    }
}
