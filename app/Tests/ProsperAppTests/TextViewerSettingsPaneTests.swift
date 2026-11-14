import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import ProsperApp

/// #1134 round 3 (QA 871 F1): the Default App section is on the Text Viewer's Settings page, built through
/// ExtensionSettingsPane itself, and only there. Every row runs against `FakeDefaultApps` and never presses
/// the button; no row builds `WorkspaceDefaultApps` or changes a default handler on this Mac.
@MainActor
final class TextViewerSettingsPaneTests: XCTestCase {

    /// Reads answer nil; a set is only recorded (no row presses the button, so none is expected).
    private final class FakeDefaultApps: DefaultAppHandlers {
        private(set) var sets = 0
        func defaultApp(for type: UTType) -> URL? { nil }
        func setDefault(_ app: URL, for type: UTType, done: @escaping @Sendable (Error?) -> Void) { sets += 1 }
    }

    /// Host services that do nothing: the static section's prefValue reads go here (nil), not to any defaults.
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

    /// The Text Viewer manifest's info row: the pane has rendered its own sections once this is in the tree.
    private static let infoTitle = "Open Markdown and text files from Finder's Open With menu"
    private static let otherID = "com.prosper.pasteplain"

    /// Puts a fake behind the seam for the rest of the row (under XCTest the seam is nil otherwise).
    private func install() -> FakeDefaultApps {
        XCTAssertTrue(TextViewerDefaultApp.handlers == nil, "the real seam is never built under XCTest")
        let fake = FakeDefaultApps()
        TextViewerDefaultApp.handlers = fake
        addTeardownBlock { @MainActor in TextViewerDefaultApp.handlers = nil }
        return fake
    }

    private func extensionsDir() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    /// The bundled extensions, a temp user folder and scratch defaults: never the operator's own.
    private func registry(_ label: String) -> ExtensionRegistry {
        let r = ExtensionRegistry(systemDir: extensionsDir(), userDir: tempDir(label),
                                  defaults: scratchDefaults(label), services: InertServices())
        r.discover()
        return r
    }

    private struct AXItem { let role: String, label: String, title: String, value: String }

    private func axWalk(_ e: Any, _ out: inout [AXItem], depth: Int = 0) {
        guard depth < 60, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        out.append(AXItem(role: text("accessibilityRole"), label: text("accessibilityLabel"),
                          title: text("accessibilityTitle"), value: text("accessibilityValue")))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { axWalk(k, &out, depth: depth + 1) }
    }

    private static func has(_ items: [AXItem], _ s: String) -> Bool {
        items.contains { $0.label == s || $0.title == s || $0.value == s }
    }

    private static func hasButton(_ items: [AXItem]) -> Bool {
        items.contains { $0.role == "AXButton" && ($0.label == TextViewerDefaultAppSection.buttonTitle
                                                   || $0.title == TextViewerDefaultAppSection.buttonTitle) }
    }

    /// The pane hosted in a never-shown window, tall enough that the lazy column builds its footer;
    /// the tree once `ready` holds (or after 5 s). SwiftUI builds it once this process (only) is asked to.
    private func tree(_ pane: ExtensionSettingsPane, ready: ([AXItem]) -> Bool) -> [AXItem] {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        let host = NSHostingView(rootView: pane.frame(width: 600, height: 1600))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 1600)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        defer { win.close() }
        for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
        var items: [AXItem] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            items = []
            axWalk(host, &items)
        } while !ready(items) && Date() < deadline
        XCTAssertFalse(win.isVisible, "never shown")
        return items
    }

    private func textViewerPage(_ r: ExtensionRegistry) throws -> (ExtensionRecord, SettingsSection) {
        try XCTUnwrap(r.settingsSection(extensionID: TextViewerDefaultApp.extensionID, sectionID: "textviewer"))
    }

    /// Row 1: the Text Viewer's own page, built as SettingsWindow builds it (no caller footer), shows the
    /// Default App section's button. Opening the page sets nothing.
    func testTextViewerPageShowsTheDefaultAppButton() throws {
        let fake = install()
        let r = registry("tvpane-own")
        let (record, section) = try textViewerPage(r)
        let items = tree(ExtensionSettingsPane(registry: r, record: record, section: section),
                         ready: { Self.has($0, Self.infoTitle) && Self.hasButton($0) })
        XCTAssertTrue(Self.has(items, Self.infoTitle), "the manifest's own row rendered")
        XCTAssertTrue(Self.hasButton(items), "the Default App section is on the Text Viewer page")
        XCTAssertEqual(fake.sets, 0, "showing the page sets nothing")
    }

    /// Row 2: the same section under another extension's record: the page renders, the button is not on it.
    /// It waits the full 5 s bound by design: the page has no mark of an empty footer slot, and an absence
    /// needs a bound (a long one can only make the row pass late, never wrongly).
    func testAnotherExtensionsPageHasNoDefaultAppButton() throws {
        let fake = install()
        let r = registry("tvpane-other")
        let (_, section) = try textViewerPage(r)
        let other = try XCTUnwrap(r.record(id: Self.otherID))
        let items = tree(ExtensionSettingsPane(registry: r, record: other, section: section),
                         ready: { Self.has($0, Self.infoTitle) && Self.hasButton($0) })
        XCTAssertTrue(Self.has(items, Self.infoTitle), "the page rendered before absence is read")
        XCTAssertFalse(Self.hasButton(items), "no Default App section for \(Self.otherID)")
        XCTAssertEqual(fake.sets, 0)
    }

    /// Row 3: a caller's own footer wins over the Text Viewer's (pageFooter is `footer ?? …`).
    func testACallersFooterWins() throws {
        let fake = install()
        let r = registry("tvpane-caller")
        let (record, section) = try textViewerPage(r)
        let mine = "Caller footer"
        let items = tree(ExtensionSettingsPane(registry: r, record: record, section: section,
                                               footer: AnyView(Text(mine))),
                         ready: { Self.has($0, Self.infoTitle) && Self.has($0, mine) })
        XCTAssertTrue(Self.has(items, Self.infoTitle))
        XCTAssertTrue(Self.has(items, mine), "the caller's footer is on the page")
        XCTAssertFalse(Self.hasButton(items), "and the Text Viewer's is not")
        XCTAssertEqual(fake.sets, 0)
    }
}
