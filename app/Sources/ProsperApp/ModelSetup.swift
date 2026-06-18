import AppKit
import SwiftUI

/// Shows a small progress window that drives `CoreBridge.ensureModel` (MLXEngine
/// download + load) and reports download progress. Invoked on launch when the
/// model isn't ready, or manually.
@MainActor
final class ModelSetup: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var isRunning = false
    private var wasCancelled = false
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
        isRunning = true
        wasCancelled = false
        self.onFinish = onFinish
        showWindow()

        CoreBridge.ensureModel(
            progress: { [weak self] progress in
                self?.update(with: progress)
            },
            completion: { [weak self] success in
                self?.finish(success: success)
            }
        )
    }

    /// Live model switch (Settings model picker): unload the current model and
    /// download-if-needed + load the newly selected one, showing the same progress
    /// window. Unlike `beginSetup` this ALWAYS runs (the target model differs) and
    /// routes through `CoreBridge.switchModel`.
    func runSwitch(onFinish: ((Bool) -> Void)? = nil) {
        guard !isRunning else { return }
        isRunning = true
        wasCancelled = false
        self.onFinish = onFinish
        showWindow()

        CoreBridge.switchModel(
            progress: { [weak self] progress in
                self?.update(with: progress)
            },
            completion: { [weak self] success in
                self?.finish(success: success)
            }
        )
    }

    /// User pressed Cancel: abort the in-flight download/load and close the window.
    /// The pending `completion(false)` from the aborted load is swallowed by
    /// `finish` (already not running) — the revert is driven from here.
    @objc private func cancelTapped() {
        guard isRunning else { return }
        wasCancelled = true
        isRunning = false
        CoreBridge.cancelModelLoad()
        closeWindow()
        let cb = onFinish; onFinish = nil
        cb?(false)
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
        let cb = onFinish; onFinish = nil
        if success {
            closeWindow()
            cb?(true)
            return
        }
        // Leave the window up with the error so the user can retry from the menu.
        progressBar?.stopAnimation(nil)
        statusLabel?.stringValue = "Setup failed. Use \u{201C}Re-run Setup\u{2026}\u{201D} to try again."
        cb?(false)
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
