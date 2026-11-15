import Foundation
import XCTest
@testable import ProsperApp

/// #1082: every file an extension ships or names (entry Lua, theme.json, host.fs.read, the snippet import,
/// extension.toml) is read through BoundedFileRead: exactly the cap is read, one byte over is refused with a
/// reason naming the file and the limit, and a FIFO is refused without blocking. Every file is in tempDir().
final class ExtensionBoundedReadTests: XCTestCase {

    private static let manifest = """
    [extension]
    id = "com.test.bounded"
    name = "bounded"
    title = "Bounded"
    description = "A test extension"
    version = "1.0.0"
    author = "tester"

    [extension.host]
    min_version = "2.0.0"
    api_level = 1

    [extension.entry]
    main = "init.lua"

    """

    /// `head` then a comment line padding the text to exactly `size` bytes.
    nonisolated private static func padded(_ head: String, to size: Int, comment: String) -> Data {
        let pad = size - head.utf8.count - comment.utf8.count - 1
        precondition(pad >= 0)
        let data = Data((head + comment + String(repeating: "x", count: pad) + "\n").utf8)
        precondition(data.count == size)
        return data
    }

    private func luaEntry(_ size: Int) -> Data {
        Self.padded("function run() return 'ok' end\n", to: size, comment: "-- ")
    }

    /// An extension folder (manifest + init.lua of `size` bytes) loaded as a trusted user extension.
    private func extensionDir(_ dir: URL, entrySize: Int) throws -> LoadedExtension {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(Self.manifest.utf8).write(to: dir.appendingPathComponent("extension.toml"))
        try luaEntry(entrySize).write(to: dir.appendingPathComponent("init.lua"))
        return try ExtensionLoader.load(directory: dir, isSystem: false, hostVersion: "2.0.0")
    }

    private func assertTooLarge(_ error: Error, _ name: String, _ limit: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(error as? BoundedFileRead.Failure, .tooLarge(name, limit: limit), file: file, line: line)
        let text = String(describing: error)
        XCTAssertTrue(text.contains(name) && text.contains("\(limit)-byte size limit"), text, file: file, line: line)
    }

    func testCapsAreTheStatedSizes() {
        XCTAssertEqual(BoundedFileRead.entryLuaMaxBytes, 4_194_304)
        XCTAssertEqual(BoundedFileRead.themeJSONMaxBytes, 1_048_576)
        XCTAssertEqual(BoundedFileRead.fsReadMaxBytes, 1_048_576)
        XCTAssertEqual(BoundedFileRead.snippetImportMaxBytes, 16_777_216)
    }

    // MARK: entry Lua, the two VM spawns

    /// ExtensionRegistry.activate (the main-actor spawn): a 4 194 304-byte entry runs, 4 194 305 is refused.
    @MainActor
    func testActivateRunsAnEntryAtTheCapAndRefusesOneByteOver() throws {
        let tmp = tempDir()
        let reg = ExtensionRegistry(systemDir: nil, userDir: tmp.appendingPathComponent("user"), hostVersion: "2.0.0",
                                    defaults: scratchDefaults("bounded"), services: MCHostServices(makeMCEnv().mc))
        let atCap = ExtensionRecord(loaded: try extensionDir(tmp.appendingPathComponent("cap"), entrySize: 4_194_304),
                                    enabled: true, trusted: true)
        let rt = try reg.activate(atCap)
        XCTAssertEqual(try rt.callGlobal("run", []), "ok")
        let over = ExtensionRecord(loaded: try extensionDir(tmp.appendingPathComponent("over"), entrySize: 4_194_305),
                                   enabled: true, trusted: true)
        XCTAssertThrowsError(try reg.activate(over)) { assertTooLarge($0, "init.lua", 4_194_304) }
        XCTAssertTrue(over.runtime == nil)
    }

    /// AsyncExtensionRuntimes (the off-main lane spawn): at the cap the handler answers, one byte over it gives nil.
    func testLaneRunsAnEntryAtTheCapAndRefusesOneByteOver() async throws {
        let tmp = tempDir()
        let services = MCHostServices(makeMCEnv().mc)
        for (size, expected) in [(4_194_304, "ok" as String?), (4_194_305, nil)] {
            let entry = tmp.appendingPathComponent("init-\(size).lua")
            try luaEntry(size).write(to: entry)
            let spec = AsyncExtensionRuntimes.Spec(extensionID: "com.test.bounded", entryURL: entry, handler: "run",
                                                   callTimeout: 30, privileged: false, trusted: true)
            let got = await AsyncExtensionRuntimes(services: services).invoke(spec, args: [])
            XCTAssertEqual(got, expected, "\(size) bytes")
        }
    }

    // MARK: theme.json, the marketplace preview

    @MainActor
    func testThemePreviewReadsAThemeAtTheCapAndSkipsOneByteOver() throws {
        let ext = tempDir().appendingPathComponent("ext", isDirectory: true)
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        let theme = ThemeContribution(id: "com.test.bounded.theme", title: "Example", path: "theme.json", appearance: "dark")
        let head = ##"{"colors":{"bg":"#101010"},"pad":""##
        for (size, swatches) in [(1_048_576, 1), (1_048_577, 0)] {
            var json = Self.padded(head, to: size - 2, comment: "")
            json.removeLast()   // the padding's newline: the string closes on the same line
            json.append(contentsOf: Data(#""}"#.utf8))
            json.append(contentsOf: Data("\n".utf8))
            XCTAssertEqual(json.count, size)
            try json.write(to: ext.appendingPathComponent("theme.json"))
            let got = ExtensionRow.themePreview(themes: [theme], dir: ext, members: ["./theme.json"])
            XCTAssertEqual(got.preview?.themes.count ?? 0, swatches, "\(size) bytes")
        }
        XCTAssertThrowsError(try BoundedFileRead.data(ext.appendingPathComponent("theme.json"), maxBytes: BoundedFileRead.themeJSONMaxBytes)) {
            assertTooLarge($0, "theme.json", 1_048_576)
        }
    }

    // MARK: host.fs.read

    func testFSReadReturnsAFileAtTheCapAndNilOneByteOver() throws {
        let url = tempDir().appendingPathComponent("notes.txt")
        try Data(repeating: UInt8(ascii: "a"), count: 1_048_576).write(to: url)
        XCTAssertEqual(FSReads.read(url.path)?.utf8.count, 1_048_576)
        try Data(repeating: UInt8(ascii: "a"), count: 1_048_577).write(to: url)
        XCTAssertTrue(FSReads.read(url.path) == nil)
        XCTAssertThrowsError(try BoundedFileRead.text(url, maxBytes: BoundedFileRead.fsReadMaxBytes)) {
            assertTooLarge($0, "notes.txt", 1_048_576)
        }
    }

    // MARK: the helper itself, the snippet import cap and extension.toml

    func testHelperReadsExactlyTheCapAndRefusesOneByteOver() throws {
        let url = tempDir().appendingPathComponent("snippets.json")
        try Data(repeating: UInt8(ascii: " "), count: 16_777_216).write(to: url)
        XCTAssertEqual(try BoundedFileRead.data(url, maxBytes: BoundedFileRead.snippetImportMaxBytes).count, 16_777_216)
        try Data(repeating: UInt8(ascii: " "), count: 16_777_217).write(to: url)
        XCTAssertThrowsError(try BoundedFileRead.text(url, maxBytes: BoundedFileRead.snippetImportMaxBytes)) {
            assertTooLarge($0, "snippets.json", 16_777_216)
        }
        try Data().write(to: url)
        XCTAssertEqual(try BoundedFileRead.text(url, maxBytes: 0), "")
        try Data([0x61]).write(to: url)
        XCTAssertThrowsError(try BoundedFileRead.text(url, maxBytes: 0)) { assertTooLarge($0, "snippets.json", 0) }
        try Data([0x61, 0xFF]).write(to: url)
        XCTAssertThrowsError(try BoundedFileRead.text(url, maxBytes: 2)) {
            XCTAssertEqual($0 as? BoundedFileRead.Failure, .invalidUTF8("snippets.json"))
        }
    }

    /// A folder is refused as not a regular file, a missing path as unreadable; neither is read.
    func testHelperRefusesAFolderAndAMissingPath() {
        let dir = tempDir()
        XCTAssertThrowsError(try BoundedFileRead.data(dir, maxBytes: 16)) {
            XCTAssertEqual($0 as? BoundedFileRead.Failure, .notRegularFile(dir.lastPathComponent))
        }
        XCTAssertThrowsError(try BoundedFileRead.data(dir.appendingPathComponent("missing.lua"), maxBytes: 16)) {
            guard case .unreadable(let why)? = $0 as? BoundedFileRead.Failure else { return XCTFail("\($0)") }
            XCTAssertTrue(why.contains("missing.lua"), why)
        }
    }

    /// QA 787 INFO-1: a refused manifest says which limit it passed.
    func testManifestRefusalNamesTheLimitItPassed() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("extension.toml")
        try Self.padded(Self.manifest, to: 1_048_577, comment: "# ").write(to: url)
        XCTAssertThrowsError(try ExtensionLoader.readManifest(url)) {
            XCTAssertEqual($0 as? ExtensionLoadError, .parse("extension.toml is over the 1048576-byte size limit"))
        }
        let deep = "a = " + String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        XCTAssertEqual(TOMLGuard.refusal(deep), TOMLGuard.Rejected(limit: .depth))
        XCTAssertEqual(String(describing: TOMLGuard.Rejected(limit: .depth)), "TOML rejected: nested deeper than the depth limit of 64")
        XCTAssertEqual(TOMLGuard.refusal(String(repeating: " ", count: 1_048_577)), TOMLGuard.Rejected(limit: .size))
        XCTAssertEqual(String(describing: TOMLGuard.Rejected(limit: .size)), "TOML rejected: over the 1048576-byte size limit")
        XCTAssertEqual(TOMLGuard.refusal("a = \"open"), TOMLGuard.Rejected(limit: .unterminatedString))
        XCTAssertTrue(TOMLGuard.refusal(Self.manifest) == nil)
    }

    // MARK: FIFO rider

    private final class Outcome: @unchecked Sendable { var refused = false }

    /// Runs `read` on a FIFO named `name` (made with mkfifo(2) in tempDir()) on a background queue and waits at most
    /// 1.5 s. A read that blocks fails the row; the stuck open is then released by a non-blocking writer open, which
    /// succeeds only while a reader waits, so the run never hangs. The FIFO is unlinked either way.
    private func assertFIFORefusedWithoutBlocking(_ name: String, _ read: @escaping @Sendable (URL) -> Bool,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        let url = tempDir().appendingPathComponent(name)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0, "mkfifo \(name)", file: file, line: line)
        defer { unlink(url.path) }
        let outcome = Outcome(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            outcome.refused = read(url)
            done.signal()
        }
        guard done.wait(timeout: .now() + 1.5) == .success else {
            XCTFail("\(name): the read blocked on a FIFO", file: file, line: line)
            let writer = open(url.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            _ = done.wait(timeout: .now() + 1)
            return
        }
        XCTAssertTrue(outcome.refused, "\(name) was not refused", file: file, line: line)
    }

    func testAFIFONamedLikeEachFileIsRefusedWithoutBlocking() {
        let start = Date()
        assertFIFORefusedWithoutBlocking("extension.toml") { url in
            do { _ = try ExtensionLoader.readManifest(url); return false } catch {
                guard case ExtensionLoadError.unreadable(let why) = error else { return false }
                return why == "extension.toml is not a regular file"
            }
        }
        assertFIFORefusedWithoutBlocking("init.lua") { url in
            (try? BoundedFileRead.text(url, maxBytes: BoundedFileRead.entryLuaMaxBytes)) == nil
        }
        assertFIFORefusedWithoutBlocking("theme.json") { url in
            do { _ = try BoundedFileRead.data(url, maxBytes: BoundedFileRead.themeJSONMaxBytes); return false } catch {
                return error as? BoundedFileRead.Failure == .notRegularFile("theme.json")
            }
        }
        assertFIFORefusedWithoutBlocking("notes.txt") { url in FSReads.read(url.path) == nil }
        assertFIFORefusedWithoutBlocking("snippets.json") { url in
            (try? BoundedFileRead.text(url, maxBytes: BoundedFileRead.snippetImportMaxBytes)) == nil
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "five FIFO reads, none of them waits")
    }
}
