import Foundation

/// Watches a single file for external changes (editor saves, imports) and fires
/// `onChange` on the main queue, debounced. Survives atomic-replace saves (most
/// editors write a temp file then rename over the target): on a delete/rename it
/// re-arms on the recreated path. A path that appears after an absence (created after the watch
/// began, or deleted and created again) fires once when it is armed (#1147). Coarse by design —
/// one fd, one callback.
///
/// Releasing a watcher closes its descriptor, whether or not `stop()` came first: the app
/// holds some for its lifetime (`AppDelegate`, `BunHarness`), the text viewer one per window.
///
/// A path that is not there is looked at again after 1 s, then after twice the last delay, up to
/// `retryCeiling` (R896-1); a successful arm starts over at 1 s. The app-long watchers keep the
/// default ceiling of 1 s (a look every second, as before). The text viewer passes 60 s: per retry
/// at most 60 s apart, and a window open for a day on a missing path does 1,445 opens (1 + 6 while
/// backing off + one a minute; 86,401 before). `remote` (the viewer, for an automount or network
/// location) bounds the looks: none for a path never seen armed; for a path that was armed and is
/// gone, 7 per delete (1, 2, 4, 8, 16, 32, 60 s: up to and including the first look at the ceiling,
/// 123 s), then no more; a later successful arm gives the whole allowance back.
final class FileWatcher {
    private let url: URL
    private let onChange: @Sendable () -> Void
    /// Not private: a row syncs on it to know the first arm has run (#1147).
    let queue = DispatchQueue(label: "com.prosper.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var stopped = false
    /// A delete or rename cancelled the source: the next debounced fire re-arms first (#1147).
    private var rearmPending = false
    /// `absent`: the caller already found nothing at `url` (the text viewer's first load), so a
    /// file there by the first arm was created since and fires too. Kept for a row to read.
    let absent: Bool
    /// The longest wait between two looks at a missing path. Kept for a row to read.
    let retryCeiling: TimeInterval
    /// An automount or network location: the looks are bounded (see the type's comment).
    let remote: Bool
    /// An arm has succeeded at least once. Touched on `queue` only.
    private var everArmed = false
    /// The last retry delay, 0 once armed. Touched on `queue` only.
    private var retryDelay: TimeInterval = 0
    /// Runs every delayed item (the retry and the debounce), on `queue` only. Nil: `queue.asyncAfter`.
    /// A row passes a recorder and performs the items itself on `queue`: no timer fires on its own.
    private let schedule: ((TimeInterval, DispatchWorkItem) -> Void)?

    init(url: URL, absent: Bool = false, retryCeiling: TimeInterval = 1, remote: Bool = false,
         schedule: ((TimeInterval, DispatchWorkItem) -> Void)? = nil, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.absent = absent
        self.retryCeiling = retryCeiling
        self.remote = remote
        self.schedule = schedule
        self.onChange = onChange
        queue.async { [weak self] in self?.arm(afterAbsence: absent) }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.source?.cancel()
            self?.source = nil
        }
    }

    // Released (with or without stop(), whose block then finds nil): cancel in place, since a
    // deinit cannot queue a block that captures self. Nothing else can touch `source` now: every
    // block that does holds self strongly while it runs, so none runs while deinit does.
    // DispatchSource.cancel is thread-safe; the cancel handler closes the descriptor (#1130).
    deinit { source?.cancel() }

    /// `afterAbsence`: an earlier look found no file here, so the one now found is a change.
    private func arm(afterAbsence: Bool = false) {
        guard !stopped else { return }
        // O_NONBLOCK: a FIFO at the path would otherwise block this queue until a writer opens it.
        let fd = open(url.path, O_EVTONLY | O_NONBLOCK)
        guard fd >= 0 else {
            // Not there yet (bootstrap creates it on launch): look again later. After any failed open
            // (not only ENOENT) the next arm fires: the watcher saw nothing meanwhile, a change must not be lost.
            // Remote: never armed, no look; armed once, looks until the one at the ceiling was made.
            if remote && (!everArmed || retryDelay >= retryCeiling) { return }
            retryDelay = min(max(retryDelay * 2, 1), retryCeiling)
            // Runs on `queue` (the scheduler's contract).
            after(retryDelay, DispatchWorkItem { [weak self] in self?.arm(afterAbsence: true) })
            return
        }
        retryDelay = 0
        everArmed = true
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                src.cancel()        // old inode is gone (atomic replace)
                self.rearmPending = true
                self.fire()         // the replace is itself a change
            } else {
                self.fire()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        if afterAbsence { fire() }   // the path appeared since the last look (#1147)
    }

    private func fire() {
        debounce?.cancel()
        let cb = onChange   // capture the Sendable closure, not self, across the main hop
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            // Re-arm in this same item, before onChange is queued: the path is looked at before the
            // reload reads it, so a file created after this look fires again (two timers had no order).
            if self.rearmPending { self.rearmPending = false; self.arm() }
            DispatchQueue.main.async { cb() }
        }
        debounce = work
        after(0.2, work)
    }

    /// On `queue`.
    private func after(_ delay: TimeInterval, _ work: DispatchWorkItem) {
        if let schedule { schedule(delay, work) } else { queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// R896-1: whether `path` lies on an automount or network location, read from the kernel's mount
    /// table (getfsstat with MNT_NOWAIT: cached entries, no path lookup, no stat or open of `path`, so
    /// the automounter is never asked). The longest mount point containing `path` decides.
    static func onAutomountOrNetwork(_ path: String) -> Bool {
        onAutomountOrNetwork(path, mounts: mountTable())
    }

    struct Mount: Equatable { let on: String; let type: String; let flags: UInt32 }

    /// Pure: autofs, a mount without MNT_LOCAL (nfs, smbfs, afpfs, webdav) or one the automounter made.
    static func onAutomountOrNetwork(_ path: String, mounts: [Mount]) -> Bool {
        // Ignoring case: the system volume is case-insensitive, so another spelling of an autofs path is
        // the same mount. On a case-sensitive volume a false "remote" only costs the retry.
        let lower = path.lowercased()
        let inside = mounts.filter { m in
            let on = m.on.lowercased()
            return on == "/" || lower == on || lower.hasPrefix(on + "/")
        }
        guard let m = inside.max(by: { $0.on.count < $1.on.count }) else { return false }
        return m.type == "autofs" || m.flags & UInt32(MNT_LOCAL) == 0 || m.flags & UInt32(MNT_AUTOMOUNTED) != 0
    }

    static func mountTable() -> [Mount] {
        let n = getfsstat(nil, 0, MNT_NOWAIT)
        guard n > 0, n < 4096 else { return [] }   // bounds the + 8 and the byte count below
        var buf = Array<statfs>(repeating: statfs(), count: Int(n) + 8)   // room for a mount added meanwhile
        let got = buf.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard got > 0 else { return [] }
        return buf.prefix(Int(min(got, Int32(buf.count)))).map { fs in
            let on = withUnsafeBytes(of: fs.f_mntonname) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            let type = withUnsafeBytes(of: fs.f_fstypename) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            return Mount(on: on, type: type, flags: fs.f_flags)
        }
    }
}
