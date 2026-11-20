import Foundation
import SwiftUI

// #1723: the Text Viewer Settings section's "Install prosper Command" control, like VS Code's `code`.
// #1732 (QA n57): the command is `prosper`, not `pv` (Homebrew's Pipe Viewer); pv is never installed again.
// /usr/local/bin is in /etc/paths for every user (~/bin is not). Only its button writes anything,
// through one admin prompt; it never replaces or removes a command it did not write.

/// The one privileged step, behind a seam so tests run the command unprivileged against a scratch dir.
protocol PrivilegedShell: Sendable {
    /// Runs `command` with /bin/sh as root; nil when it exits 0, else what it printed.
    func run(_ command: String) async -> String?
}

/// The real conformance: the system's admin prompt via osascript. No test constructs it.
struct AdminPromptShell: PrivilegedShell {
    func run(_ command: String) async -> String? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", PVCommand.appleScript(command)]
            let err = Pipe()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = err
            do { try p.run() } catch { return error.localizedDescription }
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return p.terminationStatus == 0 ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

/// Whether /usr/local/bin/prosper is ours, and the Install / Uninstall actions.
@MainActor
final class PVCommand: ObservableObject {
    enum State: Equatable { case missing, installed, outdated, other }

    /// Under XCTest the real seam is never built: a test sets a fake; with none, nothing is run.
    static var shell: (any PrivilegedShell)? = NSClassFromString("XCTestCase") == nil ? AdminPromptShell() : nil
    /// The line that makes the command ours. Install replaces and Uninstall removes only a file that has it.
    nonisolated static let marker = "# prosper-cli:"
    /// #1723's pv marker: recognised only so Uninstall removes a pv that Prosper installed next to the target.
    nonisolated static let legacyMarker = "# prosper-pv:"

    @Published private(set) var state: State?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    let target: URL
    let bundleID: String

    /// #1732: the script opens the app by bundle id, so it never launches an app at a path the installer chose.
    init(target: URL = URL(fileURLWithPath: "/usr/local/bin/prosper"),
         bundleID: String = Bundle.main.bundleIdentifier ?? "eu.illegible.prosper") {
        self.target = target
        self.bundleID = bundleID
    }

    var script: String { Self.script(bundleID: bundleID) }

    /// Reads only, off main. The Settings page calls it when it appears and after every action.
    func refresh() async {
        let target = target, script = script
        state = await Task.detached { Self.state(of: target, expected: script) }.value
    }

    func install() async {
        guard let shell = Self.shell, !busy else { return }
        busy = true
        error = await shell.run(Self.installCommand(script: script, target: target.path))
        busy = false
        await refresh()
    }

    func uninstall() async {
        guard let shell = Self.shell, !busy else { return }
        busy = true
        error = await shell.run(Self.uninstallCommand(target: target.path))
        busy = false
        await refresh()
    }

    nonisolated static func state(of target: URL, expected: String) -> State {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: target.path) else { return .missing }
        // attributesOfItem does not follow a link, and we never write one: a link is someone else's.
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? Int ?? .max) < 65_536,
              let data = try? Data(contentsOf: target) else { return .other }
        let text = String(decoding: data, as: UTF8.self)
        if text == expected { return .installed }
        return text.contains(marker) ? .outdated : .other
    }

    /// POSIX sh (dash-safe): `prosper FILE...` opens each file, `prosper -` saves what is piped in to a .txt first.
    nonisolated static func script(bundleID: String) -> String {
        """
        #!/bin/sh
        \(marker) installed by Prosper (Settings > Text Viewer). Prosper replaces or removes only a prosper command with this line.
        app=\(quote(bundleID))
        if [ $# -eq 0 ]; then
          echo 'usage: prosper FILE...  open files in the Prosper Text Viewer' >&2
          echo '       prosper -        open what is piped in' >&2
          exit 2
        fi
        rc=0
        for f in "$@"; do
          if [ "$f" = - ]; then
            d=$(mktemp -d "${TMPDIR:-/tmp}/prosper.XXXXXX") || exit 1
            f=$d/stdin.txt
            cat > "$f" || exit 1
          fi
          case $f in /*) ;; *) f=$PWD/$f ;; esac
          open -b "$app" "$f" || rc=1
        done
        exit $rc

        """
    }

    /// Refuses when the target is a link or a file without our marker, so another command is never replaced.
    /// #1732: root reads no file a user can write: the script is inside the command. It is written into a
    /// fresh root-owned 0700 dir in the target's dir (entered and checked with -O, so a dir swapped in by name
    /// is refused and nobody else can place a link inside it), then renamed over the target: rename replaces
    /// a link swapped in after the check instead of following it, and -h keeps a link to a dir from being entered.
    nonisolated static func installCommand(script: String, target: String) -> String {
        let t = quote(target), parent = (target as NSString).deletingLastPathComponent
        return "if [ -L \(t) ] || { [ -e \(t) ] && ! /usr/bin/grep -qF \(quote(marker)) \(t); }; then "
            + "echo \(quote("Another command is at \(target). Prosper did not replace it.")) >&2; exit 3; fi; "
            + "/bin/mkdir -p \(quote(parent)) && d=$(/usr/bin/mktemp -d \(quote(parent + "/.prosper.XXXXXX"))) && cd \"$d\" && [ -O . ] && "
            + "{ printf '%s' \(quote(script)) > new && /bin/chmod 755 new && /bin/mv -fh new \(t); "
            + "r=$?; /bin/rm -f new; cd / && /bin/rmdir \"$d\"; exit $r; }"
    }

    /// Removes only a regular file with our marker; anything else is left alone. The same goes for
    /// #1723's pv next to the target, by its old marker.
    nonisolated static func uninstallCommand(target: String) -> String {
        let legacy = ((target as NSString).deletingLastPathComponent as NSString).appendingPathComponent("pv")
        return [(target, marker), (legacy, legacyMarker)].map { path, mark in
            let t = quote(path)
            return "if [ -f \(t) ] && [ ! -L \(t) ] && /usr/bin/grep -qF \(quote(mark)) \(t); then /bin/rm -f \(t); fi"
        }.joined(separator: "; ")
    }

    nonisolated static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    nonisolated static func appleScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }
}

/// The "Shell Command" section of the Text Viewer Settings page.
struct PVCommandSection: View {
    @StateObject private var model: PVCommand

    init(model: @autoclosure @escaping () -> PVCommand = PVCommand()) {
        _model = StateObject(wrappedValue: model())
    }

    static let explanation = "Type prosper FILE in a terminal to open files in the Prosper Text Viewer, or pipe text into prosper - to view it. Install puts a small script at /usr/local/bin/prosper and macOS asks for an administrator password. Uninstall removes only that script."

    static func status(_ state: PVCommand.State?, target: String) -> String {
        switch state {
        case .installed: "Installed at \(target)"
        case .outdated: "An older prosper command is installed. Install again to update it."
        case .other: "Another command is at \(target). Prosper will not replace it."
        case .missing: "Not installed"
        case nil: ""
        }
    }

    var body: some View {
        NeonSection("Shell Command", footer: Self.explanation) {
            NeonRow("prosper command", subtitle: model.error.map { "Not changed: \($0)" }) {
                Text(Self.status(model.state, target: model.target.path))
                    .font(Neon.font(.caption))
                    .foregroundStyle(model.state == .installed ? Neon.blue : Neon.textSecondary)
                    .fixedSize()
            }
            NeonDivider()
            HStack {
                if model.state == .installed {
                    Button("Uninstall prosper Command") { Task { await model.uninstall() } }
                        .buttonStyle(.neon).fixedSize().disabled(model.busy)
                } else {
                    Button("Install prosper Command") { Task { await model.install() } }
                        .buttonStyle(.neon).fixedSize().disabled(model.busy || model.state == .other || model.state == nil)
                }
                Spacer(minLength: 0)
            }
        }
        .task { await model.refresh() }
    }
}
