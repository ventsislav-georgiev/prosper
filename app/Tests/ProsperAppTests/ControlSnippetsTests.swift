import Foundation
import XCTest
@testable import ProsperApp

/// #1858: snippets.list/get/set/remove on an in-memory store seam (the real SnippetStore writes the person's snippets.json).
final class ControlSnippetsTests: XCTestCase {
    @MainActor
    func withStore(_ initial: [SnippetHit] = [], phone: [PhoneSnippetStore.Snippet] = [], replacements: [String: String] = [:],
                   collections: [SnippetCollection] = [], _ body: (() -> [SnippetHit]) throws -> Void) rethrows {
        let saved = (ControlSnippets.storeAll, ControlSnippets.storeSave, ControlSnippets.storeRemove)
        let seams = (ControlSnippets.storeCollections, ControlSnippets.phoneSets, ControlSnippets.replacements)
        defer {
            (ControlSnippets.storeAll, ControlSnippets.storeSave, ControlSnippets.storeRemove) = saved
            (ControlSnippets.storeCollections, ControlSnippets.phoneSets, ControlSnippets.replacements) = seams
        }
        ControlSnippets.storeCollections = { collections }
        ControlSnippets.phoneSets = { [(device: "phone-1", set: PhoneSnippetStore.DeviceSet(name: "Phone", hash: "h", updated: 1, snippets: phone))] }
        ControlSnippets.replacements = { replacements }
        var items = initial
        ControlSnippets.storeAll = { items }
        ControlSnippets.storeSave = { h in
            if let i = items.firstIndex(where: { $0.name == h.name }) { items[i] = h } else { items.append(h) }
        }
        ControlSnippets.storeRemove = { n in items.removeAll { $0.name == n } }
        try body { items }
    }

    func args(_ d: [String: String]) -> [String: ControlJSON] { d.mapValues { .string($0) } }

    @MainActor
    func refused<T>(_ expr: @autoclosure () throws -> T, contains: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertTrue(($0 as? ControlError)?.message.contains(contains) == true, "\($0)", file: file, line: line)
        }
    }

    let sig = SnippetHit(name: "sig", keyword: ";;sig", text: "Best,\nExample", collection: "Mail", description: "mail", autoExpand: true)
    /// What an agent's set leaves: plain, auto-expand off, the stored agentMade marker on.
    let mine = SnippetHit(name: "note", keyword: ";;note", text: "Old", collection: "Mail", description: "d", autoExpand: false, agentMade: true)

    /// A new snippet never auto-expands and its undo removes it; list has no bodies, get has.
    @MainActor
    func testSetNewIsNotAutoExpandingAndUndoRemoves() throws {
        try withStore { items in
            let c = try ControlSnippets.set(args(["name": " api ", "text": "a\tb\nc", "keyword": ";;api"]))
            XCTAssertEqual(c.result, .string("api"))
            XCTAssertEqual(items().last?.autoExpand, false)
            XCTAssertEqual(items().last?.agentMade, true)
            XCTAssertEqual(items().last?.keyword, ";;api")
            XCTAssertEqual(items().last?.text, "a\tb\nc")
            guard case .object(let l) = ControlSnippets.list(), case .array(let rows)? = l["snippets"], case .object(let r)? = rows.last
            else { return XCTFail("list shape") }
            XCTAssertTrue(r["text"] == nil)
            XCTAssertEqual(r["bytes"], .number(5))
            guard case .object(let g) = try ControlSnippets.get(args(["name": "API"])) else { return XCTFail("get shape") }
            XCTAssertEqual(g["text"], .string("a\tb\nc"))
            c.undo?()
            XCTAssertEqual(items().count, 0)
        }
    }

    /// Replacing the agent's own snippet keeps its collection, keyword and description; undo restores it whole.
    @MainActor
    func testSetReplaceKeepsFieldsAndUndoRestores() throws {
        try withStore([mine]) { items in
            let c = try ControlSnippets.set(args(["name": "note", "text": "New"]))
            XCTAssertEqual(items().last, SnippetHit(name: "note", keyword: ";;note", text: "New", collection: "Mail", description: "d", autoExpand: false, agentMade: true))
            XCTAssertEqual(items().count, 1)
            c.undo?()
            XCTAssertEqual(items().last, mine)
        }
    }

    /// n163: only {cursor} {date} {time} {datetime} {uuid} {argument}, in the engine's spellings; every other placeholder
    /// ({clipboard} in any spelling, {snippet:k} that could embed one, custom {x}) refuses the whole text.
    @MainActor
    func testPlaceholdersOutsideTheAllowListAreRefused() throws {
        try withStore { items in
            for bad in ["{clipboard:0}", "x {clipboard}", "{ Clipboard : 2 }", "{clipboard | trim}", "{clipboard 1}", "{CLIPBOARD}"] {
                refused(try ControlSnippets.set(args(["name": "n", "text": bad])), contains: "{clipboard} placeholder")
            }
            refused(try ControlSnippets.set(args(["name": "n", "text": "a {snippet:k} b"])), contains: "{snippet} placeholder")
            refused(try ControlSnippets.set(args(["name": "n", "text": "{ Snippet : k }"])), contains: "{snippet} placeholder")
            refused(try ControlSnippets.set(args(["name": "n", "text": "{x}"])), contains: "{x} placeholder")
            refused(try ControlSnippets.set(args(["name": "n", "text": "{date} {clipboardish}"])), contains: "{clipboardish} placeholder")
            XCTAssertEqual(items().count, 0)
            _ = try ControlSnippets.set(args(["name": "n", "text": "{date} {Time:short} {datetime +1d} {UUID} {cursor} {argument name=\"x\" default=\"y\"} {{clipboard}}"]))
            XCTAssertEqual(items().count, 1)
        }
    }

    /// n162 (a): a name or keyword that a person's snippet answers to in {snippet:key} (its name, keyword or trigger with
    /// its collection's affixes) is refused; compared exactly, as the lookup does. Another agent snippet's is not.
    @MainActor
    func testSetRefusesANameOrKeywordThePersonsSnippetAnswersTo() throws {
        let affixed = SnippetHit(name: "addr", keyword: "a", text: "x", collection: "Home")
        try withStore([sig, affixed, mine], collections: [SnippetCollection(name: "Home", prefix: ";", suffix: "")]) { items in
            refused(try ControlSnippets.set(args(["name": "n", "text": "t", "keyword": ";;sig"])), contains: ";;sig is already")
            refused(try ControlSnippets.set(args(["name": "n", "text": "t", "keyword": "sig"])), contains: "sig is already")
            refused(try ControlSnippets.set(args(["name": ";;sig", "text": "t"])), contains: ";;sig is already")
            refused(try ControlSnippets.set(args(["name": "n", "text": "t", "keyword": ";a"])), contains: ";a is already")
            XCTAssertEqual(items().count, 3)
            _ = try ControlSnippets.set(args(["name": "n", "text": "t", "keyword": ";;SIG"]))
            _ = try ControlSnippets.set(args(["name": "n2", "text": "t", "keyword": ";;note"]))
            XCTAssertEqual(items().count, 5)
        }
    }

    /// n162 (b): set and remove refuse every snippet without the agentMade marker, a plain auto-expand-off one included,
    /// so hotkeys and embeds keep their text; the agent's own (marker on) can be replaced and removed.
    @MainActor
    func testSetAndRemoveTouchOnlyAgentMadeSnippets() throws {
        let quiet = SnippetHit(name: "rtf", text: "{\\rtf1 x}", autoExpand: false, richText: true)
        let plain = SnippetHit(name: "plain", text: "Theirs", autoExpand: false)
        try withStore([sig, quiet, plain, mine]) { items in
            for name in ["sig", "rtf", "plain"] {
                refused(try ControlSnippets.set(args(["name": name, "text": "New"])), contains: "the person's snippet")
                refused(try ControlSnippets.remove(args(["name": name])), contains: "the person's snippet")
            }
            refused(try ControlSnippets.remove(args(["name": "SIG"])), contains: "the person's snippet")
            XCTAssertEqual(items(), [sig, quiet, plain, mine])
            _ = try ControlSnippets.set(args(["name": "note", "text": "New"]))
            XCTAssertEqual(items().last?.text, "New")
            _ = try ControlSnippets.remove(args(["name": "note"]))
            XCTAssertEqual(items(), [sig, quiet, plain])
        }
    }

    /// The marker is stored only when on: a person's snippet encodes with no agentMade key (its file stays byte-identical)
    /// and decodes back unmarked; an agent's encodes "agentMade":true and decodes back marked.
    @MainActor
    func testAgentMadeMarkerIsStoredOnlyWhenOn() throws {
        let person = SnippetHit(name: "plain", keyword: "p", text: "Theirs", autoExpand: false)
        let agent = SnippetHit(name: "note", text: "Mine", autoExpand: false, agentMade: true)
        let pj = String(decoding: try JSONEncoder().encode(SnippetStore.entry(from: person)), as: UTF8.self)
        let aj = String(decoding: try JSONEncoder().encode(SnippetStore.entry(from: agent)), as: UTF8.self)
        XCTAssertFalse(pj.contains("agentMade"), pj)
        XCTAssertTrue(aj.contains("\"agentMade\":true"), aj)
        XCTAssertEqual(SnippetStore.hit(from: try JSONDecoder().decode(SnippetStore.Entry.self, from: Data(pj.utf8))), person)
        XCTAssertEqual(SnippetStore.hit(from: try JSONDecoder().decode(SnippetStore.Entry.self, from: Data(aj.utf8))), agent)
    }

    /// n162 (c): a phone snippet's keyword or name and a Text Replacement shortcut are refused as the matcher compares them.
    @MainActor
    func testSetRefusesAPhoneKeywordOrATextReplacement() throws {
        let phone = [PhoneSnippetStore.Snippet(name: "Home", text: "x", keyword: " ;home ")]
        try withStore(phone: phone, replacements: ["omw": "On my way"]) { items in
            refused(try ControlSnippets.set(args(["name": "n", "text": "t", "keyword": ";home"])), contains: ";home is already")
            refused(try ControlSnippets.set(args(["name": "Home", "text": "t"])), contains: "Home is already")
            refused(try ControlSnippets.set(args(["name": "n", "text": "t", "keyword": "omw"])), contains: "omw is already")
            XCTAssertEqual(items().count, 0)
            _ = try ControlSnippets.set(args(["name": "n", "text": "t", "keyword": ";omw"]))
            XCTAssertEqual(items().count, 1)
        }
    }

    /// n166: an undo does nothing once the snippet is no longer what the agent left (edited, or made again after a remove).
    @MainActor
    func testUndoDoesNothingAfterThePersonChangedIt() throws {
        let edited = SnippetHit(name: "note", text: "Theirs", autoExpand: true)
        try withStore { items in
            let c = try ControlSnippets.set(args(["name": "note", "text": "New"]))
            ControlSnippets.storeSave(edited)
            c.undo?()
            XCTAssertEqual(items(), [edited])
        }
        try withStore([mine]) { items in
            let c = try ControlSnippets.set(args(["name": "note", "text": "New"]))
            ControlSnippets.storeSave(edited)
            c.undo?()
            XCTAssertEqual(items(), [edited])
        }
        try withStore([mine]) { items in
            let c = try ControlSnippets.remove(args(["name": "note"]))
            ControlSnippets.storeSave(edited)
            c.undo?()
            XCTAssertEqual(items(), [edited])
        }
    }

    /// Control and hidden characters refuse the text, name, keyword and description; empty and oversized too.
    @MainActor
    func testOutsideTextIsRefused() throws {
        try withStore { items in
            for bad in ["a\rb", "a\u{1B}[31m", "a\u{202E}b", "a\u{200B}b", "a\u{7F}"] {
                refused(try ControlSnippets.set(args(["name": "n", "text": bad])), contains: "text has a control")
                refused(try ControlSnippets.set(args(["name": bad, "text": "ok"])), contains: "name has a control")
                refused(try ControlSnippets.set(args(["name": "n", "text": "ok", "keyword": bad])), contains: "keyword has a control")
                refused(try ControlSnippets.set(args(["name": "n", "text": "ok", "description": bad])), contains: "description has a control")
            }
            refused(try ControlSnippets.set(args(["name": "n", "text": "ok", "description": "a\nb"])), contains: "description has a control")
            refused(try ControlSnippets.set(args(["name": "n", "text": ""])), contains: "'text' is empty")
            refused(try ControlSnippets.set(args(["name": "  ", "text": "ok"])), contains: "'name' is empty")
            refused(try ControlSnippets.set(args(["name": "n", "text": String(repeating: "x", count: ControlSnippets.maxText + 1)])), contains: "longer")
            refused(try ControlSnippets.set(args(["name": String(repeating: "n", count: ControlSnippets.maxName + 1), "text": "ok"])), contains: "longer")
            XCTAssertEqual(items().count, 0)
        }
    }

    /// A store that drops the write is reported, and nothing is logged as a change.
    @MainActor
    func testSetReportsAStoreThatDroppedIt() throws {
        try withStore { _ in
            ControlSnippets.storeSave = { _ in }
            refused(try ControlSnippets.set(args(["name": "n", "text": "ok"])), contains: "did not save")
        }
    }

    /// Remove by exact or folded name; undo re-adds it as it was; unknown and ambiguous names are refused.
    @MainActor
    func testRemoveUndoAndFind() throws {
        let sig = SnippetHit(name: "sig", keyword: ";;sig", text: "Best", collection: "Mail", description: "mail", autoExpand: false, agentMade: true)
        let other = SnippetHit(name: "SIG", text: "x", autoExpand: false, agentMade: true)
        try withStore([sig]) { items in
            let c = try ControlSnippets.remove(args(["name": "SIG"]))
            XCTAssertEqual(c.result, .string("sig"))
            XCTAssertEqual(items().count, 0)
            c.undo?()
            XCTAssertEqual(items().last, sig)
            refused(try ControlSnippets.remove(args(["name": "nope"])), contains: "no snippet named nope")
        }
        try withStore([sig, other]) { items in
            refused(try ControlSnippets.remove(args(["name": "Sig"])), contains: "2 snippets")
            _ = try ControlSnippets.remove(args(["name": "SIG"]))
            XCTAssertEqual(items().map(\.name), ["sig"])
        }
    }

    /// The four commands register with the right mutates flags.
    @MainActor
    func testRegistration() {
        var r = ControlRegistry()
        ControlRegistry.registerSnippets(&r)
        XCTAssertEqual(r.commands.mapValues(\.mutates),
                       ["snippets.list": false, "snippets.get": false, "snippets.set": true, "snippets.remove": true])
    }
}
