import Foundation
import XCTest
@testable import ProsperApp

/// QA 787 F1 (#883): ExtensionRegistry.manifestVersion (seeding and the GitHub auto-update
/// path) reads extension.toml through ExtensionLoader.readManifest, so a file over
/// TOMLGuard.maxBytes gives nil instead of being read whole into memory.
@MainActor
final class ExtensionManifestVersionTests: XCTestCase {

    private let versionLine = "version = \"2.4.1\"\n"

    /// Writes `bytes` as dir/extension.toml in one write and returns dir.
    private func extDir(_ bytes: Data, _ label: String = #function) throws -> URL {
        let dir = tempDir(label)
        try bytes.write(to: dir.appendingPathComponent("extension.toml"))
        return dir
    }

    /// The version line at the top, padded with one comment line to exactly `size` bytes.
    private func padded(to size: Int) -> Data {
        let head = versionLine + "#"
        let data = Data((head + String(repeating: "x", count: size - head.utf8.count)).utf8)
        XCTAssertEqual(data.count, size)
        return data
    }

    private func assertVersion(_ v: SemanticVersion?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(v?.major == 2 && v?.minor == 4 && v?.patch == 1,
                      "expected 2.4.1, got \(String(describing: v))", file: file, line: line)
    }

    func testOrdinaryManifestGivesItsVersion() throws {
        let toml = """
        [extension]
        id = "example.hello"
        name = "Hello"
        version = "2.4.1"
        host = ">=1.0.0"

        [extension.entry]
        main = "init.lua"
        """
        assertVersion(ExtensionRegistry.manifestVersion(at: try extDir(Data(toml.utf8))))
    }

    func testOneByteOverTheCapGivesNil() throws {
        let dir = try extDir(padded(to: TOMLGuard.maxBytes + 1))
        XCTAssertTrue(ExtensionRegistry.manifestVersion(at: dir) == nil)
    }

    func testExactlyTheCapGivesTheVersion() throws {
        assertVersion(ExtensionRegistry.manifestVersion(at: try extDir(padded(to: TOMLGuard.maxBytes))))
    }

    func testMissingFileGivesNil() {
        XCTAssertTrue(ExtensionRegistry.manifestVersion(at: tempDir()) == nil)
    }

    func testInvalidUTF8GivesNil() throws {
        let dir = try extDir(Data(versionLine.utf8) + Data([0xFF, 0xFE, 0x80]))
        XCTAssertTrue(ExtensionRegistry.manifestVersion(at: dir) == nil)
    }
}
