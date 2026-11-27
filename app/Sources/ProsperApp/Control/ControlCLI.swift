import Foundation

/// #1807: `ProsperApp ctl <cmd> [--json '<args>']` talks to the running app over the control socket.
/// Prints the reply JSON; exit 0 on ok, 1 on an error reply or bad usage, 2 when Prosper is not running.
/// It never launches the app.
enum ControlCLI {
    static let usage = "usage: ProsperApp ctl <command> [--json '<args object>']   (ProsperApp ctl describe lists the commands)"
    /// How long the CLI waits for a reply (a handler waits for main). QA n139: past ControlXray.maxTimeout (60 s), so an
    /// awaited read's own deadline answers first.
    static let replyTimeout: TimeInterval = 70
    static let maxReply = 16 << 20

    struct Outcome: Equatable {
        var code: Int32
        var stdout: String?
        var stderr: String?
    }

    /// Handle a `ctl` subcommand and exit; returns (no side effects) otherwise. Called from main.swift before the
    /// single-instance guard, like AgentCLI.
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "ctl" else { return }
        let out = run(Array(args.dropFirst()), socketPath: ControlServer.socketPath,
                      from: ProcessInfo.processInfo.environment["DCH_SESSION"])
        if let s = out.stdout { print(s) }
        if let e = out.stderr { FileHandle.standardError.write(Data((e + "\n").utf8)) }
        exit(out.code)
    }

    /// The request line for `args` (after `ctl`), or the usage error.
    /// #2047: `from` is the client's DCH_SESSION (runIfRequested), sent so the notice names the calling session.
    static func parse(_ args: [String], from: String? = nil) -> Result<Data, ControlError> {
        guard let cmd = args.first, !cmd.hasPrefix("-"), !cmd.isEmpty else { return .failure(ControlError(usage)) }
        var req = ControlRequest(cmd: cmd, args: nil, from: from.flatMap { $0.isEmpty ? nil : $0 })
        let rest = Array(args.dropFirst())
        if !rest.isEmpty {
            guard rest.count == 2, rest[0] == "--json" else { return .failure(ControlError(usage)) }
            // The args sit one level inside the request object, which the server bounds as a whole.
            guard !ControlDepth.exceeds(rest[1].utf8, limit: ControlDepth.limit - 1) else {
                return .failure(ControlError("--json is nested deeper than \(ControlDepth.limit - 1) levels"))
            }
            guard case .object(let o)? = try? JSONDecoder().decode(ControlJSON.self, from: Data(rest[1].utf8)) else {
                return .failure(ControlError("--json must be a JSON object, e.g. --json '{\"name\": \"api\"}'"))
            }
            req.args = o
        }
        guard let data = try? JSONEncoder().encode(req) else { return .failure(ControlError("could not encode the request")) }
        return .success(data + Data("\n".utf8))
    }

    /// Function-level seam for the rows: parse, send, map the reply to an exit code. Blocks; call off main.
    static func run(_ args: [String], socketPath: String, from: String? = nil) -> Outcome {
        let line: Data
        switch parse(args, from: from) {
        case .failure(let e): return Outcome(code: 1, stdout: nil, stderr: e.message)
        case .success(let d): line = d
        }
        guard let fd = ControlServer.connect(socketPath) else {
            return Outcome(code: 2, stdout: nil, stderr: "Prosper is not running (no control socket answers at \(socketPath))")
        }
        defer { Darwin.close(fd) }
        let raw = exchange(fd, line)
        let text = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let reply = try? JSONDecoder().decode(ControlReply.self, from: Data(text.utf8)) else {
            return Outcome(code: 1, stdout: nil, stderr: "no valid reply from Prosper")
        }
        return Outcome(code: reply.ok ? 0 : 1, stdout: text, stderr: nil)
    }

    /// Send `line`, half-close, read the reply until EOF (bounded by size and `replyTimeout`). A failed write still
    /// reads: the server answers a refused or oversized request before it closes.
    static func exchange(_ fd: Int32, _ line: Data) -> Data {
        ControlServer.setTimeout(fd, SO_SNDTIMEO, replyTimeout)
        ControlServer.setTimeout(fd, SO_RCVTIMEO, replyTimeout)
        ControlServer.writeAll(fd, line)
        shutdown(fd, SHUT_WR)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while out.count <= maxReply {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}
