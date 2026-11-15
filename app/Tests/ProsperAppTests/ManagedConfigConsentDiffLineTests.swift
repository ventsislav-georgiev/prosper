import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1252 (QA F1054-1): the consent sheet's diff lines, path, notes and backup line are outside text. Each is shown through
/// ManagedConfigConsentDisplay (an unseen scalar as its visible escape, at most two marks per character drawn as marks and
/// the rest as escapes, backslashes before "u{" doubled, a 2000-scalar ceiling with a counted rest) and each diff line is
/// clipped to its own bounds. The bytes written are not touched. Hand-built change sets (com.example.kit, /Users/example
/// paths: nothing read or written) except the written-bytes row, which works in its own tempDir() (makeMCEnv). The render
/// row draws with ImageRenderer only (no window, no file); the sheet row hosts the view in a never-shown window through
/// AXTreeSupport (flags on this process only, put back). Every row runs on main (the class is @MainActor).
@MainActor
final class ManagedConfigConsentDiffLineTests: XCTestCase {
    private static let owner = "com.example.kit"

    /// Compared scalar by scalar: String == is canonical equivalence and would hide a dropped or reordered scalar.
    private static func scalars(_ s: String?) -> [UInt32] { (s ?? "").unicodeScalars.map(\.value) }

    private func check(_ input: String, _ expected: String, _ tag: String, line: UInt = #line) {
        let got = ManagedConfigConsentDisplay.displayed(input)
        XCTAssertEqual(Self.scalars(got), Self.scalars(expected), "\(tag): \(got.debugDescription)", line: line)
    }

    // MARK: the display function

    func testUnseenScalarsShowAsTheirEscapeInPlace() {
        let cases: [(String, String)] = [
            ("a\u{202E}b", "a\\u{202E}b"), ("a\u{202D}b", "a\\u{202D}b"),
            ("a\u{2066}b", "a\\u{2066}b"), ("a\u{2067}b", "a\\u{2067}b"), ("a\u{2068}b", "a\\u{2068}b"), ("a\u{2069}b", "a\\u{2069}b"),
            ("a\u{200B}b", "a\\u{200B}b"), ("a\u{200D}b", "a\\u{200D}b"), ("a\u{FEFF}b", "a\\u{FEFF}b"),
            ("a\u{0007}b", "a\\u{0007}b"), ("a\u{001B}b", "a\\u{001B}b"), ("a\u{2028}b", "a\\u{2028}b"),
            ("a\u{000D}b", "a\\u{000D}b"), ("a\u{00A0}b", "a\\u{00A0}b"),
            // five hex digits: never padded past four
            ("a\u{E0001}b", "a\\u{E0001}b"),
            // the same scalar twice and two kinds in a row, the letters in order
            ("x\u{202E}\u{202E}y\u{2066}z\u{2069}", "x\\u{202E}\\u{202E}y\\u{2066}z\\u{2069}"),
        ]
        for (input, expected) in cases { check(input, expected, "unseen \(Self.scalars(input))") }
    }

    func testPlainAsciiLinesAndTabsAreUnchanged() {
        for line in [
            "  \"command\": \"kit-run --flag='a b' \\\"q\\\" C:\\\\tmp\\\\n\",",
            "name = \"kit\" # a TOML line",
            "echo \"a\\tb\" | sed 's/\\n/ /g' && printf '%s\\\\' x",
            "path\\u",
            "\\{u}",
            "\tkey = 1\t# a tab is kept",
            "",
            "   ",
        ] {
            check(line, line, "unchanged \(line.debugDescription)")
        }
    }

    func testOtherScriptsShowAsWritten() {
        for line in [
            "\u{039A}\u{03B1}\u{03BB}\u{03B7}\u{03BC}\u{03AD}\u{03C1}\u{03B1}",   // Greek
            "\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD}",   // Hebrew, no direction controls
            "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}",                           // Japanese
            "Vi\u{0065}\u{0323}\u{0302}t",                                         // two marks on one letter
            "\u{2022}\u{2022}\u{2022}\u{2022} \u{2026}",                           // the sheet's own mask and elision
        ] {
            check(line, line, "unchanged \(Self.scalars(line))")
        }
        // the joiner (a format scalar) and the emoji variation selector (default-ignorable) are shown as escapes
        check("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F468}\\u{200D}\u{1F469}\\u{200D}\u{1F467}", "family")
        check("\u{2764}\u{FE0F}", "\u{2764}\\u{FE0F}", "heart")
    }

    func testMarksPastTwoShowAsEscapesAfterTheirCharacter() {
        let a24 = "a" + String(repeating: "\u{0323}", count: 24)
        check(a24, "a\u{0323}\u{0323}" + String(repeating: "\\u{0323}", count: 22), "24 marks")
        check(a24 + "b", "a\u{0323}\u{0323}" + String(repeating: "\\u{0323}", count: 22) + "b", "24 marks then b")
        check("a\u{0323}\u{0301}\u{0302}b", "a\u{0323}\u{0301}\\u{0302}b", "three kinds")
        // a joiner inside one character: escaped in place; the marks after it count on the same character
        check("a\u{0323}\u{200D}\u{0301}\u{0302}", "a\u{0323}\\u{200D}\u{0301}\\u{0302}", "joiner")
    }

    /// A backslash run shown just before "u{" or before an escape is doubled: an escape of ours always follows an even run.
    func testALiteralBackslashBeforeAnEscapeShapeIsDoubled() {
        check("\\u{202E}", "\\\\u{202E}", "literal escape text")
        check("x\\\\u{41}", "x\\\\\\\\u{41}", "two literal backslashes then u{")
        check("\\\u{202E}", "\\\\\\u{202E}", "a backslash then a real override")
        check("\\\\\u{202E}", "\\\\\\\\\\u{202E}", "two backslashes then a real override")
        check("\\\u{0301}\u{202E}", "\\\\\u{0301}\\u{202E}", "a backslash with a mark then a real override")
        check("\\" + String(repeating: "\u{0323}", count: 3), "\\\\\u{0323}\u{0323}\\u{0323}", "a backslash with three marks")
        check("a\\b\\", "a\\b\\", "other backslashes stay single")
    }

    func testALongLineIsCutWithItsRestCounted() {
        check(String(repeating: "a", count: 5000), String(repeating: "a", count: 2000) + "\u{2026} (+3000 more characters)", "5000")
        check(String(repeating: "a", count: 2000), String(repeating: "a", count: 2000), "2000 is whole")
        check(String(repeating: "a", count: 2001), String(repeating: "a", count: 2000) + "\u{2026} (+1 more characters)", "2001")
        // the ceiling counts scalars: 1000 letters with 4 marks each are 5000 scalars, 400 letters shown
        let stacked = String(repeating: "a\u{0323}\u{0323}\u{0323}\u{0323}", count: 1000)
        let shown = String(repeating: "a\u{0323}\u{0323}\\u{0323}\\u{0323}", count: 400) + "\u{2026} (+3000 more characters)"
        check(stacked, shown, "stacked 5000")
    }

    func testTheSheetTextsUseTheDisplay() {
        let line = ManagedConfigChangeSet.Line(sign: .added, text: "x\u{202E}y", noFinalNewline: true)
        XCTAssertEqual(Self.scalars(ManagedConfigConsentModel.text(line)), Self.scalars("+ x\\u{202E}y   (no newline at end of file)"))
        var file = Self.file(lines: [line])
        file.backupDirectory = "/Users/example/b\u{202E}k"
        let m = ManagedConfigConsentModel(changes: Self.set([file])) { _ in }
        XCTAssertEqual(Self.scalars(m.backupLine(file)), Self.scalars("Backup: /Users/example/b\\u{202E}k"))
        let strings = m.renderedStrings.map { Self.scalars($0) }
        for s in [Self.shownPath, "+ x\\u{202E}y   (no newline at end of file)", Self.shownNote, "Backup: /Users/example/b\\u{202E}k"] {
            XCTAssertTrue(strings.contains(Self.scalars(s)), "\(s.debugDescription) in \(m.renderedStrings)")
        }
        XCTAssertFalse(m.renderedStrings.joined().unicodeScalars.contains("\u{202E}"), "no raw override in what the sheet lists")
    }

    // MARK: the clip, rendered offscreen

    /// The line view with a RAW hostile string (not through the display) on a black field 40 pt above and below: no pixel
    /// row outside the line's own bounds differs from the background. The control, the same string in a plain unclipped
    /// Text with the same font and colour, rendered the same way, must put ink there, or the method proves nothing.
    func testADiffLineDrawsNothingOutsideItsOwnBounds() throws {
        let hostile = "abcdefghijklmnopqrstuvwxyz".map { String($0) + String(repeating: "\u{0323}", count: 24) + String(repeating: "\u{0301}", count: 24) }.joined()
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
            fputs("mc1252 fact \(tag): image \(cg.width)x\(cg.height), line box rows \(top)..<\(bottom) (h \(h)), ink rows outside \(outside), inside \(inside)\n", stderr)
            return (outside, inside)
        }
        let control = try ink(Text(verbatim: hostile).font(Neon.font(11, design: .monospaced)).foregroundStyle(Neon.terminal)
            .fixedSize(horizontal: false, vertical: true), "control")
        XCTAssertGreaterThan(control.inside, 0, "control: the line draws")
        XCTAssertGreaterThan(control.outside, 0, "control: no ink seen outside an unclipped line box: the measuring method is wrong, not the guard")
        guard control.outside > 0 else { return }
        let line = try ink(ManagedConfigConsentDiffLine(text: hostile, color: Neon.terminal), "line")
        XCTAssertGreaterThan(line.inside, 0, "line: the line draws")
        XCTAssertEqual(line.outside, 0, "line: ink outside its own bounds")
    }

    // MARK: the whole sheet, never-shown window

    private static let path = "/Users/example/.claude/no\u{202E}tes.md"
    private static let shownPath = "/Users/example/.claude/no\\u{202E}tes.md"
    private static let note = "Claude Code will run `kit\u{202E}run` as the status line in every session."
    private static let shownNote = "Claude Code will run `kit\\u{202E}run` as the status line in every session."
    /// Three marks on two letters, then an override: one short line once displayed.
    private static let hostile = "a\u{0323}\u{0323}\u{0323}b\u{0323}\u{0323}\u{0323}\u{202E}cd"
    private static let shownHostile = "+ a\u{0323}\u{0323}\\u{0323}b\u{0323}\u{0323}\\u{0323}\\u{202E}cd"
    private static let ordinary = "+ Always ask first."

    private static func file(lines: [ManagedConfigChangeSet.Line]) -> ManagedConfigChangeSet.File {
        ManagedConfigChangeSet.File(target: "claude:no\u{202E}tes.md", path: path,
                                    backupDirectory: "/Users/example/.config/prosper/managed-config/backups/claude",
                                    lines: lines, notes: [note])
    }

    private static func set(_ files: [ManagedConfigChangeSet.File]) -> ManagedConfigChangeSet {
        ManagedConfigChangeSet(action: .apply, owner: owner, displayName: "Fake Kit", files: files, pieces: [])
    }

    private func model(first: String) -> ManagedConfigConsentModel {
        ManagedConfigConsentModel(changes: Self.set([Self.file(lines: [.init(sign: .added, text: first), .init(sign: .added, text: "Always ask first.")])])) { _ in }
    }

    private func fitting(_ model: ManagedConfigConsentModel) -> CGSize {
        let width = sz(ManagedConfigConsentPanel.width)
        let h = NSHostingController(rootView: ManagedConfigConsentView(model: model)).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: h)
    }

    private func tree(_ model: ManagedConfigConsentModel, _ size: CGSize) -> [AXTreeNode] {
        let view = ManagedConfigConsentView(model: model).frame(width: size.width).frame(maxHeight: .infinity, alignment: .top)
        return AXTreeSupport.tree(view, size) { t in t.contains { $0.named("Apply") } && t.contains { $0.named(Self.ordinary) } }
    }

    /// A line with stacked marks and an override next to an ordinary line: the sheet draws and lists the displayed form,
    /// and the ordinary line, the id line and the buttons keep the frames they have under a harmless first line.
    func testAHostileLineLeavesItsNeighbourTheIdAndTheButtonsWhereTheyAre() throws {
        let plain = model(first: "abcd"), bad = model(first: Self.hostile)
        XCTAssertTrue(bad.renderedStrings.map { Self.scalars($0) }.contains(Self.scalars(Self.shownHostile)), "\(bad.renderedStrings)")
        let size = fitting(plain)
        fputs("mc1252 fact sheet: fitted height plain \(size.height), hostile \(fitting(bad).height)\n", stderr)
        let a = tree(plain, size), b = tree(bad, size)
        // what an AX client reads is what is drawn: the displayed forms, scalar for scalar
        for shown in [Self.shownHostile, Self.shownPath, Self.shownNote] {
            XCTAssertTrue(b.contains { $0.names.contains { Self.scalars($0) == Self.scalars(shown) } }, "\(shown.debugDescription) on the tree: \(b.map(\.names))")
        }
        XCTAssertFalse(b.contains { $0.names.contains { $0.unicodeScalars.contains("\u{202E}") } }, "no raw override on the tree")
        func near(_ p: CGRect, _ q: CGRect) -> Bool {
            abs(p.minX - q.minX) <= 0.5 && abs(p.minY - q.minY) <= 0.5 && abs(p.width - q.width) <= 0.5 && abs(p.height - q.height) <= 0.5
        }
        for label in [Self.ordinary, Self.owner, "Cancel", "Apply"] {
            let before = try XCTUnwrap(a.first { $0.named(label) && $0.frame.height > 0 }, "plain: \(label)")
            let after = try XCTUnwrap(b.first { $0.named(label) && $0.frame.height > 0 }, "hostile: \(label): \(b.map(\.names))")
            XCTAssertTrue(near(before.frame, after.frame), "\(label): \(after.frame) under the hostile line, \(before.frame) under a harmless one")
        }
    }

    // MARK: what is written

    /// The display changes nothing that is written: Allow (the recording consent) writes the kit's block with every raw
    /// scalar, in this row's own tempDir(), while the sheet built from the same change set lists the escaped form.
    func testTheDisplayChangesNothingThatIsWritten() async throws {
        let env = makeMCEnv()
        let text = Self.hostile + "\nAlways ask first."
        _ = await env.mc.apply([MCPieces.block(text: text)], owner: env.owner)
        let changes = try XCTUnwrap(env.consent.seen.first)
        let lines = changes.files.flatMap(\.lines)
        XCTAssertTrue(lines.contains { Self.scalars($0.text) == Self.scalars(Self.hostile) }, "the change set carries the raw line")
        let m = ManagedConfigConsentModel(changes: changes) { _ in }
        XCTAssertTrue(m.renderedStrings.map { Self.scalars($0) }.contains(Self.scalars(Self.shownHostile)), "\(m.renderedStrings)")
        XCTAssertTrue(m.changes == changes, "the sheet's model keeps the change set as it came")
        let written = try XCTUnwrap(env.bytes(env.claudeMD), "Allow wrote the file")
        let raw = Array(text.utf8), escaped = Array("\\u{202E}".utf8)
        func holds(_ needle: [UInt8]) -> Bool { written.indices.contains { written[$0...].starts(with: needle) } }
        XCTAssertTrue(holds(raw), "the kit's block, byte for byte")
        XCTAssertFalse(holds(escaped), "no escape of the display reaches the file")
    }
}
