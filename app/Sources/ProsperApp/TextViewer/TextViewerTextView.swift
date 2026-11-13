import AppKit

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
    static let columnWidth: CGFloat = 760

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

    /// Shows `text` in the monospaced body font and the theme's text colour, keeping the scroll
    /// position as a fraction of the height (D9: a reload keeps the place).
    func show(_ text: String, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        guard string != text || textStorage?.length == 0 else { return }
        let clip = enclosingScrollView?.contentView
        let fraction = clip.map { $0.bounds.minY / max(1, frame.height) } ?? 0
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        typingAttributes = attrs
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
    /// named pasteboard empty offscreen (green ticket 1).
    /// shortcut: the first selected range only; join selectedRanges if a multi-range select ships.
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let part = storage.attributedSubstring(from: range)
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString(part.string, forType: .string)
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
