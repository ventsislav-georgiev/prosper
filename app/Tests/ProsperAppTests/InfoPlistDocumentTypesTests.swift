import XCTest
@testable import ProsperApp

/// #1106 (design #1105 D2): scripts/Info.plist, read from the source tree. Prosper is offered in
/// Finder's Open With menu for Markdown and plain text and is never the default: exactly two
/// document types, both Alternate; the Markdown type imported, never exported; the URL types
/// (default-browser picker, prosper://) unchanged. What Finder then lists is checked by a person
/// in the beta; this file is the gate offscreen.
final class InfoPlistDocumentTypesTests: XCTestCase {

    private func plist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)   // …/app/Tests/ProsperAppTests/<this file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTwoAlternateViewerDocumentTypes() throws {
        let types = try XCTUnwrap(try plist()["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(types.count, 2)
        XCTAssertEqual(types.map { $0["LSItemContentTypes"] as? [String] ?? [] },
                       [["net.daringfireball.markdown"], ["public.plain-text"]])
        XCTAssertEqual(types.map { $0["LSHandlerRank"] as? String }, ["Alternate", "Alternate"],
                       "Owner or Default would take the user's default app")
        XCTAssertEqual(types.map { $0["CFBundleTypeRole"] as? String }, ["Viewer", "Viewer"])
        XCTAssertEqual(types.map { $0["CFBundleTypeName"] as? String }, ["Markdown document", "Plain text document"])
        XCTAssertEqual(Set(types.flatMap(\.keys)),
                       ["CFBundleTypeName", "CFBundleTypeRole", "LSHandlerRank", "LSItemContentTypes"],
                       "no extension or OSType claims beside the content types")
    }

    func testMarkdownTypeIsImportedNotExported() throws {
        let p = try plist()
        XCTAssertTrue(p["UTExportedTypeDeclarations"] == nil, "Prosper does not own a type")
        let imported = try XCTUnwrap(p["UTImportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertEqual(imported.count, 1)
        let md = try XCTUnwrap(imported.first)
        XCTAssertEqual(md["UTTypeIdentifier"] as? String, TextViewerRouting.markdownTypeID)
        XCTAssertEqual(md["UTTypeConformsTo"] as? [String], ["public.plain-text"])
        let tags = try XCTUnwrap(md["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["md", "markdown", "mdown", "mkd"])
        XCTAssertEqual(tags["public.mime-type"] as? [String], ["text/markdown"])
        XCTAssertEqual(Set(tags["public.filename-extension"] as? [String] ?? []), TextViewerRouting.markdownExtensions)
    }

    func testURLTypesUnchanged() throws {
        let urlTypes = try XCTUnwrap(try plist()["CFBundleURLTypes"] as? NSArray)
        let expected: NSArray = [
            ["CFBundleURLName": "Web URL", "CFBundleTypeRole": "Viewer", "CFBundleURLSchemes": ["http", "https"]],
            ["CFBundleURLName": "Prosper Control", "CFBundleTypeRole": "Viewer", "CFBundleURLSchemes": ["prosper"]],
        ]
        XCTAssertEqual(urlTypes, expected)
    }
}
