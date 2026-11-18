import AppKit

/// #1108 P3c: the Text Viewer windows with unsaved edits, which hold Quit and an unattended update.
/// The viewers report here from P3d (#1544); until then nothing does, so Quit and updates go on at once (R6).
@MainActor
final class TextViewerDirty {
    static let shared = TextViewerDirty()
    /// R6: what a dirty window says, once, while an update waits on it.
    static let updateWaiting = "An update is waiting: save or close this file"

    /// The dirty viewers, each with how it shows a notice. A viewer reports clean before it goes away.
    private var owners: [ObjectIdentifier: @MainActor (String) -> Void] = [:]
    /// Sparkle's install replies held while a viewer is dirty.
    private var held: [@MainActor () -> Void] = []
    var isDirty: Bool { !owners.isEmpty }

    /// Quit's prompt while a viewer is dirty: the count, then true to quit without saving, false to cancel.
    /// Tests hand in a fake; under XCTest the live one cancels and shows nothing.
    var prompt: @MainActor (Int, @escaping @MainActor (Bool) -> Void) -> Void = TextViewerDirty.livePrompt

    func report(_ owner: AnyObject, dirty: Bool, say: @escaping @MainActor (String) -> Void = { _ in }) {
        let id = ObjectIdentifier(owner)
        if dirty {
            if owners.updateValue(say, forKey: id) == nil, !held.isEmpty { say(Self.updateWaiting) }
            return
        }
        guard owners.removeValue(forKey: id) != nil, owners.isEmpty, !held.isEmpty else { return }
        let run = held
        held = []
        run.forEach { $0() }
    }

    /// AppUpdater.showReady: installs now when clean, else once when the last dirty viewer goes clean.
    func holdUpdate(_ install: @escaping @MainActor () -> Void) {
        guard isDirty else { return install() }
        held.append(install)
        if held.count == 1 { owners.values.forEach { $0(Self.updateWaiting) } }
    }

    /// AppDelegate.applicationShouldTerminate. R6: nothing dirty → `.terminateNow` at once. Dirty → `.terminateLater`,
    /// and the prompt's answer replies (Cancel → `.terminateCancel`). Edit sessions end only on a quit that goes on.
    func terminateReply(endSessions: @escaping @MainActor () -> Void,
                        reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard isDirty else {
            endSessions()
            return .terminateNow
        }
        prompt(owners.count) { quit in
            if quit { endSessions() }
            reply(quit)
        }
        return .terminateLater
    }

    /// After `.terminateLater` is returned: one alert on the next main turn. Never shown under XCTest.
    static func livePrompt(_ count: Int, _ answer: @escaping @MainActor (Bool) -> Void) {
        guard NSClassFromString("XCTestCase") == nil else { return answer(false) }
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = count == 1 ? "A Text Viewer file has unsaved changes"
                : "\(count) Text Viewer files have unsaved changes"
            alert.informativeText = "Quit anyway and lose them, or cancel and save first."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Without Saving")
            NSApp.activate(ignoringOtherApps: true)
            answer(alert.runModal() == .alertSecondButtonReturn)
        }
    }
}
