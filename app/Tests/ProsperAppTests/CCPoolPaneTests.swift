import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #871 P2a: the (unmounted) ccpool pane. Hosted offscreen only: the window is never ordered front
/// or made key, nothing is clicked, no global event is posted.
@MainActor
final class CCPoolPaneTests: XCTestCase {
    private final class BackingWindow: NSWindow {
        var fixedBacking: CGFloat?
        override var backingScaleFactor: CGFloat { fixedBacking ?? super.backingScaleFactor }
    }

    private func flush(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
    }

    /// The Settings detail width at `scale`: SettingsWindow.contentMinSize minus the sidebar.
    private func room(_ scale: CGFloat) -> CGFloat { 820 * max(scale, 0.85) - 302 * scale }

    /// Hosts the pane in an offscreen window at `width`; returns the host and its controller.
    private func host(_ model: CCPoolPaneModel, width: CGFloat, backing: CGFloat) -> (NSHostingController<CCPoolPane>, BackingWindow) {
        let hc = NSHostingController(rootView: CCPoolPane(model: model))
        let win = BackingWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 1600), styleMask: [.titled],
                                backing: .buffered, defer: false)
        win.fixedBacking = backing
        win.contentView = hc.view
        hc.view.frame = CGRect(x: 0, y: 0, width: width, height: 1600)
        flush(hc.view)
        return (hc, win)
    }

    /// Every string the pane's view values hold, walked by reflection: the AX tree of a SwiftUI host
    /// is empty in a window that is never shown. Section, row and ForEach content closures are
    /// called (CCPoolViewInner); class instances (the model, fonts, colours) are not entered, except
    /// SwiftUI's text storage, which holds a localized title's key.
    private func viewStrings(_ model: CCPoolPaneModel) -> [String] {
        var out: [String] = []
        func walk(_ v: Any, _ depth: Int) {
            guard depth < 120 else { return }
            if let s = v as? String { out.append(s); return }
            let mirror = Mirror(reflecting: v)
            if mirror.displayStyle == .class, !"\(type(of: v))".contains("TextStorage") { return }
            if let inner = v as? CCPoolViewInner { inner.ccpoolInner.forEach { walk($0, depth + 1) } }
            for c in mirror.children { walk(c.value, depth + 1) }
        }
        walk(CCPoolPane(model: model).sections, 0)
        return out
    }

    private func dumped(_ x: Any, maxDepth: Int = 12) -> String {
        var s = ""
        dump(x, to: &s, maxDepth: maxDepth)
        return s
    }

    /// The model's published state: each @Published storage, nothing it merely references.
    private func publishedState(_ m: CCPoolPaneModel) -> String {
        Mirror(reflecting: m).children.filter { ($0.label ?? "").hasPrefix("_") }.map { dumped($0.value) }.joined(separator: "\n")
    }

    /// A model showing as much as the pane can: long labels, an open action strip with its remove
    /// confirm, a notice, a limit, a hold, a refresh report, the import row.
    private func busyModel() async throws -> CCPoolPaneRig {
        let r = try ccpoolPaneRig()
        try r.add(["work-account-with-a-long-label@example.com", "personal", "spare"])
        r.store.mutate { st in
            st.current = "personal"
            st.bench("spare", claim: "seven_day_overage_included", until: 1_800_000_000 + 3600, now: 1_800_000_000)
            st.hold("personal", hours: 3, now: 1_800_000_000)
            st.accounts["spare"]?.cooldown["mystery_claim"] = 1_800_000_000 + 60
        }
        await r.model.refreshUsage()?.value
        r.model.select("work-account-with-a-long-label@example.com")
        r.model.requestRemove("work-account-with-a-long-label@example.com")
        r.model.notice = "Token rejected: someone-with-a-long-label@example.com was not added."
        try FileManager.default.createDirectory(at: r.vault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accounts": {"personal": {"token": "tok-p"}, "other": {"token": "tok-o"}}}"#.utf8).write(to: r.vault)
        r.model.checkVault()
        return r
    }

    func testCCPoolPaneFitsAtEveryScaleAndBacking() async throws {
        let r = try await busyModel()
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        // QA #739 INFO-12 (B9): the import's result states too, with the Trash offered and refused.
        for phase in ["accounts", "import review", "imported", "finished", "imported, vault kept"] {
            switch phase {
            case "import review":
                await r.model.beginImport().value
                guard case .review = r.model.importPhase else { return XCTFail("\(r.model.importPhase)") }
            case "imported":
                r.model.importChoices = ["personal": .replace]
                await r.model.runImport()?.value
                guard case .imported = r.model.importPhase else { return XCTFail("\(r.model.importPhase)") }
                XCTAssertNil(r.model.trashBlockedReason, "both buttons on one row")
            case "finished":
                r.model.finishImport(trash: false)
                guard case .finished = r.model.importPhase else { return XCTFail("\(r.model.importPhase)") }
            case "imported, vault kept":
                r.model.dismissImport()
                try Data(#"{"accounts": {"personal": {"token": "tok-p2"}, "other": {"token": "tok-o"}, "broken-entry-with-a-long-label": {}}}"#.utf8)
                    .write(to: r.vault)
                await r.model.beginImport().value
                r.model.importChoices = ["personal": .skip, "other": .skip]
                await r.model.runImport()?.value
                guard case .imported = r.model.importPhase else { return XCTFail("\(r.model.importPhase)") }
                XCTAssertNotNil(r.model.trashBlockedReason, "the reason caption and Keep it")
            default: break
            }
            for backing in [1, 2] as [CGFloat] {
                for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                    ThemeRuntime.scale = scale
                    let width = room(scale) - 2 * sz(16)
                    let (hc, win) = host(r.model, width: width, backing: backing)
                    defer { win.contentView = NSView() }
                    let pixel = 1 / win.backingScaleFactor
                    let fit = hc.sizeThatFits(in: CGSize(width: width, height: 100_000))
                    XCTAssertLessThanOrEqual(fit.width, width + pixel,
                                             "\(phase): pane wider than its room at scale \(scale), backing \(backing): \(fit.width) > \(width)")
                    XCTAssertGreaterThan(fit.height, 200, "\(phase): the pane laid out at scale \(scale)")
                }
            }
        }
    }

    // P2b-1 item 8: the mounted pane's own states fit at 0.7, 0.85 and 1.0 (both backings), offscreen.
    func testCCPoolPaneMountedStatesFit() async throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let t0 = 1_800_000_000
        var states: [(String, CCPoolPaneModel)] = []
        let empty = try ccpoolPaneRig()
        states.append(("no accounts", empty.model))

        let two = try ccpoolPaneRig()
        try two.add(["work-account-with-a-long-label@example.com", "personal"])
        two.store.mutate { $0.bench("personal", claim: "seven_day", until: t0 + 86400, now: Double(t0)) }
        guard case .limited? = two.model.rows.last?.state else { return XCTFail("\(two.model.rows)") }
        states.append(("two accounts, one limited", two.model))

        // The Python ccpool holds the port: the probe is a fake, nothing is dialled or bound.
        let held = try ccpoolPaneRig()
        try held.add(["personal"])
        var cfg = held.service.config
        cfg.port = 47_011
        cfg.portProbe = { _, _ in .ccpool(pid: 4242, impl: "python") }
        let svc = CCPoolService(config: cfg, store: held.store, secrets: held.secrets, logger: held.log)
        XCTAssertEqual(svc.start(), .heldByCCPool(pid: 4242))
        let heldModel = CCPoolPaneModel(store: held.store, secrets: held.secrets, service: svc, logger: held.log,
                                        defaults: held.defaults, probeBase: held.base, vaultURL: held.vault)
        XCTAssertTrue(heldModel.proxyText.hasPrefix("Another ccpool proxy (pid 4242)"), heldModel.proxyText)
        states.append(("python proxy holds the port", heldModel))

        let offered = try ccpoolPaneRig()
        try offered.add(["personal"])
        try FileManager.default.createDirectory(at: offered.vault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accounts": {"personal": {"token": "tok-p"}}}"#.utf8).write(to: offered.vault)
        offered.model.checkVault()
        XCTAssertTrue(offered.model.importVisible)
        states.append(("import offered", offered.model))

        for (name, m) in states {
            for backing in [1, 2] as [CGFloat] {
                for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                    ThemeRuntime.scale = scale
                    let width = room(scale) - 2 * sz(16)
                    let (hc, win) = host(m, width: width, backing: backing)
                    defer { win.contentView = NSView() }
                    let fit = hc.sizeThatFits(in: CGSize(width: width, height: 100_000))
                    XCTAssertLessThanOrEqual(fit.width, width + 1 / win.backingScaleFactor,
                                             "\(name): wider than its room at scale \(scale), backing \(backing): \(fit.width) > \(width)")
                    XCTAssertGreaterThan(fit.height, 200, "\(name): laid out at scale \(scale)")
                }
            }
        }
    }

    // P2b-1 item 5 (mutant h5): the pane as Settings mounts it, on a runtime's model, has no routing row.
    func testCCPoolMountedPaneHidesTheRoutingRow() throws {
        let dir = tempDir()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let rt = CCPoolRuntime(directory: dir.appendingPathComponent("ccpool"), secrets: CCPoolMemorySecrets(), config: cfg,
                               vaultURL: dir.appendingPathComponent("old"), defaults: scratchDefaults("ccpool-mounted"),
                               probeBase: cfg.upstream, logger: CCPoolCapturingLogger())
        try rt.store.addAccount(label: "alpha", token: "tok-alpha", secrets: rt.secrets)
        let s = viewStrings(rt.model)
        XCTAssertTrue(s.contains { $0.contains("alpha") }, "the walk saw the pane")
        XCTAssertFalse(s.contains { $0.contains(CCPoolPane.routeTitle) }, "no routing switch while nothing applies it")
        XCTAssertFalse(s.contains { $0.contains("Agent Sessions") })
    }

    // The token is in none of: the view tree, the published state, the log seam, any error.
    func testCCPoolPaneTokenNeverShownStoredOrLogged() async throws {
        let r = try ccpoolPaneRig()
        let m = r.model
        let token = "tok-alpha-secret"
        m.labelDraft = "alpha"
        m.tokenDraft = token
        let add = m.addAccount()
        XCTAssertEqual(m.tokenDraft, "", "the buffer is empty right after commit")
        await add.value
        XCTAssertEqual(m.notice, "Added alpha.")
        let id = try XCTUnwrap(r.store.snapshot.accounts["alpha"]?.id)
        XCTAssertEqual(try r.secrets.token(id: id), token, "the flow really stored it")
        XCTAssertTrue(r.anthropic.get { $0.seen }.contains("Bearer \(token)"), "and probed with it")

        // Errors on the way: a duplicate, a rejected token, an empty label.
        var errors: [String] = []
        r.anthropic.set { $0.reject = ["tok-beta": 401] }
        for (label, tok) in [("alpha", "tok-dup"), ("beta", "tok-beta"), ("", "tok-gamma")] {
            m.labelDraft = label
            m.tokenDraft = tok
            await m.addAccount().value
            XCTAssertEqual(m.tokenDraft, "")
            errors.append(m.notice ?? "")
        }
        m.select("alpha")
        let strings = viewStrings(m)
        XCTAssertTrue(strings.contains { $0.contains("alpha") }, "the walk saw the pane: \(strings.prefix(20))")
        XCTAssertTrue(publishedState(m).contains("alpha"), "the published state was read")
        let texts = strings + [publishedState(m)] + r.log.lines + errors
        for t in texts { XCTAssertFalse(t.contains("tok-"), "token leaked into: \(t.prefix(300))") }
        XCTAssertFalse(r.log.lines.contains { $0.lowercased().contains("bearer") })
    }

    // Remove asks first, inline: the confirm row shows, nothing is removed until it is confirmed.
    func testCCPoolPaneRemoveNeedsTheInlineConfirm() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["alpha", "beta"])
        r.model.select("alpha")
        XCTAssertFalse(viewStrings(r.model).contains { $0.contains("Remove alpha and its Keychain item?") })
        r.model.requestRemove("alpha")
        XCTAssertTrue(viewStrings(r.model).contains { $0.contains("Remove alpha and its Keychain item?") }, "the inline confirm row")
        XCTAssertEqual(r.store.snapshot.order, ["alpha", "beta"], "nothing removed yet")
        await r.model.confirmRemove()?.value
        XCTAssertEqual(r.store.snapshot.order, ["beta"])
        XCTAssertEqual(r.secrets.count, 1)
        XCTAssertFalse(viewStrings(r.model).contains { $0.contains("Remove alpha") })
    }

    // QA #734 INFO-4: an unreadable state.json is said in one line; an add is refused before any probe.
    func testCCPoolPaneSaysWhenTheStateCannotBeRead() async throws {
        let dir = tempDir().appendingPathComponent("ccpool")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("state.json"), withIntermediateDirectories: true)
        let log = CCPoolCapturingLogger()
        let store = CCPoolStore(directory: dir, logger: log)
        let secrets = CCPoolMemorySecrets()
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let service = CCPoolService(config: cfg, store: store, secrets: secrets, logger: log)
        let model = CCPoolPaneModel(store: store, secrets: secrets, service: service, logger: log,
                                    defaults: scratchDefaults("ccpool-pane-unreadable"),
                                    probeBase: cfg.upstream, vaultURL: dir.appendingPathComponent("old"))
        XCTAssertEqual(model.storeProblem, CCPoolStore.unreadableNote)
        XCTAssertTrue(viewStrings(model).contains(CCPoolStore.unreadableNote), "one line in the Accounts card")
        model.labelDraft = "alpha"
        model.tokenDraft = "tok-alpha"
        await model.addAccount().value
        XCTAssertEqual(model.notice, CCPoolStore.unreadableNote)
        XCTAssertEqual(secrets.count, 0)
    }

    func testCCPoolPaneCopy() async throws {
        let r = try ccpoolPaneRig()
        XCTAssertTrue(CCPoolPane.mintHint.contains("claude setup-token"))
        XCTAssertTrue(CCPoolPane.labelHint.contains("Labels are visible to local processes"), "errata C6")
        XCTAssertTrue(CCPoolPane.refreshHint.contains("one tiny request per account"))
        // QA #739 INFO-1 (B8): the order only breaks ties.
        XCTAssertFalse(CCPoolPane.accountsFooter.contains("Tried in this order"))
        XCTAssertTrue(CCPoolPane.accountsFooter.contains("five-hour window resets soonest"))
        var s = viewStrings(r.model)
        // P2b-1: the routing row is hidden until the spawn path applies it (CCPool.routingWired).
        XCTAssertEqual(s.contains { $0.contains(CCPoolPane.routeTitle) }, CCPool.routingWired)
        XCTAssertTrue(s.contains { $0.contains("Starts when the first account is added.") }, "the proxy row says why it is stopped")
        XCTAssertTrue(s.contains { $0.contains("ANTHROPIC_BASE_URL=") }, "terminal use, read-only text")
        XCTAssertFalse(s.contains { $0.contains("Import from ccpool") }, "no old vault: no import row")
        try FileManager.default.createDirectory(at: r.vault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"accounts": {}}"#.utf8).write(to: r.vault)
        r.model.checkVault()
        s = viewStrings(r.model)
        XCTAssertTrue(s.contains { $0.contains("Import from ccpool") }, "shown while a vault exists")
    }
}

/// View values whose content sits behind a closure: the walk calls it.
@MainActor protocol CCPoolViewInner { var ccpoolInner: [Any] { get } }
extension NeonSection: CCPoolViewInner { var ccpoolInner: [Any] { [content()] } }
extension NeonRow: CCPoolViewInner { var ccpoolInner: [Any] { [trailing()] } }
extension ForEach: CCPoolViewInner { var ccpoolInner: [Any] { data.map { content($0) as Any } } }
