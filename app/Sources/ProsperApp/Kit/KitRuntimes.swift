import Foundation

/// #918 S3 (M9): the app-lifetime owner of the kit runtimes, one KitRuntime per extension id, built on first use, so
/// every pane model of one kit shares its single-flight (a runtime per view would make busy worthless).
///
/// Isolation: @MainActor (the registry's records are main-actor state). Trust is read from the records on main each
/// time a runtime is handed out and kept in a locked box, so the runtime's own @Sendable trust check (run off main)
/// answers with what the registry said at the last hand-out.
///
/// Nothing here reaches the real home: the config home, the runtime factory, the record lookup and the login PATH are
/// injected. The app's instance (`shared`) is built by its owner of the registry (AppDelegate, a follow-up line); under
/// XCTest nothing sets it.
@MainActor
final class KitRuntimes {
    /// The store and the trust check of one kit -> its runtime (production: KitRuntime(provider: .live, ...)).
    typealias Make = @MainActor (_ store: KitStore, _ isTrusted: @escaping @Sendable (String) -> Bool) -> KitRuntime

    static var shared: KitRuntimes?

    let configHome: URL?
    let records: @MainActor () -> [ExtensionRecord]
    /// The login PATH (LoginPath.read in production): called off main by the pane model, never under a lock.
    let loginPath: @Sendable () -> String?
    private let make: Make
    private var runtimes: [String: KitRuntime] = [:]
    private let trust = Trust()

    /// The registry's answer, readable off main.
    final class Trust: @unchecked Sendable {
        private let lock = NSLock()
        private var trusted: [String: Bool] = [:]
        func set(_ id: String, _ yes: Bool) { lock.withLock { trusted[id] = yes } }
        func get(_ id: String) -> Bool { lock.withLock { trusted[id] ?? false } }
    }

    init(configHome: URL?, records: @escaping @MainActor () -> [ExtensionRecord],
         loginPath: @escaping @Sendable () -> String?, make: @escaping Make) {
        self.configHome = configHome
        self.records = records
        self.loginPath = loginPath
        self.make = make
    }

    func record(_ id: String) -> ExtensionRecord? { records().first { $0.id == id } }

    /// The kit records (an extension with a `[contributes.kit]` table), in the registry's order.
    func kitRecords() -> [ExtensionRecord] { records().filter { $0.manifest.contributes?.kit != nil } }

    /// The one runtime of `id`, built on first use. nil: no such kit record, no config home, or an id no store takes.
    /// Each call reads the record's trust again first.
    func runtime(for id: String) -> KitRuntime? {
        guard let rec = record(id), rec.manifest.contributes?.kit != nil else { return nil }
        trust.set(id, rec.trusted)
        if let rt = runtimes[id] { return rt }
        guard let configHome, let store = try? KitStore(configHome: configHome, extID: id) else { return nil }
        let t = trust
        let rt = make(store, { t.get($0) })
        runtimes[id] = rt
        return rt
    }

    /// The slugs the other kits recorded at their first apply (the validator refuses a kit that would take one).
    func otherKitSlugs(except id: String) -> Set<String> {
        guard let configHome else { return [] }
        return Set(kitRecords().filter { $0.id != id }.compactMap { try? KitStore(configHome: configHome, extID: $0.id).recordedSlug() })
    }

    /// #917 S7 (#1426): the bin dirs KitSessionEnv appends to a spawned session's PATH: each trusted kit with a live
    /// version and at least one tools piece switched on, in the registry's order. An untrusted or never-applied kit, or
    /// one whose tools pieces are all off, adds nothing.
    /// shortcut: the registry's order stands for install order and the record's manifest for the live one's pieces; read
    /// the live copy's manifest if an update may add or drop a tools piece before it is applied.
    func liveBins() -> [String] {
        kitRecords().compactMap { rec -> String? in
            guard rec.trusted, let raw = rec.manifest.contributes?.kit, let rt = runtime(for: rec.id),
                  let live = rt.current?.live.version, !live.isEmpty else { return nil }
            let off = rt.off()
            let tools = KitManifest.parse(raw).kit.pieces.filter { $0.kind == .tools && !off.contains($0.id) }
            return tools.isEmpty ? nil : rt.store.layout.bin
        }
    }
}
