import Foundation
import XCTest
@testable import ProsperApp

private final class ListingInertServices: ExtensionHostServices, @unchecked Sendable {
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

/// The fake upload: records each call's id, kind and preview; no session, no network. Called off the main actor.
private final class ListingPublishCalls: @unchecked Sendable {
    struct Call { let id: String; let kind: String; let preview: MarketClient.Preview? }
    private let lock = NSLock()
    private var seen: [Call] = []
    var all: [Call] { lock.withLock { seen } }
    var fake: @Sendable (MarketClient.PublishManifest, String, String, MarketClient.Preview?) async throws -> Void {
        { [self] m, _, kind, preview in lock.withLock { seen.append(Call(id: m.id, kind: kind, preview: preview)) } }
    }
}

/// #919 S2: a kit's Marketplace listing (KitListingPreview), the tolerant preview decode, and a kit published as kind
/// "kit" with its listing computed over the packed blob. Offscreen: no window, no network (a fake publishCall and
/// fetchVersion); every folder, the publish work folder included, is under the row's tempDir().
@MainActor
final class MarketKitListingTests: XCTestCase {
    private let extID = "dev.example.kit.calm-agent"

    // MARK: - Decode (4.12 row 10)

    /// A theme row, a kit row, an unknown-shape preview, a null preview and a known field of a wrong shape all decode;
    /// the kit row is a kit with its summary, and the page does not fail.
    func testBrowsePageDecodesEveryPreviewShape() throws {
        func row(_ id: String, _ kind: String, _ preview: String) -> String {
            #"{"id":"\#(id)","title":"T","description":"","author":"Example Org","icon":null,"license":null,"#
                + #""latest_version":"1.0.0","downloads":0,"updated_at":0,"kind":"\#(kind)","preview":\#(preview)}"#
        }
        let page = "[" + [
            row("com.example.theme", "theme", ##"{"themes":[{"title":"Example","appearance":"light","colors":{"bg":"#ffffff"}}]}"##),
            row("com.example.kit", "kit", #"{"kit":{"schema":1,"summary":["rules: a block"],"readme":"Calm."}}"#),
            row("com.example.x", "extension", #"{"x":1}"#),
            row("com.example.null", "extension", "null"),
            row("com.example.bad", "kit", #"{"themes":"x","kit":{"schema":"one"}}"#),
            row("com.example.text", "extension", #""a string""#),
        ].joined(separator: ",") + "]"
        let pkgs = try JSONDecoder().decode([MarketClient.Package].self, from: Data(page.utf8))
        XCTAssertEqual(pkgs.map(\.id), ["com.example.theme", "com.example.kit", "com.example.x", "com.example.null",
                                        "com.example.bad", "com.example.text"])
        XCTAssertEqual(pkgs.first?.preview?.themes?.first?.colors, ["bg": "#ffffff"])
        let kit = try XCTUnwrap(pkgs.first { $0.id == "com.example.kit" })
        XCTAssertTrue(kit.isKit)
        XCTAssertFalse(kit.isTheme)
        XCTAssertEqual(kit.preview?.kit, KitListingPreview(summary: ["rules: a block"], readme: "Calm."))
        XCTAssertEqual(pkgs.first { $0.id == "com.example.x" }?.preview, MarketClient.Preview())
        XCTAssertTrue(pkgs.first { $0.id == "com.example.null" }?.preview == nil)
        XCTAssertEqual(pkgs.first { $0.id == "com.example.bad" }?.preview, MarketClient.Preview())
        XCTAssertEqual(pkgs.first { $0.id == "com.example.text" }?.preview, MarketClient.Preview())
        // what a theme publish sends is unchanged: {"themes":[...]} with no kit key
        let sent = try JSONEncoder().encode(MarketClient.Preview(themes: pkgs.first?.preview?.themes))
        XCTAssertFalse(String(decoding: sent, as: UTF8.self).contains("kit"))
    }

    // MARK: - The listing (pure)

    /// The same kit under two folders (under /Users/example-like names) packed and unpacked in two work roots: equal
    /// previews, and no line names either folder.
    func testListingIsTheSameFromTwoFoldersAndNamesNeither() throws {
        var listings: [KitListingPreview] = []
        var roots: [String] = []
        for name in ["example-a", "example-b"] {
            let root = tempDir().appendingPathComponent("Users/\(name)", isDirectory: true)
            let f = try kitFolder(under: root)
            let listing = try ExtensionRow.kitListing(blob: RemoteInstaller.packageForPublish(f.kit), id: extID, tempRoot: root)
            listings.append(listing)
            roots.append(root.path)
            XCTAssertEqual(try leftovers(root), ["kits"], "the work folder was left behind")
        }
        XCTAssertEqual(listings.count, 2)
        XCTAssertEqual(listings.first, listings.last)
        let lines = (listings.first?.summary ?? []) + [listings.first?.readme ?? ""]
        XCTAssertFalse(lines.isEmpty)
        for line in lines { for root in roots { XCTAssertFalse(line.contains(root), line) } }
        XCTAssertFalse(lines.contains { $0.contains("/Users/") }, "\(lines)")
        XCTAssertEqual(listings.first?.readme, "# Calm Agent Kit")
        XCTAssertTrue(listings.first?.summary.contains { $0.contains("{{kit_dir}}/CLAUDE.md") } ?? false)
    }

    /// A 3000-byte first section with a 4-byte character over byte 2048: cut before it, at most 2048 bytes, the same
    /// on two calls. With no text before the first "## " heading, the first section is that heading's.
    func testReadmeFirstSectionIsCutOnACharacterBoundary() {
        let long = String(repeating: "a", count: 2046) + "\u{1F600}" + String(repeating: "b", count: 950)
        XCTAssertEqual(long.utf8.count, 3000)
        let readme = long + "\n\n## Remove\nRemove it.\n"
        let cut = KitListingPreview.firstSection(readme)
        XCTAssertLessThanOrEqual(cut.utf8.count, KitListingPreview.readmeMaxBytes)
        XCTAssertEqual(cut, String(repeating: "a", count: 2046))
        XCTAssertEqual(String(decoding: Data(cut.utf8), as: UTF8.self), cut)
        XCTAssertEqual(KitListingPreview.firstSection(readme), cut)
        XCTAssertEqual(KitListingPreview.firstSection("\n## What it changes\nOne block.\n\n## Remove\nx\n"),
                       "## What it changes\nOne block.")
        XCTAssertEqual(KitListingPreview.firstSection(KitDirFixture.readme), "# Calm Agent Kit")
    }

    // MARK: - Publish through the row

    /// A README without "## Remove": the row uploads nothing, its error names the heading, the work folder is gone.
    func testKitMissingRemoveHeadingIsNotUploaded() throws {
        let (registry, record, root) = try installedKit {
            try $0.write("README.md", KitDirFixture.readme.replacingOccurrences(of: "## Remove", with: "## Gone"))
        }
        let calls = ListingPublishCalls()
        publish(registry, record, root, calls)
        XCTAssertFalse(waitForCall(calls), "a refused kit was uploaded")
        let dir = try XCTUnwrap(registry.directory(id: extID))
        XCTAssertThrowsError(try ExtensionRow.kitListing(blob: RemoteInstaller.packageForPublish(dir), id: extID, tempRoot: root)) {
            XCTAssertTrue(($0 as? KitPublishRefused)?.text.contains("README.md ## Remove") ?? false, "\($0)")
        }
        XCTAssertEqual(try leftovers(root), ["kits", "user"])
    }

    /// A Mach-O-like file under tools/ is refused for a market kit (scripts only): nothing is uploaded.
    func testKitWithABinaryToolIsNotUploaded() throws {
        let (registry, record, root) = try installedKit {
            try $0.write("tools/calm-bin", Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01]), mode: 0o755)
        }
        let calls = ListingPublishCalls()
        publish(registry, record, root, calls)
        XCTAssertFalse(waitForCall(calls), "a kit with a binary tool was uploaded")
        let dir = try XCTUnwrap(registry.directory(id: extID))
        XCTAssertThrowsError(try ExtensionRow.kitListing(blob: RemoteInstaller.packageForPublish(dir), id: extID, tempRoot: root)) {
            XCTAssertTrue(($0 as? KitPublishRefused)?.text.contains("tools/calm-bin: \(KitReason.binaryExecutable.rawValue)") ?? false, "\($0)")
        }
        XCTAssertEqual(try leftovers(root), ["kits", "user"])
    }

    /// A valid kit is uploaded once as kind "kit" with exactly make(...)'s listing and no themes.
    func testValidKitIsPublishedAsKindKit() throws {
        let (registry, record, root) = try installedKit { _ in }
        let calls = ListingPublishCalls()
        publish(registry, record, root, calls)
        XCTAssertTrue(waitForCall(calls), "the kit was not uploaded")
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertEqual(calls.all.first?.id, extID)
        XCTAssertEqual(calls.all.first?.kind, "kit")
        XCTAssertTrue(calls.all.first?.preview?.themes == nil)
        XCTAssertEqual(calls.all.first?.preview?.kit, try expectedListing())
        XCTAssertEqual(try leftovers(root), ["kits", "user"])
    }

    /// The dev folder holds a hidden ".notes" (a Mach-O-like file with an x bit, which a market kit refuses) that the
    /// packer leaves out: the upload goes on with the listing of the packed blob, which never saw it.
    func testHiddenDevFileIsNotInTheListing() throws {
        let (registry, record, root) = try installedKit { _ in }
        let dir = try XCTUnwrap(registry.directory(id: extID))
        let notes = dir.appendingPathComponent(".notes")
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01]).write(to: notes)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notes.path)
        let calls = ListingPublishCalls()
        publish(registry, record, root, calls)
        XCTAssertTrue(waitForCall(calls), "the dev folder's hidden file stopped the upload")
        XCTAssertEqual(calls.all.first?.kind, "kit")
        XCTAssertEqual(calls.all.first?.preview?.kit, try expectedListing())
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path), "the dev folder was changed")
    }

    /// 64 allow and 64 deny rules of 400 characters: the encoded preview is over 16384 UTF-16 units, refused here with
    /// the friendly text; nothing is uploaded.
    func testOverCapPreviewIsRefusedLocally() throws {
        let rules = (0..<64).map { "\"Bash(calm-note-\($0)-" + String(repeating: "x", count: 380) + ":*)\"" }.joined(separator: ", ")
        let toml = KitFixture.kit(replacing: "allow = [\"Bash(calm-note:*)\"]\ndeny  = [\"Bash(rm -rf:*)\"]",
                                  with: "allow = [\(rules)]\ndeny = [\(rules.replacingOccurrences(of: "calm-note", with: "calm-deny"))]")
        let (registry, record, root) = try installedKit(toml) { _ in }
        let calls = ListingPublishCalls()
        publish(registry, record, root, calls)
        XCTAssertFalse(waitForCall(calls), "an over-cap preview was uploaded")
        let dir = try XCTUnwrap(registry.directory(id: extID))
        XCTAssertThrowsError(try ExtensionRow.kitListing(blob: RemoteInstaller.packageForPublish(dir), id: extID, tempRoot: root)) {
            XCTAssertEqual(($0 as? KitPublishRefused)?.text, "The marketplace preview is too large to publish.")
        }
        XCTAssertEqual(MarketClient.MarketError.http(413, "preview_too_large").errorDescription,
                       "The marketplace preview is too large to publish.")
        XCTAssertEqual(try leftovers(root), ["kits", "user"])
    }

    // MARK: - Helpers

    /// The fixture kit (every piece kind) with its extension.toml, under `root`; `change` edits it before use.
    private func kitFolder(under root: URL, _ toml: String = KitFixture.kit,
                           change: (KitDirFixture) throws -> Void = { _ in }) throws -> KitDirFixture {
        let f = try makeKitDir(under: root)
        try f.write("extension.toml", KitFixture.head + "\n" + toml + "\n")
        try change(f)
        return f
    }

    /// A registry in a tempDir() with the kit installed from a folder beside it and trusted; the root is the row's work root.
    private func installedKit(_ toml: String = KitFixture.kit, _ change: (KitDirFixture) throws -> Void)
        throws -> (ExtensionRegistry, ExtensionRecord, URL) {
        let root = tempDir()
        let f = try kitFolder(under: root, toml, change: change)
        let registry = ExtensionRegistry(systemDir: nil, userDir: root.appendingPathComponent("user"), hostVersion: "9.0.0",
                                         defaults: scratchDefaults("kit-listing"), services: ListingInertServices())
        let installed = try registry.installLocal(from: f.kit)
        try registry.trust(id: installed.id)
        return (registry, try XCTUnwrap(registry.record(id: extID)), root)
    }

    /// make(...) over the unchanged fixture kit, validated in place (the listing names no path, so any copy gives it).
    private func expectedListing() throws -> KitListingPreview {
        let f = try makeKitDir(under: tempDir())
        guard case .ok(let v) = try f.validate() else { XCTFail("the fixture kit is refused"); return KitListingPreview(summary: [], readme: "") }
        return KitListingPreview.make(v, readme: KitDirFixture.readme)
    }

    private func publish(_ registry: ExtensionRegistry, _ record: ExtensionRecord, _ root: URL, _ calls: ListingPublishCalls) {
        ExtensionRow(registry: registry, record: record, fetchVersion: { _ in nil }, publishCall: calls.fake, workRoot: root)
            .publish(RemoteInstaller.publishPlan(record.loaded.directory))
    }

    /// Runs the main run loop until `calls` holds an upload, or 5 s (a ceiling, not a wait).
    private func waitForCall(_ calls: ListingPublishCalls) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while calls.all.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return !calls.all.isEmpty
    }

    private func leftovers(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }
}
