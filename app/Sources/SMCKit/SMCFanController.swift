// SMCFanController — the ONLY sanctioned path to mutate fan state.
//
// Every write is whitelisted, fanID-bounded, and rpm-clamped FAIL-CLOSED at
// this layer (not just at the XPC boundary) so no caller can drive a fan to an
// unsafe speed or write an arbitrary SMC key as root. Forced-LOW is the thermal
// hazard, so the clamp guards the low side with a hardcoded floor independent
// of SMC-reported bounds.
//
// Apple Silicon (M1–M4, `Ftst` present): going manual is a layered unlock —
// set `Ftst=1`, let thermalmonitord yield, then hammer the mode key. M5+ lack
// `Ftst` and accept a direct mode write. Validated on M4 Pro: mode key is
// uppercase `F{i}Md`, bounds `flt `, Ftst present.

import Foundation

public enum FanMode: Int, Sendable, Codable {
    case auto = 0      // OS thermal daemon owns the fan
    case manual = 1    // forced to a target RPM
    case full = 2      // forced to max
}

public struct FanBounds: Equatable {
    public let min: Double
    public let max: Double
}

public final class SMCFanController {
    private let smc: SMC

    // Absolute safety rails, independent of (untrusted) SMC-reported bounds. The
    // FLOOR is the single load-bearing thermal backstop — distrusting SMC bounds on
    // the low side. Before adding a newly supported Mac, confirm 200 RPM is survivable
    // on its coldest-idle chassis, or promote this to a per-model calibration knob.
    private static let absoluteFloorRPM: Double = 200      // never command below this
                                                           // ponytail: per-model floor if a future chassis needs more

    private static let absoluteCeilRPM: Double = 20_000    // sanity ceiling

    /// Cached per-fan mode-key form: uppercase `F{i}Md` (Intel/most AS) vs
    /// lowercase `F{i}md` (some AS). Probed once.
    private var modeKeyUppercase: Bool?

    /// Optional per-attempt unlock trace sink. The daemon points this at its
    /// `fanLog` so a live engage logs Ftst/mode state per round — the ONLY way to
    /// tell a "firmware still yielding" reject apart from a "Ftst got dropped"
    /// reject after the fact. Nil in tests / app-side.
    public var onTrace: ((String) -> Void)?
    private func trace(_ s: String) { onTrace?(s) }

    public init(_ smc: SMC) { self.smc = smc }

    // MARK: Read-side helpers

    public func fanCount() -> Int {
        guard let v = smc.read("FNum")?.double, v.isFinite, v >= 0 else { return 0 }
        return Int(v)
    }

    /// Reads `[F{i}Mn, F{i}Mx]`. Returns nil (→ caller fails closed) if the
    /// bounds are unreadable or degenerate.
    public func bounds(_ i: Int) -> FanBounds? {
        guard let mn = smc.read("F\(i)Mn")?.double, let mx = smc.read("F\(i)Mx")?.double,
              mn.isFinite, mx.isFinite,
              mn > 0, mx > mn, mx < Self.absoluteCeilRPM
        else { return nil }
        return FanBounds(min: mn, max: mx)
    }

    public func currentRPM(_ i: Int) -> Double? { smc.read("F\(i)Ac")?.double }

    /// True on M1–M4 (layered unlock required); false on M5+ (direct mode write).
    public func hasFtst() -> Bool { smc.exists("Ftst") }

    private func modeKey(_ i: Int) -> String {
        if modeKeyUppercase == nil {
            modeKeyUppercase = smc.exists("F0Md") || !smc.exists("F0md")
        }
        return modeKeyUppercase! ? "F\(i)Md" : "F\(i)md"
    }

    // MARK: Write whitelist (enforced here, the lowest mutating layer)

    private static let writeAllowed: Set<String> = ["Ftst", "FS! "]
    private func keyAllowed(_ key: String) -> Bool {
        if Self.writeAllowed.contains(key) { return true }
        // F{n}Md / F{n}md / F{n}Tg
        guard key.count == 4, key.first == "F",
              let idx = key.dropFirst().first, idx.isNumber else { return false }
        let tail = String(key.suffix(2))
        return tail == "Md" || tail == "md" || tail == "Tg"
    }
    private func guardedWrite(_ key: String, _ bytes: [UInt8]) throws {
        guard keyAllowed(key) else { throw SMCError.writeNotAllowed(key) }
        // Centralized clamp: any RPM target write (`F{n}Tg`) is re-decoded and
        // re-clamped to the absolute rails HERE, so no in-module caller can write
        // an out-of-rail speed by reaching guardedWrite directly — the value bound
        // no longer depends on every caller routing through setManual.
        let safeBytes = key.hasSuffix("Tg") ? clampTargetBytes(bytes) : bytes
        // Tag the failing key onto a firmware rejection so the daemon log names WHICH
        // write the chassis refused (Ftst unlock / F{i}Md mode / F{i}Tg target) — the
        // bare result byte alone can't tell those apart.
        do { try smc.writeRawUnchecked(key, safeBytes) }
        catch SMCError.firmwareReject(let r) { throw SMCError.writeReject(key, r) }
    }

    /// Decode an RPM target (format depends on platform), clamp to the absolute
    /// floor/ceiling, re-encode. Floor is the thermal hazard, so it's hard-guarded.
    private func clampTargetBytes(_ bytes: [UInt8]) -> [UInt8] {
        let ftst = hasFtst()
        let rpm = ftst ? Double(SMCDecode.decodeFloatLE(bytes))
                       : Double(SMCDecode.decodeFPE2(bytes))
        guard rpm.isFinite else { return ftst ? SMCDecode.encodeFloatLE(Float(Self.absoluteFloorRPM))
                                              : SMCDecode.encodeFPE2(Int(Self.absoluteFloorRPM)) }
        let safe = Swift.min(Swift.max(rpm, Self.absoluteFloorRPM), Self.absoluteCeilRPM)
        return ftst ? SMCDecode.encodeFloatLE(Float(safe)) : SMCDecode.encodeFPE2(Int(safe))
    }

    // MARK: Manual / auto

    /// Force fan `i` to `rpm`, clamped fail-closed to a safe range. Throws
    /// `clampUnsafe` (and leaves the fan on auto) if bounds can't be trusted.
    public func setManual(_ i: Int, rpm: Double) throws {
        guard i >= 0, i < fanCount() else { throw SMCError.keyNotFound("F\(i)") }
        guard let b = bounds(i) else {
            try? setAuto(i)                          // fail closed: hand fan back to OS
            throw SMCError.clampUnsafe("F\(i)")
        }
        let lo = Swift.max(b.min, Self.absoluteFloorRPM)
        let hi = Swift.min(b.max, Self.absoluteCeilRPM)
        let safe = Swift.min(Swift.max(rpm, lo), hi)

        // Fail CLOSED across the whole manual sequence: if the unlock half-succeeds
        // (mode flipped to manual / Ftst=1) but the target write then throws, the fan
        // would be left in manual driven by a stale (possibly very low) F{i}Tg with
        // nothing supervising it. Hand it back to the OS before rethrowing so a failed
        // setManual can NEVER leave a fan wedged at an unsafe speed.
        do {
            // Skip the unlock dance if the fan is already manual — re-running it on
            // every slider commit re-triggers the 3 s thermalmonitord yield and makes
            // the control feel dead. (Matches Stats' setFanSpeed: unlock only when the
            // mode key isn't already 1.)
            if (smc.read(modeKey(i))?.double ?? 0) != 1 { try unlock(i) }
            try writeTarget(i, rpm: safe)
        } catch {
            try? setAuto(i)
            throw error
        }
    }

    public func setFull(_ i: Int) throws {
        guard let b = bounds(i) else { try? setAuto(i); throw SMCError.clampUnsafe("F\(i)") }
        try setManual(i, rpm: b.max)
    }

    /// Return fan `i` to OS thermal control.
    public func setAuto(_ i: Int) throws {
        if hasFtst() {
            // M1–M4: clearing Ftst hands all fans back. Also zero this fan's mode.
            try? guardedWrite(modeKey(i), [0])
            try guardedWrite("Ftst", [0])
        } else {
            // M5+: zero the mode key. (Intel additionally clears FS! — see resetAll.)
            try guardedWrite(modeKey(i), [0])
        }
    }

    /// Reset every fan to auto. Cheap, idempotent — the thermal-safety primitive
    /// called on launch, sleep, disconnect, version-skew. Returns whether the
    /// CRITICAL clears (per-fan mode key, and `Ftst=0` on AS) all succeeded, so the
    /// caller can keep the crash-safety armed and retry instead of believing a
    /// silently-failed reset handed the fans back. The Intel `FS!` bitmask clear is
    /// best-effort and does not gate the result (absent on Apple Silicon).
    @discardableResult
    public func resetAll() -> Bool {
        let n = fanCount()
        var ok = true
        for i in 0..<Swift.max(n, 0) {
            do { try guardedWrite(modeKey(i), [0]) } catch { ok = false }
        }
        if hasFtst() {
            do { try guardedWrite("Ftst", [0]) } catch { ok = false }   // M1–M4 master unlock-clear
        }
        try? guardedWrite("FS! ", [0, 0]) // Intel force bitmask (best effort)
        return ok
    }

    // MARK: AS unlock sequence

    private func unlock(_ i: Int) throws {
        let key = modeKey(i)
        let manual = [UInt8(FanMode.manual.rawValue)]
        // Try the DIRECT mode write first — succeeds on M5+ (no Ftst) and on any board
        // whose firmware accepts it without the thermal-daemon handoff. Stats does this
        // first and only falls back to the Ftst dance when the direct write is rejected;
        // a rigid hasFtst() branch took the wrong path on some M-series chassis.
        if (try? guardedWrite(key, manual)) != nil { trace("unlock(\(i)) direct ok"); return }

        guard hasFtst() else {
            // No Ftst and the direct write was rejected — last resort, retry it spaced.
            try retry(times: 50, delayMicros: 100_000) { try self.guardedWrite(key, manual) }
            return
        }
        // M1–M4 layered unlock. Measured on this M4: after `Ftst=1` the firmware keeps
        // rejecting the mode write with 0x82 for ~8s while thermalmonitord yields (the
        // mode key READS 0 several seconds before WRITES are accepted). So the attempts
        // must be SPACED over a window wider than that worst case.
        //
        // Critically, re-assert `Ftst=1` every round, not once up front: `Ftst`
        // auto-clears on sleep and can be dropped by a concurrent reset (a sibling
        // disable / sleep observer) mid-wait — after which every mode write rejects
        // forever and the old single-shot unlock would burn its whole window for nothing.
        // Re-pulsing makes the unlock self-healing and costs one extra cheap write/round.
        try? guardedWrite("Ftst", [1])
        usleep(500_000)                       // brief settle; the loop spans the real yield
        var last: Error?
        let rounds = 150                       // 150 × ~100ms ≈ 15s, past the measured ~8s
        for n in 0..<rounds {
            if n % 10 == 0 { try? guardedWrite("Ftst", [1]) }   // ~1s re-assert, cheap
            do { try guardedWrite(key, manual); trace("unlock(\(i)) ok @round \(n)"); return }
            catch { last = error }
            if n % 20 == 0 {
                let f = smc.read("Ftst")?.double ?? -1
                let m = smc.read(key)?.double ?? -1
                trace("unlock(\(i)) round \(n): Ftst=\(f) \(key)=\(m) last=\(String(describing: last))")
            }
            usleep(100_000)
        }
        throw last ?? SMCError.firmwareReject(0xff)
    }

    private func writeTarget(_ i: Int, rpm: Double) throws {
        // Encode to the key's ACTUAL type (read it), not a hasFtst() guess: AS reports
        // `flt ` (LE Float32), Intel `fpe2`. Matches Stats reading value.dataType.
        let type = smc.read("F\(i)Tg")?.type ?? (hasFtst() ? "flt " : "fpe2")
        let bytes = type == "fpe2" ? SMCDecode.encodeFPE2(Int(rpm))
                                   : SMCDecode.encodeFloatLE(Float(rpm))
        try retry(times: 100, delayMicros: 50_000) { try self.guardedWrite("F\(i)Tg", bytes) }
    }

    /// Bounded retry with a delay BETWEEN attempts — AS firmware rejects writes
    /// transiently while the thermal daemon yields, and it can take seconds; the
    /// attempts must be spaced (Stats uses 50–100 ms) not burned instantly. Never loops
    /// forever. ponytail: fixed spacing; per-board backoff only if a chassis needs it.
    private func retry(times: Int, delayMicros: UInt32 = 50_000, _ op: () throws -> Void) throws {
        var last: Error?
        for n in 0..<times {
            do { try op(); return } catch { last = error }
            if n < times - 1 { usleep(delayMicros) }
        }
        throw last ?? SMCError.firmwareReject(0xff)
    }
}
