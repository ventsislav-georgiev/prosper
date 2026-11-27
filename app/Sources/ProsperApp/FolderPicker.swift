import AppKit

/// #2008: one folder from a non-modal chooser (the island's openFolderPanel shape), for a Settings pane whose own folder
/// may not show modal UI. Never shown under XCTest: `done(nil)` there; tests set their pane's seam instead.
enum FolderPicker {
    @MainActor
    static func choose(message: String, _ done: @escaping @MainActor (URL?) -> Void) {
        guard NSClassFromString("XCTestCase") == nil else { return done(nil) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // a CODEX_HOME is often a dot folder
        panel.message = message
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { resp in
            MainActor.assumeIsolated { done(resp == .OK ? panel.url : nil) }
        }
    }
}
