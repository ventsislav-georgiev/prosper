import XCTest
@testable import ProsperApp

private final class InertServices: ExtensionHostServices, @unchecked Sendable {
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
}

/// #1142: installLocal leaves hidden files and folders out of the installed copy
/// (RemoteInstaller.isHiddenMember, the publish rule) and never sweeps a linked source.
@MainActor
final class ExtensionInstallLocalHiddenTests: XCTestCase {
    private let extID = "eu.example.hidden"
    private let fm = FileManager.default

    private func makeRegistry(userDir: URL) -> ExtensionRegistry {
        ExtensionRegistry(systemDir: nil, userDir: userDir, hostVersion: "2.0.0",
                          defaults: scratchDefaults("install-local-hidden"), services: InertServices())
    }

    /// A source folder with normal files at depth one and two and hidden ones at both depths.
    private func writeSource(_ dir: URL) throws {
        try fm.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(extID)"
        name = "hidden"
        title = "Hidden"
        description = "A test extension"
        version = "1.0.0"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let files = ["init.lua": "function noop() end", "sub/lib.lua": "return {}",
                     ".git/x": "ref", ".DS_Store": "ds", "sub/.hidden": "h"]
        for (path, text) in files {
            try text.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
    }

    private func listing(_ dir: URL) throws -> [String] {
        try fm.subpathsOfDirectory(atPath: dir.path).sorted()
    }

    func testCopyLeavesHiddenFilesAndFoldersOut() throws {
        let tmp = tempDir()
        let source = tmp.appendingPathComponent("source"), userDir = tmp.appendingPathComponent("user")
        try writeSource(source)
        let record = try makeRegistry(userDir: userDir).installLocal(from: source)
        XCTAssertEqual(record.id, extID)
        XCTAssertEqual(try listing(userDir.appendingPathComponent(extID)),
                       ["extension.toml", "init.lua", "sub", "sub/lib.lua"])
        // The source keeps its hidden files: only the copy is swept.
        XCTAssertEqual(try listing(source),
                       [".DS_Store", ".git", ".git/x", "extension.toml", "init.lua", "sub", "sub/.hidden", "sub/lib.lua"])
    }

    func testReinstallOverAnInstallCarryingHiddenFilesEndsWithoutThem() throws {
        let tmp = tempDir()
        let source = tmp.appendingPathComponent("source"), userDir = tmp.appendingPathComponent("user")
        try writeSource(source)
        let registry = makeRegistry(userDir: userDir)
        try registry.installLocal(from: source)
        // An install made before #1142 carried them.
        let installed = userDir.appendingPathComponent(extID)
        try fm.createDirectory(at: installed.appendingPathComponent(".omc"), withIntermediateDirectories: true)
        try "s".write(to: installed.appendingPathComponent(".omc/state"), atomically: true, encoding: .utf8)
        try "h".write(to: installed.appendingPathComponent("sub/.old"), atomically: true, encoding: .utf8)
        try registry.installLocal(from: source)
        XCTAssertEqual(try listing(installed), ["extension.toml", "init.lua", "sub", "sub/lib.lua"])
    }

    func testLinkedSourceIsNeverSwept() throws {
        let tmp = tempDir()
        let source = tmp.appendingPathComponent("source"), userDir = tmp.appendingPathComponent("user")
        let link = tmp.appendingPathComponent("link")
        try writeSource(source)
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        let before = try listing(source)
        let bytesBefore = before.map { fm.contents(atPath: source.appendingPathComponent($0).path) }
        let outcome = Result { try makeRegistry(userDir: userDir).installLocal(from: link) }
        print("LINKED-INSTALL outcome: \(outcome.map(\.id))")
        XCTAssertEqual(try listing(source),
                       [".DS_Store", ".git", ".git/x", "extension.toml", "init.lua", "sub", "sub/.hidden", "sub/lib.lua"])
        XCTAssertEqual(try listing(source).map { fm.contents(atPath: source.appendingPathComponent($0).path) }, bytesBefore)
        // The installed entry is the link itself, still pointing at the source.
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: userDir.appendingPathComponent(extID).path), source.path)
    }
}
