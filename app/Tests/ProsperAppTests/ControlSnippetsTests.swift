import Foundation
import XCTest
@testable import ProsperApp

/// #1858: snippets.list/get/set/remove on an in-memory store seam (the real SnippetStore writes the person's snippets.json).
final class ControlSnippetsTests: XCTestCase {
    @MainActor
    func withStore(_ initial: [SnippetHit] = [], _ body: (() -> [SnippetHit]) throws -> Void) rethrows {
        let saved = (ControlSnippets.storeAll, ControlSnippets.storeSave, ControlSnippets.storeRemove)
        defer { (ControlSnippets.storeAll, ControlSnippets.storeSave, ControlSnippets.storeRemove) = saved }
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

    /// A new snippet never auto-expands and its undo removes it; list has no bodies, get has.
    @MainActor
    func testSetNewIsNotAutoExpandingAndUndoRemoves() throws {
        try withStore { items in
            let c = try ControlSnippets.set(args(["name": " api ", "text": "a\tb\nc", "keyword": ";;api"]))
            XCTAssertEqual(c.result, .string("api"))
            XCTAssertEqual(items().last?.autoExpand, false)
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

    /// Replacing an auto-expanding snippet turns it off, keeps its collection, keyword and description; undo restores it whole.
    @MainActor
    func testSetReplaceKeepsFieldsTurnsExpandOffAndUndoRestores() throws {
        try withStore([sig]) { items in
            let c = try ControlSnippets.set(args(["name": "sig", "text": "New"]))
            XCTAssertEqual(items().last, SnippetHit(name: "sig", keyword: ";;sig", text: "New", collection: "Mail", description: "mail", autoExpand: false))
            XCTAssertEqual(items().count, 1)
            c.undo?()
            XCTAssertEqual(items().last, sig)
        }
    }

    /// Any clipboard placeholder, in any spelling the engine accepts, refuses the whole text; other braces pass.
    @MainActor
    func testClipboardPlaceholdersAreRefused() throws {
        try withStore { items in
            for bad in ["{clipboard:0}", "x {clipboard}", "{ Clipboard : 2 }", "{clipboard | trim}", "{clipboard 1}", "{CLIPBOARD}"] {
                refused(try ControlSnippets.set(args(["name": "n", "text": bad])), contains: "clipboard")
            }
            _ = try ControlSnippets.set(args(["name": "n", "text": "{date} {clipboardish} "]))
            XCTAssertEqual(items().count, 1)
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
        let other = SnippetHit(name: "SIG", text: "x")
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
