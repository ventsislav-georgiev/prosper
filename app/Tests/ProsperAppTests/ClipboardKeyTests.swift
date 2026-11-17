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
        // R1288-m1: a cleared unpinned row back in the index has no blob, so the text set above drops it.
        XCTAssertEqual(again.items.count, 3, "alpha, delta, epsilon: no blobless ghost row")
        XCTAssertTrue(again.items.allSatisfy { again.text(for: $0) != nil }, "every row reads back")
        XCTAssertEqual(again.items.filter(\.pinned).count, 1)
        let blobs = blobNames(d)
        XCTAssertTrue(blobs.contains(names.pinned), "the pinned row keeps its blob")
        XCTAssertFalse(blobs.contains(names.plain), "the cleared disk row's blob is removed")
        XCTAssertEqual(blobs.count, 3, "alpha, delta, epsilon")
    }

    private func age(_ dir: URL) throws {
        let old = Date(timeIntervalSinceNow: -Double(ClipboardStore.sweepMinAge * 6))
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appending(path: name).path)
        }
    }

    /// #1294: the clear is written down without the key (an empty 0600 marker), so it survives a quit.
    func testClearAllWithoutKeyThenQuitLeavesOnlyTheMarkerAndTheNextLaunchKeepsThePinnedRows() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        let names = pinnedAndPlain(d, key)
        try age(d)
        let before = snapshot(d)
        do {
            let s = ClipboardStore(dir: d, keySource: gatedSource(key, OSAllocatedUnfairLock(initialState: false)))
            s.addText("gamma")
            s.clearAll()
        }
        var after = snapshot(d)
        let marker = after.removeValue(forKey: "index.cleared")
        // #1296: the marker holds the hex SHA-256 of the sealed index it was made against (was: empty).
        let hex = SHA256.hash(data: before["index.json"] ?? Data()).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(marker == Data(hex.utf8), "the marker names the sealed index it was made against")
        XCTAssertTrue(after == before, "every other file is byte-identical: no key, no write")
        let perms = try FileManager.default.attributesOfItem(atPath: d.appending(path: "index.cleared").path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        let again = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(again.items.compactMap { again.text(for: $0) } == ["alpha"], "only the pinned row is back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "index.cleared").path),
                      "the marker stays until a persist has written the index")
        XCTAssertTrue(blobNames(d) == [names.pinned, "index.cleared"], "the sweep removed the cleared row's blob")

        again.addText("zeta")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appending(path: "index.cleared").path), "gone after the persist")
        let third = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(Set(third.items.compactMap { third.text(for: $0) }) == ["alpha", "zeta"])
    }

    /// #1294: a relaunch that still has no key keeps the clear: the marker feeds the in-process path.
    func testMarkerSurvivesARelaunchWithoutTheKeyAndClearsOnceItReturns() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        let names = pinnedAndPlain(d, key)
        do {
            let s = ClipboardStore(dir: d, keySource: gatedSource(key, OSAllocatedUnfairLock(initialState: false)))
            s.clearAll()
        }
        let open = OSAllocatedUnfairLock(initialState: false)
        let s = ClipboardStore(dir: d, keySource: gatedSource(key, open))
        open.withLock { $0 = true }
        s.addText("delta")
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appending(path: "index.cleared").path))
        XCTAssertTrue(Set(s.items.compactMap { s.text(for: $0) }) == ["alpha", "delta"], "the unpinned disk row stays cleared")
        XCTAssertFalse(blobNames(d).contains(names.plain))
    }

    /// #1294: a marker with no index.json has nothing to clear: ignored and removed, nothing else made.
    func testMarkerWithNoIndexIsIgnoredAndRemoved() throws {
        let d = tempDir()
        let marker = d.appending(path: "index.cleared")
        XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: nil))
        let s = ClipboardStore(dir: d, keySource: { SymmetricKey(size: .bits256) })
        XCTAssertTrue(s.items.isEmpty)
        XCTAssertTrue(snapshot(d).isEmpty, "the marker is gone and no index was written")
    }

    /// #1294: a marker that cannot be made (a folder holds its name) is logged, never fatal; the in-process clear works.
    func testMarkerThatCannotBeWrittenIsNotFatal() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        let names = pinnedAndPlain(d, key)
        try FileManager.default.createDirectory(at: d.appending(path: "index.cleared"), withIntermediateDirectories: false)
        let open = OSAllocatedUnfairLock(initialState: false)
        let s = ClipboardStore(dir: d, keySource: gatedSource(key, open))
        s.clearAll()
        open.withLock { $0 = true }
        s.addText("delta")
        XCTAssertTrue(Set(s.items.compactMap { s.text(for: $0) }) == ["alpha", "delta"])
        XCTAssertFalse(blobNames(d).contains(names.plain))
        // #1296: a relaunch with the key keeps the rows added after the clear (a folder is no marker).
        let again = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(Set(again.items.compactMap { again.text(for: $0) }) == ["alpha", "delta"])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "index.cleared").path, isDirectory: &isDir) && isDir.boolValue,
                      "Prosper never removes it")
    }

    private func texts(_ s: ClipboardStore) -> Set<String> { Set(s.items.compactMap { s.text(for: $0) }) }

    /// #1296: a folder named index.cleared is not a marker: the unpinned rows stay, the folder stays.
    func testFolderNamedLikeTheMarkerDropsNothing() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        _ = pinnedAndPlain(d, key)
        try FileManager.default.createDirectory(at: d.appending(path: "index.cleared"), withIntermediateDirectories: false)
        try age(d)
        let s = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(texts(s) == ["alpha", "beta"])
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: d.appending(path: "index.cleared").path, isDirectory: &isDir) && isDir.boolValue)
    }

    /// #1296: a symlink named index.cleared (to a regular file) is not a marker, is not followed, is not removed.
    func testLinkNamedLikeTheMarkerDropsNothing() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        _ = pinnedAndPlain(d, key)
        let target = tempDir().appending(path: "target")
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))
        let link = d.appending(path: "index.cleared")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try age(d)
        let s = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(texts(s) == ["alpha", "beta"])
        s.addText("zeta")
        XCTAssertTrue((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path, "the link is left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    /// #1296: an empty marker (a #1294 build) still counts.
    func testEmptyMarkerStillCounts() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        _ = pinnedAndPlain(d, key)
        XCTAssertTrue(FileManager.default.createFile(atPath: d.appending(path: "index.cleared").path, contents: nil))
        try age(d)
        let s = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(texts(s) == ["alpha"])
    }

    /// #1296: a marker whose hash no longer matches index.json (crash before the unlink) is ignored, removed at the next persist.
    func testMarkerForAnotherIndexIsIgnoredAndRemovedAtTheNextPersist() throws {
        let d = tempDir()
        let key = SymmetricKey(size: .bits256)
        _ = pinnedAndPlain(d, key)
        do {
            let s = ClipboardStore(dir: d, keySource: gatedSource(key, OSAllocatedUnfairLock(initialState: false)))
            s.clearAll()
        }
        let markerURL = d.appending(path: "index.cleared")
        let stale = try Data(contentsOf: markerURL)
        XCTAssertFalse(stale.isEmpty)
        do {
            let s = ClipboardStore(dir: d, keySource: { key })
            s.addText("zeta")   // rewrites the index, unlinks the marker
        }
        XCTAssertTrue(FileManager.default.createFile(atPath: markerURL.path, contents: stale), "the unlink that did not happen")
        try age(d)
        let s = ClipboardStore(dir: d, keySource: { key })
        XCTAssertTrue(texts(s) == ["alpha", "zeta"], "the row added after the clear is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "still there until a persist")
        s.addText("eta")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
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

    /// #1294 n1: a umask that strips the owner's write bit would leave the open(2) mode 0400; fchmod makes it 0600.
    func testKeyFileIsExactly0600UnderAUmaskThatStripsTheOwnerBit() throws {
        let url = tempDir().appending(path: "device.key")
        let old = umask(0o277)
        defer { umask(old) }
        let key = try DatabaseKey.fetchOrCreate(at: url)
        XCTAssertEqual(key.count, 64)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
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
