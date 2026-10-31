import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #632: History rows for phone uploads still arriving, and pasting one waits for it.
/// Store and Pasteboard seams only: a tempDir() store, the private Pasteboard.general.
@MainActor
final class ClipboardReceivingPanelTests: XCTestCase {

    private func upload(_ store: ClipboardStore, name: String? = "photo.heic", kind: ClipboardKind = .image,
                        size: Int = 24_600_000, bytes: Int = 0, at date: Date = Date(),
                        onCancel: @escaping @Sendable () -> Void = {}) -> ClipboardReceiving {
        let r = ClipboardReceiving(id: UUID(), kind: kind, createdAt: date, name: name, size: size, bytes: bytes)
        store.beginReceiving(r, cancel: onCancel)
        return r
    }

    private func row(_ store: ClipboardStore, _ id: UUID) throws -> ClipboardItem {
        try XCTUnwrap(store.historyRows.first { $0.id == id })
    }

    private func marker() -> String {
        let s = "before-\(UUID().uuidString)"
        Pasteboard.general.clearContents()
        Pasteboard.general.setString(s, forType: .string)
        return s
    }

    // MARK: - Rows

    func testReceivingRowSitsByDateAndBecomesTheItem() throws {
        let store = ClipboardStore(dir: tempDir())
        store.addText("older")
        let old = store.items[0]
        let r = upload(store, at: Date().addingTimeInterval(60))
        XCTAssertEqual(store.historyRows.map(\.id), [r.id, old.id], "the newer upload sits above the older item")
        XCTAssertEqual(try row(store, r.id).displayTitle, "photo.heic")
        let r2 = upload(store, name: nil, kind: .text, at: Date().addingTimeInterval(-3600))
        XCTAssertEqual(store.historyRows.map(\.id), [r.id, old.id, r2.id])
        XCTAssertEqual(try row(store, r2.id).displayTitle, "Text from iPhone", "no name: a kind label")

        XCTAssertTrue(store.addRemote(id: r.id, date: r.createdAt, source: "iPhone", sha256: "x", .text("landed")))
        XCTAssertEqual(store.historyRows.filter { $0.id == r.id }.count, 1, "inserted, not yet ended: still one row")
        store.endReceiving(r.id)
        XCTAssertEqual(store.historyRows.filter { $0.id == r.id }.count, 1, "one row under the same id")
        XCTAssertNotEqual(try row(store, r.id).source, ClipboardReceiving.placeholderSource)

        store.cancel(r2.id)
        XCTAssertNil(store.historyRows.first { $0.id == r2.id }, "a cancelled upload removes its row")
        let r3 = upload(store)
        store.endReceiving(r3.id)   // failed: leaves receiving with no item
        XCTAssertNil(store.historyRows.first { $0.id == r3.id }, "a failed upload removes its row")
        XCTAssertEqual(store.historyRows, store.items)
    }

    func testPinnedItemStaysAboveANewerUpload() throws {
        let store = ClipboardStore(dir: tempDir())
        store.addText("pinned \(UUID())")
        let pinned = store.items[0]
        store.togglePin(pinned)
        store.addText("unpinned \(UUID())")
        let unpinned = try XCTUnwrap(store.items.first { !$0.pinned })
        let newer = upload(store, at: Date().addingTimeInterval(60))
        let older = upload(store, at: Date().addingTimeInterval(-3600))
        XCTAssertEqual(store.historyRows.map(\.id), [pinned.id, newer.id, unpinned.id, older.id],
                       "pinned first, then the rest by date with the uploads among them")
    }

    // MARK: - Selection after a row leaves (QA #496 LOW-1)

    func testReselectPureCases() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        XCTAssertEqual(ClipboardPanelModel.reselect(b, old: [a, b, c], new: [a, c]), c, "middle gone: the next row")
        XCTAssertEqual(ClipboardPanelModel.reselect(c, old: [a, b, c], new: [a, b]), b, "last gone: the new last")
        XCTAssertNil(ClipboardPanelModel.reselect(a, old: [a], new: []), "only row gone: nothing")
        XCTAssertEqual(ClipboardPanelModel.reselect(a, old: [a, b, c], new: [a, c]), a, "still listed: unchanged")
        XCTAssertEqual(ClipboardPanelModel.reselect(a, old: [a, b, c], new: [b, c]), b)
        XCTAssertEqual(ClipboardPanelModel.reselect(a, old: [a, b, c], new: [c]), c, "skips a row gone with it")
        XCTAssertNil(ClipboardPanelModel.reselect(nil, old: [a], new: [a, b]))
    }

    /// A pinned old row, a today row and two older rows across buckets, plus `upload`'s date.
    private func bucketFixture(_ store: ClipboardStore, uploadAt: TimeInterval) throws -> (rows: [UUID], upload: UUID) {
        let day: TimeInterval = 86_400
        func add(_ ago: TimeInterval) -> UUID {
            let id = UUID()
            store.addRemote(id: id, date: Date().addingTimeInterval(-ago), source: "iPhone", sha256: id.uuidString,
                            .text("row \(id)"))
            return id
        }
        let pinned = add(20 * day)
        store.togglePin(try XCTUnwrap(store.item(pinned)))
        _ = add(60)
        _ = add(10 * day)
        _ = add(12 * day)
        let u = upload(store, at: Date().addingTimeInterval(-uploadAt))
        let rows = store.historyRows.map(\.id)
        XCTAssertEqual(rows, clipboardVisualOrder(store.historyRows), "history order is the order the list draws")
        XCTAssertEqual(rows.first, pinned)
        return (rows, u.id)
    }

    func testCancelledMiddleRowSelectsTheNextVisualRow() throws {
        let store = ClipboardStore(dir: tempDir())
        let f = try bucketFixture(store, uploadAt: 5 * 86_400)   // between the today and the 10-day rows
        let i = try XCTUnwrap(f.rows.firstIndex(of: f.upload))
        XCTAssertEqual(i, 2, "pinned, today, upload, …")
        store.cancel(f.upload)
        let next = ClipboardPanelModel.reselect(f.upload, old: f.rows, new: clipboardVisualOrder(store.historyRows))
        XCTAssertEqual(next, f.rows[i + 1])
    }

    func testCancelledLastRowSelectsTheNewLastRow() throws {
        let store = ClipboardStore(dir: tempDir())
        let f = try bucketFixture(store, uploadAt: 40 * 86_400)   // the "Older" bucket, last
        XCTAssertEqual(f.rows.last, f.upload)
        store.endReceiving(f.upload)   // failed
        let new = clipboardVisualOrder(store.historyRows)
        XCTAssertEqual(ClipboardPanelModel.reselect(f.upload, old: f.rows, new: new), f.rows[f.rows.count - 2])
        XCTAssertEqual(new.last, f.rows[f.rows.count - 2])
    }

    func testLandedUploadKeepsTheSelection() throws {
        let store = ClipboardStore(dir: tempDir())
        let f = try bucketFixture(store, uploadAt: 5 * 86_400)
        let r = try XCTUnwrap(store.receiving[f.upload])
        XCTAssertTrue(store.addRemote(id: r.id, date: r.createdAt, source: "iPhone", sha256: "landed", .text("landed")))
        store.endReceiving(r.id)
        let new = store.historyRows.map(\.id)
        XCTAssertEqual(new, f.rows, "the placeholder became its item: same ids, same order")
        XCTAssertEqual(ClipboardPanelModel.reselect(f.upload, old: f.rows, new: new), f.upload)
    }

    func testProgressText() {
        let r = ClipboardReceiving(id: UUID(), kind: .file, createdAt: Date(), name: nil, size: 2_000_000, bytes: 1_000_000)
        XCTAssertEqual(r.progressText, "1 MB of 2 MB")
        var over = r
        over.bytes = 3_000_000
        XCTAssertEqual(over.progressText, "2 MB of 2 MB", "never more than the size")
    }

    // MARK: - Paste waits

    func testNonReceivingRowPastesAtOnce() throws {
        let store = ClipboardStore(dir: tempDir())
        store.addText("hello \(UUID())")
        let item = store.items[0]
        let waiter = ClipboardPasteWait(store: store)
        var pasted: [UUID] = []
        _ = marker()
        waiter.paste(item) { store.copyToPasteboard($0); pasted.append($0.id) }
        XCTAssertEqual(pasted, [item.id])
        XCTAssertEqual(Pasteboard.general.string(forType: .string), store.text(for: item))
        XCTAssertNil(waiter.id)
        XCTAssertFalse(waiter.escape(), "nothing waiting: Esc closes the panel as before")
    }

    func testWaitThenPaste() throws {
        let store = ClipboardStore(dir: tempDir())
        let r = upload(store, kind: .text)
        let waiter = ClipboardPasteWait(store: store)
        var pasted: [UUID] = []
        let before = marker()
        waiter.paste(try row(store, r.id)) { store.copyToPasteboard($0); pasted.append($0.id) }
        XCTAssertEqual(waiter.id, r.id)
        store.receivingProgress(r.id, bytes: r.size / 2)
        XCTAssertTrue(pasted.isEmpty)
        let text = "from the phone \(UUID())"
        XCTAssertTrue(store.addRemote(id: r.id, date: r.createdAt, source: "iPhone", sha256: "s", .text(text)))
        store.endReceiving(r.id)   // DchClipboard's add(): insert, then end, in one main hop
        XCTAssertEqual(pasted, [r.id])
        XCTAssertEqual(Pasteboard.general.string(forType: .string), text)
        XCTAssertNotEqual(text, before)
        XCTAssertNil(waiter.id)
        XCTAssertFalse(waiter.escape())
    }

    func testWaitThenGonePastesNothing() throws {
        let store = ClipboardStore(dir: tempDir())
        let r = upload(store)
        let waiter = ClipboardPasteWait(store: store)
        var pasted: [UUID] = []
        let before = marker()
        let placeholder = try row(store, r.id)
        waiter.paste(placeholder) { store.copyToPasteboard($0); pasted.append($0.id) }
        store.endReceiving(r.id)   // failed upload
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertNil(waiter.id, "the wait ends quietly")
        XCTAssertEqual(Pasteboard.general.string(forType: .string), before)
        // A stale placeholder row pasted after the upload is gone does nothing either.
        waiter.paste(placeholder) { store.copyToPasteboard($0); pasted.append($0.id) }
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(Pasteboard.general.string(forType: .string), before)
    }

    /// QA #493 V11: a second paste, here of a stale placeholder whose upload is gone, ends a
    /// live first wait, so the first upload landing later pastes nothing.
    func testASecondPasteEndsALiveFirstWait() throws {
        let store = ClipboardStore(dir: tempDir())
        let a = upload(store, kind: .text), b = upload(store)
        let gone = try row(store, b.id)
        store.endReceiving(b.id)
        let waiter = ClipboardPasteWait(store: store)
        var pasted: [UUID] = []
        let before = marker()
        waiter.paste(try row(store, a.id)) { store.copyToPasteboard($0); pasted.append($0.id) }
        XCTAssertEqual(waiter.id, a.id)
        waiter.paste(gone) { store.copyToPasteboard($0); pasted.append($0.id) }
        XCTAssertNil(waiter.id, "the first wait ended")
        XCTAssertFalse(waiter.escape())
        XCTAssertNotNil(store.receiving[a.id], "Esc did not reach the first upload")
        XCTAssertTrue(store.addRemote(id: a.id, date: a.createdAt, source: "iPhone", sha256: "s", .text("late \(UUID())")))
        store.endReceiving(a.id)
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(Pasteboard.general.string(forType: .string), before)
    }

    /// A real DchClipboardUpload (as DchClipboardFramesTests drives it): its own insert / end
    /// order, not the store driven by hand, must land the item before the row leaves.
    func testWaitOnARealUploadPastesTheLandedItemOnce() throws {
        let store = ClipboardStore(dir: tempDir("store")), received = tempDir("recv")
        var o = DchClipboardOps()
        o.enabled = { true }
        o.store = { store }
        o.receivedDir = { received }
        o.freeSpace = { _ in nil }
        final class Replies: @unchecked Sendable { let lock = NSLock(); var all: [Data] = [] }
        let replies = Replies()
        let up = DchClipboardUpload(ops: o, reply: { f in replies.lock.withLock { replies.all.append(f) } },
                                    closeConnection: {})
        let text = "from a real upload \(UUID())", body = Data(text.utf8), id = UUID()
        let header: [String: Any] = ["id": id.uuidString, "date": DchClipboardOps.wireDate(Date()), "kind": "text",
                                     "source": "iPhone", "size": body.count, "sha256": ClipboardStore.sha256(body),
                                     "live": false]
        up.start(try JSONSerialization.data(withJSONObject: header))
        XCTAssertTrue(spin { store.receiving[id] != nil }, "begin() lands the row")
        let waiter = ClipboardPasteWait(store: store)
        var pasted: [ClipboardItem] = []
        _ = marker()
        waiter.paste(try row(store, id)) { store.copyToPasteboard($0); pasted.append($0) }
        XCTAssertEqual(waiter.id, id)
        up.feed(body)
        XCTAssertTrue(spin { replies.lock.withLock { !replies.all.isEmpty } }, "the upload replies")
        up.sync()
        XCTAssertEqual(pasted.map(\.id), [id], "pasted exactly once")
        XCTAssertEqual(pasted.first?.source, "iPhone")
        XCTAssertEqual(Pasteboard.general.string(forType: .string), text)
        XCTAssertNil(waiter.id)
    }

    private func spin(until cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(10)
        while !cond() {
            guard Date() < end else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return true
    }

    func testEscCancelsTheWaitAndTheUpload() throws {
        let store = ClipboardStore(dir: tempDir())
        let cancelled = expectation(description: "upload cancel")
        let r = upload(store, onCancel: { cancelled.fulfill() })
        let waiter = ClipboardPasteWait(store: store)
        var pasted: [UUID] = []
        let before = marker()
        waiter.paste(try row(store, r.id)) { store.copyToPasteboard($0); pasted.append($0.id) }
        XCTAssertTrue(waiter.escape(), "Esc is used by the wait, so the panel stays open on this press")
        wait(for: [cancelled], timeout: 1)
        XCTAssertNil(store.receiving[r.id])
        XCTAssertNil(store.historyRows.first { $0.id == r.id })
        XCTAssertNil(waiter.id)
        XCTAssertFalse(waiter.escape(), "the next Esc closes the panel")
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertEqual(Pasteboard.general.string(forType: .string), before)
    }

    func testPlaceholderCapturedBeforeCompletionPastesTheItem() throws {
        let store = ClipboardStore(dir: tempDir())
        let r = upload(store, kind: .text)
        let placeholder = try row(store, r.id)
        let text = "landed \(UUID())"
        XCTAssertTrue(store.addRemote(id: r.id, date: r.createdAt, source: "iPhone", sha256: "s", .text(text)))
        store.endReceiving(r.id)
        let waiter = ClipboardPasteWait(store: store)
        var pasted: [ClipboardItem] = []
        _ = marker()
        waiter.paste(placeholder) { store.copyToPasteboard($0); pasted.append($0) }
        XCTAssertEqual(pasted.map(\.source), ["iPhone"], "the stored item, not the placeholder")
        XCTAssertEqual(Pasteboard.general.string(forType: .string), text)
    }

    // MARK: - Render

    /// The row at 0 / 50 / 100 % at UI scale 1.0 and 0.85: the bar and "x of y" fit
    /// the row's card with nothing clipped. PNGs go to PROSPER_RENDER_DIR when set.
    func testReceivingRowRendersUnclipped() throws {
        let store = ClipboardStore(dir: tempDir())
        let model = ClipboardPanelModel()
        let out = tempDir()
        let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let r = upload(store, name: "IMG_4821 holiday video.mov", kind: .file, size: 1_340_000_000)
        model.selectedId = r.id
        for scale: CGFloat in [1.0, 0.85] {
            ThemeRuntime.scale = scale
            // The text column: list width minus the row's paddings, leading icon and spacing.
            let column = sz(300) - sz(4) - sz(52) - 2 * sz(8) - sz(28) - sz(8)
            var pngs: [Int: Data] = [:]
            for pct in [0, 50, 100] {
                store.receivingProgress(r.id, bytes: r.size / 100 * pct)
                let rec = try XCTUnwrap(store.receiving[r.id])
                let item = try row(store, r.id)
                let view = ClipRowView(store: store, model: model, item: item, onTap: {})
                    .frame(width: sz(300))
                    .background(Neon.bgTop)
                let png = try render(view, size: CGSize(width: sz(300), height: ClipboardView.rowPitch))
                pngs[pct] = png
                let file = "clipboard-receiving-\(pct)-\(scale).png"
                try png.write(to: out.appendingPathComponent(file))
                if let extra { try png.write(to: extra.appendingPathComponent(file)) }

                // Natural height of the progress content fits the row's card (pitch - 8).
                let content = ClipReceivingProgress(receiving: rec, title: item.displayTitle, selected: true)
                    .frame(width: column)
                    .fixedSize(horizontal: false, vertical: true)
                let h = try XCTUnwrap(ImageRenderer(content: content).cgImage).height
                XCTAssertLessThanOrEqual(CGFloat(h), ClipboardView.rowPitch - 8, "scale \(scale) \(pct)%: content taller than the row")
                // "x of y" leaves the name most of the column.
                let label = Text(rec.progressText).font(Neon.font(11)).fixedSize()
                let w = try XCTUnwrap(ImageRenderer(content: label).cgImage).width
                XCTAssertLessThanOrEqual(CGFloat(w), column * 0.6, "scale \(scale) \(pct)%: \(rec.progressText)")
            }
            XCTAssertNotEqual(pngs[0], pngs[50], "scale \(scale): the row shows the progress")
            XCTAssertNotEqual(pngs[50], pngs[100], "scale \(scale): the row shows the progress")
        }
    }

    private func render(_ view: some View, size: CGSize) throws -> Data {
        let r = ImageRenderer(content: view)
        r.scale = 2
        let cg = try XCTUnwrap(r.cgImage)
        XCTAssertEqual(CGFloat(cg.width), (size.width * 2).rounded(), accuracy: 1)
        XCTAssertEqual(CGFloat(cg.height), size.height * 2, accuracy: 1)
        return try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
    }
}
