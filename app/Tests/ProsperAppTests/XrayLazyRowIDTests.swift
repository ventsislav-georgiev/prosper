import XCTest
@testable import ProsperApp

/// #1823: the Memory tab and Search's other-session groups give every lazy row an id unique across the stack
/// (XrayRefPopover.keyed, #1816); a per-group `id: \.offset` made each group's rows 0, 1, ... share views and stay blank.
final class XrayLazyRowIDTests: XCTestCase {

    private static func section(_ name: String, to end: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/AgentWindow/XrayPanel.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let a = try XCTUnwrap(src.range(of: name)), b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex))
        return String(src[a.upperBound..<b.lowerBound])
    }

    func testMemoryAndSearchListsKeyEveryRowByTheStackUniqueId() throws {
        // #1972: Memory draws one flat list of stable ids (memoryLines, made unique by XrayScrollAnchor.unique)
        for (name, end, keyed) in [("var searchTab: some View", "ForEach(panel.searchFooter", "XrayRefPopover.keyed("),
                                   ("var memoryTab: some View", "ForEach(panel.goneFooter", "panel.memoryLines")] {
            let body = try Self.section(name, to: end)
            XCTAssertFalse(body.contains("id: \\.offset"), "\(name): a per-group offset id repeats across groups in the LazyVStack")
            XCTAssertTrue(body.contains(keyed), name)
        }
    }

    func testKeyedIdsAreUniqueAcrossGroups() {
        let groups = [[1, 2], [3, 4]]
        let ids = XrayRefPopover.keyed(groups, part: 0).flatMap { g in
            [g.id] + XrayRefPopover.keyed(g.e, part: 0, block: g.id.row).map(\.id)
        }
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
