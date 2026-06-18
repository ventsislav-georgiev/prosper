import XCTest
@testable import ProsperApp

final class ExternalConfigScannerTests: XCTestCase {
    private func writeTemp(_ name: String, _ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdtest-\(UUID().uuidString)-\(name)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTomlSingleLinePromptWithArgs() {
        let url = writeTemp("caveman.toml",
            "description = \"x\"\nprompt = \"Switch to caveman {{args}} mode.\"\n")
        let parsed = ExternalConfigScanner.commandBody(url)
        XCTAssertTrue(parsed?.name.hasSuffix("caveman") ?? false)
        XCTAssertEqual(parsed?.body, "Switch to caveman $ARGUMENTS mode.")
    }

    func testTomlTripleQuotedPrompt() {
        let url = writeTemp("multi.toml",
            "prompt = \"\"\"\nline one\nline two\n\"\"\"\n")
        XCTAssertEqual(ExternalConfigScanner.commandBody(url)?.body, "line one\nline two")
    }

    func testMarkdownBodyVerbatim() {
        let url = writeTemp("note.md", "# Title\nDo the thing.")
        XCTAssertEqual(ExternalConfigScanner.commandBody(url)?.body, "# Title\nDo the thing.")
    }

    func testTomlWithoutPromptReturnsNil() {
        let url = writeTemp("nope.toml", "description = \"only\"\n")
        XCTAssertNil(ExternalConfigScanner.commandBody(url))
    }
}
