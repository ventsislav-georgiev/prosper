import AppKit

/// #1861: clipboard.put {text} over the control channel: an agent puts plain text on the clipboard through Prosper's own
/// pasteboard seam (Pasteboard.general, a private per-process pasteboard under XCTest). Before the write the clip there
/// is saved with Pasteboard.save (every item, every concrete type, up to its byte cap; nothing under denied paste
/// access); the undo puts it back with Pasteboard.restore, only while the clipboard still holds the agent's write, so a
/// copy the person made since is left alone. Reading the clipboard or its history stays human-only: nothing here returns
/// what was there. The text is outside text: over the cap, empty, or with a control or hidden character other than LF and
/// tab, it is refused whole. On demand only: no observer, no poll.
@MainActor
enum ControlClipboard {
    /// Seam: the pasteboard written. Rows swap in a named scratch pasteboard of their own.
    static var pasteboard: @MainActor () -> NSPasteboard = { Pasteboard.general }
    /// Seam: macOS's paste access for Prosper (`.unknown` under XCTest); `.denied` saves nothing, so the undo empties.
    static var access: @MainActor () -> ClipboardAccess = { Pasteboard.access() }

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
        let pb = pasteboard()
        let previous = Pasteboard.save(pb, access: access())
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            Pasteboard.restore(previous, to: pb, ifChangeCount: pb.changeCount)
            throw ControlError("the clipboard refused the text")
        }
        let written = pb.changeCount
        return ControlChange(summary: OutsideText.shown(text, max: summaryMax), verb: "copied to the clipboard",
                             undo: { Pasteboard.restore(previous, to: pb, ifChangeCount: written) })
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
