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

    init(url: URL, absent: Bool = false, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.absent = absent
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
            // Not there yet (bootstrap creates it on launch) — retry shortly.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm(afterAbsence: true) }
            return
        }
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
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
