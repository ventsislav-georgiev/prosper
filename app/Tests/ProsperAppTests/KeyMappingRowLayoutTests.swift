import AppKit
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
        let win = FixedBackingWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.fixedBacking = backing
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
                // Every modifier plus F12 / Space (86 pt at 1.0). Not pinned: ⌃⌥⇧⌘PAGEUP (98 pt) and
                // ⌃⌥⇧⌘PAGEDOWN (120 pt, clipped at the old 110 pt too) are wider than the slot.
                try checkRow(trigger: "ctrl+alt+shift+cmd+f12", target: "ctrl+alt+shift+cmd+space",
                             scale: scale, backing: backing)
                // A fresh rule: both fields read "Unset".
                try checkRow(trigger: "", target: "", scale: scale, backing: backing)
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
