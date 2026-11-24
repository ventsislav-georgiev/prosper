import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1361: the Agent Sessions confirm strip. One row when the question fits beside its buttons (the buttons a fixed gap
/// after the text, one vertical centre), else the question wraps and the buttons sit under it, left-aligned with its
/// start. Offscreen only: every strip is hosted in a window never ordered in, no event is posted, nothing is read from a
/// screen. Frames come from AgentConfirmStrip.probe (in the strip's content space, inside its padding).
final class AgentConfirmStripTests: XCTestCase {
    private final class FixedBackingWindow: NSWindow {
        var fixedBacking: CGFloat = 1
        override var backingScaleFactor: CGFloat { fixedBacking }
    }

    private static let scales: [CGFloat] = [0.7, 0.85, 1.0]
    private static let backings: [CGFloat] = [1, 2]
    private static let shortText = "End api? No pause message first."
    private static let longText = "Stop api? Claude Code is paused and the session ends. Resume it later from History. "
        + "It is waiting on a prompt: answer it first."

    /// The strip's parts by name and its height, from a fresh never-shown window `width` points wide at `backing`.
    @MainActor
    private func lay<V: View>(_ v: V, width: CGFloat, backing: CGFloat) -> (parts: [String: CGRect], height: CGFloat) {
        var seen: [String: CGRect] = [:]
        AgentConfirmStrip.probe = { seen[$0] = $1 }
        defer { AgentConfirmStrip.probe = nil }
        let host = NSHostingView(rootView: v.frame(width: width))
        let size = host.fittingSize
        let win = FixedBackingWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.fixedBacking = backing
        win.isReleasedWhenClosed = false
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(win.isVisible, "never on screen")
        win.contentView = nil
        win.close()
        return (seen, size.height)
    }

    @MainActor
    private func strip(_ text: String, action: String = "End") -> AgentConfirmStrip {
        AgentConfirmStrip(text: text, action: action, confirm: {}, cancel: {})
    }

    @MainActor
    private func eachScale(_ body: (CGFloat, CGFloat) -> Void) {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for s in Self.scales {
            ThemeRuntime.scale = s
            for b in Self.backings { body(s, b) }
        }
    }

    /// (a) Wide pane, short question: one row. Red at TIP: the text is maxWidth .infinity inside a VStack(alignment:
    /// .trailing), so the buttons sit on their own line below it (midY apart, no gap to the text, verb at the far edge).
    @MainActor
    func testWidePaneIsOneRowWithTheButtonsRightAfterTheText() {
        eachScale { s, b in
            let w = 900 * s, tag = "scale \(s) backing \(b)"
            let r = lay(strip(Self.shortText), width: w, backing: b).parts
            guard let t = r["text"], let c = r["cancel"], let v = r["verb"] else { return XCTFail("parts missing: \(tag)") }
            XCTAssertEqual(t.midY, c.midY, accuracy: 1, "text and Cancel share a centre: \(tag)")
            XCTAssertEqual(t.midY, v.midY, accuracy: 1, "text and the verb share a centre: \(tag)")
            XCTAssertEqual(c.minX - t.maxX, 8 * s, accuracy: 1, "Cancel a fixed gap after the text: \(tag)")
            XCTAssertEqual(v.minX - c.maxX, 8 * s, accuracy: 1, "the verb a fixed gap after Cancel: \(tag)")
            let inner = w - 32 * s
            XCTAssertLessThan(v.maxX, inner * 0.75, "premise: the verb is well left of the right padding edge: \(tag)")
        }
    }

    /// (b) Narrow pane, long question: stacked. Red at TIP: the buttons are right-aligned (minX far from the text's).
    @MainActor
    func testNarrowPaneWrapsAndTheButtonsSitUnderTheTextLeftAligned() {
        eachScale { s, b in
            let tag = "scale \(s) backing \(b)"
            let line = lay(strip(Self.shortText), width: 900 * s, backing: b).parts["text"]?.height ?? 0
            let w = 320 * s
            let r = lay(strip(Self.longText), width: w, backing: b).parts
            guard let t = r["text"], let c = r["cancel"], let v = r["verb"] else { return XCTFail("parts missing: \(tag)") }
            XCTAssertGreaterThan(line, 0, "premise: a single line has a height: \(tag)")
            XCTAssertGreaterThan(t.height, line * 1.5, "premise: the question wrapped: \(tag)")
            XCTAssertGreaterThan(c.minY, t.maxY - 0.01, "Cancel under the text: \(tag)")
            XCTAssertGreaterThan(v.minY, t.maxY - 0.01, "the verb under the text: \(tag)")
            XCTAssertEqual(c.minX, t.minX, accuracy: 1, "the buttons start where the text starts: \(tag)")
            XCTAssertLessThanOrEqual(c.maxX, v.minX + 0.01, "Cancel and the verb do not overlap: \(tag)")
            XCTAssertFalse(t.intersects(c) || t.intersects(v), "no button overlaps the text: \(tag)")
            XCTAssertLessThanOrEqual(t.maxX, w - 32 * s + 1, "the text stays inside the padding (0.7 rule): \(tag)")
            XCTAssertLessThanOrEqual(v.maxX, w - 32 * s + 1, "the verb stays inside the padding: \(tag)")
        }
    }

    /// (c) The one-row strip is shorter than TIP's. TIP's height is its structure's: the text's height, sz(6), the
    /// button row's height, and sz(8) of padding above and below. (The literal TIP heights were not measured: the
    /// ticket builds one tree.) Red at TIP: the strip is exactly that sum.
    @MainActor
    func testOneRowIsShorterThanTheStackedStrip() {
        eachScale { s, b in
            let tag = "scale \(s) backing \(b)"
            let r = lay(strip(Self.shortText), width: 900 * s, backing: b)
            guard let t = r.parts["text"], let c = r.parts["cancel"] else { return XCTFail("parts missing: \(tag)") }
            let tip = t.height + 6 * s + c.height + 16 * s
            XCTAssertLessThan(r.height, tip - 4 * s, "shorter than the two-line strip: \(tag) \(r.height) vs \(tip)")
            XCTAssertGreaterThanOrEqual(r.height, c.height + 16 * s - 1, "the row holds a button and the padding: \(tag)")
        }
    }

    /// (d) The three callers draw the same layout: each caller's frames are the bare strip's for its own text, at a wide
    /// and a narrow pane. The per-session caller (AgentPaneArea.confirmCard, #1930) is a plain AgentConfirmStrip call: its
    /// question and verb are the controls' own.
    @MainActor
    func testEveryCallerDrawsTheSameLayout() {
        let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")
        let sess = AgentSession(key: key, alias: "", activity: 1_800_000_000, state: .idle, agents: 0, version: "1.30.0")
        let st = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        st.confirmingKillAll = true
        guard let q = AgentWindowControls.storeQuestion(st) else { return XCTFail("the store question is up") }
        let k = "agentIslandAutoAllow", saved = Preferences.defaults.object(forKey: k)
        defer { Preferences.defaults.set(saved, forKey: k) }
        Preferences.agentIslandAutoAllow = false
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        defer { m.close() }
        m.runSidebar(.autoAllow)
        XCTAssertTrue(m.askingAlwaysAllow, "premise: Always allow asks")
        let session = AgentWindowControls.question(.kill, sess)
        eachScale { s, b in
            for w in [900 * s, 260 * s] {
                let tag = "scale \(s) backing \(b) width \(w)"
                func same(_ name: String, _ real: [String: CGRect], _ bare: [String: CGRect]) {
                    XCTAssertEqual(Set(real.keys), ["text", "cancel", "verb"], "\(name) parts: \(tag)")
                    for p in ["text", "cancel", "verb"] {
                        let a = real[p] ?? .null, c = bare[p] ?? .zero
                        for (x, y) in [(a.minX, c.minX), (a.minY, c.minY), (a.width, c.width), (a.height, c.height)] {
                            XCTAssertEqual(x, y, accuracy: 1 / b, "\(name) \(p) frame: \(a) vs \(c) \(tag)")
                        }
                    }
                }
                same("store", lay(AgentStoreQuestionStrip(store: st) { _ in }, width: w, backing: b).parts,
                     lay(strip(q.text, action: q.action), width: w, backing: b).parts)
                same("always allow", lay(AgentAlwaysAllowStrip(model: m), width: w, backing: b).parts,
                     lay(strip(AgentWindowControls.alwaysAllowQuestion, action: AgentWindowControls.alwaysAllowAction),
                         width: w, backing: b).parts)
                let one = lay(strip(session, action: AgentWindowControls.confirmTitle(.kill)), width: w, backing: b).parts
                XCTAssertEqual(one["cancel"]?.midY ?? 0, one["verb"]?.midY ?? -1, accuracy: 1 / b, "session buttons share a row: \(tag)")
            }
        }
    }
}
