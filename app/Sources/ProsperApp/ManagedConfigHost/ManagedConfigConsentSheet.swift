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
    typealias Present = @MainActor @Sendable (ManagedConfigChangeSet, @escaping @MainActor @Sendable (Bool) -> Void) -> Void

    let present: Present

    init(present: @escaping Present) { self.present = present }

    /// The app's sheet: one panel at a time, a second request waits for the first answer.
    static let live = ManagedConfigSheetConsent { changes, done in ManagedConfigConsentPanel.shared.enqueue(changes, done: done) }

    nonisolated func confirm(_ changes: ManagedConfigChangeSet) async -> Bool {
        let present = self.present
        let answer = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in present(changes) { cont.resume(returning: $0) } }
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

    var title: String {
        switch changes.action {
        case .apply: return "\(changes.owner) wants to change your config"
        case .remove: return "Remove \(changes.owner)'s config changes"
        case .repair: return "Repair \(changes.owner)'s config changes"
        }
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
        var out = [title]
        for f in changes.files {
            out.append(f.path)
            if let s = status(f) { out.append(s) }
            out += f.lines.map(Self.text) + notes(f) + ["Backup: \(f.backupDirectory)"]
        }
        return out
    }
}

struct ManagedConfigConsentView: View {
    @ObservedObject var model: ManagedConfigConsentModel

    var body: some View {
        VStack(alignment: .leading, spacing: sz(12)) {
            Text(model.title)
                .font(Neon.font(15, weight: .semibold))
                .foregroundStyle(Neon.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Prosper writes only what is shown here, and keeps a backup of each file first.")
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
                Button("Apply") { model.answer(true) }
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
            Text("Backup: \(file.backupDirectory)")
                .font(Neon.font(11))
                .foregroundStyle(Neon.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
    private var queue: [(ManagedConfigChangeSet, @MainActor @Sendable (Bool) -> Void)] = []
    private var closeShown: (@MainActor () -> Void)?
    private var model: ManagedConfigConsentModel?

    init(show: @escaping Show) { self.show = show }

    func enqueue(_ changes: ManagedConfigChangeSet, done: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.append((changes, done))
        if model == nil { next() }
    }

    private func next() {
        guard !queue.isEmpty else { return }
        let (changes, done) = queue.removeFirst()
        let model = ManagedConfigConsentModel(changes: changes) { [weak self] ok in
            self?.close()
            done(ok)
            self?.next()
        }
        self.model = model
        closeShown = show(model)
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
