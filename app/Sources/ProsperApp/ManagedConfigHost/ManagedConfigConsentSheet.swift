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
    /// separator and other unseen scalar is dropped by the tree's rule for shown outside strings, then each base keeps
    /// at most three combining marks (B1235-1, OutsideText.maxMarks), then the 120 cut. nil when none is known, and nil for a title shaped like an
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

    /// A new file has nothing to back up: no backup line for it. #1252: the directory can hold a kit's own names: displayed.
    func backupLine(_ file: ManagedConfigChangeSet.File) -> String? {
        file.newFile ? nil : "Backup: " + ManagedConfigConsentDisplay.displayed(file.backupDirectory)
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
        return sign + ManagedConfigConsentDisplay.displayed(line.text) + (line.noFinalNewline ? "   (no newline at end of file)" : "")
    }

    /// Every string the view renders, in order, in the form it is drawn: what the C11 test greps.
    var renderedStrings: [String] {
        var out = [title] + (idLine.map { [$0] } ?? []) + [lead]
        for f in changes.files {
            out.append(ManagedConfigConsentDisplay.displayed(f.path))
            if let s = status(f) { out.append(s) }
            out += f.lines.map(Self.text) + notes(f).map(ManagedConfigConsentDisplay.displayed) + (backupLine(f).map { [$0] } ?? [])
        }
        return out + (showsCutNote ? [Self.cutNote] : []) + ["Cancel", verb]
    }

    /// R1252-q3: said once under the files when any text the cards show is cut at the display's ceiling.
    static let cutNote = "A line is too long to show here in full: read the whole file before you approve."

    var showsCutNote: Bool {
        // QA r1106: the backup directory only where its line is shown (a new file has none)
        changes.files.contains { f in ([f.path] + (backupLine(f) == nil ? [] : [f.backupDirectory]) + notes(f) + f.lines.map(\.text))
            .contains(where: ManagedConfigConsentDisplay.isCut) }
    }
}

/// #1252 (F1054-1): how the sheet shows outside text it draws whole (a diff line, the path, a note, the backup line). The
/// bytes written keep every scalar, so the display drops none of them:
/// - a scalar OutsideText.isUnseen names is shown as the escape \u{XXXX} (its code point, uppercase hex, at least four
///   digits), except a tab, which draws as blank space inside its own line and stays;
/// - each base keeps its first three combining marks as marks (OutsideText.capMarks, OutsideText.maxMarks) and shows each
///   further one as its escape IN PLACE, where it is written (#1251 F1251-s1-b): what follows a dropped mark is another
///   dropped mark, a scalar that is not a mark, or the end, so an escape never parts a kept mark from its base and the
///   scalars are shown in the order they are written;
/// - a run of backslashes (with the marks on them) shown just before an escape or before a literal "u{" is doubled: before
///   "u{", an odd run of backslashes ends in an escape of ours, an even run is the line's own backslashes, each shown twice.
///   A dropped mark's escape comes right after the kept marks of its base, so a backslash base's run is doubled before it
///   exactly as before any other escape;
/// - past `ceiling` scalars the rest is counted, not shown, and the line says so;
/// - a text whose first letter is not an ASCII letter gets U+200E in front, so it is drawn left to right in the order it is
///   written (a right-to-left word still reads right to left inside its own run); an ASCII-only text is drawn as before;
/// - each right-to-left run that anything follows gets U+200E after it (R1252-q4), so digits and signs after a
///   right-to-left word are drawn after it in the order they are written, not inside its run.
/// The marks are drawn only: never written, compared, hashed or counted for the cut. The path and backup line are
/// selectable, so copying one whose text gets a mark copies the U+200E with it (QA r1106).
/// Pure and linear in its input; no isolation.
enum ManagedConfigConsentDisplay {
    static let ceiling = 2000

    static func displayed(_ s: String) -> String {
        // what is cut, in characters as a person counts them
        var tail = String.UnicodeScalarView()
        tail.append(contentsOf: s.unicodeScalars.dropFirst(ceiling))
        let rest = String(tail).count
        var head = String.UnicodeScalarView()
        head.append(contentsOf: s.unicodeScalars.prefix(ceiling))
        // every scalar of the head in display order, with whether it is shown as its escape
        var pieces: [(scalar: Unicode.Scalar, escaped: Bool)] = []
        let chars = Array(String(head))
        for (c, ch) in chars.enumerated() {
            let kept = Array(OutsideText.capMarks(String(ch)).unicodeScalars)
            var k = 0
            // capMarks only drops marks, and the FIRST scalar it keeps after a dropped one is not a mark (the count per base
            // runs on until a non-mark): a dropped mark never equals the next kept scalar, so this walk is exact
            for u in ch.unicodeScalars {
                if k < kept.count, kept[k] == u {
                    pieces.append((u, u != "\t" && OutsideText.isUnseen(u)))
                    k += 1
                } else {
                    // a dropped mark: its escape in place, in the written order
                    pieces.append((u, true))
                }
            }
            // R1252-q4: U+200E after the last character of each right-to-left run that anything follows (the next character
            // or the cut's own text), never inside a run: the whole character goes first, so its marks stay with it
            if isRightToLeft(ch), (c + 1 < chars.count ? !isRightToLeft(chars[c + 1]) : rest > 0) {
                pieces.append(("\u{200E}", false))
            }
        }
        var out = String.UnicodeScalarView(), run: [Unicode.Scalar] = []
        func flush(doubled: Bool) {
            for u in run {
                out.append(u)
                if doubled, u == "\\" { out.append(u) }
            }
            run = []
        }
        for (i, p) in pieces.enumerated() {
            let mark = p.scalar.properties.generalCategory == .nonspacingMark || p.scalar.properties.generalCategory == .enclosingMark
            if !p.escaped, p.scalar == "\\" || (mark && !run.isEmpty) {
                run.append(p.scalar)
                continue
            }
            if !run.isEmpty {
                let next: (scalar: Unicode.Scalar, escaped: Bool)? = i + 1 < pieces.count ? pieces[i + 1] : nil
                flush(doubled: p.escaped || (p.scalar == "u" && next?.escaped == false && next?.scalar == "{"))
            }
            if p.escaped { out.append(contentsOf: escape(p.scalar).unicodeScalars) } else { out.append(p.scalar) }
        }
        flush(doubled: false)
        // R1252-q1: the first strong letter sets the direction a text is laid out in. No ASCII scalar but a letter is
        // strong, so a text whose first letter or non-ASCII scalar is an ASCII letter is left to right already, and so is an
        // ASCII-only one; any other gets U+200E in front (drawn only: never written, compared or counted for the cut).
        let ltr = out.first(where: { !$0.isASCII || $0.properties.isAlphabetic })?.isASCII ?? true
        let shown = (ltr ? "" : "\u{200E}") + String(out)
        return rest > 0 ? shown + "\u{2026} (+\(rest) more characters, not shown)" : shown
    }

    /// A character whose base is a right-to-left letter, digit or sign: drawn inside a right-to-left run.
    /// shortcut: Swift has no bidi class per scalar, so the blocks whose scalars are right to left (bidi class R, AL or AN:
    /// Hebrew to Arabic Extended-A, the Hebrew and Arabic presentation forms, the supplementary right-to-left blocks) stand
    /// in for it, minus marks and unseen scalars; upgrade if the standard library gains a bidi class.
    static func isRightToLeft(_ ch: Character) -> Bool {
        guard let u = ch.unicodeScalars.first, !OutsideText.isUnseen(u) else { return false }
        let g = u.properties.generalCategory
        guard g != .nonspacingMark, g != .enclosingMark, g != .spacingMark else { return false }
        switch u.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }

    /// True when `displayed` cuts the text at the ceiling.
    static func isCut(_ s: String) -> Bool { !s.unicodeScalars.dropFirst(ceiling).isEmpty }

    /// The visible form of one scalar: \u{XXXX}, uppercase hex, padded to four digits, never more.
    static func escape(_ u: Unicode.Scalar) -> String {
        let hex = String(u.value, radix: 16, uppercase: true)
        return "\\u{" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + "}"
    }
}

/// #1252: one diff line of the sheet, already displayed (ManagedConfigConsentDisplay). It wraps as before and is clipped
/// to its own bounds, so nothing it draws reaches the line above or below it.
struct ManagedConfigConsentDiffLine: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(Neon.font(11, design: .monospaced))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
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
            // R1252-q3: its own slot in the stack, under the cards and above the buttons: it covers nothing
            if model.showsCutNote {
                Text(verbatim: ManagedConfigConsentModel.cutNote)
                    .font(Neon.font(12))
                    .foregroundStyle(Neon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            // #1252: the path, the notes and the backup line can hold a kit's own text: displayed and clipped like a line
            Text(verbatim: ManagedConfigConsentDisplay.displayed(file.path))
                .font(Neon.font(12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Neon.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
            if let status = model.status(file) {
                Text(status).font(Neon.font(11)).foregroundStyle(Neon.blueBright)
            }
            VStack(alignment: .leading, spacing: sz(1)) {
                ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                    ManagedConfigConsentDiffLine(text: ManagedConfigConsentModel.text(line), color: color(line.sign))
                }
            }
            ForEach(model.notes(file), id: \.self) { note in
                Text(verbatim: ManagedConfigConsentDisplay.displayed(note))
                    .font(Neon.font(12))
                    .foregroundStyle(Neon.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .clipped()
            }
            if let backup = model.backupLine(file) {
                Text(verbatim: backup)
                    .font(Neon.font(11))
                    .foregroundStyle(Neon.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .clipped()
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
