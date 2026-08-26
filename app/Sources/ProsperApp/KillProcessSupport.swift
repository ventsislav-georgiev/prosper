// The single seam for "may this process be killed — and kill it".
//
// TRUST BOUNDARY. Two consumers share it and neither owns a copy of the rules:
//   * the killproc extension, through `host.process.refusal` / `host.process.kill`
//   * the stats popups' process lists, natively (StatsPopupView)
//
// Refusals: pid <= 1 (kernel_task / launchd), Prosper's own pid, a name
// blocklist, and a process that no longer exists. The name is resolved HERE from
// the pid via libproc — a caller never gets to say what a pid is called, so a
// caller can never talk its way past the blocklist.

import Darwin
import Foundation

enum KillProcessSupport {
    /// Processes macOS (or the user) cannot survive losing. Matched on the
    /// executable's base name.
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Prosper",
    ]

    /// Executable name for `pid` per libproc, or nil when the process is gone.
    static func processName(_ pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard n > 0 else { return nil }
        if let nul = buf.firstIndex(of: 0) { buf.removeSubrange(nul...) }
        let name = String(decoding: buf, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// Why killing `pid` is refused, or nil when it is allowed. The resolver and
    /// own-pid are arguments purely so tests can drive the rules without real
    /// processes; production always takes the defaults.
    static func refusal(pid: pid_t,
                        name: (pid_t) -> String? = processName,
                        own: pid_t = getpid()) -> String? {
        if pid <= 1 { return "system pid" }
        if pid == own { return "that's Prosper" }
        guard let raw = name(pid)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return "no such process" }
        // `ps -o comm=` hands back a full path; libproc hands back a bare name.
        // Take the base name either way so both callers see the same rule.
        let base = String(raw.split(separator: "/").last ?? "")
        if protectedNames.contains(base) { return "protected: \(base)" }
        return nil
    }

    /// Signals `pid` (SIGTERM, or SIGKILL when `force`). Returns nil when the
    /// signal was sent, or the refusal reason when the guards said no — the
    /// guards run here, so no caller can skip them.
    @discardableResult
    static func kill(pid: pid_t, force: Bool,
                     name: (pid_t) -> String? = processName,
                     own: pid_t = getpid(),
                     send: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }) -> String? {
        if let why = refusal(pid: pid, name: name, own: own) { return why }
        return send(pid, force ? SIGKILL : SIGTERM) == 0 ? nil : "kill failed"
    }
}
