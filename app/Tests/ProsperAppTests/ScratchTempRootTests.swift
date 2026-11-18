import XCTest

/// #1508: pins the TMPDIR rule of testTempRoot through its pure seam.
final class ScratchTempRootTests: XCTestCase {
    private let fallback = URL(fileURLWithPath: "/Users/example/fallback", isDirectory: true)

    func testAbsoluteTmpdirIsHonoured() {
        let r = tempRoot(environment: ["TMPDIR": "/Users/example/shard-1/"], fallback: fallback)
        XCTAssertEqual(r.standardizedFileURL.path, "/Users/example/shard-1")
    }

    func testUnsetEmptyAndRelativeTmpdirFallBack() {
        XCTAssertEqual(tempRoot(environment: [:], fallback: fallback), fallback)
        XCTAssertEqual(tempRoot(environment: ["TMPDIR": ""], fallback: fallback), fallback)
        XCTAssertEqual(tempRoot(environment: ["TMPDIR": "tmp/x"], fallback: fallback), fallback)
    }

    func testRealRootStillEndsInProsperTests() {
        XCTAssertEqual(testTempRoot.lastPathComponent, "prosper-tests")
    }
}
