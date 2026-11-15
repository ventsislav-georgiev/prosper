import CryptoKit
import os
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1000: the clipboard panel says when history is not being saved (ClipboardStore.notice), and Cmd-Delete on the
/// last row selects the row above. Offscreen: every store lives in a tempDir() with an injected key source, the
/// view is hosted in a window that is never shown, and no key event and no pasteboard is touched.
@MainActor
final class ClipboardPanelNoticeTests: XCTestCase {

    private struct NoKey: Error {}

    private func gate(_ key: SymmetricKey, _ open: OSAllocatedUnfairLock<Bool>) -> ClipboardCrypto.KeySource {
        { if open.withLock({ $0 }) { return key }; throw NoKey() }
    }

    private func view(_ store: ClipboardStore, _ model: ClipboardPanelModel = ClipboardPanelModel()) -> ClipboardView {
        ClipboardView(store: store, model: model, onCommit: { _ in }, onCopy: { _ in }, onCancel: {})
    }

    /// The static-text nodes an AX client reads in the hosted panel view.
    private func staticTexts(_ store: ClipboardStore, until done: ([AXTreeNode]) -> Bool) -> [AXTreeNode] {
        AXTreeSupport.tree(Themed { self.view(store) }, CGSize(width: 750, height: 520), until: done)
            .filter { !$0.ignored && $0.role == "AXStaticText" }
    }

    private func reads(_ nodes: [AXTreeNode]) -> Bool { nodes.contains { $0.named(ClipboardStore.keyNotice) } }

    func testNoticeLineShownWhileTheKeyIsMissingAndGoneOnceItReturns() {
        let open = OSAllocatedUnfairLock(initialState: false)
        let store = ClipboardStore(dir: tempDir(), keySource: gate(SymmetricKey(size: .bits256), open))
        XCTAssertTrue(store.notice == nil, "a store with nothing to save says nothing")
        store.addText("alpha")
        XCTAssertEqual(store.notice, ClipboardStore.keyNotice)

        let shown = staticTexts(store) { self.reads($0) }
        XCTAssertTrue(reads(shown), "the notice is static text in the panel while nothing is saved")
        XCTAssertEqual(store.items.count, 1, "the line never replaces the clips held in memory")

        open.withLock { $0 = true }
        store.addText("beta")
        XCTAssertTrue(store.notice == nil, "the key is back and the store saved")
        let gone = AXTreeSupport.tree(Themed { self.view(store) }, CGSize(width: 750, height: 520)) { _ in true }
        XCTAssertFalse(reads(gone), "the line is gone as soon as notice is nil")
        XCTAssertEqual(store.items.count, 2)
    }

    func testNoticeLineTextIsTheStoresNoticeVerbatim() {
        let store = ClipboardStore(dir: tempDir(), keySource: { throw NoKey() })
        store.addText("alpha")
        let shown = staticTexts(store) { self.reads($0) }
        XCTAssertTrue(shown.contains { $0.named(store.notice ?? "") && $0.named(ClipboardStore.keyNotice) },
                      "one static text whose words equal ClipboardStore.keyNotice")
    }

    func testPanelGrowsWhenTheNoticeAppearsAndDisappears() {
        let open = OSAllocatedUnfairLock(initialState: false)
        let store = ClipboardStore(dir: tempDir(), keySource: gate(SymmetricKey(size: .bits256), open))
        let panel = ClipboardPanel(store: store)   // built, never ordered front
        XCTAssertFalse(panel.panel.isVisible)
        let before = panel.panel.frame.height
        store.addText("alpha")
        pump { panel.panel.frame.height > before }
        XCTAssertGreaterThan(panel.panel.frame.height, before, "the hosting view grows the panel for the notice line")
        open.withLock { $0 = true }
        store.addText("beta")
        pump { panel.panel.frame.height <= before + 0.5 }
        XCTAssertEqual(panel.panel.frame.height, before, accuracy: 0.5, "back to its height once the line is gone")
        XCTAssertFalse(panel.panel.isVisible)
    }

    private func pump(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// The view's own delete handler (what Cmd-Delete calls), no key event.
    func testDeleteSelectedOnTheLastRowSelectsTheRowAbove() throws {
        let store = ClipboardStore(dir: tempDir(), keySource: { SymmetricKey(size: .bits256) })
        for t in ["one", "two", "three"] { store.addText(t) }
        let rows = store.historyRows.map(\.id)
        XCTAssertEqual(rows.count, 3)
        let model = ClipboardPanelModel()
        model.selectedId = rows.last
        view(store, model).deleteSelected()
        XCTAssertEqual(store.historyRows.map(\.id), Array(rows.prefix(2)), "the last row is gone")
        XCTAssertEqual(model.selectedId, rows[1], "the row above, not the first row")
    }
}
