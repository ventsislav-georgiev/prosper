import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1627: NeonRow does not combine its children, so each switch in Settings > Agent Sessions carries its row's label itself.
final class AgentSessionsToggleLabelTests: XCTestCase {
    private func labels(_ e: Any, _ out: inout [String], depth: Int = 0) {
        guard depth < 60, let o = e as? NSObject else { return }
        if let r = o.accessibilityAttributeValue(.role) as? NSAccessibility.Role, r == .checkBox || r.rawValue == "AXSwitch", o.responds(to: Selector(("accessibilityLabel"))) { out.append(o.value(forKey: "accessibilityLabel") as? String ?? "") }   // switches only: the row title Text carries the same string
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { labels(k, &out, depth: depth + 1) }
    }

    func testTheThreeTogglesCarryTheirRowLabel() {
        let host = NSHostingView(rootView: AgentSessionsSection().frame(width: 520, height: 700))
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 700)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)   // never shown
        w.isReleasedWhenClosed = false
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        var found: [String] = []
        labels(host, &found)
        XCTAssertGreaterThanOrEqual(found.count, 3, "walk found \(found.count) switches")
        for want in [AgentSessionsSection.clipboardLabel, AgentSessionsSection.roundedLabel, AgentSessionsSection.githubLabel] {
            XCTAssertTrue(found.contains(want), "no switch labelled \(want); saw \(found)")
        }
        w.contentView = nil
    }
}
