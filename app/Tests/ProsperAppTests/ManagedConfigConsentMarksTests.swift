import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1235 round 3 (QA 1047, B1235-1 and R1235-d): the consent sheet's title is outside data. Each base keeps at most
/// three combining marks (#1251 R1251-s1a), the title line is clipped to its own bounds, and a title shaped like an id never stands over the
/// real id. Hand-built change sets (com.example.kit, /Users/example paths): nothing is read or written. The render row
/// draws with ImageRenderer only (no window, no file); the sheet row hosts the view in a never-shown window through
/// AXTreeSupport (flags on this process only, put back). Every row runs on main (the class is @MainActor).
@MainActor
final class ManagedConfigConsentMarksTests: XCTestCase {
    private static let owner = "com.example.kit"
    private static let letters = "abcdefghijklmnopqrstuvwxyz"
    private static let existing = ManagedConfigChangeSet.File(
        target: "claude:CLAUDE.md", path: "/Users/example/.claude/CLAUDE.md",
        backupDirectory: "/Users/example/.config/prosper/managed-config/backups/claude-CLAUDE.md",
        lines: [.init(sign: .context, text: "# mine"), .init(sign: .added, text: "Follow the kit rules.")], notes: [])

    private func model(_ name: String?) -> ManagedConfigConsentModel {
        ManagedConfigConsentModel(changes: ManagedConfigChangeSet(action: .apply, owner: Self.owner, displayName: name,
                                                                  files: [Self.existing], pieces: [])) { _ in }
    }

    /// Each letter followed by `n` of each mark in `marks`.
    private static func stacked(_ letters: String, _ marks: [String], _ n: Int = 24) -> String {
        letters.map { String($0) + marks.map { String(repeating: $0, count: n) }.joined() }.joined()
    }

    /// Compared scalar by scalar: String == is canonical equivalence and would hide a dropped or reordered mark.
    private static func scalars(_ s: String?) -> [UInt32] { (s ?? "").unicodeScalars.map(\.value) }

    private static func marks(_ c: Character) -> Int {
        c.unicodeScalars.filter { let g = $0.properties.generalCategory; return g == .nonspacingMark || g == .enclosingMark }.count
    }

    // MARK: the cap (b), on the model

    func testEachBaseOfTheTitleKeepsAtMostThreeMarks() throws {
        for marks in [["\u{0323}"], ["\u{0301}"], ["\u{20DD}"], ["\u{0323}", "\u{0301}"]] {
            let tag = "marks \(Self.scalars(marks.joined()))"
            let m = model(Self.stacked(Self.letters, marks))
            let name = try XCTUnwrap(m.displayName, tag)
            XCTAssertEqual(name.count, Self.letters.count, tag)
            XCTAssertTrue(name.allSatisfy { $0.unicodeScalars.count <= 4 && Self.marks($0) <= 3 }, "\(tag): \(Self.scalars(name).count) scalars")
            XCTAssertEqual(String(name.compactMap { $0.unicodeScalars.first.map(Character.init) }), Self.letters, "\(tag): every letter, in order")
            XCTAssertEqual(m.idLine, Self.owner, tag)
        }
        // the literal result for a short case, from 24 marks per letter
        XCTAssertEqual(Self.scalars(model(Self.stacked("ab", ["\u{0323}"])).displayName), Self.scalars("a\u{0323}\u{0323}\u{0323}b\u{0323}\u{0323}\u{0323}"))
        XCTAssertEqual(Self.scalars(model(Self.stacked("ab", ["\u{0301}"])).displayName), Self.scalars("a\u{0301}\u{0301}\u{0301}b\u{0301}\u{0301}\u{0301}"))
        XCTAssertEqual(Self.scalars(model(Self.stacked("ab", ["\u{20DD}"])).displayName), Self.scalars("a\u{20DD}\u{20DD}\u{20DD}b\u{20DD}\u{20DD}\u{20DD}"))
        // marks with no base: one character, bounded the same way (three marks kept, not empty), the id under it
        let only = model(String(repeating: "\u{0323}", count: 24))
        XCTAssertEqual(Self.scalars(only.displayName), Self.scalars("\u{0323}\u{0323}\u{0323}"))
        XCTAssertEqual(only.idLine, Self.owner)
        // the cap counts after the cleaning: a dropped scalar between two groups of marks joins them on one letter
        XCTAssertEqual(Self.scalars(model("a\u{0323}\u{0323}\u{0007}\u{0323}\u{0323}\u{0323}b").displayName), Self.scalars("a\u{0323}\u{0323}\u{0323}b"))
        // before the 120 cut: 200 stacked letters give 120 characters, each still bounded
        let long = try XCTUnwrap(model(Self.stacked(String(String(repeating: Self.letters, count: 8).prefix(200)), ["\u{0323}"])).displayName)
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
        XCTAssertTrue(long.allSatisfy { $0.unicodeScalars.count <= 4 })
        // legitimate titles are unchanged
        XCTAssertEqual(Self.scalars(model("Fake Kit").displayName), Self.scalars("Fake Kit"))
        XCTAssertEqual(Self.scalars(model("Caf\u{0065}\u{0301}").displayName), Self.scalars("Caf\u{0065}\u{0301}"))
        XCTAssertEqual(Self.scalars(model("Vi\u{0065}\u{0323}\u{0302}t").displayName), Self.scalars("Vi\u{0065}\u{0323}\u{0302}t"), "two marks on one letter stay")
    }

    // MARK: R1235-d: a title shaped like an id

    func testATitleShapedLikeAnIdNeverStandsOverTheId() {
        let longID = "com.other." + String(repeating: "k", count: 115)   // 125: id-shaped past the 120 cut, compared whole
        // past isValidID's 128: still id-shaped (round 3b)
        let over129 = "com.other." + String(repeating: "k", count: 119), over310 = "com.other." + String(repeating: "k", count: 300)
        XCTAssertEqual(over129.count, 129)
        for title in ["com.other.kit", Self.owner, "v1.2", " com.other\u{202E}.kit ", longID, over129, over310] {
            let m = model(title)
            XCTAssertTrue(m.displayName == nil, "'\(title)': dropped")
            XCTAssertEqual(m.title, Self.owner, "'\(title)': the id alone")
            XCTAssertTrue(m.idLine == nil, "'\(title)': no second id line")
            XCTAssertEqual(m.renderedStrings.first, Self.owner)
        }
        for title in ["Calculator", "Calc 2.0", "Fake Kit"] {
            let m = model(title)
            XCTAssertEqual(m.title, title, "'\(title)' stays a title")
            XCTAssertEqual(m.idLine, Self.owner)
        }
        // 200 characters with one space and a dot: not id-shaped, shown cut at 120 with the id under it
        let spaced = String(repeating: "a", count: 99) + " " + String(repeating: "a", count: 49) + "." + String(repeating: "a", count: 50)
        XCTAssertEqual(spaced.count, 200)
        let s = model(spaced)
        XCTAssertEqual(s.title.count, 120)
        XCTAssertTrue(s.title.hasPrefix(String(repeating: "a", count: 99) + " "))
        XCTAssertTrue(s.title.hasSuffix("\u{2026}"))
        XCTAssertEqual(s.idLine, Self.owner)
    }

    // MARK: the guard (a): rendered offscreen

    /// The title view with a RAW hostile string (not through the model) on a black field 40 pt above and below: no pixel
    /// row outside the title's own bounds differs from the background. The control, the same string in a plain unclipped
    /// Text with the same font and colour, rendered the same way, must put ink there, or the method proves nothing.
    func testTheTitleLineDrawsNothingOutsideItsOwnBounds() throws {
        let hostile = Self.stacked(Self.letters, ["\u{0323}", "\u{0301}"])
        let width: CGFloat = 400, pad: CGFloat = 40
        let ref = try XCTUnwrap(ImageRenderer(content: Color.black.frame(width: 4, height: 4)).cgImage)
        let refBytes = [UInt8](try XCTUnwrap(ref.dataProvider?.data as Data?))
        let bpp = ref.bitsPerPixel / 8
        XCTAssertEqual(ref.bitsPerPixel, 32)
        let background = Array(refBytes.prefix(bpp))
        // main actor (ImageRenderer and NSHostingView are main-actor); called only from this row
        @MainActor func ink<V: View>(_ line: V, _ tag: String) throws -> (outside: Int, inside: Int) {
            let h = NSHostingView(rootView: line.frame(width: width)).fittingSize.height
            let r = ImageRenderer(content: VStack(spacing: 0) {
                Color.clear.frame(height: pad)
                line.frame(width: width)
                Color.clear.frame(height: pad)
            }.background(Color.black))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage, tag)
            XCTAssertLessThanOrEqual(cg.width, 800, tag)
            XCTAssertLessThanOrEqual(cg.height, 200, tag)
            XCTAssertEqual(cg.bitsPerPixel, ref.bitsPerPixel, tag)
            XCTAssertEqual(cg.bitmapInfo, ref.bitmapInfo, tag)
            let bytes = [UInt8](try XCTUnwrap(cg.dataProvider?.data as Data?, tag))
            let row = cg.bytesPerRow
            guard cg.bitsPerPixel == ref.bitsPerPixel, bytes.count >= row * cg.height, row >= cg.width * bpp else {
                XCTFail("\(tag): unexpected bitmap \(cg.width)x\(cg.height) row \(row) bytes \(bytes.count)")
                return (0, 0)
            }
            let top = Int(pad), bottom = Int((pad + h).rounded(.up))
            var outside = 0, inside = 0
            for y in 0..<cg.height {
                let start = y * row
                let drawn = (0..<cg.width).contains { x in !bytes[(start + x * bpp)..<(start + x * bpp + bpp)].elementsEqual(background) }
                guard drawn else { continue }
                if y < top || y >= bottom { outside += 1 } else { inside += 1 }
            }
            fputs("mc1235d fact \(tag): image \(cg.width)x\(cg.height), line box rows \(top)..<\(bottom) (h \(h)), ink rows outside \(outside), inside \(inside)\n", stderr)
            return (outside, inside)
        }
        let control = try ink(Text(verbatim: hostile).font(Neon.font(15, weight: .semibold)).foregroundStyle(Neon.textPrimary)
            .lineLimit(1).truncationMode(.middle), "control")
        XCTAssertGreaterThan(control.inside, 0, "control: the line draws")
        XCTAssertGreaterThan(control.outside, 0, "control: no ink seen outside an unclipped line box: the measuring method is wrong, not the guard")
        guard control.outside > 0 else { return }
        let title = try ink(ManagedConfigConsentTitle(text: hostile), "title")
        XCTAssertGreaterThan(title.inside, 0, "title: the line draws")
        XCTAssertEqual(title.outside, 0, "title: ink outside its own bounds")
    }

    // MARK: the whole sheet, never-shown window

    private func fitting(_ model: ManagedConfigConsentModel) -> CGSize {
        let width = sz(ManagedConfigConsentPanel.width)
        let h = NSHostingController(rootView: ManagedConfigConsentView(model: model)).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: h)
    }

    private func tree(_ model: ManagedConfigConsentModel, _ size: CGSize) -> [AXTreeNode] {
        let view = ManagedConfigConsentView(model: model).frame(width: size.width).frame(maxHeight: .infinity, alignment: .top)
        return AXTreeSupport.tree(view, size) { t in t.contains { $0.named("Apply") } && t.contains { $0.named("Cancel") } && t.contains { $0.named(Self.owner) } }
    }

    /// The sheet with a hostile manifest title: the id line holds the whole id, the title holds at most three marks per
    /// character, and the id line and the buttons have the frames they have under "Fake Kit".
    func testAHostileTitleLeavesTheIdLineAndTheButtonsWhereTheyAre() throws {
        let plain = model("Fake Kit"), bad = model(Self.stacked(Self.letters, ["\u{0323}", "\u{0301}"]))
        XCTAssertEqual(bad.idLine, Self.owner)
        XCTAssertTrue(bad.title.allSatisfy { $0.unicodeScalars.count <= 4 }, "the sheet's title is bounded")
        let size = fitting(plain)
        fputs("mc1235d fact sheet: fitted height plain \(size.height), hostile \(fitting(bad).height)\n", stderr)
        let a = tree(plain, size), b = tree(bad, size)
        func near(_ p: CGRect, _ q: CGRect) -> Bool {
            abs(p.minX - q.minX) <= 0.5 && abs(p.minY - q.minY) <= 0.5 && abs(p.width - q.width) <= 0.5 && abs(p.height - q.height) <= 0.5
        }
        let titleNode = try XCTUnwrap(b.first { $0.named(bad.title) }, "\(b.map(\.name))")
        XCTAssertTrue(titleNode.names.allSatisfy { $0.allSatisfy { $0.unicodeScalars.count <= 4 } }, "the title on the tree is bounded")
        for label in [Self.owner, "Cancel", "Apply"] {
            let before = try XCTUnwrap(a.first { $0.named(label) && $0.frame.height > 0 }, "plain: \(label)")
            let after = try XCTUnwrap(b.first { $0.named(label) && $0.frame.height > 0 }, "hostile: \(label): \(b.map(\.name))")
            XCTAssertTrue(near(before.frame, after.frame), "\(label): \(after.frame) under the hostile title, \(before.frame) under Fake Kit")
        }
    }
}
