import XCTest
@testable import ProsperApp

private final class QuietServices: ExtensionHostServices, @unchecked Sendable {
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

/// #1548: an extension id equal to a word of the app's own "ext.<word>.*" pref keys is refused at load, so it never
/// reaches ext.collapse.* or ext.timers.v1. Scratch defaults and the row's own tempDir() only.
@MainActor
final class ExtensionReservedIDTests: XCTestCase {
    private let fm = FileManager.default

    private func writeExt(_ dir: URL, id: String) throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(id)"
        name = "kit"
        title = "Kit"
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

    private func rig(_ tmp: URL, _ defaults: UserDefaults) throws -> (ExtensionRegistry, URL) {
        let sys = tmp.appendingPathComponent("system", isDirectory: true)
        let user = tmp.appendingPathComponent("user", isDirectory: true)
        try fm.createDirectory(at: sys, withIntermediateDirectories: true)
        defaults.set([String](), forKey: "trustedExtensionIDs")
        return (ExtensionRegistry(systemDir: sys, userDir: user, hostVersion: "2.0.0", defaults: defaults,
                                  services: QuietServices()), user)
    }

    /// Every "ext.<word>." literal in Sources' code, but "com": the one dotted id's own key (ext.com.prosper.currency.fetchedAt).
    /// Comment lines are no key (#1542's doc quotes an example "ext.A.x.y.k").
    func testReservedListIsTheWordsTheSourcesHold() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp")
        let re = try NSRegularExpression(pattern: #""ext\.([A-Za-z0-9_-]+)\."#)
        var found = Set<String>()
        for case let url as URL in fm.enumerator(at: sources, includingPropertiesForKeys: nil)! where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
                .filter { !$0.drop(while: { $0 == " " }).hasPrefix("//") }.joined(separator: "\n")
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                found.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        found.remove("com")
        XCTAssertEqual(found, ["collapse", "timers"])
        XCTAssertEqual(ExtensionLoader.reservedIDs, found)
    }

    func testAHandPlacedReservedFolderIsRefusedAndTheAppKeysKeepTheirValues() throws {
        let tmp = tempDir()
        let defaults = scratchDefaults("ext-reserved")
        defaults.set(false, forKey: "ext.collapse.user")
        defaults.set("[]", forKey: "ext.timers.v1")
        let (reg, user) = try rig(tmp, defaults)
        for (n, id) in ["collapse", "timers", "Collapse"].enumerated() { try writeExt(user.appendingPathComponent("dir\(n)"), id: id) }
        try writeExt(user.appendingPathComponent("ok"), id: "collapsed")
        reg.discover()

        for id in ["collapse", "timers", "Collapse"] { XCTAssertTrue(reg.record(id: id) == nil, id) }
        XCTAssertTrue(reg.record(id: "collapsed") != nil, "a longer id is not reserved")
        XCTAssertEqual(reg.refused.count, 3)
        XCTAssertTrue(reg.refused.allSatisfy { $0.reason.contains("reserved") }, "\(reg.refused.map(\.reason))")
        XCTAssertEqual(defaults.object(forKey: "ext.collapse.user") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "ext.timers.v1"), "[]")
    }

    func testInstallLocalOfAReservedIDIsRefusedBeforeAnythingIsCopied() throws {
        let tmp = tempDir()
        let (reg, user) = try rig(tmp, scratchDefaults("ext-reserved-install"))
        reg.discover()
        for id in ["collapse", "timers"] {
            let source = tmp.appendingPathComponent("source-\(id)", isDirectory: true)
            try writeExt(source, id: id)
            XCTAssertThrowsError(try reg.installLocal(from: source)) {
                XCTAssertEqual($0 as? ExtensionLoadError, .reservedID(id))
            }
            XCTAssertFalse(fm.fileExists(atPath: user.appendingPathComponent(id).path), id)
        }
    }
}
