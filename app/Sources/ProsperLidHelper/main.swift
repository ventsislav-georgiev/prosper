import Foundation
import LidHelperProtocol

// ProsperLidHelper — the privileged daemon behind "keep awake with the lid
// closed". Installed via SMAppService.daemon, launched by launchd as root on the
// first XPC message. Its ONLY job is `pmset -a disablesleep 0/1`, which needs
// root — that root requirement is the whole reason the daemon exists (it removes
// the old sudoers hack). It holds no model, no UI, no timers beyond a short
// idle-exit; resident memory is a few hundred KB and it exits entirely when no
// client is connected.

// Code-signing requirement the connecting client MUST satisfy before this root
// daemon will touch a system power setting. Pins to Prosper's bundle id + Team
// (Developer ID anchor) so no other local process can ask root to disable sleep.
// A self-signed / ad-hoc dev build does NOT satisfy `anchor apple generic`, so
// the feature is simply inert there — acceptable: it is a release-only path.
private let clientRequirement =
    "identifier \"eu.illegible.prosper\" and anchor apple generic and "
    + "certificate leaf[subject.OU] = \"V5XV3994L8\""

final class LidHelper: NSObject, LidHelperProtocol, NSXPCListenerDelegate {
    // Single serial queue guards all mutable state — XPC delivers connection
    // events + method calls on arbitrary queues.
    private let q = DispatchQueue(label: "\(lidHelperLabel).state")
    private var connections = 0
    private var disabled = false              // is the override currently on?
    private var idleTimer: DispatchSourceTimer?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // The OS invalidates the connection automatically if the peer fails this
        // requirement, so an impostor never reaches setLidSleepDisabled.
        conn.setCodeSigningRequirement(clientRequirement)
        conn.exportedInterface = NSXPCInterface(with: LidHelperProtocol.self)
        conn.exportedObject = self
        conn.invalidationHandler = { [weak self] in self?.connectionClosed() }
        conn.interruptionHandler  = { [weak self] in self?.connectionClosed() }
        q.sync {
            connections += 1
            cancelIdleExit_locked()
        }
        conn.resume()
        return true
    }

    private func connectionClosed() {
        q.async {
            self.connections = max(0, self.connections - 1)
            if self.connections == 0 {
                // App quit or crashed — NEVER leave the lid override wedged on.
                if self.disabled {
                    self.applyPmset(false)
                    self.disabled = false
                }
                self.armIdleExit_locked()
            }
        }
    }

    func setLidSleepDisabled(_ on: Bool, withReply reply: @escaping (Bool) -> Void) {
        q.async {
            let ok = self.applyPmset(on)
            if ok { self.disabled = on }
            reply(ok)
        }
    }

    // pmset is a one-shot toggle (not a hot path); shelling it matches openlid and
    // is trivially correct. Runs as root here, so no sudo. // ponytail: pmset over
    // raw IOKit IOPMSetSystemPowerSetting — switch only if spawn cost ever matters.
    @discardableResult
    private func applyPmset(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    // launchd relaunches the daemon on the next message, so exiting when idle frees
    // ALL memory at zero cost. Only armed once no client is connected (and, by
    // connectionClosed above, the override is already off). Must run on `q`.
    private func armIdleExit_locked() {
        cancelIdleExit_locked()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 10)
        t.setEventHandler { [weak self] in
            guard let self else { exit(0) }
            if self.connections == 0 { exit(0) }
        }
        t.resume()
        idleTimer = t
    }

    private func cancelIdleExit_locked() {
        idleTimer?.cancel()
        idleTimer = nil
    }
}

let delegate = LidHelper()
let listener = NSXPCListener(machServiceName: lidHelperMachServiceName)
listener.delegate = delegate
listener.resume()
// Block on the run loop; launchd owns our lifecycle and the idle-exit above ends
// the process when no client remains.
RunLoop.current.run()
