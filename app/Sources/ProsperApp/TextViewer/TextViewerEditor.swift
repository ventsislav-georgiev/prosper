import AppKit
import SwiftUI

// #1544 (#1108 P3d, design #1105 D11): the built-in editor. The model's buffer, dirty state, save and close live in
// TextViewerModel; here are the view, the close sheet and the save's failure texts.

@MainActor
enum TextViewerEditor {
    enum CloseAnswer: Equatable { case save, discard, cancel }

    /// D11: the decoded source in the Read view's subclass, editable and plain, monospaced at the UI scale. Every
    /// substitution is off so the file's bytes are kept; undo is on (the window's undo manager: the Edit menu reaches it).
    static func makeEditor(_ text: String) -> (NSScrollView, TextViewerTextView) {
        let (scroll, view) = TextViewerTextView.makeScrollable()
        view.isEditable = true
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.string = text
        let font = NSFont.monospacedSystemFont(ofSize: 13 * ThemeRuntime.scale, weight: .regular)
        let color = NSColor(Neon.textPrimary)
        view.font = font
        view.textColor = color
        view.insertionPointColor = color
        view.typingAttributes = [.font: font, .foregroundColor: color]
        return (scroll, view)
    }

    /// "Save changes to <name>?" as a sheet on the window. Under XCTest, or with no window, it shows nothing and answers
    /// Cancel: the window stays.
    static func liveCloseSheet(_ window: NSWindow?, _ name: String, _ answer: @escaping @MainActor (CloseAnswer) -> Void) {
        guard NSClassFromString("XCTestCase") == nil, let window else { return answer(.cancel) }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(name)?"
        alert.informativeText = "Your changes are lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                answer(response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .discard : .cancel)
            }
        }
    }

    /// #1545 (D12): after Keep Mine, "Overwrite the newer file on disk?" as a sheet. Under XCTest, or with no window, it
    /// shows nothing and answers no: nothing is written.
    static func liveOverwriteSheet(_ window: NSWindow?, _ name: String, _ answer: @escaping @MainActor (Bool) -> Void) {
        guard NSClassFromString("XCTestCase") == nil, let window else { return answer(false) }
        let alert = NSAlert()
        alert.messageText = "Overwrite the newer file on disk?"
        alert.informativeText = "\(name) changed on disk after you opened it. Saving replaces that version with yours."
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { answer(response == .alertFirstButtonReturn) }
        }
    }

    /// D12's banner texts.
    nonisolated static func banner(_ change: TextViewerModel.DiskChange) -> String {
        switch change {
        case .changed: "Changed on disk"
        case .deleted: "Deleted on disk"
        }
    }

    /// What the window says when a save fails (D11: shown inline; the buffer stays dirty).
    nonisolated static func message(_ failure: TextFileWriter.Failure) -> String {
        switch failure {
        case .lossy: "Not saved: not UTF-8, shown read-only"
        case .notRegular: "Not saved: this is no longer a regular file"
        case .changedOnDisk: "Not saved: the file changed on disk since it was opened"
        case .swapped: "Not saved: the file was replaced while saving"
        case .locked: "Not saved: the file is locked"
        case .retargeted: "Not saved: the link now points at another file"
        case .failed(_, let code): "Not saved: \(String(cString: strerror(code)))"
        case .incomplete(_, let code): "Save failed partway, the file may be incomplete: \(String(cString: strerror(code)))"
        }
    }
}

/// The Edit pane: the model's editor view, made once and kept with the buffer (Read and back keeps its undo history).
struct TextViewerEditorRepresentable: NSViewRepresentable {
    let model: TextViewerModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = model.makeEditor()
        model.textView = model.editorView   // ⌘F, ⌘G and ⌘E reach the editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}
