import AppKit

/// Small floating accessory button shown near the active text field, giving
/// quick access to Prosper (opens the command runner). Off by default; enabled
/// via Settings → General. Non-activating so it never steals focus.
@MainActor
final class AccessoryButton {

    /// Visual state of the indicator — the user-facing signal of what Prosper is
    /// doing in the focused field (Cotypist-parity: the per-field icon is the
    /// "am I active here, and is anything happening?" affordance).
    enum State {
        /// Field supported, nothing in flight and no ghost on screen (fresh
        /// focus, suggestion accepted/dismissed, Esc-suppressed). Normal glyph.
        case idle
        /// A completion request is in flight (loading). Glyph pulses gently.
        case thinking
        /// Success: ghost text is ready and visible at the caret. Green glyph.
        case ready
        /// Something went wrong — the model produced nothing even after the
        /// retry/reprompt ladder, so no ghost text should be expected for this
        /// keystroke. Orange exclamation glyph.
        case error
        /// Completions impossible here (macOS Secure Input engaged, e.g. a
        /// password field or a password manager holding the input). Lock glyph.
        case blocked
    }

    private let panel: NSPanel
    private let button: NSButton
    private var pulseTimer: Timer?
    private(set) var state: State = .idle

    /// Invoked when the button is clicked.
    var onClick: (() -> Void)?

    /// Whether the indicator panel is on screen. Used by the engine's mouse-down
    /// dismissal to exempt clicks landing on the button itself.
    var isVisible: Bool { panel.isVisible }

    /// The indicator's current frame in AppKit screen coords (matches
    /// `NSEvent.mouseLocation`).
    var screenFrame: CGRect { panel.frame }

    init() {
        let frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        button = NSButton(frame: frame)
        // Unobtrusive attribution mark: a small template glyph, no bezel, reduced
        // opacity — reads as a quiet presence indicator, not clickable chrome.
        button.bezelStyle = .regularSquare
        button.isBordered = false
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Prosper")?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.imagePosition = .imageOnly
        button.alphaValue = 0.5

        let container = NSView(frame: frame)
        button.autoresizingMask = [.width, .height]
        container.addSubview(button)
        panel.contentView = container

        button.target = self
        button.action = #selector(clicked)
    }

    /// Positions the button just left of the caret rect (in AppKit screen coords).
    func show(at caretRect: CGRect) {
        let size: CGFloat = 20
        let origin = CGPoint(x: caretRect.minX - size - 6, y: caretRect.minY)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
        panel.orderFrontRegardless()
    }

    /// Cotypist-style indicator: a small icon pinned just outside the leading
    /// (left) edge of a focused text field, on the line the user is typing. Both
    /// rects are in AppKit screen coords (bottom-left origin). Signals "Prosper can
    /// complete here" even before the ghost text appears.
    ///
    /// The vertical position tracks the caret line when a caret rect is known —
    /// centering on `fieldRect.midY` is wrong for multi-line views (e.g. a TextEdit
    /// document), where the field's geometric center sits far below the caret and
    /// the icon would float in the middle of the page. Falls back to the field's
    /// top line when no caret rect is available.
    func showIndicator(atField fieldRect: CGRect, caretRect: CGRect? = nil) {
        // Panel/hit-box size. The glyph stays 12pt — the extra points are click
        // padding (a 14pt target was too fiddly to hit).
        let size: CGFloat = 20
        // Sit to the LEFT of the field so the icon never overlaps the text. Clamp
        // to the screen's left edge so it can't be pushed off-screen when the field
        // hugs the display edge.
        let screenLeft = NSScreen.screens
            .first(where: { $0.frame.intersects(fieldRect) })?
            .visibleFrame.minX
            ?? NSScreen.main?.visibleFrame.minX ?? 0
        let x = max(screenLeft + 1, fieldRect.minX - size - 3)
        // Vertical line center. When a caret rect is known, align to the actual
        // glyph line: AppKit text views report a caret box ~half a line-height
        // above the rendered text, so the true line center is `minY - height/2`
        // (see SuggestionWindow.show). Without a caret rect, fall back to the
        // field's top line.
        let lineCenterY: CGFloat
        if let caretRect {
            // Toolkit-aware line center, validated against the field bounds —
            // same resolution the ghost overlay uses (see `ghostLineCenterY`).
            lineCenterY = AutocompleteEngine.ghostLineCenterY(caret: caretRect, field: fieldRect)
        } else {
            lineCenterY = fieldRect.maxY - size / 2
        }
        let y = lineCenterY - size / 2
        panel.setFrame(NSRect(x: x, y: y, width: size, height: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        setState(.idle)
        panel.orderOut(nil)
    }

    /// Updates the indicator's visual state. Cheap and idempotent — callable on
    /// every request lifecycle event even when the panel is hidden.
    func setState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        pulseTimer?.invalidate()
        pulseTimer = nil

        switch newState {
        case .idle:
            applySymbol("character.bubble")
            button.alphaValue = 0.5
        case .thinking:
            applySymbol("character.bubble")
            button.alphaValue = 0.5
            startPulse()
        case .ready:
            applySymbol("character.bubble", tint: .systemGreen)
            button.alphaValue = 0.9
        case .error:
            applySymbol("exclamationmark.bubble", tint: .systemOrange)
            button.alphaValue = 0.9
        case .blocked:
            applySymbol("lock.fill")
            button.alphaValue = 0.6
        }
    }

    private func applySymbol(_ name: String, tint: NSColor? = nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Prosper")?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        // Template images take the button's content tint: nil restores the
        // system's neutral label color for the monochrome states.
        button.contentTintColor = tint
    }

    /// Gentle opacity pulse while a completion request is in flight. Timer-driven
    /// sine wave (no Core Animation: the borderless panel's content view is not
    /// layer-backed, and a 12 Hz alpha tick on one tiny view is negligible).
    private func startPulse() {
        var phase: Double = 0
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .thinking else { return }
                phase += 0.18
                // Oscillate 0.25...0.75 around the idle 0.5.
                self.button.alphaValue = 0.5 + 0.25 * CGFloat(sin(phase))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    @objc private func clicked() {
        onClick?()
    }
}
