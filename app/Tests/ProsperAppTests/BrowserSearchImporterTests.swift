import Foundation
import SQLite3
import XCTest
@testable import ProsperApp

/// #211: a Chromium `Web Data` that is there but cannot be copied or opened (a macOS
/// privacy/XProtect denial, corruption) is reported once; a browser that is not
/// installed stays silent; a good copy imports as before. Fakes only: every file is
/// under the test's own tempDir(), never a real browser profile.
final class BrowserSearchImporterTests: XCTestCase {

    private struct Fixture {
        let webData: URL
        let copies: URL
    }

    /// <dir>/Default/Web Data (not created) and an empty <dir>/tmp for the private copy.
    private func fixture() throws -> Fixture {
        let dir = tempDir()
        let profile = dir.appendingPathComponent("Default", isDirectory: true)
        let copies = dir.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        return Fixture(webData: profile.appendingPathComponent("Web Data"), copies: copies)
    }

    private func run(_ f: Fixture) -> (providers: [FallbackProvider], reports: [String]) {
        var reports: [String] = []
        let providers = BrowserSearchImporter.chromiumProviders(webData: f.webData, tempDir: f.copies) {
            reports.append($0)
        }
        return (providers, reports)
    }

    private func leftovers(_ f: Fixture) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: f.copies.path)) ?? ["unreadable"]
    }

    func testUnreadableWebDataReportsTheCopyFailureOnce() throws {
        let f = try fixture()
        try Data("SQLite format 3\0".utf8).write(to: f.webData)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.webData.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.webData.path) }

        let r = run(f)
        XCTAssertTrue(r.providers.isEmpty)
        XCTAssertEqual(r.reports.count, 1, "\(r.reports)")
        let line = r.reports.first ?? ""
        XCTAssertTrue(line.contains("Default/Web Data copy failed"), line)
        XCTAssertFalse(line.contains(f.copies.deletingLastPathComponent().path), "never the full path: \(line)")
        XCTAssertEqual(leftovers(f), [])
    }

    /// A denial that already fails the stat (a privacy-protected profile dir; here a dir
    /// with no search permission) must not pass for "not installed": no fileExists pre-check.
    func testUnsearchableProfileDirReportsTheCopyFailureOnce() throws {
        let f = try fixture()
        try Data("SQLite format 3\0".utf8).write(to: f.webData)
        let profile = f.webData.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: profile)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profile) }

        let r = run(f)
        XCTAssertTrue(r.providers.isEmpty)
        XCTAssertEqual(r.reports.count, 1, "\(r.reports)")
        XCTAssertTrue((r.reports.first ?? "").contains("Default/Web Data copy failed"), "\(r.reports)")
    }

    func testMissingWebDataIsSilent() throws {
        let f = try fixture()
        let r = run(f)
        XCTAssertTrue(r.providers.isEmpty)
        XCTAssertEqual(r.reports, [], "a browser that is not installed says nothing")
    }

    func testMissingProfileDirIsSilent() throws {
        let f = try fixture()
        let gone = Fixture(webData: f.webData.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Absent/Web Data"), copies: f.copies)
        let r = run(gone)
        XCTAssertTrue(r.providers.isEmpty)
        XCTAssertEqual(r.reports, [])
    }

    func testCorruptWebDataReportsOnce() throws {
        let f = try fixture()
        try Data("not a database, just text that is long enough to be read".utf8).write(to: f.webData)
        let r = run(f)
        XCTAssertTrue(r.providers.isEmpty)
        XCTAssertEqual(r.reports.count, 1, "\(r.reports)")
        XCTAssertTrue((r.reports.first ?? "").contains("Default/Web Data"), "\(r.reports)")
        XCTAssertEqual(leftovers(f), [])
    }

    func testGoodWebDataImportsAndReportsNothing() throws {
        let f = try fixture()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.webData.path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE keywords (short_name TEXT, url TEXT);
            INSERT INTO keywords VALUES ('Example Search', 'https://search.example.com/?q={searchTerms}');
            INSERT INTO keywords VALUES ('Extension', 'chrome-extension://abc/?q={searchTerms}');
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let r = run(f)
        XCTAssertEqual(r.reports, [])
        XCTAssertEqual(r.providers, [FallbackProvider(id: "example-search", name: "Example Search",
                                                      urlTemplate: "https://search.example.com/?q={query}",
                                                      enabled: true, titleTemplate: nil)])
        XCTAssertEqual(leftovers(f), [], "the private copy is removed")
    }
}
