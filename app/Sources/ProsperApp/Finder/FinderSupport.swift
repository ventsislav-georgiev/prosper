// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from vorssaint-utils (github.com/vorssaint/vorssaint-utils, GPL-3.0):
//   - `editableRoles` + `acceptsFocusedRole`, verbatim from
//     `Sources/Vorssaint/Services/Finder/FinderRenameSupport.swift`
//   - `preferredImageType` + `fileName`, verbatim from
//     `Sources/Vorssaint/Services/Finder/FinderPasteImageSupport.swift`
//   - `uniqueDestination`, verbatim from its `FinderCutPaste.swift`
// `shouldHandle` and `FinderCutPasteAction` are Prosper's own — they exist because
// Prosper decides the whole swallow on the shared tap instead of re-posting a
// synthetic keystroke afterwards.

import Foundation
import UniformTypeIdentifiers

/// What a Finder chord asks Prosper to do. `nil` from `shouldHandle` means "not
/// ours" — the keystroke goes to Finder untouched.
enum FinderCutPasteAction: Equatable, Sendable {
    case cut
    case paste
}

enum FinderSupport {
    private static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField",
    ]

    static func acceptsFocusedRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return !editableRoles.contains(role)
    }

    /// The whole synchronous decision the event tap makes, as one pure function.
    ///
    /// `role` is an autoclosure on purpose: reading the focused AX role is the one
    /// expensive step here (it is a cross-process message, and the session's typing
    /// waits on it), so it must not run until the cheap checks have already said
    /// this keystroke could be ours. Tests just pass a role string.
    ///
    /// Deliberately narrow: bare ⌘X / ⌘V only. ⌥⌘V is Finder's own "Move Item
    /// Here" and ⇧⌘V/⌃⌘V belong to whoever else wants them. A focused text field
    /// (an in-progress rename, the search field) keeps both chords — swallowing
    /// ⌘X mid-rename would eat the user's edit, which is the sharpest failure
    /// mode this feature has. An unreadable role (`nil`) reads as "text field":
    /// not knowing is not a licence to swallow.
    static func shouldHandle(chord: KeyChord, bundleID: String?,
                             role: @autoclosure () -> String?,
                             cutPaste: Bool, pasteImage: Bool) -> FinderCutPasteAction? {
        guard cutPaste || pasteImage, bundleID == "com.apple.finder" else { return nil }
        guard chord.mediaCode == nil, chord.cmd, !chord.alt, !chord.ctrl, !chord.shift else { return nil }
        let action: FinderCutPasteAction
        switch chord.keyCode {
        // ⌘X is only ours when the move feature is on: with just paste-image
        // enabled, swallowing it would break Finder's own ⌘X.
        case 7 where cutPaste: action = .cut     // kVK_ANSI_X
        case 9: action = .paste   // kVK_ANSI_V
        default: return nil
        }
        guard acceptsFocusedRole(role()) else { return nil }
        return action
    }

    /// A copied image file can also advertise image data. File URLs win so a
    /// normal Finder paste is never turned into a newly rendered PNG.
    static func preferredImageType(in typeIdentifiers: [String]) -> String? {
        guard !typeIdentifiers.contains(fileURLType) else { return nil }
        if typeIdentifiers.contains(pngType) { return pngType }
        return typeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        }
    }

    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "'Pasted_Image_'yyyyMMdd_HHmmss'.png'"
        return formatter.string(from: date)
    }

    /// Appends " 2", " 3"… before the extension when a name already exists,
    /// matching how Finder de-duplicates.
    static func uniqueDestination(for name: String, in dir: URL, fm: FileManager) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private static let fileURLType = "public.file-url"
    private static let pngType = "public.png"
}
