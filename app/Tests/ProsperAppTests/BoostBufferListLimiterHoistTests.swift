// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreAudio
import XCTest
@testable import ProsperApp

// MARK: - Reference implementations (perf F4)
//
// BoostBufferListLimiter.process and BoostLookaheadBufferListLimiter.process
// used to walk the `UnsafeMutableAudioBufferListPointer` fresh on every
// frame — 512 IndexingIterators a render callback, through a generic
// Collection conformance the specializer cannot see through. The fix hoists
// that walk to once per call. These are byte-for-byte copies of the old,
// unoptimized per-frame walk, kept only so this test can drive both the old
// and the new code over identical input and assert the output samples never
// diverge by so much as a bit.

private struct ReferenceBoostBufferListLimiter {
    private var envelope: Float = 0

    mutating func process(_ buffers: UnsafeMutableAudioBufferListPointer,
                          frames: Int,
                          release: Float) {
        guard frames > 0 else { return }
        for frame in 0..<frames {
            var peak: Float = 0
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0,
                      let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let base = frame * channels
                for channel in 0..<channels { peak = max(peak, abs(samples[base + channel])) }
            }
            envelope = peak > envelope ? peak : peak + (envelope - peak) * release
            guard envelope > BoostLimiter.ceiling else { continue }
            let gain = BoostLimiter.ceiling / envelope
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0,
                      let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let base = frame * channels
                for channel in 0..<channels { samples[base + channel] *= gain }
            }
        }
    }
}

private final class ReferenceBoostLookaheadBufferListLimiter {
    private let channelCapacity: Int
    private var delay: ContiguousArray<Float>
    private var position = 0
    private var filledFrames = 0
    private var activeChannels = 0
    private var gain: Float = 1
    private var targetGain: Float = 1
    private var attackFrames = 0
    private var attackStep: Float = 0
    private var holdFrames = 0

    init(channelCapacity: Int) {
        self.channelCapacity = max(1, channelCapacity)
        delay = ContiguousArray(repeating: 0,
                                count: BoostLookaheadLimiter.lookaheadFrames
                                    * self.channelCapacity)
    }

    @discardableResult
    func process(_ buffers: UnsafeMutableAudioBufferListPointer,
                 frames: Int,
                 release: Float) -> Bool {
        let channels = buffers.reduce(0) { partial, buffer in
            partial + (buffer.mData == nil ? 0 : Int(buffer.mNumberChannels))
        }
        guard frames > 0, channels > 0, channels <= channelCapacity else { return false }
        if channels != activeChannels {
            delay.withUnsafeMutableBufferPointer {
                $0.baseAddress?.update(repeating: 0, count: $0.count)
            }
            position = 0
            filledFrames = 0
            gain = 1
            targetGain = 1
            attackFrames = 0
            attackStep = 0
            holdFrames = 0
            activeChannels = channels
        }

        let ceiling = BoostLimiter.ceiling
        for frame in 0..<frames {
            var peak: Float = 0
            for buffer in buffers {
                let count = Int(buffer.mNumberChannels)
                guard count > 0,
                      let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let base = frame * count
                for channel in 0..<count {
                    peak = max(peak, abs(samples[base + channel]))
                }
            }

            let requiredGain = peak > ceiling ? ceiling / peak : 1
            let isOverCeiling = requiredGain < 1
            if requiredGain < targetGain {
                targetGain = requiredGain
                let nextStep = (targetGain - gain)
                    / Float(BoostLookaheadLimiter.lookaheadFrames)
                attackStep = attackFrames > 0 ? min(attackStep, nextStep) : nextStep
                attackFrames = BoostLookaheadLimiter.lookaheadFrames
            }
            if isOverCeiling { holdFrames = BoostLookaheadLimiter.lookaheadFrames }

            if attackFrames > 0 {
                gain += attackStep
                attackFrames -= 1
                if gain <= targetGain {
                    gain = targetGain
                    attackFrames = 0
                }
            } else if !isOverCeiling, holdFrames > 0 {
                holdFrames -= 1
            } else if !isOverCeiling {
                gain = 1 + (gain - 1) * release
                targetGain = gain
            }

            let delayedBase = position * channelCapacity
            var channelIndex = 0
            for buffer in buffers {
                let count = Int(buffer.mNumberChannels)
                guard count > 0,
                      let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let base = frame * count
                for channel in 0..<count {
                    let delayed = filledFrames >= BoostLookaheadLimiter.lookaheadFrames
                        ? delay[delayedBase + channelIndex] : 0
                    delay[delayedBase + channelIndex] = samples[base + channel]
                    samples[base + channel] = delayed * gain
                    channelIndex += 1
                }
            }
            position += 1
            if position == BoostLookaheadLimiter.lookaheadFrames { position = 0 }
            if filledFrames < BoostLookaheadLimiter.lookaheadFrames { filledFrames += 1 }
        }
        return true
    }
}

// MARK: - Synthetic AudioBufferList fixture

/// Owns the raw storage behind a test `AudioBufferList` so it can be freed
/// deterministically; `channelsPerBuffer` lets a test choose one interleaved
/// buffer (stereo in one `AudioBuffer`) or several non-interleaved mono
/// buffers, exercising the multi-buffer channel-offset bookkeeping.
private struct BufferListScratch {
    let list: UnsafeMutableAudioBufferListPointer
    private let storages: [UnsafeMutableBufferPointer<Float>]

    init(channelsPerBuffer: [Int], frames: Int, signal: (_ frame: Int, _ channel: Int) -> Float) {
        let list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)
        var storages: [UnsafeMutableBufferPointer<Float>] = []
        var channelOffset = 0
        for (index, channels) in channelsPerBuffer.enumerated() {
            let count = frames * channels
            let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    storage[frame * channels + channel] = signal(frame, channelOffset + channel)
                }
            }
            list[index].mNumberChannels = UInt32(channels)
            list[index].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
            list[index].mData = UnsafeMutableRawPointer(storage.baseAddress)
            storages.append(storage)
            channelOffset += channels
        }
        self.list = list
        self.storages = storages
    }

    var samples: [Float] { storages.flatMap { Array($0) } }

    func free() {
        storages.forEach { $0.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }
}

/// One continuous stream split into three chunks, matching how the render
/// callback hands the limiter one block at a time: quiet (limiter fully
/// idle, gain 1), a spike well past `BoostLimiter.ceiling` (limiter
/// engaging), then quiet again (release tail recovering). Frame counts are
/// non-trivial and, for the lookahead limiter, cross its 256-frame lookahead
/// window more than once per chunk.
private let chunkFrameCounts = [512, 600, 700]
private let chunkAmplitudes: [Float] = [0.3, 1.3, 0.05]

private func chunkSignal(chunk: Int, amplitude: Float) -> (Int, Int) -> Float {
    { frame, channel in
        amplitude * sin(Float(frame) * 0.083 + Float(channel) * 0.37 + Float(chunk) * 1.7)
    }
}

// MARK: - Tests

final class BoostBufferListLimiterHoistTests: XCTestCase {
    private func assertBitIdentical(channelsPerBuffer: [Int],
                                    file: StaticString = #filePath, line: UInt = #line) {
        var reference = ReferenceBoostBufferListLimiter()
        var actual = BoostBufferListLimiter()
        let release = BoostLimiter.release(sampleRate: 48000)
        for (chunk, frames) in chunkFrameCounts.enumerated() {
            let signal = chunkSignal(chunk: chunk, amplitude: chunkAmplitudes[chunk])
            let referenceScratch = BufferListScratch(channelsPerBuffer: channelsPerBuffer,
                                                      frames: frames, signal: signal)
            let actualScratch = BufferListScratch(channelsPerBuffer: channelsPerBuffer,
                                                   frames: frames, signal: signal)
            defer {
                referenceScratch.free()
                actualScratch.free()
            }
            reference.process(referenceScratch.list, frames: frames, release: release)
            actual.process(actualScratch.list, frames: frames, release: release)
            XCTAssertEqual(actualScratch.samples, referenceScratch.samples,
                           "chunk \(chunk) (\(frames) frames) diverged", file: file, line: line)
        }
    }

    func testStereoInterleavedSingleBufferBitIdenticalAcrossIdleEngageRelease() {
        assertBitIdentical(channelsPerBuffer: [2])
    }

    func testMonoBitIdenticalAcrossIdleEngageRelease() {
        assertBitIdentical(channelsPerBuffer: [1])
    }

    func testNonInterleavedTwoMonoBuffersBitIdentical() {
        assertBitIdentical(channelsPerBuffer: [1, 1])
    }
}

final class BoostLookaheadBufferListLimiterHoistTests: XCTestCase {
    private func assertBitIdentical(channelsPerBuffer: [Int],
                                    file: StaticString = #filePath, line: UInt = #line) {
        let channelCapacity = channelsPerBuffer.reduce(0, +)
        let reference = ReferenceBoostLookaheadBufferListLimiter(channelCapacity: channelCapacity)
        let actual = BoostLookaheadBufferListLimiter(channelCapacity: channelCapacity)
        let release = BoostLimiter.release(sampleRate: 48000)
        for (chunk, frames) in chunkFrameCounts.enumerated() {
            let signal = chunkSignal(chunk: chunk, amplitude: chunkAmplitudes[chunk])
            let referenceScratch = BufferListScratch(channelsPerBuffer: channelsPerBuffer,
                                                      frames: frames, signal: signal)
            let actualScratch = BufferListScratch(channelsPerBuffer: channelsPerBuffer,
                                                   frames: frames, signal: signal)
            defer {
                referenceScratch.free()
                actualScratch.free()
            }
            let referenceAccepted = reference.process(referenceScratch.list, frames: frames,
                                                       release: release)
            let actualAccepted = actual.process(actualScratch.list, frames: frames, release: release)
            XCTAssertEqual(actualAccepted, referenceAccepted,
                           "chunk \(chunk) acceptance diverged", file: file, line: line)
            XCTAssertEqual(actualScratch.samples, referenceScratch.samples,
                           "chunk \(chunk) (\(frames) frames) diverged", file: file, line: line)
        }
    }

    func testStereoInterleavedSingleBufferBitIdenticalAcrossIdleEngageRelease() {
        assertBitIdentical(channelsPerBuffer: [2])
    }

    func testMonoBitIdenticalAcrossIdleEngageRelease() {
        assertBitIdentical(channelsPerBuffer: [1])
    }

    func testNonInterleavedTwoMonoBuffersBitIdentical() {
        assertBitIdentical(channelsPerBuffer: [1, 1])
    }
}
