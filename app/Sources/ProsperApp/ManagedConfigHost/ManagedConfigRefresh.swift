import Foundation

/// #870: keeps every owner's managed-config status current. It watches the files the state
/// records point at (never the state dir: status() can write state.json, and a watch on it would
/// re-trigger itself) and re-runs status(owner:declared:) when one changes, after a write through
/// `host.config`, and after an uninstall.
///
/// Isolation: `@MainActor` (published to the UI). status() itself takes the core's write lock and
/// touches the disk, so it runs on a detached task, never on main (A-INFO-13).
@MainActor
final class ManagedConfigRefresh: ObservableObject {
    /// The app's instance, set by AppDelegate once the config resolves.
    static var current: ManagedConfigRefresh?
    /// The ExtensionFSWatch id of these watches: no extension id has this shape.
    static let watchID = "\u{1}prosper.managed-config"

    /// The watch seam: production is ExtensionFSWatch, tests pass a recorder.
    struct Watcher: Sendable {
        var watch: @MainActor @Sendable (_ path: String, _ onChange: @escaping @MainActor () -> Void) -> Void
        var unwatch: @MainActor @Sendable (_ path: String) -> Void

        @MainActor static var fsEvents: Watcher {
            Watcher(watch: { path, onChange in
                        ExtensionFSWatch.shared.watch(extensionID: ManagedConfigRefresh.watchID, path: path, handler: "", onChange: onChange)
                    },
                    unwatch: { path in ExtensionFSWatch.shared.unwatch(extensionID: ManagedConfigRefresh.watchID, path: path) })
        }
    }

    let config: ManagedConfig
    /// The installed extensions' owners (their dirs make `orphaned` work); owners that only the state
    /// still names are added with no dir.
    let owners: @MainActor () -> [ManagedConfigOwner]
    /// The pieces an owner currently declares, for `notApplied` / adoption (#872 kits fill this).
    var declared: [String: [ManagedConfigPiece]] = [:]

    @Published private(set) var statuses: [String: [ManagedConfigPieceStatus]] = [:]
    /// A-INFO-3: state.json does not parse (or is from a newer Prosper): statuses mean nothing.
    @Published private(set) var stateUnreadable = false
    /// Rescans started, for the loop test.
    private(set) var scans = 0
    private(set) var watched: Set<String> = []
    private let watcher: Watcher

    init(config: ManagedConfig, watcher: Watcher? = nil, owners: @escaping @MainActor () -> [ManagedConfigOwner]) {
        self.config = config
        self.watcher = watcher ?? .fsEvents
        self.owners = owners
    }

    /// Re-reads every owner's status off main, then re-aims the watches at the recorded paths.
    @discardableResult
    func rescan() -> Task<Void, Never> {
        scans += 1
        let config = config
        let installed = owners()
        let declared = declared
        return Task { @MainActor in
            let (readable, result, paths) = await Task.detached { () -> (Bool, [String: [ManagedConfigPieceStatus]], Set<String>) in
                guard config.stateIsReadable() else { return (false, [:], []) }
                var owners = installed
                for id in config.ownerIDs() where !owners.contains(where: { $0.id == id }) {
                    owners.append(ManagedConfigOwner(id: id, version: "0"))
                }
                var out: [String: [ManagedConfigPieceStatus]] = [:]
                for o in owners {
                    let s = config.status(owner: o, declared: declared[o.id] ?? [])
                    if !s.isEmpty { out[o.id] = s }
                }
                return (true, out, Set(config.recordedPaths()))
            }.value
            stateUnreadable = !readable
            statuses = result
            guard readable else { return }
            for p in watched.subtracting(paths) { watcher.unwatch(p) }
            for p in paths.subtracting(watched) {
                watcher.watch(p) { [weak self] in self?.rescan() }
            }
            watched = paths
        }
    }

    /// r2 (R2-3): `current` comes to exist on the provider's first successful resolve, whenever that
    /// is (one slow login shell at launch must not leave it nil for the session). The provider calls
    /// the hook once, however many callers race.
    static func follow(_ provider: ManagedConfigProvider, watcher: Watcher? = nil,
                       owners: @escaping @MainActor @Sendable () -> [ManagedConfigOwner]) {
        provider.onFirstSuccess { config in
            Task { @MainActor in
                let refresh = ManagedConfigRefresh(config: config, watcher: watcher, owners: owners)
                ManagedConfigRefresh.current = refresh
                refresh.rescan()
            }
        }
    }

    func stop() {
        for p in watched { watcher.unwatch(p) }
        watched = []
    }
}
