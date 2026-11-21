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

    /// The refusal message for `path`, or nil when it opened.
    @MainActor
    func refusal(_ path: String) async -> String? {
        do { _ = try await ControlTextViewer.run(["path": .string(path)]); return nil } catch {
            return (error as? ControlError)?.message ?? String(describing: error)
        }
    }

    @MainActor
    func refused(_ path: String, _ part: String, file: StaticString = #filePath, line: UInt = #line) async {
        let m = await refusal(path)
        XCTAssertTrue(m?.contains(part) == true, "\(path): \(m ?? "opened")", file: file, line: line)
    }

    /// Refused by the deny list itself, not by the allow list behind it (so each deny group is pinned on its own).
    @MainActor
    func denied(_ path: String, file: StaticString = #filePath, line: UInt = #line) async {
        let m = await refusal(path) ?? "opened"
        XCTAssertTrue(m.hasPrefix("refused") && !m.contains("plain text"), "\(path): \(m)", file: file, line: line)
    }

    @MainActor
    func testOpensARegularFileOnceThroughTheSeam() async throws {
        try await withRecorder { dir, rec in
            let f = try put(dir, "notes/a.txt")
            let r = try await ControlTextViewer.run(["path": .string(f.path)])
            XCTAssertEqual(rec.urls.map(\.path), [f.resolvingSymlinksInPath().path])
            guard case .object(let o) = r.result else { return XCTFail("object") }
            XCTAssertNotNil(o["opened"])
            _ = try await ControlTextViewer.run(["path": .string("~/notes/a.txt")])
            XCTAssertEqual(rec.urls.count, 2, "~ is the seam's home")
        }
    }

    @MainActor
    func testSecretPathsAreRefusedAndNothingOpens() async throws {
        try await withRecorder { dir, rec in
            for rel in [".ssh/config", ".aws/config", ".gnupg/x", ".config/my-token/a", "a.pem", "a.KEY", ".env", ".env.local",
                        "Library/Keychains/login.keychain-db", "app/credentials.json", "id_ed25519", ".netrc"] {
                let f = try put(dir, rel)
                await denied(f.path)
            }
            XCTAssertTrue(rec.urls.isEmpty)
            let ok = try put(dir, ".config/app/a.txt").path
            let m = await refusal(ok)
            XCTAssertTrue(m == nil, m ?? "")
        }
    }

    /// n182: the firmlink spelling must not skip the home-anchored rules; refused by name, before any stat.
    @MainActor
    func testFirmlinkSpellingOfAHomeAnchoredPathIsRefused() async throws {
        try await withRecorder { dir, rec in
            let f = try put(dir, ".config/my-token/a.txt")
            await denied("/System/Volumes/Data" + f.path)
            await denied("/System/Volumes/Data" + dir.path + "/.config/my-token/missing.txt")
            XCTAssertTrue(rec.urls.isEmpty)
        }
    }

    @MainActor
    func testSymlinkIntoARefusedPlaceIsRefused() async throws {
        try await withRecorder { dir, rec in
            let target = try put(dir, ".ssh/known_hosts")
            let link = dir.appendingPathComponent("innocent.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            await refused(link.path, "refused")
            XCTAssertTrue(rec.urls.isEmpty)
        }
    }

    /// n175: one sample from each group the QA pass found missing; every one carries an allowed extension or none, so
    /// only the deny list can refuse it.
    @MainActor
    func testEveryNewDenyGroupIsRefusedEvenWithAnAllowedExtension() async throws {
        try await withRecorder { dir, rec in
            for rel in [".config/gh/hosts.yml", ".codex/auth.json", ".claude/.credentials.json", "notes/my-credential.txt",
                        ".ccpool/state.json", "personal/ccpool/accounts.json", "dist/supporter.dat",
                        ".kube/config", ".docker/config.json", "home/.pypirc", ".config/gcloud/credentials.db",
                        ".config/gcloud/access_tokens.db", "repo/.git-credentials",
                        "Library/Application Support/Google/Chrome/Default/Bookmarks.json",
                        "Library/Application Support/Firefox/profiles.ini", "Library/Application Support/Safari/a.plist",
                        "exports/Passwords.csv", "exports/1Password.csv", "exports/bitwarden_export.json", "exports/LastPass.csv",
                        "exports/keepass.xml", "Library/Application Support/Prosper/state.json",
                        "Library/Preferences/com.example.app.plist", ".config/dch/config.toml", ".config/prosper/a.toml"] {
                await denied(try put(dir, rel).path)
            }
            XCTAssertTrue(rec.urls.isEmpty)
        }
    }

    /// n175 (a): only plain-text types open; an extensionless file only outside every dot-folder.
    @MainActor
    func testOnlyPlainTextTypesOpen() async throws {
        try await withRecorder { dir, rec in
            for rel in ["data/a.sqlite", "data/a.bin", "data/a.dat", ".cache/blob", "notes/.hidden"] {
                await refused(try put(dir, rel).path, "plain text")
            }
            XCTAssertTrue(rec.urls.isEmpty)
            for rel in ["notes/Makefile", "notes/a.JSON", ".config/app/a.yml", "src/main.swift"] {
                let m = await refusal(try put(dir, rel).path)
                XCTAssertTrue(m == nil, "\(rel): \(m ?? "")")
            }
            XCTAssertEqual(rec.urls.count, 4)
        }
    }

    /// n175 (b): the checked path is the one that opens (a symlink opens its target), and a file with a second name is
    /// refused (the other name may sit in a refused place).
    @MainActor
    func testASymlinkOpensItsTargetAndAHardLinkIsRefused() async throws {
        try await withRecorder { dir, rec in
            let target = try put(dir, "notes/real.md")
            let link = dir.appendingPathComponent("link.md")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let m = await refusal(link.path)
            XCTAssertTrue(m == nil, m ?? "")
            XCTAssertEqual(rec.urls.map(\.path), [target.resolvingSymlinksInPath().path])
            let hard = try put(dir, "notes/b.txt")
            try FileManager.default.linkItem(at: hard, to: dir.appendingPathComponent("notes/c.txt"))
            await refused(hard.path, "hard link")
            XCTAssertEqual(rec.urls.count, 1)
        }
    }

    /// n174: the agent's open goes through `presentQuietly` (no activation, not key), the person's through `present`;
    /// both seams are recorders and the windows are built with no autosave and never shown.
    @MainActor
    func testTheAgentsOpenIsQuietAndThePersonsIsNot() throws {
        let dir = tempDir("ctv-quiet")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try put(dir, "a.txt"), b = try put(dir, "b.txt")
        let w = TextViewerWindows()
        var loud = 0, quiet = 0
        w.build = { TextViewerWindows.makeWindow($0, autosave: nil) }
        w.present = { _ in loud += 1 }
        w.presentQuietly = { _ in quiet += 1 }
        w.dismissed = { _ in }
        w.imageLoader = { _, _, _ in nil }
        ControlTextViewer.openQuietly(a, in: w)
        ControlTextViewer.openQuietly(a, in: w)   // the window already open: focused quietly too
        XCTAssertEqual(quiet, 2)
        XCTAssertEqual(loud, 0)
        w.open(b)
        XCTAssertEqual(loud, 1, "the person's open is unchanged")
        XCTAssertEqual(quiet, 2)
        let deadline = Date().addingTimeInterval(5)
        while !w.entries.allSatisfy({ $0.model.state != nil }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        for e in w.entries { e.window.close() }
    }

    @MainActor
    func testNonRegularMissingRelativeHiddenAndOversizedAreRefused() async throws {
        try await withRecorder { dir, rec in
            await refused(dir.path, "not a regular file")
            await refused(dir.appendingPathComponent("nope.txt").path, "no such file")
            await refused("relative/a.txt", "absolute")
            await refused("/tmp/a\u{202E}.txt", "hidden character")
            let big = dir.appendingPathComponent("big.txt")
            XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
            let h = try FileHandle(forWritingTo: big)
            try h.truncate(atOffset: UInt64(TextViewerDocument.maxBytes) + 1)   // sparse
            try h.close()
            await refused(big.path, "limit")
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
