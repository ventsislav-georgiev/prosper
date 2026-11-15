import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1252 (QA F1054-1): the consent sheet's diff lines, path, notes and backup line are outside text. Each is shown through
/// ManagedConfigConsentDisplay (an unseen scalar as its visible escape, at most three marks per base drawn as marks and
/// each further one as its escape in place, backslashes before "u{" doubled, a 2000-scalar ceiling with a counted rest) and each diff line is
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
        // R1252-q1: a text whose first letter is not an ASCII letter is shown after U+200E (left to right), as written
        for line in [
            "\u{039A}\u{03B1}\u{03BB}\u{03B7}\u{03BC}\u{03AD}\u{03C1}\u{03B1}",   // Greek
            "\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD}",   // Hebrew, no direction controls
            "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}",                           // Japanese
            "\u{2022}\u{2022}\u{2022}\u{2022} \u{2026}",                           // the sheet's own mask and elision
        ] {
            check(line, "\u{200E}" + line, "as written \(Self.scalars(line))")
        }
        check("Vi\u{0065}\u{0323}\u{0302}t", "Vi\u{0065}\u{0323}\u{0302}t", "two marks on one letter, unchanged")
        // the joiner (a format scalar) and the emoji variation selector (default-ignorable) are shown as escapes
        check("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{200E}\u{1F468}\\u{200D}\u{1F469}\\u{200D}\u{1F467}", "family")
        check("\u{2764}\u{FE0F}", "\u{200E}\u{2764}\\u{FE0F}", "heart")
    }

    /// #1251 step 2 (F1251-s1-b): three marks per base (OutsideText.maxMarks); each further one is shown as its escape
    /// where it is written, so the display keeps the written order even when the character goes on after it.
    func testMarksPastThreeShowAsEscapesInPlace() {
        let a24 = "a" + String(repeating: "\u{0323}", count: 24)
        check(a24, "a\u{0323}\u{0323}\u{0323}" + String(repeating: "\\u{0323}", count: 21), "24 marks")
        check(a24 + "b", "a\u{0323}\u{0323}\u{0323}" + String(repeating: "\\u{0323}", count: 21) + "b", "24 marks then b")
        check("a\u{0323}\u{0301}\u{0302}b", "a\u{0323}\u{0301}\u{0302}b", "three kinds, kept")
        check("a\u{0323}\u{0301}\u{0302}\u{0304}b", "a\u{0323}\u{0301}\u{0302}\\u{0304}b", "four kinds")
        // the old joiner row (was: the last mark escaped, counted over the whole character). The count is per base and the
        // joiner is not a mark, so it starts a new count: one mark before it, two after it, nothing past three, all kept
        check("a\u{0323}\u{200D}\u{0301}\u{0302}", "a\u{0323}\\u{200D}\u{0301}\u{0302}", "joiner, nothing dropped")
        // a joiner between two groups of four marks: the fourth of each group escaped where it is written, the joiner after
        // the first group's escape (the rule before step 2 showed both escapes after the whole character)
        check("a\u{0323}\u{0323}\u{0323}\u{0323}\u{200D}\u{0301}\u{0301}\u{0301}\u{0301}",
              "a\u{0323}\u{0323}\u{0323}\\u{0323}\\u{200D}\u{0301}\u{0301}\u{0301}\\u{0301}", "joiner between two groups")
        // a conjunct whose fourth mark on its first consonant is the virama: escaped before the last consonant
        // (ka, nukta, two stress signs, virama, ssa)
        check("\u{0915}\u{093C}\u{0951}\u{0952}\u{094D}\u{0937}",
              "\u{200E}\u{0915}\u{093C}\u{0951}\u{0952}\\u{094D}\u{0937}", "fourth mark a virama")
        // a spacing mark (Mc, visarga) after four marks: not counted, kept after the fourth mark's escape
        check("\u{0915}\u{093C}\u{0951}\u{0952}\u{0953}\u{0903}",
              "\u{200E}\u{0915}\u{093C}\u{0951}\u{0952}\\u{0953}\u{0903}", "spacing mark after four")
    }

    /// The display read back to what is written: each escape of ours becomes its scalar, a doubled backslash one backslash
    /// and a leading U+200E (added by the display) goes. A run of backslashes, with the marks on them, is doubled only
    /// before "u{", so only there is it halved; an odd run there ends in an escape of ours.
    private static func readBack(_ shown: String) -> [UInt32] {
        var s = Array(shown.unicodeScalars)
        if s.first == "\u{200E}" { s.removeFirst() }
        func isMark(_ u: Unicode.Scalar) -> Bool {
            let g = u.properties.generalCategory
            return g == .nonspacingMark || g == .enclosingMark
        }
        var out: [UInt32] = [], i = 0
        while i < s.count {
            guard s[i] == "\\" else { out.append(s[i].value); i += 1; continue }
            var j = i
            while j < s.count, s[j] == "\\" || isMark(s[j]) { j += 1 }
            let run = s[i..<j]
            guard j + 1 < s.count, s[j] == "u", s[j + 1] == "{" else { out += run.map(\.value); i = j; continue }
            let slashes = run.filter { $0 == "\\" }.count
            var seen = 0
            for u in run {
                if u != "\\" { out.append(u.value); continue }
                seen += 1
                // the first of each doubled pair; an odd run's last backslash opens an escape
                if seen % 2 == 1, seen < slashes || slashes % 2 == 0 { out.append(u.value) }
            }
            guard slashes % 2 == 1 else { i = j; continue }
            var k = j + 2, hex = ""
            while k < s.count, s[k] != "}" { hex.unicodeScalars.append(s[k]); k += 1 }
            guard k < s.count, let v = UInt32(hex, radix: 16) else {
                XCTFail("not an escape of ours at \(j) in \(shown.debugDescription)")
                return out
            }
            out.append(v)
            i = k + 1
        }
        return out
    }

    /// ORDER (#1251 step 2): over a literal table, the displayed line read back gives the written scalars in the written
    /// order. The read-back is proved first on two plain lines, one with the line's own escape-shaped text.
    func testTheDisplayReadsBackToTheWrittenScalarsInOrder() {
        for plain in ["ls -la /Users/example", "path\\u{41} = \"\\\\n\""] {
            XCTAssertEqual(Self.readBack(ManagedConfigConsentDisplay.displayed(plain)), Self.scalars(plain), plain)
        }
        let lines: [String] = [
            "a\u{0323}\u{0323}\u{0323}\u{0323}\u{200D}\u{0301}\u{0301}\u{0301}\u{0301}", // a joiner between two groups of four marks
            "\u{0915}\u{093C}\u{0951}\u{0952}\u{094D}\u{0937}",                       // a fourth mark (virama) before the last consonant
            "\u{0915}\u{093C}\u{0951}\u{0952}\u{0953}\u{0903}",                       // a spacing mark after four marks
            "\\" + String(repeating: "\u{0323}", count: 4) + "x",                    // a backslash base with four marks, then x
            "a" + String(repeating: "\u{0301}", count: 24) + "b\u{202E}c",            // 24 marks, then an override
            "\u{05D1}\u{05BC}\u{05B8}\u{05BD}\u{05B0} \u{05E9}",                      // Hebrew: four marks on bet, then a word
            "\\\\u{41} e\u{0301}\u{0301}\u{0301}\u{0301}\u{0302}",                     // escape-shaped text, then five marks
            "\tk = 1\u{2028}x",                                                      // a tab kept, a line separator escaped
        ]
        for line in lines {
            let shown = ManagedConfigConsentDisplay.displayed(line)
            XCTAssertEqual(Self.readBack(shown), Self.scalars(line), "\(Self.scalars(line)) shown \(shown.debugDescription)")
        }
    }

    /// A backslash run shown just before "u{" or before an escape is doubled: an escape of ours always follows an even run.
    func testALiteralBackslashBeforeAnEscapeShapeIsDoubled() {
        check("\\u{202E}", "\\\\u{202E}", "literal escape text")
        check("x\\\\u{41}", "x\\\\\\\\u{41}", "two literal backslashes then u{")
        check("\\\u{202E}", "\\\\\\u{202E}", "a backslash then a real override")
        check("\\\\\u{202E}", "\\\\\\\\\\u{202E}", "two backslashes then a real override")
        // R1252-q1: a mark is the first non-ASCII scalar here: U+200E in front
        check("\\\u{0301}\u{202E}", "\u{200E}\\\\\u{0301}\\u{202E}", "a backslash with a mark then a real override")
        check("\\" + String(repeating: "\u{0323}", count: 3), "\u{200E}\\\u{0323}\u{0323}\u{0323}", "a backslash with three marks, kept")
        // QA r1104: a backslash base with four marks, then a kept letter: the fourth mark's escape comes in place, right
        // after the kept marks, so the run (the backslash with its marks) is doubled before it
        check("\\" + String(repeating: "\u{0323}", count: 4) + "x", "\u{200E}\\\\\u{0323}\u{0323}\u{0323}\\u{0323}x",
              "a backslash with four marks, then x")
        check("a\\b\\", "a\\b\\", "other backslashes stay single")
    }

    func testALongLineIsCutWithItsRestCounted() {
        check(String(repeating: "a", count: 5000), String(repeating: "a", count: 2000) + "\u{2026} (+3000 more characters, not shown)", "5000")
        check(String(repeating: "a", count: 2000), String(repeating: "a", count: 2000), "2000 is whole")
        check(String(repeating: "a", count: 2001), String(repeating: "a", count: 2000) + "\u{2026} (+1 more characters, not shown)", "2001")
        // the ceiling counts scalars: 1000 letters with 4 marks each are 5000 scalars, 400 letters shown; the rest is
        // counted in characters (R1252-q3): 600 letters with their marks
        let stacked = String(repeating: "a\u{0323}\u{0323}\u{0323}\u{0323}", count: 1000)
        let shown = String(repeating: "a\u{0323}\u{0323}\u{0323}\\u{0323}", count: 400) + "\u{2026} (+600 more characters, not shown)"
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
    /// Four marks on two letters, then an override: one short line once displayed.
    private static let hostile = "a\u{0323}\u{0323}\u{0323}\u{0323}b\u{0323}\u{0323}\u{0323}\u{0323}\u{202E}cd"
    private static let shownHostile = "+ a\u{0323}\u{0323}\u{0323}\\u{0323}b\u{0323}\u{0323}\u{0323}\\u{0323}\\u{202E}cd"
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

    // MARK: R1252-q1, a text whose first letter is right-to-left

    private static let lrm = "\u{200E}"
    /// A Hebrew word, a left-to-right word, a Hebrew letter, a left-to-right word: no control character at all.
    private static let rtlFirst = "\u{05D0}\u{05D1} ab \u{05D2} yz"

    /// The displayed form starts with U+200E and then holds the line's own scalars in the written order; a text whose first
    /// letter is an ASCII letter, or one that is ASCII only, is shown as before.
    func testATextWhoseFirstLetterIsRightToLeftIsShownLeftToRight() {
        let shown = ManagedConfigConsentDisplay.displayed(Self.rtlFirst)
        XCTAssertEqual(Self.scalars(shown).first, 0x200E, shown.debugDescription)
        XCTAssertEqual(Array(Self.scalars(shown).dropFirst()), Self.scalars(Self.rtlFirst), "the line's own scalars, in the written order")
        check("\u{0627}\u{0628} x", Self.lrm + "\u{0627}\u{0628} x", "Arabic first")
        check("  \"\u{05D0}\": 1", Self.lrm + "  \"\u{05D0}\": 1", "ASCII neutrals, then Hebrew")
        check("1 \u{05D0}", Self.lrm + "1 \u{05D0}", "a digit is not a letter")
        check("ab \u{05D0} yz", "ab \u{05D0} yz", "an ASCII letter first: left to right already")
        for plain in ["{", "  },", "", "   ", "x = 1"] { check(plain, plain, "ASCII only \(plain.debugDescription)") }
        // an escape of ours is drawn text: its letter u comes first
        check("\u{202E}\u{05D0}", "\\u{202E}\u{05D0}", "an escape first")
        // the diff line: our sign, then the mark, then the line; the mark does not count toward the cut
        let line = ManagedConfigChangeSet.Line(sign: .added, text: Self.rtlFirst)
        XCTAssertEqual(Self.scalars(ManagedConfigConsentModel.text(line)), Self.scalars("+ " + Self.lrm + Self.rtlFirst))
        check("\u{05D0}" + String(repeating: "a", count: 2000),
              Self.lrm + "\u{05D0}" + String(repeating: "a", count: 1999) + "\u{2026} (+1 more characters, not shown)", "cut")
    }

    /// The path, a note and the backup line get the mark through the same display function as a diff line, and the sheet's
    /// tree reads the line's words (the fact line says whether the mark is in the value an AX client gets).
    func testThePathNotesAndBackupLineGetTheMarkThroughTheDisplay() throws {
        let heb = "\u{05D0}\u{05D1}"
        let file = ManagedConfigChangeSet.File(target: "claude:x.md", path: heb + "/x.md", backupDirectory: heb + "/backups",
                                               lines: [.init(sign: .added, text: heb + " x")], notes: [heb + " note"])
        let m = ManagedConfigConsentModel(changes: Self.set([file])) { _ in }
        XCTAssertEqual(Self.scalars(m.backupLine(file)), Self.scalars("Backup: " + Self.lrm + heb + "/backups"))
        let strings = m.renderedStrings.map { Self.scalars($0) }
        for s in [Self.lrm + heb + "/x.md", "+ " + Self.lrm + heb + " x", Self.lrm + heb + " note", "Backup: " + Self.lrm + heb + "/backups"] {
            XCTAssertTrue(strings.contains(Self.scalars(s)), "\(s.debugDescription) in \(m.renderedStrings)")
        }
        let bad = model(first: Self.rtlFirst)
        let b = tree(bad, fitting(bad))
        let words = Self.scalars("+ " + Self.rtlFirst)
        let node = b.first { $0.names.contains { Self.scalars($0).filter { $0 != 0x200E } == words } }
        XCTAssertTrue(node != nil, "the line on the tree: \(b.map(\.names))")
        let marked = node?.names.contains { $0.unicodeScalars.contains("\u{200E}") } ?? false
        fputs("mc1252b fact accessibility: the line's names \((node?.names ?? []).map { Self.scalars($0).prefix(4) }), mark in them \(marked)\n", stderr)
    }

    /// Offscreen: "+ " and the right-to-left-first line, and "+ " and the line's own head (up to its first left-to-right word),
    /// each drawn by the diff line view at scale 1. The head's pixels must be the line's leftmost pixels: the sign at the left
    /// edge, then the Hebrew word, then "ab" where it is written, so "yz" can only lie further right. The control, the same
    /// two strings in a plain Text without the display (the parent's drawing), must differ there, or the method proves nothing.
    func testARightToLeftWordLeavesTheSignAndTheWordsInWrittenOrder() throws {
        let head = "\u{05D0}\u{05D1} ab"
        // main actor (ImageRenderer); called only from this row
        @MainActor func pixels<V: View>(_ v: V, _ tag: String) throws -> (width: Int, height: Int, row: Int, bytes: [UInt8]) {
            let r = ImageRenderer(content: v.fixedSize().background(Color.black))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage, tag)
            XCTAssertLessThanOrEqual(cg.width, 800, tag)
            XCTAssertLessThanOrEqual(cg.height, 200, tag)
            XCTAssertEqual(cg.bitsPerPixel, 32, tag)
            return (cg.width, cg.height, cg.bytesPerRow, [UInt8](try XCTUnwrap(cg.dataProvider?.data as Data?, tag)))
        }
        // nil when the two images cannot be compared; the head's last two columns are left out (its last glyph's edge)
        @MainActor func headLeads<L: View, H: View>(_ line: L, _ first: H, _ tag: String) throws -> Bool? {
            let l = try pixels(line, tag + " line"), h = try pixels(first, tag + " head")
            guard l.height == h.height, h.width > 4, l.width > h.width, l.row >= l.width * 4, h.row >= h.width * 4,
                  l.bytes.count >= l.row * l.height, h.bytes.count >= h.row * h.height else {
                XCTFail("\(tag): line \(l.width)x\(l.height), head \(h.width)x\(h.height)")
                return nil
            }
            let n = (h.width - 2) * 4
            let same = (0..<h.height).allSatisfy { y in l.bytes[(y * l.row)..<(y * l.row + n)].elementsEqual(h.bytes[(y * h.row)..<(y * h.row + n)]) }
            fputs("mc1252b fact \(tag): line \(l.width)x\(l.height), head \(h.width)x\(h.height), left \(h.width - 2) columns equal \(same)\n", stderr)
            return same
        }
        let font = Neon.font(11, design: .monospaced)
        let control = try headLeads(Text(verbatim: "+ " + Self.rtlFirst).font(font).foregroundStyle(Neon.terminal),
                                    Text(verbatim: "+ " + head).font(font).foregroundStyle(Neon.terminal), "control")
        XCTAssertEqual(control, false, "control: the plain line must not start like its head, or the method cannot see the order")
        guard control == false else { return }
        @MainActor func drawn(_ text: String) -> ManagedConfigConsentDiffLine {
            ManagedConfigConsentDiffLine(text: ManagedConfigConsentModel.text(.init(sign: .added, text: text)), color: Neon.terminal)
        }
        let line = try headLeads(drawn(Self.rtlFirst), drawn(head), "line")
        XCTAssertEqual(line, true, "line: the sign and the first words are not where they are written")
    }

    // MARK: R1252-q3, a cut line

    func testACutLineSaysHowManyCharactersAreNotShown() {
        // 2500 letters with one mark each are 5000 scalars: the first 2000 are 1000 letters, the rest 1500 characters
        check(String(repeating: "e\u{0301}", count: 2500),
              String(repeating: "e\u{0301}", count: 1000) + "\u{2026} (+1500 more characters, not shown)", "marks")
        XCTAssertTrue(ManagedConfigConsentDisplay.isCut(String(repeating: "a", count: 2001)))
        XCTAssertFalse(ManagedConfigConsentDisplay.isCut(String(repeating: "a", count: 2000)))
    }

    /// One note under the cards when any line is cut (two cut lines: still one), none without; on the tree the note is
    /// there once and meets none of the title, the id line and the buttons.
    func testOneNoteSaysWhenALineIsCut() throws {
        let note = ManagedConfigConsentModel.cutNote
        XCTAssertEqual(note, "A line is too long to show here in full: read the whole file before you approve.")
        let long = String(repeating: "a", count: 2001)
        let cut = model(first: long), plain = model(first: "abcd")
        let two = ManagedConfigConsentModel(changes: Self.set([Self.file(lines: [.init(sign: .added, text: long)]),
                                                               Self.file(lines: [.init(sign: .removed, text: long)])])) { _ in }
        XCTAssertEqual(cut.renderedStrings.filter { $0 == note }.count, 1, "\(cut.renderedStrings.suffix(4))")
        XCTAssertEqual(two.renderedStrings.filter { $0 == note }.count, 1, "two cut lines, one note")
        XCTAssertEqual(plain.renderedStrings.filter { $0 == note }.count, 0, "nothing cut, no note")
        XCTAssertEqual(Array(cut.renderedStrings.suffix(3)), [note, "Cancel", "Apply"], "under the cards, above the buttons")
        let a = tree(plain, fitting(plain)), size = fitting(cut), b = tree(cut, size)
        fputs("mc1252b fact cut note: fitted height plain \(fitting(plain).height), with a cut line \(size.height)\n", stderr)
        XCTAssertFalse(a.contains { $0.named(note) }, "no note on the plain sheet")
        let shown = b.filter { $0.named(note) && $0.frame.height > 0 }
        XCTAssertEqual(Set(shown.map { $0.frame.minY.rounded() }).count, 1, "the note once: \(shown.map(\.frame))")
        let frame = try XCTUnwrap(shown.first, "\(b.map(\.names))").frame
        for label in ["Fake Kit", Self.owner, "Cancel", "Apply"] {
            let node = try XCTUnwrap(b.first { $0.named(label) && $0.frame.height > 0 }, "\(label): \(b.map(\.names))")
            XCTAssertFalse(node.frame.intersects(frame), "\(label) \(node.frame) meets the note \(frame)")
        }
    }
}
