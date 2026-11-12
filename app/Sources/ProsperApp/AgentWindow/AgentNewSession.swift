import AppKit
import SwiftUI

// #847: New session from the Agent Sessions window: the form in the detail pane (folder, name, command)
// and the quick shell. One spawn path with the island's New session (AgentIslandController.spawn).

/// The form's state. `name` "" with `nameEdited` false is the folder's automatic free name.
struct AgentNewSessionForm: Equatable {
    /// As typed; may be "~/x".
    var folder: String
    var name = ""
    var nameEdited = false
    /// As typed; "" runs the login shell.
    var command: String
    /// Set while the runner works.
    var starting: AgentSessionKey?
    /// QA #713 INFO-4: the window's number for this form's spawn; only that spawn's answer touches the form.
    var request = 0
    /// The status slot's failure or busy text.
    var status: String?
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
    static func autoName(folder: String, taken: Set<String>, dir: String) -> String {
        AgentIsland.freeName(String(AgentIsland.sessionName(folder: folder).prefix(max(1, nameLimit(dir: dir) - 4))), taken: taken)
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
        if t.utf8.count > limit { return "\(limit) characters at most" }
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
    static func argv(_ command: String, shell: String?) -> [String] {
        let words = AgentIsland.shellWords(command)
        return words.isEmpty ? [loginShell(shell), "-l"] : words
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
}

/// The form, in place of the detail pane's content while `model.newSession` is set.
struct AgentNewSessionView: View {
    @ObservedObject var model: AgentWindowModel
    let form: AgentNewSessionForm
    @FocusState private var focus: Field?

    enum Field: Hashable { case folder, name, command }

    var body: some View {
        let errors = model.newSessionErrors, starting = form.starting != nil
        VStack(alignment: .leading, spacing: sz(6)) {
            Text("New session").font(Neon.font(13, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .padding(.bottom, sz(6))
            field("Folder", error: errors.folder) {
                HStack(spacing: sz(6)) {
                    TextField("~", text: Binding(get: { form.folder }, set: { model.setNewSessionFolder($0) }))
                        .focused($focus, equals: .folder)
                    Menu {
                        ForEach(model.newSessionRecents, id: \.self) { f in
                            let shown = AgentNewSession.abbreviate(f, home: model.home)
                            Button(shown) { model.setNewSessionFolder(shown) }
                        }
                    } label: {
                        Image(systemName: "chevron.down").font(Neon.font(10, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: sz(18), height: sz(18))
                    .disabled(model.newSessionRecents.isEmpty)
                    .help("Recent folders")
                    AgentPillButton(title: "Choose…", icon: "folder", tint: Neon.blue) { model.chooseNewSessionFolder() }
                }
            }
            field("Name", error: errors.name) {
                TextField(model.newSessionAutoName, text: Binding(get: { form.nameEdited ? form.name : model.newSessionAutoName },
                                                                 set: { model.setNewSessionName($0) }))
                    .focused($focus, equals: .name)
            }
            field("Command", error: nil) {
                VStack(alignment: .leading, spacing: sz(4)) {
                    TextField("Empty: your login shell", text: Binding(get: { form.command }, set: { model.setNewSessionCommand($0) }))
                        .focused($focus, equals: .command)
                    let runs = model.newSessionRuns
                    Text(verbatim: "Runs: " + runs).font(Neon.font(10.5, design: .monospaced)).foregroundStyle(Neon.textSecondary)
                        .lineLimit(1).truncationMode(.tail).help(runs)
                }
            }
            Divider().padding(.vertical, sz(4))
            HStack(spacing: sz(8)) {
                AgentPillButton(title: "New shell", icon: "apple.terminal", tint: Neon.terminal,
                                enabled: !starting && model.store?.resumeGate.isOK == true) { model.startShell() }
                Spacer(minLength: 0)
                AgentPillButton(title: "Cancel", icon: "xmark", tint: Neon.textSecondary) { model.cancelNewSession() }
                    .keyboardShortcut(.cancelAction)
                // One width for both labels: nothing moves when it switches.
                ZStack {
                    AgentPillButton(title: "Starting…", icon: "play.fill", tint: Neon.blue) {}.hidden()
                    AgentPillButton(title: starting ? "Starting…" : "Start", icon: "play.fill", tint: Neon.blue,
                                    enabled: model.canStartNewSession) { model.startNewSession() }
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
            icon("apple.terminal", help: why.map { "Controls \($0)" } ?? "New shell (⇧⌘N)", label: "New shell", on: why == nil) {
                model.startShell()
            }
            icon("plus", help: why.map { "Controls \($0)" } ?? "New session… (⌘N)", label: "New session", on: why == nil) {
                model.openNewSession()
            }
        }
        .fixedSize()
    }

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
