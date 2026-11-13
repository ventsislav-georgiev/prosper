// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// The handful of mixer-wide constants and CoreAudio helpers the tap engine
/// needs. The coordinator that owns the engines (enumeration, per-app rows,
/// persistence) lands separately; these live here so the engine builds on its
/// own.
enum MixerCore {
    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    /// Volumes run 0...2: 1.0 is 100% (untouched passthrough), up to 2.0 is a
    /// 200% boost for sources that play too quietly.
    static let maxVolume: Double = 2.0

    @discardableResult
    static func read<T>(_ object: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        _ value: inout T,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size,
                                       UnsafeMutableRawPointer(pointer)) == noErr
        }
    }

    // MARK: Output stream configuration

    /// The channel count the limiter is sized for when the configuration
    /// cannot be read: a stereo device, as the tap is asked for.
    static let fallbackChannelCount = 2

    /// Largest stream configuration read. A list is an 8-byte header plus 16
    /// bytes per stream, so this holds 4095 streams; the widest real devices
    /// (MADI/Dante interfaces and aggregates of several) list a few hundred
    /// mono streams, a few KiB.
    static let maxStreamConfigurationBytes = 64 * 1024

    /// Ceiling on the channel answer. It sizes the limiter's delay line
    /// (256 frames per channel), so a bogus count must not allocate without
    /// bound; a device past it still plays, through the plain limiter.
    static let maxOutputChannels = 1024

    /// How many bytes to allocate for a stream configuration the HAL reported
    /// at `reportedSize`, or nil when it cannot hold one buffer list or is
    /// past the cap.
    static func streamConfigurationAllocationSize(reportedSize: UInt32) -> Int? {
        let size = Int(reportedSize)
        guard size >= MemoryLayout<AudioBufferList>.size,
              size <= maxStreamConfigurationBytes else { return nil }
        return size
    }

    /// The channel count of an AudioBufferList stream configuration the HAL
    /// wrote into `storage`, reporting `writtenSize` bytes used. Walks no
    /// more buffers than both the storage and the written size hold, whatever
    /// mNumberBuffers claims.
    static func outputChannelCount(streamConfiguration storage: UnsafeRawBufferPointer,
                                   writtenSize: Int) -> Int {
        let bufferStride = MemoryLayout<AudioBuffer>.stride
        let headerSize = MemoryLayout<AudioBufferList>.size - bufferStride
        let channelsOffset = MemoryLayout<AudioBuffer>.offset(of: \.mNumberChannels) ?? 0
        let used = min(storage.count, max(0, writtenSize))
        guard used >= headerSize, let base = storage.baseAddress else { return fallbackChannelCount }
        let declared = Int(base.loadUnaligned(as: UInt32.self))
        let walk = min(declared, (used - headerSize) / bufferStride)
        var total = 0
        for index in 0..<walk {
            let channels = base.loadUnaligned(fromByteOffset: headerSize + index * bufferStride + channelsOffset,
                                              as: UInt32.self)
            // total <= maxOutputChannels before the add, so the sum stays far below Int.max.
            total = min(total + Int(channels), maxOutputChannels)
        }
        return max(fallbackChannelCount, total)
    }

    /// The whole size-then-data read: `readSize` reports the property size
    /// (nil on failure), `fill` writes the configuration into the storage and
    /// answers the bytes it wrote (nil on failure). Any refusal answers the
    /// fallback; `fill` is only called with storage the cap allowed.
    static func outputChannelCount(readSize: () -> UInt32?,
                                   fill: (UnsafeMutableRawBufferPointer) -> UInt32?) -> Int {
        guard let reported = readSize(),
              let byteCount = streamConfigurationAllocationSize(reportedSize: reported) else {
            return fallbackChannelCount
        }
        let storage = UnsafeMutableRawBufferPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard let written = fill(storage) else { return fallbackChannelCount }
        return outputChannelCount(streamConfiguration: UnsafeRawBufferPointer(storage),
                                  writtenSize: Int(written))
    }
}

// MARK: - Tap engine

/// Availability-erased face of the engine, so the mixer can store engines on
/// any macOS while the implementation requires 14.4.
protocol GainEngine: AnyObject {
    var gain: Float { get set }
    var tappedObjects: [AudioObjectID] { get }
    var outputDeviceUID: String { get }
    /// How many IO callbacks the engine has completed. A count that stops
    /// moving while the tapped app is playing means the aggregate is no
    /// longer rendering, so the tap can only mute.
    var renderCycles: UInt64 { get }
    func stop()
}

/// The audio path for one routed app: a muted process tap feeding an aggregate
/// device whose IO proc re-renders the samples scaled by `gain` onto the chosen
/// output device.
@available(macOS 14.4, *)
final class TapGainEngine: GainEngine {
    let tappedObjects: [AudioObjectID]
    let outputDeviceUID: String
    var gain: Float {
        get { gainBox.value }
        set { gainBox.value = min(max(newValue, 0), Float(MixerCore.maxVolume)) }
    }

    /// Safe to hand across threads: every read and write goes through an
    /// atomic barrier, which the compiler cannot see for itself.
    private final class AtomicFloatBox: @unchecked Sendable {
        private var bits: Int32

        init(_ value: Float) {
            bits = Int32(bitPattern: value.bitPattern)
        }

        var value: Float {
            get {
                Float(bitPattern: UInt32(bitPattern: OSAtomicAdd32Barrier(0, &bits)))
            }
            set {
                let replacement = Int32(bitPattern: newValue.bitPattern)
                while true {
                    let current = OSAtomicAdd32Barrier(0, &bits)
                    if OSAtomicCompareAndSwap32Barrier(current, replacement, &bits) { return }
                }
            }
        }
    }

    private final class AtomicCycleBox {
        private var bits: Int64 = 0
        var value: UInt64 { UInt64(bitPattern: OSAtomicAdd64Barrier(0, &bits)) }
        func increment() { _ = OSAtomicIncrement64Barrier(&bits) }
    }

    /// One limiter per output buffer, preallocated so the realtime thread
    /// never allocates. Touched only by the IO proc once rendering starts.
    private final class LimiterBox {
        let lookahead: BoostLookaheadBufferListLimiter
        var fallback = BoostBufferListLimiter()
        init(channelCapacity: Int) {
            lookahead = BoostLookaheadBufferListLimiter(channelCapacity: channelCapacity)
        }
    }

    /// How fast the limiter recovers, kept beside the limiters rather than
    /// inside them: the device can change its rate while this engine keeps
    /// rendering, and the audio thread must never find another thread halfway
    /// through writing its state. Same one-float exchange as the gain.
    private typealias ReleaseBox = AtomicFloatBox

    private let gainBox = AtomicFloatBox(1)
    private let cycleBox = AtomicCycleBox()
    private let releaseBox = ReleaseBox(BoostLimiter.release(sampleRate: 48000))
    var renderCycles: UInt64 { cycleBox.value }
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    /// The retained `ReleaseBox` handed to the rate listener, released when
    /// the listener goes away.
    private var rateListenerClient: UnsafeMutableRawPointer?

    init?(objects: [AudioObjectID], gain: Float, outputDeviceUID: String) {
        tappedObjects = objects
        gainBox.value = min(max(gain, 0), Float(MixerCore.maxVolume))
        self.outputDeviceUID = outputDeviceUID

        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr, tapID != 0 else {
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Prosper Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr,
              aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let box = gainBox
        // A boost pushes loud samples past full scale, and clamping the
        // overshoot flattens every peak into audible crackle. The limiter
        // turns the whole signal down for just the moment a peak would not
        // fit, so a boosted app gets louder without distorting.
        let limiterBox = LimiterBox(
            channelCapacity: Self.outputChannelCapacity(of: aggregateID))
        releaseBox.value = BoostLimiter.release(sampleRate: Self.nominalSampleRate(of: aggregateID))
        let release = releaseBox
        let cycles = cycleBox
        let tapChannels = Self.tapChannels(of: tapID)
        guard AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil, { _, input, _, output, _ in
            let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
            guard let tapIndex = MixerRender.tapBufferIndex(in: inputBuffers,
                                                            tapChannels: tapChannels) else { return }
            let gain = box.value
            let frames = MixerRender.render(source: inputBuffers[tapIndex],
                                            into: outputBuffers,
                                            gain: gain)
            // Keep the tiny delay filled for every live engine. Crossing from
            // attenuation into boost then changes level without inserting a
            // fresh block of silence into audio that is already playing.
            guard frames > 0 else { return }
            cycles.increment()
            let releaseCoefficient = release.value
            if !limiterBox.lookahead.process(outputBuffers, frames: frames,
                                             release: releaseCoefficient) {
                limiterBox.fallback.process(outputBuffers, frames: frames,
                                            release: releaseCoefficient)
            }
        }) == noErr else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // Installed only once there is something to keep current, so the
        // failure paths above have nothing to undo.
        startWatchingSampleRate()

        guard AudioDeviceStart(aggregateID, ioProc) == noErr else {
            stop()
            return nil
        }
    }

    /// Keeps the limiter's recovery honest when the output device changes its
    /// rate under a running engine.
    ///
    /// A headset that takes the microphone for a call renegotiates to a
    /// call rate, and the aggregate follows it without the IO proc ever
    /// stopping (measured: the render kept going straight through a
    /// 48k to 44.1k change and back). Nothing else would notice, so a boosted
    /// app would keep recovering at the old rate's speed for as long as the
    /// engine lives.
    private func startWatchingSampleRate() {
        var address = Self.nominalSampleRateAddress()
        let client = Unmanaged.passRetained(releaseBox).toOpaque()
        guard AudioObjectAddPropertyListener(aggregateID, &address,
                                             Self.sampleRateListener, client) == noErr else {
            Unmanaged<ReleaseBox>.fromOpaque(client).release()
            return
        }
        rateListenerClient = client
    }

    /// Where the new rate is read, away from whatever thread the answer
    /// arrived on. Serial, so two changes in a row cannot land out of order.
    private static let rateQueue = DispatchQueue(label: "com.prosper.mixer.rate",
                                                 qos: .userInitiated)
    /// A broken HAL path can park inside teardown. Cleanup stays serialized so
    /// repeated failures cannot accumulate blocked worker threads; every IO
    /// proc is already stopped before it reaches this queue.
    private static let teardownQueue = DispatchQueue(label: "com.prosper.mixer.teardown",
                                                     qos: .utility)

    /// The smallest possible answer, for the same reason as the mixer's own
    /// callback above: the system decides which thread this arrives on and it
    /// is not always the same one. Reading the audio system here would park
    /// whatever thread that is behind the very device being reconfigured,
    /// which is the change that sent this notification in the first place.
    private static let sampleRateListener: AudioObjectPropertyListenerProc = { deviceID, _, _, client in
        guard let client else { return noErr }
        // Held for the hop, so the engine can stop and hand back its
        // registration without the read landing in memory that is gone.
        let box = Unmanaged<ReleaseBox>.fromOpaque(client).takeUnretainedValue()
        rateQueue.async {
            box.value = BoostLimiter.release(sampleRate: nominalSampleRate(of: deviceID))
        }
        return noErr
    }

    private static func nominalSampleRateAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// How many channels the tap hands over, used to find it among the
    /// aggregate's input buffers. A stereo mixdown is what the tap is asked
    /// for, so that is also the fallback.
    private static func tapChannels(of tapID: AudioObjectID) -> Int {
        var format = AudioStreamBasicDescription()
        guard MixerCore.read(tapID, kAudioTapPropertyFormat, &format),
              format.mChannelsPerFrame > 0 else { return 2 }
        return Int(format.mChannelsPerFrame)
    }

    private static func outputChannelCapacity(of deviceID: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        return MixerCore.outputChannelCount(
            readSize: {
                var size: UInt32 = 0
                return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr ? size : nil
            },
            fill: { storage in
                guard let base = storage.baseAddress,
                      let capacity = UInt32(exactly: storage.count) else { return nil }
                var size = capacity
                return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, base) == noErr ? size : nil
            })
    }

    /// The rate the aggregate renders at, for the limiter's release timing.
    /// A failed read falls back to the common device rate; being off by a
    /// device's worth of rate only shifts the release by milliseconds.
    private static func nominalSampleRate(of deviceID: AudioObjectID) -> Double {
        var sampleRate: Float64 = 0
        guard MixerCore.read(deviceID, kAudioDevicePropertyNominalSampleRate, &sampleRate),
              sampleRate > 0 else { return 48000 }
        return sampleRate
    }

    func stop() {
        let tapID = self.tapID
        let aggregateID = self.aggregateID
        let ioProc = self.ioProc
        // The listener's client pointer is only ever handed back to HAL on the
        // teardown queue below, after every IO proc has stopped.
        nonisolated(unsafe) let listenerClient = rateListenerClient
        guard tapID != 0 || aggregateID != 0 || ioProc != nil || listenerClient != nil else {
            return
        }

        self.tapID = 0
        self.aggregateID = 0
        self.ioProc = nil
        rateListenerClient = nil

        // `mutedWhenTapped` only suppresses the original output while the tap
        // is being read. Stop that read before returning so audio is handed
        // back immediately; the cleanup calls after it may wait on a broken
        // HAL path and therefore run away from the main thread.
        if let ioProc, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProc)
        }

        Self.teardownQueue.async {
            if let listenerClient {
                var mayReleaseListener = aggregateID == 0
                if aggregateID != 0 {
                    var address = Self.nominalSampleRateAddress()
                    mayReleaseListener = AudioObjectRemovePropertyListener(
                        aggregateID, &address, Self.sampleRateListener, listenerClient) == noErr
                }
                // If HAL refuses removal, retain the tiny callback box. A late
                // callback is safer than dereferencing a released pointer.
                if mayReleaseListener {
                    Unmanaged<ReleaseBox>.fromOpaque(listenerClient).release()
                }
            }
            if let ioProc, aggregateID != 0 {
                AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            }
            if aggregateID != 0 {
                AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            if tapID != 0 {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }
    }

    deinit { stop() }
}
