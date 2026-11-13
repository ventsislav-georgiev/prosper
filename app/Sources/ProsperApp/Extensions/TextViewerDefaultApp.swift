import AppKit
import SwiftUI
import UniformTypeIdentifiers

// #1134: the Text Viewer Settings section's "Make Prosper the Default" control. Only its button
// sets anything; installing, updating, launching, enabling the extension or opening a file never does.

/// The two LaunchServices calls, behind one seam so tests run against a fake.
@MainActor
protocol DefaultAppHandlers {
    func defaultApp(for type: UTType) -> URL?
    /// The system documents only that `done` runs asynchronously, not on which thread.
    func setDefault(_ app: URL, for type: UTType, done: @escaping @Sendable (Error?) -> Void)
}

/// The real conformance: it only forwards. No test constructs it.
struct WorkspaceDefaultApps: DefaultAppHandlers {
    func defaultApp(for type: UTType) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: type) }
    func setDefault(_ app: URL, for type: UTType, done: @escaping @Sendable (Error?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type, completion: done)
    }
}

/// Which app opens .txt and .md files, and the one action that makes it Prosper.
@MainActor
final class TextViewerDefaultApp: ObservableObject {
    static let extensionID = "com.prosper.textviewer"
    /// Under XCTest the real seam is never built: a test sets a fake; with none, nothing is read or set.
    static var handlers: (any DefaultAppHandlers)? = NSClassFromString("XCTestCase") == nil ? WorkspaceDefaultApps() : nil
    /// The types the button sets, in this order. .markdown files share the Markdown type.
    static let kinds: [(type: UTType, label: String)] = [
        (.plainText, "Text files (.txt)"),
        // macOS declares the Markdown type; importedAs only keeps the row on a Mac that does not.
        (UTType(TextViewerRouting.markdownTypeID) ?? UTType(importedAs: TextViewerRouting.markdownTypeID), "Markdown files (.md)"),
    ]

    struct Row: Equatable {
        let label: String
        var holder = ""
        var error: String?
    }

    static let isProsper = "Prosper is the default"

    @Published private(set) var rows: [Row]
    /// Setter calls whose completion has not come back yet; the button is off meanwhile.
    @Published private(set) var pending = 0
    let appURL: URL

    init(appURL: URL = Bundle.main.bundleURL) {
        self.appURL = appURL
        rows = Self.kinds.map { Row(label: $0.label) }
    }

    /// Reads only. The Settings page calls it when it appears and after every answer.
    func refresh() {
        guard let handlers = Self.handlers else { return }
        for (i, kind) in Self.kinds.enumerated() {
            rows[i].holder = holderName(handlers.defaultApp(for: kind.type))
        }
    }

    /// The button's action: one setter call per type, with this app's own bundle URL.
    func makeDefault() {
        guard let handlers = Self.handlers, pending == 0 else { return }
        pending = Self.kinds.count
        for (i, kind) in Self.kinds.enumerated() {
            handlers.setDefault(appURL, for: kind.type) { error in
                let text = error?.localizedDescription
                Task { @MainActor in self.finish(i, error: text) }
            }
        }
    }

    private func finish(_ i: Int, error: String?) {
        rows[i].error = error.map { "Not changed: \($0)" }
        pending = max(0, pending - 1)
        refresh()
    }

    func holderName(_ url: URL?) -> String {
        guard let url else { return "No default app" }
        if url.standardizedFileURL == appURL.standardizedFileURL { return Self.isProsper }
        return url.deletingPathExtension().lastPathComponent
    }
}

/// The native part of the Text Viewer Settings page, below the manifest's info row.
struct TextViewerDefaultAppSection: View {
    @StateObject private var model: TextViewerDefaultApp

    init(model: @autoclosure @escaping () -> TextViewerDefaultApp = TextViewerDefaultApp()) {
        _model = StateObject(wrappedValue: model())
    }

    static let buttonTitle = "Make Prosper the Default"
    static let explanation = "Nothing changes until you click the button. Then .txt, .md and .markdown files open in Prosper when you double-click them. Other plain-text files that have no app of their own, such as some .log, .csv, script or source files, may open in Prosper too. macOS may ask you to confirm. To change it back, select a file in Finder, choose File \u{203A} Get Info, pick an app under Open With and click Change All. If you turn the Text Viewer off, these files still open in Prosper, which then only shows a notice."

    /// The page footer ExtensionSettingsPane adds for the Text Viewer, and only for it.
    static func footer(forExtension id: String) -> AnyView? {
        id == TextViewerDefaultApp.extensionID ? AnyView(TextViewerDefaultAppSection()) : nil
    }

    /// What VoiceOver reads for one type's line.
    static func spoken(_ row: TextViewerDefaultApp.Row) -> String {
        ([row.label, row.holder] + (row.error.map { [$0] } ?? [])).joined(separator: ", ")
    }

    var body: some View {
        NeonSection("Default App", footer: Self.explanation) {
            ForEach(Array(model.rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { NeonDivider() }
                NeonRow(row.label, subtitle: row.error) {
                    Text(row.holder)
                        .font(Neon.font(.caption))
                        .foregroundStyle(row.holder == TextViewerDefaultApp.isProsper ? Neon.blue : Neon.textSecondary)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(row))
            }
            NeonDivider()
            HStack {
                Button(Self.buttonTitle) { model.makeDefault() }
                    .buttonStyle(.neon)
                    .fixedSize()
                    .disabled(model.pending > 0)
                Spacer(minLength: 0)
            }
        }
        .onAppear { model.refresh() }
    }
}
