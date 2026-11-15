import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #359 (QA #137): the approval card's layout is view code no test renders, so its load-bearing
/// lines are pinned by a source scan: the command summary is never line-limited (#323), both
/// boxes are height-capped, and the scroll cue comes from the laid-out height, not a char count.
final class ApprovalBoxSourceTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    func testApprovalBarKeepsTheCommandWholeInHeightCappedBoxes() throws {
        let chat = try source("Sources/ProsperApp/ChatWindow.swift")
        let start = try XCTUnwrap(chat.range(of: "struct ApprovalCardView: View {"))
        let end = try XCTUnwrap(chat.range(of: "private func approvalNoun", range: start.upperBound..<chat.endIndex))
        let bar = chat[start.upperBound..<end.lowerBound]

        XCTAssertGreaterThanOrEqual(bar.components(separatedBy: ".frame(maxHeight: sz(160))").count - 1, 2,
                                    "the summary box and the detail box are both capped at 160 pt")
        let cmd = try XCTUnwrap(bar.range(of: "if req.kind == .command {"))
        let other = try XCTUnwrap(bar.range(of: "} else {", range: cmd.upperBound..<bar.endIndex))
        let command = String(bar[cmd.upperBound..<other.lowerBound])
        XCTAssertNil(command.range(of: #"\.lineLimit\s*\("#, options: .regularExpression),
                     "the command summary scrolls whole: a lineLimit hides its tail (#323)")
        // #368: the cue compares the text with its box's own laid-out height (the box is shorter
        // than 160 pt near the window's minimum height); unmeasured box (0) = no cue.
        let summaryCue = "if approvalSummaryBoxHeight > 0 && approvalSummaryHeight > approvalSummaryBoxHeight + 0.5 { scrollCue }"
        let detailCue = "if approvalDetailBoxHeight > 0 && approvalDetailHeight > approvalDetailBoxHeight + 0.5 { scrollCue }"
        XCTAssertEqual(command.components(separatedBy: summaryCue).count - 1, 1, "summary cue, in the command branch")
        XCTAssertEqual(bar[other.upperBound...].components(separatedBy: detailCue).count - 1, 1,
                       "detail cue, after the command branch, reading only the detail heights")
        XCTAssertEqual(bar.components(separatedBy: "{ scrollCue }").count - 1, 2, "exactly the two pinned cues")
        XCTAssertEqual(bar.components(separatedBy: "$0.size.height").count - 1, 4,
                       "text and box height measured for both boxes")
        XCTAssertFalse(bar.contains("$0.size.width"), "the cue is about height")
        XCTAssertFalse(bar.contains("CardText."), "text is display-ready at construction, not per render")
        // #376 (QA #183): each geometry line pinned with its neighbour, once per branch, and the cue
        // after its box measure, outside the ScrollView (the ScrollView's closing brace precedes it).
        func flat(_ s: Substring) -> String {
            s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        }
        let det = try XCTUnwrap(bar.range(of: "if req.kind != .command, let diff = req.detail {"))
        let branches = [("summary", flat(bar[cmd.upperBound..<other.lowerBound]), "Summary", summaryCue, "ScrollView {\nText(command)"),
                        ("detail", flat(bar[det.upperBound...]), "Detail", detailCue, "ScrollView {\nText(diff)")]
        for (name, body, v, cue, open) in branches {
            let text = ".frame(maxWidth: .infinity, alignment: .leading)\n.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { approval\(v)Height = $0 }\n}"
            let box = "}\n.frame(maxHeight: sz(160))\n.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { approval\(v)BoxHeight = $0 }\n" + cue
            XCTAssertEqual(body.components(separatedBy: text).count - 1, 1, "\(name): text measured on the Text, closing the ScrollView")
            XCTAssertEqual(body.components(separatedBy: box).count - 1, 1, "\(name): box cap, box measure, then the cue outside the ScrollView")
            let t = try XCTUnwrap(body.range(of: text)), b = try XCTUnwrap(body.range(of: box))
            XCTAssertLessThan(t.lowerBound, b.lowerBound, "\(name): text measure before the box measure")
            // #383 (QA #195): the capped box is a ScrollView, so the scroll cue is honest (#323).
            XCTAssertEqual(body.components(separatedBy: open).count - 1, 1, "\(name): the capped box is a ScrollView")
            let o = try XCTUnwrap(body.range(of: open))
            XCTAssertLessThan(o.lowerBound, t.lowerBound, "\(name): ScrollView opens before the text measure")
            // #385 (QA #199 t2): the text measure sits inside the ScrollView. Braces counted from the
            // ScrollView's `{` to the measure line never close it (a ScrollView shut right after the
            // `Text(` line would move the measure onto the ScrollView and the cue would never show).
            let measure = try XCTUnwrap(body.range(of: ".onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { approval\(v)Height = $0 }"))
            guard o.lowerBound < measure.lowerBound else { XCTFail("\(name): text measure before the ScrollView"); continue }
            var depth = 1
            for c in body[body.index(o.lowerBound, offsetBy: "ScrollView {".count)..<measure.lowerBound] {
                depth += c == "{" ? 1 : c == "}" ? -1 : 0
                if depth == 0 { break }
            }
            XCTAssertGreaterThan(depth, 0, "\(name): the ScrollView closes before the text measure")
        }
    }

    func testOverflowCharCountGuessIsGone() throws {
        XCTAssertFalse(try source("Sources/ProsperApp/Harness/CodingHarness.swift").contains("summary.count > 300"))
        XCTAssertFalse(try source("Sources/ProsperApp/ChatWindow.swift").contains("count > 300"))
    }

    // MARK: #1221 the sub-agent line is its own element

    private static let label = "Asked by a sub-agent of this session"   // literal: the CHANGELOG quotes it

    private func request(_ kind: ApprovalRequest.Kind, _ summary: String, detail: String? = nil) -> ApprovalRequest {
        ApprovalRequest(id: ApprovalID(raw: "a1"), kind: kind, session: SessionID(raw: "t1"), summary: summary, detail: detail)
    }

    /// The card hosted offscreen (never shown), its natural size and the labels on its real accessibility tree.
    @MainActor
    private func host(_ req: ApprovalRequest, width: CGFloat = 420) -> (size: CGSize, labels: [String]) {
        let h = NSHostingView(rootView: ApprovalCardView(req: req, respond: { _ in }).frame(width: width))
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = h
        defer { win.close() }
        let restoreAX = AXTreeSupport.axOn()   // put back as found, not to false
        defer { restoreAX() }
        var labels: [String] = []
        for _ in 0..<20 {
            h.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            labels = []
            var nodes: [AXTreeNode] = []
            AXTreeSupport.walk(h, &nodes)   // label then title of each node, depth first, as before (main actor)
            labels = nodes.flatMap { [$0.label, $0.title] }.filter { !$0.isEmpty }
            if labels.contains("Approve") { break }
        }
        return (h.fittingSize, labels)
    }

    func testSplitTakesTheLabelLineOnly() {
        let sp = ApprovalCardView.split(Self.label + "\nEdit /Users/example/a.txt")
        XCTAssertEqual(sp.label, Self.label)
        XCTAssertEqual(sp.command, "Edit /Users/example/a.txt")
        // CardText.ltr adds U+200E after neutral characters of a non-ASCII summary, label included.
        let ltr = CardText.ltr(Self.label + "\n\u{05D0}: /Users/example")
        XCTAssertNotEqual(ltr.split(separator: "\n").first.map(String.init), Self.label, "the marks are really there")
        XCTAssertEqual(ApprovalCardView.split(ltr).label, Self.label)
        XCTAssertTrue(ApprovalCardView.split(ltr).command.hasPrefix("\u{05D0}"))
        for plain in ["ls /Users/example", "Asked by a sub-agent of this session", "other\n" + Self.label, Self.label + " \nx"] {
            XCTAssertTrue(ApprovalCardView.split(plain).label == nil, "not a label line: \(plain)")
            XCTAssertEqual(ApprovalCardView.split(plain).command, plain)
        }
    }

    @MainActor
    func testSubAgentLineIsItsOwnLabelledElementAndTheCommandKeepsThreeLines() {
        let three = "line one\nline two\nline three"
        let cases: [(ApprovalRequest.Kind, String)] = [(.fileChange, "Edit /Users/example/a.txt\nsecond\nthird"), (.permission, three)]
        for (kind, cmd) in cases {
            let sub = host(request(kind, Self.label + "\n" + cmd))
            XCTAssertEqual(sub.labels.filter { $0 == Self.label }.count >= 1, true, "\(kind): the line has its own accessibility label")
            XCTAssertFalse(sub.labels.contains { $0.contains(Self.label) && $0 != Self.label }, "\(kind): no label holds the line plus the command")
            let plain = host(request(kind, cmd))
            XCTAssertFalse(plain.labels.contains(Self.label), "\(kind): a plain card has no such element")
            // The command is whole: three lines tall in both, the sub-agent card is taller only by the line.
            XCTAssertGreaterThan(sub.size.height, plain.size.height, "\(kind): the line adds a row, it takes none of the command's")
            let oneLine = host(request(kind, Self.label + "\nx")).size.height, threeLine = sub.size.height
            XCTAssertGreaterThan(threeLine, oneLine, "\(kind): all three command lines show with the line present")
        }
    }

    @MainActor
    func testCardSizeAtEveryScale() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            for kind in [ApprovalRequest.Kind.command, .fileChange, .permission] {
                let plain = host(request(kind, "one\ntwo\nthree")).size
                let sub = host(request(kind, Self.label + "\none\ntwo\nthree")).size
                print("#1221 size scale \(scale) \(kind): plain \(plain) sub-agent \(sub) grows by \(sub.height - plain.height)")
                XCTAssertGreaterThan(sub.height, plain.height, "scale \(scale) \(kind)")
                XCTAssertLessThan(sub.height - plain.height, 40 * scale, "scale \(scale) \(kind): one line, not two")
                XCTAssertEqual(sub.width, plain.width, accuracy: 0.5, "scale \(scale) \(kind)")
            }
        }
    }

    @MainActor
    func testCopyTakesTheCommandOnlyThroughThePasteboardSeam() throws {
        let req = request(.command, Self.label + "\nls /Users/example")
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString(ApprovalCardView.copyText(req), forType: .string)
        XCTAssertEqual(pb.string(forType: .string), "ls /Users/example")
        XCTAssertFalse(try XCTUnwrap(pb.string(forType: .string)).contains("sub-agent"))
        pb.clearContents()
    }

    func testRespondIsUntouched() throws {
        let chat = try source("Sources/ProsperApp/ChatWindow.swift")
        for d in [".accept", ".acceptForSession", ".decline"] {
            XCTAssertEqual(chat.components(separatedBy: "respond(\(d))").count - 1, 1, d)
        }
        XCTAssertTrue(chat.contains("ApprovalCardView(req: approval) { controller.respond(to: approval, decision: $0) }"))
    }
}
