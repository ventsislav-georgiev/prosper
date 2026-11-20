import XCTest
@testable import ProsperApp

private final class InertServices: ExtensionHostServices, @unchecked Sendable {
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

/// #1704 (OQ-191): an update over a trusted extension is reviewed before any copy only when it declares a permission the
/// installed version lacks. The review is the registry's seam (a recorder here, never a real alert); every registry,
/// source and user folder lives in the row's tempDir().
@MainActor
final class ExtensionUpdatePermissionReviewTests: XCTestCase {
    private let extID = "eu.example.permreview"

    private struct Review { let title: String; let added: [String]; let installedVersion: String? }

    private func makeRegistry(_ userDir: URL) -> ExtensionRegistry {
        ExtensionRegistry(systemDir: nil, userDir: userDir, hostVersion: "2.0.0",
                          defaults: scratchDefaults("ext-update-permission-review"), services: InertServices())
    }

    private func writeSource(_ dir: URL, version: String, permissions: [String], market: Bool = false) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let perms = (permissions.isEmpty ? "" : "permissions = [" + permissions.map { "\"\($0)\"" }.joined(separator: ", ") + "]\n")
            + (market ? "update_url = \"prosper://market/\(extID)\"\n" : "")
        try """
        [extension]
        id = "\(extID)"
        name = "permreview"
        title = "Perm Review"
        description = "A test extension"
        version = "\(version)"
        author = "tester"
        \(perms)
        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "-- \(version)\nfunction noop() end".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    }

    /// The installed folder's own version, read off disk (nil: no installed manifest).
    private func installedVersion(_ userDir: URL) -> String? {
        let toml = userDir.appendingPathComponent(extID).appendingPathComponent("extension.toml")
        guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return nil }
        return text.range(of: #"version = "[^"]*""#, options: .regularExpression).map { String(text[$0]) }
    }

    /// Installs 1.0.0 with `had`, trusts it, and points the review seam at a recorder answering `answer`.
    private func installedTrusted(had: [String], answer: Bool, market: Bool = false, reviews: @escaping (Review) -> Void)
        throws -> (registry: ExtensionRegistry, userDir: URL, tmp: URL) {
        let tmp = tempDir(), userDir = tmp.appendingPathComponent("user")
        let registry = makeRegistry(userDir)
        try writeSource(tmp.appendingPathComponent("v1"), version: "1.0.0", permissions: had, market: market)
        try registry.installLocal(from: tmp.appendingPathComponent("v1"))
        try registry.trust(id: extID)
        registry.reviewNewPermissions = { [unowned self] title, added in
            reviews(Review(title: title, added: added, installedVersion: self.installedVersion(userDir)))
            return answer
        }
        return (registry, userDir, tmp)
    }

    func testSamePermissionsUpdateInstallsWithoutReview() throws {
        var reviews: [Review] = []
        let (registry, userDir, tmp) = try installedTrusted(had: ["full-disk-access"], answer: false) { reviews.append($0) }
        try writeSource(tmp.appendingPathComponent("v2"), version: "1.1.0", permissions: ["full-disk-access"])
        try registry.installLocal(from: tmp.appendingPathComponent("v2"))
        XCTAssertEqual(reviews.count, 0, "a plain update installs quietly")
        XCTAssertEqual(installedVersion(userDir), #"version = "1.1.0""#)
        XCTAssertTrue(registry.isTrusted(id: extID))
    }

    func testAddedPermissionStopsAtReviewAndCopiesNothingUntilAccepted() throws {
        var reviews: [Review] = []
        let (registry, userDir, tmp) = try installedTrusted(had: [], answer: true) { reviews.append($0) }
        try writeSource(tmp.appendingPathComponent("v2"), version: "1.1.0", permissions: ["full-disk-access"])
        try registry.installLocal(from: tmp.appendingPathComponent("v2"))
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews.last?.added, ["full-disk-access"])
        XCTAssertEqual(reviews.last?.title, "Perm Review")
        XCTAssertEqual(reviews.last?.installedVersion, #"version = "1.0.0""#, "the review comes before any copy")
        XCTAssertEqual(installedVersion(userDir), #"version = "1.1.0""#)
        XCTAssertTrue(registry.isTrusted(id: extID))
    }

    func testDeclinedLeavesInstalledVersionUntouched() throws {
        var reviews: [Review] = []
        let (registry, userDir, tmp) = try installedTrusted(had: ["full-disk-access"], answer: false) { reviews.append($0) }
        let before = try FileManager.default.contentsOfDirectory(atPath: userDir.path).sorted()
        try writeSource(tmp.appendingPathComponent("v2"), version: "1.1.0", permissions: ["full-disk-access", "automation"])
        XCTAssertThrowsError(try registry.installLocal(from: tmp.appendingPathComponent("v2"))) { error in
            XCTAssertEqual(error as? ExtensionError, .newPermissionsDeclined(id: extID, added: ["automation"]))
        }
        XCTAssertEqual(reviews.last?.added, ["automation"], "only the permission the installed version lacks")
        XCTAssertEqual(installedVersion(userDir), #"version = "1.0.0""#)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: userDir.path).sorted(), before, "no stage left")
        XCTAssertEqual(registry.record(id: extID)?.manifest.extension.version, "1.0.0")
        XCTAssertTrue(registry.isTrusted(id: extID))
    }

    /// An untrusted install runs nothing until Trust, which is its review: no extra question.
    func testUntrustedUpdateWithNewPermissionIsNotReviewed() throws {
        var reviews: [Review] = []
        let (registry, userDir, tmp) = try installedTrusted(had: [], answer: false) { reviews.append($0) }
        try registry.untrust(id: extID)
        try writeSource(tmp.appendingPathComponent("v2"), version: "1.1.0", permissions: ["full-disk-access"])
        try registry.installLocal(from: tmp.appendingPathComponent("v2"))
        XCTAssertEqual(reviews.count, 0)
        XCTAssertEqual(installedVersion(userDir), #"version = "1.1.0""#)
    }

    // MARK: the update check (#1704 review): the daily check never asks; the person's Check for Updates does

    /// Points the market seams at a fake: the index lists 1.1.0, each download is a fresh copy of `v2` in its own
    /// download-named work folder under the row's tempDir (the discard removes it). Returns the download counter.
    private func wireMarket(_ registry: ExtensionRegistry, tmp: URL) throws -> FetchCounter {
        let source = tmp.appendingPathComponent("v2"), work = tmp.appendingPathComponent("work")
        try writeSource(source, version: "1.1.0", permissions: ["full-disk-access"])
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let counter = FetchCounter()
        registry.marketTempRoot = work
        let id = extID
        registry.marketIndex = { [id: "1.1.0"] }
        registry.marketFetch = { _, _ in
            let folder = work.appendingPathComponent("prosper-market-\(counter.next())", isDirectory: true)
            let dir = folder.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: dir)
            return dir
        }
        return counter
    }

    func testDailyCheckHoldsAnUpdateWithNewPermissionsWithoutAskingOrCopying() async throws {
        var reviews: [Review] = []
        let (registry, userDir, tmp) = try installedTrusted(had: [], answer: true, market: true) { reviews.append($0) }
        let fetches = try wireMarket(registry, tmp: tmp)
        await registry.checkForUpdates(force: false)
        XCTAssertEqual(reviews.count, 0, "the daily check asked")
        XCTAssertEqual(fetches.count, 1)
        XCTAssertEqual(installedVersion(userDir), #"version = "1.0.0""#)
        XCTAssertEqual(registry.updateWaitingNote(id: extID),
                       "Update waits for your review (asks for: full-disk-access). Click Check for Updates to review it.")
        XCTAssertTrue(registry.updateStatus == nil, "a held update is not a failure the daily check reports")
        XCTAssertTrue(registry.isTrusted(id: extID))
    }

    func testCheckForUpdatesStartedByThePersonAsksAndInstallsTheHeldUpdate() async throws {
        var reviews: [Review] = []
        let (registry, userDir, tmp) = try installedTrusted(had: [], answer: true, market: true) { reviews.append($0) }
        _ = try wireMarket(registry, tmp: tmp)
        await registry.checkForUpdates(force: false)
        XCTAssertEqual(reviews.count, 0)
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews.last?.added, ["full-disk-access"])
        XCTAssertEqual(reviews.last?.installedVersion, #"version = "1.0.0""#, "the review comes before any copy")
        XCTAssertEqual(installedVersion(userDir), #"version = "1.1.0""#)
        XCTAssertTrue(registry.updateWaitingNote(id: extID) == nil)
        XCTAssertEqual(registry.updateStatus, "Updated 1 extension.")
    }

    func testCheckForUpdatesDeclinedByThePersonKeepsItWaitingNotFailed() async throws {
        var reviews: [Review] = []
        let (registry, userDir, tmp) = try installedTrusted(had: [], answer: false, market: true) { reviews.append($0) }
        _ = try wireMarket(registry, tmp: tmp)
        await registry.checkForUpdates(force: true)
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(installedVersion(userDir), #"version = "1.0.0""#)
        XCTAssertEqual(registry.updateStatus, "1 update waits for your review.")
        XCTAssertTrue(registry.updateWaitingNote(id: extID) != nil)
    }
}

/// Counts the fake downloads; called off the main actor.
private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func next() -> Int { lock.withLock { n += 1; return n } }
}
