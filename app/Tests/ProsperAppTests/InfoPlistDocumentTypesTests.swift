import XCTest
@testable import ProsperApp

/// #1106 (design #1105 D2), #1132: scripts/Info.plist, read from the source tree. Prosper claims
/// plain text only, as an Alternate Viewer, and is never the default: TextEdit's plain-text claim has
/// no rank key (Default). Markdown is not claimed by name (Xcode claims it as Alternate, a tie);
/// Finder offers Prosper for .md and .markdown because the system Markdown type conforms to plain
/// text. No type is imported or exported. The URL types (default-browser picker, prosper://) are
/// unchanged. What Finder then lists is checked by a person in the beta; this file is the gate offscreen.
final class InfoPlistDocumentTypesTests: XCTestCase {

    private var plistURL: URL {
        URL(fileURLWithPath: #filePath)   // …/app/Tests/ProsperAppTests/<this file>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/Info.plist")
    }

    private func plist() throws -> [String: Any] {
        let data = try Data(contentsOf: plistURL)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func documentTypes() throws -> [[String: Any]] {
        try XCTUnwrap(try plist()["CFBundleDocumentTypes"] as? [[String: Any]])
    }

    func testOnlyPlainTextIsClaimedAsAlternateViewer() throws {
        let types = try documentTypes()
        XCTAssertEqual(types.map { $0["LSItemContentTypes"] as? [String] ?? [] }, [["public.plain-text"]])
        XCTAssertEqual(types.map { $0["LSHandlerRank"] as? String }, ["Alternate"],
                       "Owner or Default, or no rank key (counts as Default), would take the user's default app")
        XCTAssertEqual(types.map { $0["CFBundleTypeRole"] as? String }, ["Viewer"])
        XCTAssertEqual(types.map { $0["CFBundleTypeName"] as? String }, ["Plain text document"])
        XCTAssertEqual(Set(types.flatMap(\.keys)),
                       ["CFBundleTypeName", "CFBundleTypeRole", "LSHandlerRank", "LSItemContentTypes"],
                       "no extension or OSType claims beside the content types")
    }

    func testNoDocumentTypeNamesMarkdown() throws {
        let types = try documentTypes()
        let claimed = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertFalse(claimed.contains("net.daringfireball.markdown"), "\(claimed)")
        XCTAssertFalse(claimed.contains(TextViewerRouting.markdownTypeID), "\(claimed)")
        XCTAssertFalse(types.contains { ($0["CFBundleTypeName"] as? String)?.localizedCaseInsensitiveContains("markdown") == true })
    }

    func testNoTypeIsImportedOrExported() throws {
        let p = try plist()
        XCTAssertTrue(p["UTExportedTypeDeclarations"] == nil, "Prosper does not own a type")
        XCTAssertTrue(p["UTImportedTypeDeclarations"] == nil, "the system declares Markdown; routing goes by file name")
    }

    func testPlistLints() throws {
        let lint = Process()
        lint.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        lint.arguments = ["-lint", "-s", plistURL.path]
        try lint.run()
        lint.waitUntilExit()
        XCTAssertEqual(lint.terminationStatus, 0)
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
