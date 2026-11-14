import AppKit
import SwiftUI

// #1107 (design #1105 D15): the whole-document screenshot. A second, unwindowed TextKit 1 view lays
// out a copy of the shown text at the window's column width and draws it in strips into one bitmap;
// the PNG goes on the clipboard through the Pasteboard seam. Every size that comes from a layout is
// outside data: the pure planner checks it before any conversion to Int and before any allocation.

enum DocumentImage {
    /// D15: the common decoder and canvas height limit among paste targets.
    static let maxHeightPixels = 32_767
    /// D15: 50 megapixels, a 200 MiB RGBA transient peak.
    static let maxAreaPixels = 50_000_000
    /// D15: the document is drawn in strips of this many points.
    static let stripPoints = 2_000
    /// Around the column, in points, on every side of the image.
    static let margin: CGFloat = 16
    /// Past this a layout size (points) is not a document's: nothing to copy.
    static let maxPoints: Double = 1_000_000_000

    static let emptyNotice = "Nothing to copy: the document is empty"
    static let failedNotice = "Could not copy the image"

    /// D15's words, with the numbers grouped by thousands ("1,520").
    static func copiedNotice(width: Int, height: Int) -> String {
        "Copied image (\(grouped(width)) × \(grouped(height)) px)"
    }

    static func cutNotice(lines: Int, of total: Int) -> String {
        lines > 0 ? "Copied lines 1-\(grouped(lines)) of \(grouped(total)) (image height limit)"
                  : "Copied part of line 1 of \(grouped(total)) (image height limit)"   // one line taller than the limit
    }

    /// A pixel or line count (never negative) with a comma every three digits, in every locale.
    static func grouped(_ n: Int) -> String {
        let digits = Array(String(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return out
    }

    /// The window's Neon surface colour, opaque: see-through pixels would paste as the target's background.
    @MainActor static var surface: NSColor { NSColor(Neon.bgTop).withAlphaComponent(1) }

    /// The bitmap to draw: `scale` is the window's (else 1), `width` and `height` in pixels. When `cut`,
    /// `height` is the most rows the ceilings allow at 1x and the image is cut at a line above it.
    struct Plan: Equatable {
        let scale: Int
        let width: Int
        let height: Int
        let cut: Bool
    }

    /// Pure: the laid-out size in points and the backing scale give the plan, or nil for nothing to copy
    /// (a non-finite, zero, negative or huge size, or not one row of pixels within the area). Every
    /// check runs on Doubles before any Int conversion; the ceilings are parameters so rows pass small ones.
    static func plan(width: Double, height: Double, backing: Double,
                     maxHeight: Int = maxHeightPixels, maxArea: Int = maxAreaPixels) -> Plan? {
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= maxPoints, height <= maxPoints,
              maxHeight > 0, maxArea > 0 else { return nil }
        let window = backing.isFinite && backing >= 1 && backing <= 4 ? backing.rounded() : 1
        // Both factors are at most 4e9 here: the product is finite, and compared as a Double.
        for s in window > 1 ? [window, 1] : [1] {
            let w = (width * s).rounded(.up), h = (height * s).rounded(.up)
            if h <= Double(maxHeight), w * h <= Double(maxArea) {
                return Plan(scale: Int(s), width: Int(w), height: Int(h), cut: false)
            }
        }
        let w = width.rounded(.up)
        let rows = min(Double(maxHeight), (Double(maxArea) / w).rounded(.down))
        guard rows >= 1 else { return nil }
        return Plan(scale: 1, width: Int(w), height: Int(rows), cut: true)
    }

    struct Image {
        let png: Data
        let width: Int
        let height: Int
        /// Set when cut: the whole lines shown (0: the top of line 1 only), of `total`.
        let lines: Int?
        let total: Int
    }

    enum Outcome {
        case image(Image)
        case empty
        case failed
    }

    /// Draws `text` as one PNG: a TextKit 1 view with no window, `column` points wide (the live view's
    /// text container width), in `appearance`, filled with `background`. Laid out once, at most to the
    /// height ceiling, then drawn in strips of `strip` points. Runs on the main actor (AppKit drawing).
    /// The live view is never touched: only `text` is read.
    @MainActor
    static func render(_ text: NSAttributedString, column: CGFloat, appearance: NSAppearance?, background: NSColor,
                       backing: CGFloat, maxHeight: Int = maxHeightPixels, maxArea: Int = maxAreaPixels,
                       strip: Int = stripPoints) -> Outcome {
        guard text.length > 0 else { return .empty }
        // The column comes from the live layout: checked before it sizes a view.
        guard column.isFinite, column > 0, Double(column) <= maxPoints, strip > 0, strip <= 100_000,
              maxHeight > 0, maxHeight <= 1_000_000 else { return .failed }
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = false
        view.isRichText = true
        view.importsGraphics = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        // R1107-1: links drawn as the renderer styled them, as the live view does (its linkTextAttributes hold only
        // the cursor); AppKit's default would draw its own blue and underline over every link.
        view.linkTextAttributes = [:]
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.drawsBackground = true
        view.backgroundColor = background
        view.appearance = appearance
        view.textContainerInset = NSSize(width: margin, height: margin)
        guard let lm = view.layoutManager, let tc = view.textContainer, let storage = view.textStorage else { return .failed }
        tc.widthTracksTextView = false
        tc.heightTracksTextView = false
        tc.size = NSSize(width: column, height: CGFloat.greatestFiniteMagnitude)
        view.frame = NSRect(x: 0, y: 0, width: column + 2 * margin, height: 1)
        lm.allowsNonContiguousLayout = false
        // As the live view (TextViewerTextView.show): the extra line after a final newline has the first attributes.
        view.typingAttributes = text.attributes(at: 0, effectiveRange: nil)
        storage.setAttributedString(text)
        // Laid out once, from the top to the 1x height ceiling at most: past it the image is cut above it anyway.
        lm.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: column, height: CGFloat(maxHeight)), in: tc)
        let whole = lm.firstUnlaidCharacterIndex() >= storage.length
        let height = whole ? Double(lm.usedRect(for: tc).height + 2 * margin) : Double(maxHeight) + 1 + 2 * Double(margin)
        guard let plan = Self.plan(width: Double(column + 2 * margin), height: height, backing: Double(backing),
                              maxHeight: maxHeight, maxArea: maxArea) else { return .failed }
        let total = paragraphs(storage.string as NSString, NSRange(location: 0, length: storage.length))
        var rows = plan.height
        var lines: Int?
        if plan.cut {   // at 1x: a row is a point
            guard let cut = cutPoint(lm, tc, storage.string as NSString, below: CGFloat(plan.height) - 2 * margin) else { return .failed }
            lines = cut.lines
            let bottom = (cut.top + 2 * margin).rounded(.up)   // the line's top is layout output: checked before Int
            guard bottom.isFinite, bottom >= 1, bottom <= CGFloat(plan.height) else { return .failed }
            rows = Int(bottom)
            // What is below the cut is not drawn at all: the next line's top would show in the bottom margin.
            storage.deleteCharacters(in: NSRange(location: cut.character, length: storage.length - cut.character))
        }
        guard rows > 0, rows <= plan.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: plan.width, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .failed }   // a refused allocation lands here, never a trap
        let s = CGFloat(plan.scale)
        view.setFrameSize(NSSize(width: CGFloat(plan.width) / s, height: CGFloat(rows) / s))
        let stripRows = strip * plan.scale   // both checked above: at most 400,000
        func drawStrips() -> Bool {
            var top = 0
            while top < rows {
                let n = min(stripRows, rows - top)
                let rect = NSRect(x: 0, y: CGFloat(top) / s, width: CGFloat(plan.width) / s, height: CGFloat(n) / s)
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: plan.width, pixelsHigh: n, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0) else { return false }
                rep.size = rect.size
                view.cacheDisplay(in: rect, to: rep)
                guard let piece = rep.cgImage else { return false }
                // Core Graphics counts rows from the bottom.
                bitmap.draw(piece, in: CGRect(x: 0, y: rows - top - n, width: plan.width, height: n))
                top += n
            }
            return true
        }
        var drawn = false
        if let appearance { appearance.performAsCurrentDrawingAppearance { drawn = drawStrips() } } else { drawn = drawStrips() }
        guard drawn, let image = bitmap.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return .failed }
        return .image(Image(png: png, width: plan.width, height: rows, lines: lines, total: total))
    }

    /// The cut at 1x: the first character not drawn, the top of its line (container points) and the whole
    /// lines above it. The cut is at the start of the first line that does not fit whole; when not even
    /// line 1 fits, at the first line fragment that does not fit (the top of line 1 only). Nil when nothing fits.
    @MainActor
    static func cutPoint(_ lm: NSLayoutManager, _ tc: NSTextContainer, _ text: NSString, below y: CGFloat)
        -> (character: Int, top: CGFloat, lines: Int)? {
        guard y > 0, lm.numberOfGlyphs > 0 else { return nil }
        var fragment = NSRange()
        let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndex(for: NSPoint(x: 0, y: y), in: tc), effectiveRange: &fragment)
        let outGlyph = rect.maxY <= y ? NSMaxRange(fragment) : fragment.location
        guard outGlyph < lm.numberOfGlyphs else { return nil }
        let out = lm.characterIndexForGlyph(at: outGlyph)
        let start = text.paragraphRange(for: NSRange(location: out, length: 0)).location
        let lines = paragraphs(text, NSRange(location: 0, length: start))
        let character = lines > 0 ? start : out
        guard character > 0 else { return nil }
        let top = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: character), effectiveRange: nil).minY
        return (character, top, lines)
    }

    /// The lines of `text` in `range`: paragraphs, as the text view breaks them (LF, CR, CRLF, U+2029).
    static func paragraphs(_ text: NSString, _ range: NSRange) -> Int {
        var n = 0
        text.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    /// D15: ONE item, PNG data only, through the seam the caller passes (Pasteboard.general in the app).
    static func write(_ png: Data, to pb: NSPasteboard) {
        pb.clearContents()
        pb.setData(png, forType: .png)
    }

    /// Render, then write on success only (an empty document or a failure leaves the clipboard as it
    /// was); returns the notice to show.
    @MainActor
    static func copy(_ text: NSAttributedString, column: CGFloat, appearance: NSAppearance?, background: NSColor,
                     backing: CGFloat, to pb: NSPasteboard, maxHeight: Int = maxHeightPixels,
                     maxArea: Int = maxAreaPixels, strip: Int = stripPoints) -> String {
        switch render(text, column: column, appearance: appearance, background: background, backing: backing,
                      maxHeight: maxHeight, maxArea: maxArea, strip: strip) {
        case .empty: return emptyNotice
        case .failed: return failedNotice
        case .image(let image):
            write(image.png, to: pb)
            return image.lines.map { cutNotice(lines: $0, of: image.total) } ?? copiedNotice(width: image.width, height: image.height)
        }
    }
}
