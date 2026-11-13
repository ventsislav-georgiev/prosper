import XCTest
@testable import ProsperApp

/// The output stream configuration parser behind the tap engine's limiter
/// sizing, driven with hand-built bytes. Layout of an AudioBufferList on
/// 64-bit macOS, written here from literal numbers rather than asked of the
/// type under test:
///   offset 0: UInt32 mNumberBuffers, offset 4: 4 bytes padding,
///   then per buffer 16 bytes: UInt32 mNumberChannels, UInt32 mDataByteSize,
///   8-byte mData pointer (zero here).
final class StreamConfigurationChannelCountTests: XCTestCase {
    private static let headerBytes = 8
    private static let bufferBytes = 16
    /// Fills every byte past the fixture, so an over-read shows up as a huge
    /// channel count (0x64646464 per buffer) instead of reading memory the
    /// test does not own.
    private static let sentinel: UInt8 = 0x64
    /// Owned room for the fixture plus 16 more buffers of sentinel.
    private static let ownedBytes = 8 + 16 * 32

    private func bytes(declaredBuffers: UInt32, channels: [UInt32]) -> [UInt8] {
        var out: [UInt8] = []
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        put(declaredBuffers)
        put(0)
        for count in channels {
            put(count)
            put(4096)
            out.append(contentsOf: [UInt8](repeating: 0, count: 8))
        }
        return out
    }

    /// Runs the parser over `fixture` as the storage (its own length), placed
    /// at the start of a larger owned, sentinel-filled buffer.
    private func channelCount(_ fixture: [UInt8], writtenSize: Int? = nil) -> Int {
        let owned = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.ownedBytes, alignment: 8)
        defer { owned.deallocate() }
        owned.initializeMemory(as: UInt8.self, repeating: Self.sentinel)
        precondition(fixture.count <= Self.ownedBytes)
        owned.copyBytes(from: fixture)
        let storage = UnsafeRawBufferPointer(rebasing: owned[0..<fixture.count])
        return MixerCore.outputChannelCount(streamConfiguration: storage,
                                            writtenSize: writtenSize ?? fixture.count)
    }

    func testStereoListAnswersTwo() {
        let fixture = bytes(declaredBuffers: 1, channels: [2])
        XCTAssertEqual(fixture.count, 24)
        XCTAssertEqual(channelCount(fixture), 2)
    }

    func testTwoBuffersSumTheirChannels() {
        XCTAssertEqual(channelCount(bytes(declaredBuffers: 2, channels: [2, 6])), 8)
    }

    func testMonoListAnswersTheFloorOfTwo() {
        XCTAssertEqual(channelCount(bytes(declaredBuffers: 1, channels: [1])), 2)
    }

    func testDeclaredCountPastTheStorageWalksOnlyWhatTheStorageHolds() {
        // Says 5 buffers, the storage (40 bytes) holds 2; the other 3 would be sentinel.
        let fixture = bytes(declaredBuffers: 5, channels: [2, 6])
        XCTAssertEqual(fixture.count, 40)
        XCTAssertEqual(channelCount(fixture), 8)
    }

    func testWrittenSizeSmallerThanTheStorageBoundsTheWalk() {
        // Storage holds 3 buffers, the HAL reports writing only the first 2.
        let fixture = bytes(declaredBuffers: 3, channels: [2, 6, 10])
        XCTAssertEqual(fixture.count, 56)
        XCTAssertEqual(channelCount(fixture, writtenSize: 40), 8)
    }

    func testWrittenSizeSmallerThanTheHeaderAnswersTwo() {
        let fixture = bytes(declaredBuffers: 1, channels: [6])
        XCTAssertEqual(channelCount(fixture, writtenSize: 4), 2)
    }

    func testNegativeWrittenSizeAnswersTwo() {
        XCTAssertEqual(channelCount(bytes(declaredBuffers: 1, channels: [6]), writtenSize: -1), 2)
    }

    func testZeroBuffersAnswerTwo() {
        XCTAssertEqual(channelCount(bytes(declaredBuffers: 0, channels: [6])), 2)
    }

    func testOverflowingChannelSumIsBoundedAtTheCeiling() {
        let fixture = bytes(declaredBuffers: 2, channels: [4_294_967_295, 4_294_967_295])
        XCTAssertEqual(channelCount(fixture), 1024)
    }

    func testAllocationSizeRefusesBelowOneBufferListAndAboveTheCap() {
        XCTAssertTrue(MixerCore.streamConfigurationAllocationSize(reportedSize: 23) == nil)
        XCTAssertEqual(MixerCore.streamConfigurationAllocationSize(reportedSize: 24), 24)
        XCTAssertEqual(MixerCore.streamConfigurationAllocationSize(reportedSize: 65_536), 65_536)
        XCTAssertTrue(MixerCore.streamConfigurationAllocationSize(reportedSize: 65_537) == nil)
        XCTAssertTrue(MixerCore.streamConfigurationAllocationSize(reportedSize: 4_294_967_295) == nil)
    }

    // MARK: - The whole read: size, allocation, fill, parse

    private struct FillLog {
        var fills = 0
        var allocated: [Int] = []
    }

    /// Drives MixerCore's size-then-fill read with fakes: `reported` is the
    /// size read (nil = failed), the fill paints the seam's storage with the
    /// sentinel, copies `fixture` over its start and answers `written`
    /// (nil = failed).
    private func readFillLog(reported: UInt32?, fixture: [UInt8], written: UInt32?,
                              _ log: inout FillLog) -> Int {
        var calls = log
        let answer = MixerCore.outputChannelCount(
            readSize: { reported },
            fill: { storage in
                calls.fills += 1
                calls.allocated.append(storage.count)
                storage.initializeMemory(as: UInt8.self, repeating: Self.sentinel)
                storage.copyBytes(from: fixture.prefix(storage.count))
                return written
            })
        log = calls
        return answer
    }

    func testFillWritingFewerBytesThanAllocatedBoundsTheWalkToWhatWasWritten() {
        var log = FillLog()
        let fixture = bytes(declaredBuffers: 3, channels: [2, 6, 10])
        XCTAssertEqual(readFillLog(reported: 56, fixture: fixture, written: 40, &log), 8)
        XCTAssertEqual(log.allocated, [56])
    }

    func testFillReportingMoreBytesThanAllocatedIsBoundedByTheStorage() {
        var log = FillLog()
        // 56 bytes allocated, the list says 2 buffers; the third slot is sentinel.
        let fixture = bytes(declaredBuffers: 2, channels: [2, 6])
        XCTAssertEqual(readFillLog(reported: 56, fixture: fixture, written: 1000, &log), 8)
        // The list says 5 buffers but the 40-byte storage holds 2.
        let longClaim = bytes(declaredBuffers: 5, channels: [2, 6])
        XCTAssertEqual(readFillLog(reported: 40, fixture: longClaim, written: 1000, &log), 8)
        XCTAssertEqual(log.allocated, [56, 40])
    }

    func testFailedSizeReadAnswersTwoWithoutFilling() {
        var log = FillLog()
        XCTAssertEqual(readFillLog(reported: nil, fixture: bytes(declaredBuffers: 1, channels: [6]),
                                    written: 24, &log), 2)
        XCTAssertEqual(log.fills, 0)
    }

    func testFailedFillAnswersTwo() {
        var log = FillLog()
        XCTAssertEqual(readFillLog(reported: 24, fixture: bytes(declaredBuffers: 1, channels: [6]),
                                    written: nil, &log), 2)
        XCTAssertEqual(log.fills, 1)
    }

    func testRefusedSizesAnswerTwoWithoutFilling() {
        var log = FillLog()
        let fixture = bytes(declaredBuffers: 1, channels: [6])
        XCTAssertEqual(readFillLog(reported: 23, fixture: fixture, written: 24, &log), 2)
        XCTAssertEqual(readFillLog(reported: 65_537, fixture: fixture, written: 24, &log), 2)
        XCTAssertEqual(log.fills, 0)
    }
}
