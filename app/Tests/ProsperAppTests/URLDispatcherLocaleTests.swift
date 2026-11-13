import Foundation
import XCTest

/// #1021 r3: Lua's lower() and its % classes follow the process LC_CTYPE. Under any value but "C" (the app's,
/// and the full suite's once something sets it) tolower turns the UTF-8 lead byte C3 into E3, so the
/// url-dispatcher IDN rules failed in the full suite and passed in a filter run, which stays in "C".
/// This runs url-dispatcher.test.lua through the ExtensionLuaSuiteTests driver under both.
final class URLDispatcherLocaleTests: XCTestCase {
    func testURLDispatcherLuaFilePassesUnderUTF8AndCLocales() throws {
        let root = try XCTUnwrap(ExtensionLuaSuiteTests.repoRoot())
        let file = root.appendingPathComponent(
            "app/Sources/ProsperApp/Resources/extensions/url-dispatcher/url-dispatcher.test.lua").path
        let harness = root.appendingPathComponent("scripts/ext-test").path
        // Copied now: the pointer setlocale returns is reused by the next call.
        let saved = try XCTUnwrap(setlocale(LC_CTYPE, nil).map { String(cString: $0) })
        defer { setlocale(LC_CTYPE, saved) }
        for locale in ["en_US.UTF-8", "C"] {
            // A leg that silently ran in "C" would pin nothing.
            guard setlocale(LC_CTYPE, locale) != nil else { throw XCTSkip("LC_CTYPE \(locale) is not available") }
            XCTAssertEqual(runLuaTestFile(file, harnessDir: harness), .passed, "url-dispatcher.test.lua under LC_CTYPE \(locale)")
        }
    }
}
