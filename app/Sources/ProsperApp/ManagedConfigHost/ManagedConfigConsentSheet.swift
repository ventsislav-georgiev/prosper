import AppKit
import SwiftUI

/// #870 (spec 2.6, errata A9/C11): the native consent sheet behind every managed-config write,
/// Removal and Repair included. Host-owned SwiftUI, never built from Lua. It shows only what the
/// P1 change set carries: the resolved path, the masked diff lines, the backup dir and the plain
/// sentences per hook and statusLine. Apply / Cancel; nothing is remembered.
///
/// Isolation: a `Sendable` final class holding one `@MainActor @Sendable` presenter. `confirm` is
/// nonisolated and hops to the main actor itself, so the core calls it from any thread.
final class ManagedConfigSheetConsent: ManagedConfigConsent {
    /// Returns the request's withdraw: called on main when the caller gives up (#947 B-INFO-2).
    typealias Present = @MainActor @Sendable (ManagedConfigChangeSet, @escaping @MainActor @Sendable (Bool) -> Void) -> @MainActor () -> Void

    let present: Present

    init(present: @escaping Present) { self.present = present }

    /// The app's sheet: one panel at a time, a second request waits for the first answer (an identical one
    /// joins it, #947 B-INFO-9).
    static let live = ManagedConfigSheetConsent { changes, done in ManagedConfigConsentPanel.shared.enqueue(changes, done: done) }

    /// Main-only state of one request: set and read only inside `@MainActor` tasks.
    private final class Pending: @unchecked Sendable {
        var gaveUp = false
        var withdraw: (@MainActor () -> Void)?
    }

    nonisolated func confirm(_ changes: ManagedConfigChangeSet) async -> Bool {
        let present = self.present
        let pending = Pending()
        // #947 (B-INFO-2): the caller's give-up (awaitSync cancels this task) takes the request out of the
        // panel's queue. onCancel runs on the cancelling thread and only hops to main; the withdraw resumes
        // `cont` with false through the panel, or the present task does if the give-up came first.
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                Task { @MainActor in
                    guard !pending.gaveUp else { return cont.resume(returning: false) }
                    pending.withdraw = present(changes) { cont.resume(returning: $0) }
                }
            }
        } onCancel: {
            Task { @MainActor in
                pending.gaveUp = true
                pending.withdraw?()
            }
        }
        // The Lua bridge gives up after 5 minutes and cancels: a late Apply is a Cancel.
        return answer && !Task.isCancelled
    }
}

/// What the sheet shows, all derived from the change set. Isolation: `@MainActor`.
@MainActor
final class ManagedConfigConsentModel: ObservableObject {
    static let liveNote = "Applies to open Claude Code sessions immediately."

    let changes: ManagedConfigChangeSet
    private var done: (@MainActor (Bool) -> Void)?

    init(changes: ManagedConfigChangeSet, done: @escaping @MainActor (Bool) -> Void) {
        self.changes = changes
        self.done = done
    }

    var answered: Bool { done == nil }

    /// Answers once; a second click (or a close after Apply) is ignored.
    func answer(_ ok: Bool) {
        guard let done else { return }
        self.done = nil
        done(ok)
    }

    /// #1235 (B-INFO-6): the manifest's display name as shown: outside data, so every control, format (direction),
    /// separator and other unseen scalar is dropped by the tree's rule for shown outside strings, then each character keeps
    /// at most 2 combining marks (B1235-1), then the 120 cut. nil when none is known, and nil for a title shaped like an
    /// id (R1235-d: id characters with a dot) or equal to this owner's id: the id is then shown alone.
    var displayName: String? {
        let cleaned = OutsideText.shown(changes.displayName ?? "", max: .max)
        let whole = cleaned.trimmingCharacters(in: .whitespaces)
        // id-shaped at any length: isValidID bounds its input at 128, so the title is checked in pieces of 128
        var idShaped = whole.contains("."), rest = Substring(whole)
        while idShaped, !rest.isEmpty {
            idShaped = ManagedConfigPaths.isValidID(String(rest.prefix(128)))
            rest = rest.dropFirst(128)
        }
        if whole == changes.owner || idShaped { return nil }
        let shown = OutsideText.shown(cleaned, max: 120).trimmingCharacters(in: .whitespaces)
        return shown.isEmpty ? nil : shown
    }

    /// The title: the display name, or the id when no name is known (one line, drawn verbatim).
    var title: String { displayName ?? changes.owner }

    /// The id under a display name; nil when the title is the id already.
    var idLine: String? { displayName == nil ? nil : changes.owner }

    /// What the operation does, under the title.
    var lead: String {
        switch changes.action {
        case .apply: return "wants to change your config"
        case .remove: return "Remove this extension's config changes"
        case .repair: return "Repair this extension's config changes"
        }
    }

    /// The consenting button reads the operation's verb. No default: a new action fails the build until it has one.
    var verb: String {
        switch changes.action {
        case .apply: return "Apply"
        case .remove: return "Remove"
        case .repair: return "Repair"
        }
    }

    /// A new file has nothing to back up: no backup line for it.
    func backupLine(_ file: ManagedConfigChangeSet.File) -> String? {
        file.newFile ? nil : "Backup: \(file.backupDirectory)"
    }

    /// The planner's sentences, plus the live note for settings.json whatever the planner said.
    func notes(_ file: ManagedConfigChangeSet.File) -> [String] {
        var out = file.notes
        if file.target == "claude:settings.json", !out.contains(Self.liveNote) { out.append(Self.liveNote) }
        return out
    }

    func status(_ file: ManagedConfigChangeSet.File) -> String? {
        if file.newFile { return "new file" }
        if file.deletesFile { return "the file is removed (Prosper created it)" }
        return nil
    }

    static func text(_ line: ManagedConfigChangeSet.Line) -> String {
        let sign: String
        switch line.sign {
        case .added: sign = "+ "
        case .removed: sign = "- "
        case .context: sign = "  "
        }
        return sign + line.text + (line.noFinalNewline ? "   (no newline at end of file)" : "")
    }

    /// Every string the view renders, in order: what the C11 test greps.
    var renderedStrings: [String] {
        var out = [title] + (idLine.map { [$0] } ?? []) + [lead]
        for f in changes.files {
            out.append(f.path)
            if let s = status(f) { out.append(s) }
            out += f.lines.map(Self.text) + notes(f) + (backupLine(f).map { [$0] } ?? [])
        }
        return out + ["Cancel", verb]
    }
}

/// #1235: the sheet's title line. Outside text, never interpreted (no Markdown, no link): one line, cut in the middle, and
/// clipped to its own bounds (B1235-1), so nothing it draws reaches the id line under it.
struct ManagedConfigConsentTitle: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Neon.font(15, weight: .semibold))
            .foregroundStyle(Neon.textPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
            .clipped()
    }
}

struct ManagedConfigConsentView: View {
    @ObservedObject var model: ManagedConfigConsentModel

    var body: some View {
        VStack(alignment: .leading, spacing: sz(12)) {
            ManagedConfigConsentTitle(text: model.title)
            if let id = model.idLine {
                // N1235-a: the line that says WHO asks is drawn whole: an owner id is at most 128 characters with no
                // space (ManagedConfig.prepare refuses others), so it wraps by character over two lines at every scale;
                // three at most, cut in the middle only past that. Selectable, the whole id as help.
                Text(verbatim: id)
                    .font(Neon.font(11, design: .monospaced))
                    .foregroundStyle(Neon.textSecondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(id)
            }
            Text(verbatim: model.lead)
                .font(Neon.font(12))
                .foregroundStyle(Neon.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Prosper writes only what is shown here, and keeps a backup of each existing file first.")
                .font(Neon.font(12))
                .foregroundStyle(Neon.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(model.changes.files.enumerated()), id: \.offset) { _, file in
                fileCard(file)
            }
            HStack(spacing: sz(10)) {
                Spacer(minLength: 0)
                Button("Cancel") { model.answer(false) }
                    .buttonStyle(.neon)
                    .keyboardShortcut(.cancelAction)
                // r2 (R2-2): no key equivalent. The sheet can take the keyboard from another app,
                // and a Return meant for that app must not consent to a config write.
                Button(model.verb) { model.answer(true) }
                    .buttonStyle(.neon)
            }
        }
        .padding(sz(18))
    }

    private func fileCard(_ file: ManagedConfigChangeSet.File) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            Text(file.path)
                .font(Neon.font(12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Neon.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let status = model.status(file) {
                Text(status).font(Neon.font(11)).foregroundStyle(Neon.blueBright)
            }
            VStack(alignment: .leading, spacing: sz(1)) {
                ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                    Text(ManagedConfigConsentModel.text(line))
                        .font(Neon.font(11, design: .monospaced))
                        .foregroundStyle(color(line.sign))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(model.notes(file), id: \.self) { note in
                Text(note)
                    .font(Neon.font(12))
                    .foregroundStyle(Neon.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let backup = model.backupLine(file) {
                Text(backup)
                    .font(Neon.font(11))
                    .foregroundStyle(Neon.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(sz(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: sz(8), style: .continuous).fill(Neon.card))
        .overlay(RoundedRectangle(cornerRadius: sz(8), style: .continuous).strokeBorder(Neon.stroke, lineWidth: 1))
    }

    private func color(_ sign: ManagedConfigChangeSet.Line.Sign) -> Color {
        switch sign {
        case .added: return Neon.terminal
        case .removed: return Neon.magenta
        case .context: return Neon.textSecondary
        }
    }
}

/// The floating panel that hosts the sheet: one at a time, in request order. A closed panel
/// (the title bar has no close button) can only end by Apply or Cancel.
/// Isolation: `@MainActor`.
@MainActor
final class ManagedConfigConsentPanel {
    /// Puts a model on screen and returns its closer. r2 (T4): the seam that keeps the queue
    /// testable; only `shared` orders a window front.
    typealias Show = @MainActor (ManagedConfigConsentModel) -> @MainActor () -> Void

    static let shared = ManagedConfigConsentPanel { model in
        let panel = ManagedConfigConsentPanel.makePanel(model)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        return { panel.orderOut(nil) }
    }
    /// The sheet's width in points at UI scale 1; the view wraps inside it.
    static let width: CGFloat = 560

    private let show: Show
    /// One sheet per entry; `queue.first` is the one on screen while `model` is set. Each waiter is one confirm.
    private var queue: [(changes: ManagedConfigChangeSet, waiters: [(id: Int, done: @MainActor @Sendable (Bool) -> Void)])] = []
    private var lastWaiter = 0
    private var closeShown: (@MainActor () -> Void)?
    private var model: ManagedConfigConsentModel?

    init(show: @escaping Show) { self.show = show }

    /// Returns the withdraw for this request: it leaves the queue (never shown) or, if its sheet is up and no
    /// one else waits on it, the sheet closes as a Cancel and the next request is shown. After an answer it does nothing.
    @discardableResult
    func enqueue(_ changes: ManagedConfigChangeSet, done: @escaping @MainActor @Sendable (Bool) -> Void) -> @MainActor () -> Void {
        lastWaiter += 1
        let id = lastWaiter
        // #947 (B-INFO-9, F947-1): the same sheet of the same kit and operation over the same writes (path, base
        // hash, new bytes' digest, mode per file), still pending: no second sheet, the same answer. Anything else,
        // or a set with no identity, queues as its own sheet: equal lines can hide other bytes.
        if changes.identity != nil, let i = queue.firstIndex(where: { $0.changes == changes && $0.changes.identity == changes.identity }) {
            queue[i].waiters.append((id, done))
        } else {
            queue.append((changes, [(id, done)]))
        }
        if model == nil { next() }
        return { [weak self] in self?.withdraw(id) }
    }

    private func next() {
        guard let first = queue.first else { return }
        let model = ManagedConfigConsentModel(changes: first.changes) { [weak self] ok in self?.answered(ok) }
        self.model = model
        closeShown = show(model)
    }

    private func answered(_ ok: Bool) {
        close()
        guard !queue.isEmpty else { return }
        let request = queue.removeFirst()
        for w in request.waiters { w.done(ok) }
        next()
    }

    private func withdraw(_ id: Int) {
        guard let i = queue.firstIndex(where: { $0.waiters.contains { $0.id == id } }),
              let done = queue[i].waiters.first(where: { $0.id == id })?.done else { return } // answered already
        queue[i].waiters.removeAll { $0.id == id }
        if queue[i].waiters.isEmpty {
            if i == 0, let model { model.answer(false) } else { queue.remove(at: i) }
        }
        done(false)
    }

    /// Built apart from `next` so tests get the panel without ordering it front.
    static func makePanel(_ model: ManagedConfigConsentModel) -> KeyablePanel {
        let width = sz(Self.width)
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        let content = ScrollView { ManagedConfigConsentView(model: model).frame(width: width) }
            .frame(width: width)
            .neonPanelSurface()
        let host = NSHostingView(rootView: content)
        let fitting = NSHostingController(rootView: ManagedConfigConsentView(model: model))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: min(fitting.height, screen * 0.8)),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Prosper: config changes"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        return panel
    }

    private func close() {
        closeShown?()
        closeShown = nil
        model = nil
    }
}
