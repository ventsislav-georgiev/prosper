import AppKit
import SwiftUI
import XCTest

/// One element of an AX client's walk: role, AXDescription, AXTitle, AXValue, AXHelp, the frame and the two flags the
/// header rows read. A Menu's accessibilityLabel arrives as its AXTitle (#887's "Recent folders"; the "⋯" reads label
/// "More", title "Session actions"), a Text's words as its AXValue: `names` is all three.
struct AXTreeNode {
    let role: String, label: String, title: String, value: String, help: String
    let frame: CGRect
    /// Ignored by AppKit (NSAccessibility.unignoredChildren drops it): an AX client never sees it.
    var ignored = false
    /// AXEnabled as served to an AX client (true where the node reports none). #1120: the drawn state of a control.
    var enabled = true
    /// #1120: where `enabled` came from (the node's class, the legacy attribute, isAccessibilityEnabled).
    var enabledFacts = ""
    /// N1097-a: AXSelected as served to an AX client (false where the node reports none), by both routes AppKit serves it:
    /// the legacy attribute (an NSView's) and isAccessibilitySelected (an accessibility element's; KVC key "accessibilitySelected").
    /// The SwiftUI `.isSelected` trait arrives here.
    var selected = false
    /// What an AX client is shown, by any of its names (not an ignored node).
    func reads(_ n: String) -> Bool { !ignored && names.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }
    var names: [String] { [label, title, value].filter { !$0.isEmpty } }
    func named(_ n: String) -> Bool { names.contains(n) }
    func named(prefix: String) -> Bool { names.contains { $0.hasPrefix(prefix) } }
    var name: String { names.first { ["Terminal", "Transcript"].contains($0) || $0.hasPrefix("Showing: ") } ?? names.first ?? "" }
}

/// #1159: the one accessibility-tree helper of the tests. A view is hosted in a window that is never shown; the two
/// AX attributes of THIS process's NSApplication (never another process, never a system-wide element) are set so the
/// tree is built, as an AX client's attribute write would, and put back to what they were. NSApplication reads
/// AXEnhancedUserInterface back and reports nothing for AXManualAccessibility (nil), so that one goes back to false.
/// Everything here runs on the main actor; the `until` closures run on it too, inside the caller's row.
@MainActor
enum AXTreeSupport {
    static let attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]

    /// The two flags as NSApplication reports them (nil where it reports nothing).
    static func flags() -> [Bool?] {
        let get = Selector(("accessibilityAttributeValue:")), app = NSApplication.shared
        guard app.responds(to: get) else { return attrs.map { _ in nil } }
        return attrs.map { (app.perform(get, with: $0)?.takeUnretainedValue() as? NSNumber)?.boolValue }
    }

    static func setFlags(_ v: [Bool?]) {
        let set = Selector(("accessibilitySetValue:forAttribute:")), app = NSApplication.shared
        for (a, f) in zip(attrs, v) { app.perform(set, with: NSNumber(value: f ?? false), with: a) }
    }

    /// Turns both flags on and returns what puts them back as found.
    static func axOn() -> @MainActor () -> Void {
        XCTAssertTrue(NSApplication.shared.responds(to: Selector(("accessibilitySetValue:forAttribute:"))))
        let prior = flags()
        setFlags([true, true])
        return { setFlags(prior) }
    }

    /// `view` in a borderless window that is never ordered in, at `size`.
    static func hosted<V: View>(_ view: V, _ size: CGSize) -> (NSWindow, NSHostingView<V>) {
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        return (win, host)
    }

    /// Every element under `e` in an AX client's walk (accessibilityChildren), depth first. Read through KVC because
    /// a SwiftUI button's title is an attributed string; a label can sit on a cell, which the walk reaches as a child.
    static func walk(_ e: Any, _ out: inout [AXTreeNode], depth: Int = 0) {
        guard depth < 60, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        let frame = o.responds(to: Selector(("accessibilityFrame"))) ? (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero : .zero
        // AppKit's own verdict, the one served to an AX client: an ignored node is replaced by its unignored descendants
        // (the raw children below still list it).
        let ignored = !NSAccessibility.unignoredChildren(from: [o]).contains { ($0 as AnyObject) === o }
        // #1120: AXEnabled by both routes AppKit serves it: the legacy attribute (an NSView's) and isAccessibilityEnabled
        // (an accessibility element's; KVC finds it under the key "accessibilityEnabled"). Off when either says off.
        let legacy = (o.accessibilityAttributeValue(.enabled) as? NSNumber)?.boolValue
        let modern = o.responds(to: Selector(("isAccessibilityEnabled"))) ? (o.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue : nil
        let legacySel = (o.accessibilityAttributeValue(.selected) as? NSNumber)?.boolValue
        let modernSel = o.responds(to: Selector(("isAccessibilitySelected"))) ? (o.value(forKey: "accessibilitySelected") as? NSNumber)?.boolValue : nil
        out.append(AXTreeNode(role: text("accessibilityRole"), label: text("accessibilityLabel"), title: text("accessibilityTitle"),
                              value: text("accessibilityValue"), help: text("accessibilityHelp"), frame: frame, ignored: ignored,
                              enabled: legacy != false && modern != false,
                              enabledFacts: "\(type(of: o)) legacy \(legacy.map { "\($0)" } ?? "nil") modern \(modern.map { "\($0)" } ?? "nil")",
                              selected: legacySel == true || modernSel == true))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(k, &out, depth: depth + 1) }
    }

    /// Lays `host` out and walks it until `done` holds, to a 5 s ceiling (each pass pumps the run loop once; no fixed
    /// wait). The caller has turned the flags on.
    static func poll(_ host: NSView, until done: ([AXTreeNode]) -> Bool) -> [AXTreeNode] {
        var tree: [AXTreeNode] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            tree = []
            walk(host, &tree)
        } while !done(tree) && Date() < deadline
        return tree
    }

    /// One device pixel in points for `win`: 1 / its backingScaleFactor, never more than 1 (no factor: 1). A layout is
    /// rounded to the pixel, so a "one rounding step" tolerance is this, not a literal 0.5 (that is one pixel at 2x only;
    /// the CI runner's display backs at 1x, where a pixel is 1 pt).
    static func devicePixel(of win: NSWindow) -> CGFloat {
        let f = win.backingScaleFactor
        return f > 1 ? 1 / f : 1
    }

    /// The pixel of the window `tree` lays out in (the same never-shown borderless window `hosted` makes).
    static var devicePixel: CGFloat {
        let (win, _) = hosted(Color.clear, CGSize(width: 1, height: 1))
        defer { win.close() }
        return devicePixel(of: win)
    }

    /// The whole thing: host `view` at `size`, flags on, poll, close the window, put the flags back.
    static func tree<V: View>(_ view: V, _ size: CGSize, until done: ([AXTreeNode]) -> Bool) -> [AXTreeNode] {
        let restore = axOn()
        defer { restore() }
        let (win, host) = hosted(view, size)
        defer { win.close() }
        let tree = poll(host, until: done)
        XCTAssertFalse(win.isVisible, "never shown")
        return tree
    }
}

private final class FixedBackingWindow: NSWindow {
    var fixedBacking: CGFloat = 1
    override var backingScaleFactor: CGFloat { fixedBacking }
}

/// The helper's own row: the flags go back as found.
final class AXTreeSupportTests: XCTestCase {
    /// One pixel is 0.5 pt on a 2x window and 1 pt on a 1x one, and never more than 1 pt.
    @MainActor
    func testDevicePixelIsOneOverTheBackingScaleAndNeverMoreThanOne() {
        let win = FixedBackingWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        for (backing, want) in [(1, 1), (2, 0.5), (3, 1.0 / 3), (0.5, 1), (0, 1)] as [(CGFloat, CGFloat)] {
            win.fixedBacking = backing
            XCTAssertEqual(AXTreeSupport.devicePixel(of: win), want, accuracy: 1e-9, "backing \(backing)")
        }
        let real = AXTreeSupport.devicePixel
        XCTAssertTrue(real > 0 && real <= 1, "\(real)")
    }

    /// R1137-1: the helper puts the flags back as it found them. NSApplication reads AXEnhancedUserInterface back and
    /// reports nothing for AXManualAccessibility (run of 2026-11-14: before [false, nil], while walking [true, nil]),
    /// so the readable one is checked: on before the helper runs (as an AX client would have left it), still on after;
    /// off before, off after. AXManualAccessibility is restored to false, its only knowable value.
    @MainActor
    func testAXHelperRestoresThePriorFlags() throws {
        let original = AXTreeSupport.flags()
        defer { AXTreeSupport.setFlags(original) }
        func enhanced() -> Bool? { AXTreeSupport.flags().first ?? nil }
        AXTreeSupport.setFlags([true, true])
        guard enhanced() == true else {
            throw XCTSkip("NSApplication does not read AXEnhancedUserInterface back (\(AXTreeSupport.flags()))")
        }
        _ = AXTreeSupport.tree(Text(verbatim: "x"), CGSize(width: 40, height: 20)) { $0.count > 1 }
        XCTAssertEqual(enhanced(), true, "put back as found, not false")
        AXTreeSupport.setFlags([false, false])
        _ = AXTreeSupport.tree(Text(verbatim: "x"), CGSize(width: 40, height: 20)) { $0.count > 1 }
        XCTAssertEqual(enhanced(), false, "and off when it was off")
    }
}
