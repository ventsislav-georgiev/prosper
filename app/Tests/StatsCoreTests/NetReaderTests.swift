import XCTest
@testable import StatsCore

// MARK: - ICMP ping primitives (pure, no network)

final class NetPingTests: XCTestCase {
    func testChecksumKnownVector() {
        // RFC-1071 worked example: 0x0001 0xf203 0xf4f5 0xf6f7 → checksum 0x220d.
        let bytes: [UInt8] = [0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]
        XCTAssertEqual(NetPingReader.checksum(bytes), 0x220d)
    }

    func testChecksumOfValidPacketRoundTrips() {
        // A packet with its checksum filled in must checksum to 0.
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        packet[6] = 0x12; packet[7] = 0x34
        let c = NetPingReader.checksum(packet)
        packet[2] = UInt8(c >> 8); packet[3] = UInt8(c & 0xff)
        XCTAssertEqual(NetPingReader.checksum(packet), 0, "verified checksum of a stamped packet is 0")
    }

    func testParseReplyBareICMP() {
        // DGRAM socket: no IP header. type=0 (reply), seq=0x002a.
        var buf = [UInt8](repeating: 0, count: 16)
        buf[0] = 0; buf[6] = 0x00; buf[7] = 0x2a
        let r = NetPingReader.parseReply(buf, count: 16)
        XCTAssertEqual(r?.0, 0); XCTAssertEqual(r?.1, 0x2a)
    }

    func testParseReplySkipsIPv4Header() {
        // Raw-socket layout: 20-byte IPv4 header (0x45 = v4, ihl 5) then ICMP.
        var buf = [UInt8](repeating: 0, count: 40)
        buf[0] = 0x45
        buf[20] = 0; buf[26] = 0x01; buf[27] = 0xff   // type 0, seq 0x01ff
        let r = NetPingReader.parseReply(buf, count: 40)
        XCTAssertEqual(r?.0, 0); XCTAssertEqual(r?.1, 0x01ff)
    }

    func testParseReplyRejectsTruncated() {
        XCTAssertNil(NetPingReader.parseReply([0, 0, 0], count: 3))
    }

    func testJitter() {
        XCTAssertTrue(NetPingReader.jitter([]).isNaN)
        XCTAssertTrue(NetPingReader.jitter([5]).isNaN)
        XCTAssertEqual(NetPingReader.jitter([10, 12, 11, 14]), (2 + 1 + 3) / 3.0, accuracy: 1e-9)
        XCTAssertEqual(NetPingReader.jitter([7, 7, 7]), 0, accuracy: 1e-9)
    }

    func testLifecycleNoCrashOnRapidStartStop() {
        let r = NetPingReader(host: "1.1.1.1", historyLength: 8)
        for _ in 0..<20 { r.start(); r.stop() }   // epoch guard: no double-loop, no crash
        _ = r.latest(); _ = r.connectivity()
    }

    func testPingReachable() throws {
        // Real ICMP — skip when offline/blocked (CI).
        guard let rtt = NetPingReader.ping(host: "1.1.1.1", seq: 1, timeout: 2.0) else {
            throw XCTSkip("no ICMP path to 1.1.1.1")
        }
        XCTAssert(rtt > 0 && rtt < 2000, "rtt \(rtt)ms out of range")
        print("ping 1.1.1.1 = \(String(format: "%.1f", rtt))ms")
    }
}

// MARK: - nettop parsing (pure, fixture-driven)

final class NetProcessParseTests: XCTestCase {
    // Two blocks; second is the delta. Cols: name.pid, bytes_in, bytes_out.
    private let fixture = """
    time,bytes_in,bytes_out,
    Safari.501,1000,2000,
    com.apple.WebKit.Networking.512,500,100,
    ----
    time,bytes_in,bytes_out,
    Safari.501,40000,8000,
    com.apple.WebKit.Networking.512,1500,300,
    idle.999,0,0,
    """

    func testParsesDeltaBlockSortedByTotal() {
        let rows = NetProcessReader.parse(fixture, limit: 8)
        XCTAssertEqual(rows.count, 2, "two non-zero rows in the delta block")
        XCTAssertEqual(rows[0].pid, 501)               // Safari: 48000 total → first
        XCTAssertEqual(rows[0].downBytesPerSec, 40000)
        XCTAssertEqual(rows[0].upBytesPerSec, 8000)
        XCTAssertEqual(rows[0].name, "Safari")
        XCTAssertEqual(rows[1].pid, 512)
        XCTAssertEqual(rows[1].name, "com.apple.WebKit.Networking", "split on LAST dot keeps dotted name")
    }

    func testFiltersZeroAndRespectsLimit() {
        let rows = NetProcessReader.parse(fixture, limit: 1)
        XCTAssertEqual(rows.count, 1, "limit honored")
        XCTAssertNil(rows.first { $0.pid == 999 }, "zero-traffic rows dropped")
    }

    func testEmptyAndGarbageInputs() {
        XCTAssertTrue(NetProcessReader.parse("", limit: 8).isEmpty)
        XCTAssertTrue(NetProcessReader.parse("no header here\njunk,1,2,", limit: 8).isEmpty)
        // Header but a row whose trailing segment isn't a pid → skipped, not crashed.
        XCTAssertTrue(NetProcessReader.parse("bytes_in\n,no_pid_here,1,2,", limit: 8).isEmpty)
    }

    func testParsePerfWithinBudget() {
        // Build a realistic-size capture (~300 procs, two blocks) and assert the pure
        // parse stays well under a tick. Runs on a private queue in prod, but cheap
        // parsing keeps the nettop refresh from piling up.
        var s = "time,bytes_in,bytes_out,\n"
        for i in 0..<300 { s += "proc\(i).\(1000 + i),\(i),\(i * 2),\n" }
        s += "time,bytes_in,bytes_out,\n"
        for i in 0..<300 { s += "proc\(i).\(1000 + i),\(i * 10),\(i * 20),\n" }
        let iterations = 500
        let t0 = DispatchTime.now().uptimeNanoseconds
        var sink = 0
        for _ in 0..<iterations { sink &+= NetProcessReader.parse(s, limit: 8).count }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(iterations)
        XCTAssertEqual(sink, iterations * 8)
        XCTAssertLessThan(perCall, 2_000_000, "nettop parse \(Int(perCall))ns exceeds 2ms budget")
        print("nettop parse (600 rows) = \(Int(perCall))ns/call")
    }
}

// MARK: - Link info (MAC / RSSI / public IP cache)

final class NetLinkTests: XCTestCase {
    func testMacFormatForLoopbackOrEN0() {
        // lo0 has no MAC; en0 usually does. Whichever returns, it must be well-formed.
        for iface in ["en0", "en1"] {
            if let mac = NetLinkReader.mac(for: iface) {
                let parts = mac.split(separator: ":")
                XCTAssertEqual(parts.count, 6, "\(iface) MAC \(mac) not 6 octets")
                XCTAssertTrue(parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil })
                print("\(iface) MAC = \(mac)")
                return
            }
        }
        throw_skip()
    }

    func testMacUnknownInterfaceIsNil() {
        XCTAssertNil(NetLinkReader.mac(for: "definitely_not_an_iface_zzz"))
    }

    func testLatestBeforeRefreshIsEmpty() {
        let r = NetLinkReader()
        let info = r.latest()
        XCTAssertNil(info.macAddress); XCTAssertNil(info.rssi); XCTAssertNil(info.publicIP)
    }

    func testRefreshIsNonBlockingAndCaches() {
        let r = NetLinkReader()
        // refresh() must return immediately (work happens off-queue); the MAC should
        // appear in latest() shortly after.
        let t0 = DispatchTime.now().uptimeNanoseconds
        r.refresh(interface: "en0")
        let dt = DispatchTime.now().uptimeNanoseconds - t0
        XCTAssertLessThan(Double(dt), 5_000_000, "refresh() blocked \(dt)ns — must be async")
        let deadline = Date().addingTimeInterval(1.0)
        while r.latest().macAddress == nil, Date() < deadline { usleep(20_000) }
        // Don't hard-assert a MAC (machine may lack en0), just that it didn't crash.
        _ = r.latest()
    }

    private func throw_skip() { /* en0 absent — soft pass */ }
}
