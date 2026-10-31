import Network
import os
import XCTest
@testable import ProsperApp

/// #616: the phone's library 0x0f → libraryResp 0x1c. Every file lives under a
/// tempDir() through DchLibraryOps.dir; no test reads ~/.config/prosper.
final class DchLibraryFramesTests: XCTestCase {
    private static let snippets = #"{"version":1,"collections":[{"name":"Work","prefix":";"}],"snippets":[{"name":"Sig","keyword":";sig","text":"Best,\nV","autoExpand":true}]}"#
    private static let quicklinks = #"{"version":1,"quicklinks":[{"name":"gh","url":"https://github.com/search?q={query}","description":"GitHub"}]}"#

    private func lib(snippets: String? = DchLibraryFramesTests.snippets,
                     quicklinks: String? = DchLibraryFramesTests.quicklinks,
                     label: String = #function) -> (DchLibraryOps, URL) {
        let dir = tempDir(label)
        if let snippets { write(snippets, dir, "snippets.json") }
        if let quicklinks { write(quicklinks, dir, "quicklinks.json") }
        return (DchLibraryOps(dir: dir), dir)
    }

    private func write(_ s: String, _ dir: URL, _ name: String) {
        try! Data(s.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// One request; exactly one reply, decoded.
    private func call(_ o: DchLibraryOps, raw: Data = Data(), file: StaticString = #filePath, line: UInt = #line)
        -> (type: UInt8, json: [String: Any]) {
        let frames = Frames()
        o.handle(raw) { f in frames.lock.withLock { frames.all.append(f) } }
        let all = frames.lock.withLock { frames.all }
        XCTAssertEqual(all.count, 1, "one reply", file: file, line: line)
        return Self.decode(all.first ?? Data([0, 0, 0, 0, 0]), file: file, line: line)
    }

    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
    }

    private static func decode(_ f: Data, file: StaticString = #filePath, line: UInt = #line) -> (type: UInt8, json: [String: Any]) {
        let b = [UInt8](f)
        let len = (Int(b[1]) << 24) | (Int(b[2]) << 16) | (Int(b[3]) << 8) | Int(b[4])
        XCTAssertEqual(len, b.count - 5, "length prefix", file: file, line: line)
        let json = (try? JSONSerialization.jsonObject(with: Data(b.dropFirst(5)))) as? [String: Any] ?? [:]
        return (b[0], json)
    }

    private func call(_ o: DchLibraryOps, etag: String) -> (type: UInt8, json: [String: Any]) {
        call(o, raw: try! JSONSerialization.data(withJSONObject: ["etag": etag]))
    }

    private static func parsed(_ s: String) -> NSObject {
        try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! NSObject
    }

    func testBothFilesAreServedAsStored() {
        let (o, _) = lib()
        for raw in [Data(), Data("{}".utf8)] {
            let r = call(o, raw: raw)
            XCTAssertEqual(r.type, DchFrame.libraryResp)
            XCTAssertEqual(r.json["snippets"] as? NSObject, Self.parsed(Self.snippets))
            XCTAssertEqual(r.json["quicklinks"] as? NSObject, Self.parsed(Self.quicklinks))
            XCTAssertNil(r.json["unchanged"])
            XCTAssertNil(r.json["errors"])
            XCTAssertEqual(r.json["etag"] as? String,
                           DchLibraryOps.etag(Data(Self.snippets.utf8), Data(Self.quicklinks.utf8)))
        }
    }

    /// The phone refuses a schema version it does not know: each file's own "version"
    /// stays the number 1 (not true, not a string), and none is invented where absent.
    func testVersionFieldsKeptAndNeverInvented() {
        let (o, _) = lib()
        let r = call(o)
        for k in ["snippets", "quicklinks"] {
            let v = (r.json[k] as? [String: Any])?["version"] as? NSNumber
            XCTAssertEqual(v, 1, k)
            XCTAssertNotEqual(v.map { CFGetTypeID($0) }, CFBooleanGetTypeID(), k)
        }
        let bare = call(lib(snippets: #"{"snippets":[]}"#, quicklinks: "[]").0)
        XCTAssertEqual(bare.json["snippets"] as? NSObject, Self.parsed(#"{"snippets":[]}"#))
        XCTAssertEqual((bare.json["quicklinks"] as? [Any])?.count, 0, "a bare array stays a bare array")
    }

    func testEtagMatchIsUnchangedAndStaleIsFull() {
        let (o, _) = lib()
        let etag = call(o).json["etag"] as? String ?? ""
        XCTAssertEqual(etag.count, 64)
        XCTAssertEqual(etag, etag.lowercased())
        let same = call(o, etag: etag)
        XCTAssertEqual(same.type, DchFrame.libraryResp)
        XCTAssertEqual(same.json as NSDictionary, ["etag": etag, "unchanged": true] as NSDictionary)
        let stale = call(o, etag: String(repeating: "0", count: 64))
        XCTAssertEqual(stale.json["etag"] as? String, etag)
        XCTAssertNil(stale.json["unchanged"])
        XCTAssertEqual(stale.json["snippets"] as? NSObject, Self.parsed(Self.snippets))
    }

    func testEtagChangesWhenEitherFileChanges() {
        let (o, dir) = lib()
        let e0 = call(o).json["etag"] as? String
        write(Self.snippets + " ", dir, "snippets.json")
        let e1 = call(o).json["etag"] as? String
        write(Self.quicklinks + " ", dir, "quicklinks.json")
        let e2 = call(o).json["etag"] as? String
        XCTAssertEqual(Set([e0, e1, e2]).count, 3)
        // The 0x00 separator: moving a byte across the boundary changes the etag.
        XCTAssertNotEqual(DchLibraryOps.etag(Data("ab".utf8), Data("c".utf8)), DchLibraryOps.etag(Data("a".utf8), Data("bc".utf8)))
    }

    func testMissingFileIsNullWithoutError() {
        let r = call(lib(quicklinks: nil).0)
        XCTAssertEqual(r.type, DchFrame.libraryResp)
        XCTAssertTrue(r.json["quicklinks"] is NSNull)
        XCTAssertEqual(r.json["snippets"] as? NSObject, Self.parsed(Self.snippets))
        XCTAssertNil(r.json["errors"])
        XCTAssertEqual(r.json["etag"] as? String, DchLibraryOps.etag(Data(Self.snippets.utf8), Data()))
        let none = call(lib(snippets: nil, quicklinks: nil).0)
        XCTAssertTrue(none.json["snippets"] is NSNull)
        XCTAssertTrue(none.json["quicklinks"] is NSNull)
    }

    func testMalformedOrUnreadableFileIsNullWithError() {
        let (o, dir) = lib(snippets: "{\"version\":1,", quicklinks: nil)
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("quicklinks.json"), withIntermediateDirectories: false)
        let r = call(o)
        XCTAssertEqual(r.type, DchFrame.libraryResp)
        XCTAssertTrue(r.json["snippets"] is NSNull)
        XCTAssertTrue(r.json["quicklinks"] is NSNull)
        XCTAssertEqual(r.json["errors"] as? [String: String], ["snippets": "malformed JSON", "quicklinks": "unreadable"])
    }

    /// QA #484 I1: a FIFO at snippets.json is unreadable, never a hang: the reply
    /// comes within a second (a blocked open would pin the thread and the connection).
    func testFifoIsUnreadableAndNeverBlocksTheReply() {
        let (o, dir) = lib(snippets: nil)
        let fifo = dir.appendingPathComponent("snippets.json").path
        XCTAssertEqual(Darwin.mkfifo(fifo, 0o600), 0)
        let frames = Frames(), got = expectation(description: "one reply")
        DispatchQueue.global().async {
            o.handle(Data()) { f in
                frames.lock.withLock { frames.all.append(f) }
                got.fulfill()
            }
        }
        guard XCTWaiter().wait(for: [got], timeout: 1) == .completed else {
            XCTFail("no reply within 1 s: opening the FIFO blocked")
            let w = Darwin.open(fifo, O_WRONLY | O_NONBLOCK)   // frees the blocked reader
            if w >= 0 { Darwin.close(w) }
            return
        }
        let r = Self.decode(frames.lock.withLock { frames.all[0] })
        XCTAssertEqual(r.type, DchFrame.libraryResp)
        XCTAssertTrue(r.json["snippets"] is NSNull)
        XCTAssertEqual(r.json["errors"] as? [String: String], ["snippets": "unreadable"])
        XCTAssertEqual(r.json["quicklinks"] as? NSObject, Self.parsed(Self.quicklinks))
    }

    /// Dotfile setups symlink these files: a symlink is followed.
    func testSymlinkedFileIsFollowed() throws {
        let (o, dir) = lib(snippets: nil)
        let real = tempDir().appendingPathComponent("real.json")
        try Data(Self.snippets.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("snippets.json"), withDestinationURL: real)
        let r = call(o)
        XCTAssertEqual(r.json["snippets"] as? NSObject, Self.parsed(Self.snippets))
        XCTAssertNil(r.json["errors"])
    }

    func testOverSizeFileIsRefused() {
        let big = "[" + String(repeating: "1,", count: DchLibraryOps.fileCap / 2) + "1]"
        let r = call(lib(snippets: big).0)
        XCTAssertEqual(r.type, DchFrame.libraryResp)
        XCTAssertTrue(r.json["snippets"] is NSNull)
        XCTAssertEqual((r.json["errors"] as? [String: String])?["snippets"], "too large (over 3 MB)")
        XCTAssertEqual(r.json["quicklinks"] as? NSObject, Self.parsed(Self.quicklinks))
        let atCap = "[" + String(repeating: " ", count: DchLibraryOps.fileCap - 2) + "]"
        XCTAssertNil(call(lib(snippets: atCap).0).json["errors"], "exactly the cap is served")
    }

    func testMalformedRequestIsAnError() {
        let (o, _) = lib()
        for raw in ["[]", "x", #"{"etag":1}"#, #"{"etag":"a","x":1}"#, #"{"x":1}"#, "null"] {
            let r = call(o, raw: Data(raw.utf8))
            XCTAssertEqual(r.type, DchFrame.error, raw)
            XCTAssertTrue((r.json["message"] as? String ?? "").contains("malformed library request"), raw)
        }
    }

    func testOpsAndFrameBytes() {
        XCTAssertTrue(DchFrame.ops.contains("library"))
        XCTAssertEqual(DchFrame.machineInfo(deviceID: "i", hostname: "h", wakeId: nil)["ops"] as? [String], DchFrame.ops)
        XCTAssertEqual([DchFrame.library, DchFrame.libraryResp], [0x0f, 0x1c])
    }

    /// Through DchConnection.handle: the reply is one frame of type 0x1c via the frame
    /// encoder. The NWConnection is never started.
    func testConnectionRepliesWithLibraryResp() {
        let queue = DispatchQueue(label: "test.dchconn.library")
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { _ in })
        let (o, _) = lib()
        conn.library = o
        let frames = Frames(), replied = expectation(description: "reply")
        conn.sendOverride = { frame in frames.lock.withLock { frames.all.append(frame) }; replied.fulfill() }
        queue.sync { conn.handle(type: DchFrame.library, payload: Data()) }
        wait(for: [replied], timeout: 5)
        let all = frames.lock.withLock { frames.all }
        XCTAssertEqual(all.count, 1)
        let r = Self.decode(all.first ?? Data([0, 0, 0, 0, 0]))
        XCTAssertEqual(r.type, DchFrame.libraryResp)
        XCTAssertEqual(r.json["etag"] as? String, DchLibraryOps.etag(Data(Self.snippets.utf8), Data(Self.quicklinks.utf8)))
        XCTAssertEqual(r.json["snippets"] as? NSObject, Self.parsed(Self.snippets))
        XCTAssertFalse(queue.sync { conn.inFlight }, "the one reply cleared inFlight")
    }
}
