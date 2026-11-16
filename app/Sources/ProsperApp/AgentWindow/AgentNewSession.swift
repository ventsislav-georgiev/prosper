import AppKit
import Combine
import SwiftUI

// #847: New session from the Agent Sessions window: the form in the detail pane (folder, name, command)
// and the quick shell. One spawn path with the island's New session (AgentIslandController.spawn).

/// The form's state. `name` "" with `nameEdited` false is the folder's automatic free name.
struct AgentNewSessionForm: Equatable {
    /// As typed; may be "~/x".
    var folder: String
    var name = ""
    var nameEdited = false
    /// The Name field's text: what was typed. The automatic name is the placeholder only; as text it came back when the field was emptied.
    var nameFieldText: String { name }
    /// As typed; "" runs the login shell.
    var command: String
    /// Set while the runner works.
    var starting: AgentSessionKey?
    /// QA #713 INFO-4: the window's number for this form's spawn; only that spawn's answer touches the form.
    var request = 0
    /// The status slot's failure or busy text.
    var status: String?
    /// #1323: the Mac it starts on: nil this one, else a host from the remote list (raw, as argv takes it).
    var host: String?
    /// #847 P1d: also start main + suffix (off on every open), the first message, and whether its editor is open.
    var sidekick = false
    var prompt = ""
    var promptShown = false
    /// Set while the second spawn (the sidekick's) runs; `starting` stays the main's.
    var startingSidekick: AgentSessionKey?
}

/// The form's rules. Pure.
enum AgentNewSession {
    static let nameMax = 64
    static let defaultShell = "/bin/zsh"

    /// "~" and "~/…" against `home`; anything else as typed (trimmed).
    static func expand(_ folder: String, home: String) -> String {
        let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if f == "~" { return home }
        return f.hasPrefix("~/") ? home + f.dropFirst(1) : f
    }

    /// `path` with `home` as "~", for the folder field.
    static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// QA #713 INFO-3: the longest name dch keeps in socket dir `dir`, in UTF-8 bytes, at most `nameMax`. A longer
    /// one is listed as "<prefix>-<6hex>" (canon_name, dch 1.50.1): sun_path's 104 less "<dir>/" and ".sock\0".
    static func nameLimit(dir: String) -> Int { max(1, min(nameMax, 104 - dir.utf8.count - 7)) }

    /// The folder's free name, compared case-folded (freeName). Cut to leave room for a "-N" under `nameLimit`
    /// (sessionName is ASCII: characters are bytes).
    /// #847 D3.4: with `suffix` (the sidekick box on), the first free name whose sidekick is free too: a taken
    /// "<t><suffix>" (case-folded) takes "<t>", and the stem leaves room for the suffix as well.
    static func autoName(folder: String, taken: Set<String>, dir: String, suffix: String? = nil) -> String {
        guard let suffix, !suffix.isEmpty else { return freeStem(AgentIsland.sessionName(folder: folder), taken: taken, dir: dir) }
        let s = suffix.lowercased()
        let mains = taken.compactMap { t in t.lowercased().hasSuffix(s) ? String(t.lowercased().dropLast(s.count)) : nil }
        return freeStem(AgentIsland.sessionName(folder: folder), taken: taken.union(mains), dir: dir, room: suffix.utf8.count)
    }

    /// #847 S9: the sidekick's name: the main's (typed or automatic) and the Settings suffix.
    static func sidekickName(_ main: String, suffix: String) -> String { main + suffix }

    /// #847 D4.3: "$name" replaced by the main session's name where the next character is not [A-Za-z0-9_]
    /// ("$names" stays). The only placeholder.
    static func render(_ template: String, name: String) -> String {
        template.replacingOccurrences(of: "\\$name(?![A-Za-z0-9_])", with: NSRegularExpression.escapedTemplate(for: name),
                                      options: .regularExpression)
    }

    /// #847 D4.5: the sidekick's first message when Settings holds none.
    static let sidekickPromptDefault = "You are the QA sidekick of the Claude Code session $name, in this same folder. "
        + "Get all your context from $name: read its screen and scrollback with `dch --read $name --recent 500`, and "
        + "look again as it works. QA and review their work. Talk to me only through them: send each finding or "
        + "question with `dch --say $name -- \"QA: <message>\"`, never to me directly."

    /// QA #736 INFO-3: the quick shell starts in every folder: a folder name dch refuses (id-shaped, too long for
    /// `dir`) gives way to the stem "shell".
    static func shellName(folder: String, taken: Set<String>, dir: String) -> String {
        let n = autoName(folder: folder, taken: taken, dir: dir)
        return nameError(n, taken: taken, dir: dir) == nil ? n : freeStem("shell", taken: taken, dir: dir)
    }

    private static func freeStem(_ stem: String, taken: Set<String>, dir: String, room: Int = 0) -> String {
        AgentIsland.freeName(String(stem.prefix(max(1, nameLimit(dir: dir) - 4 - room))), taken: taken)
    }

    /// nil: the name can be spawned into socket dir `dir`. Empty (after trim) is the automatic name, so no error.
    static func nameError(_ n: String, taken: Set<String>, dir: String) -> String? {
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        // dch sends "host:name" to a tailnet host; '/' and the rest break the socket name.
        guard t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            return "Use ASCII letters, digits, . _ and - only"
        }
        if t.hasPrefix("-") || t.hasPrefix(".") { return "Can't start with - or ." }
        let limit = nameLimit(dir: dir)
        if t.utf8.count > limit { return limit == 1 ? "1 character at most" : "\(limit) characters at most" }
        if idShaped(t) { return "Looks like a dch session id" }   // dch 1.46 refuses it (refuse_id_name)
        // The clash is case-folded: name the session as it is spelled.
        return taken.filter { $0.lowercased() == t.lowercased() }.min().map { "\($0) is taken" }
    }

    /// dch's xr_id_shaped: "m" + 16 hex digits, any case.
    static func idShaped(_ t: String) -> Bool {
        t.count == 17 && (t.first == "m" || t.first == "M") && t.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// nil: an existing folder. `f` is the expanded path.
    static func folderError(_ f: String, exists: (String) -> Bool) -> String? {
        if f.isEmpty { return "Choose a folder" }
        return f.hasPrefix("/") && exists(f) ? nil : "No such folder"
    }

    /// The command's argv as it runs; empty: the login shell (OQ-2: like Terminal.app).
    /// #1228: with the Default model (AgentIsland.withModel); Start, the "Runs:" line and the ccpool hint all read
    /// this one argv, so what is shown is what starts. The typed text (saved on success) never gets the flag.
    static func argv(_ command: String, shell: String?, model: String = Preferences.agentIslandDefaultModel) -> [String] {
        let words = AgentIsland.shellWords(command)
        return words.isEmpty ? [loginShell(shell), "-l"] : AgentIsland.withModel(words, model: model)
    }

    static let viaPoolHint = "via ccpool"

    /// spec 3.6: "via ccpool" beside the command when the pool's routing applies to `argv` (the form's argv, as
    /// Start spawns it). Decided by the routing value the spawn env applies, so the hint and the env cannot
    /// disagree. nil routing (the ccpool runtime not built): no hint.
    static func poolHint(_ argv: [String], routing: CCPool.Routing?) -> String? {
        guard let routing, !routing.delta(argv).isEmpty else { return nil }
        return viaPoolHint
    }

    /// $SHELL when absolute, else /bin/zsh (LoginPath.read's rule).
    static func loginShell(_ env: String?) -> String {
        env.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? defaultShell
    }

    /// The folder menu: the last folder first, then the agent records' folders, deduped, existing, at most 8.
    static func recents(last: String?, history: [DchHistoryRecord], exists: (String) -> Bool) -> [String] {
        let first = last.map { exists($0) ? [$0] : [] } ?? []
        var seen = Set<String>()
        return Array((first + AgentIsland.recentFolders(history, exists: exists)).filter { seen.insert($0).inserted }
            .prefix(AgentIsland.recentFoldersMax))
    }

    // MARK: #1323 on another Mac

    /// dch #114 (de271c3, first in v1.41.0): `--spawn host:name` with `--cwd` on the host.
    static let remoteMinimum = [1, 41, 0]
    static let thisMac = "This Mac"

    /// `dch --host <host> --spawn <name> --cwd <path> -- <command>`: host and path raw (argv); the command named as the local
    /// one. The --host form (remote Resume's): a local session or record named "host:name" would keep `--spawn host:name` here.
    static func remoteArgs(host: String, name: String, cwd: String, command: [String]) -> [String] {
        ["--host", host, "--spawn", name, "--cwd", cwd, "--"] + AgentIsland.naming(command, name: name)
    }

    /// v1 has no folder browser on the host: a typed absolute path, which dch checks there ("no such directory").
    static func remoteFolderError(_ f: String) -> String? {
        if f.isEmpty { return "Type a folder on that Mac" }
        guard f.hasPrefix("/") else { return "Type a full path starting with /: a relative path has no folder to start from" }
        return f.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } ? "Use a path without control characters" : nil
    }

    /// `host`'s folders: its live sessions' cwds, then its History records' newest first; absolute, deduped, at most 8; one OutsideText.shown would change (bidi, zero-width) is dropped, not offered raw.
    static func remoteRecents(host: String, sessions: [AgentSidebar.Remote], history: [AgentSidebar.RemoteRecord]) -> [String] {
        let live = sessions.filter { $0.host == host }.compactMap(\.cwd)
        let ended = history.filter { $0.host == host }.sorted { $0.record.lastSeen > $1.record.lastSeen }.map(\.record.cwd)
        var seen = Set<String>()
        return Array((live + ended).filter { remoteFolderError($0) == nil && OutsideText.shown($0) == $0 && seen.insert($0).inserted }
            .prefix(AgentIsland.recentFoldersMax))
    }

    /// dch's answer to a remote --spawn as the form's line; nil: it started. The host is shown through OutsideText.
    static func remoteFailure(_ r: DchActionResult, host: String, name: String) -> String? {
        guard r.status != 0 else { return nil }
        let h = OutsideText.shown(host), all = r.text.joined(separator: "\n")
        if r.stopped { return "No answer from \(h)" }
        if all.contains("no such directory") { return "No such folder on \(h)" }
        if all.contains("--allow-create") { return "\(h) does not allow new sessions: run dch serve --allow-create there" }
        if r.status == 7 || all.contains(": unreachable") { return "Can't reach \(h)" }
        return AgentIsland.spawnText(r, name: name).map { OutsideText.shown($0) }
    }
}

/// #1205: the "via ccpool" hint's source while the form is shown. The routing toggle, the proxy's state and the
/// pool's accounts all change through the ccpool pane model, which publishes each change on main (the toggle's
/// setter; every start, stop and restart ends in its @Published job count; store changes hop to main first). This
/// forwards those publishes so the form redraws the hint; the subscription goes with this object.
/// Isolation: @MainActor.
@MainActor
final class AgentNewSessionPoolWatch: ObservableObject {
    private(set) var routing: CCPool.Routing?
    private var changes: AnyCancellable?
    /// #1219 (R1205-2): held only while there is no runtime yet; the first one built attaches and this goes.
    private var arrival: AnyCancellable?

    init(_ runtime: CCPoolRuntime?) {
        if let runtime { attach(runtime); return }
        // The sink runs on main: CCPoolRuntime.push is @MainActor and sends there.
        arrival = CCPoolRuntime.built.sink { [weak self] made in self?.attach(made) }
    }

    private func attach(_ runtime: CCPoolRuntime) {
        guard routing == nil else { return }
        objectWillChange.send()
        routing = runtime.routing
        // The sink runs on main: the pane model is @MainActor and publishes only there.
        changes = runtime.model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        arrival = nil
    }

    /// What the form shows beside "Runs:" for `argv`, read at each redraw.
    func hint(_ argv: [String]) -> String? { AgentNewSession.poolHint(argv, routing: routing) }
}

/// The form, in place of the detail pane's content while `model.newSession` is set.
struct AgentNewSessionView: View {
    @ObservedObject var model: AgentWindowModel
    let form: AgentNewSessionForm
    @FocusState private var focus: Field?
    /// #1205: redraws the hint when the toggle or the proxy changes while the form is open.
    @StateObject private var pool = AgentNewSessionPoolWatch(CCPoolRuntime.shared)

    enum Field: Hashable { case folder, name, command }

    var body: some View {
        let errors = model.newSessionErrors, starting = form.starting != nil
        VStack(alignment: .leading, spacing: sz(6)) {
            Text("New session").font(Neon.font(13, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .padding(.bottom, sz(6))
            // #1323: only when the remote list names a host (and dch can start one there).
            let hosts = model.newSessionHosts
            if !hosts.isEmpty {
                field("On", error: nil) {
                    Picker("On", selection: Binding(get: { form.host }, set: { model.setNewSessionHost($0) })) {
                        Text(verbatim: model.newSessionHostLabel(nil)).tag(String?.none)
                        ForEach(hosts, id: \.self) { h in Text(verbatim: model.newSessionHostLabel(h)).tag(Optional(h)) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel("On")
                }
            }
            field("Folder", error: errors.folder) {
                HStack(spacing: sz(6)) {
                    TextField(form.host == nil ? "~" : "/Users/you/project", text: Binding(get: { form.folder }, set: { model.setNewSessionFolder($0) }))
                        .focused($focus, equals: .folder)
                        .accessibilityLabel("Folder")   // #887 (QA #747 INFO-6): VoiceOver read the placeholder
                    Menu {
                        ForEach(model.newSessionRecents, id: \.self) { f in
                            if form.host == nil {
                                let shown = AgentNewSession.abbreviate(f, home: model.home)
                                Button(shown) { model.setNewSessionFolder(shown) }
                            } else {
                                // #1323: another Mac's path: shown through OutsideText, set raw
                                Button(OutsideText.shown(f)) { model.setNewSessionFolder(f) }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down").font(Neon.font(10, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: sz(18), height: sz(18))
                    .disabled(model.newSessionRecents.isEmpty)
                    .help("Recent folders")
                    .accessibilityLabel("Recent folders")
                    if form.host == nil {   // #1323: no folder browser on another Mac in v1
                        AgentPillButton(title: "Choose\u{2026}", icon: "folder", tint: Neon.blue) { model.chooseNewSessionFolder() }
                    }
                }
            }
            field("Name", error: errors.name) {
                TextField(model.newSessionAutoName, text: Binding(get: { form.nameFieldText },
                                                                 set: { model.setNewSessionName($0) }))
                    .focused($focus, equals: .name)
                    .accessibilityLabel("Name")
            }
            field("Command", error: nil) {
                VStack(alignment: .leading, spacing: sz(4)) {
                    TextField("Empty: your login shell", text: Binding(get: { form.command }, set: { model.setNewSessionCommand($0) }))
                        .focused($focus, equals: .command)
                        .accessibilityLabel("Command")
                    let runs = model.newSessionRuns
                    HStack(spacing: sz(6)) {
                        Text(verbatim: "Runs: " + runs).font(Neon.font(10.5, design: .monospaced)).foregroundStyle(Neon.textSecondary)
                            .lineLimit(1).truncationMode(.tail).help(runs)
                        // Re-read on each redraw (a keystroke, the toggle, the proxy); the Start argv, the spawn path's routing.
                        if let hint = pool.hint(AgentNewSession.argv(form.command, shell: model.shell)) {
                            Text(verbatim: hint).font(Neon.font(10.5, weight: .semibold)).foregroundStyle(Neon.blue)
                                .fixedSize()
                        }
                    }
                }
            }
            sidekickRow(errors.sidekick)
            promptRows
            Divider().padding(.vertical, sz(4))
            HStack(spacing: sz(8)) {
                // QA #736 INFO-3: Start's condition; it dims in place. #847 D6.2: also while the box or the prompt holds.
                let shellWhy = model.newSessionShellRefusal
                AgentPillButton(title: "New shell", icon: "apple.terminal", tint: Neon.terminal,
                                enabled: model.canStartNewSession && shellWhy == nil) { model.startShell() }
                    .help(shellWhy ?? "")
                Spacer(minLength: 0)
                AgentPillButton(title: "Cancel", icon: "xmark", tint: Neon.textSecondary) { model.cancelNewSession() }
                    .keyboardShortcut(.cancelAction)
                // One width for both labels: nothing moves when it switches. #847 T29: the visible pill fills the
                // hidden copy's frame, so Start's own frame is the same while "Starting\u{2026}" shows.
                AgentPillButton(title: "Starting…", icon: "play.fill", tint: Neon.blue) {}.hidden()
                    .overlay {
                        AgentPillButton(title: starting ? "Starting\u{2026}" : "Start", icon: "play.fill", tint: Neon.blue,
                                        enabled: model.canStartNewSession, fill: true) { model.startNewSession() }
                            .keyboardShortcut(.return, modifiers: .command)   // #847 D5.2: from any field, the prompt editor too
                    }
            }
            slot(model.newSessionStatus)
        }
        .textFieldStyle(.roundedBorder).font(Neon.font(12))
        .onSubmit { model.startNewSession() }
        .onAppear { focus = .name }
        .onChange(of: model.newSessionFocus) { _, _ in focus = .name }
        .padding(sz(20))
        .frame(minWidth: 0, maxWidth: sz(520), alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// #847 D6.1: why the box and the prompt are dimmed (newSessionClaude false), shown on the Sidekick line.
    static func notClaude(command: String, host: String?) -> String {
        if host != nil { return "A sidekick and a first prompt start on this Mac only" }
        return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "The login shell has no Claude to name, brief or prompt"
            : "Needs a claude command (claude, or a wrapper that runs claude)"
    }

    /// #847 D3, D5.4: the box in a fixed sz(18) row, its line (the sidekick's name, or why it is dimmed) and its slot.
    private func sidekickRow(_ error: String?) -> some View {
        let claude = model.newSessionClaude
        let line = claude ? "Also start " + model.newSessionSidekickName + ", briefed by the sidekick prompt"
            : Self.notClaude(command: form.command, host: form.host)
        return field("Sidekick", error: error) {
            HStack(spacing: sz(6)) {
                Toggle("Sidekick", isOn: Binding(get: { form.sidekick && claude }, set: { model.setNewSessionSidekick($0) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .disabled(!claude)
                Text(verbatim: line).font(Neon.font(11.5)).foregroundStyle(claude ? Neon.textPrimary : Neon.textSecondary)
                    .lineLimit(1).truncationMode(.tail).help(line)
            }
            .frame(height: sz(18))
        }
    }

    /// #847 D5.1-D5.3: the disclosure, and the editor at a fixed sz(96) under it (the one accepted reflow). Return adds
    /// a line, Command-Return is Start. Not a Claude: dimmed, the text kept.
    private var promptRows: some View {
        let claude = model.newSessionClaude
        return HStack(alignment: .top, spacing: sz(8)) {
            Color.clear.frame(width: sz(64), height: 1)
            VStack(alignment: .leading, spacing: sz(6)) {
                Button { model.toggleNewSessionPrompt() } label: {
                    Text(verbatim: form.promptShown ? "\u{25BE} Prompt" : "\u{25B8} Prompt (optional)")
                        .font(Neon.font(11.5)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                        .frame(height: sz(18)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!claude)
                .help(claude ? "A first message for the new session" : Self.notClaude(command: form.command, host: form.host))
                if form.promptShown {
                    AgentComposerField(text: Binding(get: { form.prompt }, set: { model.setNewSessionPrompt($0) }),
                                       onSubmit: { model.startNewSession() }, editable: claude && form.starting == nil,
                                       returnSubmits: false)
                        .frame(height: sz(96))
                        .overlay(RoundedRectangle(cornerRadius: sz(4)).stroke(Neon.textSecondary.opacity(0.4)))
                        .opacity(claude ? 1 : 0.45)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private func field<C: View>(_ label: String, error: String?, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
            Text(label).font(Neon.font(11.5)).foregroundStyle(Neon.textSecondary).frame(width: sz(64), alignment: .leading)
            VStack(alignment: .leading, spacing: sz(2)) {
                content().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).disabled(form.starting != nil)
                slot(error, tint: Neon.magenta)
            }
        }
    }

    /// A one-line slot, there with or without text: nothing reflows when it changes.
    private func slot(_ text: String?, tint: Color = Neon.textSecondary) -> some View {
        Text(verbatim: text ?? "").font(Neon.font(10.5)).foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: sz(16), maxHeight: sz(16), alignment: .leading)
            .help(text ?? "")
    }
}

/// The sidebar title row's two icons: [>_] New shell and [+] New session…. Always there, one size; dimmed with
/// the gate's reason while it refuses.
struct AgentNewSessionButtons: View {
    @ObservedObject var model: AgentWindowModel
    @ObservedObject var store: AgentIslandStore

    var body: some View {
        let why = store.resumeGate.refusal
        HStack(spacing: sz(4)) {
            icon("apple.terminal", help: Self.help("New shell (⇧⌘N)", refusal: why), label: "New shell", on: why == nil) {
                model.startShell()
            }
            icon("plus", help: Self.help("New session… (⌘N)", refusal: why), label: "New session", on: why == nil) {
                model.openNewSession()
            }
        }
        .fixedSize()
    }

    /// The pair's width: two sz(18) slots and the gap between them.
    static var width: CGFloat { 2 * sz(18) + sz(4) }

    /// The tooltip: the shortcut, or why the gate refuses (the button dimmed in its slot).
    static func help(_ ok: String, refusal: String?) -> String { refusal.map { "Controls \($0)" } ?? ok }

    private func icon(_ name: String, help: String, label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .frame(width: sz(18), height: sz(18)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: sz(18), height: sz(18))
        .disabled(!on).opacity(on ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(label)
    }
}
