// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reimplementation of the Finder cut-and-paste-move feature from vorssaint-utils
// (github.com/vorssaint/vorssaint-utils, GPL-3.0),
// `Sources/Vorssaint/Services/Finder/FinderCutPaste.swift` — the idea, the
// AppleScript selection/insertion-location bridge and the mark-then-move model
// are theirs. No line is carried over: upstream owns an event tap, a copy
// engine, a progress panel and a synthetic-keystroke re-post dance, none of
// which exist here. Prosper rides its one shared tap, decides the swallow
// synchronously, and hands the move itself to Finder — which brings its own
// progress window and, unlike any copy engine we could write, a real entry in
// Finder's Edit ▸ Undo.
//
// The verbatim helpers that DO come from upstream live in `FinderSupport.swift`
// and keep the Vorssaint copyright line.

import AppKit
import Foundation

/// Ctrl-X / Ctrl-V for files, the Windows habit: ⌘X marks the Finder selection,
/// ⌘V moves it into the front window.
///
/// Everything the event tap does is synchronous and bounded — a bundle-id
/// compare, one AX role read with a 0.1s timeout, one `changeCount` read. Every
/// unbounded step (Apple Events to Finder, file I/O) happens off-main *after*
/// the swallow decision has already been made and returned.
@MainActor
final class FinderCutPaste {
    static let shared = FinderCutPaste()
    private init() {}

    /// The cut selection, and the pasteboard generation it was written at.
    private var marked: [URL] = []
    private var markedChangeCount = 0
    /// Bumped by every cut and paste, so an Apple Event that comes back after the
    /// user has moved on cannot publish stale marks or a stale toast.
    private var generation = 0
    /// A move is in flight; a second ⌘V must not run the same batch twice.
    private var pasting = false

    /// Either Finder tap feature being on is enough to want the keystroke.
    var isEnabled: Bool { Preferences.finderCutPasteEnabled || Preferences.finderPasteImageEnabled }

    /// Returns true to swallow the keystroke. Called on the tap's main-thread
    /// callback for every keyDown, so the early-outs are the hot path.
    func handle(keyCode: Int64, cmd: Bool, alt: Bool, ctrl: Bool, shift: Bool,
                bundleID: String?) -> Bool {
        let chord = KeyChord(keyCode: keyCode, cmd: cmd, alt: alt, ctrl: ctrl, shift: shift)
        // The role read is inside an autoclosure: it only runs once the chord and
        // the frontmost app have already matched.
        guard let action = FinderSupport.shouldHandle(
            chord: chord, bundleID: bundleID,
            role: FinderAX.focusedRole(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),
            cutPaste: Preferences.finderCutPasteEnabled,
            pasteImage: Preferences.finderPasteImageEnabled)
        else { return false }

        switch action {
        case .cut:
            cutAsync()
            return true
        case .paste:
            guard !pasting else { return false }
            let pasteboard = NSPasteboard.general
            // Decided here, synchronously, with a cheap local read — this is why
            // there is no synthetic re-post to undo a wrong guess. Marks that no
            // longer match the pasteboard belong to a copy the user made since, so
            // ⌘V is Finder's ordinary paste and must pass straight through.
            if !marked.isEmpty, pasteboard.changeCount == markedChangeCount {
                pasteAsync()
                return true
            }
            // No pending move: an image on the pasteboard becomes a PNG file.
            // `preferredImageType` returns nil the moment a `public.file-url` is
            // present — copied FILES are Finder's own paste and stay untouched.
            guard Preferences.finderPasteImageEnabled,
                  let type = FinderSupport.preferredImageType(in: (pasteboard.types ?? []).map(\.rawValue))
            else { return false }
            pasteImageAsync(type: type, changeCount: pasteboard.changeCount)
            return true
        }
    }

    /// Drops the marks and leaves the pasteboard alone.
    func clearMarks() { resetMarks(clearOwnedPasteboard: false) }

    /// Cancels a pending cut and takes the file URLs back off the pasteboard —
    /// but only while it is still the pasteboard *we* wrote. Anything copied
    /// since is the user's clipboard, and clearing that would be theft.
    func cancelPendingCut() { resetMarks(clearOwnedPasteboard: true) }

    private func resetMarks(clearOwnedPasteboard: Bool) {
        guard !marked.isEmpty else { return }
        if clearOwnedPasteboard, NSPasteboard.general.changeCount == markedChangeCount {
            NSPasteboard.general.clearContents()
        }
        marked = []
        markedChangeCount = 0
    }

    private func cutAsync() {
        clearMarks()
        generation += 1
        let generation = self.generation
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = FinderBridge.selectionURLs()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = FinderCutPaste.shared
                    // Stale reply, no consent, or nothing selected: the keystroke was
                    // swallowed and nothing else happened, which is the safe outcome.
                    guard generation == me.generation, !urls.isEmpty else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects(urls as [NSURL])
                    me.marked = urls
                    me.markedChangeCount = pasteboard.changeCount
                    ExtensionMenuBar.shared.alert(text: "Cut \(FinderMoveOutcome.items(urls.count))",
                                                  seconds: 1.2)
                }
            }
        }
    }

    private func pasteAsync() {
        pasting = true
        generation += 1
        let generation = self.generation
        let items = marked
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = FinderBridge.move(items)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = FinderCutPaste.shared
                    me.pasting = false
                    guard generation == me.generation else { return }
                    me.resetMarks(clearOwnedPasteboard: true)
                    ExtensionMenuBar.shared.alert(text: outcome.summary, seconds: 1.6)
                }
            }
        }
    }

    /// Everything expensive — the pasteboard read, the decode, the PNG encode, the
    /// write, and the Apple Event that asks Finder where the paste would land —
    /// happens here, after the swallow has already been returned.
    private func pasteImageAsync(type: String, changeCount: Int) {
        pasting = true
        generation += 1
        let generation = self.generation
        DispatchQueue.global(qos: .userInitiated).async {
            let name = FinderBridge.writeImage(type: type, changeCount: changeCount)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = FinderCutPaste.shared
                    me.pasting = false
                    guard generation == me.generation else { return }
                    ExtensionMenuBar.shared.alert(
                        text: name.map { "Pasted \($0)" } ?? "Could not paste image", seconds: 1.6)
                }
            }
        }
    }
}

/// How a paste went, and the one line the HUD shows for it.
struct FinderMoveOutcome: Equatable, Sendable {
    var moved: Int
    var failed: Int

    var summary: String {
        if moved == 0, failed == 0 { return "Nothing to move" }
        if failed == 0 { return "Moved \(Self.items(moved))" }
        if moved == 0 { return "Could not move \(Self.items(failed))" }
        return "Moved \(Self.items(moved)), \(failed) failed"
    }

    static func items(_ n: Int) -> String { "\(n) item\(n == 1 ? "" : "s")" }
}

/// Talks to Finder. Every call blocks its thread until Finder replies, so all of
/// it runs off-main.
private enum FinderBridge {
    static let bundleID = "com.apple.finder"
    /// "An item with the same name already exists in this location."
    static let collisionError = -15267

    static func selectionURLs() -> [URL] {
        guard Scripting.consentToAutomate(bundleID: bundleID) else { return [] }
        let result = Scripting.run("""
        tell application "Finder"
            set out to ""
            repeat with f in (get selection)
                set out to out & (POSIX path of (f as alias)) & linefeed
            end repeat
            return out
        end tell
        """)
        guard result.ok else { return [] }
        return result.output.split(whereSeparator: \.isNewline)
            .map { URL(fileURLWithPath: String($0)) }
    }

    /// The folder a Finder paste would land in — the front window's target, or the
    /// Desktop when no window is open. `insertion location` is first-class in
    /// Finder's dictionary, so this needs no window bookkeeping of our own.
    static func insertionLocation() -> URL? {
        guard Scripting.consentToAutomate(bundleID: bundleID) else { return nil }
        let result = Scripting.run(
            #"tell application "Finder" to return POSIX path of (insertion location as alias)"#)
        guard result.ok else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// A 64 MB pasteboard image is already an 8000×8000 screenshot. Past that the
    /// decode is likelier to be a hang than a paste, so the keystroke is spent and
    /// nothing is written — the toast says so.
    static let maxImageBytes = 64 * 1024 * 1024

    /// Re-encodes the pasteboard image as PNG and writes it where a Finder paste
    /// would have landed. Returns the file name written.
    static func writeImage(type: String, changeCount: Int) -> String? {
        let pasteboard = NSPasteboard.general
        // The user may have copied something else in the time it took to get here.
        guard pasteboard.changeCount == changeCount,
              let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)),
              data.count <= maxImageBytes,
              let png = pngData(from: data, type: type),
              let destination = insertionLocation() else { return nil }
        let target = FinderSupport.uniqueDestination(for: FinderSupport.fileName(for: Date()),
                                                     in: destination, fm: .default)
        guard (try? png.write(to: target)) != nil else { return nil }
        return target.lastPathComponent
    }

    /// PNG already on the pasteboard is written through untouched — a decode and
    /// re-encode would only cost time and drop whatever metadata it carries.
    private static func pngData(from data: Data, type: String) -> Data? {
        if type == "public.png" { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    /// Moves each item into the insertion location, ONE Apple Event PER ITEM.
    ///
    /// Two measured behaviours of Finder's scripted `move` dictate this shape:
    ///
    ///  - A batch `move {a, b, c}` is **not atomic**. With a name collision on `b`,
    ///    `a` and `c` still move and the single call raises -15267 for the whole
    ///    batch — so the error can never say which items landed. One event per
    ///    item is the only way to get one verdict per item.
    ///  - Across volumes `move` **copies and leaves the original**: it is drag
    ///    semantics, not ⌘X semantics. Cutting to another disk that way would
    ///    silently duplicate the file, so those items never reach Finder at all.
    ///
    /// Everything staying on one volume goes to Finder, which is the entire point
    /// of the design: its own progress window, and a real `Undo Move` in its Edit
    /// menu. The `FileManager` path has neither, and is used only where Finder
    /// would be wrong (cross-volume) or refuses outright (collision).
    static func move(_ urls: [URL]) -> FinderMoveOutcome {
        guard !urls.isEmpty else { return FinderMoveOutcome(moved: 0, failed: 0) }
        guard let destination = insertionLocation() else {
            return FinderMoveOutcome(moved: 0, failed: urls.count)
        }
        let fm = FileManager.default
        let destinationVolume = volumeIdentity(of: destination)
        var outcome = FinderMoveOutcome(moved: 0, failed: 0)
        for url in urls {
            if volumeIdentity(of: url) != destinationVolume {
                if relocate(url, into: destination, fm: fm) { outcome.moved += 1 } else { outcome.failed += 1 }
                continue
            }
            let result = Scripting.run(
                "tell application \"Finder\" to move \(posixFile(url)) to \(posixFile(destination))")
            if result.ok {
                outcome.moved += 1
            } else if result.errorNumber == collisionError, relocate(url, into: destination, fm: fm) {
                outcome.moved += 1
            } else {
                outcome.failed += 1
            }
        }
        return outcome
    }

    /// The `FileManager` path: a real move across volumes, and the de-duplicating
    /// retry Finder refuses to do on a name collision. Buys no undo entry.
    private static func relocate(_ url: URL, into directory: URL, fm: FileManager) -> Bool {
        let target = FinderSupport.uniqueDestination(for: url.lastPathComponent, in: directory, fm: fm)
        do {
            try fm.moveItem(at: url, to: target)
            return true
        } catch {
            return false
        }
    }

    /// Unknown volume identity reads as "same volume", which sends the item to
    /// Finder — the path with undo. The cross-volume copy trap only bites when we
    /// can positively tell the two apart.
    private static func volumeIdentity(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    private static func posixFile(_ url: URL) -> String {
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "POSIX file \"\(escaped)\""
    }
}
