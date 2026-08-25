import XCTest
@testable import ProsperApp

/// `CommandRouter.menuHits` — the pure half of the menu-command palette rows.
/// The AX walk that produces the input needs a live menu bar and an Accessibility
/// grant, so it stays manual QA; everything downstream of it is testable here.
final class MenusPaletteTests: XCTestCase {

    private func cmd(_ path: [String], _ title: String, _ shortcut: String? = nil,
                     id: String = "1:0") -> MenuCommand {
        MenuCommand(id: id, path: path, title: title, shortcut: shortcut)
    }

    private func hits(_ rows: [MenuCommand], _ query: String,
                      app: String = "Safari") -> [SearchHit] {
        let q = query.lowercased()
        return CommandRouter.menuHits(rows: rows, q: q,
                                      tokens: q.split(separator: " ").map(String.init),
                                      appName: app)
    }

    // MARK: - No rows

    /// An empty index (nothing walked yet, or Accessibility not granted — the walk
    /// returns [] either way) must produce no rows, not a crash and not a blank row.
    func testNoRowsWhenIndexEmpty() {
        XCTAssertTrue(hits([], "export").isEmpty)
    }

    /// One-character queries are floored out: nearly every menu bar matches a
    /// single letter, which would bury apps and links under menu noise.
    func testNoRowsBelowTwoCharacterFloor() {
        let rows = [cmd(["File"], "Export as PDF…")]
        XCTAssertTrue(hits(rows, "e").isEmpty)
        XCTAssertFalse(hits(rows, "ex").isEmpty)
    }

    /// A query that matches nothing in the menu bar yields nothing, even though
    /// the index is populated.
    func testNoRowsWhenNothingMatches() {
        XCTAssertTrue(hits([cmd(["File"], "Export as PDF…")], "kubernetes").isEmpty)
    }

    // MARK: - Ranking

    /// Exact title beats prefix beats scattered-token, on the shared ladder.
    func testRankingPrefersCloserMatches() {
        let rows = [
            cmd(["Edit"], "Paste and Match Style"),   // contains "paste"
            cmd(["Edit"], "Paste"),                   // exact-ish: "safari edit › paste"
            cmd(["File"], "Export as PDF…"),          // no match
        ]
        let ranked = hits(rows, "paste")
        XCTAssertEqual(ranked.map(\.title), ["Paste", "Paste and Match Style"])
        XCTAssertGreaterThan(ranked[0].score, ranked[1].score)
    }

    /// The app name is part of the haystack, so "safari export" finds Safari's
    /// export item even though "safari" appears nowhere in the breadcrumb.
    func testAppNameIsSearchable() {
        let rows = [cmd(["File"], "Export as PDF…")]
        XCTAssertEqual(hits(rows, "safari export").count, 1)
        XCTAssertTrue(hits(rows, "chrome export").isEmpty)
    }

    /// Menu rows sit last on a score tie so a same-scored app/link/bookmark is
    /// never shadowed by whatever happens to be frontmost.
    func testMenuKindSortsLastOnATie() {
        let menu = hits([cmd(["File"], "Export")], "export")[0]
        let app = SearchHit(kind: .app, title: menu.title, subtitle: "", score: menu.score)
        XCTAssertTrue(SearchScore.before(app, menu))
        XCTAssertFalse(SearchScore.before(menu, app))
    }

    // MARK: - Capping

    /// 400 menu items on the same ladder as apps would own the top 12; only the
    /// best few compete.
    func testCapsAtMenuHitLimit() {
        let rows = (0..<40).map { cmd(["File"], "Export \($0)", id: "1:\($0)") }
        XCTAssertEqual(hits(rows, "export").count, CommandRouter.menuHitLimit)
    }

    /// The cap keeps the BEST rows, not the first ones the walk happened to emit.
    func testCapKeepsHighestScoringRows() {
        var rows = (0..<20).map { cmd(["File"], "Save Export Copy \($0)", id: "1:\($0)") }
        rows.append(cmd(["File"], "Export", id: "1:99"))
        let ranked = hits(rows, "export")
        XCTAssertEqual(ranked.count, CommandRouter.menuHitLimit)
        XCTAssertEqual(ranked[0].title, "Export")
    }

    // MARK: - Row payload

    /// Subtitle carries app + full menu path so two identically-titled items
    /// (`Format › Font › Bold` vs `Format › Text › Bold`) are distinguishable.
    func testPathInSubtitle() {
        let hit = hits([cmd(["Format", "Font"], "Bold", "⌘B", id: "3:7")], "bold")[0]
        XCTAssertEqual(hit.subtitle, "Safari › Format › Font › Bold")
        XCTAssertEqual(hit.title, "Bold")
        XCTAssertEqual(hit.accessory, "⌘B")
        XCTAssertEqual(hit.kind, .menu)
    }

    /// The action payload is the generation-tagged row id — a bare index would
    /// press the wrong command after a refresh.
    func testActionValueCarriesGenerationTaggedID() {
        let hit = hits([cmd(["File"], "Export", id: "3:7")], "export")[0]
        XCTAssertEqual(hit.actionValue, "3:7")
        XCTAssertEqual(MenuCommandIndex.decodeIndex(hit.actionValue ?? "", generation: 3), 7)
        XCTAssertNil(MenuCommandIndex.decodeIndex(hit.actionValue ?? "", generation: 4))
    }

    /// An unknown app name (nothing walked yet) must not leave a dangling
    /// separator in the subtitle.
    func testSubtitleWithoutAppName() {
        let hit = hits([cmd(["File"], "Export")], "export", app: "")[0]
        XCTAssertEqual(hit.subtitle, "File › Export")
    }

    /// An item with no key equivalent carries no chip.
    func testNoAccessoryWithoutShortcut() {
        XCTAssertNil(hits([cmd(["File"], "Export")], "export")[0].accessory)
    }
}
