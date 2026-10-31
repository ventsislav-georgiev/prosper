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
        return wire(o, store: store, received: received)
    }

    private func wire(_ o: DchClipboardOps, store: ClipboardStore, received: URL) -> Rig {
        let queue = DispatchQueue(label: "test.dchconn.clipboard")
        let frames = Frames()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"),
                                 onClose: { @Sendable _ in frames.lock.withLock { frames.closed += 1 } })
        conn.sendOverride = { f in frames.lock.withLock { frames.all.append(f) } }
        conn.clipboard = o
        return Rig(conn: conn, queue: queue, frames: frames, store: store, received: received)
    }

    /// QA #493 P4: a second connection on the same store, folders and gate.
    private func peer(_ r: Rig) -> Rig { wire(r.conn.clipboard, store: r.store, received: r.received) }

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
        XCTAssertEqual(r.store.text(for: r.store.item(a)!), "first", "the refused item's seal never touches the kept item's blob")

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

    // MARK: - Fix round 1 (QA #493)

    /// Raw socket bytes through DchConnection.ingest, in `piece`-sized reads.
    private func ingest(_ r: Rig, _ bytes: Data, piece: Int = 64 << 10) {
        var at = 0
        while at < bytes.count {
            let d = bytes.subdata(in: at..<min(at + piece, bytes.count))
            r.queue.sync { r.conn.ingest(d) }
            at += d.count
        }
    }

    private static func lengthPrefix(_ type: UInt8, _ n: Int) -> Data {
        var d = Data([type]), be = UInt32(n).bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        return d
    }

    /// An RGB noise PNG: incompressible, so 2410 x 2410 is past 16 MiB, like a 4032 px photo.
    private static func noisePNG(_ w: Int, _ h: Int) -> Data {
        var px = Data(count: w * h * 4)
        px.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: CGDataProvider(data: px as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, cg, nil)
        CGImageDestinationFinalize(dst)
        return out as Data
    }

    private func blobs(_ r: Rig) -> [String] { dir(r.store.dir).filter { $0 != "index.json" } }

    /// F1: the shipped phone sends a pasted photo as ONE putClipboard frame, full size, on the
    /// attached connection, sync on or off. A 17 MB PNG read off the socket in pieces is set
    /// on the pasteboard and acked; the connection stays.
    func testAPutClipboardFramePastEightMegabytesIsSetAndAcked() {
        defer { Pasteboard.general.clearContents() }
        let png = Self.noisePNG(2410, 2410)
        XCTAssertGreaterThan(png.count, 16 << 20)
        let frame = DchFrame.encode(DchFrame.putClipboard, [UInt8](png))
        for on in [true, false] {
            let r = rig(on: on, label: "sync\(on)")
            Pasteboard.general.clearContents()
            ingest(r, frame)
            XCTAssertEqual(all(r), [DchFrame.encode(DchFrame.ok, [])], "sync \(on)")
            XCTAssertEqual(r.frames.lock.withLock { r.frames.closed }, 0, "sync \(on)")
            XCTAssertEqual(Pasteboard.general.data(forType: .png), png, "sync \(on)")
        }
    }

    /// The receive bound is a 256 MiB garbage guard on every frame type: a 2^31 length closes
    /// with "frame too large", a length at the bound waits for its bytes, and a big data frame
    /// with no pty and no upload is dropped with the connection kept.
    func testOnlyALengthPastTheRequestBoundClosesTheConnection() throws {
        XCTAssertEqual(DchFrame.maxRequestFrame, 256 << 20)
        XCTAssertEqual(DchFrame.maxFrame, 8 << 20, "the Mac's own sends stay within the phone's maxFrame")
        for (label, type, n) in [("2^31", DchFrame.putClipboard, 1 << 31), ("past", DchFrame.data, DchFrame.maxRequestFrame + 1)] {
            let r = rig(label: label)
            ingest(r, Self.lengthPrefix(type, n))
            XCTAssertEqual(all(r).map(Self.type), [DchFrame.error], label)
            XCTAssertEqual(Self.message(all(r).first), "frame too large", label)
            XCTAssertEqual(r.frames.lock.withLock { r.frames.closed }, 1, label)
        }
        let at = rig(label: "at")
        ingest(at, Self.lengthPrefix(DchFrame.putClipboard, DchFrame.maxRequestFrame))
        XCTAssertEqual(all(at), [], "at the bound: waits for the rest")
        XCTAssertEqual(at.frames.lock.withLock { at.frames.closed }, 0)

        let r = rig(label: "data")
        ingest(r, DchFrame.encode(DchFrame.data, [UInt8](repeating: 0x61, count: (8 << 20) + 1)), piece: 1 << 20)
        XCTAssertEqual(all(r), [], "no pty, no upload: dropped")
        XCTAssertEqual(r.frames.lock.withLock { r.frames.closed }, 0, "an 8 MiB + 1 data frame keeps the connection")
        XCTAssertEqual(request(r, DchFrame.clipboardList).map(Self.type), DchFrame.clipboardResp, "and it still answers")
    }

    /// F2 U2/U3 (QA P5): DchClipboardUpload alone. begin() is parked on main (never spun here)
    /// while 5 x 1 MB arrive from another thread: past the 4 MB backlog whenDrained holds `f`.
    /// Once main runs and the backlog drains, `f` runs exactly once.
    func testUploadBacklogHoldsTheReadUntilItDrainsThenResumesOnce() throws {
        let store = ClipboardStore(dir: tempDir("store")), received = tempDir("recv")
        var o = DchClipboardOps()
        o.enabled = { true }
        o.store = { store }
        o.receivedDir = { received }
        o.freeSpace = { _ in nil }
        let replies = Frames(), calls = Frames()
        let up = DchClipboardUpload(ops: o, reply: { f in replies.lock.withLock { replies.all.append(f) } }, closeConnection: {})
        let mb = DchClipboardOps.chunk, body = Self.bytes(6 * mb), id = UUID()
        up.start(try JSONSerialization.data(withJSONObject: header(body, id: id, kind: "file", name: "six.bin")))
        let fed = DispatchGroup()
        DispatchQueue.global().async(group: fed) { for i in 0..<5 { up.feed(body.subdata(in: i * mb..<(i + 1) * mb)) } }
        fed.wait()
        up.whenDrained { calls.lock.withLock { calls.closed += 1 } }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(calls.lock.withLock { calls.closed }, 0, "past the backlog the read waits")
        XCTAssertTrue(store.receiving.isEmpty, "begin() is still parked on main")
        up.feed(body.subdata(in: 5 * mb..<6 * mb))
        XCTAssertTrue(spin { replies.lock.withLock { replies.all.count } == 1 })
        XCTAssertEqual(added(replies.lock.withLock { replies.all.first }), [id.uuidString])
        XCTAssertTrue(spin { calls.lock.withLock { calls.closed } >= 1 }, "the read resumes once drained")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        up.sync()
        XCTAssertEqual(calls.lock.withLock { calls.closed }, 1, "exactly once")
        XCTAssertEqual(try Data(contentsOf: received.appendingPathComponent("six.bin")), body)
        up.whenDrained { calls.lock.withLock { calls.closed += 1 } }
        XCTAssertEqual(calls.lock.withLock { calls.closed }, 2, "an idle upload runs it at once")
    }

    /// F2 U4 (QA P4(b)): the same id on two connections; the second is a duplicate.
    func testTheSameIdOnTwoConnectionsIsADuplicateForTheSecond() {
        let r = rig(), p = peer(r)
        let body = Self.bytes(10), id = UUID()
        handle(r, DchFrame.clipboardUpload, header(body, id: id))
        XCTAssertTrue(spin { r.store.receiving[id] != nil })
        handle(p, DchFrame.clipboardUpload, header(Self.bytes(10, seed: 5), id: id))
        XCTAssertEqual(skipped(final(p)), [["id": id.uuidString, "reason": "duplicate"]])
        XCTAssertNotNil(r.store.receiving[id], "the first keeps its row")
        feed(r, body)
        XCTAssertEqual(added(final(r)), [id.uuidString])
        XCTAssertEqual(r.store.items.map(\.id), [id])
        XCTAssertEqual(r.store.text(for: r.store.items[0]), String(decoding: body, as: UTF8.self))
        XCTAssertTrue(r.store.receiving.isEmpty)
    }

    /// F2 U5 (QA P4(a)): the same content under two ids, both past begin() before either
    /// completes, ends in ONE row and ONE blob; the loser's blob, sealed off main, is removed.
    func testTheSameContentUnderTwoIdsAtOnceEndsInOneRowAndOneBlob() {
        let r = rig(), p = peer(r)
        let body = Self.bytes(2 * DchClipboardOps.chunk + 3), (i1, i2) = (UUID(), UUID())
        handle(r, DchFrame.clipboardUpload, header(body, id: i1))
        handle(p, DchFrame.clipboardUpload, header(body, id: i2))
        XCTAssertTrue(spin { r.store.receiving.count == 2 }, "both past begin()")
        feed(r, body)
        XCTAssertEqual(added(final(r)), [i1.uuidString])
        feed(p, body)
        XCTAssertEqual(skipped(final(p)), [["id": i2.uuidString, "reason": "duplicate"]])
        XCTAssertEqual(r.store.items.map(\.id), [i1])
        XCTAssertEqual(blobs(r).count, 1, "one blob: \(blobs(r))")
        XCTAssertEqual(blobs(r).first, r.store.items.first?.blobFile)
        XCTAssertTrue(r.store.receiving.isEmpty)
    }

    /// F2 U6: addClipboardHistory refuses an id still receiving; its sealed blob is removed.
    func testAddHistoryRefusesAnIdStillReceiving() {
        let r = rig(), p = peer(r)
        let body = Self.bytes(10), id = UUID()
        handle(r, DchFrame.clipboardUpload, header(body, id: id))
        XCTAssertTrue(spin { r.store.receiving[id] != nil })
        let f = request(p, DchFrame.addClipboardHistory, ["items": [["id": id.uuidString, "date": DchClipboardOps.wireDate(Date()),
                                                                    "kind": "text", "text": "other"]]])
        XCTAssertEqual(added(f), [])
        XCTAssertEqual(skipped(f), [["id": id.uuidString, "reason": "duplicate"]])
        XCTAssertEqual(blobs(r), [], "the refused item's sealed blob is gone")
        feed(r, body)
        XCTAssertEqual(added(final(r)), [id.uuidString])
        XCTAssertEqual(r.store.items.map(\.id), [id])
        XCTAssertEqual(r.store.text(for: r.store.items[0]), String(decoding: body, as: UTF8.self))
        XCTAssertEqual(blobs(r).count, 1)
    }

    /// The seal runs off main now: a cancel (#632's Esc) that lands while the item is sealing or
    /// waiting for its main hop still keeps it out of history, and its sealed blob is removed.
    func testACancelWhileTheItemSealsKeepsItOut() {
        let r = rig()
        let body = Self.bytes(DchClipboardOps.chunk + 1), id = UUID()
        handle(r, DchFrame.clipboardUpload, header(body, id: id))
        feed(r, body, to: DchClipboardOps.chunk)
        XCTAssertTrue(spin { r.store.receiving[id]?.bytes == DchClipboardOps.chunk })
        feed(r, body, from: DchClipboardOps.chunk)   // complete: the seal runs while main is held here
        Thread.sleep(forTimeInterval: 0.2)
        r.store.cancel(id)
        XCTAssertTrue(spin { r.frames.lock.withLock { r.frames.closed } == 1 })
        XCTAssertTrue(spin { !r.queue.sync { r.conn.inFlight } })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(r.store.items.isEmpty, "a cancelled upload never lands")
        XCTAssertEqual(blobs(r), [], "its sealed blob is gone")
        XCTAssertTrue(r.store.receiving.isEmpty)
    }

    /// F2 U8: a blank or whitespace-only streamed text is skipped bad_item and stores nothing.
    func testABlankStreamedTextIsSkippedAndStoresNothing() {
        for (i, text) in [" \n\t  ", ""].enumerated() {
            let r = rig(label: "blank\(i)")
            let body = Data(text.utf8), id = UUID()
            handle(r, DchFrame.clipboardUpload, header(body, id: id))
            feed(r, body)
            XCTAssertEqual(skipped(final(r)), [["id": id.uuidString, "reason": "bad_item"]], "\(i)")
            XCTAssertTrue(r.store.items.isEmpty, "\(i)")
            XCTAssertEqual(blobs(r), [], "\(i)")
            XCTAssertTrue(r.store.receiving.isEmpty, "\(i)")
            XCTAssertEqual(dir(r.received), [], "\(i)")
        }
    }

    /// QA #493 P3: every phone date is clamped to now BEFORE any dedupe, so a header can't
    /// re-date a kept item into the future, and no phone item sits above later Mac copies.
    func testPhoneDatesAreClampedToNowBeforeDedupe() {
        let r = rig()
        let future = Date(timeIntervalSince1970: 253_370_764_800)   // 9999-01-01
        let body = Data("same".utf8), kept = UUID(), t = Date(timeIntervalSince1970: 1_700_000_000)
        r.store.addRemote(id: kept, date: t, source: "iPhone", sha256: ClipboardStore.sha256(body), .text("same"))
        let start = Date()
        handle(r, DchFrame.clipboardUpload, header(Data("not the same".utf8), date: future, sha: ClipboardStore.sha256(body)))
        XCTAssertEqual(skipped(final(r)).first?["reason"], "duplicate")
        let moved = r.store.item(kept)?.createdAt ?? .distantFuture
        XCTAssertLessThanOrEqual(moved, Date(), "never re-dated into the future")
        XCTAssertGreaterThanOrEqual(moved, start, "to now, the newest date allowed")

        let a = UUID()
        let f = request(r, DchFrame.addClipboardHistory, ["items": [["id": a.uuidString, "date": DchClipboardOps.wireDate(future),
                                                                    "kind": "text", "text": "from the future"]]])
        XCTAssertEqual(added(f), [a.uuidString])
        XCTAssertLessThanOrEqual(r.store.item(a)?.createdAt ?? .distantFuture, Date())
        let u = UUID(), b = Self.bytes(7, seed: 2)
        handle(r, DchFrame.clipboardUpload, header(b, id: u, date: future))
        feed(r, b)
        XCTAssertEqual(added(final(r, 3)), [u.uuidString])
        XCTAssertLessThanOrEqual(r.store.item(u)?.createdAt ?? .distantFuture, Date())
        r.store.addText("mac copy")
        XCTAssertEqual(r.store.items.first?.preview, "mac copy", "a later Mac copy goes on top")
    }

    /// QA #493 S3: a connection that ever carried an upload never attaches or creates, even after
    /// an early reply ended it: the phone's leftover data frames would be typed into the pty.
    /// dch points at a path that does not exist, so a broken guard fails here and runs no dch.
    func testAConnectionThatUploadedNeverAttachesOrCreates() {
        let noDch = tempDir("no-dch").appendingPathComponent("no-such-dch").path
        DchCommand.dchPathOverride = noDch
        defer { DchCommand.dchPathOverride = nil }
        XCTAssertEqual(DchCommand.dchPath, noDch)
        for type in [DchFrame.attach, DchFrame.create] {
            let r = rig(label: "type\(type)")
            let body = Data("same".utf8)
            r.store.addRemote(id: UUID(), date: Date(), source: "iPhone", sha256: ClipboardStore.sha256(body), .text("same"))
            handle(r, DchFrame.clipboardUpload, header(body))
            XCTAssertEqual(skipped(final(r)).first?["reason"], "duplicate", "the early reply")
            XCTAssertFalse(r.queue.sync { r.conn.inFlight })
            handle(r, type, ["name": "qa617-never", "cols": 80, "rows": 24])
            XCTAssertEqual(Self.message(all(r).last), "clipboardUpload connections cannot attach or create", "\(type)")
            XCTAssertNil(r.queue.sync { r.conn.attachedSession }, "no session started")
            feed(r, body)   // the phone's leftover data frames: dropped
            XCTAssertEqual(all(r).count, 2, "nothing else sent")
            XCTAssertEqual(r.frames.lock.withLock { r.frames.closed }, 0)
        }
    }

    /// QA #493 P2(d)-(f): a name cut at 200 Characters keeps its extension; a NUL maps to "-"
    /// as "/" does, and the file is saved instead of failing the transfer.
    func testLongReceivedNamesKeepTheirExtensionAndANulIsMapped() throws {
        func name(_ n: String) -> String {
            DchClipboardOps.fileName(DchClipboardOps.Upload(id: UUID(), date: Date(), kind: .file, size: 0, sha256: "", name: n, mime: nil, live: false))
        }
        let q = String(repeating: "q", count: 196)
        XCTAssertEqual(name(String(repeating: "q", count: 250) + ".pdf"), q + ".pdf")
        XCTAssertEqual(name(q + ".pdf"), q + ".pdf", "exactly 200 is kept whole")
        XCTAssertEqual(name(String(repeating: "あ", count: 300) + ".txt"), String(repeating: "あ", count: 196) + ".txt")
        XCTAssertEqual(name(String(repeating: "q", count: 250)), String(repeating: "q", count: 200))
        XCTAssertEqual(name("x." + String(repeating: "z", count: 250)).count, 200, "no extension that long is kept")
        XCTAssertEqual(name("a\u{0}b.txt"), "a-b.txt")
        let r = rig()
        for (i, (n, saved)) in [("a\u{0}b.txt", "a-b.txt"), (String(repeating: "q", count: 250) + ".pdf", q + ".pdf")].enumerated() {
            let body = Self.bytes(5, seed: i), id = UUID()
            handle(r, DchFrame.clipboardUpload, header(body, id: id, kind: "file", name: n))
            feed(r, body)
            XCTAssertEqual(added(final(r, finals(r).count + 1)), [id.uuidString], saved)
            XCTAssertEqual(r.store.item(id)?.fileName, saved)
            XCTAssertEqual(try Data(contentsOf: r.received.appendingPathComponent(saved)), body)
        }
    }

    /// QA #493 F2: a name long in UTF-16 (ZWJ family emoji, 11 units each) is cut to
    /// `nameUnits` units with its extension kept, and saves through a full upload.
    func testNamesLongInUTF16AreCutToFitAndSave() throws {
        func name(_ n: String) -> String {
            DchClipboardOps.fileName(DchClipboardOps.Upload(id: UUID(), date: Date(), kind: .file, size: 0, sha256: "", name: n, mime: nil, live: false))
        }
        let fam = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        XCTAssertEqual(fam.utf16.count, 11)
        XCTAssertEqual(name(String(repeating: fam, count: 200) + ".txt"), String(repeating: fam, count: 22) + ".txt")
        XCTAssertEqual(name(String(repeating: fam, count: 300)), String(repeating: fam, count: 22))
        XCTAssertEqual(name(String(repeating: fam, count: 200) + ".sixteencharsxxxx"), String(repeating: fam, count: 21) + ".sixteencharsxxxx")
        // Under 200 Characters, only the units cut applies: 254 units become 248.
        XCTAssertEqual(name(String(repeating: "\u{1F600}", count: 127)), String(repeating: "\u{1F600}", count: 124))
        XCTAssertEqual(name(String(repeating: "q", count: 260)).utf16.count, 200)
        let r = rig()
        for (i, n) in [String(repeating: fam, count: 200) + ".txt", String(repeating: fam, count: 300) + ".heic"].enumerated() {
            let saved = name(n)
            XCTAssertLessThanOrEqual(saved.utf16.count, DchClipboardOps.nameUnits)
            for k in 1...3 {   // copies 2 and 3 take the " N" suffix and still fit
                let body = Self.bytes(5, seed: i * 3 + k), id = UUID(), want = DchClipboardOps.candidate(saved, k)
                handle(r, DchFrame.clipboardUpload, header(body, id: id, kind: "file", name: n))
                feed(r, body)
                XCTAssertEqual(added(final(r, finals(r).count + 1)), [id.uuidString], want)
                XCTAssertEqual(r.store.item(id)?.fileName, want)
                XCTAssertEqual(try Data(contentsOf: r.received.appendingPathComponent(want)), body)
            }
        }
    }

    /// QA #493 V7: a long name keeps a 4-16 Character extension; F3: and a .tar.gz/.bz2/.xz pair.
    func testLongNamesKeepLongAndDoubleExtensions() {
        func name(_ n: String) -> String {
            DchClipboardOps.fileName(DchClipboardOps.Upload(id: UUID(), date: Date(), kind: .file, size: 0, sha256: "", name: n, mime: nil, live: false))
        }
        let long = String(repeating: "q", count: 250)
        for ext in ["heic", "docx", "sixteencharsxxxx"] {
            XCTAssertEqual(name(long + "." + ext), String(repeating: "q", count: 199 - ext.count) + "." + ext)
        }
        XCTAssertEqual(name(long + ".seventeencharsxxx").count, 200, "17 is not an extension")
        XCTAssertFalse(name(long + ".seventeencharsxxx").hasSuffix(".seventeencharsxxx"))
        for ext in ["tar.gz", "TAR.bz2", "tar.xz"] {
            XCTAssertEqual(name(long + "." + ext), String(repeating: "q", count: 199 - ext.count) + "." + ext)
        }
        XCTAssertEqual(name(long + ".zip.gz"), String(repeating: "q", count: 197) + ".gz", "only .tar pairs")
    }

    /// QA #493 F2 backstop: a name the volume still refuses as too long saves as
    /// "iPhone Clipboard.<ext>" instead of failing the upload.
    func testPlaceFallsBackOnANameTooLong() throws {
        let d = tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        for (i, ext) in ["heic", "tar.gz", ""].enumerated() {
            let part = d.appendingPathComponent(".p\(i).part")
            XCTAssertTrue(FileManager.default.createFile(atPath: part.path, contents: Data([UInt8(i)])))
            let tail = ext.isEmpty ? "" : "." + ext
            let dest = DchClipboardOps.place(part, in: d, as: String(repeating: "a", count: 300) + tail)
            XCTAssertEqual(dest?.lastPathComponent, "iPhone Clipboard" + tail)
            XCTAssertEqual(dest.flatMap { try? Data(contentsOf: $0) }, Data([UInt8(i)]))
        }
    }

    /// QA #493 S4: an in-memory image that spills to a file past maxPixels re-checks the room on
    /// the received folder's volume, which can differ from the store's.
    func testAnImageSpillRechecksTheReceivedFolderRoom() {
        let img = Self.png(5, 4)
        for (label, spare) in [("tight", Int64(-1)), ("room", Int64(0))] {
            let r = rig(maxPixels: 19, label: label)
            let recv = r.received.path, need = DchClipboardOps.minFreeAfter + Int64(img.count)
            r.conn.clipboard.freeSpace = { $0.path == recv ? need + spare : nil }
            let id = UUID()
            handle(r, DchFrame.clipboardUpload, header(img, id: id, kind: "image", name: "photo.png"))
            feed(r, img)
            if spare < 0 {
                XCTAssertEqual(skipped(final(r)), [["id": id.uuidString, "reason": "no_space"]])
                XCTAssertEqual(dir(r.received), [])
                XCTAssertTrue(r.store.items.isEmpty)
            } else {
                XCTAssertEqual(added(final(r)), [id.uuidString])
                XCTAssertEqual(dir(r.received), ["photo.png"])
            }
            XCTAssertTrue(r.store.receiving.isEmpty, label)
        }
    }
}
