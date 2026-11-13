import Darwin
import XCTest
@testable import ProsperApp
@testable import StatsCore

/// #1003 (QA #148): the C-buffer decodes QA mutated, where a dropped `prefix { $0 != 0 }` ships
/// the buffer's trailing NULs, and none was reached by a test. Real sysctl and getifaddrs reads
/// only; no tailscale binary runs (tailscaleIPv4 is asked for lo0's address through its seam).
@MainActor
final class SystemStringDecodeTests: XCTestCase {
    func testDeviceModelIsTheBareHardwareModel() {
        let model = AnalyticsService.deviceModel
        XCTAssertFalse(model.contains("\0"), "trailing NULs shipped: \(model.debugDescription)")
        XCTAssertTrue(model.wholeMatch(of: /[A-Za-z]+[0-9]+,[0-9]+/) != nil, model.debugDescription)
        // The same value as an independent C-string read of hw.model.
        var size = 0
        XCTAssertEqual(sysctlbyname("hw.model", nil, &size, nil, 0), 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        XCTAssertEqual(sysctlbyname("hw.model", &buf, &size, nil, 0), 0)
        XCTAssertEqual(model, buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
    }

    func testNetworkReaderIPv4OfLoopbackIsTheBareAddress() {
        XCTAssertEqual(NetworkReader.ipv4(for: "lo0"), "127.0.0.1")
        XCTAssertTrue(NetworkReader.ipv4(for: "nosuchif0") == nil)
    }

    func testTailscaleIPv4DecodesTheMatchedAddress() {
        XCTAssertEqual(DchSessionServer.tailscaleIPv4(matching: { UInt32(bigEndian: $0.s_addr) == 0x7F00_0001 }),
                       "127.0.0.1")
        XCTAssertTrue(DchSessionServer.tailscaleIPv4(matching: { _ in false }) == nil)
    }
}

/// #1003 (QA #148): LlamaInlineEngine.swift:810, the top-k pass reloading the whole vocab row into
/// its scratch. QA's "vocab count minus one" mutant survived; this runs it on a literal row, no model.
final class LlamaTopCandidatesTests: XCTestCase {
    func testTopCandidatesRankTheWholeRowIncludingItsLastToken() {
        var logits: [Float] = [0, 1, 2, 5]
        var scratch: [Float] = []
        let top = logits.withUnsafeMutableBufferPointer {
            LlamaInlineEngine.topCandidates($0.baseAddress!, nVocab: 4, k: 2, scratch: &scratch)
        }
        XCTAssertEqual(top.map { $0.token }, [3, 2])
        // log-softmax: 5 - 5 - ln(1 + e^-3 + e^-4 + e^-5), and 2 - 5 - the same.
        XCTAssertEqual(top.first?.logprob ?? 0, -0.0721724, accuracy: 1e-5)
        XCTAssertEqual(top.last?.logprob ?? 0, -3.0721724, accuracy: 1e-5)
        XCTAssertEqual(top.first?.p ?? 0, 0.9303705, accuracy: 1e-5)
        XCTAssertEqual(scratch.count, 4, "the scratch is sized to the vocab")
    }
}
