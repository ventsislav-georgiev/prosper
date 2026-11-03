import Network
import os
import XCTest
@testable import ProsperApp

/// #731: 0x2c putPhoneSnippets and the phones' read-only sets on the Mac. Every file lives
/// under a tempDir() through DchLibraryOps.dir / PhoneSnippetStore.url; no test reads or
/// writes ~/.config/prosper.
final class PhoneSnippetsTests: XCTestCase {
    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
    }

    private func ops(_ label: String = #function) -> (DchLibraryOps, URL) {
        let dir = tempDir(label)
        return (DchLibraryOps(dir: dir), dir.appendingPathComponent(PhoneSnippetStore.fileName))
    }

    private static func body(device: String = "dev-A1B2", name: String? = "Kitchen", hash: String = "h1",
                             _ snippets: [[String: Any]]) -> Data {
        var o: [String: Any] = ["device_id": device, "hash": hash, "snippets": snippets]
        if let name { o["device_name"] = name }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    /// One request; exactly one reply, decoded.
    private func call(_ o: DchLibraryOps, _ raw: Data, file: StaticString = #filePath, line: UInt = #line)
        -> (type: UInt8, json: [String: Any]) {
        let frames = Frames()
        o.put(raw) { f in frames.lock.withLock { frames.all.append(f) } }
        let all = frames.lock.withLock { frames.all }
        XCTAssertEqual(all.count, 1, "one reply", file: file, line: line)
        let b = [UInt8](all.first ?? Data([0, 0, 0, 0, 0]))
        let json = (try? JSONSerialization.jsonObject(with: Data(b.dropFirst(5)))) as? [String: Any] ?? [:]
        return (b[0], json)
    }

    private func assertOK(_ r: (type: UInt8, json: [String: Any]), count: Int, hash: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.type, DchFrame.ok, "\(r.json)", file: file, line: line)
        XCTAssertEqual(r.json["count"] as? Int, count, file: file, line: line)
        XCTAssertEqual(r.json["hash"] as? String, hash, file: file, line: line)
    }

    private func assertRefused(_ r: (type: UInt8, json: [String: Any]), _ message: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.type, DchFrame.error, file: file, line: line)
        XCTAssertEqual(r.json["message"] as? String, message, file: file, line: line)
    }

    private static var sig: [String: Any] { ["name": "Sig", "text": "Best, V", "keyword": ";sig", "group": "Work"] }

    // MARK: - Wire

    func testFrameByteAndOps() {
        XCTAssertEqual(DchFrame.putPhoneSnippets, 0x2c)
        XCTAssertTrue(DchFrame.ops.contains("snippets_put"))
        XCTAssertTrue((DchFrame.machineInfo(deviceID: "i", hostname: "h", wakeId: nil)["ops"] as? [String] ?? [])
            .contains("snippets_put"), "always advertised")
    }

    func testReplaceStoresTheSetAndRepliesCountAndHash() {
        let (o, url) = ops()
        assertOK(call(o, Self.body([Self.sig, ["name": "Addr", "text": "1 Loop"]])), count: 2, hash: "h1")
        assertOK(call(o, Self.body(hash: "h2", [["name": "Only", "text": "x"]])), count: 1, hash: "h2")
        let set = PhoneSnippetStore(url: url).load()["dev-A1B2"]
        XCTAssertEqual(set?.snippets.map(\.name), ["Only"], "replaced, not merged")
        XCTAssertEqual(set?.hash, "h2")
        XCTAssertEqual(set?.name, "Kitchen")
    }

    func testEmptyListClearsTheDevice() {
        let (o, url) = ops()
        assertOK(call(o, Self.body([Self.sig])), count: 1, hash: "h1")
        assertOK(call(o, Self.body(hash: "h0", [])), count: 0, hash: "h0")
        XCTAssertNil(PhoneSnippetStore(url: url).load()["dev-A1B2"])
    }

    func testTwoDevicesStayApart() {
        let (o, url) = ops()
        assertOK(call(o, Self.body(device: "phone-1", [Self.sig])), count: 1, hash: "h1")
        assertOK(call(o, Self.body(device: "phone-2", name: nil, [["name": "Sig", "text": "other"]])), count: 1, hash: "h1")
        assertOK(call(o, Self.body(device: "phone-1", hash: "h3", [])), count: 0, hash: "h3")
        let all = PhoneSnippetStore(url: url).load()
        XCTAssertNil(all["phone-1"])
        XCTAssertEqual(all["phone-2"]?.snippets.first?.text, "other", "clearing one device leaves the other")
        XCTAssertEqual(all["phone-2"]?.label, "iPhone", "no device_name: iPhone")
    }

    func testSameHashSkipsTheWriteAndStillRepliesOK() throws {
        let (o, url) = ops()
        let token = SnippetStore.changeToken
        assertOK(call(o, Self.body([Self.sig])), count: 1, hash: "h1")
        XCTAssertNotEqual(SnippetStore.changeToken, token, "a write refreshes the expander's keywords")
        let written = SnippetStore.changeToken
        let marker = Data(#"{"dev-A1B2":{"hash":"h1","updated":1,"snippets":[]}}"#.utf8)
        try marker.write(to: url)
        assertOK(call(o, Self.body([Self.sig, ["name": "New", "text": "n"]])), count: 2, hash: "h1")
        XCTAssertEqual(try Data(contentsOf: url), marker, "an unchanged hash never writes")
        XCTAssertEqual(SnippetStore.changeToken, written)
    }

    func testAFailedWriteIsAnError() throws {
        let blocker = tempDir().appendingPathComponent("file")
        try Data().write(to: blocker)
        let s = PhoneSnippetStore(url: blocker.appendingPathComponent(PhoneSnippetStore.fileName))
        XCTAssertEqual(s.put(Self.body([Self.sig])), .refused("could not save snippets"))
    }

    // MARK: - Refusals leave the store untouched

    func testEveryRefusalLeavesTheStoreUntouched() throws {
        let (o, url) = ops()
        assertOK(call(o, Self.body([Self.sig])), count: 1, hash: "h1")
        let before = try Data(contentsOf: url)
        let long = String(repeating: "n", count: 257)
        let malformed: [Data] = [
            Data(), Data("x".utf8), Data("[]".utf8), Data("null".utf8),
            try JSONSerialization.data(withJSONObject: ["hash": "h", "snippets": []]),          // no device_id
            try JSONSerialization.data(withJSONObject: ["device_id": "d", "snippets": []]),     // no hash
            try JSONSerialization.data(withJSONObject: ["device_id": "d", "hash": "h"]),        // no snippets
            try JSONSerialization.data(withJSONObject: ["device_id": 7, "hash": "h", "snippets": []]),
            try JSONSerialization.data(withJSONObject: ["device_id": "d", "hash": "h", "snippets": "x"]),
            try JSONSerialization.data(withJSONObject: ["device_id": "d", "device_name": 3, "hash": "h", "snippets": []]),
            Self.body(device: "", [Self.sig]),
            Self.body(device: String(repeating: "d", count: 129), [Self.sig]),
            Self.body(device: "dev-A1B2", hash: "h9", [["name": "", "text": "t"]]),
            Self.body(device: "dev-A1B2", hash: "h9", [["name": long, "text": "t"]]),
            Self.body(device: "dev-A1B2", hash: "h9", [["name": "n"]]),                                  // no text
            Self.body(device: "dev-A1B2", hash: "h9", [["text": "t"]]),                                  // no name
            Self.body(device: "dev-A1B2", hash: "h9", [["name": "n", "text": "t", "keyword": 1]]),
            Self.body(device: "dev-A1B2", hash: "h9", [["name": "n", "text": "t", "group": false]]),
            try JSONSerialization.data(withJSONObject: ["device_id": "d", "hash": "h", "snippets": ["s"]]),
        ]
        for raw in malformed {
            assertRefused(call(o, raw), "malformed snippets")
            XCTAssertEqual(try Data(contentsOf: url), before, String(decoding: raw.prefix(80), as: UTF8.self))
        }
        assertRefused(call(o, Self.body(hash: "h9", [Self.sig, ["name": "Sig", "text": "again"]])), "duplicate name: Sig")
        XCTAssertEqual(try Data(contentsOf: url), before)
        let many = (0...PhoneSnippetStore.maxSnippets).map { ["name": "s\($0)", "text": "t"] }
        assertRefused(call(o, Self.body(hash: "h9", many)), "too large")
        XCTAssertEqual(try Data(contentsOf: url), before)
        let huge = Self.body(hash: "h9", [["name": "big", "text": String(repeating: "x", count: DchLibraryOps.fileCap)]])
        assertRefused(call(o, huge), "too large")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testCapsAreInclusive() {
        let (o, url) = ops()
        let many = (0..<PhoneSnippetStore.maxSnippets).map { ["name": "s\($0)", "text": "t"] }
        assertOK(call(o, Self.body(hash: "m", many)), count: PhoneSnippetStore.maxSnippets, hash: "m")
        let edge = Self.body(device: String(repeating: "d", count: 128), hash: "e",
                             [["name": String(repeating: "n", count: 256), "text": "t"]])
        assertOK(call(o, edge), count: 1, hash: "e")
        // Characters, not UTF-8 bytes (prosper-ios: String.count): 256 emoji pass, 257 are refused.
        assertOK(call(o, Self.body(hash: "u", [["name": String(repeating: "\u{1F600}", count: 256), "text": "t"]])),
                 count: 1, hash: "u")
        assertRefused(call(o, Self.body(hash: "v", [["name": String(repeating: "\u{1F600}", count: 257), "text": "t"]])),
                      "malformed snippets")
        // A body of exactly fileCap bytes.
        let shell = Self.body(hash: "c", [["name": "big", "text": ""]])
        let atCap = Self.body(hash: "c", [["name": "big", "text": String(repeating: "x", count: DchLibraryOps.fileCap - shell.count)]])
        XCTAssertEqual(atCap.count, DchLibraryOps.fileCap)
        assertOK(call(o, atCap), count: 1, hash: "c")
        XCTAssertEqual(PhoneSnippetStore(url: url).load().count, 2)
    }

    // MARK: - Library 0x0f never carries a phone set

    func testLibraryEtagAndPayloadUnchangedByAPut() throws {
        let (o, _) = ops()
        try Data(#"{"version":1,"snippets":[{"name":"Sig","text":"mac"}]}"#.utf8)
            .write(to: o.dir!.appendingPathComponent("snippets.json"))
        func library() -> (etag: String?, snippets: NSObject?) {
            let frames = Frames()
            o.handle(Data()) { f in frames.lock.withLock { frames.all.append(f) } }
            let f = frames.lock.withLock { frames.all.first } ?? Data([0, 0, 0, 0, 0])
            let json = (try? JSONSerialization.jsonObject(with: f.dropFirst(5))) as? [String: Any] ?? [:]
            return (json["etag"] as? String, json["snippets"] as? NSObject)
        }
        let before = library()
        assertOK(call(o, Self.body([Self.sig])), count: 1, hash: "h1")
        let after = library()
        XCTAssertNotNil(before.etag)
        XCTAssertEqual(after.etag, before.etag)
        XCTAssertEqual(after.snippets, before.snippets)
    }

    // MARK: - Keywords, identity, expansion

    private func store(_ label: String = #function) -> PhoneSnippetStore {
        PhoneSnippetStore(url: tempDir(label).appendingPathComponent(PhoneSnippetStore.fileName))
    }

    private func put(_ s: PhoneSnippetStore, _ device: String, at t: TimeInterval, _ snippets: [[String: Any]]) {
        XCTAssertEqual(s.put(Self.body(device: device, hash: "\(t)", snippets), now: Date(timeIntervalSince1970: t)),
                       .ok(count: snippets.count, hash: "\(t)"))
    }

    func testMacKeywordWinsAndTheNewestPhoneWinsBetweenPhones() {
        let s = store()
        put(s, "old", at: 100, [["name": "A", "text": "old addr", "keyword": "addr"],
                                ["name": "B", "text": "old b", "keyword": "bb"],
                                ["name": "P", "text": "phone pp", "keyword": ";;pp"]])
        put(s, "new", at: 200, [["name": "B2", "text": "new b", "keyword": "bb"],
                                ["name": "Mute", "text": "phone", "keyword": "off"]])
        let mac = [SnippetHit(name: "Addr", keyword: "addr", text: "mac addr"),
                   SnippetHit(name: "Off", keyword: "off", text: "mac off", autoExpand: false),
                   SnippetHit(name: "Pref", keyword: "pp", text: "mac pp", collection: "C")]
        let keywords = SnippetStore.effectiveKeywords(mac, collections: ["C": (prefix: ";;", suffix: "")], phone: s.sets())
        XCTAssertEqual(keywords.map(\.trigger), ["addr", ";;pp", "bb"],
                       "phone addr, off and ;;pp are the Mac's (affixes applied); one bb")
        let lookup: (String) -> SnippetHit? = { id in
            PhoneSnippetStore.lookup(id, phone: s, mac: { n in mac.first { $0.name == n } })
        }
        func expand(_ buffer: String) -> SnippetExpansionDecision {
            SnippetExpander.plan(buffer: buffer, keywords: keywords, lookup: lookup,
                                 context: PlaceholderContext(), wordBoundaryMode: false)
        }
        guard case let .insertPlain(_, _, macText, _) = expand("x addr") else { return XCTFail("addr fires") }
        XCTAssertEqual(macText, "mac addr")
        guard case let .insertPlain(_, backspaces, phoneText, _) = expand("x bb") else { return XCTFail("bb fires") }
        XCTAssertEqual(phoneText, "new b", "the most recently put set wins")
        XCTAssertEqual(backspaces, 1)
        XCTAssertEqual(expand("x off"), .none, "a Mac keyword that does not auto-expand still blocks the phone's")
    }

    func testPhoneNameNeverShadowsTheMacSnippet() {
        let s = store()
        put(s, "dev", at: 1, [["name": "Sig", "text": "phone sig", "keyword": "psig", "group": "Work"]])
        let mac = SnippetHit(name: "Sig", keyword: "msig", text: "mac sig")
        let macLookup: (String) -> SnippetHit? = { $0 == mac.name ? mac : nil }
        XCTAssertEqual(PhoneSnippetStore.lookup("Sig", phone: s, mac: macLookup)?.text, "mac sig")
        let keywords = PhoneSnippetStore.triggers(mac: [("msig", "Sig")], macKeywords: ["msig"], sets: s.sets())
        let phoneID = keywords.first { $0.trigger == "psig" }?.id
        XCTAssertEqual(phoneID, PhoneSnippetStore.id(device: "dev", name: "Sig"))
        XCTAssertNotEqual(phoneID, "Sig")
        let hit = PhoneSnippetStore.lookup(phoneID ?? "", phone: s, mac: macLookup)
        XCTAssertEqual(hit?.text, "phone sig")
        XCTAssertEqual(hit?.collection, "Kitchen", "grouped under the device name, not a Mac collection")
        XCTAssertEqual(hit?.description, "Work", "the phone's group is the description")
        XCTAssertNil(PhoneSnippetStore.lookup(PhoneSnippetStore.id(device: "dev", name: "Nope"), phone: s, mac: macLookup))
        XCTAssertNil(PhoneSnippetStore.lookup(PhoneSnippetStore.id(device: "x", name: "Sig"), phone: s,
                                              mac: { _ in mac }), "a phone id never resolves to a Mac snippet")
    }

    func testPhoneTextExpandsThroughThePlaceholderEngine() {
        let s = store()
        put(s, "dev", at: 1, [["name": "Greet", "text": "Hi {snippet:sig}{cursor}!", "keyword": "gr"],
                              ["name": "S", "text": "V", "keyword": "sig"]])
        var ctx = PlaceholderContext()
        let sets = s.sets()
        ctx.snippetByKeyword = { PhoneSnippetStore.text(forKey: $0, in: sets) }
        let keywords = PhoneSnippetStore.triggers(mac: [], macKeywords: [], sets: sets)
        let d = SnippetExpander.plan(buffer: "gr", keywords: keywords, lookup: { s.hit(id: $0) },
                                     context: ctx, wordBoundaryMode: false)
        XCTAssertEqual(d, .insertPlain(name: PhoneSnippetStore.id(device: "dev", name: "Greet"), backspaces: 1,
                                       insertText: "Hi V!", leftArrows: 1))
    }

    // MARK: - Remove

    func testRemoveDropsOnlyThatDevice() {
        let s = store()
        put(s, "one", at: 1, [Self.sig])
        put(s, "two", at: 2, [Self.sig])
        s.remove(deviceID: "one")
        s.remove(deviceID: "unknown")
        XCTAssertEqual(s.sets().map(\.device), ["two"])
        XCTAssertNil(s.hit(id: PhoneSnippetStore.id(device: "one", name: "Sig")))
    }

    // MARK: - Through DchConnection

    func testConnectionRepliesOK() {
        let queue = DispatchQueue(label: "test.dchconn.phoneSnippets")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        let (o, url) = ops()
        conn.library = o
        let frames = Frames(), replied = expectation(description: "reply")
        conn.sendOverride = { frame in frames.lock.withLock { frames.all.append(frame) }; replied.fulfill() }
        queue.sync { conn.handle(type: DchFrame.putPhoneSnippets, payload: Self.body([Self.sig])) }
        wait(for: [replied], timeout: 5)
        XCTAssertEqual(frames.lock.withLock { frames.all.first?.first }, DchFrame.ok)
        XCTAssertEqual(PhoneSnippetStore(url: url).load()["dev-A1B2"]?.snippets.count, 1)
        XCTAssertFalse(queue.sync { conn.inFlight }, "the one reply cleared inFlight")
    }
}
