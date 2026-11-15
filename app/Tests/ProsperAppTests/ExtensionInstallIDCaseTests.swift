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

/// #1246 (R1246-3, R1246-b): an id starting with a dot, and an id that differs from an installed one only by letter
/// case. Every registry here lives wholly inside the row's own tempDir().
@MainActor
final class ExtensionInstallIDCaseTests: XCTestCase {
    private let fm = FileManager.default
    private let canaryBytes = Data([0x00, 0x01, 0xFE]) + Data("canary".utf8)
    private let leadingDot = "starts with a dot", letterCase = "differs only by letter case"
    private let occupiedWords = "already answers to the name"

    private func writeExt(_ dir: URL, id: String, title: String = "Kit") throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(id)"
        name = "kit"
        title = "\(title)"
        description = "A test extension"
        version = "1.0.0"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- noop".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    }

    /// A registry with one built-in (folder "files"); trust key present (empty), so nothing is grandfathered.
    private func rig(_ tmp: URL) throws -> (ExtensionRegistry, URL) {
        let sys = tmp.appendingPathComponent("system", isDirectory: true)
        let user = tmp.appendingPathComponent("user", isDirectory: true)
        try writeExt(sys.appendingPathComponent("files", isDirectory: true), id: "com.prosper.files", title: "Files")
        let defaults = scratchDefaults("ext-install-id-case")
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

    /// Every name in `dir` straight from readdir: FileManager listings leave "._" names out.
    private func rawNames(_ dir: URL) -> [String] {
        guard let d = opendir(dir.path) else { return ["opendir failed"] }
        defer { closedir(d) }
        var names: [String] = []
        while let entry = readdir(d) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    /// The on-disk rows need a volume that ignores case (the APFS default): probed in the row's own tempDir.
    private func skipUnlessCaseInsensitive(_ tmp: URL) throws {
        let probe = tmp.appendingPathComponent("a", isDirectory: true)
        try fm.createDirectory(at: probe, withIntermediateDirectories: true)
        let ignoresCase = fm.fileExists(atPath: tmp.appendingPathComponent("A").path)
        try fm.removeItem(at: probe)
        try XCTSkipUnless(ignoresCase, "the test volume is case-sensitive: the literal rows still run")
    }

    // MARK: - R1246-3: a leading dot

    func testLeadingDotIDsAreRefusedByTheRule() {
        let form = "single name"
        let table: [(id: String, refusedFor: String?)] = [
            (".kit", leadingDot),
            ("._kit", leadingDot),
            ("..kit", leadingDot),
            (".com.example.kit", leadingDot),
            (".", form),
            ("..", form),
            ("....", form),
            ("kit.", nil),
            ("com.example.kit", nil),
            ("_kit", nil),
        ]
        for row in table {
            let why = ExtensionInstallID.refusal(row.id, bundledFolders: [], bundledIDs: [])
            if let words = row.refusedFor {
                XCTAssertTrue(why?.contains(words) == true, "\(row.id.debugDescription): \(why ?? "accepted")")
                XCTAssertTrue(why?.contains("Nothing was changed") == true, "\(row.id.debugDescription)")
            } else {
                XCTAssertTrue(why == nil, "\(row.id.debugDescription): \(why ?? "")")
            }
        }
    }

    /// The "._" listing fact, on folders in the row's own tempDir only: a FOLDER named "._kit" is listed by
    /// FileManager as by readdir (ticket 1 of this row showed it; the omission seen elsewhere is of "._" files).
    func testFileManagerListsAppleDoubleNamedFolders() throws {
        let tmp = tempDir()
        for name in ["._kit", ".kit", "kit"] {
            try fm.createDirectory(at: tmp.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path).sorted(), ["._kit", ".kit", "kit"])
        XCTAssertEqual(rawNames(tmp), ["._kit", ".kit", "kit"])
    }

    /// Existing hand-made leading-dot folders: discovery is unchanged. ".kit" and "._kit" both load as untrusted
    /// user records (hidden in Finder only); both stay on disk.
    func testHandMadeLeadingDotFoldersInDiscovery() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp)
        try writeExt(user.appendingPathComponent(".kit", isDirectory: true), id: ".kit")
        try writeExt(user.appendingPathComponent("._kit", isDirectory: true), id: "._kit")
        reg.discover()
        reg.discover()

        let hidden = reg.record(id: ".kit")
        XCTAssertEqual(hidden?.isSystem, false)
        XCTAssertEqual(hidden?.trusted, false)
        let appleDouble = reg.record(id: "._kit")
        XCTAssertEqual(appleDouble?.isSystem, false)
        XCTAssertEqual(appleDouble?.trusted, false)
        XCTAssertEqual(rawNames(user), ["._kit", ".kit", "files"])
        XCTAssertTrue(fm.fileExists(atPath: user.appendingPathComponent("._kit/extension.toml").path))
    }

    func testLeadingDotInstallIsRefusedAndChangesNothing() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp)
        reg.discover()
        let listingBefore = try fm.contentsOfDirectory(atPath: user.path).sorted()
        let rawBefore = rawNames(user)
        let source = tmp.appendingPathComponent("source", isDirectory: true)
        try writeExt(source, id: ".kit")

        refused(try reg.installLocal(from: source), contains: leadingDot)

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: user.path).sorted(), listingBefore)
        XCTAssertEqual(rawNames(user), rawBefore)
        XCTAssertEqual(rawBefore.count, 1, "only the seeded built-in")
        XCTAssertTrue(reg.record(id: ".kit") == nil)
    }

    // MARK: - R1246-b: letter case

    func testCaseRefusalOnLiteralNames() {
        let table: [(id: String, installed: [String]?, refusedFor: String?)] = [
            ("foo", ["foo"], nil),
            ("foo", ["bar", "foo"], nil),
            ("foo", ["foo", "FOO"], nil),
            ("foo", [], nil),
            ("foo", ["bar"], nil),
            ("foo", ["fo", "fooo", "foo2", "f-o-o", "foo.kit", ".foo"], nil),
            ("Foo", ["foo"], letterCase),
            ("foo", ["bar", "FOO"], letterCase),
            ("com.example.Kit", ["com.example.kit"], letterCase),
            ("kit", ["\u{212A}it"], letterCase),
            ("foo", nil, "could not be read"),
        ]
        for row in table {
            let why = ExtensionInstallID.caseRefusal(row.id, installed: row.installed, occupied: false)
            let label = "\(row.id) over \(row.installed ?? ["<unreadable>"])"
            if let words = row.refusedFor {
                XCTAssertTrue(why?.contains(words) == true, "\(label): \(why ?? "accepted")")
                XCTAssertTrue(why?.contains("Nothing was changed") == true, label)
            } else {
                XCTAssertTrue(why == nil, "\(label): \(why ?? "")")
            }
        }
        XCTAssertTrue(ExtensionInstallID.caseRefusal("Foo", installed: ["foo"], occupied: true)?
            .contains("installed extension foo") == true)
    }

    /// The belt: the disk folds more than lowercased() does (a long s here), so an occupied destination with no
    /// exact name is refused, naming no folder.
    func testOccupiedDestinationWithNoExactNameIsRefused() {
        let longS = "te\u{017F}t"
        let why = ExtensionInstallID.caseRefusal("test", installed: [longS], occupied: true)
        XCTAssertTrue(why?.contains(occupiedWords) == true, why ?? "accepted")
        XCTAssertTrue(why?.contains("Nothing was changed") == true, why ?? "accepted")
        XCTAssertFalse(why?.contains(longS) ?? true, why ?? "accepted")
        XCTAssertTrue(ExtensionInstallID.caseRefusal("test", installed: [longS], occupied: false) == nil)
        XCTAssertTrue(ExtensionInstallID.caseRefusal("test", installed: ["test"], occupied: true) == nil, "the update")
        XCTAssertTrue(ExtensionInstallID.caseRefusal("test", installed: [], occupied: true)?.contains(occupiedWords) == true)
    }

    /// Installing "Foo" over an installed "foo" is refused; foo's folder, canary and record stay.
    func testCaseVariantInstallIsRefusedAndKeepsTheInstalledFolder() throws {
        let tmp = tempDir()
        try skipUnlessCaseInsensitive(tmp)
        let (reg, user) = try rig(tmp)
        reg.discover()
        let old = tmp.appendingPathComponent("source-old", isDirectory: true)
        try writeExt(old, id: "foo", title: "Old")
        try reg.installLocal(from: old)
        let installed = user.appendingPathComponent("foo", isDirectory: true)
        try canaryBytes.write(to: installed.appendingPathComponent("canary.bin"))
        let manifestBefore = try Data(contentsOf: installed.appendingPathComponent("extension.toml"))
        let rawBefore = rawNames(user)
        let source = tmp.appendingPathComponent("source-new", isDirectory: true)
        try writeExt(source, id: "Foo", title: "New")

        refused(try reg.installLocal(from: source), contains: "\(letterCase) from the installed extension foo")

        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("canary.bin")), canaryBytes)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("extension.toml")), manifestBefore)
        XCTAssertEqual(rawNames(user), rawBefore)
        XCTAssertEqual(reg.record(id: "foo")?.manifest.extension.title, "Old")
        XCTAssertTrue(reg.record(id: "Foo") == nil)
    }

    /// A folder made by hand whose name the disk folds to "test" (a long s; lowercased() leaves it as is): an install
    /// of "test" is refused and the folder keeps its canary. Skipped where the volume does not fold that pair.
    func testInstallOverAFolderTheDiskFoldsToTheIDIsRefused() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp)
        reg.discover()
        let folded = user.appendingPathComponent("te\u{017F}t", isDirectory: true)
        try fm.createDirectory(at: folded, withIntermediateDirectories: true)
        try canaryBytes.write(to: folded.appendingPathComponent("canary.bin"))
        try XCTSkipUnless(fm.fileExists(atPath: user.appendingPathComponent("test").path),
                          "this volume does not fold the long s: the literal rows still run")
        let rawBefore = rawNames(user)
        let source = tmp.appendingPathComponent("source", isDirectory: true)
        try writeExt(source, id: "test")

        refused(try reg.installLocal(from: source), contains: occupiedWords)

        XCTAssertEqual(try Data(contentsOf: folded.appendingPathComponent("canary.bin")), canaryBytes)
        XCTAssertEqual(rawNames(user), rawBefore)
        XCTAssertEqual(rawBefore.count, 2, "the seeded built-in and the hand-made folder")
        XCTAssertTrue(reg.record(id: "test") == nil)
    }

    /// The same id stays an update, as before: the folder is replaced by the new copy (the canary goes with it).
    func testExactIDStillUpdates() throws {
        let tmp = tempDir()
        try skipUnlessCaseInsensitive(tmp)
        let (reg, user) = try rig(tmp)
        reg.discover()
        let old = tmp.appendingPathComponent("source-old", isDirectory: true)
        try writeExt(old, id: "foo", title: "Old")
        try reg.installLocal(from: old)
        let installed = user.appendingPathComponent("foo", isDirectory: true)
        try canaryBytes.write(to: installed.appendingPathComponent("canary.bin"))
        let source = tmp.appendingPathComponent("source-new", isDirectory: true)
        try writeExt(source, id: "foo", title: "New")

        let record = try reg.installLocal(from: source)

        XCTAssertEqual(record.manifest.extension.title, "New")
        XCTAssertFalse(fm.fileExists(atPath: installed.appendingPathComponent("canary.bin").path))
        XCTAssertEqual(rawNames(user), ["files", "foo"])
        XCTAssertEqual(reg.records.filter { $0.id == "foo" }.count, 1)
    }
}
