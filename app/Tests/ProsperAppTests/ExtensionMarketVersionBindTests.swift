import XCTest
@testable import ProsperApp

/// No-op host services: no native side effects.
private final class NoopServices: ExtensionHostServices, @unchecked Sendable {
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

/// R1182-g: the market binding also requires the archive's own version to be the listing version it was asked for.
/// Every row calls bindMarketIdentity directly on a folder inside its own tempDir(), with a registry whose folders
/// are in that tempDir(); nothing is fetched or installed.
@MainActor
final class ExtensionMarketVersionBindTests: XCTestCase {
    private let fm = FileManager.default

    private func rig(version: String, id: String = "com.example.kit") throws -> (ExtensionRegistry, URL) {
        let tmp = tempDir()
        let ext = tmp.appendingPathComponent("market", isDirectory: true)
        try fm.createDirectory(at: ext, withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(id)"
        name = "kit"
        title = "Kit"
        description = "A test extension"
        version = "\(version)"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: ext.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- noop".write(to: ext.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let reg = ExtensionRegistry(systemDir: nil, userDir: tmp.appendingPathComponent("user", isDirectory: true),
                                    hostVersion: "2.0.0", defaults: scratchDefaults("ext-market-version"),
                                    services: NoopServices())
        return (reg, ext)
    }

    private func versionError(_ reg: ExtensionRegistry, _ ext: URL, listed: String?,
                              expected id: String = "com.example.kit") -> ExtensionError? {
        do {
            try reg.bindMarketIdentity(extDir: ext, expected: id, expectedVersion: listed)
            return nil
        } catch {
            return error as? ExtensionError ?? .notFound("not an ExtensionError: \(error)")
        }
    }

    func testEqualVersionPasses() throws {
        let (reg, ext) = try rig(version: "1.0.0")
        XCTAssertTrue(versionError(reg, ext, listed: "1.0.0") == nil)
        // No listing version (the GitHub update path): no version check.
        XCTAssertTrue(versionError(reg, ext, listed: nil) == nil)
    }

    func testLowerArchiveVersionIsRefused() throws {
        let (reg, ext) = try rig(version: "1.0.0")
        let error = versionError(reg, ext, listed: "1.1.0")
        XCTAssertEqual(error, .marketVersionMismatch(id: "com.example.kit", listed: "1.1.0", got: "1.0.0"))
        XCTAssertEqual(error?.errorDescription,
                       "Not installed: the package's files declare version \"1.0.0\", but the Marketplace lists version "
                       + "\"1.1.0\" for com.example.kit. Nothing was changed.")
    }

    func testHigherArchiveVersionIsRefused() throws {
        let (reg, ext) = try rig(version: "2.0.0")
        XCTAssertEqual(versionError(reg, ext, listed: "1.9.9"),
                       .marketVersionMismatch(id: "com.example.kit", listed: "1.9.9", got: "2.0.0"))
    }

    /// SemanticVersion's equality decides whenever the listing is plain (R1182-l: the archive's text need not be);
    /// a listing that is not plain is never refused.
    func testSpellingsAndUnreadableVersions() throws {
        let table: [(archive: String, listed: String, refused: Bool)] = [
            ("1.2", "1.2.0", false),
            ("1.2.0", "1.2", false),
            ("1", "1.0.0", false),
            ("01.2.0", "1.2.0", false),
            ("2.0.0-beta", "2.0.0", false),
            ("2.0.0+build.7", "2.0.0", false),
            ("2.0.0", "2.0.0-rc.1", false),
            ("1.2.1", "1.2.0", true),
            ("1.2", "1.2.1", true),
            ("2.0.0-beta", "2.0.1", true),
            ("0.9.0", "1.0.0", true),
            ("v1.2.0", "1.3.0", true),
            ("abc", "1.0.0", true),
            ("", "1.0.0", true),
            ("1.0.0", "latest", false),
            ("1.2.0.9", "1.3.0", true),
            ("1.0.1\\n", "1.0.1", true),    // a TOML escape: the archive's version ends in a line feed
            (" 1.2.0", "1.2.0", true),      // reads 0.2.0: the server lists it trimmed, so it would be fetched again
            ("1.2.0.9", "1.2.0", false),    // not plain, but read as the listing's version
            ("v1.2.0", "0.2.0", false),
        ]
        XCTAssertEqual(table.count, 20)
        XCTAssertEqual(table.filter(\.refused).count, 10)
        for row in table {
            let (reg, ext) = try rig(version: row.archive)
            let error = versionError(reg, ext, listed: row.listed)
            if row.refused {
                if case .marketVersionMismatch = error {} else {
                    XCTFail("\(row.archive) against \(row.listed): expected a version refusal, got \(String(describing: error))")
                }
            } else {
                XCTAssertTrue(error == nil, "\(row.archive) against \(row.listed): \(String(describing: error))")
            }
        }
    }

    func testIdIsCheckedBeforeTheVersion() throws {
        let (reg, ext) = try rig(version: "1.0.0")
        XCTAssertEqual(versionError(reg, ext, listed: "9.9.9", expected: "com.example.other"),
                       .marketIdMismatch(expected: "com.example.other", got: "com.example.kit"))
    }

    func testShownTextIsCleanedAndBounded() throws {
        let tail = String(repeating: "a", count: 100)
        let (reg, ext) = try rig(version: "1.0.0-\u{202E}x\u{200B}" + tail)
        let error = versionError(reg, ext, listed: "1.0.1+\u{202E}b\u{200B}")
        let shownGot = "1.0.0-x" + String(repeating: "a", count: 24) + "\u{2026}"
        XCTAssertEqual(error, .marketVersionMismatch(id: "com.example.kit", listed: "1.0.1+b", got: shownGot))
        let texts = [error?.errorDescription ?? "", String(describing: error)]
        for text in texts {
            XCTAssertFalse(text.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{200B}" }, text)
            XCTAssertLessThanOrEqual(text.count, 220, text)
        }
    }

    func testRefusalLeavesTheFolderUnchanged() throws {
        let (reg, ext) = try rig(version: "1.0.0")
        let root = ext.deletingLastPathComponent()
        func listing() throws -> [String: Data] {
            var out: [String: Data] = [:]
            for path in try fm.subpathsOfDirectory(atPath: root.path) {
                let url = root.appendingPathComponent(path)
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
                out[path] = isDir.boolValue ? Data() : try Data(contentsOf: url)
            }
            return out
        }
        let before = try listing()
        XCTAssertNotNil(before["market/extension.toml"])
        XCTAssertEqual(versionError(reg, ext, listed: "1.1.0"),
                       .marketVersionMismatch(id: "com.example.kit", listed: "1.1.0", got: "1.0.0"))
        XCTAssertEqual(try listing(), before)
    }

    /// R1182-m: an id mismatch reads as a sentence, not the enum text; the case's values stay as they were.
    func testIdMismatchReadsAsASentence() throws {
        let (reg, ext) = try rig(version: "1.0.0")
        let error = versionError(reg, ext, listed: "1.0.0", expected: "com.example.other")
        XCTAssertEqual(error, .marketIdMismatch(expected: "com.example.other", got: "com.example.kit"))
        XCTAssertEqual(error?.errorDescription,
                       "Not installed: the package's files declare the id \"com.example.kit\", but the Marketplace lists it as "
                       + "\"com.example.other\". Nothing was changed.")
    }

    /// R1182-m: both ids are outside data: the sentence drops a direction override and a zero-width space and cuts each id at 128.
    func testIdMismatchTextIsCleanedAndBounded() throws {
        let got = "com.example.\u{202E}kit\u{200B}" + String(repeating: "a", count: 200)
        let (reg, ext) = try rig(version: "1.0.0", id: got)
        let error = versionError(reg, ext, listed: "1.0.0", expected: "com.example.\u{202E}other\u{200B}")
        XCTAssertEqual(error, .marketIdMismatch(expected: "com.example.\u{202E}other\u{200B}", got: got))
        let shownGot = "com.example.kit" + String(repeating: "a", count: 112) + "\u{2026}"
        XCTAssertEqual(error?.errorDescription,
                       "Not installed: the package's files declare the id \"\(shownGot)\", but the Marketplace lists it as "
                       + "\"com.example.other\". Nothing was changed.")
        let text = error?.errorDescription ?? ""
        XCTAssertFalse(text.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{200B}" }, text)
    }
}
