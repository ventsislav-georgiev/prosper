import CryptoKit
import Foundation
import os
import XCTest
@testable import ProsperApp

/// #1285: the clipboard store's key source and the device key file. Every store and key file
/// lives in a tempDir(); keys come from the keySource seam or DatabaseKey.fetchOrCreate(at:) on a
/// tempDir path, never the operator's key or store. No key or clip bytes go into a message.
@MainActor
final class ClipboardKeyTests: XCTestCase {

    private struct NoKey: Error {}

    /// Every file in `dir`, name to bytes.
    private func snapshot(_ dir: URL) -> [String: Data] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [String: Data] = [:]
        for name in names { out[name] = try? Data(contentsOf: dir.appending(path: name)) }
        return out
    }

    /// A history of two clips sealed under `key` in `dir`, every file aged past the sweep's minimum.
    private func sealedHistory(_ dir: URL, _ key: SymmetricKey) throws -> [String: Data] {
        let s = ClipboardStore(dir: dir, keySource: { key })
        s.addText("alpha")
        s.addText("beta")
        XCTAssertEqual(s.items.count, 2)
        let old = Date(timeIntervalSinceNow: -Double(ClipboardStore.sweepMinAge * 6))
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appending(path: name).path)
        }
        let files = snapshot(dir)
        XCTAssertEqual(files.count, 3, "an index and two blobs")
        return files
    }

    /// A key source that throws until `open` is set.
    private func gatedSource(_ key: SymmetricKey, _ open: OSAllocatedUnfairLock<Bool>) -> ClipboardCrypto.KeySource {
        { if open.withLock({ $0 }) { return key }; throw NoKey() }
    }

    func testNoKeyWritesNothingAndLeavesTheSealedIndexByteIdentical() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        let before = try sealedHistory(d, key)
        let source = gatedSource(key, OSAllocatedUnfairLock(initialState: false))

        let s = ClipboardStore(dir: d, keySource: source)
        XCTAssertTrue(s.items.isEmpty, "the unread history is not shown as empty-and-saved")
        XCTAssertEqual(s.notice, ClipboardStore.keyNotice)
        s.addText("gamma")
        XCTAssertEqual(s.items.count, 1)
        XCTAssertTrue(s.items.first.flatMap { s.text(for: $0) } == "gamma", "the clip is kept in memory")
        if let g = s.items.first { s.togglePin(g) }
        XCTAssertTrue(snapshot(d) == before, "no file written or replaced while the key is missing")

        _ = ClipboardStore(dir: d, keySource: source)  // a relaunch: load and the sweep's path
        XCTAssertTrue(snapshot(d) == before, "no blob swept while the key is missing")
    }

    func testKeyBackPersistsTheHeldClipsAndTheOldIndexStillOpens() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        _ = try sealedHistory(d, key)
        let open = OSAllocatedUnfairLock(initialState: false)
        let s = ClipboardStore(dir: d, keySource: gatedSource(key, open))
        s.addText("gamma")
        open.withLock { $0 = true }
        s.addText("delta")
        XCTAssertTrue(s.notice == nil)
        XCTAssertEqual(s.items.count, 4, "the history on disk joins the clips captured meanwhile")

        let again = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(Set(again.items.compactMap { again.text(for: $0) }) == ["alpha", "beta", "gamma", "delta"], "every clip reads back")
    }

    /// alpha (pinned) and beta (unpinned) sealed under `key` in `dir`; returns each one's blob name.
    private func pinnedAndPlain(_ dir: URL, _ key: SymmetricKey) -> (pinned: String, plain: String) {
        let s = ClipboardStore(dir: dir, keySource: { key })
        s.addText("alpha")
        s.addText("beta")
        if let a = s.items.first(where: { s.text(for: $0) == "alpha" }) { s.togglePin(a) }
        let p = s.items.first { $0.pinned }?.blobFile ?? ""
        let u = s.items.first { !$0.pinned }?.blobFile ?? ""
        return (p, u)
    }

    private func blobNames(_ dir: URL) -> Set<String> {
        Set(snapshot(dir).keys.filter { $0 != "index.json" })
    }

    func testClearAllWithoutKeyIsNotUndoneWhenTheKeyReturns() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        let names = pinnedAndPlain(d, key)
        XCTAssertTrue(!names.pinned.isEmpty && !names.plain.isEmpty && names.pinned != names.plain)
        let open = OSAllocatedUnfairLock(initialState: false)
        let s = ClipboardStore(dir: d, keySource: gatedSource(key, open))
        s.addText("gamma")
        s.clearAll()
        s.clearAll()  // a second one changes nothing
        XCTAssertTrue(s.items.isEmpty)
        s.addText("delta")
        open.withLock { $0 = true }
        s.addText("epsilon")

        let again = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(Set(again.items.compactMap { again.text(for: $0) }) == ["alpha", "delta", "epsilon"],
                      "the unpinned disk row and the cleared clip are gone, the pinned one and the later clips stay")
        XCTAssertEqual(again.items.filter(\.pinned).count, 1)
        let blobs = blobNames(d)
        XCTAssertTrue(blobs.contains(names.pinned), "the pinned row keeps its blob")
        XCTAssertFalse(blobs.contains(names.plain), "the cleared disk row's blob is removed")
        XCTAssertEqual(blobs.count, 3, "alpha, delta, epsilon")
    }

    func testClearAllWithoutKeyThenQuitLeavesTheDiskAsItWas() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        _ = pinnedAndPlain(d, key)
        let before = snapshot(d)
        do {
            let s = ClipboardStore(dir: d, keySource: gatedSource(key, OSAllocatedUnfairLock(initialState: false)))
            s.addText("gamma")
            s.clearAll()
        }
        XCTAssertTrue(snapshot(d) == before, "nothing on disk changed: the record lives in memory only")
        let again = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(Set(again.items.compactMap { again.text(for: $0) }) == ["alpha", "beta"], "the next launch sees every saved row")
    }

    func testClearAllWithTheKeyPresentIsUnchanged() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        let names = pinnedAndPlain(d, key)
        let s = ClipboardStore(dir: d, keySource: { key })
        s.clearAll()
        XCTAssertTrue(s.items.compactMap { s.text(for: $0) } == ["alpha"])
        XCTAssertTrue(blobNames(d) == [names.pinned])
    }

    func testFailedFetchIsAskedAgainOnTheNextPersist() {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        // Fails the first call only (the blob write), then succeeds (the persist right after).
        let s = ClipboardStore(dir: d, keySource: {
            if calls.withLock({ $0 += 1; return $0 }) == 1 { throw NoKey() }
            return key
        })
        s.addText("one")
        XCTAssertGreaterThanOrEqual(calls.withLock { $0 }, 2)
        XCTAssertTrue(s.notice == nil)

        let again = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(again.items.compactMap { again.text(for: $0) } == ["one"], "the clip reads back under the key")
    }

    func testNoFileIsEverSealedUnderTheEmptySecretKey() throws {
        let root = tempDir()
        let blocker = root.appending(path: "blocker")
        try Data().write(to: blocker)
        // The key file's folder cannot be created (its parent is a file): the fetch throws.
        let keyURL = blocker.appending(path: "prosper/device.key")
        XCTAssertThrowsError(try DatabaseKey.fetchOrCreate(at: keyURL))

        let d = root.appending(path: "store")
        let s = ClipboardStore(dir: d, keySource: { try ClipboardCrypto.fileKey(keyURL) })
        s.addText("secret-like")
        s.addRemote(id: UUID(), date: Date(), source: "phone", sha256: "00", .text("from the phone"))
        if let g = s.items.first { s.togglePin(g) }
        XCTAssertEqual(s.notice, ClipboardStore.keyNotice)
        let files = snapshot(d)
        let weak = SymmetricKey(data: SHA256.hash(data: Data()))
        let opened = files.values.filter { data in
            (try? AES.GCM.SealedBox(combined: data)).flatMap { try? AES.GCM.open($0, using: weak) } != nil
        }
        XCTAssertEqual(opened.count, 0, "nothing sealed under the empty-secret key")
        XCTAssertEqual(files.count, 0, "nothing written without a key")
    }

    func testMissingKeyFileIsCreated0600AndReadBack() throws {
        let url = tempDir().appending(path: "prosper/device.key")
        let first = try DatabaseKey.fetchOrCreate(at: url)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(try DatabaseKey.fetchOrCreate(at: url) == first, "the stored key is read back")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path),
                       ["device.key"], "no temp file left")
    }

    /// #1288 q2: the temp is created by open(2) with 0600 and is gone before persist returns, so it
    /// cannot be observed from outside (by construction, no seam); this pins the created file and
    /// folder state with a permissive umask and a pre-existing 0755 folder.
    func testKeyFileIsCreated0600UnderAPermissiveUmaskInAnExistingFolder() throws {
        let dir = tempDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let old = umask(0)
        defer { umask(old) }
        let url = dir.appending(path: "device.key")
        let key = try DatabaseKey.fetchOrCreate(at: url)
        XCTAssertEqual(key.count, 64)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["device.key"], "no temp left")
        XCTAssertTrue(try DatabaseKey.fetchOrCreate(at: url) == key)
    }

    func testMalformedKeyFileIsNeverReplaced() throws {
        let url = tempDir().appending(path: "device.key")
        let junk = Data("pdk1:not-a-key\n".utf8)
        try junk.write(to: url)
        XCTAssertThrowsError(try DatabaseKey.fetchOrCreate(at: url))
        XCTAssertTrue(try Data(contentsOf: url) == junk, "the file is byte-identical")
    }

    func testUnreadableKeyFileIsNeverReplaced() throws {
        // #1288: mode 0 does not stop root, so the unreadable state cannot be made (as the #1100 rows).
        try XCTSkipIf(geteuid() == 0, "running as root: mode 0 does not deny the read")
        let url = tempDir().appending(path: "device.key")
        let original = try DatabaseKey.fetchOrCreate(at: url)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        XCTAssertThrowsError(try DatabaseKey.fetchOrCreate(at: url))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertTrue(try Data(contentsOf: url) == bytes, "the file is byte-identical")
        XCTAssertTrue(try DatabaseKey.fetchOrCreate(at: url) == original, "the same key once readable")
    }
}
