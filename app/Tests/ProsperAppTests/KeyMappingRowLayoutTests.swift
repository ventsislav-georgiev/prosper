import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import ProsperApp

/// #868 — #859's `sizeThatFits` also resized the two key-rule recorders (the
/// trigger and the remap target, both `.frame(width: sz(96), height: sz(24))
/// .fixedSize()`): they went from the fixed 110 pt intrinsic width, overflowing
/// the 96 slot by 7 pt each side, to 96 x scale. This pins that width and checks
/// the combo label still fits inside the narrower field at every UI scale.
///
/// Hosted offscreen: the window is never ordered front or made key.
@MainActor
final class KeyMappingRowLayoutTests: XCTestCase {
    /// #1064: every offscreen window a test makes is closed in tearDown (44 per class run
    /// were never closed). Closed only: never ordered front or made key.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private func window(_ rect: NSRect, backing: CGFloat?) -> FixedBackingWindow {
        let w = FixedBackingWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.fixedBacking = backing
        windows.append(w)
        return w
    }

    private func all<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] {
        var out: [T] = []
        if let x = v as? T { out.append(x) }
        for s in v.subviews { out += all(s, t) }
        return out
    }

    private func flush(_ v: NSView) {
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
    }

    /// A remap rule shows both recorders: the trigger and the target.
    private func checkRow(trigger: String, target: String, scale: CGFloat, backing: CGFloat?,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = ThemeRuntime.scale
        ThemeRuntime.scale = scale
        defer { ThemeRuntime.scale = saved }

        var rule = ShortcutRulesStore.Rule()
        rule.trigger = trigger
        rule.action = .remap
        rule.target = target
        let side = CGSize(width: 660, height: 60)
        let host = NSHostingView(rootView: KeyMappingRow(model: SettingsModel(), rule: rule)
            .frame(width: side.width, height: side.height))
        host.frame = CGRect(origin: .zero, size: side)
        let win = window(host.frame, backing: backing)
        win.contentView = host
        defer { win.contentView = NSView() }
        flush(host)

        let tag = "scale \(scale), backing \(win.backingScaleFactor), \(trigger.isEmpty ? "unset" : trigger) -> \(target.isEmpty ? "unset" : target)"
        // SwiftUI snaps each edge to the backing pixel grid: one pixel of slack, no more.
        let pixel = 1 / win.backingScaleFactor
        let recorders = all(host, RecorderView.self).filter { !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX }
        XCTAssertEqual(recorders.count, 2, "trigger + target recorders at \(tag)", file: file, line: line)
        let frames = recorders.map { $0.convert($0.bounds, to: host) }
        for (r, f) in zip(recorders, frames) {
            XCTAssertEqual(f.width, sz(96), accuracy: pixel,
                           "key-rule recorder overflows its sz(96) slot at \(tag): \(f)", file: file, line: line)
            XCTAssertEqual(f.height, sz(24), accuracy: pixel,
                           "key-rule recorder overflows its sz(24) slot at \(tag): \(f)", file: file, line: line)
            XCTAssertTrue(host.bounds.insetBy(dx: -pixel, dy: -pixel).contains(f),
                          "key-rule recorder leaves its row at \(tag): \(f) in \(host.bounds)", file: file, line: line)
            // The combo label: centred, unconstrained, so wider than the field = clipped.
            let label = try XCTUnwrap(all(r, NSTextField.self).first, file: file, line: line)
            XCTAssertLessThanOrEqual(label.fittingSize.width, r.bounds.width + pixel,
                                     "label '\(label.stringValue)' clipped at \(tag): \(label.fittingSize) in \(r.bounds)",
                                     file: file, line: line)
            XCTAssertGreaterThanOrEqual(label.frame.minX, -pixel, "label cut left at \(tag)", file: file, line: line)
            XCTAssertLessThanOrEqual(label.frame.maxX, r.bounds.width + pixel, "label cut right at \(tag)", file: file, line: line)
            assertCentred(label, in: r, tolerance: 0.5 + pixel, tag, file: file, line: line)
        }
        if frames.count == 2 {
            XCTAssertLessThanOrEqual(frames[0].maxX, frames[1].minX,
                                     "trigger and target recorders overlap at \(tag): \(frames)", file: file, line: line)
        }
    }

    /// Centred to half a point of rounding plus one backing pixel.
    private func assertCentred(_ label: NSTextField, in r: NSView, tolerance: CGFloat, _ tag: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(label.frame.midX, r.bounds.midX, accuracy: tolerance,
                       "label not centred horizontally at \(tag): \(label.frame) in \(r.bounds)", file: file, line: line)
        XCTAssertEqual(label.frame.midY, r.bounds.midY, accuracy: tolerance,
                       "label not centred vertically at \(tag): \(label.frame) in \(r.bounds)", file: file, line: line)
    }

    /// RunnerPanel's "Assign Shortcut…" accessory builds the recorder by frame, no SwiftUI.
    /// The label is centred there too, at its fitting size, and follows a new combo
    /// (`refreshTitle` must mark the view for layout: nothing else re-centres it).
    func testFrameHostedRecorderCentresItsLabelAndFollowsANewCombo() throws {
        let r = RecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        r.combo = unsetKeyCombo
        r.refreshTitle()
        r.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(all(r, NSTextField.self).first)
        XCTAssertEqual(label.stringValue, "Unset")
        XCTAssertEqual(label.frame.size, label.fittingSize, "label not at its fitting size: \(label.frame)")
        assertCentred(label, in: r, tolerance: 1, "frame-hosted, Unset")
        let short = label.frame.width

        r.combo = try XCTUnwrap(KeyCombo.parse("ctrl+alt+shift+cmd+space"))
        r.refreshTitle()
        r.layoutSubtreeIfNeeded()
        XCTAssertEqual(label.stringValue, "⌃⌥⇧⌘Space")
        XCTAssertGreaterThan(label.fittingSize.width, short)
        XCTAssertEqual(label.frame.size, label.fittingSize, "label kept the old size after a new combo: \(label.frame)")
        assertCentred(label, in: r, tolerance: 1, "frame-hosted, after a new combo")
    }

    func testKeyRuleRecordersFitTheirSlotAtEveryScale() throws {
        // nil: this machine's own backing scale; 1: CI's non-Retina grid.
        for backing in [nil, 1] as [CGFloat?] {
            for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                // Every modifier plus F12 / Space (86 pt at 1.0). The labels wider than the slot
                // (#876) are covered by testEveryRecorderLabelFitsTheKeyRuleField.
                try checkRow(trigger: "ctrl+alt+shift+cmd+f12", target: "ctrl+alt+shift+cmd+space",
                             scale: scale, backing: backing)
                // A fresh rule: both fields read "Unset".
                try checkRow(trigger: "", target: "", scale: scale, backing: backing)
            }
        }
    }

    // MARK: - #876: labels wider than the field shrink to fit

    /// What the recorder can show: "Unset", "Press keys…" (while recording) and the
    /// label of every key code a keyboard sends, each with all four modifiers. The key
    /// names come from `KeyCombo.label`: glyphs, `codeToName` uppercased, else "Key<n>".
    private static func everyLabel() -> [(text: String, combo: KeyCombo?)] {
        let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        var seen: Set<String> = []
        var out: [(text: String, combo: KeyCombo?)] = [("Unset", unsetKeyCombo), ("Press keys…", nil)]
        for code in 0..<128 {
            let combo = KeyCombo(keyCode: UInt32(code), carbonModifiers: mods, display: "")
            if seen.insert(combo.label).inserted { out.append((combo.label, combo)) }
        }
        return out
    }

    /// Shows `text` the way the recorder would. A nil combo is the recording state, set
    /// directly: beginRecording would install an event monitor and take first responder.
    private func show(_ item: (text: String, combo: KeyCombo?), in r: RecorderView, _ label: NSTextField) {
        if let combo = item.combo {
            r.recording = false
            r.combo = combo
            r.refreshTitle()
        } else {
            r.recording = true
        }
        r.layoutSubtreeIfNeeded()
    }

    /// The label lies inside the field (one backing pixel of slack), centred, at its
    /// fitting size, its origin on whole points (#868 rounds it; whole points are whole
    /// pixels at backing 1 and 2).
    private func assertFits(_ label: NSTextField, in r: RecorderView, pixel: CGFloat, _ tag: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let f = label.frame
        XCTAssertTrue(r.bounds.insetBy(dx: -pixel, dy: -pixel).contains(f),
                      "'\(label.stringValue)' outside the field at \(tag): \(f) in \(r.bounds)", file: file, line: line)
        XCTAssertEqual(f.size, label.fittingSize, "'\(label.stringValue)' not at its fitting size at \(tag)", file: file, line: line)
        XCTAssertEqual(f.minX, f.minX.rounded(), accuracy: 0.01, "label x off whole points at \(tag): \(f)", file: file, line: line)
        XCTAssertEqual(f.minY, f.minY.rounded(), accuracy: 0.01, "label y off whole points at \(tag): \(f)", file: file, line: line)
        assertCentred(label, in: r, tolerance: 0.5 + pixel, "\(tag), \(label.stringValue)", file: file, line: line)
    }

    /// #880: the size rule as a property, not today's SF metrics. A label whose full-size
    /// width fits the field keeps the full size; one that does not is shrunk (and
    /// `assertFits` has already checked it fits), and shrunk no further than needed: one
    /// step larger (the product's 0.25 pt step) would not fit, unless it sits at the 1 pt
    /// floor. Widths are measured on the shown label (same weight and design, only the size
    /// changed) and its font put back, so another macOS's font metrics move both sides.
    private func assertFullSizeWhenItFits(_ label: NSTextField, in r: RecorderView, full: CGFloat, _ tag: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        guard let shown = label.font else { return XCTFail("no font at \(tag)", file: file, line: line) }
        func width(at size: CGFloat) -> CGFloat {
            label.font = NSFont(descriptor: shown.fontDescriptor, size: size)
            defer { label.font = shown }
            return label.fittingSize.width
        }
        let fullWidth = width(at: full)
        let pt = shown.pointSize
        if fullWidth <= r.bounds.width {
            XCTAssertEqual(pt, full, "'\(label.stringValue)' shrank though it fits at full size at \(tag): \(fullWidth) in \(r.bounds.width)",
                           file: file, line: line)
        } else {
            XCTAssertLessThan(pt, full, "'\(label.stringValue)' not shrunk at \(tag): \(fullWidth) in \(r.bounds.width)",
                              file: file, line: line)
            if pt > 1 {
                let stepUp = width(at: pt + 0.25)
                XCTAssertGreaterThan(stepUp, r.bounds.width,
                                     "'\(label.stringValue)' over-shrunk at \(tag): \(pt + 0.25) pt is \(stepUp) wide and fits \(r.bounds.width)",
                                     file: file, line: line)
            }
        }
    }

    /// The Key Remapping row's target recorder, hosted offscreen at `scale`.
    private func withKeyRuleRecorder(scale: CGFloat, backing: CGFloat?,
                                     _ body: (RecorderView, NSTextField, CGFloat, String) throws -> Void) throws {
        let saved = ThemeRuntime.scale
        ThemeRuntime.scale = scale
        defer { ThemeRuntime.scale = saved }

        var rule = ShortcutRulesStore.Rule()
        rule.action = .remap
        let side = CGSize(width: 660, height: 60)
        let host = NSHostingView(rootView: KeyMappingRow(model: SettingsModel(), rule: rule)
            .frame(width: side.width, height: side.height))
        host.frame = CGRect(origin: .zero, size: side)
        let win = window(host.frame, backing: backing)
        win.contentView = host
        defer { win.contentView = NSView() }
        flush(host)

        let r = try XCTUnwrap(all(host, RecorderView.self).filter { !$0.isHiddenOrHasHiddenAncestor }.last)
        XCTAssertEqual(r.bounds.width, sz(96), accuracy: 1 / win.backingScaleFactor)
        let label = try XCTUnwrap(all(r, NSTextField.self).first)
        try body(r, label, 1 / win.backingScaleFactor, "scale \(scale), backing \(win.backingScaleFactor)")
    }

    /// ⌃⌥⇧⌘PAGEDOWN was 120 pt at 12 pt: cut at both ends of the 96 pt key-rule field.
    /// Page Up / Page Down now draw as ⇞ ⇟. Every label lies inside the field (one
    /// backing pixel, backing 1 and 2), never above 12 pt x scale, and keeps that full
    /// size whenever it fits at it (#880: no pinned font metrics).
    func testEveryRecorderLabelFitsTheKeyRuleField() throws {
        let labels = Self.everyLabel()
        XCTAssertTrue(labels.contains { $0.text == "⌃⌥⇧⌘⇟" } && labels.contains { $0.text == "⌃⌥⇧⌘⇞" },
                      "the enumeration lost the page keys: \(labels.map(\.text))")
        for backing in [1, 2] as [CGFloat] {
            for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                try withKeyRuleRecorder(scale: scale, backing: backing) { r, label, pixel, tag in
                    for item in labels {
                        show(item, in: r, label)
                        XCTAssertEqual(label.stringValue, item.text)
                        assertFits(label, in: r, pixel: pixel, tag)
                        let pt = try XCTUnwrap(label.font?.pointSize)
                        XCTAssertLessThanOrEqual(pt, 12 * scale, "'\(item.text)' grew at \(tag)")
                        assertFullSizeWhenItFits(label, in: r, full: 12 * scale, tag)
                    }
                    r.recording = false
                }
            }
        }
    }

    /// Settings > Shortcuts (All Actions) hosts the same recorder in a sz(142) slot: the
    /// widest label of all, a four-modifier "Key<n>" fallback, fits there, at full size
    /// whenever it fits at full size.
    func testAllActionsRecorderFitsTheWidestLabel() throws {
        let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        // #890: 104 (JIS Kana) is named now; 108 is a code no key sends, still "Key108",
        // and the widest label the #890 measurement found.
        let widest = KeyCombo(keyCode: 108, carbonModifiers: mods, display: "")
        for backing in [1, 2] as [CGFloat] {
            for scale in [1.0, 0.85, 0.7] as [CGFloat] {
                let saved = ThemeRuntime.scale
                ThemeRuntime.scale = scale
                defer { ThemeRuntime.scale = saved }

                let action = BindableAction(kind: .prosper, key: "fake", title: "Fake Action", category: "Prosper",
                                            icon: "command", combo: widest)
                let side = CGSize(width: 560, height: 40)
                let host = NSHostingView(rootView: ShortcutCatalogRow(action: action, onRecord: { _ in },
                                                                      onReset: {}, onClear: {})
                    .frame(width: side.width, height: side.height))
                host.frame = CGRect(origin: .zero, size: side)
                let win = window(host.frame, backing: backing)
                win.contentView = host
                defer { win.contentView = NSView() }
                flush(host)

                let tag = "All Actions, scale \(scale), backing \(win.backingScaleFactor)"
                let pixel = 1 / win.backingScaleFactor
                let r = try XCTUnwrap(all(host, RecorderView.self).first, tag)
                XCTAssertEqual(r.bounds.width, sz(142), accuracy: pixel, tag)
                let label = try XCTUnwrap(all(r, NSTextField.self).first, tag)
                XCTAssertEqual(label.stringValue, "⌃⌥⇧⌘Key108")
                assertFits(label, in: r, pixel: pixel, tag)
                assertFullSizeWhenItFits(label, in: r, full: 12 * scale, tag)
            }
        }
    }

    /// The text changes in place ("Press keys…", a newly recorded combo): a short label
    /// after a long one is back at the full size, not left at the long one's.
    func testLabelRefitsWhenTheTextChanges() throws {
        let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let short = KeyCombo(keyCode: UInt32(kVK_F12), carbonModifiers: mods, display: "")
        let long = KeyCombo(keyCode: 108, carbonModifiers: mods, display: "")  // ⌃⌥⇧⌘Key108, the widest
        for scale in [1.0, 0.7] as [CGFloat] {
            try withKeyRuleRecorder(scale: scale, backing: nil) { r, label, _, tag in
                show((short.label, short), in: r, label)
                XCTAssertEqual(label.font?.pointSize, 12 * scale, "short label at \(tag)")
                show((long.label, long), in: r, label)
                XCTAssertLessThan(try XCTUnwrap(label.font?.pointSize), 12 * scale, "long label not shrunk at \(tag)")
                show((short.label, short), in: r, label)
                XCTAssertEqual(label.font?.pointSize, 12 * scale, "short label after a long one at \(tag)")
                XCTAssertEqual(label.frame.size, label.fittingSize, "stale frame after re-fit at \(tag)")
                show(("Unset", unsetKeyCombo), in: r, label)
                XCTAssertEqual(label.font?.pointSize, 12 * scale, "Unset after a long one at \(tag)")
            }
        }
    }

    // MARK: - #890: accessibility

    /// The recorder is one accessible button that reads the combo in words, and says it is
    /// waiting while recording. `recording` is set directly: beginRecording would install
    /// a key monitor and take first responder. No window, no AX call through the system.
    func testRecorderIsAnAccessibleButtonThatSpeaksTheCombo() throws {
        let r = RecorderView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        XCTAssertTrue(r.isAccessibilityElement())
        XCTAssertEqual(r.accessibilityRole(), .button)
        r.combo = unsetKeyCombo
        r.refreshTitle()
        XCTAssertEqual(r.accessibilityLabel(), "Unset")
        let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        r.combo = KeyCombo(keyCode: UInt32(kVK_PageUp), carbonModifiers: mods, display: "")
        r.refreshTitle()
        XCTAssertEqual(r.accessibilityLabel(), "Control Option Shift Command Page Up")
        XCTAssertNil(r.accessibilityValue())
        r.recording = true
        XCTAssertEqual(r.accessibilityValue() as? String, "Waiting for keys")
        XCTAssertEqual(r.accessibilityLabel(), "Control Option Shift Command Page Up")
        r.recording = false
        XCTAssertNil(r.accessibilityValue())
        // The glyph text underneath is not a second element VoiceOver stops on.
        let label = try XCTUnwrap(all(r, NSTextField.self).first)
        XCTAssertFalse(label.isAccessibilityElement())
    }

    // MARK: - #890: the smallest size a real combo label reaches

    /// For every key code 0-127 with all four modifiers, the font size layout() ends at in
    /// each width the field is given (110 pt intrinsic, the sz(96) key-rule slot, the
    /// sz(142) All Actions slot) at UI scale 1.0, 0.85 and 0.7: the smallest per slot and
    /// scale, the label that hit it, and whether every label fit. Built by frame in an
    /// offscreen window pinned to `backing`; the width is snapped down to that pixel grid.
    private func smallestLabelSizes(backing: CGFloat)
        -> [(slot: String, scale: CGFloat, pt: CGFloat, text: String, under9: [String], unfit: [String])] {
        let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        var out: [(slot: String, scale: CGFloat, pt: CGFloat, text: String, under9: [String], unfit: [String])] = []
        for scale in [1.0, 0.85, 0.7] as [CGFloat] {
            ThemeRuntime.scale = scale
            for (slot, w) in [("110 intrinsic", 110), ("sz(96) key rule", sz(96)), ("sz(142) All Actions", sz(142))] as [(String, CGFloat)] {
                let width = (w * backing).rounded(.down) / backing
                let win = window(NSRect(x: 0, y: 0, width: 200, height: 40), backing: backing)
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
                win.contentView = container
                defer { win.contentView = NSView() }
                let r = RecorderView(frame: NSRect(x: 0, y: 0, width: width, height: sz(24)))
                container.addSubview(r)
                guard let label = all(r, NSTextField.self).first else { continue }
                var smallest = (pt: CGFloat.infinity, text: "")
                var under9: [String] = [], unfit: [String] = []
                for code in 0..<128 {
                    r.combo = KeyCombo(keyCode: UInt32(code), carbonModifiers: mods, display: "")
                    r.refreshTitle()
                    r.layoutSubtreeIfNeeded()
                    let pt = label.font?.pointSize ?? 0
                    if pt < smallest.pt { smallest = (pt, label.stringValue) }
                    if pt < 9 { under9.append("\(label.stringValue) \(pt)") }
                    if label.fittingSize.width > r.bounds.width { unfit.append("\(label.stringValue) \(pt)") }
                }
                out.append((slot, scale, smallest.pt, smallest.text, under9, unfit))
                print("#890 measure: backing \(backing), scale \(scale), \(slot) (\(width) pt): smallest \(smallest.pt) pt '\(smallest.text)'; under 9 pt: \(under9.count); unfit: \(unfit.count)")
            }
        }
        return out
    }

    /// #890 pin: no real combo label goes under 9 pt at UI scale 1.0, at backing 1 and 2,
    /// and every label fits its field at every scale. The 1 pt loop floor in layout() stays.
    func testNoComboLabelUnderNinePointAtFullScale() {
        for backing in [1, 2] as [CGFloat] {
            let rows = smallestLabelSizes(backing: backing)
            XCTAssertEqual(rows.count, 9, "backing \(backing)")
            for row in rows {
                let tag = "backing \(backing), scale \(row.scale), \(row.slot)"
                XCTAssertTrue(row.unfit.isEmpty, "labels wider than the field at \(tag): \(row.unfit)")
                if row.scale == 1.0 {
                    XCTAssertGreaterThanOrEqual(row.pt, 9, "'\(row.text)' at \(tag)")
                    XCTAssertTrue(row.under9.isEmpty, "under 9 pt at \(tag): \(row.under9)")
                }
            }
        }
    }
}

/// A window whose backing scale can be pinned, so a Retina machine lays out on the
/// 1x pixel grid CI's runner uses. SwiftUI snaps the hosted views to this value.
private final class FixedBackingWindow: NSWindow {
    var fixedBacking: CGFloat?
    override var backingScaleFactor: CGFloat { fixedBacking ?? super.backingScaleFactor }
}
