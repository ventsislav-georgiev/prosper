import XCTest
@testable import ProsperApp

/// Unit tests for the quickdir action template — the pure substitution logic that
/// turns a config + selected directory into the command/URL that gets run. No
/// storage or filesystem side effects.
final class QuickdirStoreTests: XCTestCase {

    private func config(action: String) -> QuickdirConfig {
        QuickdirConfig(name: "payhawk", path: "~/work/payhawk", prefix: "p",
                       action: action, actionLabel: "Open")
    }

    func testShellActionSubstitutesRawTokens() {
        let c = config(action: "code {path}")
        let out = QuickdirStore.resolvedAction(
            c, dirPath: "/Users/me/work/payhawk/api gateway", dirName: "api gateway", query: "")
        // Shell template: tokens substituted verbatim (no URL-encoding).
        XCTAssertEqual(out, "code /Users/me/work/payhawk/api gateway")
    }

    func testShellActionSubstitutesNameAndQuery() {
        let c = config(action: "echo {name}::{query}")
        let out = QuickdirStore.resolvedAction(
            c, dirPath: "/x/api", dirName: "api", query: "build now")
        XCTAssertEqual(out, "echo api::build now")
    }

    func testURLActionPercentEncodesTokens() {
        let c = config(action: "https://example.com/?repo={name}&q={query}")
        let out = QuickdirStore.resolvedAction(
            c, dirPath: "/x/api gateway", dirName: "api gateway", query: "a b")
        // URL template: spaces (and other reserved chars) percent-encoded.
        XCTAssertEqual(out, "https://example.com/?repo=api%20gateway&q=a%20b")
    }

    func testCaseInsensitiveTokenForms() {
        let c = config(action: "open {Path} {NAME}")
        let out = QuickdirStore.resolvedAction(
            c, dirPath: "/x/api", dirName: "api", query: "")
        // {Path}/{Name} are accepted in addition to lowercase forms; an
        // all-caps {NAME} is not a recognized token and is left untouched.
        XCTAssertEqual(out, "open /x/api {NAME}")
    }
}
