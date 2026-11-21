import Foundation
import XCTest
@testable import ProsperApp

/// #1810: settings.schema / get / set over the real stores. Every value lives in `Preferences.defaults`, which under
/// XCTest is the in-memory XCTestDefaults store (never the real defaults domain); each row puts back what it touched.
@MainActor
final class ControlSettingsTests: XCTestCase {

    private func registry() -> ControlRegistry {
        var r = ControlRegistry()
        ControlRegistry.registerSettings(&r)
        return r
    }

    private func call(_ cmd: String, _ args: [String: ControlJSON]? = nil) async -> ControlReply {
        let data = try! JSONEncoder().encode(ControlRequest(cmd: cmd, args: args))
        return await registry().reply(to: data)
    }

    /// Restores `keys` in the test store at teardown, exactly as they were (absent stays absent).
    private func keep(_ keys: [String]) {
        let saved = keys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
    }

    func testEveryPaneControlIsASchemaEntryOrAnExplainedExclusion() {
        let titles = Set(ControlSettings.all().map(\.title))
        let controls = Set(nativeSettingsIndex.flatMap(\.keywords))
        XCTAssertFalse(controls.isEmpty)
        let missing = controls.filter { !titles.contains($0) && ControlSettings.notSettings[$0] == nil }.sorted()
        XCTAssertEqual(missing, [], "Settings controls with no settings.schema entry and no reason in ControlSettings.notSettings")
        XCTAssertEqual(titles.intersection(ControlSettings.notSettings.keys).sorted(), [], "both a setting and excluded")
    }

    func testSchemaRowsCarryEveryFieldAndAValueInsideTheirOwnBounds() async {
        let reply = await call("settings.schema")
        XCTAssertTrue(reply.ok, reply.error ?? "")
        guard case .object(let o)? = reply.result, case .array(let rows)? = o["settings"] else { return XCTFail("no settings array") }
        XCTAssertEqual(rows.count, ControlSettings.all().count)
        var keys = Set<String>()
        for case .object(let r) in rows {
            guard case .string(let key)? = r["key"], case .string(let type)? = r["type"] else { XCTFail("row without key/type: \(r)"); continue }
            XCTAssertTrue(keys.insert(key).inserted, "duplicate key \(key)")
            for f in ["title", "section", "value", "default", "writable"] { XCTAssertTrue(r[f] != nil, "\(key) has no \(f)") }
            switch type {
            case "boolean": XCTAssertEqual(r["value"]?.typeName, "boolean", key)
            case "number", "integer":
                guard case .number(let v)? = r["value"], case .number(let lo)? = r["min"], case .number(let hi)? = r["max"],
                      case .number(let d)? = r["default"] else { XCTFail("\(key) lacks a numeric value/min/max/default"); continue }
                XCTAssertTrue(lo <= v && v <= hi && lo <= d && d <= hi, "\(key) value \(v) default \(d) outside \(lo)...\(hi)")
            case "string":
                guard case .array(let allowed)? = r["allowed"] else { XCTFail("\(key) has no allowed list"); continue }
                XCTAssertTrue(r["value"].map { allowed.contains($0) } == true, "\(key) value not in its allowed list")
            default: XCTFail("\(key) has unknown type \(type)")
            }
        }
        XCTAssertEqual(keys.count, rows.count)
    }

    /// The declared default is what the store reads with the key absent, and a stored non-default value under the
    /// schema key is what get() returns: so the default and the key name cannot drift from the store.
    func testDefaultAndKeyNameMatchTheStore() {
        let d = Preferences.defaults
        for s in ControlSettings.all() where s.key != "theme" {
            keep([s.key])
            d.removeObject(forKey: s.key)
            XCTAssertEqual(s.get(), s.defaultValue, "\(s.key): declared default differs from the store's")
            let probe: Any
            switch (s.kind, s.defaultValue) {
            case (.bool, .bool(let b)): probe = !b
            case (.number(let r, _), .number(let n)): probe = n == r.upperBound ? r.lowerBound : r.upperBound
            case (.choice(let allowed), .string(let v)):
                guard let other = allowed.first(where: { $0 != v }) else { continue }
                probe = other
            default: XCTFail("\(s.key): default does not match its kind"); continue
            }
            d.set(probe, forKey: s.key)
            XCTAssertNotEqual(s.get(), s.defaultValue, "\(s.key): get() does not read the key it is declared under")
        }
    }

    func testSecretsAreNeverInTheSchemaAndNeverReadable() async {
        let secret = try! NSRegularExpression(pattern: "token|secret|password|keychain|api.?key|encryption|license|ccpool|credential",
                                              options: .caseInsensitive)
        for s in ControlSettings.all() {
            for text in [s.key, s.title] {
                XCTAssertTrue(secret.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil, "secret-looking setting \(text)")
            }
        }
        XCTAssertTrue(ControlSettings.notSettings["Encryption key"] != nil)
        for key in ["syncEncryptionKey", "encryptionKey", "apiToken", "AppleLanguages"] {
            let r = await call("settings.get", ["key": .string(key)])
            XCTAssertFalse(r.ok, "\(key) was readable")
            XCTAssertTrue(r.result == nil)
        }
    }

    func testGetReadsTheStoreAndRefusesUnknownOrMissingKeys() async {
        keep(["suppressOnTypo"])
        Preferences.suppressOnTypo = true
        let r = await call("settings.get", ["key": .string("suppressOnTypo")])
        XCTAssertEqual(r.result, .object(["key": .string("suppressOnTypo"), "value": .bool(true)]))
        let unknown = await call("settings.get", ["key": .string("nope")])
        XCTAssertEqual(unknown.error, "unknown setting 'nope' (settings.schema lists them)")
        let missing = await call("settings.get")
        XCTAssertFalse(missing.ok)
    }

    func testSetChecksEveryValueBeforeWritingAny() {
        keep(["suppressOnTypo", "clipboardHistoryMaxItems", "completionLength"])
        Preferences.suppressOnTypo = false
        let bad: [(String, [String: ControlJSON], String)] = [
            ("enum", ["suppressOnTypo": .bool(true), "completionLength": .string("huge")], "completionLength must be one of short, medium, long"),
            ("type", ["suppressOnTypo": .string("yes")], "suppressOnTypo must be boolean, got string"),
            ("range", ["agentTopP": .number(0.05), "suppressOnTypo": .bool(true)], "agentTopP must be between 0.1 and 1.0"),
            ("whole", ["clipboardHistoryMaxItems": .number(20.5)], "clipboardHistoryMaxItems must be a whole number"),
            ("read-only", ["launchAtLogin": .bool(false), "suppressOnTypo": .bool(true)], "launchAtLogin is changed in Settings only"),
            ("unknown", ["suppressOnTypo": .bool(true), "zzz": .bool(true)], "unknown setting 'zzz' (settings.schema lists them)"),
            ("empty", [:], "values is empty"),
        ]
        for (name, values, message) in bad {
            XCTAssertThrowsError(try ControlSettings.apply(values), name) { XCTAssertEqual(($0 as? ControlError)?.message, message, name) }
            XCTAssertFalse(Preferences.suppressOnTypo, "\(name): a value was written before the batch was checked")
        }
    }

    func testSetWritesThroughTheStoreAndUndoPutsEveryValueBack() throws {
        keep(["suppressOnTypo", "completionLength", "clipboardHistoryMaxItems"])
        Preferences.suppressOnTypo = false
        Preferences.completionLength = .medium
        Preferences.clipboardHistoryMaxItems = 500
        let change = try ControlSettings.apply(["suppressOnTypo": .bool(true), "completionLength": .string("long"),
                                                "clipboardHistoryMaxItems": .number(42)])
        XCTAssertTrue(Preferences.suppressOnTypo)
        XCTAssertEqual(Preferences.completionLength, .long)
        XCTAssertEqual(Preferences.clipboardHistoryMaxItems, 42)
        XCTAssertEqual(change.summary, "History size to 42, Length to long, Don't complete when a typo is suspected to on")
        XCTAssertEqual(change.result, .object(["suppressOnTypo": .bool(true), "completionLength": .string("long"),
                                               "clipboardHistoryMaxItems": .number(42)]))
        change.undo()
        XCTAssertFalse(Preferences.suppressOnTypo)
        XCTAssertEqual(Preferences.completionLength, .medium)
        XCTAssertEqual(Preferences.clipboardHistoryMaxItems, 500)
    }

    func testSetGoesThroughTheRegistryAsAMutatingCommandAndReadsDoNot() async {
        keep(["suppressOnTypo"])
        Preferences.suppressOnTypo = false
        let r = await call("settings.set", ["values": .object(["suppressOnTypo": .bool(true)])])
        XCTAssertTrue(r.ok, r.error ?? "")
        XCTAssertTrue(Preferences.suppressOnTypo)
        let reg = registry()
        XCTAssertEqual(reg.commands["settings.set"]?.mutates, true)
        XCTAssertEqual(reg.commands["settings.get"]?.mutates, false)
        XCTAssertEqual(reg.commands["settings.schema"]?.mutates, false)
        let notObject = await call("settings.set", ["values": .string("suppressOnTypo=true")])
        XCTAssertEqual(notObject.error, "argument 'values' must be object, got string")
    }
}
