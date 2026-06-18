import AppKit
import ApplicationServices

/// A snapshot of the text around the caret of the focused UI element.
struct CaretContext {
    let textBefore: String
    let textAfter: String
    /// Caret rect in AppKit screen coords (bottom-left origin), or nil if the
    /// focused element does not expose parameterized bounds.
    let caretScreenRect: CGRect?
    /// Bounding rect of the focused text element in AppKit screen coords. Used to
    /// place the leading-edge indicator and as a fallback when the caret rect is
    /// unavailable.
    let fieldScreenRect: CGRect?
    /// True when the focused element looks like a browser address/search bar
    /// (omnibox): a single-line text field whose AX role/description/identifier
    /// reads as an address or URL field. Used to suppress completion in the
    /// address bar while still allowing it in page text fields.
    let isAddressBarLike: Bool
    /// The font in use at the caret (from the field's attributed text), or nil if
    /// the element doesn't expose it. The ghost overlay matches this so it reads as
    /// inline continuation of the user's text rather than a fixed system size.
    let caretFont: NSFont?
    /// True when the focused element is a single-line text field (AXTextField /
    /// AXComboBox / AXSearchField). Used by the tab-through-form heuristic: small
    /// single-line fields (logins, search boxes, spreadsheet cells) are where
    /// completions annoy more than help.
    let isSingleLineField: Bool
}

/// Reads caret / text context from the focused UI element via the Accessibility API.
enum AXCaret {

    /// Diagnostic logging for caret-geometry resolution, off by default. Enable with
    /// `defaults write com.prosper.app axDebug -bool true`; lines append to
    /// `~/Library/Logs/prosper-axdbg.log`.
    private static let debugEnabled = UserDefaults.standard.bool(forKey: "axDebug")
    private static let debugLogURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/prosper-axdbg.log")
    private static func dbg(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let line = "\(Date()) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: debugLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: debugLogURL)
        }
    }

    /// Returns the text before/after the caret and the caret's screen rect, or
    /// nil if the focused element does not expose usable text.
    static func currentContext() -> CaretContext? {
        let systemWide = AXUIElementCreateSystemWide()

        guard let focused = copyElement(systemWide, kAXFocusedUIElementAttribute) else {
            return nil
        }

        let textBefore: String
        let textAfter: String
        let clamped: Int
        // True on WebKit/Electron surfaces read via the text-marker APIs: there the
        // integer `clamped` offset is meaningless to the bounds-for-range query
        // (it would clamp to line start, planting the ghost at the line's left
        // edge), so the caret rect must come from the text markers directly.
        let preferMarker: Bool

        if let fullText = copyString(focused, kAXValueAttribute), !fullText.isEmpty {
            // Native AppKit / standard text: integer-offset AX value + selected range.
            let caretOffset = selectedRange(focused)?.location ?? fullText.utf16.count
            let utf16 = Array(fullText.utf16)
            clamped = max(0, min(caretOffset, utf16.count))
            let beforeUnits = Array(utf16[0..<clamped])
            let afterUnits = Array(utf16[clamped..<utf16.count])
            textBefore = String(utf16CodeUnits: beforeUnits, count: beforeUnits.count)
            textAfter = String(utf16CodeUnits: afterUnits, count: afterUnits.count)
            preferMarker = false
        } else if let marker = markerTextContext(focused) {
            // Electron/WebKit (Slack, Notion, VSCode, Chrome page fields) expose no
            // usable `kAXValue` for their contenteditable areas — the text lives
            // behind the WebKit text-marker APIs. Without this fallback the focused
            // element produced an empty/nil value and completion never fired there.
            // (This is how Cotypist reads Slack's message box.)
            textBefore = marker.before
            textAfter = marker.after
            // No integer offset in the marker world; keep the before-length for the
            // font probe only. The caret rect comes from the text markers directly
            // (preferMarker), since the integer bounds query mislocates here.
            clamped = (textBefore as NSString).length
            preferMarker = true
        } else {
            return nil
        }

        if debugEnabled {
            var names: CFArray?
            let nameList: String
            if AXUIElementCopyParameterizedAttributeNames(focused, &names) == .success,
               let names = names as? [String] {
                nameList = names.joined(separator: ",")
            } else {
                nameList = "<unavailable>"
            }
            dbg("ctx role=\(copyString(focused, kAXRoleAttribute) ?? "?") preferMarker=\(preferMarker) paramAttrs=[\(nameList)]")
        }

        // "Effectively at end": only trailing whitespace/newlines follow the caret
        // (Chromium contenteditables keep a trailing "\n" after the caret). Gates the
        // doc-end marker fallback, which is only correct for an end-of-text caret.
        let caretAtEnd = textAfter
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let rect = caretRect(
            focused, offset: clamped, preferMarker: preferMarker, caretAtEnd: caretAtEnd
        ).map(flippedToAppKit)
        let field = elementRect(focused).map(flippedToAppKit)
        let totalLength = clamped + (textAfter as NSString).length
        // WebKit/Electron fields don't expose `kAXAttributedStringForRange`, so the
        // glyph font is unknown; fall back to a size derived from the caret rect's
        // height (≈ line height) so the ghost matches the field's text size instead
        // of an oversized system default.
        let font = caretFont(focused, offset: clamped, textCount: totalLength)
            ?? rect.flatMap { fontForCaretHeight($0.height) }

        let role = copyString(focused, kAXRoleAttribute) ?? ""
        let singleLineRoles: Set<String> = [kAXTextFieldRole as String, "AXComboBox", "AXSearchField"]

        return CaretContext(
            textBefore: textBefore,
            textAfter: textAfter,
            caretScreenRect: rect,
            fieldScreenRect: field,
            isAddressBarLike: addressBarLike(focused),
            caretFont: font,
            isSingleLineField: singleLineRoles.contains(role)
        )
    }

    /// The font applied at the caret, read from the field's attributed text. Queries
    /// the character just before the caret (or just after, at the start), since a
    /// zero-length range carries no attributes. Returns nil when the element doesn't
    /// support `kAXAttributedStringForRange` (most WebKit/Electron fields), in which
    /// case the overlay falls back to its default system font.
    private static func caretFont(_ element: AXUIElement, offset: Int, textCount: Int) -> NSFont? {
        let probe = offset > 0 ? offset - 1 : (textCount > 0 ? 0 : -1)
        guard probe >= 0 else { return nil }
        var range = CFRange(location: probe, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &out
        )
        guard result == .success, let out,
              CFGetTypeID(out) == CFAttributedStringGetTypeID() else { return nil }
        let attr = out as! NSAttributedString
        guard attr.length > 0 else { return nil }
        let attrs = attr.attributes(at: 0, effectiveRange: nil)
        if let font = attrs[.font] as? NSFont { return font }
        // AppKit apps (TextEdit, Notes, Mail) report the font as an "AXFont"
        // dictionary — {AXFontName, AXFontFamily, AXFontSize} — not as an NSFont
        // under .font. Rebuild the NSFont from it, or the overlay falls through to
        // the caret-height heuristic and renders the ghost at the wrong size.
        if let dict = attrs[NSAttributedString.Key("AXFont")] as? [String: Any],
           let size = (dict["AXFontSize"] as? NSNumber).map({ CGFloat(truncating: $0) }),
           size > 1 {
            if let name = dict["AXFontName"] as? String, let font = NSFont(name: name, size: size) {
                return font
            }
            if let family = dict["AXFontFamily"] as? String,
               let font = NSFontManager.shared.font(
                   withFamily: family, traits: [], weight: 5, size: size
               ) {
                return font
            }
            return .systemFont(ofSize: size)
        }
        return nil
    }

    /// Heuristic: does the focused element look like a browser omnibox? Chromium
    /// browsers expose `AXDescription` "Address and search bar"; Firefox uses the
    /// `urlbar-input` identifier; Safari's unified field reads as an address/search
    /// text field. Match on role == AXTextField plus an address/search/url token in
    /// description / identifier / title / role-description / placeholder. The caller
    /// only honours this when the frontmost app is a known browser, so a false
    /// positive in a non-browser app cannot suppress completion there.
    private static func addressBarLike(_ element: AXUIElement) -> Bool {
        let role = copyString(element, kAXRoleAttribute) ?? ""
        guard role == (kAXTextFieldRole as String) || role == "AXComboBox" else { return false }
        let hints = [
            copyString(element, kAXDescriptionAttribute),
            copyString(element, kAXIdentifierAttribute),
            copyString(element, kAXTitleAttribute),
            copyString(element, kAXRoleDescriptionAttribute),
            copyString(element, kAXPlaceholderValueAttribute),
        ].compactMap { $0?.lowercased() }
        let tokens = ["address", "search", "url", "omnibox", "location bar"]
        return hints.contains { hint in tokens.contains { hint.contains($0) } }
    }

    /// Converts an Accessibility rect (global screen coords, TOP-LEFT origin,
    /// y growing downward) into AppKit screen coords (BOTTOM-LEFT origin, y
    /// growing upward) used by NSWindow/NSPanel. Without this the ghost overlay
    /// is placed mirrored vertically — usually far off-screen, so nothing shows.
    private static func flippedToAppKit(_ rect: CGRect) -> CGRect {
        // The primary display (screens[0], frame origin = (0,0)) defines the
        // global flip; its height is the mirror axis.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// The focused element's bounding rect (position + size) in AX (flipped)
    /// coords, or nil.
    private static func elementRect(_ element: AXUIElement) -> CGRect? {
        guard let origin = copyPoint(element, kAXPositionAttribute),
              let size = copySize(element, kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - AX helpers

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        )
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    /// Returns the screen rect of the caret using the parameterized
    /// bounds-for-range attribute.
    ///
    /// A zero-length range at the caret is the natural query, and AppKit text
    /// views answer it with a real (zero-width) caret rect. WebKit / Electron
    /// surfaces (Slack, Chrome, etc.) instead return an empty `(0,0,0,0)` rect for
    /// a zero-length range — but they DO report bounds for a non-empty range. So
    /// when the primary query is unusable, fall back to the PREVIOUS character's
    /// bounds and take its trailing edge as the caret position (the technique
    /// Cotypist labels `cursorRectIsFromPreviousCharacter`).
    ///
    /// Pure Chromium/Electron text areas (Slack, Notion, VSCode) answer NEITHER
    /// integer-range query — they expose caret geometry only through the WebKit
    /// text-marker APIs. So as a final fallback we read `AXSelectedTextMarkerRange`
    /// and ask for `AXBoundsForTextMarkerRange`, which returns a real caret rect in
    /// those surfaces. (This is how Cotypist positions correctly in Slack.)
    private static func caretRect(
        _ element: AXUIElement, offset: Int, preferMarker: Bool, caretAtEnd: Bool
    ) -> CGRect? {
        // Marker surfaces (Slack et al.): the integer offset doesn't address their
        // text, so the integer bounds query returns a line-start rect. Go straight
        // to the text-marker caret geometry, which is the authoritative position.
        if preferMarker {
            let marker = markerCaretRect(element, caretAtEnd: caretAtEnd)
            dbg("caretRect preferMarker → \(marker.map(String.init(describing:)) ?? "nil")")
            if let marker, usable(marker) { return marker }
        }
        let zero = boundsForRange(element, location: offset, length: 0)
        dbg("caretRect boundsForRange(\(offset),0) → \(zero.map(String.init(describing:)) ?? "nil")")
        if let r = zero, usable(r) {
            return r
        }
        if offset > 0 {
            let prev = boundsForRange(element, location: offset - 1, length: 1)
            dbg("caretRect boundsForRange(\(offset - 1),1) → \(prev.map(String.init(describing:)) ?? "nil")")
            if let prev, usable(prev) {
                // Caret sits flush after the previous glyph: a zero-width box at its
                // trailing edge, on the same line.
                return CGRect(x: prev.maxX, y: prev.origin.y, width: 0, height: prev.height)
            }
        }
        if !preferMarker,
           let marker = markerCaretRect(element, caretAtEnd: caretAtEnd), usable(marker) {
            return marker
        }
        dbg("caretRect → nil (all paths failed)")
        return nil
    }

    /// Approximates the field's glyph font from the caret rect's height when the
    /// element exposes no attributed-string font (WebKit/Electron). A caret box's
    /// height tracks the line height, which is ≈ 1.35× the point size for typical
    /// UI fonts; dividing yields a size close to the real text so the ghost neither
    /// dwarfs nor undershoots it. Clamped to a sane range.
    private static func fontForCaretHeight(_ height: CGFloat) -> NSFont? {
        guard height > 1 else { return nil }
        let size = min(max(height / 1.35, 11), 24)
        return .systemFont(ofSize: size)
    }

    /// Caret rect from the WebKit/Chromium text-marker APIs, for Electron/web text
    /// areas (Slack, Notion, VSCode, Chrome page fields) where integer-range
    /// `kAXBoundsForRange` returns `(0,0,0,0)`.
    ///
    /// `AXSelectedTextMarkerRange` / `AXBoundsForTextMarkerRange` are stable but
    /// undocumented attributes (not in the public headers), so they're referenced
    /// by string. The text-marker-range value is an opaque CFType — we never decode
    /// it, just hand it straight back as the parameter to the bounds query. Returns
    /// nil on any app that doesn't implement these (e.g. native AppKit fields).
    private static func markerCaretRect(_ element: AXUIElement, caretAtEnd: Bool) -> CGRect? {
        let selectedMarkerRange = "AXSelectedTextMarkerRange" as CFString
        let boundsForMarkerRange = "AXBoundsForTextMarkerRange" as CFString
        let startForRange = "AXStartTextMarkerForTextMarkerRange" as CFString
        let prevForMarker = "AXPreviousTextMarkerForTextMarker" as CFString
        let rangeForMarkers = "AXTextMarkerRangeForUnorderedTextMarkers" as CFString
        let docEndMarker = "AXEndTextMarker" as CFString

        func attr(_ name: CFString) -> CFTypeRef? {
            var out: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name, &out) == .success else { return nil }
            return out
        }
        func param(_ name: CFString, _ arg: CFTypeRef) -> CFTypeRef? {
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name, arg, &out) == .success
            else { return nil }
            return out
        }
        func rect(ofRange markerRange: CFTypeRef) -> CGRect? {
            guard let boundsRef = param(boundsForMarkerRange, markerRange),
                  CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
            let axValue = boundsRef as! AXValue
            guard AXValueGetType(axValue) == .cgRect else { return nil }
            var r = CGRect.zero
            guard AXValueGetValue(axValue, .cgRect, &r) else { return nil }
            return r
        }

        guard let selRange = attr(selectedMarkerRange) else {
            dbg("marker: AXSelectedTextMarkerRange unavailable")
            return nil
        }

        // Marker bounds are TRUE glyph boxes (WebKit/Chromium), while the rest of the
        // pipeline speaks the AppKit caret-box convention — a box sitting one height
        // ABOVE the glyph line (`ghostLineCenterY` derives the line center as
        // `minY - height/2`). Normalize here, at the source, so every consumer keeps
        // a single convention. In AX coords (top-left origin, y down) "one height up"
        // is `y - height`. In a TIGHT field the heuristic's in-field check used to
        // rescue the raw glyph box (corrected center fell outside → true center won);
        // in a TALL field (Slack composer) the wrongly-corrected center stayed inside
        // and the ghost rendered a full line low — normalizing fixes both.
        func appKitCaretConvention(_ r: CGRect) -> CGRect {
            CGRect(x: r.origin.x, y: r.origin.y - r.height, width: r.width, height: r.height)
        }

        // The collapsed caret range: AppKit/WebKit text views answer it with a real
        // (zero-width) caret rect.
        let selBounds = rect(ofRange: selRange)
        dbg("marker: bounds(selRange) → \(selBounds.map(String.init(describing:)) ?? "nil")")
        if let r = selBounds, usable(r) { return appKitCaretConvention(r) }

        // Slack/Chromium return a degenerate rect for a collapsed range. Fall back to
        // the PREVIOUS character's bounds and take its trailing edge as the caret —
        // the marker-world analogue of the integer `cursorRectIsFromPreviousCharacter`
        // path. Without this the caret rect is unusable and the ghost collapses to the
        // line's left edge.
        //
        // The previous character's range needs a marker AT the caret. WebKit extracts
        // it from the selected range via `AXStartTextMarkerForTextMarkerRange`;
        // Chromium does NOT implement that attribute, so when the caret is at the end
        // of the text (the live-typing case) substitute the document-end marker
        // (`AXEndTextMarker`), which Chromium does expose.
        func trailingEdgeOfCharBefore(_ marker: CFTypeRef) -> CGRect? {
            guard let prev = param(prevForMarker, marker) else {
                dbg("marker: AXPreviousTextMarkerForTextMarker failed")
                return nil
            }
            let markers = [prev, marker] as CFArray
            guard let prevRange = param(rangeForMarkers, markers) else {
                dbg("marker: AXTextMarkerRangeForUnorderedTextMarkers failed")
                return nil
            }
            let prevBounds = rect(ofRange: prevRange)
            dbg("marker: bounds(prevChar) → \(prevBounds.map(String.init(describing:)) ?? "nil")")
            guard let r = prevBounds, usable(r) else { return nil }
            return appKitCaretConvention(
                CGRect(x: r.maxX, y: r.origin.y, width: 0, height: r.height)
            )
        }

        if let caretStart = param(startForRange, selRange) {
            return trailingEdgeOfCharBefore(caretStart)
        }
        dbg("marker: AXStartTextMarkerForTextMarkerRange failed (Chromium)")
        if caretAtEnd, let docEnd = attr(docEndMarker) {
            dbg("marker: trying doc-end fallback")
            return trailingEdgeOfCharBefore(docEnd)
        }
        return nil
    }

    /// Text before/after the caret via the WebKit/Chromium text-marker APIs, for
    /// Electron/web text areas (Slack, Notion, VSCode, Chrome page fields) that
    /// expose no usable `kAXValue`. Mirrors `markerCaretRect`: the attributes are
    /// stable but undocumented (referenced by string), and the marker values are
    /// opaque CFTypes we only ever pass back as parameters. Returns nil on any app
    /// that doesn't implement these (native AppKit fields, which use the AX-value
    /// path instead).
    private static func markerTextContext(_ element: AXUIElement) -> (before: String, after: String)? {
        let selectedMarkerRange = "AXSelectedTextMarkerRange" as CFString
        let docStartMarker = "AXStartTextMarker" as CFString
        let docEndMarker = "AXEndTextMarker" as CFString
        let stringForRange = "AXStringForTextMarkerRange" as CFString
        let startForRange = "AXStartTextMarkerForTextMarkerRange" as CFString
        let endForRange = "AXEndTextMarkerForTextMarkerRange" as CFString
        let rangeForMarkers = "AXTextMarkerRangeForUnorderedTextMarkers" as CFString

        func attr(_ name: CFString) -> CFTypeRef? {
            var out: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name, &out) == .success else { return nil }
            return out
        }
        func param(_ name: CFString, _ argument: CFTypeRef) -> CFTypeRef? {
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name, argument, &out) == .success
            else { return nil }
            return out
        }

        // Caret = the (usually collapsed) selected marker range; document bounds.
        guard let selRange = attr(selectedMarkerRange),
              let docStart = attr(docStartMarker),
              let docEnd = attr(docEndMarker),
              let caretStart = param(startForRange, selRange),
              let caretEnd = param(endForRange, selRange) else { return nil }

        func text(from a: CFTypeRef, to b: CFTypeRef) -> String? {
            let markers = [a, b] as CFArray
            guard let range = param(rangeForMarkers, markers),
                  let raw = param(stringForRange, range),
                  CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
            return (raw as! CFString) as String
        }

        let before = text(from: docStart, to: caretStart)
        let after = text(from: caretEnd, to: docEnd)
        // Need at least the before-text to be meaningful; an empty field yields "".
        guard before != nil || after != nil else { return nil }
        return (before ?? "", after ?? "")
    }

    /// A caret rect is usable only if it has real vertical extent; WebKit/Electron
    /// report `(0,0,0,0)` for zero-length ranges, which must be rejected.
    private static func usable(_ rect: CGRect) -> Bool {
        rect.height > 0
    }

    /// Raw `kAXBoundsForRange` query for an arbitrary character range, or nil if
    /// the element does not support the parameterized attribute.
    private static func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

        var bounds: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &bounds
        )
        guard result == .success, let bounds else { return nil }
        guard CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        let axValue = bounds as! AXValue
        guard AXValueGetType(axValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }
}
