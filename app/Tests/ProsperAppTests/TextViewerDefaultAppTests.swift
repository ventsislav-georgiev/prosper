import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import ProsperApp

/// #1134: the Text Viewer's "Make Prosper the Default" control. Every row runs against `FakeDefaultApps`;
/// no row builds `WorkspaceDefaultApps` or changes a default handler on this Mac.
@MainActor
final class TextViewerDefaultAppTests: XCTestCase {

    /// Records every call; answers the setter only when a row says so, from a background queue.
    private final class FakeDefaultApps: DefaultAppHandlers {
        var holders: [String: URL] = [:]
        private(set) var reads = 0
        private(set) var sets: [(app: URL, type: String)] = []
        private var waiting: [(type: String, done: @Sendable (Error?) -> Void)] = []

        func defaultApp(for type: UTType) -> URL? { reads += 1; return holders[type.identifier] }
        func setDefault(_ app: URL, for type: UTType, done: @escaping @Sendable (Error?) -> Void) {
            sets.append((app, type.identifier))
            waiting.append((type.identifier, done))
        }

        /// Answers every waiting call off the main thread; `failing` types get a refusal.
        func answer(failing: Set<String> = []) {
            let calls = waiting
            waiting = []
            for call in calls {
                let fail = failing.contains(call.type), done = call.done
                DispatchQueue.global().async {
                    done(fail ? NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError,
                                        userInfo: [NSLocalizedDescriptionKey: "The change was declined."]) : nil)
                }
            }
        }
    }

    /// Host services that do nothing; only the registry's discovery and enable gate run.
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

    private static let txt = "public.plain-text", md = "net.daringfireball.markdown"
    private static let textEdit = URL(fileURLWithPath: "/Applications/TextEdit.app")

    /// Puts `fake` behind the seam for the rest of the row (under XCTest the seam is nil otherwise).
    private func install(_ fake: FakeDefaultApps) {
        XCTAssertTrue(TextViewerDefaultApp.handlers == nil, "the real seam is never built under XCTest")
        TextViewerDefaultApp.handlers = fake
        addTeardownBlock { @MainActor in TextViewerDefaultApp.handlers = nil }
    }

    private func waitUntil(_ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func extensionsDir() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    private func registry(_ label: String) -> ExtensionRegistry {
        let r = ExtensionRegistry(systemDir: extensionsDir(), userDir: tempDir(label),
                                  defaults: scratchDefaults(label), services: InertServices())
        r.discover()
        return r
    }

    // MARK: Nothing is set unless the button is pressed

    /// Loading the extensions (what launch does), turning the Text Viewer off and on again: no setter call.
    func testLoadAndActivationSetNothing() throws {
        let fake = FakeDefaultApps()
        install(fake)
        let r = registry("tvdefault-activate")
        XCTAssertTrue(try XCTUnwrap(r.record(id: TextViewerDefaultApp.extensionID)).isLive)
        try r.setEnabled(false, id: TextViewerDefaultApp.extensionID)
        try r.setEnabled(true, id: TextViewerDefaultApp.extensionID)
        XCTAssertEqual(fake.sets.count, 0, "activation never sets a default")
    }

    /// Opening a .md and a .txt through the router and the intake: no setter call.
    func testOpeningAFileSetsNothing() {
        let fake = FakeDefaultApps()
        install(fake)
        let intake = TextViewerIntake.shared
        let saved = (intake.isEnabled, intake.notifyOff, intake.show)
        defer { (intake.isEnabled, intake.notifyOff, intake.show) = saved }
        var shown: [String] = []
        intake.isEnabled = { true }
        intake.show = { shown.append($0.lastPathComponent) }
        intake.ready()
        TextViewerRouting.route([URL(fileURLWithPath: "/Users/example/notes.md"),
                                 URL(fileURLWithPath: "/Users/example/todo.txt")],
                                document: intake.receive, link: { _ in })
        XCTAssertEqual(shown, ["notes.md", "todo.txt"])
        XCTAssertEqual(fake.sets.count, 0, "opening a file never sets a default")
    }

    // MARK: The trigger

    /// The button sets exactly .txt then .md, each with the app's own bundle URL, once per press.
    func testTriggerSetsBothTypesWithTheAppsOwnBundleURL() {
        let fake = FakeDefaultApps()
        fake.holders = [Self.txt: Self.textEdit, Self.md: Self.textEdit]
        install(fake)
        let model = TextViewerDefaultApp()
        model.refresh()
        XCTAssertEqual(model.rows.map(\.holder), ["TextEdit", "TextEdit"])
        XCTAssertEqual(fake.sets.count, 0, "reading the state sets nothing")
        model.makeDefault()
        XCTAssertEqual(fake.sets.map { $0.type }, ["public.plain-text", "net.daringfireball.markdown"])
        XCTAssertEqual(Set(fake.sets.map { $0.app }), [Bundle.main.bundleURL])
        model.makeDefault()
        XCTAssertEqual(fake.sets.count, 2, "a second press while the system answers sets nothing more")
        fake.holders = [Self.txt: Bundle.main.bundleURL, Self.md: Bundle.main.bundleURL]
        fake.answer()
        waitUntil { model.pending == 0 }
        XCTAssertEqual(model.rows, [TextViewerDefaultApp.Row(label: "Text files (.txt)", holder: "Prosper is the default"),
                                    TextViewerDefaultApp.Row(label: "Markdown files (.md)", holder: "Prosper is the default")])
    }

    /// A refusal for Markdown is shown on the Markdown line only, the other type still applies, and both
    /// lines are read again after the answers.
    func testAFailureIsShownForItsTypeAndTheStateIsReRead() {
        let fake = FakeDefaultApps()
        fake.holders = [Self.txt: Self.textEdit, Self.md: Self.textEdit]
        install(fake)
        let model = TextViewerDefaultApp()
        model.refresh()
        let readsBefore = fake.reads
        model.makeDefault()
        fake.holders[Self.txt] = Bundle.main.bundleURL
        fake.answer(failing: [Self.md])
        waitUntil { model.pending == 0 }
        XCTAssertGreaterThan(fake.reads, readsBefore, "re-read after the answers")
        XCTAssertEqual(model.rows.first, TextViewerDefaultApp.Row(label: "Text files (.txt)", holder: "Prosper is the default"))
        XCTAssertEqual(model.rows.last, TextViewerDefaultApp.Row(label: "Markdown files (.md)", holder: "TextEdit",
                                              error: "Not changed: The change was declined."))
        XCTAssertEqual(model.rows.count, 2)
        // A later success clears the line's failure.
        model.makeDefault()
        fake.holders[Self.md] = Bundle.main.bundleURL
        fake.answer()
        waitUntil { model.pending == 0 }
        XCTAssertEqual(model.rows.last, TextViewerDefaultApp.Row(label: "Markdown files (.md)", holder: "Prosper is the default"))
    }

    /// The system's completion arrives off the main thread (FakeDefaultApps.answer uses a global queue):
    /// the model hops to the main actor itself instead of trapping.
    func testCompletionFromABackgroundQueueLandsOnMain() {
        let fake = FakeDefaultApps()
        install(fake)
        let model = TextViewerDefaultApp()
        model.makeDefault()
        XCTAssertEqual(model.pending, 2)
        fake.answer()
        waitUntil { model.pending == 0 }
        XCTAssertEqual(model.pending, 0)
        XCTAssertEqual(model.rows.map(\.holder), ["No default app", "No default app"])
    }

    // MARK: The extension turned off

    /// With the Text Viewer off its Settings page is gone, and with it the control: the registry
    /// hands out no section for an extension that is not live. The control rides only on that page.
    func testControlIsAbsentWithTheExtensionOff() throws {
        let fake = FakeDefaultApps()
        install(fake)
        let r = registry("tvdefault-off")
        XCTAssertTrue(r.settingsSection(extensionID: TextViewerDefaultApp.extensionID, sectionID: "textviewer") != nil)
        try r.setEnabled(false, id: TextViewerDefaultApp.extensionID)
        XCTAssertTrue(r.settingsSection(extensionID: TextViewerDefaultApp.extensionID, sectionID: "textviewer") == nil)
        XCTAssertFalse(r.settingsSections(placement: "sidebar").contains { $0.record.id == TextViewerDefaultApp.extensionID })
        XCTAssertTrue(TextViewerDefaultAppSection.footer(forExtension: TextViewerDefaultApp.extensionID) != nil)
        XCTAssertTrue(TextViewerDefaultAppSection.footer(forExtension: "com.prosper.files") == nil)
        XCTAssertEqual(fake.sets.count, 0)
    }

    // MARK: Accessibility and fit, from the real accessibility tree of a never-shown window

    private struct AXItem { let role: String, label: String, title: String, frame: CGRect }

    private func axWalk(_ e: Any, _ out: inout [AXItem], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        let frame = o.responds(to: Selector(("accessibilityFrame")))
            ? (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero : .zero
        out.append(AXItem(role: text("accessibilityRole"), label: text("accessibilityLabel"),
                          title: text("accessibilityTitle"), frame: frame))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { axWalk(k, &out, depth: depth + 1) }
    }

    /// The section hosted at `width` in a never-shown window; the tree once `ready` holds (or after 5 s).
    /// SwiftUI builds it once this process (only) is asked to, as an AX client's attribute write would.
    private func tree(_ model: TextViewerDefaultApp, width: CGFloat,
                      ready: ([AXItem]) -> Bool) -> (items: [AXItem], window: CGRect) {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        let host = NSHostingView(rootView: TextViewerDefaultAppSection(model: model).frame(width: width))
        let size = CGSize(width: width, height: max(host.fittingSize.height, 200))
        host.frame = CGRect(origin: .zero, size: size)
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
        return (items, win.frame)
    }

    private static let lines = ["Text files (.txt), Prosper is the default",
                                "Markdown files (.md), TextEdit, Not changed: The change was declined."]
    private static func hasAll(_ items: [AXItem]) -> Bool {
        lines.allSatisfy { l in items.contains { $0.label == l } }
            && items.contains { $0.role == "AXButton" && ($0.label == TextViewerDefaultAppSection.buttonTitle
                                                         || $0.title == TextViewerDefaultAppSection.buttonTitle) }
    }

    /// A model in the state after a half-refused press: Prosper holds .txt, the .md line shows the refusal.
    private func refusedModel(_ fake: FakeDefaultApps) -> TextViewerDefaultApp {
        fake.holders = [Self.txt: Self.textEdit, Self.md: Self.textEdit]
        let model = TextViewerDefaultApp()
        model.makeDefault()
        fake.holders[Self.txt] = Bundle.main.bundleURL
        fake.answer(failing: [Self.md])
        waitUntil { model.pending == 0 }
        return model
    }

    /// VoiceOver reads each type's line as one element (type, holder, failure) and the button by name.
    /// Showing the page reads the state and sets nothing.
    func testControlAndStateLinesReadByVoiceOver() {
        let fake = FakeDefaultApps()
        install(fake)
        let model = refusedModel(fake)
        let setsBefore = fake.sets.count
        let (items, _) = tree(model, width: 549, ready: { Self.hasAll($0) })
        print("#1134 a11y tree:\n" + items.filter { !$0.label.isEmpty || !$0.title.isEmpty }
            .map { "  \($0.role) label=\($0.label) title=\($0.title)" }.joined(separator: "\n"))
        for line in Self.lines { XCTAssertTrue(items.contains { $0.label == line }, line) }
        XCTAssertTrue(items.contains { $0.role == "AXButton" && ($0.label == TextViewerDefaultAppSection.buttonTitle
                                                                 || $0.title == TextViewerDefaultAppSection.buttonTitle) })
        XCTAssertEqual(fake.sets.count, setsBefore, "showing the page sets nothing")
    }

    /// At UI scale 1.0, 0.85 and 0.7, in the narrowest Settings pane (window sz(820) less the sidebar
    /// sz(218), its rule and the scroll's 2 x sz(26)): the button keeps its natural width and every
    /// line stays inside the pane.
    func testNothingClipsAtEveryScale() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let fake = FakeDefaultApps()
        install(fake)
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            let model = refusedModel(fake)
            let width = sz(820) - sz(218) - 1 - 2 * sz(26)
            let (items, win) = tree(model, width: width, ready: { Self.hasAll($0) })
            let natural = NSHostingView(rootView: Button(TextViewerDefaultAppSection.buttonTitle) {}
                .buttonStyle(.neon).fixedSize()).fittingSize.width
            let button = items.first { $0.role == "AXButton" }
            // 1 pt: AX frames are whole points, the natural width is not (0.85: 153 against 154).
            XCTAssertGreaterThanOrEqual(button?.frame.width ?? 0, natural - 1, "scale \(scale): the button is not squeezed")
            for line in Self.lines {
                let f = items.first { $0.label == line }?.frame ?? .null
                XCTAssertTrue(!f.isNull && f.minX >= win.minX - 0.5 && f.maxX <= win.maxX + 0.5,
                              "scale \(scale): \(line) at \(f) inside \(win)")
            }
            if let b = button { XCTAssertLessThanOrEqual(b.frame.maxX, win.maxX + 0.5, "scale \(scale)") }
        }
    }
}
