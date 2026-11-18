import Foundation
import XCTest
@testable import ProsperApp

private final class RecheckInertServices: ExtensionHostServices, @unchecked Sendable {
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

/// The fake Marketplace: each download hands out a fresh copy of `source` (an extracted folder under the row's tempDir),
/// each listing read answers `detail`; both count their calls. No network. Called off the main actor.
private final class FakeMarket: @unchecked Sendable {
    private let lock = NSLock()
    private var fetches = 0, details = 0
    private var listing: MarketClient.PackageDetail?
    let source: URL, work: URL

    init(source: URL, work: URL, detail: MarketClient.PackageDetail?) { self.source = source; self.work = work; listing = detail }

    var detail: MarketClient.PackageDetail? {
        get { lock.withLock { listing } }
        set { lock.withLock { listing = newValue } }
    }

    var workFolder: URL { work.appendingPathComponent("prosper-market-fake", isDirectory: true) }
    var fetchCount: Int { lock.withLock { fetches } }
    var detailCount: Int { lock.withLock { details } }

    @MainActor func wire(_ registry: ExtensionRegistry, index: [String: String]? = nil) {
        registry.marketFetch = { [self] _, _ in
            let n = lock.withLock { () -> Int in fetches += 1; return fetches }
            // Like the real download: a work folder directly in the temp root, a lost cleanup keeps it (the real one keeps a lock).
            let folder = workFolder
            guard !FileManager.default.fileExists(atPath: folder.path) else {
                throw RemoteInstaller.InstallError.extractFailed("this extension is already being installed")
            }
            let dir = folder.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: dir)
            return dir
        }
        registry.marketTempRoot = work
        registry.marketDetail = { [self] _ in lock.withLock { () -> MarketClient.PackageDetail? in details += 1; return listing } }
        registry.marketIndex = { index }
    }
}

/// #919 S3 (spec 4.12 row 10): a market install of a kit is checked against its listing as the server holds it, on the
/// Install path and in the update check. Offscreen: no window, no network (fake download, listing and index), every
/// folder under the row's tempDir().
@MainActor
final class MarketKitRecheckTests: XCTestCase {
    private let extID = "dev.example.kit.calm-agent"

    // MARK: - The listing must match

    /// A listing whose summary misses the hook line: refused, nothing installed.
    func testSummaryMissingAHookLineRefuses() async throws {
        let (registry, market, user) = try served(kit: true)
        var listing = try XCTUnwrap(market.detail)
        let summary = listing.preview?.kit?.summary ?? []
        let cut = summary.filter { !$0.hasPrefix("guard: ") }
        XCTAssertEqual(cut.count, summary.count - 1, "the fixture summary holds one line of the guard hook: \(summary)")
        listing = detail(summary: cut, readme: listing.preview?.kit?.readme ?? "")
        market.detail = listing
        await assertRefused(registry, .previewMismatch, user)
    }

    /// A listing whose README section differs: refused, nothing installed.
    func testEditedReadmeSectionRefuses() async throws {
        let (registry, market, user) = try served(kit: true)
        let shown = try XCTUnwrap(market.detail?.preview?.kit)
        market.detail = detail(summary: shown.summary, readme: shown.readme + " Now also edits your shell profile.")
        await assertRefused(registry, .previewMismatch, user)
    }

    /// The listing the archive's own preview equals: installed, untrusted, stamped with the market origin.
    func testMatchingListingInstallsUntrusted() async throws {
        let (registry, market, user) = try served(kit: true)
        let rec = try await registry.installFromMarket(id: extID, version: "1.0.0")
        XCTAssertEqual(rec.id, extID)
        XCTAssertFalse(rec.trusted)
        XCTAssertEqual(rec.manifest.extension.updateURL, "prosper://market/\(extID)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent(extID).path))
        XCTAssertEqual(market.detailCount, 1)
    }

    // MARK: - Kind, version, status

    /// A kit archive listed as kind "extension" (no kit preview shown at browse): refused.
    func testKitListedAsExtensionRefuses() async throws {
        let (registry, market, user) = try served(kit: true)
        market.detail = MarketClient.PackageDetail(kind: "extension", latest_version: "1.0.0", preview: market.detail?.preview,
                                                   status: "active")
        await assertRefused(registry, .kitListedAsOther, user)
    }

    /// A listing of kind "kit" over an archive that is not a kit: refused (the caller's listing says kit).
    func testListedKitOverNonKitArchiveRefuses() async throws {
        let (registry, market, user) = try served(kit: false)
        market.detail = detail(summary: ["rules: a block"], readme: "Calm.")
        do {
            _ = try await registry.prepareFromMarket(id: plainID, version: "1.0.0", listedKind: "kit")
            XCTFail("a non-kit archive listed as a kit was prepared")
        } catch {
            XCTAssertEqual(error as? ExtensionError, .marketKitRefused(id: plainID, .listedKitNotKit))
        }
        XCTAssertEqual(market.detailCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent(plainID).path))
    }

    /// The listing moved on to another version while the old one downloaded: not installed, a retry sentence, and not a
    /// refusal of the content (the update check tries the new version).
    func testVersionMovedOnRefusesWithARetrySentence() async throws {
        let (registry, market, user) = try served(kit: true)
        let shown = try XCTUnwrap(market.detail?.preview?.kit)
        market.detail = MarketClient.PackageDetail(kind: "kit", latest_version: "1.0.1", preview: MarketClient.Preview(kit: shown),
                                                   status: "active")
        let error = await assertRefused(registry, .versionMovedOn, user)
        XCTAssertTrue(MarketplaceRootView.installErrorText(error).contains("Try again"), MarketplaceRootView.installErrorText(error))
        XCTAssertFalse(ExtensionRegistry.RefusedUpdates.isRefusal(error))
    }

    /// A withdrawn listing, and an active one without a kit preview: refused.
    func testInactiveOrPreviewlessListingRefuses() async throws {
        let (registry, market, user) = try served(kit: true)
        let shown = try XCTUnwrap(market.detail?.preview?.kit)
        market.detail = MarketClient.PackageDetail(kind: "kit", latest_version: "1.0.0", preview: MarketClient.Preview(kit: shown),
                                                   status: "yanked")
        await assertRefused(registry, .notActive, user)
        market.detail = MarketClient.PackageDetail(kind: "kit", latest_version: "1.0.0", preview: MarketClient.Preview(), status: "active")
        await assertRefused(registry, .noPreview, user)
    }

    // MARK: - The validator

    /// A README without "## Remove" whose first section and summary still equal the listing's: the validator refuses it.
    func testValidatorRefusalWinsOverAMatchingPreview() async throws {
        let (registry, _, user) = try served(kit: true) { f in
            try f.write("README.md", KitDirFixture.readme.replacingOccurrences(of: "## Remove", with: "## Afterwards"))
        }
        let error = await assertRefused(registry, nil, user)
        guard case .marketKitRefused(_, .validator(let why))? = error as? ExtensionError else {
            return XCTFail("not a validator refusal: \(error)")
        }
        XCTAssertTrue(why.contains("Remove"), why)
    }

    /// Another installed kit already named like this one: the slug is taken, refused.
    func testSlugClashWithAnInstalledKitRefuses() async throws {
        let (registry, _, user) = try served(kit: true)
        let other = try makeKitDir(under: tempDir())
        try other.write("extension.toml", KitFixture.head.replacingOccurrences(of: extID, with: "dev.example.kit.other")
                        + "\n" + KitFixture.kit + "\n")
        _ = try registry.installLocal(from: other.kit)
        let error = await assertRefused(registry, nil, user)
        guard case .marketKitRefused(_, .validator(let why))? = error as? ExtensionError else {
            return XCTFail("not a validator refusal: \(error)")
        }
        XCTAssertTrue(why.contains(KitReason.slugTaken.rawValue), why)
    }

    // MARK: - Failures, the update check, plain extensions

    /// A refused recheck removes the download's work folder (the real one keeps a lock until then), so the next Install runs.
    func testRefusedRecheckRemovesTheWorkFolderAndASecondInstallProceeds() async throws {
        let (registry, market, user) = try served(kit: true)
        let good = try XCTUnwrap(market.detail)
        market.detail = detail(summary: good.preview?.kit?.summary ?? [], readme: "Something else.")
        await assertRefused(registry, .previewMismatch, user)
        XCTAssertEqual(market.fetchCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: market.workFolder.path), "the refused download was kept")
        market.detail = good
        let rec = try await registry.installFromMarket(id: extID, version: "1.0.0")
        XCTAssertEqual(rec.id, extID)
        XCTAssertEqual(market.fetchCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: market.workFolder.path), "the installed download was kept")
    }

    /// A kit update whose listing matches installs through the update check (the kit's own name is not "taken").
    func testUpdateCheckInstallsAKitUpdateWhoseListingMatches() async throws {
        let (registry, market, user) = try updating(newVersion: "1.1.0") { _ in }
        market.detail = try detail(summary: expectedListing().summary, readme: expectedListing().readme, version: "1.1.0")
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(registry.record(id: extID)?.manifest.extension.version, "1.1.0")
        XCTAssertEqual(registry.updateStatus, "Updated 1 extension.")
        XCTAssertEqual(market.detailCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent(extID).path))
    }

    /// An installed kit whose next version is a plain extension under the same id: the update check reads the listing
    /// (it passes kind "kit"), refuses it, and keeps the installed kit.
    func testUpdateCheckRefusesAKitThatTurnedIntoAnExtension() async throws {
        let (registry, market, _) = try updating(newVersion: "1.1.0") { f in
            try f.write("extension.toml", KitFixture.head.replacingOccurrences(of: "\"1.0.0\"", with: "\"1.1.0\"") + "\n")
            try f.write("init.lua", "return {}\n")
        }
        // The listing still says kit (it is what the installed kit was published as); only the archive changed.
        market.detail = MarketClient.PackageDetail(kind: "kit", latest_version: "1.1.0", preview: nil, status: "active")
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(market.detailCount, 1, "the update check did not read the listing of an installed kit")
        XCTAssertEqual(registry.record(id: extID)?.manifest.extension.version, "1.0.0")
        XCTAssertEqual(registry.updateStatus, "1 update could not be installed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: market.workFolder.path))
    }

    /// QA R1535 s1: a trusted installed kit whose next archive is a plain extension, with a listing that says extension
    /// too (listing and archive agree: the author controls both): refused, nothing installed, noted, folder removed.
    func testUpdateCheckRefusesATrustedKitTurningIntoAnExtension() async throws {
        let (registry, market, user) = try updating(newVersion: "1.1.0") { f in
            try f.write("extension.toml", KitFixture.head.replacingOccurrences(of: "\"1.0.0\"", with: "\"1.1.0\"") + "\n")
            try f.write("init.lua", "return {}\n")
        }
        try registry.trust(id: extID)
        market.detail = MarketClient.PackageDetail(kind: "extension", latest_version: "1.1.0", preview: nil, status: "active")
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(registry.record(id: extID)?.manifest.extension.version, "1.0.0")
        XCTAssertTrue(registry.record(id: extID)?.manifest.contributes?.kit != nil, "the installed kit was replaced")
        XCTAssertEqual(registry.updateStatus, "1 update could not be installed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: market.workFolder.path), "the refused download was kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent(extID).path))
        XCTAssertEqual(market.fetchCount, 1)
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(market.fetchCount, 1, "a refused kind change was downloaded again")
        // The refusal is the kind change, in plain words; the manual Install path (no installedKit) is unchanged.
        let error = await prepareError(registry, installedKit: true)
        XCTAssertEqual(error as? ExtensionError, .marketKindChanged(id: extID))
        XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                       "Not installed: \(extID) changed kind; install it again from the Marketplace. Nothing was changed.")
        XCTAssertTrue(ExtensionRegistry.RefusedUpdates.isRefusal(error))
        let manual = try await registry.installFromMarket(id: extID, version: "1.1.0")
        XCTAssertEqual(manual.manifest.extension.version, "1.1.0")
    }

    /// The reverse: an installed plain extension whose next archive is a kit (its listing matches): refused the same way.
    func testUpdateCheckRefusesAnExtensionTurningIntoAKit() async throws {
        let root = tempDir()
        let user = root.appendingPathComponent("user", isDirectory: true)
        let registry = makeRegistry(user)
        let old = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data((KitFixture.head.replacingOccurrences(of: "[extension]\n", with: "[extension]\nupdate_url = \"prosper://market/\(extID)\"\n"))
            .utf8).write(to: old.appendingPathComponent("extension.toml"))
        try Data("return {}\n".utf8).write(to: old.appendingPathComponent("init.lua"))
        _ = try registry.installLocal(from: old)
        XCTAssertTrue(registry.record(id: extID)?.manifest.contributes?.kit == nil)
        let new = try kitFolder(under: root.appendingPathComponent("new", isDirectory: true)) { f in
            try f.write("extension.toml", KitFixture.head.replacingOccurrences(of: "\"1.0.0\"", with: "\"1.1.0\"")
                        + "\n" + KitFixture.kit + "\n")
        }
        let shown = try expectedListing()
        let market = FakeMarket(source: new.kit, work: root,
                                detail: detail(summary: shown.summary, readme: shown.readme, version: "1.1.0"))
        market.wire(registry, index: [extID: "1.1.0"])
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(registry.record(id: extID)?.manifest.extension.version, "1.0.0")
        XCTAssertTrue(registry.record(id: extID)?.manifest.contributes?.kit == nil, "the extension was replaced by a kit")
        XCTAssertEqual(registry.updateStatus, "1 update could not be installed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: market.workFolder.path), "the refused download was kept")
        XCTAssertEqual(market.fetchCount, 1)
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(market.fetchCount, 1, "a refused kind change was downloaded again")
        let error = await prepareError(registry, installedKit: false)
        XCTAssertEqual(error as? ExtensionError, .marketKindChanged(id: extID))
    }

    /// The listing could not be loaded: an error, nothing installed, and not remembered as a refusal.
    func testFailedListingReadIsTransient() async throws {
        let (registry, market, user) = try served(kit: true)
        market.detail = nil
        let error = await assertRefused(registry, nil, user)
        XCTAssertEqual(error as? ExtensionError, .marketListingUnavailable(id: extID))
        XCTAssertFalse(ExtensionRegistry.RefusedUpdates.isRefusal(error))
        var refused = ExtensionRegistry.RefusedUpdates()
        refused.note(error, id: extID, listed: "1.0.0")
        XCTAssertTrue(refused.listed.isEmpty)
    }

    /// The update check reaches the same recheck: a mismatched listing is refused and noted, and the second forced check
    /// does not download it again.
    func testUpdateCheckRefusalIsNotedAndNotDownloadedAgain() async throws {
        let root = tempDir()
        let user = root.appendingPathComponent("user", isDirectory: true)
        let registry = makeRegistry(user)
        let old = try makeKitDir(under: root.appendingPathComponent("old", isDirectory: true))
        try old.write("extension.toml", KitFixture.head.replacingOccurrences(
            of: "[extension]\n", with: "[extension]\nupdate_url = \"prosper://market/\(extID)\"\n") + "\n" + KitFixture.kit + "\n")
        _ = try registry.installLocal(from: old.kit)
        XCTAssertEqual(registry.record(id: extID)?.manifest.extension.updateURL, "prosper://market/\(extID)")
        let new = try kitFolder(under: root.appendingPathComponent("new", isDirectory: true)) { f in
            try f.write("extension.toml", KitFixture.head.replacingOccurrences(of: "\"1.0.0\"", with: "\"1.1.0\"")
                        + "\n" + KitFixture.kit + "\n")
        }
        let shown = try expectedListing()
        let market = FakeMarket(source: new.kit, work: root, detail: MarketClient.PackageDetail(
            kind: "kit", latest_version: "1.1.0", preview: MarketClient.Preview(kit: KitListingPreview(summary: shown.summary,
                                                                                                    readme: "Something else.")),
            status: "active"))
        market.wire(registry, index: [extID: "1.1.0"])
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(market.fetchCount, 1)
        XCTAssertEqual(market.detailCount, 1, "the update check did not recheck the listing")
        XCTAssertEqual(registry.record(id: extID)?.manifest.extension.version, "1.0.0")
        XCTAssertEqual(registry.updateStatus, "1 update could not be installed.")
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(market.fetchCount, 1, "a refused update was downloaded again")
        XCTAssertEqual(registry.record(id: extID)?.manifest.extension.version, "1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent(extID).path), "the installed kit is kept")
    }

    /// A plain extension (not a kit, not listed as one) installs as before with no listing read.
    func testPlainExtensionInstallMakesNoListingCall() async throws {
        let (registry, market, user) = try served(kit: false)
        let rec = try await registry.installFromMarket(id: plainID, version: "1.0.0")
        XCTAssertEqual(rec.id, plainID)
        XCTAssertFalse(rec.trusted)
        XCTAssertEqual(market.detailCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: user.appendingPathComponent(plainID).path))
    }

    /// Every content refusal is remembered by the update check and reads as a plain sentence; the moved-on listing is not.
    func testContentRefusalsAreRefusalsWithPlainSentences() {
        let content: [KitListingRefusal] = [.kitListedAsOther, .listedKitNotKit, .notActive, .noPreview, .validator("x"),
                                            .previewMismatch]
        for why in content + [.versionMovedOn] {
            let error = ExtensionError.marketKitRefused(id: extID, why)
            XCTAssertEqual(ExtensionRegistry.RefusedUpdates.isRefusal(error), why != .versionMovedOn, "\(why)")
            let text = MarketplaceRootView.installErrorText(error)
            XCTAssertTrue(text.hasPrefix("Not installed: \(extID): "), text)
            XCTAssertFalse(text.contains("marketKitRefused"), text)
        }
    }

    /// QA R1520-n1: the server's 409 "kind_change" (an id published before as another kind) reads as a plain sentence.
    func testKindChangePublishErrorHasAPlainSentence() {
        XCTAssertEqual(MarketClient.MarketError.http(409, "kind_change").errorDescription,
                       "This id is already published as a different kind of package.")
    }

    // MARK: - Helpers

    private let plainID = "com.example.plain"

    /// discover() first: it seeds the (empty) trusted list, so an install lands untrusted (no grandfathering).
    private func makeRegistry(_ user: URL) -> ExtensionRegistry {
        let registry = ExtensionRegistry(systemDir: nil, userDir: user, hostVersion: "9.0.0",
                                         defaults: scratchDefaults("kit-recheck"), services: RecheckInertServices())
        registry.discover()
        return registry
    }

    /// A registry over an empty user dir, and a fake Marketplace serving the fixture kit (or a plain extension) whose
    /// listing is the one recomputed from the unchanged fixture kit.
    private func served(kit: Bool, change: (KitDirFixture) throws -> Void = { _ in })
        throws -> (ExtensionRegistry, FakeMarket, URL) {
        let root = tempDir()
        let user = root.appendingPathComponent("user", isDirectory: true)
        let source: URL
        if kit {
            source = try kitFolder(under: root.appendingPathComponent("served", isDirectory: true), change: change).kit
        } else {
            source = root.appendingPathComponent("served/plain", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data((KitFixture.head.replacingOccurrences(of: extID, with: plainID)
                      .replacingOccurrences(of: "\"calm-agent\"", with: "\"plain\"")).utf8)
                .write(to: source.appendingPathComponent("extension.toml"))
            try Data("return {}\n".utf8).write(to: source.appendingPathComponent("init.lua"))
        }
        let shown = try expectedListing()
        let market = FakeMarket(source: source, work: root, detail: detail(summary: shown.summary, readme: shown.readme))
        let registry = makeRegistry(user)
        market.wire(registry)
        return (registry, market, user)
    }

    /// An installed kit 1.0.0 with the market update_url, and a fake Marketplace serving `newVersion` (the fixture kit with
    /// that version, then `change`) and an index that lists it. The caller sets the listing.
    private func updating(newVersion: String, change: (KitDirFixture) throws -> Void) throws -> (ExtensionRegistry, FakeMarket, URL) {
        let root = tempDir()
        let user = root.appendingPathComponent("user", isDirectory: true)
        let registry = makeRegistry(user)
        let old = try makeKitDir(under: root.appendingPathComponent("old", isDirectory: true))
        try old.write("extension.toml", KitFixture.head.replacingOccurrences(
            of: "[extension]\n", with: "[extension]\nupdate_url = \"prosper://market/\(extID)\"\n") + "\n" + KitFixture.kit + "\n")
        _ = try registry.installLocal(from: old.kit)
        let new = try kitFolder(under: root.appendingPathComponent("new", isDirectory: true)) { f in
            try f.write("extension.toml", KitFixture.head.replacingOccurrences(of: "\"1.0.0\"", with: "\"\(newVersion)\"")
                        + "\n" + KitFixture.kit + "\n")
            try change(f)
        }
        let market = FakeMarket(source: new.kit, work: root, detail: nil)
        market.wire(registry, index: [extID: newVersion])
        return (registry, market, user)
    }

    private func detail(summary: [String], readme: String, version: String = "1.0.0") -> MarketClient.PackageDetail {
        MarketClient.PackageDetail(kind: "kit", latest_version: version,
                                   preview: MarketClient.Preview(kit: KitListingPreview(summary: summary, readme: readme)),
                                   status: "active")
    }

    private func kitFolder(under root: URL, change: (KitDirFixture) throws -> Void = { _ in }) throws -> KitDirFixture {
        let f = try makeKitDir(under: root)
        try f.write("extension.toml", KitFixture.head + "\n" + KitFixture.kit + "\n")
        try change(f)
        return f
    }

    /// make(...) over the unchanged fixture kit, validated in place (the listing names no path, so any copy gives it).
    private func expectedListing() throws -> KitListingPreview {
        let f = try makeKitDir(under: tempDir())
        guard case .ok(let v) = try f.validate() else {
            XCTFail("the fixture kit is refused")
            return KitListingPreview(summary: [], readme: "")
        }
        return KitListingPreview.make(v, readme: KitDirFixture.readme)
    }

    /// The error prepareFromMarket throws for the fixture id at 1.1.0 with `installedKit` (nil: it did not throw).
    private func prepareError(_ registry: ExtensionRegistry, installedKit: Bool) async -> Error {
        do {
            let p = try await registry.prepareFromMarket(id: extID, version: "1.1.0", installedKit: installedKit)
            registry.discard(p)
            return NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "did not throw"])
        } catch { return error }
    }

    /// installFromMarket throws (the refusal `want` when given) and leaves no installed folder or record. Returns the error.
    @discardableResult
    private func assertRefused(_ registry: ExtensionRegistry, _ want: KitListingRefusal?, _ user: URL,
                               file: StaticString = #filePath, line: UInt = #line) async -> Error {
        do {
            _ = try await registry.installFromMarket(id: extID, version: "1.0.0")
            XCTFail("installed", file: file, line: line)
            return CancellationError()
        } catch {
            if let want {
                XCTAssertEqual(error as? ExtensionError, .marketKitRefused(id: extID, want), file: file, line: line)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent(extID).path), file: file, line: line)
            XCTAssertTrue(registry.record(id: extID) == nil, file: file, line: line)
            return error
        }
    }
}
