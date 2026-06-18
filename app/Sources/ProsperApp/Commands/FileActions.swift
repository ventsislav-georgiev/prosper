import AppKit

/// Native file actions for the `f ` finder (and any extension list row that opts
/// in). These are the mission-critical, OS-integrated operations — open, reveal,
/// Quick Look, copy, trash, open-with — so they live in native Swift behind the
/// `host.files` API rather than in a Lua extension. Irreversible ones (trash) are
/// deliberately native and explicit.
///
/// A row declares which of these it offers via `ListItem.actions` (reserved ids
/// below); the runner maps each id here and runs it on the main actor.
enum FileActions {

    /// Reserved built-in action ids the runner dispatches natively. An extension
    /// puts these in a list item's `actions` to surface them (Open is the default
    /// primary). Anything else is treated as a custom, extension-handled action.
    enum ID {
        static let open = "file.open"
        static let reveal = "file.reveal"
        static let quickLook = "file.quicklook"
        static let copyPath = "file.copyPath"
        static let copyFile = "file.copyFile"
        static let openWith = "file.openWith"
        static let enclosingFolder = "file.enclosingFolder"
        static let trash = "file.trash"

        /// All reserved ids — used to tell built-in (native) from custom actions.
        static let all: Set<String> = [
            open, reveal, quickLook, copyPath, copyFile, openWith, enclosingFolder, trash,
        ]
    }

    /// True if `id` is a built-in file action this type handles natively.
    static func isBuiltIn(_ id: String) -> Bool { ID.all.contains(id) }

    /// Engagements that count toward frecency ranking (actively using a file),
    /// as opposed to incidental ones (copy/trash).
    static let engagementIDs: Set<String> = [ID.open, ID.reveal, ID.openWith, ID.enclosingFolder, ID.quickLook]

    /// Whether running `id` should dismiss the runner. Quick Look overlays the
    /// runner and keeps it open (preview-then-act); everything else completes and
    /// dismisses, matching Raycast.
    static func dismissesRunner(_ id: String) -> Bool { id != ID.quickLook }

    /// Runs a built-in action against `path`. Returns true if it was a recognized
    /// built-in (so the caller can record frecency / dismiss). Unknown / missing
    /// path → false (caller routes custom actions elsewhere).
    @discardableResult
    @MainActor
    static func perform(_ id: String, path: String) -> Bool {
        guard isBuiltIn(id), !path.isEmpty else { return false }
        let url = URL(fileURLWithPath: path)
        // Re-check existence: the index can lag a delete between search and act.
        guard id == ID.copyPath || FileManager.default.fileExists(atPath: path) else { return true }

        switch id {
        case ID.open:
            NSWorkspace.shared.open(url)
        case ID.reveal, ID.enclosingFolder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case ID.quickLook:
            QuickLook.preview(path)
        case ID.copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(path, forType: .string)
        case ID.copyFile:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
        case ID.openWith:
            // Reveal the app picker by opening the enclosing folder + selecting the
            // file; a full "Open With" submenu is a follow-up (needs UI). Fall back
            // to a plain open so the action is never a dead end.
            NSWorkspace.shared.open(url)
        case ID.trash:
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        default:
            return false
        }
        return true
    }
}

/// Performs a built-in file action against a path. Abstracted so the runner's
/// action dispatch can be tested with a mock that records calls instead of hitting
/// the real OS (mocked UI interaction).
protocol FileActionPerforming: Sendable {
    @MainActor @discardableResult func perform(_ id: String, path: String) -> Bool
}

/// Production performer: the real `FileActions` OS operations.
struct LiveFileActionPerformer: FileActionPerforming {
    @MainActor func perform(_ id: String, path: String) -> Bool { FileActions.perform(id, path: path) }
}

/// Couples a file action to its side effects: run it through the performer, and
/// record a frecency engagement for the usage actions (open / reveal / quick look
/// / …). This is the shared logic behind both the runner's row activation and the
/// `host.files.act` host call, so a single unit covers "what an action does".
@MainActor
final class FileActionDispatcher {
    static let live = FileActionDispatcher()

    private let performer: FileActionPerforming
    private let frecency: FrecencyStore

    init(performer: FileActionPerforming = LiveFileActionPerformer(),
         frecency: FrecencyStore = .shared) {
        self.performer = performer
        self.frecency = frecency
    }

    /// Runs `id` against `path`; on a handled engagement, bumps frecency. Returns
    /// whether the action was a recognized built-in (so callers can branch).
    @discardableResult
    func run(id: String, path: String, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let handled = performer.perform(id, path: path)
        if handled, FileActions.engagementIDs.contains(id) {
            frecency.record(path: path, now: now)
        }
        return handled
    }
}

/// Inline Quick Look for the finder. Uses `qlmanage -p`, the documented Quick Look
/// CLI, rather than `QLPreviewPanel`: the runner is a non-activating panel that
/// never becomes the preview panel's controlling responder (the responder-chain
/// `*PreviewPanelControl` handshake never fires), and `qlmanage` previews from any
/// context without that dance. The window is visually the standard Quick Look.
enum QuickLook {
    /// Opens a Quick Look preview for `path`. Fire-and-forget; `qlmanage`'s noisy
    /// stdout/stderr is discarded.
    @MainActor
    static func preview(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        proc.arguments = ["-p", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }
}
