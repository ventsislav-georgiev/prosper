import AppKit
import UniformTypeIdentifiers

// #1106 (design #1105 D3): which opened URLs are text documents for the viewer, and the intake
// that buffers them across a cold launch and checks the extension's enable gate (D14).

enum TextViewerRouting {
    nonisolated static let markdownTypeID = "net.daringfireball.markdown"
    /// Extensions Prosper treats as Markdown by file name (macOS declares the type for md and markdown only). By name because under XCTest, or
    /// on a Mac where nothing declares the type, UTType(filenameExtension: "md") is a dynamic type.
    nonisolated static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// True for a file URL whose type is Markdown or plain text and not HTML. Pure: it never checks
    /// that the file exists or is regular; the viewer refuses a missing file, a directory or a FIFO
    /// itself, so a text-typed file URL never falls through to a browser.
    nonisolated static func isDocument(_ url: URL) -> Bool {
        isDocument(url) { [(try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType].compactMap { $0 } }
    }

    /// The same rule with the types of an extensionless name from the caller: the one type a file read
    /// gives above, every type of the Spotlight tree a search hit already holds for FileSearchEngine.isViewable
    /// (#1148), which reads nothing. Order-free: an HTML type anywhere refuses, then a Markdown or plain-text
    /// type anywhere accepts, no type refuses. A name with an extension decides by that extension's one type.
    nonisolated static func isDocument(_ url: URL, typesWithoutExtension: () -> [UTType]) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return true }
        let types = ext.isEmpty ? typesWithoutExtension() : [UTType(filenameExtension: ext)].compactMap { $0 }
        // the .html link case stays the router's
        guard !types.isEmpty, !types.contains(where: { $0.conforms(to: .html) }) else { return false }
        let md = UTType(markdownTypeID)
        return types.contains { t in md.map { t.conforms(to: $0) } == true || t.conforms(to: .plainText) }
    }

    /// True when `url` is shown as Markdown (P1b renders it; P1a shows its source).
    nonisolated static func isMarkdown(_ url: URL) -> Bool {
        if markdownExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let md = UTType(markdownTypeID) else { return false }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: md) ?? false
    }

    /// The branch in application(_:open:): documents to the viewer, everything else to the link
    /// path exactly as before (as `absoluteString`).
    @MainActor
    static func route(_ urls: [URL], document: (URL) -> Void, link: (String) -> Void) {
        for url in urls {
            if isDocument(url) { document(url) } else { link(url.absoluteString) }
        }
    }
}

/// Document URLs from Finder, `open`, and the runner. Buffered until the extensions are loaded
/// (a cold launch by a file arrives before applicationDidFinishLaunching), like
/// OpenedLinkRouter.pending, because the enable gate needs the registry.
@MainActor
final class TextViewerIntake {
    static let shared = TextViewerIntake()

    /// The textviewer extension is live. AppDelegate sets it; false until then (and in tests).
    var isEnabled: () -> Bool = { false }
    /// D14: with the extension off, one notification per batch (R1118-6: the documents of one
    /// Open With or one launch arrive in one main-queue turn), never a hand-off to another app (if
    /// Prosper were the default for .md, that would loop).
    var notifyOff: () -> Void = {}
    var show: (URL) -> Void = { TextViewerWindows.shared.open($0) }
    private var pending: [URL]? = []
    private var noticed = false

    func receive(_ url: URL) {
        if pending != nil { pending?.append(url); return }
        guard isEnabled() else {
            guard !noticed else { return }
            noticed = true
            notifyOff()
            Task { @MainActor in self.noticed = false }   // the next turn is the next batch
            return
        }
        show(url)
    }

    /// Extensions are loaded: open anything that arrived before, in order.
    func ready() {
        let queued = pending ?? []
        pending = nil
        queued.forEach(receive)
    }
}
