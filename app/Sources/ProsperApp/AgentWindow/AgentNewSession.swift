import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// #847: New session from the Agent Sessions window: the form in the detail pane (folder, name, command)
// and the quick shell. One spawn path with the island's New session (AgentIslandController.spawn).

/// The form's state. #1731: `name` starts "" (required, never generated); Start refuses it while its trim is empty.
struct AgentNewSessionForm: Equatable {
    /// As typed; may be "~/x".
    var folder: String
    var name = ""
    var nameEdited = false
    /// The Name field's text: what was typed (no placeholder, no generated text).
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
    /// #847 P1d: the first message. #1822: its editor is always shown (no disclosure).
    var prompt = ""
    /// #1822: the images pasted into the prompt, in paste order (their paths are in `prompt`).
    var images: [AgentPromptImages.Pasted] = []
    /// #1836: pastes still being encoded (Start waits for them), and the line a paste left (failed, skipped, refused).
    var pasting = 0
    var imageNote: String?
}

/// #1822: an image pasted into the New session prompt: written as a PNG to a Prosper-owned cache dir, its absolute
/// path inserted at the caret (Claude Code reads an image file named by its path in a message). Nothing runs until a
/// paste; the encode, the thumbnail and the age prune run off main, on that paste.
enum AgentPromptImages {
    /// What a paste holds: an image file, or an item's image bytes (PNG, TIFF, any image UTI).
    enum Source: Sendable, Equatable { case file(URL), data(Data) }
    /// One written PNG and its small thumbnail's PNG bytes (made off main; NSImage is built on main).
    struct Made: Sendable, Equatable { var path: String; var thumb: Data? }
    /// A pasted image as the form keeps it.
    struct Pasted: Equatable { var path: String; var thumb: NSImage? }
    /// #1836: what a paste came to: the written images and the ones that did not make it.
    struct Outcome: Sendable, Equatable {
        var made: [Made] = []
        /// Unreadable or not an image.
        var failed = 0
        /// Over the per-paste cap.
        var refused = 0
        /// File URLs of the paste that are not images.
        var skipped = 0

        /// The one status line under the prompt; nil: all went well.
        var note: String? {
            let parts = [
                failed > 0 ? "Could not add \(failed) image\(failed == 1 ? "" : "s")" : nil,
                refused > 0 ? "Refused \(refused) image\(refused == 1 ? "" : "s") over the limit of \(AgentPromptImages.maxImages) images or 50 MB" : nil,
                skipped > 0 ? "Skipped \(skipped) file\(skipped == 1 ? " that is not an image" : "s that are not images")" : nil,
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ". ")
        }
    }

    /// Pruned on each paste: older files are gone by then (a first message reads its image at once).
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let thumbPixels = 64
    /// #1836: one paste's cap: images, and bytes read.
    static let maxImages = 20
    static let maxBytes = 50_000_000
    /// #1863 n173 (b): an image's width times height, read from its header before anything decodes it (a small file can
    /// claim a huge canvas). 64 megapixels: an 8K photo is 33.
    static let maxPixels = 64_000_000

    /// Caches/Prosper/prompt-images; nil under XCTest, so a row writes only under the temp dir it sets.
    static let defaultDir: URL? = {
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Prosper/prompt-images", isDirectory: true)
    }()

    /// The paste's images; nil: not an image paste (the text path, unchanged). Image file URLs first (Finder's copy
    /// also holds the names as text); then text wins over image bytes, as in the terminal's paste.
    static func sources(_ pb: NSPasteboard) -> [Source]? {
        let urls = fileURLs(pb, imagesOnly: true)
        if !urls.isEmpty { return urls.map(Source.file) }
        guard pb.string(forType: .string) == nil,
              pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier]) else { return nil }   // AgentTerminal's test
        let datas = (pb.pasteboardItems ?? []).compactMap { item in
            item.types.first { UTType($0.rawValue)?.conforms(to: .image) == true }.flatMap { item.data(forType: $0) }
        }
        return datas.isEmpty ? nil : datas.map(Source.data)
    }

    private static func fileURLs(_ pb: NSPasteboard, imagesOnly: Bool) -> [URL] {
        var opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if imagesOnly { opts[.urlReadingContentsConformToTypes] = [UTType.image.identifier] }
        return pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
    }

    /// #1836: the file URLs in `pb` that are not images (a paste of images drops them; the status line says so).
    static func skippedFiles(_ pb: NSPasteboard) -> Int {
        max(0, fileURLs(pb, imagesOnly: false).count - fileURLs(pb, imagesOnly: true).count)
    }

    /// Off main: prunes `dir`, then writes each source as `<uuid>.png` (a PNG as it is, anything else re-encoded),
    /// and hands what came of it to `done` on main. A source that is not a readable image is counted in `failed`.
    /// `skipped`: the paste's non-image files.
    static func store(_ sources: [Source], skipped: Int = 0, dir: URL, now: Date = Date(),
                      done: @escaping @MainActor @Sendable (Outcome) -> Void) {
        Task.detached(priority: .userInitiated) {
            var out = write(sources, dir: dir, now: now)
            out.skipped = skipped
            await done(out)
        }
    }

    /// #1836: past `maxImages` sources, or when the next one would take the bytes read past `maxBytes`, the rest is
    /// refused unread (a file's size is asked for before it is read). #1863: a file whose target is not named as an image
    /// type, is not a regular file, or an image over `maxPixels` counts as failed.
    static func write(_ sources: [Source], dir: URL, now: Date, maxImages: Int = maxImages, maxBytes: Int = maxBytes,
                      maxPixels: Int = maxPixels) -> Outcome {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        prune(dir: dir, now: now)
        var out = Outcome(), read = 0
        for (i, s) in sources.enumerated() {
            let data: Data?
            switch s {
            case .file(let named):
                // #1863: a link is read as its target, and the target's name is the one that must be an image type's.
                let url = named.resolvingSymlinksInPath()
                let v = try? url.resourceValues(forKeys: [.fileSizeKey])
                if i >= maxImages || (v?.fileSize ?? 0) > maxBytes - read { out.refused = sources.count - i; return out }
                guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { out.failed += 1; continue }
                // n172: one read on the open descriptor: a FIFO or device (swapped in since the size check, too) is refused
                // without blocking, and a file grown since then is refused at the bytes left, never read whole.
                data = try? BoundedFileRead.data(url, maxBytes: maxBytes - read)
            case .data(let d):
                if i >= maxImages || d.count > maxBytes - read { out.refused = sources.count - i; return out }
                data = d
            }
            read += data?.count ?? 0   // at most maxBytes - read: both reads are capped above
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
                  pixels(src).map({ $0 <= maxPixels }) == true else {
                out.failed += 1
                continue
            }
            let url = dir.appendingPathComponent(UUID().uuidString + ".png")
            if CGImageSourceGetType(src) as String? == UTType.png.identifier {
                guard (try? data.write(to: url)) != nil else { out.failed += 1; continue }
            } else {
                guard let image = CGImageSourceCreateImageAtIndex(src, 0, nil), png(image, to: url as CFURL) else { out.failed += 1; continue }
            }
            out.made.append(Made(path: url.path, thumb: thumb(src)))
        }
        return out
    }

    /// Removes the PNGs in `dir` last modified before `now - maxAge`; nothing else. Returns how many went.
    @discardableResult
    static func prune(dir: URL, now: Date, maxAge: TimeInterval = maxAge) -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for f in files where f.pathExtension == "png" {
            // #1836: a directory named *.png is not ours to remove.
            guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true,
                  let at = v.contentModificationDate, now.timeIntervalSince(at) > maxAge, (try? fm.removeItem(at: f)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    /// The first image's width times height from its header (no decode); nil when the header does not say.
    static func pixels(_ src: CGImageSource) -> Int? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w >= 0, h >= 0 else { return nil }
        let (n, over) = w.multipliedReportingOverflow(by: h)
        return over ? nil : n
    }

    private static func png(_ image: CGImage, to url: CFURL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    private static func thumb(_ src: CGImageSource) -> Data? {
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: thumbPixels] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The text a paste inserts: the paths, space-separated, a space before them unless at a line start or after a
    /// space, and one after.
    static func insertion(_ paths: [String], after previous: Character?) -> String {
        let lead = previous.map { $0.isWhitespace ? "" : " " } ?? ""
        return lead + paths.joined(separator: " ") + " "
    }

    /// `prompt` without `path` (and the one space after it): the chip's remove.
    static func removing(_ path: String, from prompt: String) -> String {
        prompt.replacingOccurrences(of: path + " ", with: "").replacingOccurrences(of: path, with: "")
    }
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

    /// #1429: the Recent folders chevron. The borderless menu button takes its label image's own accessibility
    /// description, and a bare chevron.down symbol's is "go down" (VoiceOver read it after the title). The button
    /// draws the symbol at its default configuration (the label's font never reached it), so this is that symbol,
    /// unconfigured, described by the menu's title; the pixel row compares it with the old Image(systemName:).
    /// #1540: a Recent folders item: what it shows and what it sets.
    struct Recent: Equatable { var shown: String; var set: String }
    static let recentsMenuID = "agent.newSession.recents"

    /// #1997: the Command menu beside the field. The form opens on Claude; a pick sets the whole field.
    enum Agent: String, CaseIterable { case claude = "Claude", codex = "Codex", shell = "Login shell" }
    static let agentsMenuID = "agent.newSession.agents"
    static let agentsMenuTitle = "Agent"

    /// #1997: what a pick sets: the Settings command, else the agent's binary; Login shell: empty. Claude's unset
    /// setting is plain claude: the form open already ran the #606 inference, which stores what it finds.
    static func command(for a: Agent) -> String {
        switch a {
        case .claude: let c = Preferences.agentIslandNewSessionCommand; return c.isEmpty ? "claude" : c
        case .codex: let c = Preferences.agentIslandCodexCommand; return c.isEmpty ? "codex" : c
        case .shell: return ""
        }
    }

    /// #1540: this Mac's folders are shown and set abbreviated; #1323: another Mac's path is shown through
    /// OutsideText and set raw.
    static func recents(_ folders: [String], remote: Bool, home: String) -> [Recent] {
        folders.map { f in
            if remote { return Recent(shown: OutsideText.shown(f), set: f) }
            let shown = abbreviate(f, home: home)
            return Recent(shown: shown, set: shown)
        }
    }

    static func recentFoldersChevron(_ title: String = "Recent folders") -> NSImage {
        NSImage(systemSymbolName: "chevron.down", accessibilityDescription: title) ?? NSImage()
    }

    /// The menu's label around `chevron` (the tests draw the old symbol image through it too).
    static func recentFoldersLabel(_ chevron: Image) -> some View {
        chevron.font(Neon.font(10, weight: .semibold)).foregroundStyle(Neon.textPrimary).contentShape(Rectangle())
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
        freeStem(AgentIsland.sessionName(folder: folder), taken: taken, dir: dir)
    }

    /// QA #736 INFO-3: the quick shell starts in every folder: a folder name dch refuses (id-shaped, too long for
    /// `dir`) gives way to the stem "shell".
    static func shellName(folder: String, taken: Set<String>, dir: String) -> String {
        let n = autoName(folder: folder, taken: taken, dir: dir)
        return nameError(n, taken: taken, dir: dir) == nil ? n : freeStem("shell", taken: taken, dir: dir)
    }

    private static func freeStem(_ stem: String, taken: Set<String>, dir: String) -> String {
        AgentIsland.freeName(String(stem.prefix(max(1, nameLimit(dir: dir) - 4))), taken: taken)
    }

    /// nil: the name can be spawned into socket dir `dir`. Empty (after trim): no error here (the form shows none while it is untouched); #1731 canStartNewSession refuses it.
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
    /// #1454: and the Default effort.
    static func argv(_ command: String, shell: String?, model: String = Preferences.agentIslandDefaultModel,
                     effort: String = Preferences.agentIslandDefaultEffort) -> [String] {
        let words = AgentIsland.shellWords(command)
        return words.isEmpty ? [loginShell(shell), "-l"] : AgentIsland.withModel(words, model: model, effort: effort)
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

/// #1540: the New session form's Recent folders menu: a StableMenu, rebuilt only when its folders change.
struct AgentRecentFoldersMenu: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let recents: [AgentNewSession.Recent]
    let choose: (String) -> Void

    var body: some View {
        StableMenu(AgentNewSession.recentsMenuID, entries: recents, run: choose) { rs, run in
            ForEach(Array(rs.enumerated()), id: \.offset) { _, r in Button(r.shown) { run(r.set) } }
        } label: { _ in
            AgentNewSession.recentFoldersLabel(Image(nsImage: AgentNewSession.recentFoldersChevron()))
        }
    }
}

/// #1997: the New session form's Command menu (Claude, Codex, Login shell), built like the Recent folders one.
struct AgentCommandMenu: View {
    @ObservedObject var liveTheme = ThemeStore.shared
    let choose: (AgentNewSession.Agent) -> Void

    var body: some View {
        StableMenu(AgentNewSession.agentsMenuID, entries: AgentNewSession.Agent.allCases, run: choose) { all, run in
            ForEach(all, id: \.self) { a in Button(a.rawValue) { run(a) } }
        } label: { _ in
            AgentNewSession.recentFoldersLabel(Image(nsImage: AgentNewSession.recentFoldersChevron(AgentNewSession.agentsMenuTitle)))
        }
    }
}

extension View {
    /// The Recent folders menu's style, size and names (#887), shared with the #1429 pixel row.
    func recentFoldersMenuStyle(disabled: Bool, title: String = "Recent folders") -> some View {
        menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: sz(18), height: sz(18))
            .disabled(disabled)
            .help(title)
            .accessibilityLabel(title)
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
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
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
                    // #1540: the window model publishes as the store ticks; the open list is rebuilt only on a change.
                    let recents = AgentNewSession.recents(model.newSessionRecents, remote: form.host != nil, home: model.home)
                    AgentRecentFoldersMenu(recents: recents) { model.setNewSessionFolder($0) }
                        .recentFoldersMenuStyle(disabled: recents.isEmpty)
                    if form.host == nil {   // #1323: no folder browser on another Mac in v1
                        AgentPillButton(title: "Choose\u{2026}", icon: "folder", tint: Neon.blue) { model.chooseNewSessionFolder() }
                    }
                }
            }
            field("Name", error: errors.name) {
                TextField("Optional for a shell: the folder's name", text: Binding(get: { form.nameFieldText }, set: { model.setNewSessionName($0) }))
                    .focused($focus, equals: .name)
                    .accessibilityLabel("Name")
            }
            field("Command", error: nil) {
                VStack(alignment: .leading, spacing: sz(4)) {
                    HStack(spacing: sz(6)) {
                        TextField("Empty: your login shell", text: Binding(get: { form.command }, set: { model.setNewSessionCommand($0) }))
                            .focused($focus, equals: .command)
                            .accessibilityLabel("Command")
                        AgentCommandMenu { model.pickNewSessionAgent($0) }
                            .recentFoldersMenuStyle(disabled: false, title: AgentNewSession.agentsMenuTitle)
                    }
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
            promptRows
            Divider().padding(.vertical, sz(4))
            HStack(spacing: sz(8)) {
                // QA #736 INFO-3: Start's condition; it dims in place. #847 D6.2: also while the prompt holds.
                let shellWhy = model.newSessionShellRefusal
                AgentPillButton(title: "New shell", icon: "apple.terminal", tint: Neon.terminal,
                                enabled: model.canStartNewShell && shellWhy == nil) { model.startShell() }
                    .help(shellWhy ?? "With no Name, the shell takes the folder's name")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)   // #1479: centred when it fits; a ScrollView gives it its own height, so it stays top-aligned there
    }

    /// #847 D6.1: why the prompt is dimmed (newSessionTakesPrompt false); #1822: shown under it. #1992: or Codex.
    static func notClaude(command: String, host: String?) -> String {
        if host != nil { return "A first prompt starts on this Mac only" }
        return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "The login shell has no Claude or Codex to prompt"
            : "Needs a claude or codex command (or a wrapper that runs one)"
    }

    /// #847 D5.1-D5.3: the editor at a fixed sz(96). #1822: always shown (no disclosure), the line under it says it is
    /// optional, or why it is dimmed. Return adds a line, Command-Return is Start. Not a Claude: dimmed, the text kept.
    static let promptLabel = "Prompt"
    static let addingImage = "Adding image…"
    static let promptHint = "Optional. \u{2318}V pastes images too"
    /// #1992: a Codex's prompt is text only (images go through Claude's paste path).
    static let codexPromptHint = "Optional. Text only: images need Claude"
    static let promptEditorLabel = "First prompt for the new session"   // #1392: not the composer's "Message Claude"
    static func promptEditor(text: Binding<String>, onSubmit: @escaping () -> Void, editable: Bool,
                             imagePaste: AgentComposerTextView.ImagePaste? = nil) -> AgentComposerField {
        AgentComposerField(text: text, onSubmit: onSubmit, editable: editable, returnSubmits: false, label: promptEditorLabel,
                           imagePaste: imagePaste)
    }

    private var promptRows: some View {
        let claude = model.newSessionClaude, takes = model.newSessionTakesPrompt
        let paste = !claude ? nil : model.promptImagesDir.map { dir in
            AgentComposerTextView.ImagePaste(dir: dir, began: { [weak model] in model?.beginNewSessionPromptPaste() },
                                                 added: { [weak model] out in model?.addNewSessionPromptImages(out) })
        }
        // A chip only while its path is still in the text (typing it away drops the chip too).
        let images = form.images.filter { form.prompt.contains($0.path) }
        return HStack(alignment: .top, spacing: sz(8)) {
            Text(Self.promptLabel).font(Neon.font(11.5)).foregroundStyle(Neon.textSecondary).frame(width: sz(64), alignment: .leading)
            VStack(alignment: .leading, spacing: sz(2)) {
                Self.promptEditor(text: Binding(get: { form.prompt }, set: { model.setNewSessionPrompt($0) }),
                                  onSubmit: { model.startNewSession() }, editable: takes && form.starting == nil, imagePaste: paste)
                    .frame(height: sz(96))
                    .overlay(RoundedRectangle(cornerRadius: sz(4)).stroke(Neon.textSecondary.opacity(0.4)))
                    .opacity(takes ? 1 : 0.45)
                if !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: sz(6)) { ForEach(images, id: \.path) { promptChip($0, enabled: takes && form.starting == nil) } }
                    }
                    .padding(.top, sz(4))
                }
                slot(form.pasting > 0 ? Self.addingImage : form.imageNote
                     ?? (claude ? Self.promptHint : takes ? Self.codexPromptHint : Self.notClaude(command: form.command, host: form.host)))
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    /// #1822: one pasted image: its thumbnail, and an x that takes its path out of the prompt.
    private func promptChip(_ image: AgentPromptImages.Pasted, enabled: Bool) -> some View {
        let name = (image.path as NSString).lastPathComponent
        return HStack(spacing: sz(3)) {
            Group {
                if let thumb = image.thumb { Image(nsImage: thumb).resizable().scaledToFill() }
                else { Image(systemName: "photo").foregroundStyle(Neon.textSecondary) }
            }
            .frame(width: sz(28), height: sz(28)).clipShape(RoundedRectangle(cornerRadius: sz(3)))
            .help(image.path)
            Button { model.removeNewSessionPromptImage(image.path) } label: {
                Image(systemName: "xmark").font(Neon.font(9, weight: .semibold)).foregroundStyle(Neon.textSecondary)
                    .frame(width: sz(14), height: sz(14)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!enabled)
            .help("Remove this image").accessibilityLabel("Remove image \(name)")
        }
        .padding(sz(2))
        .overlay(RoundedRectangle(cornerRadius: sz(4)).stroke(Neon.textSecondary.opacity(0.4)))
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
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
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
