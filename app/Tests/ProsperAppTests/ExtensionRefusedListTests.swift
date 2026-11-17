import XCTest
@testable import ProsperApp

/// Minimal no-op host services: the registry here only discovers inside the row's own tempDir().
private final class RefusedListNoopServices: ExtensionHostServices, @unchecked Sendable {
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

/// #984 (QA #160): a manifest discover() refuses is listed with a fixed sentence (the TOML guard's own reason, or one
/// sentence for a parse failure, never the parser's text), the Settings list's line shows it, and the marketplace's
/// install error reads the same. Made-up manifests (com.example ids) in the row's own tempDir(); no fetch, no network,
/// no window: the list line and the marketplace text are pure functions.
@MainActor
final class ExtensionRefusedListTests: XCTestCase {
    private static func manifest(_ id: String) -> String {
        """
        [extension]
        id = "\(id)"
        name = "example"
        title = "Example"
        description = "An example extension"
        version = "1.0.0"
        author = "Example Org"

        [extension.host]
        min_version = "1.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        """
    }

    /// The parser's own words would name this key; no shown text may hold it.
    private static let rawMarker = "zzrawmarker"

    @discardableResult
    private func writeExt(_ dir: URL, _ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- noop".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return dir
    }

    private func registry(_ user: URL) -> ExtensionRegistry {
        ExtensionRegistry(systemDir: nil, userDir: user, hostVersion: "2.0.0",
                          defaults: scratchDefaults("refused"), services: RefusedListNoopServices())
    }

    /// Four refused folders and one good one, sorted the way discover reads them.
    private func writeFixtures(_ user: URL) throws {
        let head = Self.manifest("com.example.bad")
        var big = head + "# "
        big += String(repeating: "x", count: TOMLGuard.maxBytes + 1 - big.utf8.count - 1) + "\n"
        XCTAssertEqual(big.utf8.count, TOMLGuard.maxBytes + 1)
        try writeExt(user.appendingPathComponent("big"), big)
        try writeExt(user.appendingPathComponent("broken"), head + "\(Self.rawMarker) = = 1\n")
        let n = TOMLGuard.maxDepth + 1
        try writeExt(user.appendingPathComponent("deep"),
                     head + "deep = " + String(repeating: "[", count: n) + "1" + String(repeating: "]", count: n) + "\n")
        try writeExt(user.appendingPathComponent("ok"), Self.manifest("com.example.ok"))
        try writeExt(user.appendingPathComponent("quote"), head + "note = \"open\n")
    }

    private static let expectedReasons = [
        "extension.toml is over the 1048576-byte size limit",
        "The extension's manifest could not be read.",
        "TOML rejected: nested deeper than the depth limit of 64",
        "TOML rejected: an unterminated string",
    ]

    func testDiscoverListsRefusedFoldersWithTheFixedSentences() throws {
        let user = tempDir().appendingPathComponent("user")
        try writeFixtures(user)
        let reg = registry(user)
        reg.discover()
        XCTAssertEqual(reg.records.map(\.id), ["com.example.ok"])
        XCTAssertEqual(reg.refused.map(\.folder), ["big", "broken", "deep", "quote"])
        XCTAssertEqual(reg.refused.map(\.reason), Self.expectedReasons)
        XCTAssertEqual(reg.refused.last?.directory.lastPathComponent, "quote")
        // The Settings list's lines for the same folders.
        XCTAssertEqual(reg.refused.map(ExtensionsPane.refusedLine), [
            "Not loaded: big: extension.toml is over the 1048576-byte size limit",
            "Not loaded: broken: The extension's manifest could not be read.",
            "Not loaded: deep: TOML rejected: nested deeper than the depth limit of 64",
            "Not loaded: quote: TOML rejected: an unterminated string",
        ])
        XCTAssertFalse(reg.refused.map(ExtensionsPane.refusedLine).joined().contains(Self.rawMarker))
        // A rescan after the folders are fixed empties the list.
        for name in ["big", "broken", "deep", "quote"] {
            try writeExt(user.appendingPathComponent(name), Self.manifest("com.example.\(name)"))
        }
        reg.discover()
        XCTAssertTrue(reg.refused.isEmpty, "\(reg.refused.count)")
        XCTAssertEqual(reg.records.count, 5)
    }

    func testRefusedListIsBounded() throws {
        let user = tempDir().appendingPathComponent("user")
        XCTAssertEqual(ExtensionRegistry.maxRefused, 20)
        for i in 0..<25 {
            try writeExt(user.appendingPathComponent(String(format: "f%02d", i)), Self.manifest("com.example.f") + "= =\n")
        }
        let reg = registry(user)
        reg.discover()
        XCTAssertEqual(reg.refused.count, 20)
        XCTAssertEqual(reg.refused.first?.folder, "f00")
        XCTAssertEqual(reg.refused.last?.folder, "f19")
    }

    /// The folder name is outside text: unseen scalars dropped and cut at 80, in the list and in its line.
    func testRefusedFolderNameIsShownCleanedAndCut() throws {
        let user = tempDir().appendingPathComponent("user")
        try writeExt(user.appendingPathComponent("bad\u{202E}kit\u{200B}" + String(repeating: "x", count: 100)),
                     Self.manifest("com.example.bad") + "= =\n")
        let reg = registry(user)
        reg.discover()
        let shown = "badkit" + String(repeating: "x", count: 73) + "\u{2026}"
        XCTAssertEqual(reg.refused.map(\.folder), [shown])
        XCTAssertEqual(reg.refused.map(ExtensionsPane.refusedLine),
                       ["Not loaded: " + shown + ": The extension's manifest could not be read."])
    }

    /// R984-s1: two refused folders give two different Reveal labels, each naming its folder (the button's action is never run).
    func testRevealLabelNamesItsFolder() throws {
        let user = tempDir().appendingPathComponent("user")
        for name in ["alpha", "beta"] { try writeExt(user.appendingPathComponent(name), Self.manifest("com.example.bad") + "= =\n") }
        let reg = registry(user)
        reg.discover()
        let labels = reg.refused.map(ExtensionsPane.revealLabel)
        XCTAssertEqual(labels, ["Reveal alpha in Finder", "Reveal beta in Finder"])
        XCTAssertEqual(Set(labels).count, 2)
    }

    /// A scan by necessity (no hosting row, no window): the refused row's button is labelled with revealLabel.
    func testRefusedRowButtonUsesTheRevealLabel() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Extensions/ExtensionsSettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".accessibilityLabel(Self.revealLabel(refused))"))
    }

    /// The marketplace's install error for each refused manifest, from the loader the market path reads with
    /// (bindMarketIdentity, no download), and for the two errors that carry a manifest value.
    func testMarketplaceInstallErrorIsThePlainSentence() throws {
        let user = tempDir().appendingPathComponent("user")
        try writeFixtures(user)
        let reg = registry(user)
        var texts: [String] = []
        for name in ["big", "broken", "deep", "quote"] {
            XCTAssertThrowsError(try reg.bindMarketIdentity(extDir: user.appendingPathComponent(name),
                                                            expected: "com.example.bad", expectedVersion: nil)) {
                texts.append(MarketplaceRootView.installErrorText($0))
            }
        }
        XCTAssertEqual(texts, Self.expectedReasons)
        XCTAssertEqual(MarketplaceRootView.installErrorText(ExtensionLoadError.entryMissing("in\u{202E}it.lua")),
                       "The extension's entry file init.lua is missing.")
        XCTAssertEqual(MarketplaceRootView.installErrorText(ExtensionLoadError.incompatibleHost(need: "9.\u{200B}0.0", have: "2.0.0")),
                       "The extension needs Prosper 9.0.0 or newer; this is 2.0.0.")
    }
}
