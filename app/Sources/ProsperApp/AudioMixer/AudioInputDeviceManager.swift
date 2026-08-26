// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Input half of Vorssaint's audio services: Services/Audio/AudioInputDeviceManager.swift
// plus the mute/restore core of Services/QuickTools/MicMuteService.swift, rebuilt on
// Prosper's MixerCore reads and the pure decisions in MixerRoutingSupport.swift.

import AppKit
import AudioToolbox
import CoreAudio
import Darwin

struct MixerInputDevice: Identifiable, Equatable {
    let id: String
    let uid: String
    let name: String
    let isDefault: Bool
    fileprivate let audioObjectID: AudioObjectID
}

private struct InputSnapshot {
    let devices: [MixerInputDevice]
    let currentUID: String?
    let resolution: MixerInputRouteResolution
    /// Non-nil when re-asserting the preferred microphone failed, so the panel
    /// can say so instead of silently showing the wrong device.
    let applyStatus: OSStatus?
}

/// Tracks the input devices the HAL reports, keeps the user's preferred
/// microphone selected whenever it is present, and can silence every input at
/// once (the mute reaches the device, so it holds no matter which app is
/// listening).
@MainActor
final class AudioInputDeviceManager: ObservableObject {
    static let shared = AudioInputDeviceManager()

    @Published private(set) var inputDevices: [MixerInputDevice] = []
    @Published private(set) var currentInputDeviceUID: String?
    @Published private(set) var preferredInputDeviceUID: String?
    /// The preferred microphone is saved but not plugged in: the system default
    /// is in use and the panel says so.
    @Published private(set) var preferredUnavailable = false
    /// One ready-to-render sentence: the panel shows it as a quiet caption.
    @Published private(set) var lastError: String?
    @Published private(set) var micMuted = false

    private var listenerInstalled = false
    private var globalListeners: [AudioObjectPropertySelector] = []
    private var refresh = MixerRefreshCoordinator()
    private var refreshPending = false
    private var lastListenerRefreshAt: CFAbsoluteTime = 0
    /// Same reason as the mixer's own HAL queue: a single read can block for as
    /// long as the audio daemon holds its lock, so none of them happen on main.
    private let halQueue = DispatchQueue(label: "com.prosper.mixer.input.hal", qos: .userInitiated)

    private init() {}

    // MARK: - Lifecycle

    /// Follows the mixer's master switch: the picker only exists inside the
    /// mixer panel, so off means no listeners and no published state.
    func syncWithPreferences() {
        if Preferences.mixerEnabled, MixerCore.isSupported {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard !listenerInstalled else { refreshInputs(); return }
        // A mute that outlived the app (quit, crash) leaves a microphone silent
        // with no switch in sight, so a leftover record is released on the way up.
        releaseStaleMute()
        listenerInstalled = true
        preferredInputDeviceUID = Preferences.mixerPreferredInputDeviceUID
        installListener(selector: kAudioHardwarePropertyDevices)
        installListener(selector: kAudioHardwarePropertyDefaultInputDevice)
        refreshInputs()
    }

    func stop() {
        if micMuted { setMicMuted(false) }
        guard listenerInstalled else { return }
        listenerInstalled = false
        for selector in globalListeners {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                              &address,
                                              Self.listenerCallback,
                                              listenerClient)
        }
        globalListeners.removeAll()
        refresh.discardInFlight()
        if !inputDevices.isEmpty { inputDevices = [] }
        currentInputDeviceUID = nil
        preferredUnavailable = false
        lastError = nil
    }

    // MARK: - Selection API (panel)

    /// Nil clears the preference: the system default wins again, and nothing is
    /// re-asserted when the device list changes.
    func setPreferredInputDeviceUID(_ uid: String?) {
        let sanitized = uid.flatMap { MixerRoutingSupport.sanitizedDeviceUID($0) }
        Preferences.mixerPreferredInputDeviceUID = sanitized
        preferredInputDeviceUID = sanitized
        lastError = nil
        // The pass in flight read the previous preference; this one replaces it.
        refresh.discardInFlight()
        refreshInputs()
    }

    // MARK: - Listeners

    private nonisolated static let listenerCallback: AudioObjectPropertyListenerProc = { _, _, _, client in
        guard let client else { return noErr }
        let manager = Unmanaged<AudioInputDeviceManager>.fromOpaque(client).takeUnretainedValue()
        // Reading the HAL from inside its own notification deadlocks on the
        // device being reconfigured, so the callback only hops to main.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { manager.scheduleListenerRefresh() }
        }
        return noErr
    }

    private var listenerClient: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private func installListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                             &address,
                                             Self.listenerCallback,
                                             listenerClient) == noErr else { return }
        globalListeners.append(selector)
    }

    private nonisolated static let listenerRefreshInterval: CFAbsoluteTime = 0.2

    /// Plugging in one interface fires several notifications; they coalesce into
    /// one pass.
    private func scheduleListenerRefresh() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastListenerRefreshAt
        if elapsed >= Self.listenerRefreshInterval {
            lastListenerRefreshAt = now
            refreshInputs()
            return
        }
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.listenerRefreshInterval - elapsed)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                self.lastListenerRefreshAt = CFAbsoluteTimeGetCurrent()
                self.refreshInputs()
            }
        }
    }

    // MARK: - Refresh

    private func refreshInputs() {
        guard listenerInstalled else { return }
        guard let generation = refresh.begin() else { return }
        let preferredUID = Preferences.mixerPreferredInputDeviceUID
        halQueue.async { [weak self] in
            let snapshot = Self.readSnapshot(preferredUID: preferredUID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot, generation: generation) }
            }
        }
    }

    /// Runs on `halQueue`. Reads the device list, and while it is there
    /// re-asserts the preferred microphone — that is the whole "it came back,
    /// switch to it" behaviour, since every device arrival fires a listener.
    private nonisolated static func readSnapshot(preferredUID: String?) -> InputSnapshot {
        var currentUID = defaultInputDeviceUID()
        var devices = inputDevices(defaultUID: currentUID)
        var resolution = MixerRoutingSupport.resolveInputDevice(
            preferredUID: preferredUID,
            availableUIDs: Set(devices.map(\.uid)),
            currentUID: currentUID)
        var applyStatus: OSStatus?

        if resolution.shouldApplyPreferred,
           let device = devices.first(where: { $0.uid == resolution.effectiveUID }) {
            let status = setDefaultInputDevice(device.audioObjectID)
            if status == noErr {
                currentUID = device.uid
                devices = devices.map {
                    MixerInputDevice(id: $0.id,
                                     uid: $0.uid,
                                     name: $0.name,
                                     isDefault: $0.uid == currentUID,
                                     audioObjectID: $0.audioObjectID)
                }
                resolution = MixerRoutingSupport.resolveInputDevice(
                    preferredUID: preferredUID,
                    availableUIDs: Set(devices.map(\.uid)),
                    currentUID: currentUID)
            } else {
                applyStatus = status
            }
        }

        return InputSnapshot(devices: devices,
                             currentUID: currentUID,
                             resolution: resolution,
                             applyStatus: applyStatus)
    }

    /// Main thread. Only assigns what actually changed: a chatty HAL would
    /// otherwise re-render the panel continuously.
    private func apply(_ snapshot: InputSnapshot, generation: Int) {
        guard refresh.finish(generation) else { return }
        let refreshAgain = refresh.takeRepeatRequest()
        guard listenerInstalled else { return }
        defer { if refreshAgain { refreshInputs() } }

        if inputDevices != snapshot.devices { inputDevices = snapshot.devices }
        if currentInputDeviceUID != snapshot.currentUID { currentInputDeviceUID = snapshot.currentUID }
        if preferredUnavailable != snapshot.resolution.selectedUnavailable {
            preferredUnavailable = snapshot.resolution.selectedUnavailable
        }
        let error = snapshot.applyStatus.map { "Could not switch microphone: OSStatus \($0)" }
        if lastError != error { lastError = error }
    }

    // MARK: - Mute every input

    /// The panel button and the global shortcut both land here. Inert while the
    /// mixer is off — the listeners are down, so `micMuted` says nothing useful
    /// and there would be no switch in sight to undo it with.
    func toggleMicMute() {
        guard Preferences.mixerEnabled, MixerCore.isSupported else { return }
        setMicMuted(!micMuted)
    }

    func setMicMuted(_ muted: Bool) {
        if muted { muteAllInputs() } else { unmuteRecordedInputs() }
    }

    /// Prefers the device's own mute switch; where there is none the level is
    /// saved and driven to zero instead. Either way the microphone is silent at
    /// the device, so it holds whichever app is listening.
    private func muteAllInputs() {
        var recorded: [String] = []
        var savedVolumes: [String: Double] = [:]
        for device in Self.inputDevices(defaultUID: nil) {
            if Self.setMuteSwitch(true, of: device.audioObjectID) {
                recorded.append(device.uid)
                continue
            }
            // A saved zero would make the unmute restore silence, so a device
            // that is already down is left alone rather than recorded.
            guard let volume = Self.inputVolume(of: device.audioObjectID), volume > 0.01,
                  Self.setInputVolume(0, of: device.audioObjectID) else { continue }
            savedVolumes[device.uid] = Double(volume)
            recorded.append(device.uid)
        }
        guard !recorded.isEmpty else {
            lastError = "No microphone could be muted."
            return
        }
        UserDefaults.standard.set(recorded, forKey: MixerDefaultsKey.micMutedDevices)
        UserDefaults.standard.set(savedVolumes, forKey: MixerDefaultsKey.micSavedInputVolumes)
        lastError = nil
        micMuted = true
    }

    private func unmuteRecordedInputs() {
        let defaults = UserDefaults.standard
        // No record at all (settings carried to another Mac, a state from before
        // this was tracked) restores everything: leaving someone muted with no
        // way back is the worse failure. A record that exists but is empty means
        // the sweep found every device already silent by the user's own hand.
        let recorded = defaults.stringArray(forKey: MixerDefaultsKey.micMutedDevices).map(Set.init)
        let savedVolumes = defaults.dictionary(forKey: MixerDefaultsKey.micSavedInputVolumes)
            as? [String: Double] ?? [:]
        for device in Self.inputDevices(defaultUID: nil) {
            guard recorded?.contains(device.uid) ?? true else { continue }
            if let volume = savedVolumes[device.uid] {
                _ = Self.setInputVolume(Float(volume), of: device.audioObjectID)
            }
            _ = Self.setMuteSwitch(false, of: device.audioObjectID)
        }
        defaults.removeObject(forKey: MixerDefaultsKey.micMutedDevices)
        defaults.removeObject(forKey: MixerDefaultsKey.micSavedInputVolumes)
        micMuted = false
    }

    private func releaseStaleMute() {
        guard UserDefaults.standard.object(forKey: MixerDefaultsKey.micMutedDevices) != nil else { return }
        unmuteRecordedInputs()
    }

    // MARK: - CoreAudio plumbing

    private nonisolated static func inputDevices(defaultUID: String?) -> [MixerInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceIDs) == noErr else { return [] }

        var devices: [MixerInputDevice] = []
        for deviceID in deviceIDs {
            guard hasInputStreams(deviceID) else { continue }

            var isAlive: UInt32 = 1
            if MixerCore.read(deviceID, kAudioDevicePropertyDeviceIsAlive, &isAlive), isAlive == 0 {
                continue
            }
            var isHidden: UInt32 = 0
            if MixerCore.read(deviceID, kAudioDevicePropertyIsHidden, &isHidden), isHidden != 0 {
                continue
            }

            var uidRef: CFString = "" as CFString
            guard MixerCore.read(deviceID, kAudioDevicePropertyDeviceUID, &uidRef) else { continue }
            let uid = uidRef as String
            guard !uid.isEmpty else { continue }

            var nameRef: CFString = "" as CFString
            let name = MixerCore.read(deviceID, kAudioObjectPropertyName, &nameRef)
                ? nameRef as String
                : uid
            // The mixer's own aggregate device carries a tapped app's audio, not
            // a microphone: it is neither an input to pick nor one to mute.
            guard name != "Prosper Mixer" else { continue }

            devices.append(MixerInputDevice(id: uid,
                                            uid: uid,
                                            name: name,
                                            isDefault: uid == defaultUID,
                                            audioObjectID: deviceID))
        }

        return devices.sorted { lhs, rhs in
            MixerRoutingSupport.deviceDisplayOrderedBefore(
                isDefault: lhs.isDefault, name: lhs.name, uid: lhs.uid,
                otherIsDefault: rhs.isDefault, otherName: rhs.name, otherUID: rhs.uid)
        }
    }

    private nonisolated static func hasInputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
            && size >= MemoryLayout<AudioObjectID>.size
    }

    private nonisolated static func defaultInputDeviceUID() -> String? {
        var defaultDevice = AudioObjectID(0)
        guard MixerCore.read(AudioObjectID(kAudioObjectSystemObject),
                             kAudioHardwarePropertyDefaultInputDevice, &defaultDevice),
              defaultDevice != 0 else { return nil }
        var uidRef: CFString = "" as CFString
        guard MixerCore.read(defaultDevice, kAudioDevicePropertyDeviceUID, &uidRef) else { return nil }
        return uidRef as String
    }

    private nonisolated static func setDefaultInputDevice(_ deviceID: AudioObjectID) -> OSStatus {
        var nextDeviceID = deviceID
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &address,
                                          0,
                                          nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size),
                                          &nextDeviceID)
    }

    private nonisolated static func setMuteSwitch(_ muted: Bool, of deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var isSettable = DarwinBoolean(false)
        guard AudioObjectHasProperty(deviceID, &address),
              AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
              isSettable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Some interfaces expose the input level per channel and nothing on the
    /// main element, so all three are tried.
    private nonisolated static let inputVolumeElements: [AudioObjectPropertyElement] =
        [kAudioObjectPropertyElementMain, 1, 2]

    private nonisolated static func inputVolume(of deviceID: AudioObjectID) -> Float? {
        for element in inputVolumeElements {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        return nil
    }

    private nonisolated static func setInputVolume(_ volume: Float, of deviceID: AudioObjectID) -> Bool {
        var applied = false
        for element in inputVolumeElements {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioDevicePropertyScopeInput,
                                                     mElement: element)
            var isSettable = DarwinBoolean(false)
            guard AudioObjectHasProperty(deviceID, &address),
                  AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
                  isSettable.boolValue else { continue }
            var value = volume
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                applied = true
            }
        }
        return applied
    }
}
