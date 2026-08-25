import XCTest

@testable import StatsCore

/// NVMe SMART. The user-client call can't run in CI (and needs real hardware), so
/// the byte-level decode is exercised against a synthetic log page and the live
/// path only gets one tolerant, skippable integration probe.
final class DiskSMARTTests: XCTestCase {

    /// Builds a 512-byte `nvme_smart_log` with the fields we decode, little-endian.
    private func page(percentUsed: UInt8 = 3, kelvin: UInt16 = 312,
                      unitsRead: UInt64 = 0, unitsWritten: UInt64 = 0,
                      powerCycles: UInt32 = 0, powerOnHours: UInt32 = 0,
                      unsafeShutdowns: UInt32 = 0, mediaErrors: UInt32 = 0) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 512)
        p[1] = UInt8(kelvin & 0xff); p[2] = UInt8(kelvin >> 8)
        p[5] = percentUsed
        func put64(_ v: UInt64, _ o: Int) { for i in 0..<8 { p[o + i] = UInt8((v >> (8 * UInt64(i))) & 0xff) } }
        func put32(_ v: UInt32, _ o: Int) { for i in 0..<4 { p[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) } }
        put64(unitsRead, 32); put64(unitsWritten, 48)
        put32(powerCycles, 112); put32(powerOnHours, 128)
        put32(unsafeShutdowns, 144); put32(mediaErrors, 160)
        return p
    }

    func testDecodesEveryField() throws {
        let s = try XCTUnwrap(DiskSMART.decode(logPage: page(
            percentUsed: 7, kelvin: 312,
            unitsRead: 1_000, unitsWritten: 2_000,
            powerCycles: 431, powerOnHours: 5_112,
            unsafeShutdowns: 12, mediaErrors: 0)))
        XCTAssertEqual(s.healthPercent, 93, "health is 100 − percent_used")
        XCTAssertEqual(try XCTUnwrap(s.celsius), 39, accuracy: 0.001, "312 K − 273")
        // NVMe data unit = 1000 × 512 B, so the numbers are bytes, not units.
        XCTAssertEqual(s.totalRead, 512_000_000)
        XCTAssertEqual(s.totalWritten, 1_024_000_000)
        XCTAssertEqual(s.powerCycles, 431)
        XCTAssertEqual(s.powerOnHours, 5_112)
        XCTAssertEqual(s.unsafeShutdowns, 12)
        XCTAssertEqual(s.mediaErrors, 0)
    }

    /// Byte order is the whole risk in this decode: a big-endian read of the same
    /// page would give 0x3801 = 14337 K, not 312 K.
    func testTemperatureIsLittleEndian() throws {
        var p = page()
        p[1] = 0x38; p[2] = 0x01     // 0x0138 = 312
        let s = try XCTUnwrap(DiskSMART.decode(logPage: p))
        XCTAssertEqual(try XCTUnwrap(s.celsius), 39, accuracy: 0.001)
    }

    func testZeroKelvinReportsNoTemperature() throws {
        let s = try XCTUnwrap(DiskSMART.decode(logPage: page(kelvin: 0)))
        XCTAssertNil(s.celsius, "0 K means the drive doesn't report composite temperature")
    }

    /// A drive past its rated endurance reports percent_used > 100; health must
    /// floor at 0 rather than go negative.
    func testHealthFloorsAtZero() throws {
        let s = try XCTUnwrap(DiskSMART.decode(logPage: page(percentUsed: 137)))
        XCTAssertEqual(s.healthPercent, 0)
    }

    /// × 512 000 on a garbage 128-bit counter must saturate, not trap.
    func testLifetimeBytesSaturateInsteadOfTrapping() throws {
        let s = try XCTUnwrap(DiskSMART.decode(logPage: page(unitsWritten: UInt64.max)))
        XCTAssertEqual(s.totalWritten, UInt64.max)
    }

    func testShortPageIsRejected() {
        XCTAssertNil(DiskSMART.decode(logPage: [UInt8](repeating: 0, count: 511)),
                     "a truncated page would decode as garbage")
    }

    // MARK: - Integration (real host, tolerant)

    /// The `@convention(c)` signatures fault at call time, not link time — this is
    /// the only check that they're right. Skips on anything without NVMe SMART.
    func testRealHostSMARTIsPlausibleOrAbsent() throws {
        var st = statfs()
        guard statfs("/", &st) == 0 else { throw XCTSkip("statfs / failed") }
        let bsd = withUnsafeBytes(of: st.f_mntfromname) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            .replacingOccurrences(of: "/dev/", with: "")
        guard let s = NVMeSMART.read(bsdName: bsd) else {
            throw XCTSkip("no NVMe SMART on \(bsd)")
        }
        XCTAssertTrue((0...100).contains(s.healthPercent))
        if let c = s.celsius { XCTAssertTrue((0...120).contains(c), "\(c)°C is not a drive temperature") }
        XCTAssertGreaterThan(s.totalWritten, 0, "a booted machine has written something")
        XCTAssertGreaterThan(s.powerOnHours, 0)
        XCTAssertLessThan(s.powerOnHours, 1_000_000, "~114 years of uptime means a bad offset")
    }
}
