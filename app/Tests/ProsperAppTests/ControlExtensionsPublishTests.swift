import AppKit
import Foundation
import XCTest
@testable import ProsperApp

/// #1903: extensions.publish over a fake registry (temp dirs, scratch defaults), a fake signed-in check, a fake live
/// version and a recording upload: never the network, never the stored session.
@MainActor
final class ControlExtensionsPublishTests: XCTestCase {
    private var notices: [String] = []
    private let uploads = UploadLog()

    override func tearDown() async throws {
        ControlExtensions.registry = { (NSApp?.delegate as? AppDelegate)?.extensionRegistry }
        ControlExtensions.fetchVersion = ControlExtensions.liveVersion
        ControlExtensions.publishCall = ControlExtensions.marketUpload
        ControlExtensions.signedIn = ControlExtensions.storedSession
        ControlExtensions.publishWorkRoot = FileManager.default.temporaryDirectory
        Preferences.agentControlEnabled = true
        try await super.tearDown()
    }

    private func write(_ dir: URL, id: String, system: Bool) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let toml = """
        [extension]
        id          = "\(id)"
        name        = "\(dir.lastPathComponent)"
        title       = "Mine"
        description = "Test fixture"
        version     = "1.2.3"
        author      = "example"
        license     = "MIT"
        system      = \(system)

        [extension.host]
        min_version = "2.0.0"
        api_level   = 1

        [extension.entry]
        main = "init.lua"

        """
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        try "return {}".write(to: dir.appendingPathComponent("lib/util.lua"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)   // left out, not refused
    }

    /// A trusted user extension (com.example.mine), an untrusted one (com.example.stranger), a system one (com.example.fake);
    /// signed in, nothing live, agent control on.
    @discardableResult
    private func fakeRegistry(link: Bool = false) throws -> (ExtensionRegistry, URL) {
        let root = tempDir()
        let mine = root.appendingPathComponent("user/mine")
        try write(mine, id: "com.example.mine", system: false)
        if link { try FileManager.default.createSymbolicLink(atPath: mine.appendingPathComponent("lib/link.lua").path, withDestinationPath: "util.lua") }
        try write(root.appendingPathComponent("user/stranger"), id: "com.example.stranger", system: false)
        try write(root.appendingPathComponent("system/fake"), id: "com.example.fake", system: true)
        let defaults = scratchDefaults("ctlpublish")
        defaults.set(["com.example.mine"], forKey: "trustedExtensionIDs")
        let registry = ExtensionRegistry(systemDir: root.appendingPathComponent("system"), userDir: root.appendingPathComponent("user"),
                                         hostVersion: "2.0.0", defaults: defaults)
        registry.discover()
        ControlExtensions.registry = { registry }
        ControlExtensions.signedIn = { true }
        ControlExtensions.fetchVersion = { _ in nil }
        let log = uploads
        ControlExtensions.publishCall = { manifest, blob, kind, _ in log.add(manifest.id, manifest.version, blob, kind) }
        ControlExtensions.publishWorkRoot = root
        Preferences.agentControlEnabled = true
        return (registry, root)
    }

    private func registry() -> ControlRegistry {
        var r = ControlRegistry()
        ControlRegistry.registerExtensions(&r)
        let changes = ControlChanges()
        changes.present = { [weak self] text, _ in self?.notices.append(text) }
        r.changes = changes
        return r
    }

    private func call(_ reg: ControlRegistry, _ id: String) async -> ControlReply {
        await reg.reply(to: try! JSONEncoder().encode(ControlRequest(cmd: "extensions.publish", args: ["id": .string(id)])))
    }

    /// A refusal: the error holds `text`, nothing was uploaded, logged or shown.
    private func assertRefused(_ reg: ControlRegistry, _ id: String, _ text: String, line: UInt = #line) async {
        let reply = await call(reg, id)
        XCTAssertFalse(reply.ok, "\(reply)", line: line)
        XCTAssertTrue(reply.error?.contains(text) == true, "\(reply)", line: line)
        XCTAssertEqual(uploads.calls.count, 0, "uploaded", line: line)
        XCTAssertTrue(reg.changes.entries.isEmpty, line: line)
        XCTAssertTrue(notices.isEmpty, line: line)
    }

    func testPublishUploadsThePackedFolderAndRepliesWithItsMembers() async throws {
        let (_, root) = try fakeRegistry()
        let log = uploads
        let token = NotificationCenter.default.addObserver(forName: ExtensionRow.published, object: nil, queue: nil) { n in
            log.post((n.userInfo as? [String: String]) ?? [:])
        }
        defer { NotificationCenter.default.removeObserver(token) }
        ControlExtensions.fetchVersion = { _ in "1.0.0" }   // an older version live: this one is ahead, as the row offers
        let reg = registry()
        let reply = await call(reg, "com.example.mine")
        XCTAssertTrue(reply.ok, "\(reply)")
        guard case .object(let o)? = reply.result else { return XCTFail("\(reply)") }
        XCTAssertEqual(o["id"], .string("com.example.mine"))
        XCTAssertEqual(o["version"], .string("1.2.3"))
        XCTAssertEqual(o["members"], .array(["extension.toml", "init.lua", "lib/util.lua"].map { .string($0) }), "the hidden file is left out")
        let sent = try XCTUnwrap(uploads.calls.last)
        XCTAssertEqual(uploads.calls.count, 1)
        XCTAssertEqual([sent.id, sent.version, sent.kind], ["com.example.mine", "1.2.3", "extension"])
        let tgz = root.appendingPathComponent("sent.tgz")
        try XCTUnwrap(Data(base64Encoded: sent.blob)).write(to: tgz)
        XCTAssertEqual(Set(try tar(["-tzf", tgz.path])), ["./extension.toml", "./init.lua", "./lib/util.lua"], "the fake got the packed blob")
        XCTAssertEqual(uploads.posted, [["id": "com.example.mine", "version": "1.2.3"]], "the rows' published version is refreshed")
        XCTAssertEqual(reg.changes.entries.count, 1)
        XCTAssertEqual(notices.last, "Agent published to the Marketplace: Mine 1.2.3, 3 files (no Undo: a published version stays live)")
        XCTAssertFalse(reg.changes.undo(reg.changes.entries.last?.id ?? -1), "no undo")
    }

    func testAnUnknownIdIsRefused() async throws {
        try fakeRegistry()
        await assertRefused(registry(), "com.example.nope", "unknown extension")
    }

    func testASystemExtensionIsRefused() async throws {
        try fakeRegistry()
        await assertRefused(registry(), "com.example.fake", "is built in")
    }

    func testAnUntrustedExtensionIsRefused() async throws {
        try fakeRegistry()
        await assertRefused(registry(), "com.example.stranger", "needs a trust approval")
    }

    func testAVersionAlreadyLiveOrNewerLiveIsRefused() async throws {
        try fakeRegistry()
        let reg = registry()
        for live in ["1.2.3", "2.0.0"] {
            ControlExtensions.fetchVersion = { _ in live }
            await assertRefused(reg, "com.example.mine", "is not newer than the live Marketplace version \(live)")
        }
    }

    func testNotSignedInIsRefusedBeforeTheMarketplaceIsAsked() async throws {
        try fakeRegistry()
        ControlExtensions.signedIn = { false }
        let log = uploads
        ControlExtensions.fetchVersion = { _ in log.ask(); return nil }
        await assertRefused(registry(), "com.example.mine", "Sign in to publish extensions.")
        XCTAssertEqual(uploads.asked, 0, "the live version was fetched")
    }

    func testAPlanRefusalIsTheError() async throws {
        try fakeRegistry(link: true)
        await assertRefused(registry(), "com.example.mine", "Can't publish symbolic links (every install refuses them): lib/link.lua")
    }

    func testAgentControlOffRefusesAndUploadsNothing() async throws {
        try fakeRegistry()
        Preferences.agentControlEnabled = false
        await assertRefused(registry(), "com.example.mine", ControlChanges.offError)
    }

    func testDescribeMarksPublishAsMutating() {
        XCTAssertEqual(registry().commands["extensions.publish"]?.mutates, true)
    }

    private func tar(_ args: [String]) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// The uploads the fake was asked for (called off the main actor).
private final class UploadLog: @unchecked Sendable {
    struct Call { let id, version, blob, kind: String }
    private let lock = NSLock()
    private var list: [Call] = [], notes: [[String: String]] = [], asks = 0
    var calls: [Call] { lock.withLock { list } }
    var posted: [[String: String]] { lock.withLock { notes } }
    var asked: Int { lock.withLock { asks } }
    func post(_ info: [String: String]) { lock.withLock { notes.append(info) } }
    func ask() { lock.withLock { asks += 1 } }
    func add(_ id: String, _ version: String, _ blob: String, _ kind: String) { lock.withLock { list.append(Call(id: id, version: version, blob: blob, kind: kind)) } }
}
