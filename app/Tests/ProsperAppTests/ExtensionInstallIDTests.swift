import XCTest
@testable import ProsperApp

/// No-op host services: no native side effects.
private final class NoopServices: ExtensionHostServices, @unchecked Sendable {
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
}

/// #1246: the id an extension is installed under, and which folder is a system record. Every registry here
/// lives wholly inside the row's own tempDir(); the path-shaped ids go through the pure rule only.
@MainActor
final class ExtensionInstallIDTests: XCTestCase {
    private let fm = FileManager.default
    private let canaryBytes = Data([0x00, 0x01, 0xFE]) + Data("canary".utf8)

    private func writeExt(_ dir: URL, id: String, title: String = "Kit", version: String = "1.0.0") throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(id)"
        name = "kit"
        title = "\(title)"
        description = "A test extension"
        version = "\(version)"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- noop".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    }

    /// A registry whose bundled dir holds one built-in, `folder` declaring com.prosper.files; trust key present
    /// (empty), so nothing is grandfathered as trusted.
    private func rig(_ tmp: URL, builtInFolder folder: String = "files") throws -> (ExtensionRegistry, URL) {
        let sys = tmp.appendingPathComponent("system", isDirectory: true)
        let user = tmp.appendingPathComponent("user", isDirectory: true)
        try writeExt(sys.appendingPathComponent(folder, isDirectory: true), id: "com.prosper.files", title: "Files")
        let defaults = scratchDefaults("ext-install-id")
        defaults.set([String](), forKey: "trustedExtensionIDs")
        let reg = ExtensionRegistry(systemDir: sys, userDir: user, hostVersion: "2.0.0", defaults: defaults,
                                    services: NoopServices())
        return (reg, user)
    }

    private func refused(_ expr: @autoclosure () throws -> ExtensionRecord, contains words: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) { error in
            let reason = (error as? ExtensionInstallID.Refused)?.reason ?? "not a refusal: \(error)"
            XCTAssertTrue(reason.contains(words), reason, file: file, line: line)
            XCTAssertTrue(reason.contains("Nothing was changed"), reason, file: file, line: line)
        }
    }

    // MARK: - the pure rule

    func testRuleOnLiteralIDs() {
        let folders: Set<String> = ["files", "theme-amber"]
        let ids: Set<String> = ["com.prosper.files", "com.prosper.theme.amber"]
        let form = "single name", builtIn = "built into Prosper"
        let table: [(id: String, refusedFor: String?)] = [
            ("com.example.kit", nil),
            ("COM.Example.Kit", nil),
            ("com.example.kit-2", nil),
            ("com.example.my_kit", nil),
            ("examplekit", nil),
            ("com.prosper.filesx", nil),
            ("com.prosper.theme", nil),
            ("files.example", nil),
            ("..kit", nil),
            (String(repeating: "a", count: 128), nil),
            (String(repeating: "a", count: 129), form),
            ("", form),
            (".", form),
            ("..", form),
            ("....", form),
            ("com.example/kit", form),
            ("../kit", form),
            ("kit/..", form),
            ("/Users/example", form),
            ("~", form),
            ("com.example\\kit", form),
            ("com.example kit", form),
            ("com.example.kit\n", form),
            ("com.example\u{0}kit", form),
            ("com.example.k\u{00EF}t", form),
            ("files", builtIn),
            ("FILES", builtIn),
            ("Files", builtIn),
            ("theme-amber", builtIn),
            ("Theme-Amber", builtIn),
            ("com.prosper.files", builtIn),
            ("COM.PROSPER.FILES", builtIn),
            ("com.prosper.theme.amber", builtIn),
            ("Com.Prosper.Theme.Amber", builtIn),
        ]
        for row in table {
            let why = ExtensionInstallID.refusal(row.id, bundledFolders: folders, bundledIDs: ids)
            if let words = row.refusedFor {
                XCTAssertTrue(why?.contains(words) == true, "\(row.id.debugDescription): \(why ?? "accepted")")
            } else {
                XCTAssertTrue(why == nil, "\(row.id.debugDescription): \(why ?? "")")
            }
        }
        // No bundled names given (a registry with no bundled dir): only the form rule is left.
        XCTAssertTrue(ExtensionInstallID.refusal("files", bundledFolders: [], bundledIDs: []) == nil)
        XCTAssertTrue(ExtensionInstallID.refusal("com.prosper.files", bundledFolders: [], bundledIDs: []) == nil)
        XCTAssertTrue(ExtensionInstallID.refusal("..", bundledFolders: [], bundledIDs: [])?.contains(form) == true)
    }

    // MARK: - installLocal refusals (destinations inside the row's own extensions folder)

    func testInstallUnderABundledFolderNameIsRefusedAndChangesNothing() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp)
        reg.discover()
        let builtIn = user.appendingPathComponent("files", isDirectory: true)
        let canary = builtIn.appendingPathComponent("canary.bin")
        try canaryBytes.write(to: canary)
        let manifestBefore = try Data(contentsOf: builtIn.appendingPathComponent("extension.toml"))
        let listingBefore = try fm.contentsOfDirectory(atPath: user.path).sorted()
        let source = tmp.appendingPathComponent("source", isDirectory: true)
        try writeExt(source, id: "files", title: "Other")

        refused(try reg.installLocal(from: source), contains: "built into Prosper")

        XCTAssertEqual(try Data(contentsOf: canary), canaryBytes, "the would-be destination is untouched")
        XCTAssertEqual(try Data(contentsOf: builtIn.appendingPathComponent("extension.toml")), manifestBefore)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: user.path).sorted(), listingBefore)
        XCTAssertEqual(reg.record(id: "com.prosper.files")?.isSystem, true)
    }

    func testInstallUnderABundledIDIsRefused() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp)
        reg.discover()
        let source = tmp.appendingPathComponent("source", isDirectory: true)
        try writeExt(source, id: "com.prosper.files", title: "Other")

        refused(try reg.installLocal(from: source), contains: "built into Prosper")

        XCTAssertFalse(fm.fileExists(atPath: user.appendingPathComponent("com.prosper.files").path))
        XCTAssertEqual(reg.records.filter { $0.id == "com.prosper.files" }.count, 1)
        XCTAssertEqual(reg.record(id: "com.prosper.files")?.isSystem, true)
        XCTAssertEqual(reg.record(id: "com.prosper.files")?.loaded.directory.lastPathComponent, "files")
    }

    /// A refused install creates nothing, not even the extensions folder.
    func testRefusedInstallCreatesNoExtensionsFolder() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp)
        let source = tmp.appendingPathComponent("source", isDirectory: true)
        try writeExt(source, id: "files", title: "Other")
        refused(try reg.installLocal(from: source), contains: "built into Prosper")
        XCTAssertFalse(fm.fileExists(atPath: user.path))
    }

    /// The ordinary install still goes in (dotted and dotless ids).
    func testOrdinaryIDsStillInstall() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp)
        reg.discover()
        for id in ["com.example.kit", "examplekit"] {
            let source = tmp.appendingPathComponent("source-\(id)", isDirectory: true)
            try writeExt(source, id: id)
            let record = try reg.installLocal(from: source)
            XCTAssertEqual(record.id, id)
            XCTAssertFalse(record.isSystem)
            XCTAssertFalse(record.trusted)
            XCTAssertTrue(fm.fileExists(atPath: user.appendingPathComponent("\(id)/extension.toml").path))
        }
    }

    // MARK: - discovery

    /// A bundled folder name replaced by hand with another id is an ordinary user record: not trusted, not privileged.
    func testBundledFolderNameWithAnotherIDIsNotSystem() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp)
        // Same version as the bundled copy, so seeding leaves the hand-made folder in place.
        try writeExt(user.appendingPathComponent("files", isDirectory: true), id: "com.example.kit", title: "Hand made")
        reg.discover()

        let record = reg.record(id: "com.example.kit")
        XCTAssertEqual(record?.isSystem, false)
        XCTAssertEqual(record?.trusted, false)
        XCTAssertEqual(record?.privileged, false)
        XCTAssertFalse(reg.isTrusted(id: "com.example.kit"))
        XCTAssertFalse(reg.isPrivileged(id: "com.example.kit"))
        XCTAssertFalse(reg.records.contains { $0.isSystem })
    }

    /// A user folder declaring a built-in's id never shadows it, whatever the folder names sort like.
    func testUserFolderWithABuiltInIDDoesNotShadowIt() throws {
        let tmp = tempDir()
        // "com.prosper.files" sorts before "zz-files": the old first-wins rule kept the user folder.
        let (reg, user) = try rig(tmp, builtInFolder: "zz-files")
        try writeExt(user.appendingPathComponent("com.prosper.files", isDirectory: true), id: "com.prosper.files",
                     title: "User copy")
        reg.discover()

        XCTAssertEqual(reg.records.filter { $0.id == "com.prosper.files" }.count, 1)
        let record = reg.record(id: "com.prosper.files")
        XCTAssertEqual(record?.isSystem, true)
        XCTAssertEqual(record?.manifest.extension.title, "Files")
        XCTAssertEqual(record?.loaded.directory.lastPathComponent, "zz-files")
    }

    /// Existing installs under an id the new rule refuses are never removed: one with a built-in's id is skipped as
    /// a duplicate, one with an id of another form still loads as a user record; both folders stay as they were.
    func testExistingInstallsUnderRefusedIDsStayOnDisk() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp, builtInFolder: "zz-files")
        let shadow = user.appendingPathComponent("com.prosper.files", isDirectory: true)
        let spaced = user.appendingPathComponent("example kit", isDirectory: true)
        try writeExt(shadow, id: "com.prosper.files", title: "User copy")
        try writeExt(spaced, id: "example kit", title: "Spaced")
        try canaryBytes.write(to: shadow.appendingPathComponent("canary.bin"))
        let before = try Data(contentsOf: shadow.appendingPathComponent("extension.toml"))

        reg.discover()
        reg.discover()

        XCTAssertEqual(try Data(contentsOf: shadow.appendingPathComponent("canary.bin")), canaryBytes)
        XCTAssertEqual(try Data(contentsOf: shadow.appendingPathComponent("extension.toml")), before)
        XCTAssertTrue(fm.fileExists(atPath: spaced.appendingPathComponent("extension.toml").path))
        XCTAssertFalse(reg.records.contains { $0.loaded.directory.lastPathComponent == "com.prosper.files" })
        let kept = reg.record(id: "example kit")
        XCTAssertEqual(kept?.isSystem, false)
        XCTAssertEqual(kept?.trusted, false)
        XCTAssertEqual(ExtensionInstallID.refusal("example kit", bundledFolders: [], bundledIDs: [])?.isEmpty, false)
    }
}
