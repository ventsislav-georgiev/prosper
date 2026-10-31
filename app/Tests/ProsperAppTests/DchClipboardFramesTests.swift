import AppKit
import Combine
import ImageIO
import Network
import os
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import ProsperApp

/// #617: clipboard history both ways over Remote Terminal, through DchConnection.handle
/// and the sendOverride frame sink. Every store is a ClipboardStore(dir:) on a tempDir()
/// (ClipboardCrypto's key is per-process under XCTest), the received-files folder and the
/// disk-space probe are seams, and the pasteboard is Pasteboard.general's private test one.
/// The NWConnection is never started. #632 owns the History row UI (progress bar, a paste
/// that waits, Esc); here only ClipboardStore.receiving and cancel(id) are tested.
@MainActor
final class DchClipboardFramesTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
        var closed = 0
    }

    private struct Rig {
        let conn: DchConnection
        let queue: DispatchQueue
        let frames: Frames
        let store: ClipboardStore
        let received: URL
    }

    private func rig(on: Bool = true, free: Int64? = nil, memoryMax: Int? = nil, maxPixels: Int? = nil,
                     label: String = #function) -> Rig {
        let store = ClipboardStore(dir: tempDir(label + "-store"))
        let received = tempDir(label + "-recv")
        var o = DchClipboardOps()
        o.enabled = { on }
        o.store = { store }
        o.receivedDir = { received }
        o.freeSpace = { _ in free }
        if let memoryMax { o.memoryMax = { _ in memoryMax } }
        if let maxPixels { o.maxPixels = maxPixels }
        let queue = DispatchQueue(label: "test.dchconn.clipboard")
        let frames = Frames()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"),
                                 onClose: { @Sendable _ in frames.lock.withLock { frames.closed += 1 } })
        conn.sendOverride = { f in frames.lock.withLock { frames.all.append(f) } }
        conn.clipboard = o
        return Rig(conn: conn, queue: queue, frames: frames, store: store, received: received)
    }

    // MARK: Frame helpers

    private static func type(_ f: Data) -> UInt8 { f[f.startIndex] }
    private static func payload(_ f: Data) -> Data { f.subdata(in: (f.startIndex + 5)..<f.endIndex) }
    private static func json(_ f: Data) -> Any? { try? JSONSerialization.jsonObject(with: payload(f)) }
    private static func object(_ f: Data?) -> [String: Any] { f.flatMap { json($0) as? [String: Any] } ?? [:] }
    private static func message(_ f: Data?) -> String { object(f)["message"] as? String ?? "" }
    private static let finalTypes: Set<UInt8> = [DchFrame.ok, DchFrame.error, DchFrame.clipboardResp]

    private func all(_ r: Rig) -> [Data] { r.frames.lock.withLock { r.frames.all } }
    private func finals(_ r: Rig) -> [Data] { all(r).filter { Self.finalTypes.contains(Self.type($0)) } }

    private func handle(_ r: Rig, _ type: UInt8, _ obj: Any) {
        handle(r, type, raw: try! JSONSerialization.data(withJSONObject: obj))
    }

    private func handle(_ r: Rig, _ type: UInt8, raw: Data) {
        r.queue.sync { r.conn.handle(type: type, payload: raw) }
    }

    /// Spins main (the ops hop there) until `cond` or 10 s.
    @discardableResult
    private func spin(until cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(10)
        while !cond() {
            guard Date() < end else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return true
    }

    /// Waits for the `n`-th final reply, then checks no other final follows.
    @discardableResult
    private func final(_ r: Rig, _ n: Int = 1, file: StaticString = #filePath, line: UInt = #line) -> Data? {
        XCTAssertTrue(spin { finals(r).count >= n }, "final reply \(n)", file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        r.queue.sync {}
        XCTAssertEqual(finals(r).count, n, "exactly one final reply per request", file: file, line: line)
        return finals(r).last
    }

    private func request(_ r: Rig, _ type: UInt8, _ obj: Any = [String: Any](), file: StaticString = #filePath,
                         line: UInt = #line) -> Data? {
        let before = finals(r).count
        handle(r, type, obj)
        return final(r, before + 1, file: file, line: line)
    }

    private static func bytes(_ n: Int, seed: Int = 0) -> Data {
        // ASCII a-z from `seed`, valid UTF-8 text; appended whole so a debug build stays quick.
        let abc = Array("abcdefghijklmnopqrstuvwxyz".utf8), p = Data(abc[(seed % 26)...] + abc[..<(seed % 26)])
        var d = Data(capacity: n)
        while d.count < n { d.append(p.prefix(n - d.count)) }
        return d
    }

    private static func png(_ w: Int, _ h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dst)
        return out as Data
    }

    private func header(_ data: Data, id: UUID = UUID(), kind: String = "text", date: Date = Date(), name: String? = nil,
                        live: Bool = false, sha: String? = nil) -> [String: Any] {
        var h: [String: Any] = ["id": id.uuidString, "date": DchClipboardOps.wireDate(date), "kind": kind, "source": "iPhone",
                                "size": data.count, "sha256": sha ?? ClipboardStore.sha256(data), "live": live]
        if let name { h["name"] = name }
        return h
    }

    /// 0x10 frames of at most 1 MB over data[from..<to].
    private func feed(_ r: Rig, _ data: Data, from: Int = 0, to: Int? = nil) {
        var at = from
        let end = to ?? data.count
        while at < end {
            let next = min(at + DchClipboardOps.chunk, end)
            handle(r, DchFrame.data, raw: data.subdata(in: at..<next))
            at = next
        }
    }

    private func dir(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func added(_ f: Data?) -> [String] { Self.object(f)["added"] as? [String] ?? [] }
    private func skipped(_ f: Data?) -> [[String: String]] { Self.object(f)["skipped"] as? [[String: String]] ?? [] }

    // MARK: - Codes, gate, toggle

    func testFrameCodesAreThePhonesContractAndCollideWithNone() {
        XCTAssertEqual([DchFrame.clipboardList, DchFrame.clipboardItem, DchFrame.putClipboardText, DchFrame.clipboardItemResp,
                        DchFrame.clipboardResp, DchFrame.addClipboardHistory, DchFrame.clipboardUpload],
                       [0x15, 0x16, 0x17, 0x1a, 0x1d, 0x22, 0x23])
        let every: [UInt8] = [DchFrame.attach, DchFrame.create, DchFrame.list, DchFrame.kill, DchFrame.resize, DchFrame.rename,
                              DchFrame.redraw, DchFrame.machineInfo, DchFrame.snapshot, DchFrame.putClipboard, DchFrame.history,
                              DchFrame.revive, DchFrame.restart, DchFrame.stop, DchFrame.library, DchFrame.pin, DchFrame.forget,
                              DchFrame.forgetAll, DchFrame.data, DchFrame.listResp, DchFrame.exit, DchFrame.error, DchFrame.ok,
                              DchFrame.machineInfoResp, DchFrame.snapshotResp, DchFrame.historyResp, DchFrame.libraryResp,
                              DchFrame.clipboardList, DchFrame.clipboardItem, DchFrame.putClipboardText,
                              DchFrame.clipboardItemResp, DchFrame.clipboardResp, DchFrame.addClipboardHistory,
                              DchFrame.clipboardUpload]
        XCTAssertEqual(Set(every).count, every.count, "no two frames share a code")
    }

    func testClipboardIsAdvertisedOnlyWhileHistoryAndTheToggleAreOn() {
        let d = Preferences.defaults
        defer {
            d.removeObject(forKey: "clipboardSyncWithPhone")
            d.removeObject(forKey: "clipboardHistoryEnabled")
        }
        d.removeObject(forKey: "clipboardSyncWithPhone")
        d.removeObject(forKey: "clipboardHistoryEnabled")
        XCTAssertFalse(Preferences.clipboardSyncWithPhone, "default OFF")
        XCTAssertFalse(Preferences.clipboardSyncActive)
        XCTAssertFalse(SettingsModel().clipboardSyncWithPhone)
        XCTAssertFalse(DchClipboardOps().enabled(), "the default gate reads the prefs")
        Preferences.clipboardSyncWithPhone = true
        XCTAssertTrue(Preferences.clipboardSyncActive)
        XCTAssertTrue(DchClipboardOps().enabled())
        Preferences.clipboardHistoryEnabled = false
        XCTAssertFalse(Preferences.clipboardSyncActive, "history off closes it too")
        XCTAssertFalse(DchClipboardOps().enabled())

        XCTAssertFalse((DchFrame.machineInfo(deviceID: "i", hostname: "h", wakeId: nil)["ops"] as? [String] ?? []).contains("clipboard"))
        XCTAssertEqual(DchFrame.machineInfo(deviceID: "i", hostname: "h", wakeId: nil, clipboard: true)["ops"] as? [String],
                       DchFrame.ops + ["clipboard"])
        XCTAssertFalse(DchFrame.ops.contains("clipboard"))
    }

    /// Through handle: the handshake's ops follow the connection's gate.
    func testHandshakeOpsFollowTheGate() {
        for on in [false, true] {
            let r = rig(on: on)
            handle(r, DchFrame.machineInfo, raw: Data())
            let ops = Self.object(all(r).first)["ops"] as? [String] ?? []
            XCTAssertEqual(ops.contains("clipboard"), on)
        }
    }

    func testEveryClipboardRequestIsRefusedWhileSyncIsOff() {
        let r = rig(on: false)
        r.store.addRemote(id: UUID(), date: Date(), source: "iPhone", sha256: "x", .text("kept"))
        let count = Pasteboard.general.changeCount
        let requests: [(UInt8, Any)] = [
            (DchFrame.clipboardList, [String: Any]()), (DchFrame.clipboardItem, ["id": r.store.items[0].id.uuidString]),
            (DchFrame.putClipboardText, ["text": "x"]),
            (DchFrame.addClipboardHistory, ["items": [["id": UUID().uuidString, "date": DchClipboardOps.wireDate(Date()), "kind": "text", "text": "y"]]]),
            (DchFrame.clipboardUpload, header(Data("z".utf8))),
        ]
        for (i, (t, o)) in requests.enumerated() {
            let f = request(r, t, o)
            XCTAssertEqual(f.map(Self.type), DchFrame.error, "\(t)")
            XCTAssertEqual(Self.message(f), "clipboard sync is off", "\(t)")
            XCTAssertEqual(finals(r).count, i + 1)
        }
        handle(r, DchFrame.data, raw: Data("z".utf8))
        r.queue.sync {}
        XCTAssertEqual(r.store.items.count, 1)
        XCTAssertTrue(r.store.receiving.isEmpty)
        XCTAssertEqual(Pasteboard.general.changeCount, count, "nothing reached the pasteboard")
        XCTAssertEqual(all(r).count, requests.count, "no stream frame either")
    }

    /// Settings › General › Remote Terminal: the row's label fits on one line inside the
    /// pane's narrowest card at 1.0 and 0.85, and the PNGs land for a look.
    func testSyncToggleRendersOffscreenUnclippedAt1And085() throws {
        Preferences.defaults.removeObject(forKey: "clipboardSyncWithPhone")
        let model = SettingsModel()
        XCTAssertFalse(model.clipboardSyncWithPhone)
        let out = tempDir(), saved = ThemeRuntime.scale
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        defer { ThemeRuntime.scale = saved }
        for scale in [1.0, 0.85] as [CGFloat] {
            ThemeRuntime.scale = scale
            // The window's minimum width less the sidebar, the pane's and the card's insets.
            let room = sz(820) - sz(302) - 2 * sz(26) - 2 * sz(16)
            let natural = NSHostingView(rootView: ClipboardSyncToggle(model: model).fixedSize())
            XCTAssertLessThanOrEqual(natural.fittingSize.width, room, "label and switch fit at \(scale)")
            let fitted = NSHostingView(rootView: ClipboardSyncToggle(model: model).frame(width: room))
            XCTAssertEqual(fitted.fittingSize.height, natural.fittingSize.height, accuracy: 0.5, "one line, no wrap at \(scale)")
            let card = NSHostingView(rootView: NeonSection("Remote Terminal") { ClipboardSyncToggle(model: model) }
                .frame(width: room + 2 * sz(16)).padding(sz(16)).background(Color(white: 0.1)).preferredColorScheme(.dark))
            card.frame = CGRect(origin: .zero, size: card.fittingSize)
            card.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            card.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(card.bitmapImageRepForCachingDisplay(in: card.bounds))
            card.cacheDisplay(in: card.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("settings-617-clipboard-sync-\(scale).png"))
            if let extra { try png.write(to: extra.appendingPathComponent("settings-617-clipboard-sync-\(scale).png")) }
        }
    }

    // MARK: - The store

    /// An index.json from before #617 (no source, no sha256; nor pinned/title) still loads.
    func testOldStoreWithoutSourceOrShaStillLoads() throws {
        let d = tempDir()
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","kind":"text","createdAt":700000000,"preview":"hi","byteCount":2,"blobFile":"a.txt"}]"#
        try Data(old.utf8).write(to: d.appendingPathComponent("index.json"))
        try Data("hi".utf8).write(to: d.appendingPathComponent("a.txt"))
        let s = ClipboardStore(dir: d)
        XCTAssertEqual(s.items.map(\.id), [id])
        let first = try XCTUnwrap(s.items.first)   // a crash here would skip tempDir's teardown
        XCTAssertNil(first.source)
        XCTAssertNil(first.sha256)
        XCTAssertEqual(first.wireSource, "Mac")
        XCTAssertEqual(s.text(for: first), "hi")
        // A phone item round-trips through the sealed index with its source and hash.
        let pid = UUID()
        XCTAssertTrue(s.addRemote(id: pid, date: Date(timeIntervalSince1970: 1), source: "iPhone", sha256: "ab", .text("yo")))
        let again = ClipboardStore(dir: d)
        XCTAssertEqual(again.item(pid)?.source, "iPhone")
        XCTAssertEqual(again.item(pid)?.sha256, "ab")
        XCTAssertEqual(again.item(id)?.wireSource, "Mac")
        let index = try Data(contentsOf: d.appendingPathComponent("index.json"))
        XCTAssertNil(index.range(of: Data("iPhone".utf8)), "the index stays sealed")
    }

    /// Review R1: under XCTest the shared store never points at the operator's store.
    func testSharedStoreUnderXCTestIsAThrowawayDir() {
        let d = ClipboardStore.defaultDir.standardizedFileURL.path
        XCTAssertEqual(d, URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prosper-xctest-clipboard").standardizedFileURL.path)
        XCTAssertFalse(d.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path + "/Application Support"))
        XCTAssertFalse(d.contains("/prosper-tests/"), "outside the leak-checked root")
        XCTAssertEqual(ClipboardStore.shared.dir.standardizedFileURL.path, d)
    }

    /// A Mac capture stores its sha256, so a phone copy of the same text dedupes against it.
    func testMacCaptureStoresItsShaForDedupe() {
        let s = ClipboardStore(dir: tempDir())
        s.addText("same words")
        XCTAssertEqual(s.items.first?.sha256, ClipboardStore.sha256(Data("same words".utf8)))
        XCTAssertTrue(s.dedupe(sha256: ClipboardStore.sha256(Data("same words".utf8)), date: .distantPast))
        XCTAssertFalse(s.dedupe(sha256: ClipboardStore.sha256(Data("other".utf8)), date: .distantPast))
    }

    /// A huge text skips the link detector (it ran 5 s on main for 3 MB in a debug build).
    func testClassifySkipsTheDetectorPast64KB() {
        XCTAssertEqual(ClipboardStore.classify("https://example.com/a"), .link)
        let long = "https://example.com/" + String(repeating: "a", count: 64 << 10)
        XCTAssertEqual(ClipboardStore.classify(long), .text)
    }

    /// The live:true write is in history already; the monitor's next poll records no copy.
    func testMonitorRecordsNoSecondCopyOfAnIgnoredChange() {
        let s = ClipboardStore(dir: tempDir())
        let pb = NSPasteboard(name: NSPasteboard.Name("com.prosper.tests.clipboard.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let m = ClipboardMonitor()
        m.store = { s }
        pb.clearContents()
        pb.setString("prime", forType: .string)
        m.poll(pb)
        let n0 = s.items.count
        pb.clearContents()
        pb.setString("from the phone", forType: .string)
        m.ignoreHistory(changeCount: pb.changeCount)
        m.poll(pb)
        XCTAssertEqual(s.items.count, n0, "the ignored change is not recorded")
        pb.clearContents()
        pb.setString("copied on the Mac", forType: .string)
        m.poll(pb)
        XCTAssertEqual(s.items.count, n0 + 1)
        XCTAssertEqual(s.items.first?.preview, "copied on the Mac")
    }

    // MARK: - clipboardList 0x15

    func testListIsNewestFirstWithSinceBeforeLimitAndTheWireFields() throws {
        let r = rig()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)   // 2023: before the Mac capture
        let ids = (0..<3).map { _ in UUID() }
        let long = String(repeating: "x", count: 3000)
        r.store.addRemote(id: ids[0], date: t0, source: "iPhone", sha256: "0", .text(long))
        r.store.addRemote(id: ids[1], date: t0 + 1.5, source: "iPhone", sha256: "1", .text("https://example.com"))
        r.store.addRemote(id: ids[2], date: t0 + 3, source: "iPhone", sha256: "2", .text("third"))
        r.store.addText("on the mac")   // now: the newest, a Mac capture
        r.store.togglePin(r.store.item(ids[0])!)  // pinned sorts first in the store, never on the wire

        let rows = try XCTUnwrap(Self.json(try XCTUnwrap(request(r, DchFrame.clipboardList))) as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }.dropFirst(), ids.reversed().map(\.uuidString)[...])
        guard rows.count == 4 else { return XCTFail("4 rows, got \(rows.count)") }   // no crash: tempDir teardown runs
        XCTAssertEqual(rows[0]["source"] as? String, "Mac")
        XCTAssertEqual(rows[0]["text"] as? String, "on the mac")
        XCTAssertEqual(rows[1]["source"] as? String, "iPhone")
        XCTAssertEqual(rows[2]["kind"] as? String, "text", "a link is text on the wire")
        XCTAssertEqual(rows[2]["date"] as? String, DchClipboardOps.wireDate(t0 + 1.5))
        XCTAssertEqual((rows[3]["text"] as? String)?.count, 2000, "text is the first 2000 characters")
        XCTAssertEqual(rows[3]["size"] as? Int, 3000)
        XCTAssertNil(rows[3]["thumb"])

        let since = try XCTUnwrap(Self.json(try XCTUnwrap(request(r, DchFrame.clipboardList, ["since": DchClipboardOps.wireDate(t0 + 1.5)]))) as? [[String: Any]])
        XCTAssertEqual(since.compactMap { $0["id"] as? String }.dropFirst(), [ids[2].uuidString][...], "only items dated after `since`")
        let page = try XCTUnwrap(Self.json(try XCTUnwrap(request(r, DchFrame.clipboardList, ["before": ids[2].uuidString, "limit": 1]))) as? [[String: Any]])
        XCTAssertEqual(page.compactMap { $0["id"] as? String }, [ids[1].uuidString])
        let zero = try XCTUnwrap(Self.json(try XCTUnwrap(request(r, DchFrame.clipboardList, ["limit": 0]))) as? [[String: Any]])
        XCTAssertEqual(zero.count, 1, "limit clamps to 1…100")
        let plain = try XCTUnwrap(Self.json(try XCTUnwrap(request(r, DchFrame.clipboardList, ["since": "2025-01-01T00:00:00Z"]))) as? [[String: Any]])
        XCTAssertEqual(plain.count, 1, "a date without fractional seconds parses too")

        for bad: [String: Any] in [["limit": "x"], ["limit": true], ["limit": -1], ["before": "nope"], ["since": "yesterday"]] {
            XCTAssertTrue(Self.message(request(r, DchFrame.clipboardList, bad)).contains("malformed clipboardList"), "\(bad)")
        }
        XCTAssertEqual(Self.message(request(r, DchFrame.clipboardList, ["before": UUID().uuidString])), "before: no such item")
    }

    /// Review R2: a text past 1 MB lists its stored preview; its blob is not read.
    func testListUsesThePreviewPastOneMegabyte() throws {
        let d = tempDir(), (big, small) = (UUID(), UUID())
        let index = #"[{"id":"\#(big.uuidString)","kind":"text","createdAt":700000001,"preview":"the preview","byteCount":1048577,"blobFile":"big.txt"},"# +
            #"{"id":"\#(small.uuidString)","kind":"text","createdAt":700000000,"preview":"p","byteCount":1048576,"blobFile":"small.txt"}]"#
        try Data(index.utf8).write(to: d.appendingPathComponent("index.json"))
        try Data("blob text, not the preview".utf8).write(to: d.appendingPathComponent("big.txt"))
        try Data("small blob".utf8).write(to: d.appendingPathComponent("small.txt"))
        let r = rig()
        var o = r.conn.clipboard
        let store = ClipboardStore(dir: d)
        o.store = { store }
        r.conn.clipboard = o
        let rows = try XCTUnwrap(Self.json(try XCTUnwrap(request(r, DchFrame.clipboardList))) as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["text"] as? String }, ["the preview", "small blob"], "exactly 1 MB still reads the blob")
    }

    func testListLimitIsAtMost100() throws {
        let r = rig()
        for i in 0..<105 { r.store.addRemote(id: UUID(), date: Date(timeIntervalSince1970: Double(i)), source: "iPhone", sha256: "\(i)", .text("t\(i)")) }
        let rows = try XCTUnwrap(Self.json(try XCTUnwrap(request(r, DchFrame.clipboardList, ["limit": 500]))) as? [[String: Any]])
        XCTAssertEqual(rows.count, 100)
        XCTAssertEqual(rows.first?["text"] as? String, "t104")
    }

    func testListThumbIsASmallJPEGCachedById() throws {
        let r = rig()
        let id = UUID()
        r.store.addRemote(id: id, date: Date(), source: "iPhone", sha256: "p", .image(Self.png(600, 300), width: 600, height: 300))
        let rows = try XCTUnwrap(Self.json(try XCTUnwrap(request(r, DchFrame.clipboardList))) as? [[String: Any]])
        guard rows.count == 1 else { return XCTFail("1 row, got \(rows.count)") }
        let thumb = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(rows[0]["thumb"] as? String)))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(thumb as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.jpeg.identifier)
        let px = try XCTUnwrap(DchClipboardUpload.pixels(thumb))
        XCTAssertEqual(max(px.0, px.1), 256)
        XCTAssertNil(rows[0]["text"])
        XCTAssertEqual(rows[0]["kind"] as? String, "image")
        XCTAssertNotNil(DchClipboardOps.thumbs.object(forKey: id as NSUUID), "cached by id")
    }

    // MARK: - addClipboardHistory 0x22

    func testAddHistoryAddsSmallTextAtItsDateAndNeverTheLivePasteboard() {
        let r = rig()
        let count = Pasteboard.general.changeCount
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let (a, b) = (UUID(), UUID())
        func item(_ id: UUID, _ text: Any, date: Date = t, kind: String = "text") -> [String: Any] {
            ["id": id.uuidString, "date": DchClipboardOps.wireDate(date), "kind": kind, "text": text, "source": "iPhone"]
        }
        let big = String(repeating: "b", count: DchClipboardOps.smallText + 1)
        let f = request(r, DchFrame.addClipboardHistory, ["items": [
            item(a, "first"), item(b, "#ff0000", date: t + 1), item(UUID(), big), item(UUID(), "img", kind: "image"),
            ["id": "nope", "kind": "text", "text": "x", "date": DchClipboardOps.wireDate(t)], item(UUID(), 3), item(UUID(), "   "),
            item(UUID(), "first", date: t + 10),
        ]])
        XCTAssertEqual(f.map(Self.type), DchFrame.ok)
        XCTAssertEqual(added(f), [a.uuidString, b.uuidString])
        XCTAssertEqual(skipped(f).map { $0["reason"] ?? "" }, ["use_upload", "use_upload", "bad_item", "bad_item", "bad_item", "duplicate"])
        XCTAssertEqual(skipped(f).dropFirst(2).first?["id"], "nope")
        XCTAssertEqual(r.store.item(a)?.source, "iPhone")
        XCTAssertEqual(r.store.item(a)?.createdAt, t + 10, "the same content keeps one entry; the newest date wins")
        XCTAssertEqual(r.store.item(b)?.kind, .color, "classified as a Mac capture is")
        XCTAssertEqual(r.store.items.count, 2)
        XCTAssertEqual(Pasteboard.general.changeCount, count, "history only, never the live pasteboard")
        let older = request(r, DchFrame.addClipboardHistory, ["items": [item(UUID(), "first", date: t)]])
        XCTAssertEqual(skipped(older).first?["reason"], "duplicate")
        XCTAssertEqual(r.store.item(a)?.createdAt, t + 10, "an older duplicate moves nothing")
        XCTAssertEqual(skipped(request(r, DchFrame.addClipboardHistory, ["items": [item(a, "other text")]])).first?["reason"], "duplicate",
                       "a known id is a duplicate too")

        let atCap = request(r, DchFrame.addClipboardHistory, ["items": [item(UUID(), String(repeating: "c", count: DchClipboardOps.smallText))]])
        XCTAssertEqual(added(atCap).count, 1, "exactly 64 KB is small")
        let many = (0...DchClipboardOps.maxItems).map { item(UUID(), "n\($0)") }
        XCTAssertEqual(Self.message(request(r, DchFrame.addClipboardHistory, ["items": many])), "too many items (max 100)")
        XCTAssertTrue(Self.message(request(r, DchFrame.addClipboardHistory, ["nope": 1])).contains("malformed addClipboardHistory"))
    }

    /// An item older than every entry a full history keeps is evicted on insert: skipped
    /// "too_old", and an upload's received file goes with it.
    func testAnItemOlderThanAFullHistoryIsSkippedTooOld() {
        defer { Preferences.defaults.removeObject(forKey: "clipboardHistoryMaxItems") }
        Preferences.clipboardHistoryMaxItems = 10
        let r = rig()
        for i in 0..<10 { r.store.addRemote(id: UUID(), date: Date(), source: "iPhone", sha256: "\(i)", .text("t\(i)")) }
        let old = Date(timeIntervalSince1970: 0), id = UUID()
        let f = request(r, DchFrame.addClipboardHistory, ["items": [["id": id.uuidString, "date": DchClipboardOps.wireDate(old),
                                                                     "kind": "text", "text": "ancient"]]])
        XCTAssertEqual(skipped(f), [["id": id.uuidString, "reason": "too_old"]])
        let body = Self.bytes(5), fid = UUID()
        handle(r, DchFrame.clipboardUpload, header(body, id: fid, kind: "file", date: old, name: "old.txt"))
        feed(r, body)
        XCTAssertEqual(skipped(final(r, 2)), [["id": fid.uuidString, "reason": "too_old"]])
        XCTAssertEqual(dir(r.received), [], "the received file goes with it")
        XCTAssertEqual(r.store.items.count, 10)
        XCTAssertTrue(r.store.receiving.isEmpty)
    }

    // MARK: - putClipboardText 0x17

    func testPutClipboardTextSetsTheLivePasteboard() {
        let r = rig()
        defer { Pasteboard.general.clearContents() }
        handle(r, DchFrame.putClipboardText, ["text": "send to Mac now"])
        XCTAssertEqual(all(r), [DchFrame.encode(DchFrame.ok, [])], "acked at once, on the queue")
        XCTAssertEqual(Pasteboard.general.string(forType: .string), "send to Mac now")
        handle(r, DchFrame.putClipboardText, ["text": 1])
        XCTAssertTrue(Self.message(all(r).last).contains("malformed putClipboardText"))
        XCTAssertTrue(r.store.items.isEmpty, "not history")
    }

    // MARK: - clipboardItem 0x16

    /// The data frames after clipboardItemResp, concatenated, and their sizes.
    private func pulled(_ r: Rig, from: Int = 0) -> (header: [String: Any], chunks: [Int], data: Data) {
        let frames = Array(all(r).dropFirst(from))
        let header = frames.first { Self.type($0) == DchFrame.clipboardItemResp }
        let data = frames.filter { Self.type($0) == DchFrame.data }.map(Self.payload)
        return (Self.object(header), data.map(\.count), data.reduce(Data(), +))
    }

    func testItemStreamsTextInMegabyteChunksAtExactBoundariesAndZeroBytes() throws {
        let r = rig()
        let mb = DchClipboardOps.chunk
        for (n, chunks) in [(mb, [mb]), (2 * mb + 1, [mb, mb, 1]), (0, [])] {
            let id = UUID(), body = Self.bytes(n), from = all(r).count
            r.store.addRemote(id: id, date: Date(timeIntervalSince1970: 5), source: "iPhone", sha256: "s\(n)",
                              .text(String(decoding: body, as: UTF8.self)))
            let f = request(r, DchFrame.clipboardItem, ["id": id.uuidString])
            XCTAssertEqual(f, DchFrame.encode(DchFrame.ok, []), "\(n)")
            let p = pulled(r, from: from)
            XCTAssertEqual(p.chunks, chunks, "\(n)")
            XCTAssertEqual(p.data, body)
            XCTAssertEqual(p.header["size"] as? Int, n)
            XCTAssertEqual(p.header["sha256"] as? String, ClipboardStore.sha256(body))
            XCTAssertEqual(p.header["id"] as? String, id.uuidString)
            XCTAssertEqual(p.header["kind"] as? String, "text")
            XCTAssertEqual(p.header["source"] as? String, "iPhone")
            XCTAssertEqual(p.header["date"] as? String, DchClipboardOps.wireDate(Date(timeIntervalSince1970: 5)))
            XCTAssertEqual(p.header["mime"] as? String, "text/plain; charset=utf-8")
            XCTAssertEqual(Self.type(all(r)[from]), DchFrame.clipboardItemResp, "the header comes first")
        }
    }

    func testItemResumesFromAnOffsetAndTheShaCoversTheWholeItem() throws {
        let r = rig()
        let body = Self.bytes(2 * DchClipboardOps.chunk + 1), id = UUID()
        r.store.addRemote(id: id, date: Date(), source: "iPhone", sha256: "s", .text(String(decoding: body, as: UTF8.self)))
        let off = DchClipboardOps.chunk + 5
        var from = all(r).count
        XCTAssertEqual(request(r, DchFrame.clipboardItem, ["id": id.uuidString, "offset": off]), DchFrame.encode(DchFrame.ok, []))
        var p = pulled(r, from: from)
        XCTAssertEqual(p.data, body.subdata(in: off..<body.count))
        XCTAssertEqual(p.chunks, [body.count - off], "chunks count from the offset")
        XCTAssertEqual(p.header["sha256"] as? String, ClipboardStore.sha256(body))
        XCTAssertEqual(p.header["size"] as? Int, body.count)
        from = all(r).count
        XCTAssertEqual(request(r, DchFrame.clipboardItem, ["id": id.uuidString, "offset": body.count]), DchFrame.encode(DchFrame.ok, []))
        p = pulled(r, from: from)
        XCTAssertEqual(p.chunks, [], "offset == size: the header, then ok")
        for bad: Any in [body.count + 1, -1, "1", true] {
            XCTAssertEqual(Self.message(request(r, DchFrame.clipboardItem, ["id": id.uuidString, "offset": bad])), "bad offset", "\(bad)")
        }
    }

    func testItemStreamsAFileEntryAndRefusesWhatItCannotServe() throws {
        let r = rig()
        let d = tempDir()
        let file = d.appendingPathComponent("notes.md"), body = Self.bytes(DchClipboardOps.chunk + 7)
        try body.write(to: file)
        r.store.addFile(file)
        let fid = try XCTUnwrap(r.store.items.first?.id)
        let from = all(r).count
        XCTAssertEqual(request(r, DchFrame.clipboardItem, ["id": fid.uuidString]), DchFrame.encode(DchFrame.ok, []))
        let p = pulled(r, from: from)
        XCTAssertEqual(p.data, body)
        XCTAssertEqual(p.header["name"] as? String, "notes.md")
        XCTAssertEqual(p.header["kind"] as? String, "file")
        XCTAssertEqual(p.header["sha256"] as? String, ClipboardStore.sha256(body))
        XCTAssertEqual(p.header["source"] as? String, "Mac")

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(Self.message(request(r, DchFrame.clipboardItem, ["id": fid.uuidString])), "gone")
        let fifo = d.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        r.store.addFile(fifo)
        XCTAssertEqual(Self.message(request(r, DchFrame.clipboardItem, ["id": r.store.items[0].id.uuidString])), "not a regular file",
                       "a FIFO never blocks the reply")
        r.store.addOversizeText(byteCount: 200 << 20, preview: "huge")
        XCTAssertEqual(Self.message(request(r, DchFrame.clipboardItem, ["id": r.store.items[0].id.uuidString])), "not stored")
        XCTAssertEqual(Self.message(request(r, DchFrame.clipboardItem, ["id": UUID().uuidString])), "gone")
        XCTAssertTrue(Self.message(request(r, DchFrame.clipboardItem, ["id": "x"])).contains("malformed clipboardItem"))
        XCTAssertTrue(Self.message(request(r, DchFrame.clipboardItem, ["id": fid.uuidString, "x": 1])).contains("malformed clipboardItem"))
    }

    func testItemStreamStopsWhenTheConnectionCloses() {
        let r = rig()
        let id = UUID(), body = Self.bytes(3 * DchClipboardOps.chunk)
        r.store.addRemote(id: id, date: Date(), source: "iPhone", sha256: "s", .text(String(decoding: body, as: UTF8.self)))
        let conn = r.conn, q = r.queue
        r.conn.sendOverride = { f in
            r.frames.lock.withLock { r.frames.all.append(f) }
            if f.first == DchFrame.data { q.async { conn.close() } }   // the phone hangs up after one chunk
        }
        handle(r, DchFrame.clipboardItem, ["id": id.uuidString])
        XCTAssertTrue(spin { !r.queue.sync { r.conn.inFlight } })
        XCTAssertLessThanOrEqual(all(r).filter { $0.first == DchFrame.data }.count, 2, "no more chunks once closed")
        XCTAssertTrue(finals(r).isEmpty, "the reply to a closed connection is dropped")
    }

    // MARK: - clipboardUpload 0x23

    func testUploadedTextIsSealedIntoTheStoreWithItsReceivingStateMeanwhile() throws {
        let r = rig()
        let body = Self.bytes(2 * DchClipboardOps.chunk + 1), id = UUID(), t = Date(timeIntervalSince1970: 1_750_000_000)
        var changes = 0
        let sub = r.store.objectWillChange.sink { changes += 1 }
        defer { sub.cancel() }
        handle(r, DchFrame.clipboardUpload, header(body, id: id, date: t))
        feed(r, body, to: DchClipboardOps.chunk)
        XCTAssertTrue(spin { r.store.receiving[id]?.bytes == DchClipboardOps.chunk })
        XCTAssertEqual(r.store.receiving[id], ClipboardReceiving(id: id, kind: .text, createdAt: t, name: nil, size: body.count,
                                                                 bytes: DchClipboardOps.chunk))
        XCTAssertGreaterThan(changes, 0, "receiving is observable")
        XCTAssertNil(r.store.item(id), "not in history until complete")
        XCTAssertTrue(finals(r).isEmpty)
        feed(r, body, from: DchClipboardOps.chunk)
        let f = final(r)
        XCTAssertEqual(added(f), [id.uuidString])
        XCTAssertTrue(r.store.receiving.isEmpty)
        let it = try XCTUnwrap(r.store.item(id))
        XCTAssertEqual(it.source, "iPhone")
        XCTAssertEqual(it.sha256, ClipboardStore.sha256(body))
        XCTAssertEqual(it.createdAt, t)
        XCTAssertEqual(r.store.text(for: it), String(decoding: body, as: UTF8.self))
        let blob = try Data(contentsOf: r.store.dir.appendingPathComponent(try XCTUnwrap(it.blobFile)))
        XCTAssertNil(blob.range(of: body.prefix(64)), "sealed: no plaintext in the store dir")
        XCTAssertEqual(dir(r.received), [], "in-memory sizes never touch the received-files folder")
        XCTAssertEqual(dir(r.store.dir).filter { $0.hasSuffix(".part") }, [])
    }

    /// Past the in-memory limit a text is a file: written to the .part file as each chunk
    /// arrives (bytes on disk before the end, not held whole), renamed Finder-style.
    func testUploadOverTheMemoryLimitStreamsToAFileAndDedupesItsName() throws {
        let r = rig(memoryMax: 10)
        let body = Self.bytes(3 * DchClipboardOps.chunk), id = UUID()
        handle(r, DchFrame.clipboardUpload, header(body, id: id, name: "notes.txt"))
        feed(r, body, to: 2 * DchClipboardOps.chunk)
        let part = r.received.appendingPathComponent(".prosper-\(id.uuidString).part")
        XCTAssertTrue(spin { r.store.receiving[id]?.bytes == 2 * DchClipboardOps.chunk })
        XCTAssertEqual((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int, 2 * DchClipboardOps.chunk,
                       "each chunk is on disk once taken")
        XCTAssertEqual(r.store.receiving[id]?.name, "notes.txt")
        feed(r, body, from: 2 * DchClipboardOps.chunk)
        XCTAssertEqual(added(final(r)), [id.uuidString])
        XCTAssertEqual(dir(r.received), ["notes.txt"])
        XCTAssertEqual(try Data(contentsOf: r.received.appendingPathComponent("notes.txt")), body)
        let it = try XCTUnwrap(r.store.item(id))
        XCTAssertEqual(it.kind, .file)
        XCTAssertEqual(it.sourcePath, r.received.appendingPathComponent("notes.txt").path)
        XCTAssertEqual(it.source, "iPhone")
        XCTAssertEqual(it.byteCount, body.count)
        XCTAssertNil(it.blobFile)

        // The connection takes the next upload once that one has replied.
        let other = Self.bytes(20, seed: 3), id2 = UUID()
        handle(r, DchFrame.clipboardUpload, header(other, id: id2, kind: "file", name: "notes.txt"))
        feed(r, other)
        XCTAssertEqual(added(final(r, 2)), [id2.uuidString])
        XCTAssertEqual(dir(r.received), ["notes 2.txt", "notes.txt"], "Finder-style: name 2.ext")
        XCTAssertEqual(r.store.item(id2)?.fileName, "notes 2.txt")
        XCTAssertEqual(try Data(contentsOf: r.received.appendingPathComponent("notes.txt")), body, "never over the first")
    }

    func testASecondUploadMidStreamIsBusyAndTheFirstCarriesOn() {
        let r = rig()
        let body = Self.bytes(10), id = UUID()
        handle(r, DchFrame.clipboardUpload, header(body, id: id))
        feed(r, body, to: 4)
        XCTAssertTrue(spin { r.store.receiving[id]?.bytes == 4 })
        XCTAssertEqual(Self.message(request(r, DchFrame.clipboardUpload, header(Data("x".utf8)))), "busy with an earlier request")
        XCTAssertEqual(Self.message(request(r, DchFrame.clipboardList)), "busy with an earlier request")
        feed(r, body, from: 4)
        XCTAssertEqual(added(final(r, 3)), [id.uuidString])
        XCTAssertEqual(r.store.text(for: r.store.item(id)!), String(decoding: body, as: UTF8.self))
    }

    func testMemoryLimitIsInclusive() {
        let r = rig(memoryMax: 10)
        let ten = Self.bytes(10), id = UUID()
        handle(r, DchFrame.clipboardUpload, header(ten, id: id))
        feed(r, ten)
        XCTAssertEqual(added(final(r)), [id.uuidString])
        XCTAssertEqual(r.store.item(id)?.kind, .text, "at the limit: in memory, sealed")
        XCTAssertEqual(dir(r.received), [])
        let eleven = Self.bytes(11, seed: 1), id2 = UUID()
        handle(r, DchFrame.clipboardUpload, header(eleven, id: id2))
        feed(r, eleven)
        XCTAssertEqual(added(final(r, 2)), [id2.uuidString])
        XCTAssertEqual(r.store.item(id2)?.kind, .file, "one byte past: a file")
        XCTAssertEqual(dir(r.received), ["iPhone Clipboard.txt"])
    }

    func testZeroByteUploadCompletesOnTheHeader() throws {
        let r = rig()
        let id = UUID()
        handle(r, DchFrame.clipboardUpload, header(Data(), id: id, kind: "file", name: "empty"))
        XCTAssertEqual(added(final(r)), [id.uuidString])
        XCTAssertEqual(dir(r.received), ["empty"])
        XCTAssertEqual(try Data(contentsOf: r.received.appendingPathComponent("empty")), Data())
        XCTAssertEqual(r.store.item(id)?.sha256, ClipboardStore.sha256(Data()))
    }

    func testHashMismatchShortAndLongStreamsAreRefusedAndLeaveNothing() {
        let body = Self.bytes(DchClipboardOps.chunk + 3)
        let cases: [(String, (Rig, UUID) -> Void, String)] = [
            ("hash", { r, id in self.handle(r, DchFrame.clipboardUpload, self.header(body, id: id, kind: "file", sha: String(repeating: "0", count: 64))); self.feed(r, body) }, "hash mismatch"),
            ("short", { r, id in self.handle(r, DchFrame.clipboardUpload, self.header(body, id: id, kind: "file")); self.feed(r, body, to: 10); self.handle(r, DchFrame.data, raw: Data()) }, "short"),
            ("long", { r, id in self.handle(r, DchFrame.clipboardUpload, self.header(body, id: id, kind: "file")); self.feed(r, body + Data("x".utf8)) }, "too long"),
            ("memhash", { r, id in self.handle(r, DchFrame.clipboardUpload, self.header(body, id: id, sha: String(repeating: "a", count: 64))); self.feed(r, body) }, "hash mismatch"),
        ]
        for (label, run, message) in cases {
            let r = rig(label: label)
            let id = UUID()
            run(r, id)
            let f = final(r)
            XCTAssertEqual(f.map(Self.type), DchFrame.error, label)
            XCTAssertEqual(Self.message(f), message, label)
            XCTAssertEqual(dir(r.received), [], "\(label): the partial file is gone")
            XCTAssertTrue(r.store.receiving.isEmpty, label)
            XCTAssertTrue(r.store.items.isEmpty, label)
            XCTAssertFalse(r.queue.sync { r.conn.inFlight }, label)
        }
    }

    func testCancelOrADroppedConnectionMidStreamRemovesTheRowAndThePartFile() {
        for viaStore in [true, false] {
            let r = rig(memoryMax: 10, label: viaStore ? "cancel" : "drop")
            let body = Self.bytes(2 * DchClipboardOps.chunk), id = UUID()
            handle(r, DchFrame.clipboardUpload, header(body, id: id, name: "big.bin"))
            feed(r, body, to: DchClipboardOps.chunk)
            XCTAssertTrue(spin { r.store.receiving[id]?.bytes == DchClipboardOps.chunk })
            XCTAssertEqual(dir(r.received), [".prosper-\(id.uuidString).part"])
            if viaStore { r.store.cancel(id) } else { r.queue.sync { r.conn.close() } }
            XCTAssertTrue(spin { r.frames.lock.withLock { r.frames.closed } == 1 }, "the connection closes")
            XCTAssertTrue(spin { self.dir(r.received).isEmpty }, "the partial file is gone")
            XCTAssertTrue(spin { r.store.receiving.isEmpty }, "the row is gone")
            feed(r, body, from: DchClipboardOps.chunk)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(r.store.items.isEmpty)
            XCTAssertEqual(dir(r.received), [])
        }
    }

    func testLiveSetsThePasteboardOnlyAfterCompletion() throws {
        defer { Pasteboard.general.clearContents() }
        let r = rig()
        // The app's monitor, polling this store, in step with the pasteboard (an empty one
        // records nothing), as it is in the app before any upload.
        let monitor = ClipboardMonitor.shared, saved = monitor.store
        defer { monitor.store = saved }
        monitor.store = { r.store }
        Pasteboard.general.clearContents()
        monitor.poll(Pasteboard.general)
        // Dated before the newest entry, so the monitor's own "same as the newest" check
        // would not stop a second copy; only ignoreHistory does.
        let newer = UUID()
        r.store.addRemote(id: newer, date: Date(), source: "iPhone", sha256: "n", .text("newer"))
        let body = Self.bytes(DchClipboardOps.chunk + 9), id = UUID()
        let count = Pasteboard.general.changeCount
        handle(r, DchFrame.clipboardUpload, header(body, id: id, date: Date(timeIntervalSince1970: 1_000), live: true))
        feed(r, body, to: DchClipboardOps.chunk)
        XCTAssertTrue(spin { r.store.receiving[id]?.bytes == DchClipboardOps.chunk })
        XCTAssertEqual(Pasteboard.general.changeCount, count, "nothing live while arriving")
        feed(r, body, from: DchClipboardOps.chunk)
        XCTAssertEqual(added(final(r)), [id.uuidString])
        XCTAssertEqual(Pasteboard.general.string(forType: .string), String(decoding: body, as: UTF8.self))
        // The monitor's next poll records no second, "Mac" copy of that live write.
        monitor.poll(Pasteboard.general)
        XCTAssertEqual(r.store.items.map(\.id), [newer, id])
        // Control: the same write by anyone else is recorded.
        r.store.copyToPasteboard(r.store.item(id)!)
        monitor.poll(Pasteboard.general)
        XCTAssertEqual(r.store.items.count, 3, "the control write is recorded")

        let img = Self.png(4, 3), iid = UUID()
        let s = rig(label: "image")
        handle(s, DchFrame.clipboardUpload, header(img, id: iid, kind: "image", live: true))
        feed(s, img)
        XCTAssertEqual(added(final(s)), [iid.uuidString])
        XCTAssertEqual(s.store.item(iid)?.preview, "Image 4×3")
        XCTAssertNotNil(Pasteboard.general.data(forType: .png), "an image goes live as PNG")

        let f = rig(memoryMax: 1, label: "file")
        let fid = UUID()
        handle(f, DchFrame.clipboardUpload, header(body, id: fid, kind: "file", name: "a.bin", live: true))
        feed(f, body)
        XCTAssertEqual(added(final(f)), [fid.uuidString])
        let urls = Pasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.first?.path, f.received.appendingPathComponent("a.bin").path, "a file goes live as its URL")
    }

    func testNoSpaceRefusesAnUploadThatWouldLeaveUnder5GB() {
        let body = Self.bytes(100)
        let tight = rig(free: DchClipboardOps.minFreeAfter + 99, label: "tight")
        let id = UUID()
        handle(tight, DchFrame.clipboardUpload, header(body, id: id, kind: "file"))
        feed(tight, body)
        let f = final(tight)
        XCTAssertEqual(skipped(f), [["id": id.uuidString, "reason": "no_space"]])
        XCTAssertEqual(dir(tight.received), [])
        XCTAssertTrue(tight.store.receiving.isEmpty)
        XCTAssertTrue(tight.store.items.isEmpty)
        let enough = rig(free: DchClipboardOps.minFreeAfter + 100, label: "enough")
        handle(enough, DchFrame.clipboardUpload, header(body, id: id, kind: "file"))
        feed(enough, body)
        XCTAssertEqual(added(final(enough)), [id.uuidString], "exactly 5 GB left is allowed")
        XCTAssertEqual(DchClipboardOps.minFreeAfter, 5 << 30)
    }

    func testDuplicateUploadIsSkippedOnTheHeaderAndTheNewestDateWins() {
        let r = rig()
        let body = Data("same".utf8), kept = UUID(), t = Date(timeIntervalSince1970: 1_700_000_000)
        r.store.addRemote(id: kept, date: t, source: "iPhone", sha256: ClipboardStore.sha256(body), .text("same"))
        let id = UUID()
        handle(r, DchFrame.clipboardUpload, header(body, id: id, date: t + 60))
        XCTAssertEqual(skipped(final(r)), [["id": id.uuidString, "reason": "duplicate"]], "before any data frame")
        feed(r, body)   // the phone may already be sending: swallowed
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(finals(r).count, 1)
        XCTAssertEqual(r.store.items.map(\.id), [kept])
        XCTAssertEqual(r.store.item(kept)?.createdAt, t + 60)
        let s = rig(label: "older")
        s.store.addRemote(id: kept, date: t, source: "iPhone", sha256: ClipboardStore.sha256(body), .text("same"))
        handle(s, DchFrame.clipboardUpload, header(body, date: t - 60))
        XCTAssertEqual(skipped(final(s)).first?["reason"], "duplicate")
        XCTAssertEqual(s.store.item(kept)?.createdAt, t)
    }

    func testImagesWithinAndBeyondThePixelLimitAndBadImages() throws {
        let img = Self.png(5, 4)
        let r = rig(maxPixels: 19)
        let id = UUID()
        handle(r, DchFrame.clipboardUpload, header(img, id: id, kind: "image", name: "photo.png"))
        feed(r, img)
        XCTAssertEqual(added(final(r)), [id.uuidString])
        XCTAssertEqual(r.store.item(id)?.kind, .file, "past the pixel limit an image is a file")
        XCTAssertEqual(dir(r.received), ["photo.png"])
        XCTAssertEqual(try Data(contentsOf: r.received.appendingPathComponent("photo.png")), img)

        let ok = rig(maxPixels: 20, label: "within")
        handle(ok, DchFrame.clipboardUpload, header(img, id: id, kind: "image"))
        feed(ok, img)
        XCTAssertEqual(added(final(ok)), [id.uuidString])
        XCTAssertEqual(ok.store.item(id)?.kind, .image)
        XCTAssertEqual(ok.store.imageData(for: ok.store.item(id)!), img)
        XCTAssertEqual(dir(ok.received), [])

        let bad = rig(label: "bad")
        let junk = Data("not an image".utf8)
        handle(bad, DchFrame.clipboardUpload, header(junk, id: id, kind: "image"))
        feed(bad, junk)
        XCTAssertEqual(skipped(final(bad)), [["id": id.uuidString, "reason": "bad_item"]])
        XCTAssertTrue(bad.store.items.isEmpty)
        XCTAssertTrue(bad.store.receiving.isEmpty)
    }

    func testMalformedUploadHeadersAndReceivedFileNames() {
        let good = header(Data("x".utf8))
        let bads: [[String: Any]] = [
            [:], good.merging(["kind": "link"]) { $1 }, good.merging(["size": -1]) { $1 }, good.merging(["sha256": "zz"]) { $1 },
            good.merging(["source": "Mac"]) { $1 }, good.merging(["live": 1]) { $1 }, good.merging(["date": "now"]) { $1 },
            good.merging(["id": "x"]) { $1 }, good.merging(["name": 3]) { $1 },
        ]
        for (i, b) in bads.enumerated() {
            let c = rig(label: "bad\(i)")
            let f = request(c, DchFrame.clipboardUpload, b)
            XCTAssertTrue(Self.message(f).hasPrefix("malformed clipboardUpload"), "\(b)")
        }
        func name(_ n: String?, kind: ClipboardKind = .file, mime: String? = nil) -> String {
            DchClipboardOps.fileName(DchClipboardOps.Upload(id: UUID(), date: Date(), kind: kind, size: 0, sha256: "", name: n, mime: mime, live: false))
        }
        XCTAssertEqual(name("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(name(".hidden"), "hidden")
        XCTAssertEqual(name("a/b:c"), "a-b-c")
        XCTAssertEqual(name(nil, kind: .text), "iPhone Clipboard.txt")
        XCTAssertEqual(name("  ", kind: .image, mime: "image/jpeg"), "iPhone Clipboard.jpeg")
        XCTAssertEqual(name(nil), "iPhone Clipboard")
        XCTAssertEqual(DchClipboardOps.candidate("a.tar", 3), "a 3.tar")
        XCTAssertEqual(DchClipboardOps.candidate("README", 2), "README 2")
        XCTAssertEqual(DchClipboardOps.candidate("README", 1), "README")
    }

    /// Unstubbed: no received-files folder under XCTest, so a file upload is refused and
    /// nothing is written to the real ~/Downloads.
    func testDefaultReceivedFolderIsNoneUnderXCTest() {
        XCTAssertNil(DchClipboardOps().receivedDir())
        let r = rig()
        r.conn.clipboard.receivedDir = DchClipboardOps().receivedDir
        handle(r, DchFrame.clipboardUpload, header(Data("x".utf8), kind: "file"))
        XCTAssertEqual(Self.message(final(r)), "no folder for received files")
    }
}
