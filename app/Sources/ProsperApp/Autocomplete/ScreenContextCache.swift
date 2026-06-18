import AppKit
import CoreGraphics

/// Throttled cache for the expensive screen-derived completion context: on-screen
/// OCR text and the caret-region background color.
///
/// Capturing a screenshot and running Vision OCR on *every* keystroke is the
/// dominant latency and CPU cost of inline completion — yet the surrounding
/// on-screen text barely changes between keystrokes. This caches the last capture
/// and refreshes it in the background at most once per `ttl`, so the completion
/// hot path reads a fresh-enough value instantly and never blocks on a capture.
/// The very first read (cold) returns nil and kicks off a refresh; subsequent
/// reads within `ttl` reuse the warm value.
@MainActor
final class ScreenContextCache {
    static let shared = ScreenContextCache()

    private var ocrText: String?
    private var ocrAt = Date.distantPast
    private var ocrConversation = false
    private var ocrRefreshing = false

    private var color: NSColor?
    private var colorAt = Date.distantPast
    private var colorRefreshing = false

    /// How long a capture stays fresh. Typing rarely changes the surrounding
    /// screen text meaningfully within a few seconds, so this trades a little
    /// staleness for a hot path that never waits on Vision/ScreenCaptureKit.
    private let ttl: TimeInterval = 4.0

    /// Most recent on-screen text near the caret, refreshing in the background
    /// when stale (or when the capture mode flips between conversation/inline).
    /// Never blocks: returns the cached (possibly stale, or nil on the first call)
    /// value immediately while a fresh capture runs off the hot path.
    func onScreenText(around caret: CGRect, conversation: Bool) -> String? {
        let stale = Date().timeIntervalSince(ocrAt) >= ttl
        if !ocrRefreshing, stale || conversation != ocrConversation {
            ocrRefreshing = true
            ocrConversation = conversation
            Task.detached { [caret, conversation] in
                let text = conversation
                    ? await VisionContext.conversationText(around: caret)
                    : await VisionContext.surroundingText(around: caret)
                await MainActor.run {
                    Self.shared.ocrText = text
                    Self.shared.ocrAt = Date()
                    Self.shared.ocrRefreshing = false
                }
            }
        }
        return ocrText
    }

    /// Most recent caret-region background color, refreshing in the background
    /// when stale. Only tints the ghost overlay, so a slightly late color is
    /// harmless. Never blocks.
    func backgroundColor(around caret: CGRect) -> NSColor? {
        if !colorRefreshing, Date().timeIntervalSince(colorAt) >= ttl {
            colorRefreshing = true
            Task.detached { [caret] in
                let c = await VisionContext.averageColorAroundCaret(caret)
                await MainActor.run {
                    if let c { Self.shared.color = c }
                    Self.shared.colorAt = Date()
                    Self.shared.colorRefreshing = false
                }
            }
        }
        return color
    }

    /// Drops cached context (e.g. on focus change) so the next completion captures
    /// fresh rather than reusing another field's surroundings.
    func invalidate() {
        ocrText = nil
        ocrAt = .distantPast
        color = nil
        colorAt = .distantPast
    }
}
