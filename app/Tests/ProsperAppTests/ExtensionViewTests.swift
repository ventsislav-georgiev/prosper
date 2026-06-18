import XCTest
import LuaRuntime
@testable import ProsperApp

/// Verifies the declarative-UI contract (ADR-002 §D7): Lua builds a component
/// tree, `host.ui.render` encodes it to JSON, and the host decodes it back into
/// native view models — plus the action handler round-trip and form payload.
private final class NoopUIServices: ExtensionHostServices, @unchecked Sendable {
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
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
}

final class ExtensionViewTests: XCTestCase {

    func testDecodeListFromRawJSON() throws {
        let json = """
        {"type":"list","title":"Snippets","searchable":true,
         "items":[{"id":"a","title":"Alpha","subtitle":"first","actions":[{"id":"copy","title":"Copy","value":"A"}]},
                  {"id":"b","title":"Beta"}]}
        """
        let node = try ExtensionViewNode.decode(json: json)
        guard case .list(let list) = node else { return XCTFail("expected list") }
        XCTAssertEqual(list.title, "Snippets")
        XCTAssertTrue(list.isSearchable)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[0].allActions.first?.value, "A")
        XCTAssertEqual(node.title, "Snippets")
    }

    func testDecodeListItemImageAndLaunch() throws {
        // The `open` system extension emits items with `image` (Finder icon path)
        // and `launch` (app bundle path opened natively on Enter). Both are
        // optional and absent for ordinary text items (e.g. translate candidates).
        let json = """
        {"type":"list","title":"Open App",
         "items":[{"id":"0","title":"Safari","image":"/Applications/Safari.app","launch":"/Applications/Safari.app"},
                  {"id":"1","title":"plain"}]}
        """
        let node = try ExtensionViewNode.decode(json: json)
        guard case .list(let list) = node else { return XCTFail("expected list") }
        XCTAssertEqual(list.items[0].image, "/Applications/Safari.app")
        XCTAssertEqual(list.items[0].launch, "/Applications/Safari.app")
        XCTAssertNil(list.items[1].image)
        XCTAssertNil(list.items[1].launch)
    }

    func testDecodeFormAndGridAndDetail() throws {
        XCTAssertNoThrow(try ExtensionViewNode.decode(json:
            ##"{"type":"detail","title":"Doc","markdown":"# Hi"}"##))
        XCTAssertNoThrow(try ExtensionViewNode.decode(json:
            #"{"type":"grid","columns":4,"items":[{"id":"x","title":"X"}]}"#))
        let form = try ExtensionViewNode.decode(json:
            #"{"type":"form","fields":[{"id":"name","label":"Name","kind":"text","value":"Bob"}],"actions":[{"id":"ok","title":"OK"}]}"#)
        guard case .form(let f) = form else { return XCTFail("expected form") }
        XCTAssertEqual(f.fields.first?.kind, .text)
        XCTAssertEqual(f.fields.first?.defaultValue, "Bob")
    }

    func testRejectsUnknownComponent() {
        XCTAssertThrowsError(try ExtensionViewNode.decode(json: #"{"type":"webview"}"#))
    }

    func testDecodeLoadingIndeterminateAndProgressive() throws {
        // Indeterminate (infinite) spinner: no progress field.
        let spin = try ExtensionViewNode.decode(json:
            #"{"type":"loading","title":"Fetching","subtitle":"one sec"}"#)
        guard case .loading(let s) = spin else { return XCTFail("expected loading") }
        XCTAssertNil(s.clampedProgress)
        XCTAssertEqual(s.title, "Fetching")

        // Progressive (determinate) bar, clamped to 0…1.
        let bar = try ExtensionViewNode.decode(json:
            #"{"type":"loading","title":"Downloading","progress":1.4}"#)
        guard case .loading(let b) = bar else { return XCTFail("expected loading") }
        XCTAssertEqual(b.clampedProgress, 1.0)
    }

    func testSpinnerHelperAndLuaLoadingBuilder() throws {
        // Host-built spinner convenience.
        guard case .loading(let s) = ExtensionViewNode.spinner("Wait", subtitle: "…") else {
            return XCTFail("expected loading")
        }
        XCTAssertNil(s.clampedProgress)
        XCTAssertEqual(s.subtitle, "…")

        // Lua host.ui.loading builder round-trips through host.json.
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test.ui", services: NoopUIServices()).install(into: lua)
        try lua.run("""
        function show() return host.ui.render(host.ui.loading{ title = "Loading", progress = 0.5 }) end
        """)
        let json = try XCTUnwrap(try lua.callGlobal("show"))
        guard case .loading(let n) = try ExtensionViewNode.decode(json: json) else {
            return XCTFail("expected loading")
        }
        XCTAssertEqual(n.clampedProgress, 0.5)
        XCTAssertEqual(n.title, "Loading")
    }

    /// End-to-end: Lua handler builds a tree with host.ui builders, encodes via
    /// host.json, host decodes it.
    func testLuaBuiltViewDecodes() throws {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test.ui", services: NoopUIServices()).install(into: lua)
        try lua.run("""
        function show()
            return host.ui.render(host.ui.list{
                title = "Items",
                searchable = true,
                items = {
                    { id = "1", title = "One", actions = { { id = "open", title = "Open", value = "1" } } },
                    { id = "2", title = "Two" },
                }
            })
        end
        """)
        let json = try XCTUnwrap(try lua.callGlobal("show"))
        let node = try ExtensionViewNode.decode(json: json)
        guard case .list(let list) = node else { return XCTFail("expected list") }
        XCTAssertEqual(list.title, "Items")
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[0].allActions.first?.id, "open")
    }

    /// host.json decode handles the form payload an action handler receives.
    func testLuaJSONRoundTrip() throws {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test.ui", services: NoopUIServices()).install(into: lua)
        try lua.run("""
        function probe()
            local decoded = host.json.decode('{"name":"Bob","count":3,"on":true}')
            return decoded.name .. "/" .. tostring(decoded.count) .. "/" .. tostring(decoded.on)
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "Bob/3/true")
    }
}
