import Foundation
import os.log

/// Newline-delimited JSON framer. The Codex app-server speaks JSON-RPC 2.0 with one
/// complete JSON object per line over stdio; stdout is reserved for protocol frames
/// (logs go to stderr). Feed raw stdout `Data` in, get back complete decoded objects.
/// Tolerant of partial reads: a line split across two `append` calls is buffered until
/// its terminating newline arrives.
struct JSONLineFramer {
    /// Longest line kept: 2× plugin-host.js's `MAX_FRAME_BYTES` (8 MB). Codex frames are
    /// chat-sized; the big ones (a command's `aggregatedOutput`, a file change's diff) are
    /// already truncated by codex well below this. A longer line is a runaway, and bounding
    /// memory matters more than delivering it (a dropped response then times out).
    static let maxLineBytes = 16 << 20
    static let log = Logger(subsystem: "com.prosper.app", category: "JSONL")

    private var buffer = Data()
    /// Discarding an over-cap line until its newline arrives.
    private var skipping = false
    private static let newline = UInt8(ascii: "\n")

    /// Append a stdout read and return every complete JSON object it completed.
    /// Lines that aren't a JSON object (stray logging on stdout) or exceed `maxLineBytes`
    /// are logged and skipped rather than throwing.
    mutating func append(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var out: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: Self.newline) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if skipping { skipping = false; continue }   // the tail of a dropped line
            guard !lineData.isEmpty else { continue }
            guard lineData.count <= Self.maxLineBytes else { Self.dropOversize(); continue }
            if let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] {
                out.append(obj)
            } else {
                Self.log.error("dropped a stdout line that is not a JSON object: \(Self.preview(lineData), privacy: .public)")
            }
        }
        if buffer.count > Self.maxLineBytes {
            if !skipping { Self.dropOversize() }
            skipping = true
            buffer.removeAll()
        }
        return out
    }

    private static func dropOversize() {
        log.error("dropped a stdout line over \(maxLineBytes) bytes")
    }

    /// The first 256 bytes of a line for a log message, with its full length if cut.
    static func preview(_ data: Data) -> String {
        let head = String(decoding: data.prefix(256), as: UTF8.self)
        return data.count > 256 ? "\(head)… (\(data.count) bytes)" : head
    }
}

/// Builds JSON-RPC 2.0 frames and tracks request ids. Not thread-safe on its own;
/// `CodexHarness` confines it to its actor.
struct JSONRPC {
    private var nextID = 1

    /// A client→server request expecting a response. Returns the encoded line
    /// (newline-terminated) and the id to correlate the response.
    mutating func request(method: String, params: [String: Any]) throws -> (id: Int, line: Data) {
        let id = nextID
        nextID += 1
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return (id, try Self.line(obj))
    }

    /// A client→server notification (no response expected).
    static func notification(method: String, params: [String: Any]) throws -> Data {
        try line(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// A client→server reply to a server-initiated request (e.g. an approval).
    static func response(id: Any, result: [String: Any]) throws -> Data {
        try line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// A client→server error reply to a server-initiated request we can't serve
    /// (`JSONRPCError {id, error: {code, message}}`; -32601 = method not found).
    static func errorResponse(id: Any, code: Int, message: String) throws -> Data {
        try line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// Throws `HarnessError.protocolError` for a value JSON can't carry (NaN, infinity, a
    /// non-JSON object): NSJSONSerialization raises an uncatchable ObjC exception on those.
    static func line(_ obj: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(obj) else {
            throw HarnessError.protocolError("cannot encode JSON-RPC \((obj["method"] as? String) ?? "reply"): params are not valid JSON")
        }
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(Self.newlineByte)
        return data
    }

    private static let newlineByte = Data([UInt8(ascii: "\n")])
}

/// Classifies a decoded JSON-RPC object.
enum JSONRPCFrame {
    case response(id: Int, result: [String: Any]?, error: [String: Any]?)
    case serverRequest(id: Any, method: String, params: [String: Any])
    case notification(method: String, params: [String: Any])

    init?(_ obj: [String: Any]) {
        let method = obj["method"] as? String
        let hasID = obj["id"] != nil
        if let method, hasID, let id = obj["id"] {
            // Server→client request (needs a reply): has both id and method.
            self = .serverRequest(id: id, method: method, params: (obj["params"] as? [String: Any]) ?? [:])
        } else if let method {
            self = .notification(method: method, params: (obj["params"] as? [String: Any]) ?? [:])
        } else if hasID {
            // Response to one of our requests. An id we can't read as Int can't
            // correlate to anything — treat the frame as undecodable rather than
            // inventing a sentinel id.
            guard let id = (obj["id"] as? Int) ?? (obj["id"] as? NSNumber)?.intValue else { return nil }
            self = .response(id: id, result: obj["result"] as? [String: Any], error: obj["error"] as? [String: Any])
        } else {
            return nil
        }
    }
}
