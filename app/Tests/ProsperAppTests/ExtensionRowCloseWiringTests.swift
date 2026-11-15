import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// Inert host services: the registry here only installs into the row's own tempDir() and looks the folder up.
private final class InertServices: ExtensionHostServices, @unchecked Sendable {
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
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

/// #1182: the settings pane's real ExtensionRow closes its open publish list when its offer turns false, through
/// each of its own inputs (the record: untrusted, a system extension; the live version its fetch returns). The fetch
/// is a fake fed by the row (an AsyncStream, no network); the registry installs into the row's tempDir() only. Views
/// sit in never-shown windows; the accessibility flags go through AXTreeSupport; no event is posted. Also the install
/// refusals' names with unseen characters (#1182 item 3), as whole literal strings.
final class ExtensionRowCloseWiringTests: XCTestCase {

    // MARK: - The close wiring (item 1)

    @MainActor
    func testListClosesWhenTheRowIsUntrusted() throws {
        try assertList(closes: true, waitFor: "Trust") { box, _ in
            box.record = ExtensionRecord(loaded: box.record.loaded, enabled: false, trusted: false)
        }
    }

    @MainActor
    func testListClosesWhenTheRowBecomesASystemExtension() throws {
        try assertList(closes: true, waitFor: "Reset") { box, _ in
            let l = box.record.loaded
            box.record = ExtensionRecord(loaded: LoadedExtension(manifest: l.manifest, directory: l.directory, isSystem: true),
                                         enabled: false, trusted: true)
        }
    }

    /// The fetch returns the local version: it is live, the offer ends.
    @MainActor
    func testListClosesWhenTheLocalVersionIsLive() throws {
        try assertList(closes: true, waitFor: "Published v1.0.0") { _, live in live.yield("1.0.0") }
    }

    /// Control: an older live version keeps the offer (the title turns "Publish v1.0.0"), and a second update that
    /// keeps it (System Access granted) is drawn with the list still open.
    @MainActor
    func testListStaysOpenWhileTheRowStillOffersPublish() throws {
        try assertList(closes: false, waitFor: "Publish v1.0.0") { _, live in live.yield("0.9.0") }
    }

    // MARK: - Names in install refusals (item 3)

    /// A pipe-type refusal drops the bidi override, the control character and the line break from the name; a name
    /// with nothing left reads "an item".
    @MainActor
    func testNotFileRefusalShowsTheNameWithoutUnseenCharacters() {
        XCTAssertEqual(RemoteInstaller.notFileReason("a\u{202E}b\u{7}c\nd.lua", type: S_IFIFO),
                       "a named pipe, not a file or folder: abcd.lua")
        XCTAssertEqual(RemoteInstaller.notFileReason("\u{202E}\u{7}\n", type: S_IFSOCK),
                       "a socket, not a file or folder: an item")
    }

    /// The link refusal through the real lstat walk: a link inside the row's tempDir() to a file beside it.
    @MainActor
    func testLinkRefusalShowsTheNameWithoutUnseenCharacters() throws {
        let dir = tempDir()
        try Data("x".utf8).write(to: dir.appendingPathComponent("extension.toml"))
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("a\u{202E}b\u{7}c\nd.lua").path,
                                                   withDestinationPath: "extension.toml")
        XCTAssertThrowsError(try RemoteInstaller.assertNoSymlinks(dir)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .unsafeArchive("symlink: abcd.lua"))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "Refused to extract an unsafe archive: symlink: abcd.lua")
        }
    }

    // MARK: - Helpers

    /// Hosts ExtensionRow for a trusted user extension (local 1.0.0, never fetched yet), opens its list with the
    /// row's own Publish button, runs `change`, waits until `waitFor` is drawn, and checks the list closed or not.
    @MainActor
    private func assertList(closes: Bool, waitFor: String,
                            change: (RecordBox, AsyncStream<String?>.Continuation) -> Void) throws {
        let user = tempDir().appendingPathComponent("user")
        let source = user.deletingLastPathComponent().appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        [extension]
        id = "com.example.kit"
        name = "kit"
        title = "Kit"
        description = "A test extension"
        version = "1.0.0"
        author = "Example"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: source.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "function noop() end".write(to: source.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let registry = ExtensionRegistry(systemDir: nil, userDir: user, hostVersion: "2.0.0",
                                         defaults: scratchDefaults("closewiring"), services: InertServices())
        let installed = try registry.installLocal(from: source)
        let box = RecordBox(ExtensionRecord(loaded: installed.loaded, enabled: false, trusted: true))
        let (stream, live) = AsyncStream<String?>.makeStream()
        defer { live.finish() }
        // Runs where the row's task calls it (off the main actor); only the Sendable stream is captured.
        let fetch: @Sendable (String) async -> String? = { _ in
            for await v in stream { return v }
            return nil
        }
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (window, host) = AXTreeSupport.hosted(BoxedRow(box: box, registry: registry, fetch: fetch),
                                                  CGSize(width: 760, height: 400))
        defer { window.close() }

        let publish = try XCTUnwrap(wait(host) { $0.first { $0.isButton("Publish") } }, "no Publish button")
        XCTAssertTrue(press(publish.object))
        XCTAssertNotNil(wait(host) { $0.first { $0.isButton("Publish 2 files") } }, "the list did not open")

        change(box, live)
        let drawn = wait(host) { items in
            items.contains { $0.named(waitFor) } && (closes ? !items.contains { $0.isButton("Publish 2 files") } : true)
                ? items : nil
        }
        if closes {
            XCTAssertNotNil(drawn, "the list outlived the offer (\(waitFor) drawn: "
                            + "\(items(host).contains { $0.named(waitFor) }))")
        } else {
            XCTAssertNotNil(drawn, "\(waitFor) was not drawn")
            box.record = ExtensionRecord(loaded: box.record.loaded, enabled: false, trusted: true, privileged: true)
            let kept = wait(host) { items in items.contains { $0.isButton("Revoke System Access") } ? items : nil }
            XCTAssertNotNil(kept, "the second update was not drawn")
            XCTAssertTrue((kept ?? []).contains { $0.isButton("Publish 2 files") }, "the list closed while still offered")
        }
        XCTAssertFalse(window.isVisible, "never shown")
    }

    /// VoiceOver's press on an element of the never-shown window's tree (no event is posted).
    private func press(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        guard o.responds(to: sel) else { return false }
        if let p = o as? NSAccessibilityProtocol { return p.accessibilityPerformPress() }
        _ = o.perform(sel)
        return true
    }

    /// The tree as an AX client walks it, with each element's object (so a row can press a button).
    @MainActor
    private func items(_ host: NSView) -> [CloseWiringAXItem] {
        var out: [CloseWiringAXItem] = []
        func walk(_ e: Any, depth: Int) {
            guard depth < 60, let o = e as? NSObject else { return }
            func text(_ key: String) -> String {
                guard o.responds(to: Selector(key)) else { return "" }
                let v = o.value(forKey: key)
                return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
            }
            out.append(CloseWiringAXItem(object: o, role: text("accessibilityRole"),
                                         names: [text("accessibilityLabel"), text("accessibilityTitle"),
                                                 text("accessibilityValue")]))
            for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(k, depth: depth + 1) }
        }
        walk(host, depth: 0)
        return out
    }

    /// Lays out and reads the tree until `found` returns a value, or nil after 5 s (a ceiling, not a wait).
    @MainActor
    private func wait<T>(_ host: NSView, _ found: ([CloseWiringAXItem]) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let v = found(items(host)) { return v }
        } while Date() < deadline
        return nil
    }
}

private struct CloseWiringAXItem {
    let object: NSObject
    let role: String
    let names: [String]
    func named(_ n: String) -> Bool { names.contains(n) }
    func isButton(_ n: String) -> Bool { role == "AXButton" && named(n) }
}

/// The record the row is drawn with (main actor); a row swaps it to change the row's input.
@MainActor
private final class RecordBox: ObservableObject {
    @Published var record: ExtensionRecord
    init(_ record: ExtensionRecord) { self.record = record }
}

/// The real ExtensionRow, its record from `box`, its live version from the fake `fetch`.
private struct BoxedRow: View {
    @ObservedObject var box: RecordBox
    let registry: ExtensionRegistry
    let fetch: @Sendable (String) async -> String?
    var body: some View {
        ExtensionRow(registry: registry, record: box.record, fetchVersion: fetch)
            .frame(width: 760, alignment: .leading)
    }
}
