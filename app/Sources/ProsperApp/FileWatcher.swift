import Foundation

/// Watches a single file for external changes (editor saves, imports) and fires
/// `onChange` on the main queue, debounced. Survives atomic-replace saves (most
/// editors write a temp file then rename over the target): on a delete/rename it
/// re-arms on the recreated path. Coarse by design — one fd, one callback.
///
/// ponytail: intended to live for the app's lifetime (held by `AppDelegate`), so the
/// fd cleanup in `stop()`/`deinit` is belt-and-suspenders, not a hot path.
final class FileWatcher {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.prosper.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var stopped = false

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.source?.cancel()
            self?.source = nil
        }
    }

    deinit { stop() }

    private func arm() {
        guard !stopped else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Not there yet (bootstrap creates it on launch) — retry shortly.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: queue)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                src.cancel()        // old inode is gone (atomic replace)
                self.fire()         // the replace is itself a change
                self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.arm() }
            } else {
                self.fire()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func fire() {
        debounce?.cancel()
        let cb = onChange   // capture the Sendable closure, not self, across the main hop
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.async { cb() }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
