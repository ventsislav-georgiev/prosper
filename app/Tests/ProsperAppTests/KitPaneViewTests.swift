import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1424 (#918 S4): the kit pane and the install-selection sheet, UNMOUNTED. Hosted offscreen only: an NSHostingController
/// that is never put in a window, so nothing is ordered front, made key, clicked or posted. A never-shown host has an
/// empty AX tree (the ccpool pane rows found the same), so what is offered, enabled and labelled is read from KitPaneView.controls,
/// the one list the view draws its controls from. The model runs over the KitPaneModelTests fixtures: real KitStore and
/// ManagedConfig under the row's tempDir(), a recording consent, a fake login PATH. The opener is a recorder.
@MainActor
final class KitPaneViewTests: XCTestCase {
    typealias Env = KitRuntimeTests.Env
    static let ext = KitPaneModelTests.ext

    /// Records what the pane asked to reveal or open (the seam; NSWorkspace is never reached).
    @MainActor
    final class Opened {
        var revealed: [URL] = []
        var opened: [URL] = []
        var opener: KitPaneOpener { KitPaneOpener(reveal: { self.revealed.append($0) }, open: { self.opened.append($0) }) }
    }

    private func model(_ e: Env, _ rec: ExtensionRecord) -> KitPaneModel {
        KitPaneModel(extID: Self.ext, owner: kitPaneOwner(e) { [rec] })
    }

    private func control(_ m: KitPaneModel, _ id: String) -> KitPaneControl? { KitPaneView.controls(m).first { $0.id == id } }

    /// The Settings detail width at `scale` (as the ccpool pane rows compute it), less the pane's padding.
    private func room(_ scale: CGFloat) -> CGFloat { 820 * max(scale, 0.85) - 302 * scale - 2 * sz(16) }

    /// The pane's fitting size at `width`, laid out in a host that is never put in a window.
    private func fit(_ m: KitPaneModel, width: CGFloat) -> CGSize {
        let hc = NSHostingController(rootView: KitPaneView(model: m, opener: Opened().opener))
        hc.view.frame = CGRect(x: 0, y: 0, width: width, height: 1600)
        hc.view.layoutSubtreeIfNeeded()
        return hc.sizeThatFits(in: CGSize(width: width, height: 100_000))
    }

    private func applied(_ e: Env, kit: String = KitFixture.kit, extra: [(String, String, Int)] = []) async throws -> (KitPaneModel, ExtensionRecord) {
        let r = ExtensionRecord(loaded: try kitPaneSource(e, kit: kit, extra: extra), enabled: true, trusted: true)
        let m = model(e, r)
        await m.load()?.value
        await m.apply()?.value
        XCTAssertEqual(m.result, "done")
        return (m, r)
    }

    // MARK: S4 rows

    /// Every section renders for the fixture kit: header, requirements, pieces (with the hook line and the tool
    /// switches), actions, settings, the A9 and user-scope lines; the pane lays out.
    func testEverySectionRendersForAFixtureKit() async throws {
        let e = try kitPaneEnv()
        let (m, _) = try await applied(e)
        let ids = Set(KitPaneView.controls(m).map(\.id))
        for id in ["reveal", "local", "apply", "repair", "remove", "save", "setting:default_repo",
                   "tool:tools/calm-note", "tool:tools/calm-todo"] {
            XCTAssertTrue(ids.contains(id), "\(id) in \(ids.sorted())")
        }
        let rows = KitPaneView.pieceRows(m)
        XCTAssertEqual(rows.map(\.id), ["rules", "tools", "guard", "hud", "perms", "config"])
        for r in rows { XCTAssertTrue(ids.contains("piece:\(r.id)") && ids.contains("menu:\(r.id)"), r.id) }
        XCTAssertEqual(rows.first { $0.id == "guard" }?.hook, "PreToolUse Bash")
        XCTAssertEqual(m.facts?.requirements.count, 1)
        let notes = KitPaneView.notes(m)
        XCTAssertTrue(notes.contains(KitPaneView.applyNote) && notes.contains(KitPaneView.userScopeNote))
        XCTAssertFalse(notes.contains(KitPaneView.editedNote), "a clean apply is not edited")
        XCTAssertTrue(KitPaneView.subtitle(m).contains("applied: 1.0.0"), KitPaneView.subtitle(m))
        XCTAssertGreaterThan(fit(m, width: room(1)).height, 200, "the pane laid out")
    }

    /// #1887 / #1888: each tool of a tools piece is DRAWN with its name as text (an AXStaticText whose value is exactly the
    /// name; the switch's own label "Tool calm-note of piece tools on" never matches), not as a bare switch. Red with the NeonRow dropped.
    func testEachToolRowDrawsItsName() async throws {
        let e = try kitPaneEnv()
        let (m, _) = try await applied(e)
        let view = KitPaneView(model: m, opener: Opened().opener)
        let names = ["calm-note", "calm-todo"]
        let tree = AXTreeSupport.tree(view, CGSize(width: room(1), height: 1600)) { t in
            names.allSatisfy { n in t.contains { $0.role == "AXStaticText" && $0.value == n } }
        }
        for n in names {
            XCTAssertTrue(tree.contains { !$0.ignored && $0.role == "AXStaticText" && $0.value == n }, "\(n) drawn as text: \(tree.map { "\($0.role) \($0.value)" })")
        }
    }

    /// Long outside text (a title and an author with stacked combining marks, a long hook matcher) is clipped and the
    /// pane does not overflow its room at scale 0.85, 1 and 1.5.
    func testLongOutsideTextFitsAtEveryScale() async throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let e = try kitPaneEnv()
        let marks = String(repeating: "e\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}", count: 20)
        let kit = KitFixture.kit.replacingOccurrences(of: "matcher = \"Bash\"", with: "matcher = \"" + String(repeating: "Bash|", count: 50) + "Edit\"")
        let src = try kitPaneSource(e, kit: kit, title: marks, author: String(marks.prefix(18)) + " Example Org")
        let r = ExtensionRecord(loaded: src, enabled: true, trusted: true)
        let m = model(e, r)
        await m.load()?.value
        await m.apply()?.value
        XCTAssertTrue(m.live != nil, "\(String(describing: m.result))")
        XCTAssertEqual(m.title, marks)
        XCTAssertLessThanOrEqual(KitPaneView.subtitle(m).unicodeScalars.filter { $0 == "\u{0301}" }.count, 3 * 18, "marks capped at three per base")
        XCTAssertLessThanOrEqual(KitPaneView.pieceRows(m).first { $0.id == "guard" }?.hook?.count ?? 0, 120, "the hook line is clipped")
        for scale in [0.85, 1.0, 1.5] as [CGFloat] {
            ThemeRuntime.scale = scale
            let width = room(scale)
            let got = fit(m, width: width)
            XCTAssertLessThanOrEqual(got.width, width + 1, "wider than its room at scale \(scale): \(got.width) > \(width)")
            XCTAssertGreaterThan(got.height, 200, "laid out at scale \(scale)")
        }
    }

    /// VoiceOver: every switch, row menu, menu item, checkbox, field and button carries a non-empty label of its own;
    /// the piece switches and menus name their piece.
    func testEveryControlHasItsOwnAccessibilityLabel() async throws {
        let e = try kitPaneEnv()
        let (m, _) = try await applied(e)
        let plan = KitPaneView.controls(m)
        XCTAssertTrue(plan.allSatisfy { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }, "\(plan.filter { $0.label.isEmpty })")
        let own = plan.filter { !($0.kind == .menuItem && ($0.id.hasSuffix(":apply") || $0.id.hasSuffix(":repair"))) }
        XCTAssertEqual(Set(own.map(\.label)).count, own.count, "labels are unique (the whole-kit Apply and Repair each row menu repeats aside)")
        for r in KitPaneView.pieceRows(m) {
            XCTAssertEqual(control(m, "piece:\(r.id)")?.label.contains(r.id), true, r.id)
            XCTAssertEqual(control(m, "menu:\(r.id)")?.label.contains(r.id), true, r.id)
        }
        let fresh = model(try kitPaneEnv(label: "fresh"), ExtensionRecord(loaded: try kitPaneSource(e), enabled: true, trusted: true))
        await fresh.load()?.value
        let boxes = KitPaneView.controls(fresh).filter { $0.kind == .checkbox }
        XCTAssertEqual(boxes.count, 6)
        XCTAssertTrue(boxes.allSatisfy { !$0.label.isEmpty && $0.label.contains($0.id.dropFirst("install:".count)) })
    }

    /// Untrusted (spec 4.9): no Apply, Repair, Update or Rollback anywhere in the controls, the row menus included;
    /// Remove stays; the pane says to trust it in Extensions. A never-applied untrusted kit offers no Apply either.
    func testUntrustedKitOffersNoApply() async throws {
        let e = try kitPaneEnv()
        let (m, r) = try await applied(e)
        r.trusted = false
        await m.load()?.value
        XCTAssertFalse(m.trusted)
        let ids = KitPaneView.controls(m).map(\.id)
        XCTAssertFalse(ids.contains { $0 == "apply" || $0 == "repair" || $0 == "update" || $0 == "rollback" || $0 == "install"
                                      || $0.hasSuffix(":apply") || $0.hasSuffix(":repair") }, "\(ids)")
        XCTAssertTrue(ids.contains("remove"))
        XCTAssertTrue(KitPaneView.notes(m).contains(KitPaneView.untrustedNote))
        let fresh = model(try kitPaneEnv(label: "fresh"), ExtensionRecord(loaded: try kitPaneSource(e), enabled: true, trusted: false))
        await fresh.load()?.value
        XCTAssertFalse(KitPaneView.controls(fresh).contains { $0.id == "install" })
        XCTAssertTrue(KitPaneView.controls(fresh).filter { $0.kind == .checkbox }.allSatisfy { !$0.enabled })
    }

    /// Busy: while this model's apply is parked at its sheet, every writing control is disabled; after it, enabled.
    /// #1423 left 3 (#1428): a second model's install-selection write meanwhile shows the busy text. The parked
    /// apply (KitParkedConsent) holds the runtime for the whole check; no sleep, no timing window.
    func testBusyDisablesButtonsAndASecondModelShowsBusy() async throws {
        let rec = KitRTConsent()
        let gate = KitParkedConsent(rec)
        let e = try kitPaneEnv(rec, sheet: gate)
        let r = ExtensionRecord(loaded: try kitPaneSource(e), enabled: true, trusted: true)
        let o = kitPaneOwner(e) { [r] }
        let a = KitPaneModel(extID: Self.ext, owner: o), b = KitPaneModel(extID: Self.ext, owner: o)
        await a.load()?.value
        await b.load()?.value
        XCTAssertTrue(KitPaneView.controls(a).filter { $0.kind == .checkbox || $0.id == "install" }.allSatisfy(\.enabled))
        let first = a.apply()
        let watcher = Task { await first?.value; gate.wake() }
        await gate.waitParked()
        XCTAssertTrue(gate.didPark)
        let during = KitPaneView.controls(a).filter { !["reveal", "local", "cancel"].contains($0.id) }
        XCTAssertFalse(during.isEmpty)
        XCTAssertTrue(during.allSatisfy { !$0.enabled }, "\(during.filter(\.enabled).map(\.id))")
        await b.apply()?.value
        XCTAssertEqual(b.busy, KitRuntime.busyText)
        XCTAssertEqual(KitPaneView.alerts(b), [KitRuntime.busyText], "busy once, no raw error text")
        gate.release()
        await first?.value
        await watcher.value
        XCTAssertEqual(a.result, "done")
        XCTAssertTrue(KitPaneView.controls(a).filter { $0.id == "apply" || $0.id.hasPrefix("piece:") }.allSatisfy(\.enabled))
    }

    /// A piece switched off (confirmed) shows "off" in its row.
    func testOffPieceShowsOff() async throws {
        let e = try kitPaneEnv()
        let (m, _) = try await applied(e)
        m.toggle("perms", on: false)
        XCTAssertEqual(m.pendingOff, ["perms"])
        XCTAssertNotNil(control(m, "confirm"))
        await m.confirmToggle()?.value
        let row = KitPaneView.pieceRows(m).first { $0.id == "perms" }
        XCTAssertEqual(row?.state, "off", "\(String(describing: row)) \(String(describing: m.result))")
        XCTAssertTrue(KitPaneView.pieceLine(row ?? .init(id: "", kind: "", state: "", tools: [])).contains("off"))
        XCTAssertNotEqual(KitPaneView.pieceRows(m).first { $0.id == "rules" }?.state, "off")
    }

    /// First apply: the checkbox list, one per piece, all checked; unchecking one names its dependents.
    func testFirstApplyShowsTheCheckboxListAllChecked() async throws {
        let e = try kitPaneEnv()
        let src = try kitPaneSource(e, kit: KitRuntimePaneTests.neededKit, extra: [("EXTRA.md", "# extra rules\n", 0o644)])
        let m = model(e, ExtensionRecord(loaded: src, enabled: true, trusted: true))
        await m.load()?.value
        XCTAssertTrue(m.live == nil)
        let boxes = KitInstallSheet.controls(m).filter { $0.kind == .checkbox }
        XCTAssertEqual(boxes.count, 7)
        XCTAssertTrue(m.installOff.isEmpty, "every box is checked")
        XCTAssertTrue(boxes.allSatisfy(\.enabled))
        XCTAssertNotNil(KitInstallSheet.controls(m).first { $0.id == "install" })
        XCTAssertFalse(KitPaneView.controls(m).contains { $0.id.hasPrefix("piece:") }, "the switches come after the first apply")
        m.installOff = ["tools"]
        XCTAssertEqual(KitInstallSheet.dependents(m).also, ["guard", "hud"])
        XCTAssertTrue(KitInstallSheet.lines(m).contains { $0.hasSuffix("guard, hud") }, "\(KitInstallSheet.lines(m))")
    }

    // MARK: #1421 carry

    /// A market kit over the market byte cap is named in the sheet and Apply is not offered; the same kit as a local
    /// one (the local cap) is offered.
    func testMarketKitOverTheCapIsNamedBeforeApply() async throws {
        let e = try kitPaneEnv()
        let big = String(repeating: "x", count: 300 << 10)
        let market = try kitPaneSource(e, updateURL: "prosper://market/com.example.kit", extra: [("big.txt", big, 0o644)])
        let m = model(e, ExtensionRecord(loaded: market, enabled: true, trusted: true))
        await m.load()?.value
        XCTAssertNotNil(m.facts?.sourceRefusal)
        XCTAssertTrue(KitInstallSheet.lines(m).contains { $0.hasPrefix(KitInstallSheet.capNote) }, "\(KitInstallSheet.lines(m))")
        XCTAssertFalse(KitInstallSheet.controls(m).contains { $0.id == "install" })
        let e2 = try kitPaneEnv(label: "local")
        let local = model(e2, ExtensionRecord(loaded: try kitPaneSource(e2, extra: [("big.txt", big, 0o644)]), enabled: true, trusted: true))
        await local.load()?.value
        XCTAssertTrue(local.facts?.sourceRefusal == nil)
        XCTAssertNotNil(KitInstallSheet.controls(local).first { $0.id == "install" })
    }

    // MARK: seams and outside text

    /// Reveal and Open local.md go through the opener only, with paths under the row's tempDir.
    func testRevealAndOpenGoThroughTheOpener() async throws {
        let e = try kitPaneEnv()
        let (m, _) = try await applied(e)
        let rec = Opened()
        KitPaneView.reveal(m, rec.opener)
        KitPaneView.openLocal(m, rec.opener)
        XCTAssertEqual(rec.revealed.map(\.path), [try KitStore.layout(configHome: e.roots.configHome, extID: Self.ext).live])
        XCTAssertEqual(rec.opened.map(\.lastPathComponent), ["local.md"])
        XCTAssertTrue(rec.opened.allSatisfy { $0.path.hasPrefix(e.root.path) }, "\(rec.opened)")
    }

    /// README: unseen scalars dropped line by line; over the cap it is not read.
    func testReadmeIsCleanedAndCapped() throws {
        let dir = tempDir()
        try Data("## What it changes\nhid\u{202E}den\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        XCTAssertEqual(KitPaneView.readme(dir), "## What it changes\nhidden\n")
        try Data(String(repeating: "x", count: KitPaneView.readmeMaxBytes + 1).utf8).write(to: dir.appendingPathComponent("README.md"))
        XCTAssertTrue(KitPaneView.readme(dir).hasPrefix("README.md cannot be read here"))
    }
}
