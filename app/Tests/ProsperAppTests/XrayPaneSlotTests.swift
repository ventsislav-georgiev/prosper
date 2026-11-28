import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2093 (#2077 hotspot 6): opening or closing X-ray on one pane re-evaluates only that pane's X-ray button, drawer and
/// dock (XrayPanels.Slot); docked and the gate still reach every pane. Counted by XrayPaneProbe's body passes. Offscreen
/// only: a never-shown borderless window, no read started (no dch, fake or real), no event built or posted.
@MainActor
final class XrayPaneSlotTests: XCTestCase {
    let a = UUID(), b = UUID()
    let ta = XrayTarget(name: "api", dir: "/tmp/dch-test"), tb = XrayTarget(name: "web", dir: "/tmp/dch-test")

    /// Two panes side by side, each with its header's X-ray button over a docked site whose drawer it draws.
    func rig(_ body: (NSView) throws -> Void) rethrows {
        let docked = XrayPanels.shared.docked
        defer { XrayPaneProbe.bodies = nil; XrayPanels.shared.open = [:]; XrayPanels.shared.docked = docked }
        XrayPanels.shared.open = [:]
        XrayPaneProbe.bodies = [:]
        let pane = { (p: UUID, t: XrayTarget) in
            VStack(spacing: 0) {
                AgentXrayButton(pane: p, target: t)
                Color.clear.modifier(XrayDock(pane: p, target: t) { _ in true })
            }
        }
        let size = CGSize(width: 1600, height: 600)
        let host = NSHostingView(rootView: HStack(spacing: 0) { pane(a, ta); pane(b, tb) }.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.contentView = nil; win.close() }
        win.contentView = host
        settle(host)
        XCTAssertGreaterThan(n("button", a) * n("button", b) * n("dock", a) * n("dock", b), 0, "every pane drew once")
        try body(host)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    func n(_ kind: String, _ pane: UUID) -> Int { XrayPaneProbe.bodies?["\(kind) \(pane)"] ?? 0 }
    func counts(_ pane: UUID) -> [Int] { ["button", "drawer", "dock"].map { n($0, pane) } }

    /// A few layout and run loop passes: whatever a change queued is drawn.
    func settle(_ host: NSView) {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Red at 27a090f7 (XrayPanel.swift:66, `@Published var open`: every open tells every pane's views): an open on A
    /// re-evaluates A's button, drawer and dock and none of B's; the close likewise. Mutants slot-shared-map (B redraws)
    /// and slot-no-notify (A stays stale).
    func testOpenAndCloseOnOnePaneRedrawOnlyThatPane() {
        rig { host in
            let a0 = counts(a), b0 = counts(b)
            XrayPanels.shared.open[a] = XrayPanelModel(target: ta, tab: .tasks)
            settle(host)
            let a1 = counts(a), b1 = counts(b)
            XCTAssertGreaterThan(a1[0], a0[0], "A's button shows it open")
            XCTAssertGreaterThan(a1[1], a0[1], "A's drawer draws the panel")
            XCTAssertGreaterThan(a1[2], a0[2], "A's dock makes room")
            XCTAssertEqual(b1, b0, "B's button, drawer and dock keep their bodies on A's open")
            XrayPanels.shared.close(a)
            settle(host)
            let a2 = counts(a), b2 = counts(b)
            XCTAssertGreaterThan(a2[0], a1[0], "A's button shows it closed")
            XCTAssertGreaterThan(a2[2], a1[2], "A's dock gives the room back")
            XCTAssertEqual(b2, b1, "B's keep their bodies on A's close")
            XrayPanels.shared.close(a)   // already closed: nothing changes, nothing is told
            settle(host)
            XCTAssertEqual(counts(a), a2, "a close of a closed pane redraws nothing")
        }
    }

    /// #2092's follow moves the panel from A to B in one write: both panes' views re-evaluate, B's drawer draws it.
    func testAMoveToAnotherPaneRedrawsBoth() {
        rig { host in
            let p = XrayPanelModel(target: ta, tab: .tasks)
            XrayPanels.shared.open[a] = p
            settle(host)
            let a0 = counts(a), b0 = counts(b)
            XrayPanels.shared.open = [b: XrayPanelModel(target: tb, tab: .tasks)]
            settle(host)
            XCTAssertGreaterThan(n("button", a), a0[0], "A's button shows it closed")
            XCTAssertGreaterThan(n("button", b), b0[0], "B's button shows it open")
            XCTAssertGreaterThan(n("drawer", b), b0[1], "B's drawer draws the panel")
        }
    }

    /// The former whole-object updates still reach every pane: a docked flip re-evaluates both docks and drawers, the
    /// gate's publish both buttons. Mutant slot-button-drops-panels (the button no longer observes XrayPanels: no gate).
    func testDockedAndTheGateStillReachEveryPane() {
        rig { host in
            XrayPanels.shared.open[a] = XrayPanelModel(target: ta, tab: .tasks)
            settle(host)
            let a0 = counts(a), b0 = counts(b)
            XrayPanels.shared.docked.toggle()
            settle(host)
            XCTAssertGreaterThan(n("dock", a), a0[2], "A's dock sees docked")
            XCTAssertGreaterThan(n("dock", b), b0[2], "B's dock sees docked")
            XCTAssertGreaterThan(n("drawer", a), a0[1], "A's drawer sees docked")
            let a1 = counts(a), b1 = counts(b)
            XrayPanels.publish(XrayPanels.probed)   // the same probe: the gate does not change, the views are told
            settle(host)
            XCTAssertGreaterThan(n("button", a), a1[0], "A's button re-reads the gate")
            XCTAssertGreaterThan(n("button", b), b1[0], "B's button re-reads the gate")
        }
    }
}
