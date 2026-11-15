import XCTest
import AppKit
@testable import ProsperApp

/// #980 (QA #178, QA #39): the extension status-item autosave name is one-to-one and bounded, and every own content
/// item gets an identifier of its own. The name rows call the pure name function only (no item gets a name, no
/// defaults are read or written). The identifier rows use a private NSStatusBar(), never the system bar.
final class MenuBarIdentityTests: XCTestCase {
    private func name(_ ext: String, _ id: String = "main") -> String {
        ExtensionMenuBar.autosaveName(extensionID: ext, id: id)
    }

    // MARK: QA #178, the autosave name

    /// The audit's four ids shared "a_b" before; now each has its own name, in both halves.
    func testTheAuditsFourIDsGetFourNames() {
        XCTAssertEqual(name("a b"), "ProsperExt:a%20b:main")
        XCTAssertEqual(name("a/b"), "ProsperExt:a%2Fb:main")
        XCTAssertEqual(name("a:b"), "ProsperExt:a%3Ab:main")
        XCTAssertEqual(name("a_b"), "ProsperExt:a_b:main", "a clean id keeps today's name")
        XCTAssertEqual(name("com.example.kit", "a b"), "ProsperExt:com.example.kit:a%20b")
        XCTAssertEqual(name("com.example.kit", "a_b"), "ProsperExt:com.example.kit:a_b")
        XCTAssertEqual(Set(["a b", "a/b", "a:b", "a_b"].map { name($0) }).count, 4)
        XCTAssertEqual(Set(["a b", "a/b", "a:b", "a_b"].map { name("com.example.kit", $0) }).count, 4)
    }

    /// Every id clean() left unchanged keeps exactly today's name: its saved position survives.
    func testCleanIDsKeepTodaysName() {
        let kept = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        XCTAssertEqual(name(kept, kept), "ProsperExt:\(kept):\(kept)")
        let longest = String(repeating: "k", count: 128)   // the install rule's longest id
        XCTAssertEqual(name(longest), "ProsperExt:\(longest):main")
        XCTAssertEqual(name("com.example.kit", "i-1"), "ProsperExt:com.example.kit:i-1")
        XCTAssertEqual(name("."), "ProsperExt:.:main")
        XCTAssertEqual(name("", ""), "ProsperExt::", "empty stays empty, as before")
    }

    /// The bundled extensions that put an item in the menu bar (a literal list: the item is a Lua call, not a
    /// manifest field, so the set is read from the bundled .lua sources) keep their names.
    func testBundledMenuBarExtensionsKeepTheirNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/Resources/extensions")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var folders = Set<String>()
        for case let url as URL in files where url.pathExtension == "lua" {
            let parts = url.pathComponents
            if try String(contentsOf: url, encoding: .utf8).contains("menubar.set"),
               let i = parts.lastIndex(of: "extensions"), i + 1 < parts.count {
                folders.insert(parts[i + 1])
            }
        }
        XCTAssertEqual(folders, ["openlid"], "a new bundled menu bar item: add its id and name below")
        XCTAssertEqual(name("com.prosper.openlid", "main"), "ProsperExt:com.prosper.openlid:main")
    }

    /// An id is outside data: a part over 256 escaped characters becomes "%%" + 64 hex digits.
    func testAVeryLongIDIsBounded() {
        let a256 = String(repeating: "a", count: 256), a257 = String(repeating: "a", count: 257)
        XCTAssertEqual(name(a256), "ProsperExt:\(a256):main", "256 is kept")
        for long in [a257, String(repeating: "x", count: 100_000), String(repeating: "é", count: 5_000)] {
            let n = name("com.example.kit", long)
            XCTAssertTrue(n.hasPrefix("ProsperExt:com.example.kit:%%"), String(n.prefix(40)))
            XCTAssertEqual(n.utf8.count, "ProsperExt:com.example.kit:".utf8.count + 66)
        }
        XCTAssertNotEqual(name(a257), name(a257 + "a"), "two long ids differ")
        XCTAssertNotEqual(name("com.example.kit", a257), name(a257, "com.example.kit"))
        XCTAssertEqual(name(String(repeating: "%", count: 85)).utf8.count, 11 + 255 + 5, "85 escapes: 255 kept")
        XCTAssertTrue(name(String(repeating: "%", count: 86)).hasPrefix("ProsperExt:%%"), "86 escapes: 258, hashed")
    }

    /// An id of only escaped scalars, the escape character itself included.
    func testAnIDOfOnlyEscapedScalars() {
        XCTAssertEqual(name("::"), "ProsperExt:%3A%3A:main")
        XCTAssertEqual(name("%"), "ProsperExt:%25:main")
        XCTAssertEqual(name("\u{0}\n"), "ProsperExt:%00%0A:main")
        XCTAssertEqual(name("\u{1F600}"), "ProsperExt:%F0%9F%98%80:main")
        XCTAssertEqual(name("e\u{301}"), "ProsperExt:e%CC%81:main")
    }

    /// Near-collisions: every pair (extension id, item id) in the table gets its own name, and every name is
    /// printable ASCII (a plain defaults key).
    func testNearCollisionsGetDifferentNames() {
        let pairs: [(String, String)] = [
            ("a_b", "c"), ("a:b", "c"), ("a b", "c"), ("a/b", "c"), ("a", "b:c"), ("a:b:c", ""), ("a", "b_c"),
            ("a%20b", "c"), ("a%3Ab", "c"), ("%", "c"), ("%25", "c"), ("\u{E9}", "c"), ("e\u{301}", "c"), ("_", "c"),
            ("com.x", "ext.main"), ("com.x.ext", "main"), ("com.x", "ext:main"), ("com.x:ext", "main"), ("", "c"),
            ("a%%", "c"), ("a%", "%c"),
        ]
        let names = pairs.map { name($0.0, $0.1) }
        XCTAssertEqual(Set(names).count, pairs.count, names.joined(separator: " "))
        for n in names {
            XCTAssertTrue(n.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value < 0x7F }, n)
        }
    }

    // MARK: QA #39, the content identifier

    /// Content items on a private bar, registered as their owners do; removed from the bar when the row ends.
    @MainActor
    private func contentItems(_ names: [String], on bar: NSStatusBar) -> [NSStatusItem] {
        names.map { n in
            let item = bar.statusItem(withLength: NSStatusItem.variableLength)
            ProsperStatusItems.register(item, role: .content, name: n)
            return item
        }
    }

    @MainActor
    private func ident(_ item: NSStatusItem) -> String { item.button?.accessibilityIdentifier() ?? "" }

    /// Two same-titled items of one extension and a third of another extension with that title: three
    /// identifiers, and the hosted read's lookup finds each item by its own.
    @MainActor
    func testSameNamedContentItemsEachGetTheirOwnIdentifier() throws {
        let bar = NSStatusBar()
        let items = contentItems(["Lid", "Lid", "Lid"], on: bar)
        defer { items.forEach { bar.removeStatusItem($0) } }
        let ids = items.map { ident($0) }
        XCTAssertEqual(Set(ids).count, 3, ids.joined(separator: " "))
        for (item, id) in zip(items, ids) {
            XCTAssertTrue(id.hasPrefix(ProsperStatusItems.contentPrefix), id)
            let hit = try XCTUnwrap(ProsperStatusItems.content(identifier: id, minX: -1e9))
            XCTAssertTrue(hit.item === item, id)
            XCTAssertEqual(hit.name, "Lid")
        }
    }

    /// An extension item titled like a built-in does not take the built-in's identifier, and no title shows in
    /// an identifier (so no title can name another item's).
    @MainActor
    func testAnItemNamedLikeABuiltInDoesNotTakeItsIdentifier() throws {
        let bar = NSStatusBar()
        let items = contentItems(["Calendar", "Calendar"], on: bar)
        defer { items.forEach { bar.removeStatusItem($0) } }
        let builtIn = try XCTUnwrap(items.first), ext = try XCTUnwrap(items.last)
        XCTAssertNotEqual(ident(builtIn), ident(ext))
        XCTAssertFalse(ident(ext).contains("Calendar"), ident(ext))
        XCTAssertTrue(ProsperStatusItems.content(identifier: ident(builtIn), minX: -1e9)?.item === builtIn)
        XCTAssertTrue(ProsperStatusItems.content(identifier: ident(ext), minX: -1e9)?.item === ext)
        XCTAssertTrue(ProsperStatusItems.content(identifier: ProsperStatusItems.contentPrefix + "Calendar", minX: -1e9) == nil,
                      "the old title form names no item")
    }
}
