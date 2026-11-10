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

    func testWordBoundaryRequestErasesTheKeywordAndKeepsTheDelimiterAside() {
        let hit = SnippetHit(name: "S", keyword: "sig", text: "To {argument name=\"to\"}")
        // The space is swallowed as for an expansion: erase "sig" (3), the space comes back after.
        XCTAssertEqual(plan(hit, buffer: "sig ", trigger: "sig", boundary: true),
                       .needsArguments(name: "S", backspaces: 3, delimiter: " ", keyword: "sig"))
    }

    func testNonASCIIKeywordIsCarriedAsTyped() {
        let hit = SnippetHit(name: "D", keyword: ";déjà", text: "{argument}")
        XCTAssertEqual(plan(hit, buffer: "x ;déjà ", trigger: ";déjà", boundary: true),
                       .needsArguments(name: "D", backspaces: 5, delimiter: " ", keyword: ";déjà"))
        XCTAssertEqual(plan(hit, buffer: "x;déjà", trigger: ";déjà"),
                       .needsArguments(name: "D", backspaces: 4, delimiter: "", keyword: ";déjà"))
    }

    /// Cancel puts back the keyword and a printable delimiter, never Return, Enter or Tab.
    func testRetypeKeepsSpaceAndPunctuationButNeverReturnOrTab() {
        XCTAssertEqual(SnippetExpander.retype(keyword: ";sig", delimiter: " "), ";sig ")
        XCTAssertEqual(SnippetExpander.retype(keyword: ";sig", delimiter: ","), ";sig,")
        XCTAssertEqual(SnippetExpander.retype(keyword: ";sig", delimiter: "\r"), ";sig")
        XCTAssertEqual(SnippetExpander.retype(keyword: ";sig", delimiter: "\n"), ";sig")
        XCTAssertEqual(SnippetExpander.retype(keyword: ";sig", delimiter: "\u{3}"), ";sig")   // keypad Enter
        XCTAssertEqual(SnippetExpander.retype(keyword: ";sig", delimiter: "\t"), ";sig")
        XCTAssertEqual(SnippetExpander.retype(keyword: ";déjà", delimiter: ""), ";déjà")
    }

    func testNestedArgumentAsksThroughContextLookup() {
        let hit = SnippetHit(name: "N", keyword: ";n", text: "x {snippet:inner}")
        var ctx = PlaceholderContext()
        ctx.snippetByKeyword = { $0 == "inner" ? "{argument name=\"q\"}" : nil }
        XCTAssertEqual(plan(hit, buffer: ";n", trigger: ";n", ctx),
                       .needsArguments(name: "N", backspaces: 1, delimiter: "", keyword: ";n"))
        ctx.arguments = ["q": "v"]
        XCTAssertEqual(plan(hit, buffer: ";n", trigger: ";n", ctx),
                       .insertPlain(name: "N", backspaces: 1, insertText: "x v", leftArrows: 0))
    }

    func testRichWithArgumentAsks() {
        let hit = SnippetHit(name: "R", keyword: ";r", text: "body {argument}", richText: true)
        XCTAssertEqual(plan(hit, buffer: ";r", trigger: ";r"),
                       .needsArguments(name: "R", backspaces: 1, delimiter: "", keyword: ";r"))
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
    private var revealed = 0
    private var alerts = 0

    private func expander() -> SnippetExpander {
        let e = SnippetExpander()
        e.prompt = { [unowned self] title, fields, done in
            prompts.append((title, fields))
            answer = done
        }
        e.activateApp = { [unowned self] pid in activated.append(pid); return !appGone }
        e.frontmostPID = { [unowned self] in frontmost }
        e.secureInputActive = { [unowned self] in secure }
        e.reveal = { [unowned self] in revealed += 1 }
        e.alert = { [unowned self] in alerts += 1 }
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
    private let sig = SnippetHit(name: "sig", keyword: ";sig", text: "Regards {argument name=\"who\"}")

    /// The erase a typed fill-in sends at match time.
    private func erase(_ name: String, _ n: Int) -> SnippetExpansionDecision {
        .insertPlain(name: name, backspaces: n, insertText: "", leftArrows: 0)
    }

    private func typeSig(_ e: SnippetExpander, bundleId: String? = nil) -> Bool {
        e.run(plan(sig, buffer: ";sig ", trigger: ";sig", boundary: true), hit: sig,
              context: PlaceholderContext(), bundleId: bundleId)
    }

    /// QA #684 F1: everything destructive happens at match time, while the field is known.
    func testTypedKeywordIsSwallowedAndErasedAtMatchThenSubmitErasesNothing() {
        let e = expander()
        XCTAssertTrue(typeSig(e, bundleId: "com.example.ed"), "the trigger key is swallowed, as for an expansion")
        XCTAssertEqual(executed.map { $0.0 }, [erase("sig", 4)], "the keyword goes at match time")
        XCTAssertEqual(prompts.map(\.title), ["sig"])
        XCTAssertEqual(prompts.first?.fields, [ArgumentSpec(name: "who", defaultValue: nil)])

        answer?(["who": "Bob"])
        settle { executed.count == 2 }
        XCTAssertEqual(activated, [4242], "focus returns to the app the keyword was typed in")
        XCTAssertEqual(executed.count, 2)
        XCTAssertEqual(executed.last?.0, .insertPlain(name: "sig", backspaces: 0, insertText: "Regards Bob ", leftArrows: 0),
                       "inserted at the caret: type-ahead or a click elsewhere loses nothing")
        XCTAssertEqual(executed.last?.1, ["who": "Bob"])
        XCTAssertEqual(executed.last?.2, "com.example.ed")
    }

    func testCursorSnippetSubmitMovesTheCaretWithNoBackspaces() {
        let e = expander()
        XCTAssertTrue(e.run(plan(greet, buffer: ";hi", trigger: ";hi"), hit: greet, context: PlaceholderContext(), bundleId: nil))
        XCTAssertEqual(executed.map { $0.0 }, [erase("greet", 2)])
        answer?(["who": "Ann", "tone": "?"])
        settle { executed.count == 2 }
        XCTAssertEqual(executed.last?.0, .insertPlain(name: "greet", backspaces: 0, insertText: "Hi Ann!?", leftArrows: 2))
    }

    /// Cancel leaves the field as it was: the keyword and its space come back once, sent while
    /// the gate still holds, so the expander neither asks again nor expands.
    func testCancelRetypesTheKeywordOnceWithoutReTriggering() {
        let e = expander()
        _ = typeSig(e)
        answer?(nil)
        XCTAssertTrue(e.prompting, "the gate holds until the re-type is sent")
        XCTAssertFalse(typeSig(e), "a keyword seen before the re-type lands does not ask again")
        let plain = SnippetHit(name: "p", keyword: ";p", text: "plain")
        XCTAssertFalse(e.run(plan(plain, buffer: ";p", trigger: ";p"), hit: plain, context: PlaceholderContext(), bundleId: nil))
        settle { executed.count == 2 }
        settle()
        XCTAssertEqual(activated, [4242], "cancel returns focus to the app the keyword was typed in")
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(executed.map { $0.0 }, [erase("sig", 4),
                                               .insertPlain(name: "sig", backspaces: 0, insertText: ";sig ", leftArrows: 0)],
                       "re-typed exactly once, as a string")
        XCTAssertFalse(e.prompting)
    }

    func testCancelOnThePaletteAndHotkeyPathReturnsFocusAndTypesNothing() {
        let e = expander()
        e.insert(greet, context: PlaceholderContext(), target: 99, bundleId: nil)
        answer?(nil)
        settle()
        XCTAssertEqual(activated, [99])
        XCTAssertTrue(executed.isEmpty)
        XCTAssertFalse(e.prompting)
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
        XCTAssertEqual(executed.count, 1, "only the match-time erase")
        first?(["who": "Ann"])
        settle { executed.count == 2 }
        XCTAssertFalse(e.prompting)
        XCTAssertEqual(e.buffer, "", "the next keyword starts from an empty buffer")
        XCTAssertEqual(executed.count, 2, "the first prompt's insert survives")
    }

    /// QA #684 INFO-4: a hotkey chord leaves the buffer as typed (handle() bails before
    /// clearing it), and a mouse-only Insert sends no key: finishing must clear it.
    func testFinishClearsTheBufferAHotkeyLeftBehind() {
        guard !SnippetExpander.autoExpandActive else { return XCTFail("auto-expand must be off in tests") }
        let e = expander()
        // Off by default under XCTest: handle() appends, then bails before any store read.
        _ = e.handle(keyCode: 0, typed: "a", controlHeld: false, optionHeld: false, commandHeld: false, bundleId: nil)
        _ = e.handle(keyCode: 1, typed: "s", controlHeld: true, optionHeld: false, commandHeld: false, bundleId: nil)
        XCTAssertEqual(e.buffer, "a", "the chord left the buffer as typed")
        e.insert(greet, context: PlaceholderContext(), target: 99, bundleId: nil)
        answer?(nil)
        XCTAssertEqual(e.buffer, "", "a mouse-only finish clears it")
    }

    /// QA #684 INFO-3: an argument snippet from the palette or a hotkey while a fill-in is open
    /// brings that one forward; one without arguments inserts at once (into the field that has
    /// focus, the panel's), as `insert` is not gated.
    func testPaletteOrHotkeyWhileThePanelIsOpenRevealsItAndNeverAsksTwice() {
        let e = expander()
        _ = e.run(plan(greet, buffer: ";hi", trigger: ";hi"), hit: greet, context: PlaceholderContext(), bundleId: nil)
        let first = answer
        let other = SnippetHit(name: "other", keyword: ";o", text: "Re {argument name=\"topic\"}")
        e.insert(other, context: PlaceholderContext(), target: 99, bundleId: nil)
        XCTAssertEqual(revealed, 1, "the open panel comes forward")
        let noArg = SnippetHit(name: "plain", keyword: ";s", text: "Best")
        e.insert(noArg, context: PlaceholderContext(), target: 99, bundleId: nil)
        XCTAssertEqual(prompts.count, 1, "no second prompt over the open one")
        XCTAssertEqual(executed.map { $0.0 }, [erase("greet", 2),
                                               .insertPlain(name: "plain", backspaces: 0, insertText: "Best", leftArrows: 0)])
        XCTAssertTrue(activated.isEmpty)
        first?(["who": "Ann"])
        settle { executed.count == 3 }
        XCTAssertFalse(e.prompting)
        XCTAssertEqual(activated, [4242], "the first prompt still returns to its own target")
        XCTAssertEqual(executed.last?.0, .insertPlain(name: "greet", backspaces: 0, insertText: "Hi Ann!!", leftArrows: 2))
        XCTAssertEqual(revealed, 1)
    }

    /// Another app frontmost once focus "returned": neither the insert nor the re-type is sent.
    func testFocusChangedAbortsBothTheInsertAndTheRetype() {
        for result in [["who": "Ann"], nil] as [[String: String]?] {
            executed = []; activated = []; frontmost = 4242
            let e = expander()
            _ = typeSig(e)
            frontmost = 777
            answer?(result)
            settle()
            XCTAssertEqual(activated, [4242])
            XCTAssertEqual(executed.map { $0.0 }, [erase("sig", 4)], "never types into a field the keyword was not typed in")
            XCTAssertFalse(e.prompting)
        }
    }

    /// #848: anything the panel was going to send and could not beeps once: a cancel's
    /// re-type or a submit's insert. A re-type that lands, and a palette cancel, do not.
    func testDroppedRetypeOrInsertBeepsOnce() {
        let cases: [(name: String, front: pid_t?, gone: Bool, retyped: Bool, beeps: Int)] = [
            ("target frontmost", 4242, false, true, 0),
            ("frontmost differs", 777, false, false, 1),
            ("activate fails", 4242, true, false, 1),
        ]
        for c in cases {
            executed = []; activated = []; alerts = 0; frontmost = 4242; appGone = false
            let e = expander()
            _ = typeSig(e)
            frontmost = c.front; appGone = c.gone
            answer?(nil)
            settle { alerts > 0 || executed.count == 2 }
            settle()
            XCTAssertEqual(activated, [4242], c.name)
            XCTAssertEqual(executed.count == 2, c.retyped, c.name)
            XCTAssertEqual(alerts, c.beeps, c.name)
            XCTAssertFalse(e.prompting, c.name)
        }
        for gone in [false, true] {
            // Typed path: the keyword went at match time, so a dropped insert leaves nothing.
            executed = []; alerts = 0; frontmost = 4242; appGone = false
            let e = expander()
            _ = typeSig(e)
            frontmost = gone ? 4242 : 777; appGone = gone
            answer?(["who": "Ann"])
            settle { alerts > 0 }
            settle()
            XCTAssertEqual(executed.map { $0.0 }, [erase("sig", 4)], "typed submit, gone=\(gone)")
            XCTAssertEqual(alerts, 1, "typed submit, gone=\(gone)")
            // Palette/hotkey path: an Insert press that did nothing.
            executed = []; alerts = 0
            e.insert(greet, context: PlaceholderContext(), target: 99, bundleId: nil)
            answer?(["who": "Ann"])
            settle { alerts > 0 }
            settle()
            XCTAssertTrue(executed.isEmpty, "palette submit, gone=\(gone)")
            XCTAssertEqual(alerts, 1, "palette submit, gone=\(gone)")
            // Palette/hotkey cancel: nothing to send, nothing lost.
            alerts = 0
            e.insert(greet, context: PlaceholderContext(), target: 99, bundleId: nil)
            answer?(nil)
            settle()
            XCTAssertEqual(alerts, 0, "palette cancel, gone=\(gone)")
        }
    }

    func testTargetGoneAbortsTheInsert() {
        let e = expander()
        _ = typeSig(e)
        appGone = true
        answer?(["who": "Ann"])
        settle()
        XCTAssertEqual(executed.count, 1)
        XCTAssertFalse(e.prompting)
    }

    /// Secure input on by the time focus returns: nothing typed, and a beep says the keyword is gone.
    func testSecureInputAtFinishSkipsTheInsertAndTheRetypeAndBeeps() {
        for result in [["who": "Ann"], nil] as [[String: String]?] {
            executed = []; secure = false; alerts = 0
            let e = expander()
            _ = typeSig(e)
            secure = true
            answer?(result)
            settle { alerts > 0 }
            XCTAssertEqual(executed.map { $0.0 }, [erase("sig", 4)])
            XCTAssertEqual(alerts, 1)
            XCTAssertFalse(e.prompting)
        }
    }

    func testNoPromptAndNoEraseInsideSecureInput() {
        secure = true
        let e = expander()
        XCTAssertFalse(typeSig(e), "the trigger goes through untouched")
        e.insert(greet, context: PlaceholderContext(), target: 4242, bundleId: nil)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(executed.isEmpty, "the keyword is not erased")
    }

    /// No app to return to: nothing is erased and nothing is asked for.
    func testNoTargetNeitherErasesNorAsks() {
        frontmost = nil
        let e = expander()
        XCTAssertFalse(typeSig(e))
        e.insert(greet, context: PlaceholderContext(), target: nil, bundleId: nil)
        XCTAssertTrue(prompts.isEmpty)
        XCTAssertTrue(executed.isEmpty)
        XCTAssertFalse(e.prompting)
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

    /// QA #684 INFO-5: the runner's fill action hands the row's snippet and the app before the
    /// palette to the expander.
    func testRunnerFillActionAsksThenInsertsIntoTheAppBeforeThePalette() {
        let e = expander()
        let lookup: (String) -> SnippetHit? = { [greet] in $0 == "greet" ? greet : nil }
        RunnerPanel.fillIn(value: "gone", target: 99, bundleId: nil, lookup: lookup,
                           context: { _ in PlaceholderContext() }, expander: e)
        RunnerPanel.fillIn(value: "greet", target: nil, bundleId: nil, lookup: lookup,
                           context: { _ in PlaceholderContext() }, expander: e)
        XCTAssertTrue(prompts.isEmpty, "an unknown row or no previous app asks for nothing")
        RunnerPanel.fillIn(value: "greet", target: 99, bundleId: "com.example.prev", lookup: lookup,
                           context: { _ in PlaceholderContext() }, expander: e)
        XCTAssertEqual(prompts.map(\.title), ["greet"])
        frontmost = 99
        answer?(["who": "Bo"])
        settle { !executed.isEmpty }
        XCTAssertEqual(activated, [99])
        XCTAssertEqual(executed.first?.2, "com.example.prev")
    }

    /// QA #684 INFO-5: Mac and phone rows flag `arguments` by the same formula, nested ones included.
    func testHostRowsFlagArgumentsForMacAndPhoneSnippets() {
        let mac = [SnippetHit(name: "ask", keyword: ";a", text: "Hi {argument}"),
                   SnippetHit(name: "plain", keyword: ";p", text: "Hi {date}"),
                   SnippetHit(name: "nest", keyword: ";n", text: "x {snippet:;a}")]
        let set = PhoneSnippetStore.DeviceSet(name: "Phone", hash: "h", updated: 0, snippets: [
            PhoneSnippetStore.Snippet(name: "p-ask", text: "{argument name=\"q\" default=\"1\"}"),
            PhoneSnippetStore.Snippet(name: "p-plain", text: "plain"),
            PhoneSnippetStore.Snippet(name: "p-nest", text: "{snippet:;a}"),
        ])
        let macRows = LiveExtensionHostServices.snippetRows(mac, phone: [("dev", set)])
        XCTAssertEqual(macRows.map { $0["arguments"] as? Bool }, [true, false, true])
        let phoneRows = LiveExtensionHostServices.phoneRows([("dev", set)], mac: mac)
        let snippets = phoneRows.first?["snippets"] as? [[String: Any]] ?? []
        XCTAssertEqual(snippets.map { $0["arguments"] as? Bool }, [true, false, true])
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
        XCTAssertTrue(e.run(plan(rich, buffer: ";r", trigger: ";r"), hit: rich, context: PlaceholderContext(), bundleId: nil))
        answer?(["x": "1"])
        settle { executed.count == 2 }
        XCTAssertEqual(executed.map { $0.0 }, [erase("R", 1), .insertRich(name: "R", backspaces: 0)])
        XCTAssertEqual(executed.last?.1, ["x": "1"])
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

    /// QA #684 F2: a keyword typed in a full-screen app does not pull the user off its Space.
    func testPanelJoinsAFullScreenAppsSpace() {
        let panel = SnippetFillInPanel.makePanel(SnippetFillInModel(title: "t", fields: []) { _ in })
        defer { panel.close() }
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.isVisible)
    }

    /// QA #684 INFO-6: a bare {argument} is labelled "Value"; a named one by its name.
    func testBareArgumentIsLabelledValue() {
        let specs = PlaceholderEngine.arguments(in: "{argument} {argument name=\"to\"}")
        XCTAssertEqual(specs.map(\.label), ["Value", "to"])
    }
}
