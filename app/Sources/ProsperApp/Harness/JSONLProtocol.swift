import Foundation

/// Newline-delimited JSON framer. The Codex app-server speaks JSON-RPC 2.0 with one
/// complete JSON object per line over stdio; stdout is reserved for protocol frames
/// (logs go to stderr). Feed raw stdout `Data` in, get back complete decoded objects.
/// Tolerant of partial reads: a line split across two `append` calls is buffered until
/// its terminating newline arrives.
struct JSONLineFramer {
    private var buffer = Data()
    private static let newline = UInt8(ascii: "\n")

    /// Append a stdout read and return every complete JSON object it completed.
    /// Non-JSON lines (stray logging on stdout) are skipped rather than throwing.
    mutating func append(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var out: [[String: Any]] = []
        while let nl = buffer.firstIndex(of: Self.newline) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            if let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] {
                out.append(obj)
            }
        }
        return out
    }
}

/// Builds JSON-RPC 2.0 frames and tracks request ids. Not thread-safe on its own;
/// `CodexHarness` confines it to its actor.
struct JSONRPC {
    private var nextID = 1

    /// A client→server request expecting a response. Returns the encoded line
    /// (newline-terminated) and the id to correlate the response.
    mutating func request(method: String, params: [String: Any]) -> (id: Int, line: Data) {
        let id = nextID
        nextID += 1
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return (id, Self.line(obj))
    }

    /// A client→server notification (no response expected).
    static func notification(method: String, params: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// A client→server reply to a server-initiated request (e.g. an approval).
    static func response(id: Any, result: [String: Any]) -> Data {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func line(_ obj: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
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
