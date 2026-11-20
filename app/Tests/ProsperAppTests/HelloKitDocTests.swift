import Foundation
import XCTest
@testable import ProsperApp

// #919 S6: the "Agent Kits" chapter of extensions.md is pinned to the code. Reads two repository files, writes nothing.

final class HelloKitDocTests: XCTestCase {
    /// the repository root, from this file's place in the tree (app/Tests/ProsperAppTests/)
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// the chapter: from its "## 12. Agent Kits" heading to the next level-2 heading or the end
    private func chapter() throws -> String {
        let all = try String(contentsOf: Self.root.appendingPathComponent("extensions.md"), encoding: .utf8)
        let lines = all.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "## 12. Agent Kits") else { XCTFail("no Agent Kits chapter"); return "" }
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
        return lines[start..<end].joined(separator: "\n")
    }

    func testTheChaptersFencedManifestIsTheExamplesFileByteForByte() throws {
        let lines = try chapter().components(separatedBy: "\n")
        guard let open = lines.firstIndex(of: "```toml") else { return XCTFail("no toml fence") }
        let close = lines[(open + 1)...].firstIndex(of: "```") ?? lines.count
        let quoted = lines[(open + 1)..<close].joined(separator: "\n") + "\n"
        let file = Self.root.appendingPathComponent("app/Examples/kits/hello-kit/extension.toml")
        XCTAssertTrue(Data(quoted.utf8) == (try Data(contentsOf: file)), "the quoted manifest differs from the example's extension.toml")
    }

    func testEveryPieceKindIsARowOfTheKindTable() throws {
        let rows = try chapter().components(separatedBy: "\n")
        for kind in KitManifest.Piece.Kind.allCases {
            XCTAssertTrue(rows.contains { $0.hasPrefix("| `\(kind.rawValue)` |") }, "no kind table row for \(kind.rawValue)")
        }
    }

    /// OQ-193: the chapter's env allowlist names exactly the keys the code allows.
    func testTheChaptersEnvAllowlistIsTheCodes() throws {
        let line = try XCTUnwrap(try chapter().components(separatedBy: "\n").first { $0.hasPrefix("- **Env allowlist") })
        let listed = Set(line.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            .filter { $0.allSatisfy { $0.isUppercase || $0 == "_" } })
        XCTAssertEqual(listed, Set(ManagedConfigPlanner.envKeys))
        XCTAssertEqual(ManagedConfigPlanner.envKeys.count, 13, "OQ-193 approved 13 keys")
    }

    func testEveryReadmeHeadingIsInTheChapter() throws {
        let text = try chapter()
        for h in KitValidator.readmeHeadings { XCTAssertTrue(text.contains("## \(h)"), "chapter lacks the heading \(h)") }
    }
}
