import Foundation
@testable import ProsperApp

/// Cleanup signal that refuses 0, 1 and -1 (through pid > 1), our own group and our own
/// pid: a pid read from a process or a file could be any of them (#380, #386, #401).
/// Returns kill's result, or nil when the pid was refused and nothing was sent.
@discardableResult
func killIfReal(_ pid: pid_t, group: Bool = true, using signal: (pid_t, Int32) -> Int32 = kill) -> Int32? {
    guard CodexHarness.mayKillGroup(pid), pid != getpid() else { return nil }
    return signal(group ? -pid : pid, SIGKILL)
}

/// A pid parsed from script output or a file; nil unless > 1 so an XCTUnwrap fails (#380).
func parsePid(_ text: String?) -> pid_t? {
    text.flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 > 1 ? $0 : nil }
}
