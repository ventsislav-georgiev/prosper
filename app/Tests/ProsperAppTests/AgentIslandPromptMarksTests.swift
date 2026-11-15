import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1251: on the island's permission card a character with more than two combining marks (Mn, Me) makes the prompt
/// hidden (only a deny answers, the hidden caption shows) and the card shows the further marks escaped after the
/// character; every prompt row is clipped to its fixed slot. Rows build prompts and the card model and read them;
/// nothing is sent. Renders are offscreen (ImageRenderer, scale 1, no window, no file). Prompt texts are made up.
final class AgentIslandPromptMarksTests: XCTestCase {
    private typealias G = AgentIslandGeometry

    /// String == folds canonically equivalent text: expectations compare scalar by scalar.
    private static func scalars(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }
    private static func token(_ hex: String) -> String { "\u{27E8}U+\(hex)\u{27E9}" }
    private static func stack(_ base: String, _ mark: String, _ n: Int) -> String { base + String(repeating: mark, count: n) }

    private static let question = "Do you want to proceed?"
    private static let context = ["Bash command", "ls /Users/example"]

    private static func prompt(question: String = question, context: [String] = context, label: String = "Yes, for ls",
                               detail: [String] = [], preview: [String] = [], notes: [String] = []) -> AgentPrompt {
        AgentPrompt(question: question, context: context,
                    options: [AgentPromptOption(digit: 1, label: "Yes", hint: nil),
                              AgentPromptOption(digit: 2, label: label, hint: nil, detail: detail),
                              AgentPromptOption(digit: 3, label: "No", hint: nil)],
                    preview: preview, notes: notes)
    }

    // MARK: visible

    func testVisibleKeepsTwoMarksAndEscapesTheRestAfterTheCharacter() {
        // the short case written out: two marks kept, two tokens
        XCTAssertEqual(Self.scalars(AgentPrompt.visible("a\u{0323}\u{0323}\u{0323}\u{0323}")),
                       Self.scalars("a\u{0323}\u{0323}\u{27E8}U+0323\u{27E9}\u{27E8}U+0323\u{27E9}"))
        for (mark, hex) in [("\u{0323}", "0323"), ("\u{0301}", "0301"), ("\u{20DD}", "20DD")] {
            let shown = AgentPrompt.visible("x" + Self.stack("a", mark, 24) + "y")
            let expected = "x" + Self.stack("a", mark, 2) + String(repeating: Self.token(hex), count: 22) + "y"
            XCTAssertEqual(Self.scalars(shown), Self.scalars(expected), hex)
            XCTAssertTrue(shown.allSatisfy { $0.unicodeScalars.lazy.filter(AgentPrompt.isMark).count <= 2 }, hex)
        }
        // two marks on a character: unchanged
        for word in ["Vi\u{0065}\u{0323}\u{0302}t", "Caf\u{0065}\u{0301}"] {
            XCTAssertEqual(Self.scalars(AgentPrompt.visible(word)), Self.scalars(word), word)
        }
        // a spacing mark (Mc) is not counted
        let spacing = Self.stack("\u{0915}", "\u{0903}", 4)
        XCTAssertEqual(Self.scalars(AgentPrompt.visible(spacing)), Self.scalars(spacing))
        // a direction override and a mark stack: both escaped, in order
        XCTAssertEqual(Self.scalars(AgentPrompt.visible("\u{202E}a\u{0301}\u{0301}\u{0301}b")),
                       Self.scalars("\u{27E8}U+202E\u{27E9}a\u{0301}\u{0301}\u{27E8}U+0301\u{27E9}b"))
    }

    /// Plain ASCII takes the fast path: the very same string comes back (same UTF-8 storage), nothing rebuilt.
    func testVisibleReturnsPlainTextAsItIs() {
        let plain = String(repeating: "ls -la /Users/example ", count: 4)
        func address(_ s: String) -> UInt {
            var s = s
            return s.withUTF8 { UInt(bitPattern: $0.baseAddress) }
        }
        let shown = AgentPrompt.visible(plain)
        XCTAssertEqual(Self.scalars(shown), Self.scalars(plain))
        XCTAssertEqual(address(shown), address(plain), "the fast path returns its argument")
    }

    // MARK: hasHiddenCharacters

    func testAMarkStackInEachFieldIsHiddenAndTwoMarksAreNot() {
        for (s, hidden) in [(Self.stack("a", "\u{0323}", 3), true), ("Vi\u{0065}\u{0323}\u{0302}t Caf\u{0065}\u{0301}", false)] {
            let cases: [(String, AgentPrompt)] = [
                ("question", Self.prompt(question: s)), ("context", Self.prompt(context: Self.context + [s])),
                ("preview", Self.prompt(preview: ["plain", s])), ("notes", Self.prompt(notes: [s])),
                ("label", Self.prompt(label: s)), ("detail", Self.prompt(detail: ["plain", s])),
            ]
            for (field, p) in cases { XCTAssertEqual(p.hasHiddenCharacters, hidden, "\(field) \(Self.scalars(s))") }
        }
        XCTAssertFalse(Self.prompt().hasHiddenCharacters)
    }

    // MARK: the card

    /// The card's rows as drawn, through its text hook; rendered offscreen at scale 1 inside a 200 pt tall frame.
    @MainActor
    private func drawn(_ p: AgentPrompt) throws -> [String] {
        var texts: [String] = []
        // runs on main, inside the render below
        AgentPromptCardView.textHook = { s, _ in texts.append(s) }
        defer { AgentPromptCardView.textHook = nil }
        let r = ImageRenderer(content: AgentPromptCardView(card: .prompt(p))
            .frame(width: G.cardInner + 2 * G.cardPad, height: 200, alignment: .top))
        r.scale = 1
        let cg = try XCTUnwrap(r.cgImage)
        XCTAssertLessThanOrEqual(cg.width, 800)
        XCTAssertLessThanOrEqual(cg.height, 200)
        return texts
    }

    @MainActor
    func testAStackedQuestionOrContextLineIsDenyOnlyAndDrawnEscaped() throws {
        let stacked = "a\u{0323}\u{0323}\u{0323}\u{0323}", escaped = "a\u{0323}\u{0323}\u{27E8}U+0323\u{27E9}\u{27E8}U+0323\u{27E9}"
        let cases: [(String, AgentPrompt, String)] = [
            ("question", Self.prompt(question: "Proceed with \(stacked)?"), "Proceed with \(escaped)?"),
            ("context", Self.prompt(context: ["Bash command", "ls /Users/example/\(stacked)"]), "ls /Users/example/\(escaped)"),
        ]
        for (what, p, row) in cases {
            let l = p.layout
            XCTAssertTrue(p.hasHiddenCharacters, what)
            XCTAssertEqual(l.caption.joined(), "Hidden characters in this prompt, open the terminal to approve", what)
            XCTAssertEqual(l.caption.joined(), AgentCardLayout.hiddenCaption, what)
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, false, true], "\(what): only the deny answers")
            XCTAssertTrue((l.question + l.context).contains { Self.scalars($0) == Self.scalars(row) }, "\(what): \(l.question + l.context)")
            let texts = try drawn(p)
            XCTAssertTrue(texts.contains { Self.scalars($0) == Self.scalars(row) }, "\(what): drawn \(texts)")
            XCTAssertTrue(texts.contains("Hidden characters in this prompt, open the terminal to approve"), what)
            XCTAssertFalse(texts.contains { $0.contains { $0.unicodeScalars.lazy.filter(AgentPrompt.isMark).count > 2 } },
                           "\(what): no drawn character carries more than two marks")
        }
    }

    /// The control of the rule: the same prompts with two marks per character are not hidden and every answer is on.
    @MainActor
    func testTwoMarksPerCharacterStayApprovable() throws {
        let two = "a\u{0323}\u{0302}"
        let cases: [(AgentPrompt, String)] = [(Self.prompt(question: "Proceed with \(two)?"), "Proceed with \(two)?"),
                                              (Self.prompt(context: ["Bash command", "ls /Users/example/\(two)"]), "ls /Users/example/\(two)")]
        for (p, row) in cases {
            XCTAssertFalse(p.hasHiddenCharacters, row)
            XCTAssertEqual(p.layout.caption, [], row)
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, true, true], row)
            let texts = try drawn(p)
            XCTAssertTrue(texts.contains { Self.scalars($0) == Self.scalars(row) }, "drawn as it is: \(texts)")
        }
    }

    /// An ordinary card renders exactly the height the model counts (the clip sizes nothing).
    @MainActor
    func testAnOrdinaryCardKeepsItsCountedSize() throws {
        let card = AgentCard.prompt(Self.prompt())
        let r = ImageRenderer(content: AgentPromptCardView(card: card).frame(width: G.cardInner + 2 * G.cardPad))
        r.scale = 1
        let cg = try XCTUnwrap(r.cgImage)
        XCTAssertEqual(CGFloat(cg.width), G.cardInner + 2 * G.cardPad)
        XCTAssertEqual(CGFloat(cg.height), G.cardHeight(card))
        XCTAssertLessThanOrEqual(cg.height, 200)
    }

    // MARK: the clip, rendered offscreen

    /// The card's row slot fed a RAW string (not through `visible`): 24 marks below and 24 above on each letter, on a
    /// black field 60 pt above and below. No pixel row outside the slot differs from the background. The control, the
    /// same Text in the same unclipped frame, must put ink there, or the method proves nothing.
    @MainActor
    func testACardRowDrawsNothingOutsideItsSlot() throws {
        let raw = "ls " + ["a", "b", "c"].map { $0 + String(repeating: "\u{0323}", count: 24) + String(repeating: "\u{0301}", count: 24) }.joined()
        let width: CGFloat = 400, pad: CGFloat = 60, slot = G.cardQuestion
        let ref = try XCTUnwrap(ImageRenderer(content: Color.black.frame(width: 4, height: 4)).cgImage)
        let refBytes = [UInt8](try XCTUnwrap(ref.dataProvider?.data as Data?))
        let bpp = ref.bitsPerPixel / 8
        XCTAssertEqual(ref.bitsPerPixel, 32)
        let background = Array(refBytes.prefix(bpp))
        // main actor (ImageRenderer); called only from this row
        @MainActor func ink<V: View>(_ row: V, _ tag: String) throws -> (outside: Int, inside: Int) {
            let r = ImageRenderer(content: VStack(spacing: 0) {
                Color.clear.frame(height: pad)
                row.frame(width: width, alignment: .leading)
                Color.clear.frame(height: pad)
            }.background(Color.black))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage, tag)
            XCTAssertLessThanOrEqual(cg.width, 800, tag)
            XCTAssertLessThanOrEqual(cg.height, 200, tag)
            XCTAssertEqual(cg.bitsPerPixel, ref.bitsPerPixel, tag)
            XCTAssertEqual(cg.bitmapInfo, ref.bitmapInfo, tag)
            let bytes = [UInt8](try XCTUnwrap(cg.dataProvider?.data as Data?, tag))
            let stride = cg.bytesPerRow
            guard cg.bitsPerPixel == ref.bitsPerPixel, bytes.count >= stride * cg.height, stride >= cg.width * bpp else {
                XCTFail("\(tag): unexpected bitmap \(cg.width)x\(cg.height) row \(stride) bytes \(bytes.count)")
                return (0, 0)
            }
            let top = Int(pad), bottom = Int((pad + slot).rounded(.up))
            var outside = 0, inside = 0
            for y in 0..<cg.height {
                let start = y * stride
                let drawn = (0..<cg.width).contains { x in !bytes[(start + x * bpp)..<(start + x * bpp + bpp)].elementsEqual(background) }
                guard drawn else { continue }
                if y < top || y >= bottom { outside += 1 } else { inside += 1 }
            }
            fputs("marks1251b fact \(tag): image \(cg.width)x\(cg.height), slot rows \(top)..<\(bottom), ink rows outside \(outside), inside \(inside)\n", stderr)
            return (outside, inside)
        }
        let text = Text(raw).font(Font(G.questionFont)).foregroundStyle(Color.white).lineLimit(1)
        let control = try ink(text.frame(height: slot, alignment: .leading), "control")
        XCTAssertGreaterThan(control.inside, 0, "control: the row draws")
        XCTAssertGreaterThan(control.outside, 0, "control: no ink outside an unclipped slot: the measuring method is wrong, not the clip")
        guard control.outside > 0 else { return }
        let row = try ink(text.agentCardSlot(height: slot, alignment: .leading), "card row")
        XCTAssertGreaterThan(row.inside, 0, "card row: the row draws")
        XCTAssertEqual(row.outside, 0, "card row: ink outside its slot")
    }

    // MARK: B1251-2: the marks are counted per base (each consonant of a conjunct is its own base)

    /// QA 1064's Hindi words (OutsideTextTests.words) in a prompt: not hidden, drawn as they are, the allow answers on.
    @MainActor
    func testOrdinaryConjunctsStayApprovable() {
        for w in OutsideTextTests.words {
            let p = Self.prompt(question: "Proceed with \(w)?", context: ["Bash command", "ls /Users/example/\(w)"])
            XCTAssertFalse(p.hasHiddenCharacters, "\(Self.scalars(w))")
            XCTAssertEqual(Self.scalars(AgentPrompt.visible(w)), Self.scalars(w))
            XCTAssertEqual(p.layout.caption, [], "\(Self.scalars(w))")
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [true, true, true], "\(Self.scalars(w)): every answer is on")
        }
    }

    @MainActor
    func testAThirdMarkOnOneBaseIsHiddenAndEscaped() {
        let cases = [
            // a Latin letter with three marks
            ("a\u{0323}\u{0301}\u{0302}", "a\u{0323}\u{0301}" + Self.token("0302")),
            // a Hindi conjunct whose second consonant carries three marks (vowel sign u, anusvara, stress sign)
            ("\u{0938}\u{094D}\u{0924}\u{0941}\u{0902}\u{0951}", "\u{0938}\u{094D}\u{0924}\u{0941}\u{0902}" + Self.token("0951")),
        ]
        for (s, shown) in cases {
            let p = Self.prompt(question: "Proceed with \(s)?")
            XCTAssertTrue(p.hasHiddenCharacters, "\(Self.scalars(s))")
            XCTAssertEqual(p.layout.caption.joined(), AgentCardLayout.hiddenCaption, "\(Self.scalars(s))")
            XCTAssertEqual(p.options.map { p.isEnabled($0) }, [false, false, true], "\(Self.scalars(s)): only the deny answers")
            XCTAssertEqual(Self.scalars(AgentPrompt.visible(s)), Self.scalars(shown))
        }
    }

    /// The card's mark rule and OutsideText.capMarks cannot drift apart: over texts with no hidden scalar, the card
    /// hides a prompt exactly when capMarks changes its text.
    func testTheCardAndOutsideTextAgreeOnTheMarkRule() {
        let texts = [
            "ls /Users/example",                                   // plain
            "Caf\u{0065}\u{0301}", "Vi\u{0065}\u{0323}\u{0302}t", // at most two marks on a letter
            "a\u{0323}\u{0323}\u{0323}",                          // three marks on one letter
            "a\u{0323}\u{0323}b\u{0301}\u{0301}",                 // two marks on each of two letters
            "a\u{0323}\u{0323}\u{0323}b\u{0301}\u{0301}\u{0301}", // three marks on each of two letters
            "\u{0938}\u{094D}\u{0924}\u{0941}\u{0902}\u{0951}",   // a Hindi conjunct, three marks on its second consonant
            "\u{0938}\u{093C}\u{094D}\u{0951}\u{0924}",           // a Hindi conjunct, three marks on its first consonant
            "\u{0915}\u{0903}\u{0903}\u{0903}",                   // spacing marks (Mc), not counted
        ] + OutsideTextTests.words + [OutsideTextTests.bengali]
        for s in texts {
            let changed = Self.scalars(OutsideText.capMarks(s)) != Self.scalars(s)
            XCTAssertEqual(Self.prompt(question: s).hasHiddenCharacters, changed, "\(Self.scalars(s))")
        }
        XCTAssertEqual(texts.filter { Self.prompt(question: $0).hasHiddenCharacters }.count, 4, "the table holds both outcomes")
    }

    /// Facts for the report (B1251-2 item 5), not a rule: the ink height of one unclipped line in the question font, in
    /// pixel rows with ink on a black field. Only the method is asserted (a 24-mark pile on one base must come out
    /// taller than a plain line, or the method proves nothing); the other heights are printed (font-dependent).
    @MainActor
    func testInkHeightsOfMarksAfterRestartsAndOfSubjoinedChains() throws {
        let pad: CGFloat = 80
        let ref = try XCTUnwrap(ImageRenderer(content: Color.black.frame(width: 4, height: 4)).cgImage)
        let background = Array([UInt8](try XCTUnwrap(ref.dataProvider?.data as Data?)).prefix(ref.bitsPerPixel / 8))
        // main actor (ImageRenderer); called only from this row
        @MainActor func inkHeight(_ s: String, _ tag: String) throws -> Int {
            let r = ImageRenderer(content: VStack(spacing: 0) {
                Color.clear.frame(height: pad)
                Text(s).font(Font(G.questionFont)).foregroundStyle(Color.white).lineLimit(1)
                    .frame(width: 600, height: G.cardQuestion, alignment: .leading)
                Color.clear.frame(height: pad)
            }.background(Color.black))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage, tag)
            XCTAssertLessThanOrEqual(cg.width, 800, tag)
            XCTAssertLessThanOrEqual(cg.height, 200, tag)
            let bytes = [UInt8](try XCTUnwrap(cg.dataProvider?.data as Data?, tag))
            let bpp = cg.bitsPerPixel / 8, stride = cg.bytesPerRow
            guard cg.bitsPerPixel == ref.bitsPerPixel, bytes.count >= stride * cg.height, stride >= cg.width * bpp else {
                XCTFail("\(tag): unexpected bitmap \(cg.width)x\(cg.height) row \(stride) bytes \(bytes.count)")
                return 0
            }
            let rows = (0..<cg.height).filter { y in
                (0..<cg.width).contains { x in !bytes[(y * stride + x * bpp)..<(y * stride + x * bpp + bpp)].elementsEqual(background) }
            }
            let height = rows.isEmpty ? 0 : (rows.last ?? 0) - (rows.first ?? 0) + 1
            fputs("marks1251d fact \(tag): characters \(s.count), image \(cg.width)x\(cg.height), ink rows \(rows.first ?? -1)...\(rows.last ?? -1), height \(height)\n", stderr)
            return height
        }
        let plain = try inkHeight("ls /Users/example", "plain line")
        let control = try inkHeight("a" + String(repeating: "\u{0323}", count: 24), "control: 24 marks on one base")
        XCTAssertGreaterThan(control, plain, "the control is not taller than a plain line: the measurement proves nothing")
        // two marks, then a spacing mark (Mc), 24 times, on one base
        _ = try inkHeight("\u{0915}" + String(repeating: "\u{0323}\u{0323}\u{0903}", count: 24), "Mc restarts")
        // Devanagari and Bengali: consonant, nukta, virama, 24 times, then a consonant (two marks per consonant)
        _ = try inkHeight(String(repeating: "\u{0915}\u{093C}\u{094D}", count: 24) + "\u{0915}", "Devanagari chain")
        _ = try inkHeight(String(repeating: "\u{0995}\u{09BC}\u{09CD}", count: 24) + "\u{0995}", "Bengali chain")
        // Khmer: a consonant, then 12 pairs of the subscript sign (one mark) and a consonant
        _ = try inkHeight("\u{1780}" + String(repeating: "\u{17D2}\u{1780}", count: 12), "Khmer chain")
    }
}
