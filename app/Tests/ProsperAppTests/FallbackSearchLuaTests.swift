import XCTest
import LuaRuntime
@testable import ProsperApp

// MARK: - Test-local services stub

/// Bridges host.fallback.* Lua calls (which run off-main) to a real
/// FallbackSearchStore (which is @MainActor) via DispatchQueue.main.sync.
private final class FallbackAwareFakeServices: ExtensionHostServices, @unchecked Sendable {

    let store: FallbackSearchStore

    init(store: FallbackSearchStore) { self.store = store }

    // Bridge from an arbitrary background thread to @MainActor.
    @discardableResult
    private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    // --- fallback surface (routed to the real store via main-thread bridge) ---
    func fallbackList() -> String { onMain { self.store.providersJSON() } }
    func fallbackSave(_ json: String) { onMain { self.store.setProvidersJSON(json) } }
    func fallbackMode() -> Bool { onMain { self.store.appendMode } }
    func fallbackSetMode(_ on: Bool) { onMain { self.store.appendMode = on } }
    func fallbackImport() -> Int { 0 }   // import_browser not under test

    // --- stubs for the rest of ExtensionHostServices ---
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "{}" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
    func appsSearch(_ query: String) -> String { "[]" }
    func filesSearch(_ optsJSON: String) async -> String { "[]" }
    func filesAct(id: String, path: String) {}
    func timerSchedule(extensionID: String, id: String, every: Bool, seconds: Double, handler: String) {}
    func timerCancel(extensionID: String, id: String) {}
    func log(level: String, message: String) {}
    func envGet(_ name: String) -> String? { nil }
    func appLaunchOrFocus(_ nameOrBundleID: String) {}
    func appFrontmostJSON() -> String { "{}" }
    func appWindowCount(bundleID: String) -> Int { 0 }
    func appHide(bundleID: String) {}
    func runAppleScript(_ source: String) -> String { "{}" }
    func keyboardCurrentSource() -> String { "" }
    func keyboardLayoutsJSON() -> String { "[]" }
    func keyboardSetSource(_ id: String) -> Bool { false }
    func keysSetRules(extensionID: String, json: String) {}
    func keysStroke(_ spec: String) {}
    func keysSystem(_ name: String) {}
    func urlOpen(_ url: String, bundleID: String?) -> Bool { false }
    func urlDefaultBrowser() -> String { "" }
    func urlSetDefaultBrowser(_ bundleID: String) -> Bool { false }
    func fsExists(_ path: String) -> Bool { false }
    func fsAttributesJSON(_ path: String) -> String { "{}" }
    func fsWatch(extensionID: String, path: String, handler: String) {}
    func fsUnwatch(extensionID: String, path: String) {}
}

// MARK: - Test class

@MainActor
final class FallbackSearchLuaTests: XCTestCase {

    // MARK: - Helpers

    /// Isolated UserDefaults suite + store. UUID suffix guarantees no cross-test leakage.
    private func makeStore() -> FallbackSearchStore {
        let suiteName = "fallback-lua-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        // Seed an empty provider list so first-run defaults don't pollute assertions.
        let store = FallbackSearchStore(defaults: defaults)
        store.providers = []
        return store
    }

    /// Returns the URL of the fallback-search init.lua inside the bundle sources.
    private func luaURL() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()           // ProsperAppTests/
            .deletingLastPathComponent()           // Tests/
            .deletingLastPathComponent()           // app/
            .appendingPathComponent(
                "Sources/ProsperApp/Resources/extensions/fallback-search/init.lua",
                isDirectory: false
            )
        try XCTSkipIf(!FileManager.default.fileExists(atPath: url.path),
                      "fallback-search/init.lua not found — skipping Lua round-trip tests")
        return url
    }

    /// Set up a LuaRuntime with init.lua loaded and host.fallback wired to `store`.
    /// Runs off the main thread because `callGlobal` blocks its thread.
    private func makeRuntime(store: FallbackSearchStore) throws -> (LuaRuntime, URL) {
        let url = try luaURL()
        let svc = FallbackAwareFakeServices(store: store)
        let lua = try LuaRuntime()
        // privileged: true activates the real host.fallback.* surface (system-only gate).
        try ExtensionHost(extensionID: "com.prosper.fallback-search",
                          services: svc,
                          privileged: true,
                          trusted: true).install(into: lua)
        let source = try String(contentsOf: url, encoding: .utf8)
        try lua.run(source)
        return (lua, url)
    }

    /// Run `body` on a background thread and propagate any thrown error as an XCTFail.
    private func offMain(timeout: TimeInterval = 10, _ body: @escaping () throws -> Void) {
        let exp = expectation(description: "offMain")
        var thrown: Error?
        DispatchQueue.global().async {
            do { try body() } catch { thrown = error }
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        if let thrown { XCTFail("threw: \(thrown)") }
    }

    // MARK: - Tests

    /// settings_render returns a non-nil JSON string (valid UI payload) without Lua error.
    func testSettingsRenderReturnsUIPayload() throws {
        let store = makeStore()
        offMain {
            let (lua, _) = try self.makeRuntime(store: store)
            let result: String? = try lua.callGlobal("settings_render", ["mode", "{}"])
            XCTAssertNotNil(result, "settings_render must return a non-nil UI payload")
            if let json = result {
                // Minimal sanity: the returned string must be valid JSON with a "title" key.
                let data = Data(json.utf8)
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertNotNil(obj?["title"], "UI payload must contain a 'title' key")
            }
        }
    }

    /// record.save:providers: action persists a new provider through the real store.
    func testSaveProviderActionPersistsToStore() throws {
        let store = makeStore()
        offMain {
            let (lua, _) = try self.makeRuntime(store: store)
            let formJSON = #"{"name":"DuckDuckGo","urlTemplate":"https://duckduckgo.com/?q={query}","enabled":"true"}"#
            let result: String? = try lua.callGlobal(
                "settings_action",
                ["providers", "record.save:providers:", "", formJSON]
            )
            // The action must return a fresh settings_render payload (non-nil).
            XCTAssertNotNil(result, "settings_action must return a re-render payload")
        }
        // Verify the store was mutated on the main actor after the off-main call.
        let ids = store.providers.map { $0.id }
        XCTAssertTrue(ids.contains("duckduckgo"), "provider 'duckduckgo' must be persisted; got \(ids)")
    }

    /// set:append_mode action toggles appendMode through the real store.
    func testToggleAppendModeFlipsStore() throws {
        let store = makeStore()
        store.appendMode = true    // start in append mode

        offMain {
            let (lua, _) = try self.makeRuntime(store: store)
            // Toggle off
            _ = try lua.callGlobal("settings_action",
                                   ["mode", "set:append_mode", "false", "{}"])
        }
        XCTAssertFalse(store.appendMode, "appendMode must be false after set:append_mode false")

        offMain {
            let (lua, _) = try self.makeRuntime(store: store)
            // Toggle back on
            _ = try lua.callGlobal("settings_action",
                                   ["mode", "set:append_mode", "true", "{}"])
        }
        XCTAssertTrue(store.appendMode, "appendMode must be true after set:append_mode true")
    }

    /// REGRESSION: delete-last provider must leave the store EMPTY, not revert.
    ///
    /// The bug: an empty Lua table encodes as `{}` (JSON object), not `[]`.
    /// The native JSONDecoder rejected `{}` as `[FallbackProvider]`, so the delete
    /// silently no-oped and the last provider reappeared. The fix in init.lua
    /// force-sends `"[]"` when the kept table is empty; this test guards that fix.
    func testDeleteLastProviderLeavesStoreEmpty() throws {
        let store = makeStore()

        // Seed exactly one provider so there is a last one to delete.
        store.providers = [
            FallbackProvider(id: "google", name: "Google",
                             urlTemplate: "https://www.google.com/search?q={query}",
                             enabled: true, titleTemplate: nil)
        ]

        offMain {
            let (lua, _) = try self.makeRuntime(store: store)
            _ = try lua.callGlobal("settings_action",
                                   ["providers", "record.delete:providers:google", "", "{}"])
        }

        XCTAssertTrue(
            store.providers.isEmpty,
            "store must be EMPTY after deleting the last provider; got \(store.providers.map { $0.id })"
        )
    }
}
