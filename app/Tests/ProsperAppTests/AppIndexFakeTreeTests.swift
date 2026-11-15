import XCTest
@testable import ProsperApp

extension XCTestCase {
    /// A fake application folder under tempDir(): `<name>.app/Contents/Info.plist` with a
    /// com.example.* id. Rows scan this instead of the real application folders.
    func fakeAppsDir(_ names: [String], _ label: String = #function) -> URL {
        let root = tempDir(label)
        for name in names {
            let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let id = "com.example." + name.lowercased().filter { $0.isLetter || $0.isNumber }
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: contents.appendingPathComponent("Info.plist"))
            }
        }
        return root
    }
}

/// `AppIndex.scan` reads CFBundleIdentifier from Info.plist and never creates a Bundle.
final class AppIndexFakeTreeTests: XCTestCase {
    private func scanned(_ root: URL) -> [AppEntry] {
        AppIndex.scan(dirs: [root.path], nested: [], extraPaths: [])
    }

    func testScanLeavesNoBundleRegisteredUnderTheTree() {
        let root = fakeAppsDir(["Alpha", "Beta"])
        XCTAssertEqual(scanned(root).count, 2)
        let prefixes = [root.path, root.resolvingSymlinksInPath().path]
        let leaked = Bundle.allBundles.filter { b in
            let p = b.bundleURL.path
            return prefixes.contains { p.hasPrefix($0) }
        }
        XCTAssertTrue(leaked.isEmpty, "scan registered \(leaked.count) bundle(s) in Bundle.allBundles")
    }

    func testScanReadsIdAndNameLikeTheBundleDid() {
        let root = fakeAppsDir(["Alpha Tool"])
        let found = scanned(root)
        XCTAssertEqual(found.first?.bundleId, "com.example.alphatool")
        XCTAssertEqual(found.first?.name, "Alpha Tool", "name still comes from the file name")
        XCTAssertEqual(found.first?.url.path, root.appendingPathComponent("Alpha Tool.app").path)
    }

    func testMissingOrMalformedPlistKeepsTheEntryWithNoId() throws {
        let root = fakeAppsDir(["Good", "Bad"])
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("NoPlist.app"), withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: root.appendingPathComponent("Bad.app/Contents/Info.plist"))
        let big = root.appendingPathComponent("Big.app/Contents")
        try fm.createDirectory(at: big, withIntermediateDirectories: true)
        try Data(count: AppIndex.maxInfoPlistBytes + 1).write(to: big.appendingPathComponent("Info.plist"))
        let ids = Dictionary(uniqueKeysWithValues: scanned(root).map { ($0.name, $0.bundleId) })
        XCTAssertEqual(Set(ids.keys), ["Good", "Bad", "NoPlist", "Big"])
        XCTAssertEqual(ids["Good"] ?? nil, "com.example.good")
        XCTAssertTrue((ids["Bad"] ?? nil) == nil)
        XCTAssertTrue((ids["NoPlist"] ?? nil) == nil)
        XCTAssertTrue((ids["Big"] ?? nil) == nil, "an oversized plist is not parsed")
    }

    /// No row of the three index consumers scans the default (real) roots.
    func testNoRowScansTheDefaultRoots() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let banned = "AppIndex." + "scan()"
        for f in ["AppIndexTests", "AppShortcutTests", "AppPickerMenuTests"] {
            let text = try String(contentsOf: dir.appendingPathComponent("\(f).swift"), encoding: .utf8)
            XCTAssertFalse(text.contains(banned), "\(f) scans the real application folders")
            XCTAssertFalse(text.contains("ensureBuilt()") && !text.contains("install(apps:"),
                           "\(f) builds the shared index without a fake tree")
        }
    }
}
