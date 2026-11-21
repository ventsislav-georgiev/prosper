import Foundation

/// #1807: a JSON value that crosses threads (Sendable), for control requests, replies and arg schemas.
indirect enum ControlJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ControlJSON])
    case object([String: ControlJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([ControlJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: ControlJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// The JSON-schema type name this value matches.
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

/// A wire request: one line `{"cmd": "...", "args": {...}}`.
struct ControlRequest: Codable, Equatable {
    var cmd: String
    var args: [String: ControlJSON]?
}

/// A wire reply: `{"ok": true, "result": ...}` or `{"ok": false, "error": "..."}`.
struct ControlReply: Codable, Equatable {
    var ok: Bool
    var result: ControlJSON?
    var error: String?

    static func failure(_ message: String) -> ControlReply { ControlReply(ok: false, result: nil, error: message) }

    /// One JSON line, keys sorted so output is stable.
    var line: Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return ((try? e.encode(self)) ?? Data(#"{"error":"encode failed","ok":false}"#.utf8)) + Data("\n".utf8)
    }
}

struct ControlError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One argument of a command: its JSON type, whether it must be present, the allowed values (strings), a one-liner.
struct ControlArg: Sendable, Equatable {
    var type: String
    var required = false
    var allowed: [String]? = nil
    var summary = ""
}

/// A command the control channel serves. `run` is called on main with arguments already checked against `args`.
struct ControlCommand: Sendable {
    let name: String
    let summary: String
    let args: [String: ControlArg]
    /// True when the command changes Prosper's state: refused while the Settings switch is off. Build these with
    /// `ControlCommand.change` (ControlNotice.swift), which adds the notice, the undo and the log line.
    let mutates: Bool
    let run: @MainActor @Sendable (_ registry: ControlRegistry, _ args: [String: ControlJSON]) throws -> ControlJSON
    /// #1834: a command that awaits its answer (a dch read): run on main in place of `run`; nil for the rest.
    var runAsync: (@MainActor @Sendable (_ registry: ControlRegistry, _ args: [String: ControlJSON]) async throws -> ControlJSON)? = nil

    /// JSON-schema-like description: {"type":"object","properties":{...},"required":[...]}.
    var argsSchema: ControlJSON {
        var props: [String: ControlJSON] = [:]
        for (k, a) in args {
            var p: [String: ControlJSON] = ["type": .string(a.type)]
            if let allowed = a.allowed { p["enum"] = .array(allowed.map { .string($0) }) }
            if !a.summary.isEmpty { p["description"] = .string(a.summary) }
            props[k] = .object(p)
        }
        let required = args.filter(\.value.required).keys.sorted().map { ControlJSON.string($0) }
        return .object(["type": .string("object"), "properties": .object(props), "required": .array(required)])
    }

    /// Unknown, missing, mistyped or out-of-enum arguments are refused before `run` sees them.
    func validate(_ given: [String: ControlJSON]) throws {
        for key in given.keys.sorted() where args[key] == nil { throw ControlError("unknown argument '\(key)' for \(name)") }
        for (key, a) in args.sorted(by: { $0.key < $1.key }) {
            guard let v = given[key] else {
                if a.required { throw ControlError("missing argument '\(key)' for \(name)") }
                continue
            }
            guard v.typeName == a.type else { throw ControlError("argument '\(key)' must be \(a.type), got \(v.typeName)") }
            if let allowed = a.allowed, case .string(let s) = v, !allowed.contains(s) {
                throw ControlError("argument '\(key)' must be one of \(allowed.joined(separator: ", "))")
            }
        }
    }
}

/// #1807: every command the control channel knows. `describe` returns the whole list, so an agent learns everything
/// from one call. Later phases add their commands with one `register` line each in `standard()`.
struct ControlRegistry: Sendable {
    private(set) var commands: [String: ControlCommand] = [:]
    /// #1808: where mutating commands log their changes and undos; rows swap in their own.
    var changes = ControlChanges.shared

    mutating func register(_ c: ControlCommand) { commands[c.name] = c }

    /// The registry the app serves.
    static func standard() -> ControlRegistry {
        var r = ControlRegistry()
        r.register(ControlCommand(name: "describe", summary: "List every command with its summary, arguments and whether it changes state.",
                                  args: [:], mutates: false) { reg, _ in reg.describe })
        r.register(ControlCommand(name: "ping", summary: "Check that Prosper is running and answering.",
                                  args: [:], mutates: false) { _, _ in .string("pong") })
        r.register(ControlCommand(name: "version", summary: "Prosper's version and build number.",
                                  args: [:], mutates: false) { _, _ in
            .object(["version": .string(AppInfo.shortVersion), "build": AppInfo.buildNumber.map { .string($0) } ?? .null])
        })
        r.register(ControlCommand(name: "log", summary: "The last changes agents made to Prosper, oldest first, with whether each was undone.",
                                  args: [:], mutates: false) { reg, _ in reg.changes.logJSON })
        ControlRegistry.registerActions(&r)
        ControlRegistry.registerSettings(&r)
        ControlRegistry.registerExtensions(&r)
        ControlRegistry.registerSessions(&r)
        ControlRegistry.registerXray(&r)
        ControlRegistry.registerSessionsTalk(&r)
        ControlRegistry.registerSessionsEdit(&r)
        ControlRegistry.registerLayouts(&r)
        ControlRegistry.registerCCPool(&r)
        return r
    }

    /// {"commands": [{name, summary, mutates, args}, ...]} sorted by name.
    var describe: ControlJSON {
        .object(["commands": .array(commands.keys.sorted().compactMap { commands[$0] }.map { c -> ControlJSON in
            .object(["name": .string(c.name), "summary": .string(c.summary), "mutates": .bool(c.mutates), "args": c.argsSchema])
        })])
    }

    /// Parse one request line, check it, run its command on main. Never throws: every failure is an error reply.
    func reply(to line: Data) async -> ControlReply {
        guard let req = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
            return .failure("bad request: expected one JSON line {\"cmd\": \"...\", \"args\": {...}}")
        }
        guard let cmd = commands[req.cmd] else { return .failure("unknown command: \(req.cmd) (run describe for the list)") }
        let args = req.args ?? [:]
        do {
            try cmd.validate(args)
            let registry = self
            let result = try await Self.run(cmd, registry, args)
            return ControlReply(ok: true, result: result, error: nil)
        } catch let e as ControlError {
            return .failure(e.message)
        } catch {
            return .failure(String(describing: error))
        }
    }

    /// Checked on main with the run itself, so a flip of the switch cannot land between check and change.
    @MainActor
    private static func run(_ cmd: ControlCommand, _ registry: ControlRegistry, _ args: [String: ControlJSON]) async throws -> ControlJSON {
        if cmd.mutates, !Preferences.agentControlEnabled { throw ControlError(ControlChanges.offError) }
        if let a = cmd.runAsync { return try await a(registry, args) }
        return try cmd.run(registry, args)
    }
}
