import AppKit
import CryptoKit
import Foundation
import LuaRuntime
import os

/// One installed extension's live state: its validated manifest, its disk
/// location, whether it is enabled, and a lazily-created Lua runtime.
final class ExtensionRecord {
    let loaded: LoadedExtension
    var enabled: Bool
    /// Whether the user has reviewed + trusted this extension. System extensions
    /// (shipped inside the signed bundle) are always trusted. A freshly installed
    /// user/market extension lands UNTRUSTED: its files sit on disk and its manifest
    /// is parsed for the list UI, but no contribution is routed and no Lua VM is ever
    /// spawned until the user inspects it and clicks Trust. The only attack surface
    /// is the download/extract code — see `ExtensionRegistry.trust`.
    var trusted: Bool
    /// Whether the user has granted this extension the SYSTEM tier (host.shell, the
    /// coding-agent, destructive host.files.act) — an explicit, per-extension opt-in
    /// SEPARATE from Trust. System extensions are always privileged. A user/market
    /// extension is privileged ONLY if the user toggles it on (default off), so a
    /// trusted-but-not-privileged extension keeps the automation-only surface (today's
    /// behaviour). See `ExtensionRegistry.grantPrivilege`.
    var privileged: Bool
    /// Created on first activation, torn down on disable/reset/reload.
    var runtime: LuaRuntime?

    init(loaded: LoadedExtension, enabled: Bool, trusted: Bool, privileged: Bool = false) {
        self.loaded = loaded
        self.enabled = enabled
        self.trusted = trusted
        self.privileged = privileged
    }

    var id: String { loaded.id }
    var manifest: ExtensionManifest { loaded.manifest }
    var isSystem: Bool { loaded.isSystem }

    /// Eligible to route / activate: enabled AND trusted.
    var isLive: Bool { enabled && trusted }
}

enum ExtensionError: Error, Equatable {
    case notFound(String)
    case cannotUninstallSystem(String)
    case cannotResetUserExtension(String)
    case noPristineCopy(String)
    case untrusted(String)
    /// A market artifact's internal manifest id didn't match the signed/requested
    /// package id — an id-spoof attempt (could overwrite/impersonate another id).
    case marketIdMismatch(expected: String, got: String)
    /// #870: the extension still has managed-config pieces and they were not removed (Remove
    /// cancelled, refused or failed): the uninstall stops and the dir stays.
    case managedConfigKept(id: String, reason: String)
    /// R1182-g: a market artifact's own manifest declares another version than the listing it was asked for.
    /// The values are stored as shown (OutsideText), so the log's String(describing:) holds them cleaned too.
    case marketVersionMismatch(id: String, listed: String, got: String)
    /// #919 S3: a downloaded package checked against its Marketplace listing (a kit, or listed as one) was refused. The id
    /// is stored as shown (OutsideText). `.versionMovedOn` is not a refusal of the content (RefusedUpdates.isRefusal).
    case marketKitRefused(id: String, KitListingRefusal)
    /// #919 S3: the listing a kit is checked against could not be loaded: nothing installed, a later try can pass.
    case marketListingUnavailable(id: String)
    /// An update's archive is a kit where the installed record is not, or the reverse: the id is stored as shown (OutsideText).
    /// A refusal of the content (RefusedUpdates.isRefusal); installLocal would keep trust and privilege across the change.
    case marketKindChanged(id: String)
    /// #1704 (OQ-191): an update over a trusted extension asked for permissions the installed version lacks and the review
    /// was declined: nothing was copied. The id is stored as shown (OutsideText); `added` as the manifest declares them
    /// (outside data, shown through OutsideText). Not a refusal of the content: the update check holds it for review.
    case newPermissionsDeclined(id: String, added: [String])
}

extension ExtensionError: LocalizedError {
    /// Plain words for the two market refusals; every other case keeps nil, so it is shown as before.
    var errorDescription: String? {
        switch self {
        case let .marketVersionMismatch(id, listed, got):
            return "Not installed: the package's files declare version \"\(got)\", but the Marketplace lists version "
                + "\"\(listed)\" for \(id). Nothing was changed."
        case let .marketIdMismatch(expected, got):
            // R1182-m: both ids are outside data (the listing's and the archive's own), cleaned and bounded here.
            return "Not installed: the package's files declare the id \"\(OutsideText.shown(got, max: 128))\", but the Marketplace "
                + "lists it as \"\(OutsideText.shown(expected, max: 128))\". Nothing was changed."
        case let .marketKitRefused(id, why):
            return "Not installed: \(id): " + why.sentence + (why.isRefusal ? " Nothing was changed." : "")
        case let .marketListingUnavailable(id):
            return "Not installed: the Marketplace listing of \(id) could not be loaded to check the kit. Try again."
        case let .marketKindChanged(id):
            return "Not installed: \(id) changed kind; install it again from the Marketplace. Nothing was changed."
        case let .newPermissionsDeclined(id, _):
            return "Not updated: \(id) asks for new permissions and they were not allowed. The installed version stays."
        default:
            return nil
        }
    }
}

/// #1246: which manifest ids an extension may be installed under. The id becomes the folder name in the
/// extensions folder, and the built-ins own their folder names and their ids.
enum ExtensionInstallID {
    /// A refused install, with the reason in plain words (shown as is by the marketplace window).
    struct Refused: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// nil when an install under `id` may go ahead, else why not. Pure: the bundled folder names and ids come in
    /// as values. Names are compared ignoring case because the disk does.
    static func refusal(_ id: String, bundledFolders: Set<String>, bundledIDs: Set<String>) -> String? {
        // The kit id rule (KitValidator): one name of letters, digits, '.', '_' and '-', at most 128, not only dots.
        guard ManagedConfigPaths.isValidID(id), !id.allSatisfy({ $0 == "." }) else {
            return "Not installed: its id is not a single name of letters, digits, dots, dashes and underscores "
                + "(at most 128 characters). Nothing was changed."
        }
        // A leading dot makes a folder hidden in Finder.
        if id.hasPrefix(".") {
            return "Not installed: its id starts with a dot, which would make a hidden folder. Nothing was changed."
        }
        let builtIn = Set(bundledFolders.union(bundledIDs).map { $0.lowercased() })
        if builtIn.contains(id.lowercased()) {
            return "Not installed: its id \(id) belongs to an extension built into Prosper. Nothing was changed."
        }
        return nil
    }

    /// nil when `id` may be installed next to the names listed in the extensions folder (nil: it could not be read).
    /// The disk ignores case, so a name that differs from `id` only by case would be replaced as if it were `id`:
    /// refused. An exact match is an update. `id` has passed refusal(), so it is a plain single name.
    /// `occupied`: the disk says the destination exists. Its fold table is wider than lowercased(), so with no exact
    /// name that is another extension's folder: refused, naming no folder.
    static func caseRefusal(_ id: String, installed names: [String]?, occupied: Bool) -> String? {
        guard let names else { return "Not installed: the extensions folder could not be read. Nothing was changed." }
        if names.contains(id) { return nil }
        if let other = names.first(where: { $0.lowercased() == id.lowercased() }) {
            return "Not installed: its id \(id) differs only by letter case from the installed extension \(other). "
                + "Nothing was changed."
        }
        if occupied {
            return "Not installed: a folder of another installed extension already answers to the name \(id) on this "
                + "disk. Nothing was changed."
        }
        return nil
    }
}

/// Off-main Lua VM cache for commands that call async host APIs (http / llm /
/// shell). `LuaRuntime` is not thread-safe and `ExtensionHost.awaitSync` blocks
/// its caller, so these VMs must live OFF the main thread and apart from the
/// MainActor `invokeSync` VMs — otherwise the bridge would deadlock the UI.
///
/// PER-EXTENSION serial lanes: each extension gets its own serial queue, so its
/// VM is never touched concurrently (the only thread-safety LuaRuntime needs) and
/// its `host.prefs` read-modify-write stays serialized (the single-flight invariant
/// — see plan §7). A slow handler in one extension (e.g. `host.http` with backoff,
/// which blocks its lane via `awaitSync`) no longer head-of-line-blocks every other
/// extension's timers/events/commands. The small cache/lane maps are guarded by a
/// lock; each VM object is only ever used from its own lane.
final class AsyncExtensionRuntimes: @unchecked Sendable {

    /// Everything needed to (re)build one VM, captured on the MainActor side.
    struct Spec: Sendable {
        let extensionID: String
        let entryURL: URL
        let handler: String
        let callTimeout: TimeInterval
        /// Bundled system extension → privileged host surface (shell/agent).
        let privileged: Bool
        /// User has trusted this extension. Guarded in `callOnLane` as a chokepoint.
        let trusted: Bool
        /// #870: owner of the extension's managed-config pieces (`host.config`).
        var configOwner: ManagedConfigOwner? = nil
        /// #983: set only by deliverEvent for a host.fs.watch run; callOnLane drops the run once that watch is gone.
        var fsWatch: FSWatchRun? = nil
        /// #1569: set only by callXref (an X-ray ref card's handler): a dropped call never starts, and its host waits go.
        var lane: LaneCall? = nil
    }

    private let lock = NSLock()
    private var cache: [String: LuaRuntime] = [:]   // guarded by `lock`; each VM used only on its lane
    private var lanes: [String: DispatchQueue] = [:] // guarded by `lock`
    /// #930: bumped by `retire` (teardown). An invocation carries the epoch it was
    /// queued under; a changed epoch means its extension was torn down meanwhile.
    private var epochs: [String: Int] = [:]          // guarded by `lock`
    /// #1238: torn down and not brought back since (retire inserts, revive removes). Resources are keyed by id
    /// only, so a call that outlives its retire may release late only while its id is still here.
    private var down: Set<String> = []               // guarded by `lock`
    /// #1238: the epoch of the call now running on each id's lane; written only on that lane (see callOnLane).
    private var running: [String: Int] = [:]         // guarded by `lock`
    private let services: ExtensionHostServices
    private static let log = Logger(subsystem: "com.prosper.extensions", category: "async-runtime")

    init(services: ExtensionHostServices) {
        self.services = services
    }

    /// The serial queue that owns `id`'s VM. Created on first use.
    private func lane(for id: String) -> DispatchQueue {
        lock.lock(); defer { lock.unlock() }
        if let q = lanes[id] { return q }
        let q = DispatchQueue(label: "com.prosper.extensions.async.\(id)")
        lanes[id] = q
        return q
    }

    private func epoch(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return epochs[id] ?? 0 }

    /// #930: called by the registry's teardown, on the main actor. Every invocation
    /// queued before it is refused if it has not started; one already running has its
    /// takes refused from now on, and releases again when it returns unless revived (see callOnLane).
    func retire(id: String) { lock.lock(); epochs[id, default: 0] += 1; down.insert(id); cache[id] = nil; lock.unlock() }

    /// #1238: the extension is live again (re-enable, reset, re-trust, reinstall): what is held under its id
    /// now belongs to the live generation, so an older call's late release must leave it alone.
    func revive(id: String) { lock.lock(); down.remove(id); lock.unlock() }

    /// #1238: true while the call running on `id`'s lane has not been retired. Read by the lane VM's
    /// gated host functions (ExtensionHost.isCurrent: every one outside retiredReads), on that lane.
    private func callIsCurrent(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running[id] == (epochs[id] ?? 0)
    }

    /// #1550: the epoch of the call running on `id`'s lane: the owner its takes record. Read on that lane.
    private func runningEpoch(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return running[id] ?? -1
    }

    /// Run `spec.handler(args…)` on the extension's lane, building + caching the VM
    /// on first use. Returns the handler's string result, or nil to decline / error.
    /// MainActor: the epoch is read and the job enqueued in the caller's turn, so no
    /// teardown can fall between the caller's isLive check and the lane.
    @MainActor
    func invoke(_ spec: Spec, args: [String]) async -> String? {
        let queued = epoch(spec.extensionID)
        let q = lane(for: spec.extensionID)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            q.async {
                cont.resume(returning: self.callOnLane(spec, epoch: queued, args: args))
            }
        }
    }

    /// Runs on `spec.extensionID`'s serial lane — so the VM (built or cached) is
    /// never concurrently accessed.
    private func callOnLane(_ spec: Spec, epoch: Int, args: [String]) -> String? {
        // Defense-in-depth chokepoint mirroring ExtensionRegistry.activate(): never
        // build or run a VM for an untrusted extension, even if a caller forgot to
        // gate on isLive. This lane runs the privileged host APIs (http/llm/shell),
        // so it gets the same untrusted-can-never-execute guarantee as the sync path.
        guard spec.trusted else {
            Self.log.error("refused async VM for untrusted extension \(spec.extensionID, privacy: .public)")
            return nil
        }
        // #930: torn down after this was queued: never run (it would take resources
        // nobody releases). Torn down while it ran: release again what it took late.
        guard self.epoch(spec.extensionID) == epoch else { return nil }
        // #983: a watch run handed off before host.fs.unwatch returned never starts after it (nil for every other call).
        if let run = spec.fsWatch, !ExtensionFSWatch.isCurrent(run) { return nil }
        if spec.lane?.isDropped == true { return nil }   // #1569: dropped while queued (a newer card, its timeout)
        lock.lock(); running[spec.extensionID] = epoch; lock.unlock()
        defer {
            // #1238: only while the extension is still off (or off again); once back, the id's resources are the
            // live generation's. The VM is dropped either way: it belongs to the retired generation.
            lock.lock()
            let retired = (epochs[spec.extensionID] ?? 0) != epoch
            let stillDown = retired && down.contains(spec.extensionID)
            if retired { cache[spec.extensionID] = nil }
            lock.unlock()
            if stillDown {
                TimerScheduler.shared.cancelAll(extID: spec.extensionID)
                services.resetResources(extensionID: spec.extensionID)
            }
        }
        do {
            let rt: LuaRuntime
            lock.lock(); let cached = cache[spec.extensionID]; lock.unlock()
            if let cached {
                rt = cached
            } else {
                rt = try LuaRuntime(allowLoad: spec.privileged || spec.trusted)
                // #1238: formed here on the lane (nonisolated) and called on the lane by this VM's gate (every
                // host function outside ExtensionHost.retiredReads, and take()); captures a weak Sendable self and a String. The VM outlives this call, so the
                // check reads the epoch of the call running at that moment (running), not the one it was built in.
                let id = spec.extensionID
                try ExtensionHost(extensionID: spec.extensionID, services: services,
                                  callTimeout: spec.callTimeout,
                                  privileged: spec.privileged, trusted: spec.trusted,
                                  configOwner: spec.configOwner,
                                  isCurrent: { [weak self] in self?.callIsCurrent(id) ?? false },
                                  generation: { [weak self] in self?.runningEpoch(id) ?? -1 }).install(into: rt)
                let source = try BoundedFileRead.text(spec.entryURL, maxBytes: BoundedFileRead.entryLuaMaxBytes)
                try rt.run(source, name: "@\(spec.extensionID)")
                lock.lock(); cache[spec.extensionID] = rt; lock.unlock()
            }
            return try LaneCall.with(spec.lane) {
                guard spec.lane != nil else { return try rt.callGlobal(spec.handler, args) }
                // #1569: an xref handler takes and returns a table; the host's shim keeps the lane string in, string out
                try rt.run(LaneCall.shim, name: "=xref")
                return try rt.callGlobal(LaneCall.shimName, [spec.handler] + args)
            }
        } catch {
            spec.lane?.fail(String(describing: error))   // #1569: the card says it failed (a nil result is "nothing")
            // A broken handler must not fail silently forever — surface it.
            Self.log.error("extension \(spec.extensionID, privacy: .public) handler \(spec.handler, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func invalidate(id: String) { lock.lock(); cache[id] = nil; lock.unlock() }
    func invalidateAll() { lock.lock(); cache.removeAll(); lock.unlock() }
}

/// #1569 (X7 c): one lane call an X-ray ref card may drop. drop() refuses it before it starts and cancels every host
/// wait it is in (ExtensionHost.awaitSync's task: host.process.run's group kill); `failed` keeps why the handler threw.
final class LaneCall: @unchecked Sendable {
    private let lock = NSLock()
    private var dropped = false
    private var failure: String?
    private var cancels: [Int: @Sendable () -> Void] = [:]
    private var next = 0

    var isDropped: Bool { lock.withLock { dropped } }
    var failed: String? { lock.withLock { failure } }
    func fail(_ why: String) { lock.withLock { if failure == nil { failure = why } } }

    func drop() {
        let c: [@Sendable () -> Void] = lock.withLock {
            dropped = true
            defer { cancels = [:] }
            return Array(cancels.values)
        }
        c.forEach { $0() }
    }

    /// Keeps `cancel` while a host call waits; a call already dropped is cancelled at once (nil token).
    func watch(_ cancel: @escaping @Sendable () -> Void) -> Int? {
        let token: Int? = lock.withLock {
            guard !dropped else { return nil }
            next += 1
            cancels[next] = cancel
            return next
        }
        if token == nil { cancel() }
        return token
    }

    func unwatch(_ token: Int?) { if let token { lock.withLock { _ = cancels.removeValue(forKey: token) } } }

    private static let key = "eu.illegible.prosper.laneCall"

    /// #1569 (v2.1 7.3): the host's fixed shim around an xref handler, defined again before each call (so an extension
    /// that replaced it gets it back). The handler gets the decoded table {text, parts, dir, session}; nil or an empty
    /// table is no card; any other non-table, or a throw, fails the card; a table goes back as JSON.
    static let shimName = "__prosper_xref"
    static let shim = """
        function __prosper_xref(name, s)
          local f = rawget(_G, name)
          if type(f) ~= "function" then error("the handler " .. tostring(name) .. " is not a function", 0) end
          local r = f(host.json.decode(s))
          if r == nil then return nil end
          if type(r) ~= "table" then error("the handler returned a " .. type(r) .. ", not a table", 0) end
          if next(r) == nil then return nil end
          return host.json.encode(r)
        end
        """
    /// The call the lane thread runs now (set by `with` around the handler; nil for every other lane call).
    static var current: LaneCall? { Thread.current.threadDictionary[key] as? LaneCall }

    static func with<T>(_ call: LaneCall?, _ body: () throws -> T) rethrows -> T {
        guard let call else { return try body() }
        Thread.current.threadDictionary[key] = call
        defer { Thread.current.threadDictionary[key] = nil }
        return try body()
    }
}

/// Discovers, validates, and routes to extensions. Static-first + lazy: every
/// manifest is parsed up front to build a `(trigger → extension id)` table, but
/// each extension's Lua VM is spawned only when one of its triggers fires.
/// See docs/ADR-002-extensibility.md.
@MainActor
final class ExtensionRegistry: ObservableObject {

    /// All discovered extensions, system first, in discovery order.
    @Published private(set) var records: [ExtensionRecord] = []

    /// #984: a folder the last discover() could not load: its name as shown (OutsideText) and the plain reason.
    struct RefusedFolder: Equatable, Sendable {
        let folder: String
        let reason: String
        let directory: URL
    }
    static let maxRefused = 20, refusedNameMax = 80
    /// #984: the first `maxRefused` folders the last discover() refused, in discovery order.
    @Published private(set) var refused: [RefusedFolder] = []

    private let systemDir: URL?
    private let userDir: URL
    /// Pristine copies of system extensions, used by `reset(id:)`.
    private let systemPristineDir: URL?
    private let hostVersion: String
    private let defaults: UserDefaults
    /// Native capabilities exposed to extensions via `host.*`.
    private let services: ExtensionHostServices
    private let callTimeout: TimeInterval
    /// Off-main VM lane for commands that call async host APIs (http/llm/shell).
    private let asyncRuntimes: AsyncExtensionRuntimes
    private let log = Logger(subsystem: "com.prosper.app", category: "extensions")

    /// #1146: instruction budgets for the Lua this registry runs on the MAIN thread (the MainActor VM). A spent
    /// call holds the UI for its whole budget: about 7 ms per million instructions of plain Lua, up to ~55 ms for
    /// allocation-heavy code (measured 2026-11; the 10,000,000 default was 74-550 ms). A call made from inside a
    /// host function runs on what is left of its outer call's budget (#1154). The event-tap dispatch has its own.
    enum MainThreadBudget {
        /// The VM's ceiling: the host bootstraps and the entry chunk when the VM is made (`run` takes no budget).
        static let load: Int32 = 500_000
        /// A command handler (invokeSync: the launcher's calc and units on each keystroke).
        static let command: Int32 = 500_000
        /// A bare function call (callExtensionString's default): snippet placeholders and the event-tap probe.
        /// Higher than a command because the probe runs a whole Hammerspoon config (~98 per binding line).
        static let call: Int32 = 1_000_000
    }

    private static let disabledKey = "disabledExtensionIDs"
    /// Turn-ONS for opt-in (`default_disabled`) extensions. The disabled set is the
    /// inverse default (everything on unless listed); opt-in flips it (everything off
    /// unless listed) so a brand-new opt-in extension stays inert until the user acts.
    private static let enabledKey = "enabledExtensionIDs"
    private static let trustedKey = "trustedExtensionIDs"
    private static let privilegedKey = "privilegedExtensionIDs"
    /// #726: "Allow on iPhone" — [extension id: phoneApprovalHash at approval].
    static let phoneApprovedKey = "phoneApprovedExtensions"

    /// Command routing: id → record, plus an ordered list carrying compiled
    /// `match` regexes for query-prefix dispatch.
    private var commandByID: [String: (record: ExtensionRecord, command: CommandContribution)] = [:]
    private var matchRoutes: [(regex: NSRegularExpression, command: CommandContribution, record: ExtensionRecord)] = []

    init(
        systemDir: URL? = ExtensionRegistry.bundledSystemDir,
        userDir: URL = ExtensionRegistry.defaultUserDir,
        hostVersion: String = ExtensionRegistry.bundleVersion,
        defaults: UserDefaults = Preferences.defaults,
        services: ExtensionHostServices = LiveExtensionHostServices.shared,
        callTimeout: TimeInterval = ExtensionHost.defaultCallTimeout
    ) {
        self.systemDir = systemDir
        self.systemPristineDir = systemDir
        self.userDir = userDir
        self.hostVersion = hostVersion
        self.defaults = defaults
        self.services = services
        self.callTimeout = callTimeout
        self.asyncRuntimes = AsyncExtensionRuntimes(services: services)
    }

    /// Bundled system-extensions directory. Lives in the app bundle's
    /// Contents/Resources (`Bundle.main`); scripts/bundle.sh copies it there.
    /// We deliberately do NOT use SwiftPM's `Bundle.module`: its generated
    /// accessor looks at the .app root, where a resource bundle can't be placed
    /// without breaking the code-signature seal (see Package.swift).
    static var bundledSystemDir: URL? {
        Bundle.main.url(forResource: "extensions", withExtension: nil)
    }

    static var defaultUserDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/prosper/extensions")
    }

    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
    }

    // MARK: - Discovery

    /// Seed system extensions from the pristine bundled dir into the editable
    /// userDir. A missing one is copied in. An existing one is refreshed only when
    /// the bundled copy has a NEWER manifest version — so shipped updates to a
    /// system extension (new commands, a runner-mode `prefix`, bug fixes) reach
    /// users on upgrade. User edits to a system extension therefore persist within
    /// a version and reset on a version bump; a user can still `reset(id:)` anytime.
    private func seedSystemExtensions() {
        guard let pristineRoot = systemPristineDir else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        guard let children = try? fm.contentsOfDirectory(
            at: pristineRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for child in children {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let dest = userDir.appendingPathComponent(child.lastPathComponent, isDirectory: true)
            // Development / unstamped bundles report host 0.0.0. There, ALWAYS
            // overwrite from the bundle — the source tree is the single source of
            // truth, and a stale seeded copy (an old init.lua left from a previous
            // build) would otherwise silently shadow local edits and waste hours.
            let isDevHost = SemanticVersion(hostVersion) == SemanticVersion("0.0.0")
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: child, to: dest)
            } else if isDevHost {
                try? stageAndSwap(child, into: dest, sweep: false)   // #1435: a failed copy leaves the old copy
            } else if let bundled = Self.manifestVersion(at: child),
                      let installed = Self.manifestVersion(at: dest),
                      installed < bundled {
                do {
                    try stageAndSwap(child, into: dest, sweep: false)
                    log.info("refreshed system extension \(child.lastPathComponent, privacy: .public) to newer bundled version")
                } catch {
                    log.error("could not refresh system extension \(child.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Reads just the `version` from an extension directory's `extension.toml`,
    /// without a full validating load (used by seeding to compare versions).
    /// Static and internal so ExtensionManifestVersionTests can call it without a registry;
    /// reads through `ExtensionLoader.readManifest` so an oversized file is never read whole (QA 787 F1).
    static func manifestVersion(at dir: URL) -> SemanticVersion? {
        let toml = dir.appendingPathComponent("extension.toml")
        guard let text = try? ExtensionLoader.readManifest(toml) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("version") else { continue }
            // version = "1.2.3"  → grab the quoted value
            guard let open = t.firstIndex(of: "\""),
                  let close = t[t.index(after: open)...].firstIndex(of: "\"") else { return nil }
            return SemanticVersion(String(t[t.index(after: open)..<close]))
        }
        return nil
    }

    /// The set of directory names that exist under the pristine system dir.
    private func systemFolderNames() -> Set<String> {
        guard let pristineRoot = systemPristineDir,
              let children = try? FileManager.default.contentsOfDirectory(
                at: pristineRoot, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return Set(children.compactMap { child -> String? in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            return child.lastPathComponent
        })
    }

    /// #1794: folder name -> id of a built-in that was seeded into userDir by an older release and no longer ships
    /// (Violet became Royal Purple; ThemeStore.renamedThemeIDs moves its users).
    static let retiredBuiltIns = ["theme-violet": "com.prosper.theme.violet"]

    /// #1246: bundled folder name -> the id its pristine copy declares. A pristine copy that does not load is left out.
    private func bundledIDsByFolder() -> [String: String] {
        guard let pristineRoot = systemPristineDir else { return [:] }
        var ids: [String: String] = [:]
        for name in systemFolderNames() {
            let dir = pristineRoot.appendingPathComponent(name, isDirectory: true)
            if let loaded = try? ExtensionLoader.load(directory: dir, isSystem: true, hostVersion: hostVersion) {
                ids[name] = loaded.id
            }
        }
        return ids
    }

    /// (Re)scan the editable userDir (after seeding from pristine), parse +
    /// validate manifests, and rebuild the routing table. Safe to call repeatedly.
    func discover() {
        recoverInstallLeftovers()   // before the seed: a built-in's own copy comes back before a refresh is weighed
        seedSystemExtensions()
        let bundledIDs = bundledIDsByFolder()

        var found: [ExtensionRecord] = []
        let disabled = disabledIDs()
        let optedIn = enabledIDs()
        var seen = Set<String>()

        // A missing/unreadable userDir = zero user extensions. Fall through (don't
        // early-return) so the grandfather marker below still gets seeded — else the
        // first discover after an install would see the key absent and auto-trust
        // that fresh install as if it were pre-existing (trust-gate bypass).
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: userDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        var loads: [LoadedExtension] = []
        var refusedFound: [RefusedFolder] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // #1430: an install's stage or replaced copy (a crash can leave one) is never an extension. Only these two
            // prefixes: a hand-made ".kit" folder still loads (#1246, ExtensionInstallIDCaseTests).
            guard !entry.lastPathComponent.hasPrefix(".stage-"), !entry.lastPathComponent.hasPrefix(".old-") else { continue }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            do {
                let loaded = try ExtensionLoader.load(
                    directory: entry, isSystem: false, hostVersion: hostVersion)
                // #1794: the seeded copy of a built-in that no longer ships stays on disk but never loads.
                if Self.retiredBuiltIns[entry.lastPathComponent] == loaded.id { continue }
                // #1246: a system record is a bundled folder holding the id its bundled copy declares, never a name alone.
                let isSystem = bundledIDs[entry.lastPathComponent] == loaded.id
                loads.append(isSystem ? LoadedExtension(manifest: loaded.manifest, directory: entry, isSystem: true) : loaded)
            } catch {
                log.error("failed to load extension at \(entry.path, privacy: .public): \(String(describing: error), privacy: .public)")
                if refusedFound.count < Self.maxRefused {
                    refusedFound.append(RefusedFolder(
                        folder: OutsideText.shown(entry.lastPathComponent, max: Self.refusedNameMax),
                        reason: (error as? LocalizedError)?.errorDescription ?? ExtensionLoadError.unreadableManifest,
                        directory: entry))
                }
            }
        }
        // #1246: a built-in's id stays the built-in's: a user folder declaring it is a duplicate whatever it sorts like.
        let builtInIDs = Set(loads.filter(\.isSystem).map(\.id))
        for loaded in loads {
            guard !seen.contains(loaded.id), loaded.isSystem || !builtInIDs.contains(loaded.id) else {
                log.warning("duplicate extension id \(loaded.id, privacy: .public), skipping \(loaded.directory.path, privacy: .public)")
                continue
            }
            seen.insert(loaded.id)
            if !loaded.isSystem {
                for w in (loaded.manifest.contributes?.phoneWarnings ?? []) + (loaded.manifest.contributes?.settingsSectionWarnings ?? []) {
                    log.warning("extension \(loaded.id, privacy: .public): \(w, privacy: .public)")
                }
            }
            // Opt-in extensions are off unless the user turned them on; everything
            // else is on unless the user turned it off.
            let isEnabled = loaded.manifest.extension.defaultDisabled
                ? optedIn.contains(loaded.id)
                : !disabled.contains(loaded.id)
            found.append(ExtensionRecord(loaded: loaded,
                                         enabled: isEnabled,
                                         trusted: false))
        }

        // Grandfather migration: on the FIRST run after the trust gate ships, every
        // already-installed user extension was implicitly trusted, so seed them all
        // as trusted (otherwise they'd silently go inert on upgrade). Absence of the
        // key — not an empty array — marks "never gated before".
        if defaults.object(forKey: Self.trustedKey) == nil {
            persistTrusted(Set(found.filter { !$0.isSystem }.map(\.id)))
        }
        let trusted = trustedIDs()
        // No grandfather migration for privilege: it must be an explicit opt-in, so
        // absence of the key = nothing privileged (only system extensions, via isSystem).
        let privileged = privilegedIDs()
        for record in found {
            record.trusted = record.isSystem || trusted.contains(record.id)
            // Privilege can never exceed trust: a non-system extension is privileged
            // only if BOTH trusted and explicitly granted. This is the invariant gate —
            // even if some path clears trust without clearing the privilege set, an
            // untrusted extension can never reach the system tier. (untrust/uninstall
            // still scrub the set so a later re-trust requires an explicit re-grant.)
            record.privileged = record.isSystem || (record.trusted && privileged.contains(record.id))
        }

        // #1542: before any extension runs, so a dotted key saved before the key change reads back.
        LiveExtensionHostServices.migrateDottedPrefKeys(ids: found.map(\.id), in: defaults)
        records = found
        refused = refusedFound
        dropStalePhoneApprovals()
        rebuildRoutes()
        asyncRuntimes.invalidateAll()   // drop stale off-main VMs on rescan
        disarmLegacyRemoteWake()
    }

    /// Live (enabled + trusted) state of the extensions whose behaviour runs natively
    /// on a per-keystroke path, cached so that path reads a Bool instead of scanning
    /// `records`: the runner's web-search rows (`fallbackRows`) and inline snippet
    /// expansion (`SnippetExpander`). Refreshed in `rebuildRoutes`, which every
    /// discover / enable / disable / trust change runs. False until `discover()`.
    private(set) var fallbackSearchLive = false
    private(set) var snippetsLive = false

    /// #1564 (X7): the live extensions' `[[contributes.xrefs]]` rules. Rebuilt with the routes, so discover (reload),
    /// enable, disable, trust and untrust each bump `rulesVersion`; an X-ray memo keyed on it never outlives a rule set.
    private(set) var xrefRules: [XrayExtensionRule] = []
    private(set) var rulesVersion = 0

    private func rebuildRoutes() {
        let xrefs = XrayExtensionRefs.compile(records.filter(\.isLive).map { ($0.id, $0.manifest.contributes?.xrefs) })
        for line in xrefs.refusals { log.warning("\(line, privacy: .public)") }
        xrefRules = xrefs.rules
        rulesVersion &+= 1
        fallbackSearchLive = record(id: FallbackSearchStore.extensionID)?.isLive ?? false
        snippetsLive = record(id: SnippetStore.extensionID)?.isLive ?? false
        cachedCommandEntries = nil   // live command set changed → drop discovery memo
        commandByID.removeAll(keepingCapacity: true)
        matchRoutes.removeAll(keepingCapacity: true)
        for record in records where record.isLive {
            // #1238: every path that makes an extension live again ends here; untrust and disable never do.
            asyncRuntimes.revive(id: record.id)
            for command in record.manifest.contributes?.allCommands ?? [] {
                commandByID[command.id] = (record, command)
                if let pattern = command.match,
                   let regex = try? NSRegularExpression(pattern: pattern) {
                    matchRoutes.append((regex, command, record))
                }
            }
        }
    }

    // MARK: - Routing

    /// Resolve a palette query to the first enabled extension command whose
    /// `match` regex accepts it. Pure lookup — does not spawn the Lua VM.
    ///
    /// HOT PATH (per keystroke). Budget: O(live routes) precompiled-regex matches,
    /// no allocations beyond one NSRange, no regex compilation (done once in
    /// `rebuildRoutes`), no trust/enabled checks (untrusted/disabled extensions are
    /// absent from `matchRoutes`). See `testRoutePerformance`: < 1ms over 200 routes.
    func route(query: String) -> (record: ExtensionRecord, command: CommandContribution)? {
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        for r in matchRoutes where r.regex.firstMatch(in: query, range: range) != nil {
            return (r.record, r.command)
        }
        return nil
    }

    func command(id: String) -> (record: ExtensionRecord, command: CommandContribution)? {
        commandByID[id]
    }

    /// All color themes contributed by live (enabled + trusted) extensions, as
    /// selector descriptors with their on-disk theme.json path. Pure manifest
    /// data — does not spawn any Lua VM. Feeds `ThemeStore.setAvailable`.
    func contributedThemes() -> [ThemeDescriptor] {
        var out: [ThemeDescriptor] = []
        for record in records where record.isLive {
            let dir = record.loaded.directory
            for t in record.manifest.contributes?.allThemes ?? [] {
                out.append(ThemeDescriptor(
                    id: t.id,
                    title: t.title,
                    appearance: ThemeAppearance(rawValue: t.appearance ?? "dark") ?? .dark,
                    extensionID: record.id,
                    jsonPath: dir.appending(path: t.path)))
            }
        }
        return out
    }

    /// Window-launching commands (manifest `launches_window`) discoverable by a
    /// PARTIAL query: a prefix of the title, id, or any keyword (case-insensitive).
    /// This is what lets "base" surface the Base64 command before the regex `match`
    /// verb is fully typed — general discovery for every launcher extension, not a
    /// base64 special case. Pure lookup; does not spawn the Lua VM. Title-prefix
    /// matches rank ahead of keyword-only matches.
    func launcherMatches(query: String) -> [CommandContribution] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var titleHits: [CommandContribution] = []
        var otherHits: [CommandContribution] = []
        for record in records where record.isLive {
            for command in record.manifest.contributes?.allCommands ?? []
            where command.launchesWindow {
                if command.title.lowercased().hasPrefix(q) {
                    titleHits.append(command)
                } else if ([command.id] + (command.keywords ?? []))
                    .contains(where: { $0.lowercased().hasPrefix(q) }) {
                    otherHits.append(command)
                }
            }
        }
        return titleHits + otherHits
    }

    /// A manifest-declared runner-mode trigger: the leading prefix that locks the
    /// universal launcher into an extension command, plus the chip label/icon.
    struct ModeTriggerSpec: Sendable, Equatable {
        let prefix: String
        let commandID: String
        let title: String
        let icon: String
        /// Display name of the contributing extension, used to disambiguate
        /// identically-titled commands in the shortcut target picker (e.g. several
        /// "Run Shell" commands → "Run Shell · gh-payhawk"). Empty for dynamic
        /// triggers whose titles are already unique (a quickdir's own name).
        var extensionTitle: String = ""
        /// Opaque argument carried into the locked mode (e.g. which quickdir a
        /// dynamic prefix selects). nil for ordinary manifest triggers.
        var arg: String? = nil
    }

    /// Provider of runtime mode triggers contributed by an extension from its own
    /// data (not the static manifest) — e.g. quickdirs giving each configured
    /// directory its own activation prefix. Set by the app; consulted live in
    /// `modeTriggers()` so edits take effect without a rescan.
    var dynamicModeProvider: (@MainActor () -> [ModeTriggerSpec])?

    /// Runner-mode triggers contributed by enabled extensions (manifest `prefix`)
    /// plus any dynamic triggers from `dynamicModeProvider`, longest-prefix-first
    /// so a more specific trigger wins over a shorter overlap. This is what lets
    /// extensions surface as labelled modes without host edits.
    func modeTriggers() -> [ModeTriggerSpec] {
        var out: [ModeTriggerSpec] = []
        for record in records where record.isLive {
            for command in record.manifest.contributes?.allCommands ?? [] {
                for prefix in command.allPrefixes where !prefix.isEmpty {
                    out.append(ModeTriggerSpec(
                        prefix: prefix,
                        commandID: command.id,
                        title: command.title,
                        icon: command.icon ?? "puzzlepiece.extension",
                        extensionTitle: record.manifest.extension.title))
                }
            }
        }
        // A dynamic trigger lives only while the command it locks into does: a
        // disabled Quickdirs drops every per-quickdir prefix with its `qd ` one.
        out.append(contentsOf: (dynamicModeProvider?() ?? []).filter { commandByID[$0.commandID] != nil })
        return out.sorted { $0.prefix.count > $1.prefix.count }
    }

    /// A live extension command, flattened for the launcher's discovery search.
    /// `haystack` is the precomputed lowercased text the scorer matches against —
    /// the command title, its keywords, AND the contributing extension's name +
    /// title — so typing an extension's name ("translate", "openlid") or any
    /// keyword ("lid", "awake") surfaces all of its commands as ranked rows, not
    /// just the ones whose `prefix`/`match` the user happens to remember.
    struct CommandSearchEntry: Sendable, Equatable {
        let commandID: String
        let title: String
        let icon: String
        let extensionTitle: String
        /// Opens its own window on select (vs entering an inline mode). The
        /// run-immediately-vs-wait-for-input choice for inline commands is re-read
        /// from the command (`runs_on_select`) in the runner, not carried here.
        let launchesWindow: Bool
        /// Lowercased match text (title + keywords + extension name/title).
        let haystack: String
        /// Tie-break length (command title), so a long keyword list doesn't sink it.
        let tieLen: Int
    }

    /// Built-in commands answered by dedicated `RunnerOutcome` cases — never
    /// surfaced as discovery rows (you don't "open" the calc engine) and never
    /// re-dispatched by the generic extension step. Single source of truth shared
    /// with `CommandRouter`'s generic-dispatch guard.
    nonisolated static let dedicatedCommandIDs: Set<String> =
        ["calc.eval", "unit.convert", "currency.convert"]

    /// All live extension commands flattened for the discovery search (see
    /// `CommandSearchEntry`). Pure manifest data — no Lua VM. Called on the
    /// per-keystroke launcher hot path; cost is O(commands) over a handful of
    /// dozen commands (string joins precomputed here), negligible next to the
    /// app-name scan it rides alongside.
    /// Memoized: the result only changes when the live command set does, and every
    /// such mutation routes through `rebuildRoutes()` (discover/enable/trust/…),
    /// which drops the cache. So per-keystroke calls are an O(1) hit after the
    /// first build — no repeated string-join + lowercase allocation on the main
    /// actor. Measured: 300 commands rebuild in ~0.3ms (debug); cache hit is free.
    private var cachedCommandEntries: [CommandSearchEntry]?
    func commandSearchEntries() -> [CommandSearchEntry] {
        if let cachedCommandEntries { return cachedCommandEntries }
        var out: [CommandSearchEntry] = []
        for record in records where record.isLive {
            let ext = record.manifest.extension
            for command in record.manifest.contributes?.allCommands ?? []
            where !Self.dedicatedCommandIDs.contains(command.id) {
                let parts = [command.title]
                    + (command.keywords ?? [])
                    + [ext.title, ext.name]
                out.append(CommandSearchEntry(
                    commandID: command.id,
                    title: command.title,
                    icon: command.icon ?? "puzzlepiece.extension",
                    extensionTitle: ext.title,
                    launchesWindow: command.launchesWindow,
                    haystack: parts.joined(separator: " ").lowercased(),
                    tieLen: command.title.count))
            }
        }
        cachedCommandEntries = out
        return out
    }

    /// Resolves a custom dynamic placeholder `{name …}` contributed by an enabled
    /// extension (manifest `[[contributes.placeholders]]`). Invokes the declared
    /// Lua handler synchronously with the raw token body and returns its string,
    /// or nil when no enabled extension contributes `name`. Used by the snippet
    /// engine; resolution happens only when a snippet actually uses the placeholder
    /// (never on the per-keystroke hot path).
    /// #1176, the bound of one lookup: each handler runs on its own call budget (activation first: three load budgets, one each for the
    /// two host bootstraps and the entry chunk, a fixed count), so a lookup costs at most 3 x load + call per live extension that declares `name`, wherever it sits in the order.
    func resolvePlaceholder(name: String, raw: String) -> String? {
        let lower = name.lowercased()
        for record in records where record.isLive {
            for p in record.manifest.contributes?.allPlaceholders ?? []
            where p.name.lowercased() == lower {
                if let value = callExtensionString(extensionID: record.id, function: p.handler, arg: raw) {
                    return value
                }
            }
        }
        return nil
    }

    /// Lua handler global for a command id: non-alphanumerics → '_'
    /// ("calc.eval" → "calc_eval"). See Resources/extensions/*/init.lua.
    static func handlerName(for commandID: String) -> String {
        String(commandID.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
    }

    /// Invoke a command's Lua handler synchronously, returning its string result
    /// or nil to decline (caller falls back to native / next command).
    ///
    /// SYNCHRONOUS — safe only for commands that do NOT call async host APIs
    /// (calc/unit/base64/emoji/meta). Commands that call `host.llm`/`host.shell`
    /// must use the off-main async lane so the bridge cannot block the caller.
    func invokeSync(commandID: String, query: String) -> String? {
        guard let (record, command) = command(id: commandID), record.isLive else { return nil }
        do {
            let rt = try activate(record)
            let result = try rt.callGlobal(Self.handlerName(for: command.id), [query], budget: MainThreadBudget.command)
            if result != nil, record.isSystem { AnalyticsStore.bumpUsage(extensionID: record.id) }
            return result
        } catch {
            log.error("extension \(record.id, privacy: .public) command \(command.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Invoke a command's Lua handler on the OFF-MAIN async lane, returning its
    /// string result or nil to decline. Use this for commands that call async
    /// host APIs (`host.http` / `host.llm` / `host.shell`) — the bridge blocks
    /// its worker thread, which must never be the main thread. The async lane
    /// keeps a separate VM cache (see `AsyncExtensionRuntimes`).
    func invokeAsync(commandID: String, query: String) async -> String? {
        guard let (record, command) = command(id: commandID) else { return nil }
        return await invokeAsync(record, command, query: query)
    }

    /// #726: `record`'s own `command`, never through the last-writer-wins route table, so
    /// another extension declaring the same command id can't stand in for it.
    func invokeAsync(_ record: ExtensionRecord, _ command: CommandContribution, query: String) async -> String? {
        guard record.isLive else { return nil }
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id,
            entryURL: record.loaded.entryURL,
            handler: Self.handlerName(for: command.id),
            callTimeout: callTimeout,
            privileged: record.privileged, trusted: record.trusted,
            configOwner: record.loaded.managedConfigOwner
        )
        let result = await asyncRuntimes.invoke(spec, args: [query])
        if result != nil, record.isSystem { AnalyticsStore.bumpUsage(extensionID: record.id) }
        return result
    }

    /// Render a `mode = "view"` command on the OFF-MAIN async lane (for views
    /// that call async host APIs). #1170: the only view render; the synchronous twin had no caller.
    func renderViewAsync(commandID: String, query: String = "") async -> ExtensionViewNode? {
        guard let (_, command) = command(id: commandID), command.mode == .view else { return nil }
        guard let json = await invokeAsync(commandID: commandID, query: query) else { return nil }
        do {
            return try ExtensionViewNode.decode(json: json)
        } catch {
            log.error("view \(commandID, privacy: .public) returned invalid JSON: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Dispatch a UI action on the OFF-MAIN async lane. The handler may call
    /// async host APIs (http/llm/shell); the panel shows a spinner meanwhile.
    func dispatchActionAsync(
        commandID: String, actionID: String, value: String?, formValues: [String: String]
    ) async -> ExtensionViewNode? {
        guard let (record, command) = command(id: commandID), record.isLive else { return nil }
        let formJSON = (try? JSONEncoder().encode(formValues))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id,
            entryURL: record.loaded.entryURL,
            handler: Self.handlerName(for: command.id) + "_action",
            callTimeout: callTimeout,
            privileged: record.privileged, trusted: record.trusted,
            configOwner: record.loaded.managedConfigOwner
        )
        guard let json = await asyncRuntimes.invoke(spec, args: [actionID, value ?? "", formJSON]) else { return nil }
        return try? ExtensionViewNode.decode(json: json)
    }

    // MARK: - Settings sections (declarative settings UI)

    /// (record, section) for every enabled extension section with `placement`
    /// ("sidebar" | "inline"). Pure lookup; does not spawn a VM.
    func settingsSections(placement: String) -> [(record: ExtensionRecord, section: SettingsSection)] {
        var out: [(ExtensionRecord, SettingsSection)] = []
        for record in records where record.isLive {
            for section in record.manifest.contributes?.allSettingsSections ?? []
            where (section.placement ?? "sidebar") == placement {
                out.append((record, section))
            }
        }
        return out
    }

    /// #918 S5: the enabled kits (a `[contributes.kit]` table), trusted or not, in the registry's order: one Settings tab each.
    var kitRecords: [ExtensionRecord] { records.filter { $0.enabled && $0.manifest.contributes?.kit != nil } }

    /// Locate a specific (record, section) by ids.
    func settingsSection(extensionID: String, sectionID: String) -> (ExtensionRecord, SettingsSection)? {
        guard let record = record(id: extensionID), record.isLive else { return nil }
        guard let section = (record.manifest.contributes?.allSettingsSections ?? [])
            .first(where: { $0.id == sectionID }) else { return nil }
        return (record, section)
    }

    /// Tier B: render a dynamic section via the extension's `settings_render`
    /// handler on the async lane. Returns the decoded tree, or nil.
    func renderSettingsAsync(extensionID: String, sectionID: String,
                             state: String = "{}") async -> SettingsUI? {
        guard let record = record(id: extensionID), record.isLive else { return nil }
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id, entryURL: record.loaded.entryURL,
            handler: "settings_render", callTimeout: callTimeout, privileged: record.privileged, trusted: record.trusted,
            configOwner: record.loaded.managedConfigOwner)
        guard let json = await asyncRuntimes.invoke(spec, args: [sectionID, state]) else { return nil }
        return try? SettingsUI.decode(json: json)
    }

    /// Tier B: dispatch a settings interaction to `settings_action`; returns the
    /// next tree (nil → caller keeps the current one / re-renders).
    func dispatchSettingsActionAsync(extensionID: String, sectionID: String,
                                     actionID: String, value: String?,
                                     formValues: [String: String]) async -> SettingsUI? {
        guard let record = record(id: extensionID), record.isLive else { return nil }
        let formJSON = (try? JSONEncoder().encode(formValues))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id, entryURL: record.loaded.entryURL,
            handler: "settings_action", callTimeout: callTimeout, privileged: record.privileged, trusted: record.trusted,
            configOwner: record.loaded.managedConfigOwner)
        guard let json = await asyncRuntimes.invoke(
            spec, args: [sectionID, actionID, value ?? "", formJSON]) else { return nil }
        return try? SettingsUI.decode(json: json)
    }

    // MARK: - Host-window callbacks (host.window.open)

    /// Call a bare global Lua function `function(arg)` in an extension's MainActor
    /// VM and return its string result. Powers `converter` panes opened via
    /// `host.window.open`: each keystroke runs the declared forward/backward
    /// transform synchronously (cheap, on-device string work — base64, hex, …).
    /// Returns nil to decline (missing extension / error), which the UI treats as
    /// an empty pane.
    func callExtensionString(extensionID: String, function: String, arg: String,
                             budget: Int32 = MainThreadBudget.call) -> String? {
        guard let record = record(id: extensionID), record.isLive else { return nil }
        do {
            let rt = try activate(record)
            return try rt.callGlobal(function, [arg], budget: budget)
        } catch {
            log.error("window fn \(function, privacy: .public) on \(extensionID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Call a global Lua function in an extension on the OFF-MAIN async lane and
    /// decode its result as a component tree (for host-window button actions that
    /// may touch async host APIs). Returns nil to decline / on bad JSON.
    func callExtensionViewAsync(extensionID: String, function: String, args: [String]) async -> ExtensionViewNode? {
        guard let record = record(id: extensionID), record.isLive else { return nil }
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id,
            entryURL: record.loaded.entryURL,
            handler: function,
            callTimeout: callTimeout,
            privileged: record.privileged, trusted: record.trusted,
            configOwner: record.loaded.managedConfigOwner
        )
        guard let json = await asyncRuntimes.invoke(spec, args: args) else { return nil }
        return try? ExtensionViewNode.decode(json: json)
    }

    /// Call a global Lua function on the OFF-MAIN async lane and return its RAW
    /// string result (no view decoding). Used by the unified launcher search to
    /// pull ranked bookmark rows as JSON without building a component tree.
    func callExtensionStringAsync(extensionID: String, function: String, args: [String]) async -> String? {
        guard let record = record(id: extensionID), record.isLive else { return nil }
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id,
            entryURL: record.loaded.entryURL,
            handler: function,
            callTimeout: callTimeout,
            privileged: record.privileged, trusted: record.trusted,
            configOwner: record.loaded.managedConfigOwner
        )
        return await asyncRuntimes.invoke(spec, args: args)
    }

    /// #1569 (X7 c, v2.1 7.3): an xref rule's handler on its extension's lane, `arg` its one JSON string argument.
    /// The handler's string (its JSON result) or nil: no handler, not live, dropped, failed (`call.failed`), or nil.
    func callXref(_ rule: XrayExtensionRule, arg: String, call: LaneCall) async -> String? {
        guard let handler = rule.handler, let record = record(id: rule.extensionID), record.isLive else { return nil }
        var spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id, entryURL: record.loaded.entryURL, handler: handler, callTimeout: callTimeout,
            privileged: record.privileged, trusted: record.trusted, configOwner: record.loaded.managedConfigOwner)
        spec.lane = call
        return await asyncRuntimes.invoke(spec, args: [arg])
    }

    // MARK: - Native events (stateless per-event handler delivery)

    /// Deliver a native event to a named Lua handler on the OFF-MAIN async lane.
    /// That lane is a single serial queue, so deliveries to a given extension are
    /// serialized (host-enforced single-flight — the one invariant the stateless
    /// model needs so per-event load-modify-write on `host.prefs` can't race).
    /// `payloadJSON` is the event arg the handler decodes via `host.json`.
    func deliverEvent(extensionID: String, handler: String, payloadJSON: String, fsWatch: FSWatchRun? = nil) async {
        guard let record = record(id: extensionID), record.isLive else { return }
        let spec = AsyncExtensionRuntimes.Spec(
            extensionID: record.id, entryURL: record.loaded.entryURL,
            handler: handler, callTimeout: callTimeout, privileged: record.privileged, trusted: record.trusted,
            configOwner: record.loaded.managedConfigOwner, fsWatch: fsWatch)
        _ = await asyncRuntimes.invoke(spec, args: [payloadJSON])
    }

    /// (extensionID, handler) for every enabled extension subscribing to `event`
    /// via `[[contributes.events]]`. Pure lookup; does not spawn a VM.
    func eventSubscribers(_ event: String) -> [(extensionID: String, handler: String)] {
        var out: [(String, String)] = []
        for record in records where record.isLive {
            for sub in record.manifest.contributes?.allEvents ?? [] where sub.event == event {
                out.append((record.id, sub.handler))
            }
        }
        return out
    }

    /// Broadcast a native event (battery/network/wake/lid/app/url) to every
    /// subscriber. Each delivery is serialized per extension by the async lane.
    func broadcastEvent(_ event: String, payloadJSON: String = "{}") {
        for sub in eventSubscribers(event) {
            Task { await self.deliverEvent(extensionID: sub.extensionID,
                                           handler: sub.handler, payloadJSON: payloadJSON) }
        }
    }

    /// True when any enabled extension subscribes to `event` — lets native watchers
    /// stay dormant until something actually wants the event.
    func hasSubscribers(_ event: String) -> Bool {
        for record in records where record.isLive {
            if (record.manifest.contributes?.allEvents ?? []).contains(where: { $0.event == event }) {
                return true
            }
        }
        return false
    }

    // MARK: - Lazy activation

    /// Return the extension's runtime, creating + loading its entry script on
    /// first use. Host API wiring is layered on in task #22.
    func activate(_ record: ExtensionRecord) throws -> LuaRuntime {
        // Single chokepoint: never spawn a VM for an untrusted extension, even if a
        // caller reached here without going through the routing table.
        guard record.trusted else { throw ExtensionError.untrusted(record.id) }
        if let rt = record.runtime { return rt }
        let rt = try LuaRuntime(maxInstructions: MainThreadBudget.load, allowLoad: record.isSystem || record.trusted)
        try ExtensionHost(extensionID: record.id, services: services, callTimeout: callTimeout,
                          privileged: record.privileged, trusted: record.trusted,
                          configOwner: record.loaded.managedConfigOwner)
            .install(into: rt)
        let source = try BoundedFileRead.text(record.loaded.entryURL, maxBytes: BoundedFileRead.entryLuaMaxBytes)
        try rt.run(source, name: "@\(record.id)")
        record.runtime = rt
        return rt
    }

    // MARK: - Management

    func record(id: String) -> ExtensionRecord? { records.first { $0.id == id } }

    // MARK: - Resident event-tap VM support (EventTapHost)

    /// True if the extension opted into a resident keystroke-path VM via
    /// `[extension.host] event_taps = true`. Pure manifest read.
    func manifestDeclaresEventTaps(_ id: String) -> Bool {
        record(id: id)?.manifest.extension.host.event_taps == true
    }

    /// Live extensions that opted into resident event-tap VMs. Almost always 0 or 1
    /// (the hammerspoon-compat shim). Order is records order (deterministic).
    func eventTapExtensionIDs() -> [String] {
        records.filter { $0.isLive && $0.manifest.extension.host.event_taps == true }.map(\.id)
    }

    /// Drop an extension's resident VM to free its lua_State + memory. The next
    /// call re-activates lazily. Used by EventTapHost when an ext stops needing
    /// its event-tap VM (disabled, or its config registers no running tap).
    func deactivateRuntime(_ id: String) {
        record(id: id)?.runtime = nil
    }

    /// Fired after an extension's enabled state changes, so the host can reconcile
    /// side effects — notably model residency (an LLM extension toggling on/off
    /// changes whether the local model must stay loaded). Set by AppDelegate.
    var onEnabledChanged: (@MainActor () -> Void)?

    /// Drop everything an extension left running in the host: its VM (both lanes),
    /// durable timers, and the native resources it registered — power assertions,
    /// menubar items, FS watches, and KEY RULES. The key rules matter most: the
    /// shared tap swallows a matched chord in its hot path and only then dispatches
    /// to the (now gone) extension, so a lingering rule silently eats the keystroke
    /// system-wide until relaunch — e.g. pasteplain's opt-in ⌘V would stop pasting
    /// anything at all. Shared by disable, uninstall, reset and untrust so none can drift.
    private func teardown(_ record: ExtensionRecord) {
        record.runtime = nil
        // #930: retire FIRST: an in-flight call that returns after this sweeps again,
        // one that returned before it took its resources before the release below.
        asyncRuntimes.retire(id: record.id)         // the off-main twin, and its in-flight calls
        TimerScheduler.shared.cancelAll(extID: record.id)
        services.resetResources(extensionID: record.id)
    }

    func setEnabled(_ enabled: Bool, id: String) throws {
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        let wasEnabled = record.enabled
        record.enabled = enabled
        if !enabled { teardown(record); ManagedConfigRefresh.current?.declared[id] = nil } // #1232 r2: a disabled one declares nothing
        asyncRuntimes.invalidate(id: id)        // re-enable drops the stale twin too
        persistDisabled()
        persistEnabled()
        rebuildRoutes()
        objectWillChange.send()
        onEnabledChanged?()
        // #930: disable tore down the extension's assertions, timers, menubar items and
        // key rules, and only its system.launch handler restores them (openlid's
        // "kept awake" state, pasteplain's rules). Replay that one-shot to this
        // extension alone; deliverEvent skips it unless it is live (trusted too).
        if enabled && !wasEnabled { replayLaunch(id: id) }
        if !enabled && wasEnabled && id == Self.openLidID { suspendRemoteWake(id: id) }
    }

    static let openLidID = "com.prosper.openlid"
    static let openLidLegacyDisarmKey = "openLidLegacyRemoteWakeDisarmed"

    /// #1541: an OpenLid turned off before #1072 never disarmed Remote Wake, and the helper keeps it across
    /// restarts. The first discover with OpenLid off disarms once through the #1072 path; the marker (set by the
    /// first check whatever the state, since a later turn-off disarms itself) keeps later launches and rescans quiet.
    private func disarmLegacyRemoteWake() {
        guard defaults.object(forKey: Self.openLidLegacyDisarmKey) == nil,
              let openLid = record(id: Self.openLidID) else { return }
        defaults.set(true, forKey: Self.openLidLegacyDisarmKey)
        if !openLid.enabled { suspendRemoteWake(id: openLid.id) }
    }

    /// #1072: Remote Wake outlives quit by design, so no teardown disarms it; turning OpenLid off does,
    /// only when its saved setting (openlid's `remote_wake` pref, kept as is) has it on. Re-enable needs
    /// nothing here: the launch replay above runs openlid's on_launch, which re-arms it from that setting.
    /// The same serial chain as the extension's own calls, so a queued arm cannot land after this disarm.
    private func suspendRemoteWake(id: String) {
        guard services.prefGet(extensionID: id, key: "remote_wake") == "true" else { return }
        let host = services
        let device = host.prefGet(extensionID: id, key: "rw_device_id") ?? ""
        // shortcut: cadence is the host's defaults (unused by a disarm; only the off meta report carries it).
        LidSleepHelper.enqueueApply {
            await host.caffeinateSetRemoteWake(extensionID: id, enabled: false, deviceID: device,
                                                   intervalAC: 60, intervalBatt: 300, batteryFloor: 20)
        }
    }

    /// #930/#1038: re-run `id`'s system.launch handler after a teardown that leaves it live (re-enable, reset).
    /// Each delivery is a main-actor Task that queues on the extension's lane, so it runs after a call still
    /// running there and after that call's late release. A disabled or untrusted extension gets nothing.
    private func replayLaunch(id: String) {
        guard record(id: id)?.isLive == true else { return }
        for sub in record(id: id)?.manifest.contributes?.allEvents ?? [] where sub.event == "system.launch" {
            Task { await self.deliverEvent(extensionID: id, handler: sub.handler, payloadJSON: "{}") }
        }
    }

    /// #870: the managed-config core, set by AppDelegate. nil (tests that do not exercise it) skips
    /// the uninstall hook.
    var managedConfig: ManagedConfigProvider?

    /// Uninstall a user extension. System extensions cannot be uninstalled
    /// (only disabled) — see ADR-002 system-extension semantics.
    /// #870 (spec 2.7): an extension with managed-config pieces goes through the Remove sheet first;
    /// declined, refused or failed = the uninstall stops and the dir is kept.
    func uninstall(id: String) async throws {
        guard let first = record(id: id) else { throw ExtensionError.notFound(id) }
        guard !first.isSystem else { throw ExtensionError.cannotUninstallSystem(id) }
        var left: String?
        if let provider = managedConfig {
            // #1232: the pieces the extension last declared (host.config.status), read on main while its folder is here
            // r2 (F1232-2): a disabled extension makes no status calls, so a declaration of it is stale: none is passed
            let declared = first.enabled ? (ManagedConfigRefresh.current?.declared[id] ?? []) : []
            let outcome = await Self.removeManagedPieces(owner: first.loaded.managedConfigOwner, declared: declared, provider: provider)
            if let kept = outcome.stop { throw ExtensionError.managedConfigKept(id: id, reason: kept) }
            left = outcome.left
            ManagedConfigRefresh.current?.declared[id] = nil // r2: dropped with the uninstall (a reinstall starts with none)
            ManagedConfigRefresh.current?.rescan()
        }
        // re-read after the await: the record list may have been rebuilt meanwhile
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        guard !record.isSystem else { throw ExtensionError.cannotUninstallSystem(id) }
        // Drop any granted system-tier privilege so a different extension reinstalled
        // later under the SAME id can never inherit RCE access without an explicit
        // re-grant. (In-place upgrades go through installLocal's overwrite, not here,
        // so an update of a privileged extension keeps its privilege.)
        clearPrivilege(id: id)
        setPhoneApproved(false, id: id)
        // Same teardown as disabling. `discover()` below only rebuilds the record
        // list — it does not reach into the host, so without this an uninstalled
        // extension's key rules, menubar items, watches and timers all outlive it.
        teardown(record)
        try FileManager.default.removeItem(at: record.loaded.directory)
        discover()
        // OQ-144 (b): said after the uninstall, in Extensions settings; the newest last, at most maxUninstallNotices
        if let left { uninstallNotices = Array((uninstallNotices + [left]).suffix(Self.maxUninstallNotices)) }
    }

    /// OQ-144: what an uninstall left in a person's file (blocks Prosper had no record of), shown in Extensions settings
    /// until dismissed.
    @Published private(set) var uninstallNotices: [String] = []
    static let maxUninstallNotices = 5
    func dismissUninstallNotice(at index: Int) {
        if uninstallNotices.indices.contains(index) { uninstallNotices.remove(at: index) }
    }

    /// `stop` nil: nothing of `owner` that Prosper has a record of is left in the managed config; otherwise why the
    /// uninstall stops. `left`: the notice for the unrecorded blocks it leaves in the file (OQ-144), nil when none.
    /// Runs off the main actor (status and remove take the write lock, A-INFO-13); only the
    /// consent sheet hops to main.
    /// r2 (R2-1): a provider that cannot resolve (slow or fish login shell, relative
    /// CLAUDE_CONFIG_DIR) stops only an owner the state has records for.
    /// #1232: a declared block of the owner with no record (lost, edited or not) is one Remove cannot take.
    /// r2 (F1232-1): status with the declared pieces first adopts a byte-equal block (a record in Prosper's own state
    /// file, as the extension's status call does), so only the edited ones are left; at most five are named.
    /// OQ-144 (b): an edited one no longer stops the uninstall: it is left in the file untouched and named afterwards.
    nonisolated static func removeManagedPieces(owner: ManagedConfigOwner, declared: [ManagedConfigPiece] = [],
                                                provider: ManagedConfigProvider) async -> (stop: String?, left: String?) {
        let config: ManagedConfig
        switch await provider.resolve() {
        case .failure(let why):
            guard let state = provider.stateOnly() else { return (why.description, nil) }
            guard state.stateIsReadable() else { return (ManagedConfigRefusalReason.stateUnreadable.description, nil) }
            return (state.ownerIDs().contains(owner.id) ? "Its config changes cannot be removed now: \(why.description)" : nil, nil)
        case .success(let c): config = c
        }
        guard config.stateIsReadable() else { return (ManagedConfigRefusalReason.stateUnreadable.description, nil) }
        if !declared.isEmpty { _ = config.status(owner: owner, declared: declared) } // the adopt; writes state.json only
        let recorded = config.status(owner: owner) // recomputed: the adopted ones are recorded now
        var left: String?
        let blocks = declared.filter { p in p.kind == .block && !recorded.contains { $0.id == p.id } }
        if !blocks.isEmpty {
            let plan = config.plan(blocks, owner: owner) // adopt: byte-equal, drifted: edited; both on disk with no record
            let named = blocks.filter { p in
                plan.actions.contains { $0.id == p.id && $0.action == .adopt } || plan.refusals.contains { $0.pieceID == p.id && $0.reason == .drifted }
            }
            if !named.isEmpty { left = leftNotice(extensionID: owner.id, named) }
        }
        guard !recorded.isEmpty else { return (nil, left) }
        // #1244: a block with broken markers is forgotten (its file left as it is) after a sheet that says so, not refused
        let result = await config.uninstall(owner: owner)
        if result.ok { return (nil, left) }
        return (result.status == .denied ? "Remove was cancelled: the extension and its config stay" : result.message, nil)
    }

    /// OQ-144: the after-uninstall notice: one name per block (id and target, as the stop named them), at most five,
    /// then "and n more"; the extension id cleaned and cut at 80 as a refused folder's name (refusedNameMax, main-isolated).
    nonisolated static func leftNotice(extensionID: String, _ blocks: [ManagedConfigPiece]) -> String {
        let names = blocks.map { "\($0.id) in \(String(reflecting: $0.target))" }
        return "Uninstalled \(OutsideText.shown(extensionID, max: 80)). Prosper had no record of these blocks of it, "
            + "so they were left in the file as they are: "
            + names.prefix(5).joined(separator: ", ") + (names.count > 5 ? " and \(names.count - 5) more" : "")
            + ". To remove one, delete it from the file yourself; to keep its text as your own, delete only its two prosper marker lines."
    }

    /// Install (or upgrade) a user extension by copying a validated source
    /// directory into the user extensions dir. The source must contain an
    /// `extension.toml`; it is validated against the host before any copy.
    /// #1704: `review` answers the new-permissions question (nil: `reviewNewPermissions`, the person's alert); the daily
    /// update check passes a quiet decline.
    /// #1866 n185: `admit` sees the candidate right after its load, before anything on disk changes; a throw refuses it.
    @discardableResult
    func installLocal(from sourceDir: URL, review: PermissionReview? = nil, admit: Admit? = nil) throws -> ExtensionRecord {
        // Validate first so a bad download never lands in the extensions dir.
        let loaded = try ExtensionLoader.load(
            directory: sourceDir, isSystem: false, hostVersion: hostVersion)
        try admit?(loaded)
        // A remote extension cannot masquerade as a bundled system one.
        guard !loaded.manifest.extension.isSystem else {
            throw ExtensionError.cannotUninstallSystem(loaded.id)
        }
        // #1246: the id names the destination folder: an unsafe or built-in id is refused before anything on disk changes.
        if let why = ExtensionInstallID.refusal(loaded.id, bundledFolders: systemFolderNames(),
                                                bundledIDs: Set(bundledIDsByFolder().values)) {
            throw ExtensionInstallID.Refused(reason: why)
        }
        // R1246-b: an installed folder whose name differs only by case is not this id's: refused before any disk change.
        // No extensions folder yet: nothing to replace. One that exists but cannot be listed: refused.
        let installedNames = (try? FileManager.default.contentsOfDirectory(atPath: userDir.path))
            ?? (FileManager.default.fileExists(atPath: userDir.path) ? nil : [])
        let occupied = FileManager.default.fileExists(
            atPath: userDir.appendingPathComponent(loaded.id, isDirectory: true).path)
        if let why = ExtensionInstallID.caseRefusal(loaded.id, installed: installedNames, occupied: occupied) {
            throw ExtensionInstallID.Refused(reason: why)
        }
        // #1704 (OQ-191): an update over a trusted extension of the same kind (a kind change drops trust, #1495) that declares
        // a permission the installed version lacks is reviewed before anything is copied; declined: nothing on disk changes.
        if let old = record(id: loaded.id), old.trusted,
           (old.manifest.contributes?.kit != nil) == (loaded.manifest.contributes?.kit != nil) {
            let had = Set(old.manifest.extension.declaredPermissions)
            let added = loaded.manifest.extension.declaredPermissions.filter { !had.contains($0) }
            if !added.isEmpty, !(review ?? reviewNewPermissions)(loaded.manifest.extension.title, added) {
                throw ExtensionError.newPermissionsDeclined(id: OutsideText.shown(loaded.id), added: added)
            }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        // Use the extension id as the on-disk folder name (stable across renames).
        let dest = userDir.appendingPathComponent(loaded.id, isDirectory: true)
        try stageAndSwap(sourceDir, into: dest, sweep: true)
        // #1241: an install over an installed id tears the old code down as reset does: after the copy, so a failed
        // copy changes nothing, and before discover. Enabled, trusted and privileged stay (discover reads them by id).
        let old = record(id: loaded.id)
        if let old { teardown(old) }
        // #1495: an id that changes kind (kit or not) in either direction does not inherit trust or privilege: same
        // store calls as untrust, before discover reads them.
        if let old, (old.loaded.manifest.contributes?.kit != nil) != (loaded.manifest.contributes?.kit != nil) {
            try untrust(id: loaded.id)
        }
        discover()
        guard let record = record(id: loaded.id) else { throw ExtensionError.notFound(loaded.id) }
        refusedUpdates.release(id: loaded.id)   // #1704: an installed update no longer waits for review
        if old != nil {
            onEnabledChanged?()   // as reset: the new manifest's shortcuts, themes and live flags
            replayLaunch(id: loaded.id)   // as a re-enable: only the launch handler re-takes what the teardown released
        }
        return record
    }

    /// #1704 (OQ-191): the review an update over a trusted extension gets when it declares new permissions (the title and
    /// the added names, both outside data); true installs. Rows pass a recorder.
    typealias PermissionReview = @MainActor (_ title: String, _ added: [String]) -> Bool
    /// #1866 n185: a caller's own check of the loaded candidate (ctl kits.install: a kit, not installed yet, the switch on).
    typealias Admit = @MainActor (LoadedExtension) throws -> Void
    var reviewNewPermissions: PermissionReview = { ExtensionRegistry.newPermissionsAlert(title: $0, added: $1) }

    /// The app's review: a modal alert naming the added permissions, only ever after a person's click (Prosper is in front
    /// then, so it does not activate itself). Under XCTest it declines without showing anything.
    static func newPermissionsAlert(title: String, added: [String]) -> Bool {
        guard NSClassFromString("XCTestCase") == nil else { return false }
        let names = added.prefix(10).map { OutsideText.shown($0, max: 64) }
        let alert = NSAlert()
        alert.messageText = "\(OutsideText.shown(title, max: 120)) asks for new permissions"
        alert.informativeText = "This update asks for: " + names.joined(separator: ", ")
            + (added.count > 10 ? " and \(added.count - 10) more" : "")
            + ". Allow them and update? If not, the installed version stays as it is."
        alert.addButton(withTitle: "Allow and Update")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// #1430: the folder copy install and reset use; a row swaps in a failing one.
    var copyFolder: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    /// #1435: every rename stageAndSwap makes; a row fails the final one to see the old folder moved back.
    var moveItem: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }

    /// #1430: copies `source` into a dot-named stage beside `dest` (same folder, so the same volume), sweeps it when
    /// asked, then renames it into place. A failed copy or sweep removes only the stage: the installed folder stays.
    /// An existing `dest` is renamed aside first and removed once the stage is in; a failed rename puts it back.
    private func stageAndSwap(_ source: URL, into dest: URL, sweep: Bool) throws {
        let fm = FileManager.default
        let parent = dest.deletingLastPathComponent()
        let stage = parent.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        do {
            try copyFolder(source, stage)
            // #1435: a copy keeps the source's date; the stage's own date is now, so another instance's sweep sees it fresh.
            // Only a real folder: a source given as a link is copied as that link, and setting its date would reach the source.
            if (try? fm.attributesOfItem(atPath: stage.path))?[.type] as? FileAttributeType == .typeDirectory {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: stage.path)
            }
            // #1142: the copy leaves out hidden files and folders by the publish rule. A source
            // given as a link is copied as that link: never swept, it is the source folder itself.
            if sweep, try fm.attributesOfItem(atPath: stage.path)[.type] as? FileAttributeType == .typeDirectory {
                try RemoteInstaller.removeHiddenMembers(stage)
            }
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
        guard fm.fileExists(atPath: dest.path) else {
            do { try moveItem(stage, dest) } catch { try? fm.removeItem(at: stage); throw error }
            return
        }
        // #1435: the aside carries dest's folder name, so discover can move a crash-left one back.
        let aside = parent.appendingPathComponent(".old-\(dest.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
        do { try moveItem(dest, aside) } catch { try? fm.removeItem(at: stage); throw error }
        do {
            try moveItem(stage, dest)
        } catch {
            try? moveItem(aside, dest)
            try? fm.removeItem(at: stage)
            throw error
        }
        // Not thrown: the new folder is in and the teardown must run; discover skips a ".old-" leftover.
        do { try fm.removeItem(at: aside) } catch {
            log.error("could not remove the replaced extension folder: \(String(describing: error), privacy: .public)")
        }
    }

    /// #1435: the <name> of an aside ".old-<name>-<UUID>": the UUID is the last 36 characters after a "-", so a name
    /// holding "-" still parses. Nil (never acted on) for any other shape, an empty name or a dot-named one.
    static func asideOwner(_ folder: String) -> String? {
        let uuidLength = 36
        guard folder.hasPrefix(".old-"), folder.count > ".old-".count + 1 + uuidLength,
              UUID(uuidString: String(folder.suffix(uuidLength))) != nil,
              folder.dropLast(uuidLength).hasSuffix("-") else { return nil }
        let owner = String(folder.dropFirst(".old-".count).dropLast(uuidLength + 1))
        return owner.hasPrefix(".") ? nil : owner
    }

    /// #1435: a crash between "dest -> aside" and "stage -> dest" leaves only the aside: one whose <name> has nothing
    /// beside it is moved back. A ".stage-" and an aside whose <name> is there are removed once a day old by their
    /// modification date (younger: an install may be in flight). Only direct children of userDir with those prefixes
    /// are touched; a link is skipped, never followed; a name that does not parse stays.
    private func recoverInstallLeftovers() {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .contentModificationDateKey]
        guard let names = try? fm.contentsOfDirectory(atPath: userDir.path) else { return }
        let dayAgo = Date().addingTimeInterval(-86_400)
        for name in names.sorted() where name.hasPrefix(".stage-") || name.hasPrefix(".old-") {
            let entry = userDir.appendingPathComponent(name, isDirectory: false)
            guard let values = try? entry.resourceValues(forKeys: keys), values.isSymbolicLink == false else { continue }
            if name.hasPrefix(".old-") {
                guard let owner = Self.asideOwner(name) else { continue }
                let home = userDir.appendingPathComponent(owner, isDirectory: true)
                if (try? fm.attributesOfItem(atPath: home.path)) == nil {   // lstat: a link at <name> counts as there
                    do { try moveItem(entry, home) } catch {
                        log.error("could not move back a replaced extension folder: \(String(describing: error), privacy: .public)")
                    }
                    continue
                }
            }
            guard let modified = values.contentModificationDate, modified < dayAgo else { continue }
            do { try fm.removeItem(at: entry) } catch {
                log.error("could not remove an install leftover: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Fetch + install an extension from a GitHub URL (repo or repo subdir).
    /// #1866 n186/n188: `maxBytes` caps the download (RemoteInstaller.fetch), `review` and `admit` go to installLocal;
    /// the defaults are the Settings path's (no cap, the person's alert).
    @discardableResult
    func installRemote(url: String, maxBytes: Int? = nil, review: PermissionReview? = nil, admit: Admit? = nil) async throws -> ExtensionRecord {
        let extDir = try await remoteFetch(url, maxBytes)
        defer { RemoteInstaller.removeWorkFolder(holding: extDir) }
        // Stamp the origin so future launches can poll it for updates (no-op if
        // the author already declared an update_url).
        injectUpdateURL(url, intoManifestAt: extDir)
        return try installLocal(from: extDir, review: review, admit: admit)
    }

    /// #1866: installRemote's download (rows pass a fake folder; the default reaches GitHub).
    var remoteFetch: @Sendable (_ url: String, _ maxBytes: Int?) async throws -> URL = { try await RemoteInstaller.fetch($0, maxBytes: $1) }

    /// Fetch + install (or upgrade) an extension from the marketplace. The download
    /// is integrity- and signature-verified in `RemoteInstaller.fetchFromMarket`
    /// before extraction. The installed copy lands UNTRUSTED (see trust gate) unless
    /// it was already trusted under the same id — an auto-update of a trusted package
    /// stays trusted. Stamps `prosper://market/<id>` as the update origin (force —
    /// overrides any author-declared update_url so updates always come from us).
    /// #919 S3: the Install button and the auto-update both come here, so both get the kit recheck.
    @discardableResult
    func installFromMarket(id: String, version: String, listedKind: String? = nil) async throws -> ExtensionRecord {
        let prepared = try await prepareFromMarket(id: id, version: version, listedKind: listedKind)
        defer { discard(prepared) }
        return try install(prepared)
    }

    /// #919 S3: a market download fetched, bound to its id and version and, for a kit, checked against its listing.
    /// It holds the work folder until `discard`.
    struct PreparedMarketInstall: Sendable {
        let id: String
        let version: String
        let directory: URL
    }

    /// #919 S3: the download and the listing read (rows pass fakes; the defaults reach the Marketplace).
    var marketFetch: @Sendable (_ id: String, _ version: String) async throws -> URL = {
        try await RemoteInstaller.fetchFromMarket(id: $0, version: $1)
    }
    var marketDetail: @Sendable (_ id: String) async -> MarketClient.PackageDetail? = { await MarketClient.packageDetail(id: $0) }
    var marketIndex: @Sendable () async -> [String: String]? = { await MarketClient.index() }
    /// Where the downloads' work folders live (rows pass a folder under their tempDir, so the cleanup really removes).
    var marketTempRoot: URL = FileManager.default.temporaryDirectory

    /// Fetch, bind and recheck; on a throw the work folder is already removed. `listedKind`: the kind the caller's
    /// listing shows (nil: not known, as in the update check); "kit" makes a non-kit archive fetch the listing too.
    /// A non-kit archive not listed as a kit makes no listing call.
    /// `installedKit` (the update check only): whether the installed record is a kit; an archive of the other kind is refused.
    func prepareFromMarket(id: String, version: String, listedKind: String? = nil,
                           installedKit: Bool? = nil) async throws -> PreparedMarketInstall {
        let prepared = PreparedMarketInstall(id: id, version: version, directory: try await marketFetch(id, version))
        do {
            let loaded = try bindMarketIdentity(extDir: prepared.directory, expected: id, expectedVersion: version)
            try await recheckKitListing(prepared, manifest: loaded.manifest, listedKind: listedKind)
            if let installedKit, installedKit != (loaded.manifest.contributes?.kit != nil) {
                throw ExtensionError.marketKindChanged(id: OutsideText.shown(id))
            }
        } catch {
            discard(prepared)
            throw error
        }
        return prepared
    }

    /// Stamps `prosper://market/<id>` as the update origin and installs the prepared folder.
    func install(_ prepared: PreparedMarketInstall, review: PermissionReview? = nil) throws -> ExtensionRecord {
        injectUpdateURL("prosper://market/\(prepared.id)", intoManifestAt: prepared.directory, force: true)
        return try installLocal(from: prepared.directory, review: review)
    }

    func discard(_ prepared: PreparedMarketInstall) { RemoteInstaller.removeWorkFolder(holding: prepared.directory, tempRoot: marketTempRoot) }

    /// #919 S3 (spec 4.12): a kit archive is checked against its listing as the server holds it now (kind, version, status,
    /// and the preview recomputed from the archive); the validator sees the other installed kits' names as taken.
    private func recheckKitListing(_ p: PreparedMarketInstall, manifest: ExtensionManifest, listedKind: String?) async throws {
        let isKit = manifest.contributes?.kit != nil
        guard isKit || listedKind == "kit" else { return }
        let shownID = OutsideText.shown(p.id)
        guard let listing = await marketDetail(p.id) else { throw ExtensionError.marketListingUnavailable(id: shownID) }
        var tarballKit: KitValidation?, readme = ""
        if isKit {
            let others = Set(records.filter { $0.id != p.id && $0.manifest.contributes?.kit != nil }.map(\.manifest.extension.name))
            tarballKit = KitValidator.validate(kitDir: p.directory, manifest: manifest, source: .market, otherKitSlugs: others)
            readme = (try? BoundedFileRead.data(p.directory.appendingPathComponent("README.md"), maxBytes: KitValidator.maxTextBytes))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        if let why = KitListingCheck.verify(tarballKit: tarballKit, readme: readme, listing: listing, version: p.version) {
            throw ExtensionError.marketKitRefused(id: shownID, why)
        }
    }

    /// Bind the signed/requested package id to the artifact's OWN manifest id BEFORE
    /// any install copies files. installLocal installs under the manifest id and
    /// overwrites userDir/<that-id>; without this guard a package published as A
    /// could ship a tarball declaring id B and clobber/impersonate B — and if B was
    /// already trusted, the replacement would inherit trust. The Ed25519 sig binds
    /// the claim's id, NOT the bytes' internal manifest, so this is the binding.
    /// R1182-g: `expectedVersion` is the listing version the download was asked for (nil: no listing, no check).
    @discardableResult
    func bindMarketIdentity(extDir: URL, expected: String, expectedVersion: String?) throws -> LoadedExtension {
        let loaded = try ExtensionLoader.load(directory: extDir, isSystem: false, hostVersion: hostVersion)
        guard loaded.id == expected else {
            throw ExtensionError.marketIdMismatch(expected: expected, got: loaded.id)
        }
        // R1182-l: refused when the listing reads as a plain number version and differs from the archive's as SemanticVersion,
        // the update check's compare, so what passes is never fetched again; the archive's text need not be plain (other text
        // reads as 0 parts there). 1.2 and 1.2.0 (or 1.2.0-beta) pass as one version; a listing that is not plain never refuses.
        let plain = #"\A[0-9]{1,18}(\.[0-9]{1,18}){0,2}([-+].*)?\z"#
        let got = loaded.manifest.extension.version
        if let listed = expectedVersion,
           listed.range(of: plain, options: .regularExpression) != nil,
           SemanticVersion(got) != SemanticVersion(listed) {
            throw ExtensionError.marketVersionMismatch(id: OutsideText.shown(expected), listed: OutsideText.shown(listed, max: 32),
                                                       got: OutsideText.shown(got, max: 32))
        }
        return loaded
    }

    // MARK: - Auto-update

    private static let updateCheckKey = "extensionsUpdateLastCheck"

    /// Surfaced to the UI after a check: e.g. "Updated 2 extensions". nil = idle.
    @Published private(set) var updateStatus: String?

    /// R1182-q1: market updates whose download was refused for its content, as (id, listed version), so the check does not
    /// download the same refused package again. One pair per id, replaced when the listing shows another version.
    /// shortcut: in memory, one more download per app launch; persist it if that matters
    struct RefusedUpdates: Sendable {
        static let maxCount = 256          // ids are outside data: at most this many are remembered
        private(set) var listed: [String: String] = [:]   // id -> the listed version that was refused

        /// #1704: updates held for the person's review (they declare new permissions): id -> the listed version when known
        /// (market; nil for GitHub, whose version is known only after the download) and the note the row shows.
        private(set) var waiting: [String: (listed: String?, note: String)] = [:]

        /// The daily check neither asks nor downloads a held market pair again.
        func waits(id: String, listed version: String) -> Bool { waiting[id]?.listed == version }

        mutating func hold(id: String, listed: String?, added: [String]) {
            guard waiting[id] != nil || waiting.count < Self.maxCount else { return }
            let names = added.prefix(10).map { OutsideText.shown($0, max: 64) }.joined(separator: ", ")
                + (added.count > 10 ? " and \(added.count - 10) more" : "")
            waiting[id] = (listed, "Update waits for your review (asks for: \(names)). Click Check for Updates to review it.")
        }

        mutating func release(id: String) { waiting[id] = nil }

        /// True only for the exact pair noted (both texts compared whole): another listed version is downloaded.
        func skips(id: String, listed version: String) -> Bool { listed[id] == version }

        /// Remembers the pair when `error` refused the package's content; a transient failure is not remembered.
        mutating func note(_ error: Error, id: String, listed version: String) {
            guard Self.isRefusal(error), listed[id] != nil || listed.count < Self.maxCount else { return }
            listed[id] = version
        }

        /// A refusal of what was downloaded (its manifest, id, version or archive entries), never a failure that a later
        /// try could pass (no network, a timeout, a server answer, a cut or undecodable body, a local unpack or install failure).
        static func isRefusal(_ error: Error) -> Bool {
            switch error {
            case ExtensionError.marketIdMismatch, ExtensionError.marketVersionMismatch, ExtensionError.marketKindChanged: return true
            case ExtensionError.marketKitRefused(_, let why): return why.isRefusal   // #919 S3
            case ExtensionLoadError.unreadable: return false   // R1182-q4: a failed open or read is local, may pass next time
            case is ExtensionLoadError: return true
            case RemoteInstaller.InstallError.unsafeArchive, RemoteInstaller.InstallError.manifestNotFound: return true
            default: return false
            }
        }
    }

    private var refusedUpdates = RefusedUpdates()

    /// #1704: the row's note while an update of `id` waits for the person's review; nil when none does.
    func updateWaitingNote(id: String) -> String? { refusedUpdates.waiting[id]?.note }

    /// R1182-q5: what one check did. A skipped (refused) or failed candidate is not installed: the status then says so in one
    /// fixed sentence (a count only, no name, path or error text) and never "up to date".
    struct UpdateTally: Sendable {
        private(set) var installed = 0
        private(set) var notInstalled = 0
        private(set) var unchecked = 0   // R1182-q6/q7: no newer version could be looked up (fetch or index failed)
        private(set) var waiting = 0     // #1704: held for the person's review (new permissions); not a failure
        mutating func waitingOne() { waiting += 1 }
        mutating func installedOne() { installed += 1 }
        mutating func skippedOne() { notInstalled += 1 }
        mutating func failedOne() { notInstalled += 1 }
        mutating func uncheckedOne() { unchecked += 1 }
        /// The per-candidate decision and the outcome of a try land here (the call sites in checkForUpdates).
        mutating func record(_ step: UpdateStep) {
            switch step {
            case .skipRefused: skippedOne()
            case .unchecked: uncheckedOne()
            case .nothing, .install: break
            }
        }
        mutating func record(_ outcome: UpdateOutcome) {
            switch outcome {
            case .installed: installedOne()
            case .failed: failedOne()
            case .unchecked: uncheckedOne()
            }
        }
        /// nil = leave the status alone (an automatic check that installed nothing). Counts only, no name or error text.
        /// The check sentence, a space, the install sentence; "up to date" only when both counts are 0.
        func status(force: Bool) -> String? {
            guard force || installed > 0 else { return nil }
            var parts: [String] = []
            if unchecked > 0 { parts.append("Could not check \(unchecked) extension\(unchecked == 1 ? "" : "s") for updates.") }
            if notInstalled > 0 { parts.append("\(notInstalled) update\(notInstalled == 1 ? "" : "s") could not be installed.") }
            if waiting > 0 { parts.append("\(waiting) update\(waiting == 1 ? " waits" : "s wait") for your review.") }
            if !parts.isEmpty { return parts.joined(separator: " ") }
            return installed == 0 ? "All extensions up to date." : "Updated \(installed) extension\(installed == 1 ? "" : "s")."
        }
    }

    /// What the check does with one MARKET candidate (R1182-q7: pure, so a row drives it without the network).
    enum UpdateStep: Sendable, Equatable { case nothing, skipRefused, unchecked, install }
    /// Where a try threw: `.fetch` = before a newer version is known (R1182-q6), `.install` = after.
    enum UpdateStage: Sendable { case fetch, install }
    enum UpdateOutcome: Sendable, Equatable { case installed, failed, unchecked }

    /// `index` nil = the Marketplace index failed to load: nothing can be said about any listing. A loaded index that does
    /// not list the id, or lists a version that is not newer, is a plain `.nothing` (looked up, nothing to do).
    nonisolated static func marketStep(index: [String: String]?, id: String, current: SemanticVersion,
                                       refused: RefusedUpdates) -> UpdateStep {
        guard let index else { return .unchecked }
        guard let latest = index[id], current < SemanticVersion(latest) else { return .nothing }
        return refused.skips(id: id, listed: latest) ? .skipRefused : .install
    }

    /// The outcome of a try: no throw = installed; a throw at `.fetch` = unchecked; any later throw = failed.
    nonisolated static func outcome(threwAt stage: UpdateStage?) -> UpdateOutcome {
        switch stage {
        case nil: return .installed
        case .fetch?: return .unchecked
        case .install?: return .failed
        }
    }

    /// R1182-p: the update failure log line, "update check failed for <id>: <why>". `shown` (the id, as logged before) is
    /// its only public part; `why` (the error text, which can hold a folder name or a path) is logged private.
    nonisolated static func updateFailureLog(id: String, error: Error) -> (shown: String, why: String) {
        // R1182-m: through the description, so an id mismatch logs the cleaned sentence, not the archive's raw id.
        ("update check failed for \(id)", (error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }

    /// #1869: what the check did with one candidate (ctl extensions.update's reply). The texts are outside data, raw here:
    /// the reply cleans them. `to`: the newer version found (nil when none was); `reason`: why failed or held.
    struct UpdateResult: Sendable, Equatable {
        enum Outcome: String, Sendable { case updated, upToDate, held, failed }
        let id: String, from: String
        var to: String? = nil
        var outcome: Outcome
        var reason: String? = nil
    }

    /// Poll each user extension's `update_url` for a newer version and auto-apply
    /// it. Throttled to once per day unless `force` (the "Check for Updates"
    /// button passes force). System extensions update via the bundle, not here.
    /// #1869: `quiet` (ctl extensions.update) never asks about new permissions, even with force: it holds the update as the
    /// daily check does. `only` checks that one id and leaves the daily throttle date alone. Stops at the next candidate
    /// once the task is cancelled (a ctl deadline); an install already started runs to its end.
    @discardableResult
    func checkForUpdates(force: Bool = false, quiet: Bool = false, only: String? = nil) async -> [UpdateResult] {
        if !force, let last = defaults.object(forKey: Self.updateCheckKey) as? Date,
           Date().timeIntervalSince(last) < 86_400 { return [] }
        if only == nil { defaults.set(Date(), forKey: Self.updateCheckKey) }

        // Snapshot candidates up front — installLocal() rebuilds `records`.
        let candidates: [(id: String, version: SemanticVersion, from: String, url: String)] =
            records.compactMap { rec in
                guard !rec.isSystem, only == nil || rec.id == only,
                      let url = rec.manifest.extension.updateURL else { return nil }
                return (rec.id, SemanticVersion(rec.manifest.extension.version), rec.manifest.extension.version, url)
            }
        guard !candidates.isEmpty else { if force { updateStatus = "No updatable extensions." }; return [] }
        if force { updateStatus = "Checking…" }

        // Market extensions (prosper://market/<id>) share one index request rather
        // than polling per-package. GitHub-hosted ones keep the per-url tarball path.
        let marketPrefix = "prosper://market/"
        let marketIndex: [String: String]? = candidates.contains { $0.url.hasPrefix(marketPrefix) }
            ? await marketIndex() : [:]   // nil = the index failed (R1182-q7)

        // #1704: only the person's Check for Updates (force) asks about new permissions; the daily check never shows the
        // alert: it declines quietly and holds the update for review.
        let asks = force && !quiet
        let review: PermissionReview = asks ? reviewNewPermissions : { @Sendable _, _ in false }
        var tally = UpdateTally()
        var results: [UpdateResult] = []
        for cand in candidates {
            if Task.isCancelled { break }
            var tried: (id: String, listed: String)?   // R1182-q1: the market pair this pass downloads
            var stage = UpdateStage.install            // R1182-q6: .fetch only while RemoteInstaller.fetch runs
            var result = UpdateResult(id: cand.id, from: cand.from, outcome: .upToDate)
            defer { results.append(result) }
            do {
                if cand.url.hasPrefix(marketPrefix) {
                    let pkgID = String(cand.url.dropFirst(marketPrefix.count))
                    let step = Self.marketStep(index: marketIndex, id: pkgID, current: cand.version, refused: refusedUpdates)
                    tally.record(step)
                    result.to = step == .nothing ? nil : marketIndex?[pkgID]
                    switch step {
                    case .skipRefused: result.outcome = .failed; result.reason = "this version's package was refused before"
                    case .unchecked: result.outcome = .failed; result.reason = "the Marketplace index could not be read"
                    case .nothing, .install: break
                    }
                    guard step == .install, let latest = marketIndex?[pkgID] else { continue }
                    if !asks, refusedUpdates.waits(id: cand.id, listed: latest) {
                        tally.waitingOne()
                        result.outcome = .held
                        result.reason = refusedUpdates.waiting[cand.id]?.note
                        continue
                    }
                    tried = (pkgID, latest)
                    // An installed kit gets its listing read whatever the new archive is (it may have turned into a non-kit).
                    let wasKit = record(id: cand.id)?.manifest.contributes?.kit != nil
                    let prepared = try await prepareFromMarket(id: pkgID, version: latest, listedKind: wasKit ? "kit" : nil,
                                                               installedKit: wasKit)
                    defer { discard(prepared) }
                    _ = try install(prepared, review: review)
                    tally.record(Self.outcome(threwAt: nil))
                    result.outcome = .updated
                    log.info("auto-updated market extension \(cand.id, privacy: .public) to \(latest, privacy: .public)")
                    continue
                }
                stage = .fetch
                let remoteDir = try await remoteFetch(cand.url, RemoteInstaller.maxArtifactBytes)   // #1870: capped like the other GitHub downloads
                stage = .install
                defer { RemoteInstaller.removeWorkFolder(holding: remoteDir) }
                guard let remote = Self.manifestVersion(at: remoteDir), cand.version < remote else { continue }
                result.to = "\(remote.major).\(remote.minor).\(remote.patch)"
                // Same clobber guard as the market path: installLocal installs under the
                // tarball's OWN manifest id, so a (compromised) update feed for A that ships
                // a tarball declaring id B would overwrite userDir/B and inherit B's trust.
                // GitHub has no signature, so this id-binding is the only defense.
                try bindMarketIdentity(extDir: remoteDir, expected: cand.id, expectedVersion: nil)
                injectUpdateURL(cand.url, intoManifestAt: remoteDir)   // keep origin sticky
                try installLocal(from: remoteDir, review: review)
                tally.record(Self.outcome(threwAt: nil))
                result.outcome = .updated
                log.info("auto-updated extension \(cand.id, privacy: .public) to a newer version")
            } catch ExtensionError.newPermissionsDeclined(_, let added) {
                tally.waitingOne()
                refusedUpdates.hold(id: cand.id, listed: tried?.listed, added: added)
                result.outcome = .held
                result.reason = refusedUpdates.waiting[cand.id]?.note
                objectWillChange.send()   // the row's note; an automatic check sets no status
                log.info("update of \(cand.id, privacy: .public) waits for review: it asks for new permissions")
            } catch {
                tally.record(Self.outcome(threwAt: stage))
                if let tried { refusedUpdates.note(error, id: tried.id, listed: tried.listed) }
                let line = Self.updateFailureLog(id: cand.id, error: error)
                log.error("\(line.shown, privacy: .public): \(line.why, privacy: .private)")
                result.outcome = .failed
                result.reason = line.why
            }
        }
        if let status = tally.status(force: force) { updateStatus = status }
        return results
    }

    /// Persist the GitHub origin as `update_url` in the extension's manifest so
    /// auto-update knows where to poll. No-op when the manifest already declares
    /// one (author-provided or stamped by a prior install).
    private func injectUpdateURL(_ url: String, intoManifestAt dir: URL, force: Bool = false) {
        let toml = dir.appendingPathComponent(ExtensionLoader.manifestFileName)
        guard var text = try? ExtensionLoader.readManifest(toml) else { return }
        if let existing = text.range(of: #"(?m)^[ \t]*update_url[ \t]*=.*$"#, options: .regularExpression) {
            guard force else { return }          // author/origin already set; leave it
            text.replaceSubrange(existing, with: "")   // drop it, re-stamp below
        }
        guard let header = text.range(of: #"(?m)^[ \t]*\[extension\][ \t]*$"#, options: .regularExpression) else { return }
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        text.replaceSubrange(header.upperBound..<header.upperBound, with: "\nupdate_url = \"\(escaped)\"")
        try? text.write(to: toml, atomically: true, encoding: .utf8)
    }

    // MARK: - Per-extension settings (schema-driven UI <-> host prefs)

    func setSetting(extensionID: String, key: String, value: String) {
        services.prefSet(extensionID: extensionID, key: key, value: value)
    }

    /// Current raw `host.prefs` value for a key (nil if unset). Used by Tier-A
    /// settings sections to seed their controls.
    func prefValue(extensionID: String, key: String) -> String? {
        services.prefGet(extensionID: extensionID, key: key)
    }

    /// Reveal an extension's source directory in Finder (for editing system or
    /// user extensions in place).
    func directory(id: String) -> URL? { record(id: id)?.loaded.directory }

    /// Reset a system extension to its bundled pristine copy, discarding local
    /// edits. Copies the pristine bundled dir over the editable copy in userDir.
    func reset(id: String) throws {
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        guard record.isSystem else { throw ExtensionError.cannotResetUserExtension(id) }
        guard let pristineRoot = systemPristineDir else { throw ExtensionError.noPristineCopy(id) }
        let folder = record.loaded.directory.lastPathComponent
        let pristine = pristineRoot.appendingPathComponent(folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: pristine.path) else {
            throw ExtensionError.noPristineCopy(id)
        }
        let dest = userDir.appendingPathComponent(folder, isDirectory: true)
        try stageAndSwap(pristine, into: dest, sweep: false)
        // #1038: the old code's VMs, in-flight calls, timers and held resources go; settings, trust and
        // the enabled state stay. After the copy, so a failed reset changes nothing.
        teardown(record)
        discover()
        onEnabledChanged?()   // N1038-c: the pristine manifest's shortcuts, themes and live flags, as a toggle does
        // Like a re-enable: only the launch handler restores what the teardown released (key rules, menu items).
        replayLaunch(id: id)
    }

    // MARK: - Disabled-id persistence

    private func disabledIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
    }

    private func persistDisabled() {
        // Opt-in exts are governed SOLELY by `enabledExtensionIDs` (persistEnabled),
        // so keep them out of the disabled set — else a disabled opt-in ext sits in
        // both keys and the two could disagree about the same id.
        let ids = records.filter { !$0.enabled && !$0.manifest.extension.defaultDisabled }
            .map(\.id).sorted()
        defaults.set(ids, forKey: Self.disabledKey)
    }

    private func enabledIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.enabledKey) ?? [])
    }

    /// Persist the turn-ONs for opt-in extensions (mirror of `persistDisabled`).
    private func persistEnabled() {
        let ids = records.filter { $0.manifest.extension.defaultDisabled && $0.enabled }
            .map(\.id).sorted()
        defaults.set(ids, forKey: Self.enabledKey)
    }

    // MARK: - Trust gate

    private func trustedIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.trustedKey) ?? [])
    }

    private func persistTrusted(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: Self.trustedKey)
    }

    func isTrusted(id: String) -> Bool { record(id: id)?.trusted ?? false }

    /// Mark a reviewed extension as trusted: its contributions are routed and its
    /// Lua VM may now spawn. Idempotent for already-trusted ids.
    func trust(id: String) throws {
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        var ids = trustedIDs()
        ids.insert(id)
        persistTrusted(ids)
        record.trusted = true
        rebuildRoutes()
        objectWillChange.send()
        onEnabledChanged?()
    }

    /// Revoke trust: tear down any live VM and stop routing to the extension. Its
    /// files stay on disk so the user can re-inspect and re-trust.
    func untrust(id: String) throws {
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        var ids = trustedIDs()
        ids.remove(id)
        persistTrusted(ids)
        record.trusted = false
        // Privilege requires trust: revoking trust revokes the system tier too, so an
        // extension is never privileged-but-untrusted and a later re-trust must be an
        // explicit re-grant.
        clearPrivilege(id: id)
        setPhoneApproved(false, id: id)
        // #1038: same teardown as disable, after trust is off: no VM is left to release what it held.
        teardown(record)
        rebuildRoutes()
        objectWillChange.send()
        onEnabledChanged?()
    }

    // MARK: - Privilege (system tier) gate

    private func privilegedIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.privilegedKey) ?? [])
    }

    private func persistPrivileged(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: Self.privilegedKey)
    }

    func isPrivileged(id: String) -> Bool { record(id: id)?.privileged ?? false }

    /// Drop any granted system-tier privilege for `id` (persisted set + live record).
    /// No VM teardown here — callers (untrust/uninstall) already rebuild or discard.
    private func clearPrivilege(id: String) {
        var ids = privilegedIDs()
        if ids.remove(id) != nil { persistPrivileged(ids) }
        record(id: id)?.privileged = false
    }

    /// Grant the SYSTEM tier to a user extension: host.shell, the coding-agent, and
    /// destructive host.files.act become available to its Lua. A deliberate, explicit
    /// escalation — the extension can now run arbitrary commands as the user, so this
    /// is a user action distinct from Trust (the Settings toggle warns). Tears down any
    /// live VM so the next call rebuilds with the privileged host table. No-op for
    /// system extensions (always privileged). Takes effect only once the extension is
    /// also trusted — an untrusted extension never spawns a VM.
    func grantPrivilege(id: String) throws {
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        guard !record.isSystem else { return }
        // Privilege requires trust — enforce the invariant at the API, not just the UI.
        guard record.trusted else { throw ExtensionError.untrusted(id) }
        var ids = privilegedIDs()
        ids.insert(id)
        persistPrivileged(ids)
        record.privileged = true
        record.runtime = nil
        asyncRuntimes.invalidate(id: id)
        rebuildRoutes()
        objectWillChange.send()
        onEnabledChanged?()
    }

    /// Revoke the system tier: the extension drops back to the automation tier
    /// (shell/agent/destructive fs refused). Tears down its VM so it rebuilds gated.
    func revokePrivilege(id: String) throws {
        guard let record = record(id: id) else { throw ExtensionError.notFound(id) }
        guard !record.isSystem else { return }
        var ids = privilegedIDs()
        ids.remove(id)
        persistPrivileged(ids)
        record.privileged = false
        record.runtime = nil
        asyncRuntimes.invalidate(id: id)
        rebuildRoutes()
        objectWillChange.send()
        onEnabledChanged?()
    }

    // MARK: - Phone approval (#726)

    /// What "Allow on iPhone" approved: the sorted (id, title, argument hint) of the phone
    /// commands. The rest of an update (version, code, descriptions) keeps the approval; a new,
    /// removed or renamed phone command, or a changed hint, drops it.
    nonisolated static func phoneApprovalHash(_ manifest: ExtensionManifest) -> String {
        let rows = (manifest.contributes?.phoneCommands ?? []).sorted { $0.id < $1.id }
            .map { [$0.id, $0.title, $0.phoneArgument] }
        let data = (try? JSONEncoder().encode(rows)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func phoneApprovals() -> [String: String] {
        defaults.dictionary(forKey: Self.phoneApprovedKey) as? [String: String] ?? [:]
    }

    /// The user allowed this extension on iPhone and its phone commands are still the ones
    /// they allowed. Never a system extension: the allowlist is their only path.
    func isPhoneApproved(id: String) -> Bool {
        guard let record = record(id: id), !record.isSystem else { return false }
        return phoneApprovals()[id] == Self.phoneApprovalHash(record.manifest)
    }

    /// Approve the extension's current phone commands, or withdraw.
    func setPhoneApproved(_ on: Bool, id: String) {
        var all = phoneApprovals()
        if on, let record = record(id: id), !record.isSystem {
            all[id] = Self.phoneApprovalHash(record.manifest)
        } else {
            guard all.removeValue(forKey: id) != nil else { return }
        }
        defaults.set(all, forKey: Self.phoneApprovedKey)
        objectWillChange.send()
    }

    /// An update that changed the phone commands drops the approval for good: a later update
    /// that reverts them doesn't bring it back. A missing record keeps its entry (a manifest
    /// that fails to load for a while is not an update; uninstall clears it explicitly).
    private func dropStalePhoneApprovals() {
        let all = phoneApprovals()
        let kept = all.filter { id, hash in
            guard let r = record(id: id) else { return true }
            return hash == Self.phoneApprovalHash(r.manifest)
        }
        if kept.count != all.count { defaults.set(kept, forKey: Self.phoneApprovedKey) }
    }
}
