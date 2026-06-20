import AppKit
import SwiftUI

/// Shows a small progress window that drives `CoreBridge.ensureModel` (MLXEngine
/// download + load) and reports download progress. Invoked on launch when the
/// model isn't ready, or manually.
@MainActor
final class ModelSetup: NSObject, NSWindowDelegate {

    /// A model operation: ensureModel / switchModel share this shape, so Retry can
    /// re-run whichever one this run started with — in the same window.
    private typealias Operation = (
        @escaping @MainActor @Sendable (SetupProgress) -> Void,
        @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Void

    private var window: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private weak var retryButton: NSButton?
    private var operation: Operation?
    private var isRunning = false
    /// Reports the run outcome: `true` only when the model loaded successfully.
    /// `false` on cancel or genuine failure — callers revert the selection.
    private var onFinish: ((Bool) -> Void)?

    /// Checks health and, if the model/server isn't ready (or `force`), runs setup.
    func runIfNeeded(force: Bool, onFinish: ((Bool) -> Void)? = nil) {
        guard !isRunning else { return }
        if force {
            beginSetup(onFinish: onFinish)
            return
        }
        CoreBridge.health { [weak self] health in
            guard let self else { return }
            // If health is unknown, or the model/server isn't ready, run setup.
            let ready = health?.ok == true && health?.model == true && health?.ollama == true
            if !ready {
                self.beginSetup(onFinish: onFinish)
            } else {
                onFinish?(true)
            }
        }
    }

    private func beginSetup(onFinish: ((Bool) -> Void)? = nil) {
        guard !isRunning else { return }
        self.onFinish = onFinish
        operation = CoreBridge.ensureModel
        showWindow()
        start()
    }

    /// Live model switch (Settings model picker): unload the current model and
    /// download-if-needed + load the newly selected one, showing the same progress
    /// window. Unlike `beginSetup` this ALWAYS runs (the target model differs) and
    /// routes through `CoreBridge.switchModel`.
    func runSwitch(onFinish: ((Bool) -> Void)? = nil) {
        guard !isRunning else { return }
        self.onFinish = onFinish
        operation = CoreBridge.switchModel
        showWindow()
        start()
    }

    /// Runs (or re-runs, on Retry) the stored operation against the live window.
    private func start() {
        guard !isRunning, let operation else { return }
        isRunning = true
        operation(
            { [weak self] progress in self?.update(with: progress) },
            { [weak self] success in self?.finish(success: success) }
        )
    }

    /// Cancel / Esc / close box. Aborts any in-flight load, then closes and reverts.
    /// Works both during a run and after a failure (when `isRunning` is already
    /// false and the window sits on its error state) — so the window is never stuck.
    /// The pending `completion(false)` from an aborted load is swallowed by `finish`
    /// (already not running) — the revert is driven from here.
    @objc private func cancelTapped() {
        if isRunning {
            isRunning = false
            CoreBridge.cancelModelLoad()
        }
        closeWindow()
        let cb = onFinish; onFinish = nil
        cb?(false)
    }

    /// Retry after a failure: re-run the same operation in the existing window.
    @objc private func retryTapped() {
        guard !isRunning, operation != nil else { return }
        retryButton?.isHidden = true
        statusLabel?.stringValue = "Preparing the language model\u{2026}"
        progressBar?.isIndeterminate = true
        progressBar?.startAnimation(nil)
        start()
    }

    // MARK: - UI

    private func showWindow() {
        // E2E: load the model headlessly. The progress window's NSApp.activate
        // would steal frontmost from the external E2EHost field under test.
        if ProcessInfo.processInfo.environment["PROSPER_E2E"] == "1" { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Prosper Setup"
        window.delegate = self
        window.isReleasedWhenClosed = false
        // Neon-console chrome, same treatment as Settings / extension windows.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Neon.bgTop)
        window.appearance = NSAppearance(named: .darkAqua)
        window.centerOnScreen()

        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        content.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "Preparing the language model\u{2026}")
        label.textColor = NSColor(Neon.textPrimary)
        label.frame = NSRect(x: 20, y: 100, width: 340, height: 20)
        label.autoresizingMask = [.width, .minYMargin]
        content.addSubview(label)
        statusLabel = label

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 70, width: 340, height: 20))
        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 100
        bar.autoresizingMask = [.width, .minYMargin]
        bar.startAnimation(nil)
        content.addSubview(bar)
        progressBar = bar

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 280, y: 16, width: 80, height: 28)
        cancel.autoresizingMask = [.minXMargin, .maxYMargin]
        cancel.keyEquivalent = "\u{1b}" // Esc cancels
        content.addSubview(cancel)

        // Hidden until a failure; re-runs the same operation in this window.
        let retry = NSButton(title: "Retry", target: self, action: #selector(retryTapped))
        retry.bezelStyle = .rounded
        retry.frame = NSRect(x: 192, y: 16, width: 80, height: 28)
        retry.autoresizingMask = [.minXMargin, .maxYMargin]
        retry.keyEquivalent = "\r" // Return retries
        retry.isHidden = true
        content.addSubview(retry)
        retryButton = retry

        window.contentView = content
        self.window = window

        DockPolicy.windowDidShow(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func update(with progress: SetupProgress) {
        statusLabel?.stringValue = progress.status

        if let percent = progress.percent, percent > 0 {
            progressBar?.isIndeterminate = false
            progressBar?.doubleValue = min(max(percent, 0), 100)
        } else if let total = progress.total, total > 0, let completed = progress.completed {
            progressBar?.isIndeterminate = false
            progressBar?.doubleValue = Double(completed) / Double(total) * 100.0
        }

        if progress.phase == "done" {
            progressBar?.doubleValue = 100
        }
    }

    private func finish(success: Bool) {
        // Cancel already handled teardown + callback; swallow the aborted load's
        // trailing completion(false).
        guard isRunning else { return }
        isRunning = false
        if success {
            let cb = onFinish; onFinish = nil
            closeWindow()
            cb?(true)
            return
        }
        // Failure: keep the window AND `onFinish` so Retry can re-run, or Cancel can
        // close + revert the selection. (Don't fire onFinish here — that would revert
        // the pending model, making a retry switch back to the old one.)
        progressBar?.stopAnimation(nil)
        statusLabel?.stringValue = "Setup failed \u{2014} check your internet connection, then Retry."
        retryButton?.isHidden = false
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let window { DockPolicy.windowDidHide(window) }
        window = nil
    }
}
