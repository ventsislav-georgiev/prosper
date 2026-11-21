import AppKit

/// #1861: clipboard.put {text} over the control channel: an agent puts plain text on the clipboard through Prosper's own
/// pasteboard seam (Pasteboard.general, a private per-process pasteboard under XCTest). Before the write the clip there
/// is saved with Pasteboard.save (every item, every concrete type); the undo puts it back with Pasteboard.restore, only
/// while the clipboard still holds the agent's write, so a copy the person made since is left alone. Refused, the
/// clipboard untouched, when the save could not keep the person's clip whole or would raise macOS's paste alert (QA
/// n158, n160). Neither the write nor the undo's restore goes into the clipboard history (n159).
/// Reading the clipboard or its history stays human-only: nothing here returns
/// what was there. The text is outside text: over the cap, empty, or with a control or hidden character other than LF and
/// tab, it is refused whole. On demand only: no observer, no poll.
@MainActor
enum ControlClipboard {
    /// Seam: the pasteboard written. Rows swap in a named scratch pasteboard of their own.
    static var pasteboard: @MainActor () -> NSPasteboard = { Pasteboard.general }
    /// Seam: macOS's paste access for Prosper (`.unknown` under XCTest).
    static var access: @MainActor () -> ClipboardAccess = { Pasteboard.access() }
    /// Seam: the history skip for a change Prosper made itself (DchClipboard.setLive's pattern); rows swap in a recorder.
    static var ignoreHistory: @MainActor (_ changeCount: Int) -> Void = { ClipboardMonitor.shared.ignoreHistory(changeCount: $0) }
    /// Seam: the save's byte cap; rows lower it instead of filling 32 MiB.
    static var saveCap = Pasteboard.saveByteCap

    /// The text's cap, in UTF-8 bytes.
    static let maxBytes = 1 << 20
    /// How much of the text the notice and `ctl log` show.
    static let summaryMax = 80

    static func put(_ args: [String: ControlJSON]) throws -> ControlChange {
        guard case .string(let text)? = args["text"], !text.isEmpty else { throw ControlError("argument 'text' is empty") }
        guard text.utf8.count <= maxBytes else { throw ControlError("text is longer than \(maxBytes) bytes") }
        if ControlSessionsTalk.hasUnseen(text, allowing: ["\n", "\t"]) {
            throw ControlError("text has a control or hidden character: only line breaks (LF) and tabs are allowed")
        }
        // n158: under .denied the save reads nothing (the undo would empty the clipboard); under .asks or
        // .systemDefault the save's read raises macOS's paste alert for an agent's command (ClipboardMonitor holds reads too).
        let state = access()
        guard state == .allowed || state == .unknown else {
            throw ControlError("clipboard left as it was: Undo needs Prosper allowed in \(ClipboardAccess.paneName)")
        }
        let pb = pasteboard()
        let previous = Pasteboard.save(pb, access: state, cap: saveCap)
        // n160: a clip past the cap is saved in part; the undo would lose the rest of the person's copy.
        guard previous.bytesRead <= saveCap else {
            throw ControlError("clipboard left as it was: it holds more than Undo can put back (\(saveCap) bytes)")
        }
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            restore(previous, to: pb, ifChangeCount: pb.changeCount)
            throw ControlError("the clipboard refused the text")
        }
        let written = pb.changeCount
        ignoreHistory(written)
        return ControlChange(summary: OutsideText.shown(text, max: summaryMax), verb: "copied to the clipboard",
                             undo: { restore(previous, to: pb, ifChangeCount: written) })
    }

    /// Puts the saved clip back, and keeps that change out of the history (it is the person's clip, already there).
    private static func restore(_ saved: Pasteboard.SavedClip, to pb: NSPasteboard, ifChangeCount written: Int) {
        if Pasteboard.restore(saved, to: pb, ifChangeCount: written) { ignoreHistory(pb.changeCount) }
    }
}

extension ControlRegistry {
    /// #1861: wired in ControlRegistry.standard().
    static func registerClipboard(_ r: inout ControlRegistry) {
        r.register(.change(name: "clipboard.put", summary: "Put plain text on the clipboard. Undo puts back what was there, unless something was copied since.", args: [
            "text": ControlArg(type: "string", required: true, summary: "the text; line breaks and tabs allowed, no other control characters"),
        ]) { _, a in try ControlClipboard.put(a) })
    }
}
