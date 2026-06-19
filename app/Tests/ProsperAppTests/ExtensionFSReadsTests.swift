import XCTest
@testable import ProsperApp

final class ExtensionFSReadsTests: XCTestCase {

    private func tempDir() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-fsreads-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testExists() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try! "hello".data(using: .utf8)!.write(to: file)

        XCTAssertTrue(FSReads.exists(file.path))
        XCTAssertTrue(FSReads.exists(dir.path))
        XCTAssertFalse(FSReads.exists(dir.appendingPathComponent("nope").path))
    }

    func testAttributesForFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "hello".data(using: .utf8)!.write(to: file)

        let json = FSReads.attributesJSON(file.path)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["exists"] as? Bool, true)
        XCTAssertEqual(obj["isDir"] as? Bool, false)
        XCTAssertEqual(obj["size"] as? Int, 5)
        XCTAssertNotNil(obj["mtime"]) // epoch seconds, present
    }

    func testAttributesForDirectory() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = FSReads.attributesJSON(dir.path)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["exists"] as? Bool, true)
        XCTAssertEqual(obj["isDir"] as? Bool, true)
    }

    func testAttributesForMissingPath() throws {
        let json = FSReads.attributesJSON("/no/such/path/here-xyz")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["exists"] as? Bool, false)
    }
}
