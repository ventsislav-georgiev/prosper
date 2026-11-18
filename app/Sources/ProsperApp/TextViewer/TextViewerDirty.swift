import AppKit

/// #1108 P3c: the Text Viewer windows with unsaved edits, which hold Quit and an unattended update.
/// Each window's model reports here (#1544, TextViewerModel.setDirty), and so does each live terminal edit session (#1599);
/// with none dirty, Quit and updates go on at once (R6).
@MainActor
final class TextViewerDirty {
    static let shared = TextViewerDirty()
    /// R6: what a dirty window says, once, while an update waits on it.
    static let updateWaiting = "An update is waiting: save or close this file"
    /// #1604: what the menu's version row and the About pane say while an update is held.
    static let updateHeld = "Update waits on an open editor"

    /// The dirty viewers, each with how it shows a notice and whether it is a terminal edit session (#1604: its
    /// buffer is not seen). A viewer reports clean before it goes away.
    private var owners: [ObjectIdentifier: (say: @MainActor (String) -> Void, session: Bool)] = [:]
    /// Sparkle's install replies held while a viewer is dirty.
    private var held: [@MainActor () -> Void] = []
    var isDirty: Bool { !owners.isEmpty }
    /// #1604: an update waits on a dirty viewer.
    var isHoldingUpdate: Bool { !held.isEmpty }

    /// Quit's prompt while a viewer is dirty: the dirty files, the live terminal edit sessions, then true to quit without
    /// saving, false to cancel. Tests hand in a fake; under XCTest the live one cancels and shows nothing.
    var prompt: @MainActor (Int, Int, @escaping @MainActor (Bool) -> Void) -> Void = TextViewerDirty.livePrompt

    func report(_ owner: AnyObject, dirty: Bool, say: @escaping @MainActor (String) -> Void = { _ in }) {
        let id = ObjectIdentifier(owner)
        if dirty {
            if owners.updateValue((say, owner is TextViewerTerminalEdit), forKey: id) == nil, !held.isEmpty { say(Self.updateWaiting) }
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
        if held.count == 1 { owners.values.forEach { $0.say(Self.updateWaiting) } }
    }

    /// AppDelegate.applicationShouldTerminate. R6: nothing dirty → `.terminateNow` at once. Dirty → `.terminateLater`,
    /// and the prompt's answer replies (Cancel → `.terminateCancel`). Edit sessions end only on a quit that goes on.
    func terminateReply(endSessions: @escaping @MainActor () -> Void,
                        reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard isDirty else {
            endSessions()
            return .terminateNow
        }
        let sessions = owners.values.filter(\.session).count
        prompt(owners.count - sessions, sessions) { [self] quit in
            if quit {
                held = []   // #1599: an ended session reports clean; a held install must not fire into this quit
                endSessions()
            }
            reply(quit)
        }
        return .terminateLater
    }

    /// #1604: the alert's title and text. A terminal edit session is an open editor, never "unsaved changes": Prosper
    /// cannot see its buffer. The built-in editor's dirty files keep "unsaved changes".
    static func promptText(files: Int, sessions: Int) -> (message: String, info: String) {
        let unsaved = files == 1 ? "A Text Viewer file has unsaved changes" : "\(files) Text Viewer files have unsaved changes"
        if sessions == 0 { return (unsaved, "Quit anyway and lose them, or cancel and save first.") }
        let info = "Quit anyway and the open editor closes, losing what it has not saved; or cancel and save first."
        if files == 0 {
            return (sessions == 1 ? "A Text Viewer file is open in an editor" : "\(sessions) Text Viewer files are open in an editor", info)
        }
        return (unsaved + (sessions == 1 ? ", and another is open in an editor" : ", and \(sessions) more are open in an editor"), info)
    }

    /// After `.terminateLater` is returned: one alert on the next main turn. Never shown under XCTest.
    static func livePrompt(_ files: Int, _ sessions: Int, _ answer: @escaping @MainActor (Bool) -> Void) {
        guard NSClassFromString("XCTestCase") == nil else { return answer(false) }
        Task { @MainActor in
            let alert = NSAlert()
            (alert.messageText, alert.informativeText) = promptText(files: files, sessions: sessions)
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Without Saving")
            NSApp.activate(ignoringOtherApps: true)
            answer(alert.runModal() == .alertSecondButtonReturn)
        }
    }
}
