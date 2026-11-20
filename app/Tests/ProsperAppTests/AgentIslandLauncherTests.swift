import Carbon
import XCTest
@testable import ProsperApp

/// #1536 (OQ-95 part 2): the launcher's Open Agent Island command and its optional global shortcut.
/// No hotkey is registered (the rows read `ShortcutStore` values and `windowHotkey`'s closure without
/// running it), no monitor is installed (both monitor seams are fakes), no panel is built or ordered
/// (`showsPanel = false`), no dch runs (the io and history seams are fakes). The store rows write only
/// `Preferences.defaults`, the in-memory XCTest scratch store, asserted first.
final class AgentIslandLauncherTests: XCTestCase {
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    private func session(_ name: String, _ state: AgentState) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: "/Users/example/d", name: name), alias: "", activity: 0, state: state, agents: 0)
    }

    /// A controller on fakes and a store holding `sessions`, sorted by name so the drawn order is the names'.
    @MainActor private func controller(_ sessions: [AgentSession], sidekicks pattern: String = "") -> AgentIslandController {
        let c = AgentIslandController()
        c.showsPanel = false
        c.center = NotificationCenter()
        c.io = AgentPromptIO(read: { _ in "" }, status: { _ in "idle" }, send: { _, _ in })
        c.controlDch = { nil }
        c.historyDirs = { [] }
        c.seedDirs = { [] }
        c.listSessions = { _ in [] }
        c.readLiveRecords = { _ in [] }
        c.monitorClicks = { _ in "global" }
        c.monitorOwnClicks = { _ in "local" }
        c.removeMonitor = { _ in }
        let store = AgentIslandStore(geometry: notched, sort: .name, sidekickPattern: pattern)
        store.sessions = sessions
        c.store = store
        return c
    }

    // MARK: - The launcher command

    /// Through the real router: the row is listed for what a person would type.
    func testOpenAgentIslandIsListedInTheLauncher() async {
        for q in ["agent island", "island", "needs input"] {
            guard case .search(let hits) = await CommandRouter.run(q) else {
                XCTFail("\u{201C}\(q)\u{201D} produced no search outcome")
                continue
            }
            XCTAssertTrue(hits.contains { $0.metaCommand == .openAgentIsland }, "\u{201C}\(q)\u{201D} lists Open Agent Island")
        }
        XCTAssertEqual(MetaCommand.openAgentIsland.label, "Open Agent Island")
    }

    @MainActor func testOpenFocusedOpensExpandedOnTheFirstSessionNeedingInput() throws {
        let c = controller([session("api", .idle), session("api-qa", .blocked), session("web", .blocked)])
        XCTAssertTrue(c.openFocused())
        let store = try XCTUnwrap(c.store)
        XCTAssertTrue(store.expanded, "the command opens the island expanded")
        XCTAssertEqual(store.focusKey?.name, "api-qa", "the first drawn session that needs input, not the first row")
    }

    @MainActor func testOpenFocusedFallsBackToTheFirstSessionWhenNoneNeedsInput() throws {
        let c = controller([session("web", .working), session("api", .idle)])
        XCTAssertTrue(c.openFocused())
        let store = try XCTUnwrap(c.store)
        XCTAssertTrue(store.expanded)
        XCTAssertEqual(store.focusKey?.name, "api", "the first drawn session (name order)")
    }

    /// A sidekick needing input beats an idle primary row: its tab is shown so the focused row is drawn.
    @MainActor func testANeedingSidekickIsFocusedOnItsTab() throws {
        let c = controller([session("api", .idle), session("api-helper", .blocked)], sidekicks: "helper")
        XCTAssertTrue(c.openFocused())
        let store = try XCTUnwrap(c.store)
        XCTAssertEqual(store.focusKey?.name, "api-helper")
        XCTAssertTrue(store.groupTab == SessionGroup.sidekicksID, "the sidekick's tab is shown")
        XCTAssertEqual(store.visible.map(\.name), ["api-helper"])
    }

    /// Already open: the press still moves the focus; collapsing drops it.
    @MainActor func testOpenOnAnOpenIslandFocusesAndCollapseClearsIt() throws {
        let c = controller([session("api", .idle), session("web", .blocked)])
        c.setExpanded(true)
        let store = try XCTUnwrap(c.store)
        XCTAssertTrue(store.focusKey == nil, "a plain open focuses nothing")
        XCTAssertTrue(c.openFocused())
        XCTAssertEqual(store.focusKey?.name, "web")
        c.setExpanded(false)
        XCTAssertTrue(store.focusKey == nil, "the next open picks its own")
    }

    /// The island off (no store): false, so the runner opens Settings instead; nothing is built.
    @MainActor func testNoStoreReportsNotOpened() {
        let c = AgentIslandController()
        c.showsPanel = false
        XCTAssertFalse(c.openFocused())
        XCTAssertTrue(c.store == nil)
    }

    // MARK: - The global shortcut

    /// #1581: the shortcut toggles: closed, it opens focused as the launcher command does; open, it closes.
    @MainActor func testShortcutTogglesTheIsland() throws {
        let c = controller([session("api", .idle), session("web", .blocked)])
        let store = try XCTUnwrap(c.store)
        c.toggleFocused()
        XCTAssertTrue(store.expanded, "a closed island opens")
        XCTAssertEqual(store.focusKey?.name, "web", "on the session that needs input")
        c.toggleFocused()
        XCTAssertFalse(store.expanded, "an open island closes")
        XCTAssertTrue(store.focusKey == nil)
        c.toggleFocused()
        XCTAssertTrue(store.expanded, "and opens again")
    }

    /// #1581 (OQ-95 Reduce Motion): the island has no motion to reduce. Open/close and expand swap frames at
    /// once (the panel's animationBehavior is .none, the root view drops every transaction's animation), so
    /// Reduce Motion is honoured whatever it is set to. A future animation here must read Reduce Motion
    /// through one seam (as AgentWindowModel.reduceMotion does) and be added to this list on purpose.
    func testIslandHasNoMotionToReduce() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/AgentIsland")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertTrue(files.count >= 5, "the island's sources were found")
        let motion = ["withAnimation", ".animation(", "animator()", "NSAnimationContext", ".transition(", "repeatForever",
                      ".symbolEffect", "phaseAnimator", "keyframeAnimator", "matchedGeometryEffect", "CABasicAnimation",
                      "allowsImplicitAnimation", "animate: true"]
        var text: [String: String] = [:]
        for f in files {
            let s = try String(contentsOf: f, encoding: .utf8)
            text[f.lastPathComponent] = s
            for m in motion { XCTAssertFalse(s.contains(m), "\(f.lastPathComponent) animates (\(m)) without Reduce Motion") }
        }
        XCTAssertTrue(text["AgentIslandController.swift"]?.contains("p.animationBehavior = .none") == true,
                      "the panel orders in and out without the window fade")
        XCTAssertTrue(text["AgentIslandView.swift"]?.contains(".transaction { $0.animation = nil }") == true,
                      "the root view drops implicit animations")
    }

    @MainActor func testShortcutIsOffByDefaultAndRegistersNothing() {
        let a = ShortcutAction.agentIsland
        XCTAssertEqual(a.defaultCombo, unsetKeyCombo, "off by default")
        XCTAssertEqual(a.title, "Open Agent Island")
        XCTAssertEqual(a.hotKeyId, 22)
        XCTAssertEqual(ShortcutAction.allCases.filter { $0.hotKeyId == a.hotKeyId }, [a])
        XCTAssertEqual(a.owningExtensionID, "com.prosper.agentisland")
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "never the app's or the operator's defaults")
        guard Preferences.defaults is XCTestDefaults else { return }
        ShortcutStore.reset(.agentIsland)
        let list = ShortcutStore.builtInRegistrations([(action: a, payload: 1)], isAvailable: { _ in true }, held: [])
        XCTAssertTrue(list.isEmpty, "nothing saved: no hotkey, even with the island on")
    }

    /// The Settings row's save: the recorded combo round-trips through the store and re-registers;
    /// turning it off saves the clear, which then registers nothing.
    @MainActor func testStoredShortcutRoundTrips() {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "never the app's or the operator's defaults")
        guard Preferences.defaults is XCTestDefaults else { return }
        let hooks = SettingsHooks.shared, kept = hooks.onShortcutsChanged
        var reran = 0
        hooks.onShortcutsChanged = { reran += 1 }
        defer { hooks.onShortcutsChanged = kept; ShortcutStore.reset(.agentIsland) }

        let mine = KeyCombo(keyCode: UInt32(kVK_ANSI_I), carbonModifiers: UInt32(controlKey | optionKey), display: "⌃⌥I")
        AgentIslandShortcutSection.save(mine)
        XCTAssertEqual(ShortcutStore.combo(for: .agentIsland), mine)
        XCTAssertEqual(ShortcutStore.savedCombo(for: .agentIsland), mine)
        XCTAssertEqual(reran, 1, "a recorded combo re-registers at once")
        let on = ShortcutStore.builtInRegistrations([(action: ShortcutAction.agentIsland, payload: 1)],
                                                    isAvailable: { _ in true }, held: [])
        XCTAssertEqual(on.map(\.combo), [mine])

        AgentIslandShortcutSection.save(unsetKeyCombo)
        XCTAssertEqual(ShortcutStore.savedCombo(for: .agentIsland), unsetKeyCombo, "the clear is saved, not the default")
        XCTAssertEqual(reran, 2)
        let off = ShortcutStore.builtInRegistrations([(action: ShortcutAction.agentIsland, payload: 1)],
                                                     isAvailable: { _ in true }, held: [])
        XCTAssertTrue(off.isEmpty)
    }
}
