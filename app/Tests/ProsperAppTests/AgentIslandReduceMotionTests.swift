import XCTest

/// #1535 (OQ-95): the island honours Reduce Motion by having no animation at all. The tree has no
/// animation site there, so there is no helper and no seam to read; this guard fails when one is added,
/// so whoever adds it must route it through a Reduce Motion seam first (see FootprintWindow.swift).
final class AgentIslandReduceMotionTests: XCTestCase {
    private static let pattern = try! NSRegularExpression(pattern:
        #"withAnimation|\.animation\(|\.transition\(|matchedGeometryEffect|repeatForever|\.animator\(\)|NSAnimationContext|CABasicAnimation|CAKeyframeAnimation|symbolEffect|contentTransition|animate: *true|\.spring\(|\.easeInOut|\.easeIn\(|\.easeOut\("#)

    func testIslandSourcesHaveNoAnimationSite() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/AgentIsland")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertTrue(files.count > 5, "island sources not found at \(dir.path)")
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let hit = Self.pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
                XCTAssertTrue(!hit, "\(f.lastPathComponent):\(n + 1) animates; route it through a Reduce Motion seam: \(s)")
            }
        }
    }
}
