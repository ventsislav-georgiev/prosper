import AppKit
import XCTest
@testable import ProsperApp

/// #842: the `{argument}` fill-in. Argument collection, the decision on each path
/// (typed keyword, `sn` palette, bound hotkey), and the collect-then-insert flow,
/// driven through `SnippetExpander`'s seams: no real panel is shown, no app is
/// activated, no key event is posted, secure input is never read. The panel is
/// built offscreen and never ordered front or made key.
@MainActor
final class SnippetFillInTests: XCTestCase {

    // MARK: - Collection: order, dedup, defaults, nesting

    func testArgumentsInFirstSeenOrderDedupedFirstDefaultWins() {
        let specs = PlaceholderEngine.arguments(in:
            "{argument name=\"a\"} {argument name=\"b\" default=\"x\"} {argument name=\"a\" default=\"y\"} {argument}")
        XCTAssertEqual(specs, [ArgumentSpec(name: "a", defaultValue: nil),
                               ArgumentSpec(name: "b", defaultValue: "x"),
                               ArgumentSpec(name: "argument", defaultValue: nil)])
        XCTAssertEqual(specs.map(\.required), [true, false, true])
    }

    func testNestedSnippetArgumentsCollectedWhereTheEmbedSits() {
        let bodies = ["sig": "{argument name=\"from\" default=\"me\"} {argument name=\"to\"}",
                      "loop": "{snippet:loop} {argument name=\"deep\"}"]
        let specs = PlaceholderEngine.arguments(
            in: "{argument name=\"to\"} {snippet:sig} {argument name=\"cc\"} {snippet:loop}",
            snippetByKeyword: { bodies[$0] })
        // "to" once (first seen), "from" from the embed, then "cc"; a self-embedding snippet terminates.
        XCTAssertEqual(specs.map(\.name), ["to", "from", "cc", "deep"])
        XCTAssertEqual(specs[1].defaultValue, "me")
    }

    func testFillInFieldsReadRichPlainProjectionAndSkipTextReplacements() throws {
        let attributed = NSAttributedString(string: "Dear {argument name=\"who\"},")
        let data = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
        let rtf = try XCTUnwrap(String(data: data, encoding: .utf8))
        let rich = SnippetHit(name: "R", text: rtf, richText: true)
        XCTAssertEqual(SnippetExpander.fillInFields(rich, snippetByKeyword: { _ in nil }).map(\.name), ["who"])
        let literal = SnippetHit(name: "omw", text: "On my way {argument}", literal: true)
        XCTAssertEqual(SnippetExpander.fillInFields(literal, snippetByKeyword: { _ in nil }), [])
    }

    // MARK: - plan(): needsArguments is a prompt request

    private func plan(_ hit: SnippetHit, buffer: String, trigger: String, boundary: Bool = false,
                      _ context: PlaceholderContext = PlaceholderContext()) -> SnippetExpansionDecision {
        SnippetExpander.plan(buffer: buffer, keywords: [(trigger, hit.name)],
                             lookup: { $0 == hit.name ? hit : nil }, context: context,
                             wordBoundaryMode: boundary)
    }

    func testWordBoundaryRequestCountsTheDeliveredDelimiter() {
        let hit = SnippetHit(name: "S", keyword: "sig", text: "To {argument name=\"to\"}")
        // "sig" + " " both reach the field (nothing swallowed): erase 4, re-append the space.
        XCTAssertEqual(plan(hit, buffer: "sig ", trigger: "sig", boundary: true),
                       .needsArguments(name: "S", backspaces: 4, delimiter: " "))
    }

    func testNestedArgumentAsksThroughContextLookup() {
        let hit = SnippetHit(name: "N", keyword: ";n", text: "x {snippet:inner}")
        var ctx = PlaceholderContext()
        ctx.snippetByKeyword = { $0 == "inner" ? "{argument name=\"q\"}" : nil }
        XCTAssertEqual(plan(hit, buffer: ";n", trigger: ";n", ctx), .needsArguments(name: "N", backspaces: 2, delimiter: ""))
        ctx.arguments = ["q": "v"]
        XCTAssertEqual(plan(hit, buffer: ";n", trigger: ";n", ctx),
                       .insertPlain(name: "N", backspaces: 1, insertText: "x v", leftArrows: 0))
    }

    func testRichWithArgumentAsks() {
        let hit = SnippetHit(name: "R", keyword: ";r", text: "body {argument}", richText: true)
        XCTAssertEqual(plan(hit, buffer: ";r", trigger: ";r"), .needsArguments(name: "R", backspaces: 2, delimiter: ""))
    }

    func testTextReplacementNeverAsks() {
        let hit = SnippetHit(name: "omw", keyword: "omw", text: "On my way {argument}", literal: true)
        XCTAssertEqual(plan(hit, buffer: "omw", trigger: "omw"),
                       .insertPlain(name: "omw", backspaces: 2, insertText: "On my way {argument}", leftArrows: 0))
    }

    // MARK: - Flow through seams

    private var prompts: [(title: String, fields: [ArgumentSpec])] = []
    private var answer: (@MainActor ([String: String]?) -> Void)?
    private var activated: [pid_t] = []
    private var executed: [(SnippetExpansionDecision, [String: String], String?)] = []
    private var frontmost: pid_t? = 4242
    private var secure = false
    private var appGone = false

    private func expander() -> SnippetExpander {
        let e = SnippetExpander()
        e.prompt = { [unowned self] title, fields, done in
            prompts.append((title, fields))
            answer = done
        }
        e.activateApp = { [unowned self] pid in activated.append(pid); return !appGone }
        e.frontmostPID = { [unowned self] in frontmost }
        e.secureInputActive = { [unowned self] in secure }
        e.focusSettle = 0
        e.execute = { [unowned self] d, args, bundle in executed.append((d, args, bundle)) }
        return e
    }

    /// Runs the main loop until `done` or 0.3 s, so the post-focus insert (settle 0) can land.
    private func settle(until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(0.3)
        while Date() < end, !done() { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private let greet = SnippetHit(name: "greet", keyword: ";hi",
                                   text: "Hi {argument name=\"who\"}{cursor}!{argument name=\"tone\" default=\"!\"}")

    func testTypedKeywordPromptsLetsTheKeyThroughThenInsertsIntoTheTarget() {
        let e = expander()
        let decision = plan(greet, buffer: ";hi", trigger: ";hi")
        XCTAssertFalse(e.run(decision, hit: greet, context: PlaceholderContext(), bundleId: "com.example.ed"),
                       "the trigger key is not swallowed: the keyword stays typed while the panel asks")
        XCTAssertEqual(prompts.map(\.title), ["greet"])
        XCTAssertEqual(prompts.first?.fields, [ArgumentSpec(name: "who", defaultValue: nil),
                                               ArgumentSpec(name: "tone", defaultValue: "!")])
        XCTAssertTrue(executed.isEmpty, "nothing inserted while the panel is open")

        answer?(["who": "Ann", "tone": "?"])
        settle { !executed.isEmpty }
        XCTAssertEqual(activated, [4242], "focus returns to the app the keyword was typed in")
        XCTAssertEqual(executed.count, 1)
        XCTAssertEqual(executed.first?.0, .insertPlain(name: "greet", backspaces: 3, insertText: "Hi Ann!?", leftArrows: 2))
        XCTAssertEqual(executed.first?.1, ["who": "Ann", "tone": "?"])
        XCTAssertEqual(executed.first?.2, "com.example.ed")
    }

    func testCancelLeavesTheKeywordAndInsertsNothing() {
        let e = expander()
        _ = e.run(plan(greet, buffer: ";hi", trigger: ";hi"), hit: greet, context: PlaceholderContext(), bundleId: nil)
        answer?(nil)
        settle()
        XCTAssertEqual(activated, [4242], "cancel returns focus to the app the keyword was typed in")
        XCTAssertTrue(executed.isEmpty, "no backspace, no insert: the keyword stays as typed")
    }

    func testCancelReturnsFocusOnThePaletteAndHotkeyPathToo() {
        let e = expander()
        e.insert(greet, context: PlaceholderContext(), target: 99, bundleId: nil)
        answer?(nil)
        settle()
        XCTAssertEqual(activated, [99])
        XCTAssertTrue(executed.isEmpty)
    }

    /// Keys typed into the open panel reach the shared tap: they neither ask again, nor
    /// expand, nor stay in the buffer; the next keyword after submit starts clean.
    func testKeysTypedWhileThePanelIsOpenNeitherAskNorExpand() {
        let e = expander()
        _ = e.run(plan(greet, buffer: ";hi", trigger: ";hi"), hit: greet, context: PlaceholderContext(), bundleId: nil)
        XCTAssertTrue(e.prompting)
        let first = answer
        XCTAssertFalse(e.run(plan(greet, buffer: ";hi", trigger: ";hi"), hit: greet, context: PlaceholderContext(), bundleId: nil))
        let plain = SnippetHit(name: "p", keyword: ";p", text: "plain")
        XCTAssertFalse(e.run(plan(plain, buffer: ";p", trigger: ";p"), hit: plain, context: PlaceholderContext(), bundleId: nil),
                       "a plain keyword does not expand inside the panel")
        // With the gate in place handle() returns before any store, preference or event access.
        XCTAssertFalse(e.handle(keyCode: 0, typed: "x", controlHeld: false, optionHeld: false,
                                commandHeld: false, bundleId: nil))
        XCTAssertEqual(e.buffer, "", "panel keystrokes stay out of the buffer")
        XCTAssertEqual(prompts.count, 1, "no second prompt over the open one")
        XCTAssertTrue(executed.isEmpty)
        frontmost = 4242
        first?(["who": "Ann"])
        settle { !executed.isEmpty }
        XCTAssertFalse(e.prompting)
        XCTAssertEqual(e.buffer, "", "the next keyword starts from an empty buffer")
        XCTAssertEqual(executed.count, 1, "the first prompt's insert survives")
    }

    /// The palette or a hotkey fired while a fill-in is open: a snippet with arguments does not
    /// open a second prompt; one without arguments inserts at once (into the field that has
    /// focus, the panel's), as `insert` is not gated.
    func testPaletteOrHotkeyWhileThePanelIsOpenNeverOpensASecondPrompt() {
        let e = expander()
        _ = e.run(plan(greet, buffer: ";hi", trigger: ";hi"), hit: greet, context: PlaceholderContext(), bundleId: nil)
        let first = answer
        let other = SnippetHit(name: "other", keyword: ";o", text: "Re {argument name=\"topic\"}")
        e.insert(other, context: PlaceholderContext(), target: 99, bundleId: nil)
        let noArg = SnippetHit(name: "sig", keyword: ";s", text: "Best")
        e.insert(noArg, context: PlaceholderContext(), target: 99, bundleId: nil)
        XCTAssertEqual(prompts.count, 1, "no second prompt over the open one")
        XCTAssertEqual(executed.map { $0.0 }, [.insertPlain(name: "sig", backspaces: 0, insertText: "Best", leftArrows: 0)])
        XCTAssertTrue(activated.isEmpty)
        first?(["who": "Ann"])
        settle { executed.count == 2 }
        XCTAssertFalse(e.prompting)
        XCTAssertEqual(activated, [4242], "the first prompt still returns to its own target")
        XCTAssertEqual(executed.last?.0, .insertPlain(name: "greet", backspaces: 3, insertText: "Hi Ann!!", leftArrows: 2))
    }

    func testFocusChangedAbortsTheInsert() {
        let e = expander()
        _ = e.run(plan(greet, buffer: ";hi", trigger: ";hi"), hit: greet, context: PlaceholderContext(), bundleId: nil)
        frontmost = 777   // another app is frontmost once focus "returned"
        answer?(["who": "Ann"])
        settle()
        XCTAssertEqual(activated, [4242])
        XCTAssertTrue(executed.isEmpty, "never types into a field the keyword was not typed in")
    }

    func testTargetGoneAbortsTheInsert() {
        let e = expander()
        _ = e.run(plan(greet, buffer: ";hi", trigger: ";hi"), hit: greet, context: PlaceholderContext(), bundleId: nil)
        appGone = true
        answer?(["who": "Ann"])
        settle()
        XCTAssertTrue(executed.isEmpty)
    }

    func testNoPromptInsideSecureInput() {
        secure = true
        let e = expander()
        _ = e.run(plan(greet, buffer: ";hi", trigger: ";hi"), hit: greet, context: PlaceholderContext(), bundleId: nil)
        e.insert(greet, context: PlaceholderContext(), target: 4242, bundleId: nil)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(executed.isEmpty)
    }

    /// The `sn` palette and a bound hotkey both come in through `insert`, with no keyword to erase.
    func testPaletteAndHotkeyPromptThenInsertIntoTheTargetWithoutBackspaces() {
        let e = expander()
        e.insert(greet, context: PlaceholderContext(), target: 99, bundleId: "com.example.prev")
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(executed.isEmpty)
        frontmost = 99   // focus came back to the app that was frontmost before the palette
        answer?(["who": "Bo", "tone": "."])
        settle { !executed.isEmpty }
        XCTAssertEqual(activated, [99])
        XCTAssertEqual(executed.first?.0, .insertPlain(name: "greet", backspaces: 0, insertText: "Hi Bo!.", leftArrows: 2))
    }

    func testPhoneSnippetPromptShowsItsOwnName() {
        let e = expander()
        let phone = SnippetHit(name: PhoneSnippetStore.id(device: "dev-1", name: "sig"), text: "Bye {argument}")
        e.insert(phone, context: PlaceholderContext(), target: 99, bundleId: nil)
        XCTAssertEqual(prompts.map(\.title), ["sig"])
    }

    func testNoArgumentSnippetInsertsAtOnceWithoutPrompt() {
        let e = expander()
        e.insert(SnippetHit(name: "plain", text: "abc"), context: PlaceholderContext(), target: 99, bundleId: nil)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(activated.isEmpty)
        XCTAssertEqual(executed.first?.0, .insertPlain(name: "plain", backspaces: 0, insertText: "abc", leftArrows: 0))
    }

    func testRichSnippetSubmitHandsTheValuesToTheRichExecutor() {
        let e = expander()
        // Not valid RTF, so the plain projection is the text itself (a leading "{" would parse as a group).
        let rich = SnippetHit(name: "R", keyword: ";r", text: "Dear {argument name=\"x\"}", richText: true)
        _ = e.run(plan(rich, buffer: ";r", trigger: ";r"), hit: rich, context: PlaceholderContext(), bundleId: nil)
        answer?(["x": "1"])
        settle { !executed.isEmpty }
        XCTAssertEqual(executed.first?.0, .insertRich(name: "R", backspaces: 2))
        XCTAssertEqual(executed.first?.1, ["x": "1"])
    }

    func testPaletteActionIDMatchesTheLuaRows() {
        // snippets/init.lua's fill_in() writes this id; RunnerPanel handles it before extension dispatch.
        XCTAssertEqual(SnippetExpander.fillInActionID, "snippets.fill")
    }

    // MARK: - Panel model (offscreen)

    func testModelPrefillsDefaultsAndGatesSubmitOnRequiredFields() {
        var results: [[String: String]?] = []
        let model = SnippetFillInModel(title: "greet", fields: [ArgumentSpec(name: "who", defaultValue: nil),
                                                                ArgumentSpec(name: "tone", defaultValue: "!")]) {
            results.append($0)
        }
        XCTAssertEqual(model.values, ["", "!"])
        XCTAssertFalse(model.canSubmit, "a required field is empty")
        model.submit()
        XCTAssertTrue(results.isEmpty, "Return while blocked does nothing")
        model.values[0] = "Ann"
        XCTAssertTrue(model.canSubmit)
        model.values[1] = ""
        XCTAssertTrue(model.canSubmit, "a defaulted field may be cleared")
        model.submit()
        model.submit()
        model.cancel()
        XCTAssertEqual(results.count, 1, "finishes once")
        XCTAssertEqual(results.first ?? nil, ["who": "Ann", "tone": ""])
    }

    func testModelCancelReturnsNil() {
        var results: [[String: String]?] = []
        let model = SnippetFillInModel(title: "t", fields: [ArgumentSpec(name: "a", defaultValue: "x")]) {
            results.append($0)
        }
        model.cancel()
        model.submit()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results.first ?? ["unexpected": ""])
    }

    func testPanelBuildsOneFieldPerArgumentOffscreen() {
        let model = SnippetFillInModel(title: "greet", fields: [ArgumentSpec(name: "who", defaultValue: nil),
                                                                ArgumentSpec(name: "tone", defaultValue: "!")]) { _ in }
        let panel = SnippetFillInPanel.makePanel(model)
        defer { panel.close() }
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        guard let content = panel.contentView else { return XCTFail("no content view") }
        content.layoutSubtreeIfNeeded()
        settle()
        func fields(_ v: NSView) -> [NSTextField] {
            v.subviews.flatMap { sub -> [NSTextField] in
                if let field = sub as? NSTextField { return [field] }
                return fields(sub)
            }
        }
        let editable = fields(content).filter(\.isEditable)
        XCTAssertEqual(editable.map(\.stringValue), ["", "!"], "one field per argument, prefilled with its default")
        XCTAssertFalse(panel.isVisible, "never ordered front")
    }
}
