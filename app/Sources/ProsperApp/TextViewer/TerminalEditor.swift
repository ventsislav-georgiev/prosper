import AppKit
import Combine
import CryptoKit

// #1109 (design #1105 D13, riders R7, R8, R9; OQ-118 Q2, Q3): Edit in a terminal. The editor named by the
// Settings field, else the login shell's VISUAL or EDITOR, runs in a dch session the Text Viewer window shows.
// Its argv is never a string handed to a shell: the editor's words, then the file's path as ONE element.

/// What the plan reads from outside, behind one seam. Under XCTest every part is inert: no login shell, no dch.
struct TerminalEditorIO: Sendable {
    /// One variable of the login shell's env ("" unset, nil when the probe failed): LoginPath.value(of:).
    var probe: @Sendable (String) -> String?
    /// The login shell's PATH (nil when the probe failed): LoginPath.read().
    var loginPath: @Sendable () -> String?
    /// The island's one gate on the control dch.
    var gate: @Sendable () -> DchCommand.Gate
    var isExecutable: @Sendable (String) -> Bool
    /// The spawn's environment before PATH is set.
    var env: @Sendable () -> [String: String]

    static let live = TerminalEditorIO(
        probe: { LoginPath.value(of: $0) },
        loginPath: { LoginPath.read() },
        gate: { DchCommand.gate(DchCommand.controlDch(), masters: [], minimum: AgentIsland.controlMinimum) },
        isExecutable: { path in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
                && FileManager.default.isExecutableFile(atPath: path)
        },
        env: { AgentIsland.spawnEnv(DchCommand.childEnv()) })

    static let inert = TerminalEditorIO(probe: { _ in nil }, loginPath: { nil }, gate: { .refused("no dch under XCTest") },
                                        isExecutable: { _ in false }, env: { [:] })

    static var current: TerminalEditorIO { NSClassFromString("XCTestCase") == nil ? live : inert }
}

enum TerminalEditor {
    static let prefix = "edit-"
    /// dch's MAX_CMD is 256 with the path.
    static let maxWords = 255

    /// Settings › Text Viewer, read when Edit is pressed.
    struct Settings: Equatable {
        var terminal: Bool
        var command: String
        @MainActor static var stored: Settings {
            Settings(terminal: Preferences.textViewerEditWith == Preferences.textViewerEditWithTerminal,
                     command: Preferences.textViewerEditorCommand)
        }
    }

    struct Spawn: Equatable, Sendable {
        /// The gate's dch.
        let dch: String
        let key: AgentSessionKey
        /// The editor's words with argv[0] absolute, then the path.
        let argv: [String]
        let env: [String: String]

        /// `dch -E -n <name> -- <argv…>`: creates the session running the editor, or attaches it.
        func request(cols: Int, rows: Int) -> AgentTerminalSpawn {
            AgentTerminalSpawn(exe: dch, args: DchCommand.spawnArgs(name: key.name, command: argv, attach: false),
                               env: env, cols: cols, rows: rows)
        }
    }

    enum Plan: Equatable, Sendable {
        case spawn(Spawn)
        /// Why the terminal editor does not start; the window says it.
        case refused(String)
    }

    // The refusal texts.
    static let needsDch = "Terminal editor needs dch \(DchCommand.versionString(AgentIsland.controlMinimum))"
    static let controlChars = "This file name has control characters"
    static let notAbsolute = "This file's path is not absolute"
    static let noEditor = "No editor found: type one in Settings \u{203A} Text Viewer"
    static let probeFailed = "Could not read your login shell: type your editor in Settings \u{203A} Text Viewer"
    static let tooManyWords = "The editor command has more than \(maxWords) words"
    static func notFound(_ word: String) -> String {
        "\(word.count > 64 ? String(word.prefix(64)) + "\u{2026}" : word) was not found on your login PATH"
    }

    // MARK: Detection (once per process once it works; a failed probe is not cached)

    enum Detection: Equatable, Sendable {
        case found(command: String, from: String)
        case none
    }

    final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var value: Detection?
    }
    static let shared = Cache()

    /// VISUAL, then EDITOR, from the login shell (OQ-118 Q2: never the interactive one). Off main.
    static func detect(_ probe: (String) -> String?, cache: Cache = shared) -> Detection? {
        if let hit = cache.lock.withLock({ cache.value }) { return hit }
        var found = Detection.none
        for name in ["VISUAL", "EDITOR"] {
            guard let v = probe(name) else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { found = .found(command: t, from: name); break }
        }
        cache.lock.withLock { cache.value = found }
        return found
    }

    static func detectedText(_ d: Detection?) -> String {
        switch d {
        case .found(let command, let from)?: "Detected: \(command) (from $\(from))"
        case .none?: "None found. A login zsh reads .zprofile, not .zshrc: type your editor here."
        case nil: probeFailed
        }
    }

    // MARK: The pieces

    /// "edit-" + the file name as the island sanitizes a folder, cut to 40, + "-" + 16 hex digits (R8) of the
    /// resolved path's SHA-256: the same file always gets the same session.
    static func sessionName(path: String) -> String {
        let hex = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return prefix + String(AgentIsland.sessionName(folder: path).prefix(40)) + "-" + hex
    }

    /// R9: a session this file names (the island never treats one as an agent).
    static func isEditSession(_ name: String) -> Bool {
        guard name.hasPrefix(prefix), name.utf8.count >= prefix.utf8.count + 18 else { return false }
        let tail = name.utf8.suffix(17)
        return tail.first == UInt8(ascii: "-") && tail.dropFirst().allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The set DchCtl.nameOK refuses, without its "/" and dash rules: C0, DEL, C1, the bidi embeddings, overrides,
    /// isolates and marks, and the line and paragraph separators.
    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { c in
            let v = c.value
            return v < 0x20 || (0x7f..<0xa0).contains(v) || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v)
                || [0x200e, 0x200f, 0x061c, 0x2028, 0x2029].contains(v)
        }
    }

    /// argv[0] as an absolute executable: a word with a "/" must be absolute already, a bare one is looked up in
    /// the login PATH's absolute dirs in order.
    static func resolve(_ word: String, path: String, isExecutable: (String) -> Bool) -> String? {
        if word.contains("/") { return word.hasPrefix("/") && isExecutable(word) ? word : nil }
        for dir in path.split(separator: ":") where dir.hasPrefix("/") {
            let candidate = (String(dir) as NSString).appendingPathComponent(word)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// The whole decision, off main: the path's checks first (no probe for a refused file), then the gate, the
    /// command (the setting, else detection), argv[0] on the login PATH, the name and the env.
    static func plan(command setting: String, path: String, io: TerminalEditorIO, cache: Cache = shared) -> Plan {
        // The path is one argv element after the editor's words; absolute, so it never starts with a dash.
        guard path.hasPrefix("/") else { return .refused(notAbsolute) }
        guard !hasControl(path) else { return .refused(controlChars) }
        guard case .ok(let dch) = io.gate() else { return .refused(needsDch) }
        var command = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty {
            switch detect(io.probe, cache: cache) {
            case .found(let c, _)?: command = c
            case .none?: return .refused(noEditor)
            case nil: return .refused(probeFailed)
            }
        }
        let words = AgentIsland.shellWords(command)
        guard let first = words.first, !first.isEmpty else { return .refused(noEditor) }
        guard words.count <= maxWords else { return .refused(tooManyWords) }
        var env = io.env()
        let login = LoginPath.path(login: io.loginPath(), process: env["PATH"] ?? "", home: NSHomeDirectory())
        guard let exe = resolve(first, path: login, isExecutable: io.isExecutable) else { return .refused(notFound(first)) }
        env["PATH"] = login
        let dir = DchCommand.socketDir(env: env)
        env["DCH_SOCKET_DIR"] = dir
        return .spawn(Spawn(dch: dch, key: AgentSessionKey(dir: dir, name: sessionName(path: path)),
                            argv: [exe] + words.dropFirst() + [path], env: env))
    }

    /// OQ-118 Q3: the window closed, so its session ends (`dch -k <name>`, the spawn's dch and dir). Off main.
    static func end(_ s: Spawn) {
        guard NSClassFromString("XCTestCase") == nil, let args = AgentIsland.killArgs(s.key.name) else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = DchCommand.bounded(LoginPath.timeout) { onPid, onExit in
                DchCommand.runCapturingBoth(args: args, env: s.env, path: s.dch, onPid: onPid, onExit: onExit).status
            }
        }
    }
}

/// The window's seams for the terminal editor; tests hand in fakes.
@MainActor
struct TerminalEditorSeams {
    var settings: @MainActor () -> TerminalEditor.Settings
    var io: TerminalEditorIO
    var cache: TerminalEditor.Cache
    var makeController: @MainActor () -> AgentTerminalController
    var end: @MainActor (TerminalEditor.Spawn) -> Void

    static var current: TerminalEditorSeams {
        TerminalEditorSeams(settings: { .stored }, io: .current, cache: TerminalEditor.shared,
                            makeController: { AgentTerminalController() }, end: { TerminalEditor.end($0) })
    }
}

/// One editor session shown in a window: its own controller, attached to the edit session's key.
@MainActor
final class TextViewerTerminalEdit {
    let spawn: TerminalEditor.Spawn
    let controller: AgentTerminalController
    private var watch: AnyCancellable?

    init(_ spawn: TerminalEditor.Spawn, controller: AgentTerminalController, ended: @escaping @MainActor @Sendable () -> Void) {
        self.spawn = spawn
        self.controller = controller
        controller.request = { _, cols, rows in spawn.request(cols: cols, rows: rows) }
        // The controller ends on an exit with the socket gone (dch unlinks it when the editor quits).
        controller.isLive = { _ in true }
        // @Published sends before the value is stored: the window acts on the next main turn.
        watch = controller.$phase.sink { phase in
            if phase == .ended { DispatchQueue.main.async { MainActor.assumeIsolated { ended() } } }
        }
        controller.attach(spawn.key)
    }
}
