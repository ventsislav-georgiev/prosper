import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1500: the sidebar row's detail line follows the UI size. Offscreen only: views hosted in windows that are never
/// shown; no event, no file. Fakes only.
extension AgentRowModelEffortTests {
    @MainActor
    func fit1500<V: View>(_ size: CGSize, _ backing: CGFloat, _ v: V) -> CGFloat { probed1453(v, size: size, backing: backing).fit }

    /// The line's fitting height with no agents (the 10.5 pt state word is its tallest text): 9 / 11 / 13 at 0.7 / 0.85 / 1.0,
    /// 1x and 2x, within a device pixel, and it grows with the scale. Old line that makes it red: the age slot's
    /// `ZStack { hidden Text; Text }.font(..)` in AgentSidebarRowView.ageSlot, which held 14 at every scale.
    @MainActor
    func testDetail1500LineFollowsTheScale() {
        let pixel = AXTreeSupport.devicePixel
        let want: [CGFloat: CGFloat] = [0.7: 9, 0.85: 11, 1.0: 13]
        for backing: CGFloat in [1, 2] {
            var seen: [CGFloat] = []
            atScales { scale in
                let row = AgentSidebarRowView(row: outlined1360(agents: 0), selected: false)
                let h = fit1500(CGSize(width: sz(274), height: 60), backing, row.detailLine([]))
                seen.append(h)
                XCTAssertEqual(h, want[scale] ?? -1, accuracy: pixel, "the detail line's height (\(scale) @\(backing)x)")
            }
            XCTAssertTrue(seen.count == 3 && seen[0] < seen[1] && seen[1] < seen[2], "grows with the scale: \(seen) (@\(backing)x)")
        }
    }

    /// Prints the pieces and the age slot's variants as DETAIL1500-FACT (the evidence for the slot's height).
    @MainActor
    func testDetail1500Facts() {
        atScales { scale in
            for backing: CGFloat in [1, 2] {
                let row = AgentSidebarRowView(row: outlined1360(agents: 0), selected: false)
                let size = CGSize(width: sz(274), height: 60)
                let f = Neon.font(10), m = Neon.font(10).monospacedDigit()
                let facts: [(String, CGFloat)] = [
                    ("age", fit1500(size, backing, row.ageSlot)),
                    ("hiddenMono", fit1500(size, backing, Text("000d").font(m))),
                    ("hiddenPlain", fit1500(size, backing, Text("000d").font(f))),
                    ("empty", fit1500(size, backing, Text("").font(f))),
                    ("zstackOld", fit1500(size, backing, ZStack(alignment: .trailing) { Text("000d").hidden(); Text("") }.font(m))),
                    ("zstackPerText", fit1500(size, backing, ZStack(alignment: .trailing) { Text("000d").font(m).hidden(); Text("").font(m) })),
                    ("counts", fit1500(size, backing, AgentCountGroups(counts: row.row.counts, size: 10.5))),
                ]
                print("DETAIL1500-FACT scale \(scale) backing \(backing): " + facts.map { "\($0.0) \($0.1)" }.joined(separator: " "))
                XCTAssertTrue(facts.allSatisfy { $0.1 > 0 }, "measured: \(facts)")
            }
        }
    }
}
