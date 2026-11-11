import Foundation
import XCTest
@testable import ProsperApp

/// #870 P1: OrderedJSON and text-block units, plus the source guards.
final class ManagedConfigUnitTests: XCTestCase {

    func testOrderedJSONParsesAndKeepsLexemes() throws {
        let doc = try OrderedJSON(#"{"b": 1.50, "a": "xé\/", "c": [true, null, -0.5e+3]}"#)
        guard case .object(let m) = doc.root.value else { return XCTFail("not an object") }
        XCTAssertEqual(m.map(\.key), ["b", "a", "c"])
        if case .number(let n) = m[0].value.value { XCTAssertEqual(n, "1.50") } else { XCTFail("number") }
        if case .string(let s) = m[1].value.value { XCTAssertEqual(s, "xé/") } else { XCTFail("string") }
        XCTAssertEqual(OrderedJSON.canonical(doc.root.value), #"{"a":"xé/","b":1.5,"c":[true,null,-500]}"#)
    }

    func testDeepEqualityIgnoresKeyOrderAndNumberSpelling() throws {
        let a = try OrderedJSON(#"{"x": 1, "y": {"p": 2.0, "q": [1]}}"#).root.value
        let b = try OrderedJSON(#"{"y": {"q": [1.0], "p": 2}, "x": 1e0}"#).root.value
        XCTAssertEqual(OrderedJSON.hash(a), OrderedJSON.hash(b))
        let c = try OrderedJSON(#"{"y": {"q": [1], "p": 2}, "x": "1"}"#).root.value
        XCTAssertNotEqual(OrderedJSON.hash(a), OrderedJSON.hash(c))
    }

    func testOrderedJSONRefusals() {
        let cases: [(String, String)] = [
            (#"{"a": 1, "a": 2}"#, "duplicate key"),
            ("{\n/* c */ \"a\": 1}", "comments are not allowed"),
            (#"{"a": [1,]}"#, "trailing comma"),
            (#"{"a": 01}"#, "expected ',' or '}'"),
            (#"{"a": "\x"}"#, "invalid escape"),
            ("{} {}", "unexpected text"),
            ("", "unexpected end"),
        ]
        for (text, reason) in cases {
            XCTAssertThrowsError(try OrderedJSON(text), text) { error in
                XCTAssertTrue("\(error)".contains(reason), "\(text): \(error)")
            }
        }
    }

    func testInsertAndRemoveAreInversesInCompactAndPrettyContainers() throws {
        for text in [#"{"a": 1}"#, "{\n    \"a\": 1\n}", "{}", "{\n}", #"{"a": [1, 2]}"#] {
            let doc = try OrderedJSON(text)
            let value = try OrderedJSON(#"{"k": [1]}"#).root.value
            let inserted = try OrderedJSON(bytes: doc.insertingMember("new", value: value, intoObjectAt: []))
            XCTAssertNotNil(inserted.node(at: ["new", "k"]), text)
            let back = String(decoding: inserted.removingMember(at: ["new"]), as: UTF8.self)
            XCTAssertEqual(back, text == "{\n}" ? "{}" : text, "emptied containers are written {}")
        }
        let four = try OrderedJSON("{\n    \"a\": 1\n}")
        let out = String(decoding: four.insertingMember("b", value: .array([]), intoObjectAt: []), as: UTF8.self)
        XCTAssertEqual(out, "{\n    \"a\": 1,\n    \"b\": []\n}", "the file's own 4-space indent is used")
    }

    /// Known limit (the OrderedJSON emptied-container shortcut): a container emptied by a removal is
    /// written `[]`/`{}`, so a user's `[ ]` comes back compact. Pinned so the limit stays visible.
    func testEmptiedContainerShortcutIsPinned() throws {
        let doc = try OrderedJSON(#"{"allow": [ ]}"#)
        let added = try OrderedJSON(bytes: doc.appendingElement(.string("x"), toArrayAt: ["allow"]))
        XCTAssertEqual(String(decoding: added.removingElement(0, fromArrayAt: ["allow"]), as: UTF8.self), #"{"allow": []}"#)
    }

    func testTextBlockMarkersForMarkdownAndOtherText() {
        let md = ManagedTextBlock.render(owner: "o", piece: "p", version: "2", body: "x\n\n", syntax: .markdown)
        XCTAssertEqual(md, "<!-- >>> prosper:o:p v2 · managed by Prosper, edits show as drift >>> -->\nx\n<!-- <<< prosper:o:p <<< -->")
        let sh = ManagedTextBlock.render(owner: "o", piece: "p", version: "2", body: "x", syntax: .hash)
        XCTAssertTrue(sh.hasPrefix("# >>> prosper:o:p v2") && sh.hasSuffix("# <<< prosper:o:p <<<"))
        XCTAssertFalse(ManagedTextBlock.bodyIsValid("<!-- <<< prosper:o:p <<< -->"))
        let twice = Array((md + "\n" + md + "\n").utf8)
        XCTAssertEqual(ManagedTextBlock.find(owner: "o", piece: "p", in: twice), .corrupt(lines: [1, 3, 4, 6]))
    }

    // MARK: guards

    private var appDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(_ dir: URL) -> [URL] {
        (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Done-condition: nothing in ManagedConfig or its tests reaches the real home except the
    /// single production-default function, and no test reads the process env for the root.
    func testHomeIsReadOnlyInTheProductionDefault() throws {
        let home = "homeDirectory" + "ForCurrentUser"
        let forbidden = ["NSHome" + "Directory", "expandingTilde" + "InPath", "\"" + "~" + "/", "Process" + "Info.processInfo.environment"]
        let sources = swiftFiles(appDir.appendingPathComponent("Sources/ProsperApp/ManagedConfig"))
        XCTAssertGreaterThanOrEqual(sources.count, 7)
        let tests = swiftFiles(appDir.appendingPathComponent("Tests/ProsperAppTests")).filter { $0.lastPathComponent.hasPrefix("ManagedConfig") }
        XCTAssertGreaterThanOrEqual(tests.count, 2)
        var homeLines: [String] = []
        for file in sources + tests {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden { XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) uses \(token)") }
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains(home) {
                let fn = lines[..<i].last { $0.contains("func ") } ?? ""
                homeLines.append("\(file.lastPathComponent): \(fn.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(homeLines, ["ManagedConfigPaths.swift: static func production(loginEnvironment: [String: String]) -> ManagedConfigRoots {"])
    }

    /// P1 wires the core to nothing: no source outside ManagedConfig/ names it.
    func testNoCallSiteOutsideTheManagedConfigDirectory() throws {
        let dir = appDir.appendingPathComponent("Sources")
        for file in swiftFiles(dir) where !file.path.contains("/ManagedConfig/") {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("ManagedConfig"), file.lastPathComponent)
        }
    }

    /// Swift 6: the core carries no actor isolation (it runs off main; the sheet hops to main itself).
    func testCoreHasNoMainActorIsolation() throws {
        for file in swiftFiles(appDir.appendingPathComponent("Sources/ProsperApp/ManagedConfig")) {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("@" + "MainActor"), file.lastPathComponent)
        }
    }
}
