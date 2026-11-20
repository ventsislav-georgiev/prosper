import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1760: open-to-first-frame of the ref card, offscreen (a never-shown window, cacheDisplay): the stream parse, the
/// context, the hosted card on Mentions laid out and drawn once. A timing row: it prints, it asserts no time. The same
/// file builds at the base tree, for the before number.
@MainActor
final class XrayCardOpenTimingTests: XCTestCase {
    func testOpenToFirstFrameTiming() throws {
        let lines = [XrayRefStreamTests.first] + (0..<120).map { i in
            XrayRefTurnTests.mention(turn: 1 + i / 10, offset: i, sentence: "You **Unthreaded hold:** `decide` in deltaScope.ts for #12", span: [55, 58])
        } + [XrayRefStreamTests.done]
        let data = Data(lines.joined(separator: "\n").utf8)
        let refs = try XCTUnwrap(XrayRefs.parse(XrayRefsParseTests.object(refs: XrayRefPopoverTests.refs)))
        let e = try XCTUnwrap(refs.entries.first { $0.text == "#12" })
        var opens: [Double] = [], parses: [Double] = []
        for _ in 0..<6 {
            let t0 = Date()
            let s = XrayRefStream.parse(data)
            let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .refs)
            p.refContext = XrayRefContext(s, ref: "#12", tasks: nil, memory: nil)
            let t1 = Date()
            let size = XrayRefPopover.size
            let (win, host) = AXTreeSupport.hosted(XrayRefPopover(panel: p, entry: e, complete: true, tab: .mentions), size)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
            opens.append(Date().timeIntervalSince(t0) * 1000)
            parses.append(t1.timeIntervalSince(t0) * 1000)
            win.contentView = nil
            win.close()
        }
        let warm = opens.dropFirst().sorted(), warmParse = parses.dropFirst().sorted()
        print("XRAY_CARD_OPEN_MS first=\(opens.first ?? 0) median=\(warm[warm.count / 2]) parse_median=\(warmParse[warmParse.count / 2]) mentions=120")
        XCTAssertEqual(opens.count, 6)
    }
}
