import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1627: NeonRow does not combine its children, so each switch in Settings > Agent Sessions carries its row's label itself.
/// Read the way AgentIslandFollowThemeTests reads its Follow theme checkbox: AXTreeSupport.tree (never-shown window, this
/// process's AX flags on and put back). Without the flags the tree holds no switches (CI run 44474244497: "found 0").
@MainActor
final class AgentSessionsToggleLabelTests: XCTestCase {
    static let wanted = [AgentSessionsSection.clipboardLabel, AgentSessionsSection.roundedLabel, AgentSessionsSection.githubLabel]

    /// Switches only: the row title Text carries the same string, so a label on a text node must not count.
    private static func switches(_ t: [AXTreeNode]) -> [AXTreeNode] { t.filter { $0.role == "AXCheckBox" || $0.role == "AXSwitch" } }

    func testTheThreeTogglesCarryTheirRowLabel() {
        let nodes = AXTreeSupport.tree(AgentSessionsSection().frame(width: 520), CGSize(width: 520, height: 700)) { t in
            let s = Self.switches(t)
            return Self.wanted.allSatisfy { w in s.contains { $0.label == w } }
        }
        let found = Self.switches(nodes).map(\.label)
        XCTAssertGreaterThanOrEqual(found.count, 3, "walk found \(found.count) switches; read \(nodes.map { "\($0.role) \($0.label)" }.prefix(12))")
        for want in Self.wanted {
            XCTAssertTrue(found.contains(want), "no switch labelled \(want); saw \(found)")
        }
    }
}
