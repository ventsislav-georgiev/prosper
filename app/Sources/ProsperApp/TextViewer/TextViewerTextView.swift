import AppKit
import Quartz   // QLPreviewItem, for the Quick Look override

// #1106 (design #1105 D8, rider R1): the viewer's TextKit 1 text view. Copy, Cut and Paste go
// through the Pasteboard.general seam (the stock view writes the system pasteboard directly, which a
// test could not observe and the seam rule forbids), and "Use Selection for Find" through the
// find pasteboard seam below.

enum TextViewerFind {
    /// R1: the shared find pasteboard every app reads; under XCTest a private per-process one,
    /// released at exit, as Pasteboard.general does (#316).
    nonisolated(unsafe) static let pasteboard: NSPasteboard = {
        guard NSClassFromString("XCTestCase") != nil else { return NSPasteboard(name: .find) }
        let pb = NSPasteboard(name: NSPasteboard.Name("eu.illegible.prosper.xctest.find.\(getpid())"))
        atexit { TextViewerFind.pasteboard.releaseGlobally() }
        return pb
    }()
}

final class TextViewerTextView: NSTextView {
    /// D9: the text column is at most this wide (points at UI scale 1), centred.
    nonisolated static let columnWidth: CGFloat = 760

    /// A non-editable, selectable TextKit 1 view in a vertical scroll view, nothing on screen.
    static func makeScrollable() -> (NSScrollView, TextViewerTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        let view = TextViewerTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true   // RTF on Copy (D8); the view never takes rich input in Read mode
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]   // the renderer's own link colour and underline
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return (scroll, view)
    }

    /// The text last shown: the model hands over a new object only when the text or the theme
    /// changed, so the same one again keeps the selection and the scroll.
    private var shown: NSAttributedString?
    /// D6: a clicked link, for the model to decide; AppKit's own handling never runs.
    var onLink: ((URL) -> Void)?

    /// Shows the rendered (or plain) text, keeping the scroll position as a fraction of the height
    /// (D9: a reload keeps the place).
    func show(_ text: NSAttributedString) {
        guard text !== shown else { return }
        shown = text
        let clip = enclosingScrollView?.contentView
        let fraction = clip.map { $0.bounds.minY / max(1, frame.height) } ?? 0
        textStorage?.setAttributedString(text)
        typingAttributes = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        guard let clip, let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        sizeToFit()
        clip.scroll(to: NSPoint(x: 0, y: (fraction * frame.height).rounded()))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(sz(20), (newSize.width - Self.columnWidth * ThemeRuntime.scale) / 2)
        if textContainerInset.width != side { textContainerInset = NSSize(width: side, height: sz(16)) }
    }

    /// The selection as plain text plus RTF. Written explicitly: writeSelection(to:types:) left a
    /// named pasteboard empty offscreen (#1106 green ticket 1). An Option-drag column selection has
    /// several ranges: they are joined with newlines, as the stock view does (R1118-1).
    override func copy(_ sender: Any?) {
        guard let storage = textStorage else { return }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= storage.length }
        guard !ranges.isEmpty else { return }
        let part = NSMutableAttributedString()
        for range in ranges {
            if part.length > 0 { part.append(NSAttributedString(string: "\n")) }
            part.append(storage.attributedSubstring(from: range))
        }
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString(Self.plainString(part.string), forType: .string)
        if let rtf = part.rtf(from: NSRange(location: 0, length: part.length), documentAttributes: [:]) { pb.setData(rtf, forType: .rtf) }
    }

    override func cut(_ sender: Any?) {
        guard isEditable else { return }
        copy(sender)
        delete(sender)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        readSelection(from: Pasteboard.general)
    }

    /// An image's attachment character means nothing pasted as text.
    static func plainString(_ s: String) -> String { s.replacingOccurrences(of: "\u{FFFC}", with: "") }

    /// D6: every click on a link lands here (NSTextView's click path calls this before its delegate
    /// and NSWorkspace); the model asks LinkPolicy again and acts through its seams.
    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return }
        onLink?(url)
    }

    /// Round 2: at a link, our own menu: Copy, and Copy Link Address (the tooltip's target). Nothing
    /// in it opens or previews: the stock one at a link has Copy Link (the real URL), Share and Quick
    /// Look Attachments (a preview of the link's URL). Elsewhere the stock menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let target = linkTarget(at: convert(event.locationInWindow, from: nil)) else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
        let item = menu.addItem(withTitle: "Copy Link Address", action: #selector(copyLinkAddress(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = target
        return menu
    }

    @objc func copyLinkAddress(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String else { return }
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString(target, forType: .string)
    }

    /// Round 3 (F1): the recognizers NSTextView adds that the viewer keeps, by class name, read from
    /// the runtime on macOS 27.2. The immediate-action recognizer is not among them: its force click at a
    /// link previews the target (a web page fetched without a click) and never reaches quickLook(with:).
    /// On macOS 27 and later every class not listed is refused, so one a later macOS adds or renames is
    /// refused too (testForceClickHasNoImmediateAction pins the stock set). Round 4: macOS 14 to 26 were
    /// never read, so there only the immediate-action recognizer (and any subclass) is refused.
    nonisolated static let keptRecognizers: Set<String> = [
        "NSClickGestureRecognizer", "NSPressGestureRecognizer", "NSDragGestureRecognizer",
        "_NSTextSelectionMouseEmulationBlocker", "_NSTextSelectionTouchTracker",
    ]

    /// Whether the view keeps `recognizer`: by the list where it was read (`listRule`), else everything
    /// but an immediate-action recognizer; with no such class at run time, everything.
    nonisolated static func keeps(_ recognizer: NSGestureRecognizer, listRule: Bool) -> Bool {
        if listRule { return keptRecognizers.contains(NSStringFromClass(type(of: recognizer))) }
        guard let immediate = NSClassFromString("NSImmediateActionGestureRecognizer") else { return true }
        return !recognizer.isKind(of: immediate)
    }

    /// NSTextView adds its recognizers here, at init and whenever it sets them up again.
    override func addGestureRecognizer(_ recognizer: NSGestureRecognizer) {
        let listRule: Bool
        if #available(macOS 27, *) { listRule = true } else { listRule = false }
        guard Self.keeps(recognizer, listRule: listRule) else { return }
        super.addGestureRecognizer(recognizer)
    }

    /// A three-finger tap (or, with no immediate-action recognizer, a force click) at a link does
    /// nothing: the stock Quick Look would preview the target. Elsewhere (a word) the stock Look Up.
    override func quickLook(with event: NSEvent) {
        if linkTarget(at: convert(event.locationInWindow, from: nil)) != nil { return }
        super.quickLook(with: event)
    }

    /// Nothing is offered to Quick Look: the stock list holds each link's URL (Round 2 fact), so the
    /// panel (Quick Look Attachments, or the key) would preview a web page without a click.
    override func quickLookPreviewableItems(inRanges ranges: [NSValue]) -> [any QLPreviewItem] { [] }

    /// The tooltip's target of the link nearest `point` (view coordinates), or nil off a link.
    /// Nearest, not exact: a point beside a link gets the inert menu, never the stock link one.
    func linkTarget(at point: NSPoint) -> String? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = lm.characterIndexForGlyph(at: lm.glyphIndex(for: p, in: tc))
        guard index < storage.length, storage.attribute(.link, at: index, effectiveRange: nil) != nil else { return nil }
        return storage.attribute(.toolTip, at: index, effectiveRange: nil) as? String ?? ""
    }

    /// ⌘E: the selection becomes the search string, on the find pasteboard seam (R1).
    func useSelectionForFind() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let pb = TextViewerFind.pasteboard
        pb.clearContents()
        pb.setString(storage.attributedSubstring(from: range).string, forType: .string)
    }

    /// ⌘F, ⌘G, ⇧⌘G: the find bar. NSTextFinder reads the action from the sender's tag.
    func find(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()   // never put in a menu: it only carries the tag
        sender.tag = action.rawValue
        performTextFinderAction(sender)
    }
}
