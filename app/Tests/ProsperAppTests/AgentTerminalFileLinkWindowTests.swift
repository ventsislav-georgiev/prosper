import XCTest
@testable import ProsperApp

/// #1480 b: through the window model, a relative file link resolves against the live session's folder; a remote
/// session opens no path at all. Fake files in a scratch folder; the viewer is a recorder, never a window.
@MainActor
final class AgentTerminalFileLinkWindowTests: XCTestCase {
    private struct Fixture {
        let model: AgentWindowModel
        let dir: URL
        var shown: Recorder
    }

    private final class Recorder { var urls: [URL] = [] }

    private func fixture(cwd: String? = nil, dir key: String = "/Users/example/dch") throws -> Fixture {
        let dir = tempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try "fake\n".write(to: dir.appendingPathComponent("docs/draft.txt"), atomically: true, encoding: .utf8)
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        var s = AgentSession(key: AgentSessionKey(dir: key, name: "api"), alias: "", activity: 0, state: .done, agents: 0,
                             meta: nil, version: "1.30.0", claudeSessionID: nil, transcriptPath: nil)
        s.cwd = cwd ?? dir.path
        store.sessions = [s]
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)   // no defaults: nothing stored or read
        m.now = { AgentWindowD1Tests.now }
        m.openSession = { _ in }
        m.resume = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        m.bind(store)
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.terminal.makeScreen = { AgentTerminalTests.FakeScreen($0) }
        m.terminal.homeDirectory = { dir.path }
        let rec = Recorder()
        m.terminal.showFile = { rec.urls.append($0) }
        m.terminal.fileCheck = { $0() }   // #1719: the link's disk check inline (the product runs it off main)
        m.terminal.openURL = { _ in XCTFail("a file never reaches openURL") }
        m.terminal.attach(s.key)
        return Fixture(model: m, dir: dir, shown: rec)
    }

    func testARelativePathInALocalSessionOpensUnderItsFolder() throws {
        let f = try fixture()
        defer { f.model.close() }
        f.model.terminal.open("docs/draft.txt.")
        XCTAssertEqual(f.shown.urls.map(\.path), [f.dir.path + "/docs/draft.txt"])
    }

    func testARelativePathInARemoteSessionOpensNothing() throws {
        // The remote key sits in the store with a folder that exists here: only the remote rule keeps it shut.
        let f = try fixture(dir: "@host")
        defer { f.model.close() }
        f.model.terminal.open("docs/draft.txt")
        XCTAssertTrue(f.shown.urls.isEmpty, "\(f.shown.urls)")
    }

    func testAnAbsolutePathInARemoteSessionOpensNothing() throws {
        let f = try fixture(dir: "@host")
        defer { f.model.close() }
        f.model.terminal.open(f.dir.path + "/docs/draft.txt")
        f.model.terminal.open("~/docs/draft.txt")
        f.model.terminal.open("file://" + f.dir.path + "/docs/draft.txt")
        XCTAssertTrue(f.shown.urls.isEmpty, "\(f.shown.urls)")
    }

    func testASessionWithAnEmptyFolderOpensNoRelativePath() throws {
        let f = try fixture(cwd: "")
        defer { f.model.close() }
        f.model.terminal.open("docs/draft.txt")
        XCTAssertTrue(f.shown.urls.isEmpty, "\(f.shown.urls)")
        f.model.terminal.open(f.dir.path + "/docs/draft.txt")   // an absolute path still opens
        XCTAssertEqual(f.shown.urls.count, 1)
    }
}
