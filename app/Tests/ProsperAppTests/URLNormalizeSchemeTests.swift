import XCTest
@testable import ProsperApp

final class URLNormalizeSchemeTests: XCTestCase {
    func testBareDomainGetsHTTPS() {
        XCTAssertEqual(URLServices.normalizeScheme("github.com"), "https://github.com")
        XCTAssertEqual(URLServices.normalizeScheme("github.com/foo?a=1"), "https://github.com/foo?a=1")
    }

    func testSchemedURLsUntouched() {
        XCTAssertEqual(URLServices.normalizeScheme("https://github.com"), "https://github.com")
        XCTAssertEqual(URLServices.normalizeScheme("http://x.com"), "http://x.com")
        XCTAssertEqual(URLServices.normalizeScheme("mailto:a@b.com"), "mailto:a@b.com")
        XCTAssertEqual(URLServices.normalizeScheme("file:///tmp/x"), "file:///tmp/x")
    }

    func testEmptyUntouched() {
        XCTAssertEqual(URLServices.normalizeScheme(""), "")
    }
}
