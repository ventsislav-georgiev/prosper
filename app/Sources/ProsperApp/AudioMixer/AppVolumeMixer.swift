// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Coordinator half of Vorssaint's AppVolumeMixer. The tap engine it drives
// lives in TapGainEngine.swift; the pure decision helpers in
// MixerRoutingSupport.swift.

import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Darwin

/// Everything the mixer keeps on disk. Volumes and routes are stored under a
/// row's persistence id (its bundle id where the process has one), never under
/// a pid, because pids recycle.
enum MixerDefaultsKey {
    static let appVolumes = "mixerAppVolumes"
    static let appOutputs = "mixerAppOutputs"
    static let hiddenApps = "mixerHiddenApps"
    /// Read by the panel, not by this service: a row hidden for being idle is
    /// at unity on the default output, so it owns no tap either way.
    static let hideInactiveApps = "mixerHideInactiveApps"
    /// Which input devices the mic mute silenced, and the level each one was at
    /// beforehand. Recorded so an unmute never opens a microphone the user muted
    /// themselves, and so a mute that outlived the app can be released.
    static let micMutedDevices = "mixerMicMutedDevices"
    static let micSavedInputVolumes = "mixerMicSavedInputVolumes"
    /// UIDs the output-cycling hotkey walks, in order. Absent (never configured)
    /// means every available output takes part; a stored list is taken literally,
    /// so unticking everything really does disable the cycle.
    static let soundOutputCycleUIDs = "mixerSoundOutputCycleUIDs"
}

struct MixerOutputDevice: Identifiable, Equatable {
    let id: String
    let uid: String
    let name: String
    let isDefault: Bool
    let isHeadphones: Bool
    let canBeDefaultOutput: Bool
    let canBeDefaultSystemOutput: Bool
    fileprivate let audioObjectID: AudioObjectID
}

/// One row: an app, with every audio process object it owns folded into a
/// single entry.
struct MixerApp: Identifiable, Equatable {
    let id: String
    /// Nil when the process offers no stable key, so nothing is ever saved
    /// under a pid.
    let persistenceID: String?
    let ownerPid: pid_t
    let name: String
    let audioObjects: [AudioObjectID]
    let isPlaying: Bool
    /// Apps a tap would break (conferencing, DAWs). They keep a row but are
    /// pinned at unity with no route, so they never need an engine.
    var isBypassed: Bool = false
    var selectedOutputDeviceUID: String?
    var effectiveOutputDeviceUID: String?
    var outputDeviceUnavailable: Bool = false
    var volume: Double

    var identity: MixerRowIdentity {
        MixerRowIdentity(rowID: id, persistenceID: persistenceID)
    }
}

struct MixerHiddenApp: Identifiable, Equatable {
    let id: String
    let name: String
}

/// What one refresh needs from main-thread state to read the HAL without
/// touching the mixer again.
private struct RefreshRequest {
    let savedVolumes: [String: Double]
    let savedOutputs: [String: String]
    let sessionVolumes: [String: Double]
    let sessionRoutes: [String: String]
    let hiddenRowIDs: Set<String>
    let ownPid: pid_t
}

/// Everything one refresh read from the HAL, handed back for the main thread
/// to turn into published state.
private struct RefreshSnapshot {
    let defaultUID: String?
    let systemSoundUID: String?
    let outputDevices: [MixerOutputDevice]
    let defaultDeviceID: AudioObjectID?
    let systemOutputVolume: Double?
    let systemOutputMuted: Bool?
    /// Nil where process taps do not exist (before macOS 14.4): the app list
    /// stays empty and no process object is looked at.
    let apps: [MixerApp]?
    let processObjects: [AudioObjectID]
}

/// Carries one freshly built engine from the build queue back to the main
/// thread. The engine is only ever touched on the main thread once it lands,
/// so the hop is safe even though the engine itself is not `Sendable`.
private final class EngineBox: @unchecked Sendable {
    let engine: (any GainEngine)?
    init(_ engine: (any GainEngine)?) { self.engine = engine }
}

@MainActor
final class AppVolumeMixer: ObservableObject {
    static let shared = AppVolumeMixer()

    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var outputDevices: [MixerOutputDevice] = []
    @Published private(set) var currentOutputDeviceUID: String?
    @Published private(set) var currentSystemSoundOutputDeviceUID: String?
    @Published private(set) var systemOutputVolume: Double?
    @Published private(set) var systemOutputMuted: Bool?
    @Published private(set) var outputSwitchError: String?
    /// Set when tap creation fails and no engine is running for the row, which
    /// in practice means audio capture consent was refused.
    @Published private(set) var needsPermission = false
    /// Apps the user took off the list.
    @Published private(set) var hiddenApps: [MixerHiddenApp] = []
    /// Outputs the cycle hotkey walks. `nil` = never configured, so every
    /// available output takes part (see `MixerDefaultsKey.soundOutputCycleUIDs`).
    @Published private(set) var soundOutputCycleUIDs: [String]? =
        UserDefaults.standard.array(forKey: MixerDefaultsKey.soundOutputCycleUIDs) as? [String]

    private var engines: [String: any GainEngine] = [:]
    /// Suppresses duplicate builds and discards a build the mixer moved past.
    private var builds = MixerEngineBuilds()
    private var engineChangeAt: [String: Double] = [:]
    private var objectsLostAt: [String: Double] = [:]
    private var engineRenderProgress: [String: MixerRoutingSupport.EngineRenderObservation] = [:]
    /// One replacement for a dead audio path, then the row is left untapped so
    /// a HAL failure cannot become a rebuild loop.
    private var engineRecovery = MixerEngineRecovery()
    private var engineReconcilePending = false
    private var refresh = MixerRefreshCoordinator()

    /// Rows with no bundle id: adjustable while the process runs, never
    /// written to disk.
    private var sessionVolumes: [String: Double] = [:]
    private var sessionRoutes: [String: String] = [:]
    private var lastAudibleVolume: [String: Double] = [:]

    private var listenerInstalled = false
    private var globalListeners: [AudioObjectPropertySelector] = []
    private var runningListeners = Set<AudioObjectID>()
    private var outputControlListenerDevice: AudioObjectID?
    private var outputControlListenerAddresses: [AudioObjectPropertyAddress] = []
    private var outputControlRefreshGeneration = 0
    private var refreshPending = false
    private var lastListenerRefreshAt: CFAbsoluteTime = 0
    private var stopped = false
    private var wakeObserver: NSObjectProtocol?

    /// Building a tap and an aggregate device is slower than reading the HAL,
    /// and the reconfiguration it causes is exactly what fires the listeners,
    /// so it gets its own queue: a panel must never wait on a build to learn
    /// which devices exist.
    private let buildQueue = DispatchQueue(label: "com.prosper.mixer", qos: .userInitiated)
    /// While the audio HAL is busy (a device pairing, an interface
    /// renegotiating, a display with audio waking) a single read can wait for
    /// as long as the daemon holds that lock, so no read happens on main.
    private let halQueue = DispatchQueue(label: "com.prosper.mixer.hal", qos: .userInitiated)

    private init() {}

    // MARK: - Lifecycle

    /// The whole mixer follows its master switch: off means no HAL listeners,
    /// no taps and no published state at all.
    func syncWithPreferences() {
        if Preferences.mixerEnabled, MixerCore.isSupported {
            start()
        } else {
            stop()
        }
    }

    /// Starts watching audio processes. Saved volumes re-apply as soon as the
    /// matching app produces sound — no panel interaction needed.
    func start() {
        stopped = false
        publishHiddenApps()
        guard !listenerInstalled else {
            refreshApps()
            return
        }
        listenerInstalled = true
        installListener(selector: kAudioHardwarePropertyDevices)
        installListener(selector: kAudioHardwarePropertyDefaultOutputDevice)
        installListener(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        if MixerCore.isSupported {
            installListener(selector: kAudioHardwarePropertyProcessObjectList)
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A wake can wedge an engine while leaving the HAL snapshot
                    // byte-identical, and apply() skips reconciliation when
                    // nothing changed. Dropping the stored render observations
                    // and reconciling directly arms the note-then-recheck
                    // sequence deterministically, so a frozen engine is caught
                    // even on a quiet wake.
                    self.engineRenderProgress.removeAll()
                    self.engineRecovery.clearAll()
                    self.refreshApps()
                    self.reconcileEngines(with: self.apps)
                    self.scheduleEngineReconcile(after: 2)
                }
            }
        }
        refreshApps()
    }

    /// Tears every tap down so all apps return to untouched system output.
    func stopAll() {
        stopped = true
        builds.invalidateAll()
        for engine in engines.values { engine.stop() }
        engines.removeAll()
        engineChangeAt.removeAll()
        objectsLostAt.removeAll()
        engineRenderProgress.removeAll()
        engineRecovery.clearAll()
    }

    /// Full teardown: taps, per-process listeners and the global HAL listeners
    /// all go away, and the published state empties out.
    func stop() {
        stopAll()
        sessionVolumes.removeAll()
        sessionRoutes.removeAll()
        // A refresh already reading the HAL must not publish into a mixer that
        // is no longer watching, nor re-register the listeners just removed.
        refresh.discardInFlight()
        pruneRunningListeners(keeping: [])
        removeGlobalListeners()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if !apps.isEmpty { apps = [] }
        if !hiddenApps.isEmpty { hiddenApps = [] }
        if !outputDevices.isEmpty { outputDevices = [] }
        if currentOutputDeviceUID != nil { currentOutputDeviceUID = nil }
        if currentSystemSoundOutputDeviceUID != nil { currentSystemSoundOutputDeviceUID = nil }
        if systemOutputVolume != nil { systemOutputVolume = nil }
        if systemOutputMuted != nil { systemOutputMuted = nil }
        if outputSwitchError != nil { outputSwitchError = nil }
        if needsPermission { needsPermission = false }
    }

    /// What the audio system calls when something changes. The system decides
    /// which thread this arrives on and it is not always the same one, so all
    /// it does is ask the main thread for a refresh and return. Everything the
    /// refresh then reads from the audio system happens away from the main
    /// thread.
    ///
    /// One stored callback, never a fresh closure per registration: handing a
    /// closure back to be removed never matches the one that was registered.
    private nonisolated static let listenerCallback: AudioObjectPropertyListenerProc = { _, _, _, client in
        guard let client else { return noErr }
        let mixer = Unmanaged<AppVolumeMixer>.fromOpaque(client).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { mixer.scheduleListenerRefresh() }
        }
        return noErr
    }

    private nonisolated static let outputControlListenerCallback: AudioObjectPropertyListenerProc = { device, _, _, client in
        guard let client else { return noErr }
        let mixer = Unmanaged<AppVolumeMixer>.fromOpaque(client).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { mixer.scheduleOutputControlRefresh(for: device) }
        }
        return noErr
    }

    /// Unretained on purpose: the singleton outlives every listener.
    private var listenerClient: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

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

    private func removeGlobalListeners() {
        guard listenerInstalled else { return }
        listenerInstalled = false
        removeOutputControlListeners()
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
    }

    /// Follows the system volume and mute of whichever device is the default
    /// output right now, so the panel's system slider tracks the volume keys.
    private func subscribeToOutputControls(of device: AudioObjectID?) {
        guard let device else {
            removeOutputControlListeners()
            return
        }
        guard outputControlListenerDevice != device else { return }
        removeOutputControlListeners()
        let selectors = Self.outputVolumeSelectors + [kAudioDevicePropertyMute]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(device, &address) else { continue }
            if AudioObjectAddPropertyListener(device,
                                              &address,
                                              Self.outputControlListenerCallback,
                                              listenerClient) == noErr {
                outputControlListenerAddresses.append(address)
            }
        }
        if !outputControlListenerAddresses.isEmpty {
            outputControlListenerDevice = device
        }
    }

    private func removeOutputControlListeners() {
        if let device = outputControlListenerDevice {
            for var address in outputControlListenerAddresses {
                AudioObjectRemovePropertyListener(device,
                                                  &address,
                                                  Self.outputControlListenerCallback,
                                                  listenerClient)
            }
        }
        outputControlListenerDevice = nil
        outputControlListenerAddresses.removeAll()
        outputControlRefreshGeneration &+= 1
    }

    /// A volume key press fires the listener once per element; the read that
    /// answers it goes off-main behind a short coalescing delay.
    private func scheduleOutputControlRefresh(for device: AudioObjectID) {
        outputControlRefreshGeneration &+= 1
        let generation = outputControlRefreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.outputControlRefreshGeneration == generation else { return }
                self.halQueue.async { [weak self] in
                    let volume = Self.hasSettableOutputVolume(for: device)
                        ? Self.outputVolume(for: device).map(Double.init)
                        : nil
                    let muted = Self.outputMuted(for: device)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self,
                                  self.listenerInstalled,
                                  self.outputControlListenerDevice == device,
                                  self.outputControlRefreshGeneration == generation else { return }
                            if self.systemOutputVolume != volume { self.systemOutputVolume = volume }
                            if self.systemOutputMuted != muted { self.systemOutputMuted = muted }
                        }
                    }
                }
            }
        }
    }

    private func subscribeToRunningChanges(of object: AudioObjectID) {
        guard !runningListeners.contains(object) else { return }
        var address = MixerRoutingSupport.processObjectListenerAddress
        if AudioObjectAddPropertyListener(object, &address, Self.listenerCallback, listenerClient) == noErr {
            runningListeners.insert(object)
        }
    }

    /// Drops listeners of process objects that no longer exist. Removal on a
    /// dead object can fail; object ids do come back, so the record goes
    /// either way.
    private func pruneRunningListeners(keeping current: Set<AudioObjectID>) {
        for object in runningListeners where !current.contains(object) {
            var address = MixerRoutingSupport.processObjectListenerAddress
            AudioObjectRemovePropertyListener(object, &address, Self.listenerCallback, listenerClient)
            runningListeners.remove(object)
        }
    }

    /// One hardware event fires the listeners back-to-back (device list,
    /// default device, process list, plus one IsRunningOutput per object), and
    /// a busy audio HAL can keep that stream going for as long as the panel is
    /// open. An isolated notification refreshes immediately (a headphone
    /// unplug must react now); a burst is coalesced into one trailing refresh,
    /// so the panel does not redraw once per listener.
    private func scheduleListenerRefresh() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastListenerRefreshAt
        if elapsed >= Self.listenerRefreshInterval {
            lastListenerRefreshAt = now
            refreshApps()
            return
        }
        guard !refreshPending else { return }
        refreshPending = true
        let delay = Self.listenerRefreshInterval - elapsed
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshPending = false
                self.lastListenerRefreshAt = CFAbsoluteTimeGetCurrent()
                self.refreshApps()
            }
        }
    }

    private nonisolated static let listenerRefreshInterval: CFAbsoluteTime = 0.2

    // MARK: - Volume API (panel)

    func setCurrentOutputVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 1)
        Self.setSystemOutputVolume(clamped)
        if systemOutputVolume != clamped { systemOutputVolume = clamped }
        if clamped > 0, systemOutputMuted == true { systemOutputMuted = false }
    }

    /// 100% means bit-perfect passthrough (no tap). The UI rounds to 100% so
    /// dragging near 100% or tapping reset restores true passthrough; anything
    /// else runs a gain engine.
    private func isUnity(_ volume: Double) -> Bool { MixerRoutingSupport.isUnity(volume) }

    func setVolume(_ volume: Double, for app: MixerApp) {
        guard !app.isBypassed else { return }
        engineRecovery.clear(app.id)
        let clamped = Self.sanitizedVolume(volume)
        persistVolume(clamped, for: app)
        if clamped > 0.001 { lastAudibleVolume[app.id] = clamped }
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].volume = clamped
            let updated = apps[index]
            applyRouting(for: updated)
        } else {
            applyRouting(for: app)
        }
    }

    func setOutputDeviceUID(_ uid: String?, for app: MixerApp) {
        guard !app.isBypassed else { return }
        engineRecovery.clear(app.id)
        let sanitized = MixerRoutingSupport.sanitizedDeviceUID(uid)
        persistOutputDeviceUID(sanitized, for: app)
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index].selectedOutputDeviceUID = sanitized
            applyOutputRoute(to: &apps[index],
                             savedOutputs: [app.id: sanitized].compactMapValues { $0 },
                             availableUIDs: Set(outputDevices.map(\.uid)),
                             defaultUID: currentOutputDeviceUID)
            applyRouting(for: apps[index])
        }
    }

    /// Mute is a volume of zero that remembers where the slider was.
    func setMute(_ muted: Bool, for app: MixerApp) {
        if muted {
            if app.volume > 0.001 { lastAudibleVolume[app.id] = app.volume }
            setVolume(0, for: app)
        } else {
            setVolume(lastAudibleVolume[app.id] ?? 1, for: app)
        }
    }

    func toggleMute(_ app: MixerApp) {
        setMute(app.volume > 0.001, for: app)
    }

    /// The one-tap boost: full 200% or straight back to passthrough.
    func setBoost(_ boosted: Bool, for app: MixerApp) {
        setVolume(boosted ? MixerCore.maxVolume : 1, for: app)
    }

    /// Back to untouched system audio for one row: 100% on the system default
    /// output, saved state cleared and the tap torn down.
    func resetRow(_ app: MixerApp) {
        setOutputDeviceUID(nil, for: app)
        setVolume(1, for: app)
    }

    func resetAll() {
        for app in apps { resetRow(app) }
    }

    @discardableResult
    func setUniversalOutputDeviceUID(_ uid: String) -> Bool {
        guard let sanitized = MixerRoutingSupport.sanitizedDeviceUID(uid),
              let device = outputDevices.first(where: {
                  $0.uid == sanitized && $0.canBeDefaultOutput
              }) else {
            outputSwitchError = Self.outputUnavailableMessage
            refreshApps()
            return false
        }

        let status = Self.setDefaultDevice(device.audioObjectID,
                                           selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard status == noErr else {
            outputSwitchError = "OSStatus \(status)"
            refreshApps()
            return false
        }
        outputSwitchError = nil
        // The default app output just changed by this app's own hand, so a refresh
        // still reading the previous devices is thrown away; the one at the end
        // of this method replaces it.
        refresh.discardInFlight()
        let preferences = MixerRoutingSupport.preferencesAfterUniversalOutputSwitch(
            outputDeviceUIDs: savedOutputDeviceUIDs(),
            volumes: savedVolumes(),
            switchSucceeded: true)
        persistOutputDeviceUIDs(preferences.outputDeviceUIDs)

        currentOutputDeviceUID = device.uid
        outputDevices = outputDevices.map { outputDevice in
            MixerOutputDevice(id: outputDevice.id,
                              uid: outputDevice.uid,
                              name: outputDevice.name,
                              isDefault: outputDevice.uid == device.uid,
                              isHeadphones: outputDevice.isHeadphones,
                              canBeDefaultOutput: outputDevice.canBeDefaultOutput,
                              canBeDefaultSystemOutput: outputDevice.canBeDefaultSystemOutput,
                              audioObjectID: outputDevice.audioObjectID)
        }

        // Builds started for the previous device can no longer be installed;
        // the engines themselves stay live until reconciliation has their
        // replacement running on the new device.
        builds.invalidateAll()

        let availableUIDs = Set(outputDevices.map(\.uid))
        apps = apps.map { current in
            var app = current
            app.volume = storedVolume(for: app.identity, saved: preferences.volumes) ?? app.volume
            applyOutputRoute(to: &app,
                             savedOutputs: preferences.outputDeviceUIDs,
                             availableUIDs: availableUIDs,
                             defaultUID: device.uid)
            return app
        }
        reconcileEngines(with: apps)
        clearPermissionIfNoActiveAdjustments()
        refreshApps()
        return true
    }

    @discardableResult
    func setSystemSoundOutputDeviceUID(_ uid: String) -> Bool {
        guard let sanitized = MixerRoutingSupport.sanitizedDeviceUID(uid),
              let device = outputDevices.first(where: {
                  $0.uid == sanitized && $0.canBeDefaultSystemOutput
              }) else {
            outputSwitchError = Self.outputUnavailableMessage
            refreshApps()
            return false
        }

        let status = Self.setDefaultDevice(
            device.audioObjectID,
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        guard status == noErr else {
            outputSwitchError = "OSStatus \(status)"
            refreshApps()
            return false
        }

        outputSwitchError = nil
        refresh.discardInFlight()
        currentSystemSoundOutputDeviceUID = device.uid
        refreshApps()
        return true
    }

    @discardableResult
    func switchToNextSoundOutput(in selectedUIDs: [String]) -> Bool {
        let availableUIDs = Set(outputDevices.filter(\.canBeDefaultOutput).map(\.uid))
        guard let nextUID = MixerRoutingSupport.nextSelectedOutputDeviceUID(
            currentUID: currentOutputDeviceUID,
            selectedUIDs: selectedUIDs,
            availableUIDs: availableUIDs) else { return false }
        return setUniversalOutputDeviceUID(nextUID)
    }

    /// The outputs the hotkey cycles through, resolved: an unconfigured list
    /// means "all of them", so the shortcut works the moment it is recorded.
    var participatingOutputUIDs: [String] {
        soundOutputCycleUIDs ?? outputDevices.filter(\.canBeDefaultOutput).map(\.uid)
    }

    /// Pass `nil` to go back to "every output participates".
    func setSoundOutputCycleUIDs(_ uids: [String]?) {
        soundOutputCycleUIDs = uids
        if let uids {
            UserDefaults.standard.set(uids, forKey: MixerDefaultsKey.soundOutputCycleUIDs)
        } else {
            UserDefaults.standard.removeObject(forKey: MixerDefaultsKey.soundOutputCycleUIDs)
        }
    }

    /// What the global shortcut calls. Inert while the mixer is off — the
    /// device list is only kept fresh while the service runs.
    @discardableResult
    func cycleSoundOutput() -> Bool {
        guard Preferences.mixerEnabled, MixerCore.isSupported else { return false }
        return switchToNextSoundOutput(in: participatingOutputUIDs)
    }

    private static let outputUnavailableMessage = "That output device is no longer available."

    /// Main-thread only. Engine creation happens off-main (CoreAudio object
    /// setup takes tens of milliseconds) and lands back here exactly once.
    ///
    /// A tap mutes the app on the real output and replays it through the
    /// aggregate, so an engine that goes away for even a moment hands the app
    /// straight back to the speakers at full volume. Replacements are built
    /// first and the old engine is stopped only once the new one is running.
    private func applyRouting(for app: MixerApp) {
        guard !stopped else { return }
        guard !app.isBypassed else {
            discardEngine(for: app.id)
            return
        }
        guard let targetOutputDeviceUID = app.effectiveOutputDeviceUID,
              appNeedsEngine(app) else {
            // System default at 100% stays true passthrough.
            discardEngine(for: app.id)
            clearPermissionIfNoActiveAdjustments()
            return
        }
        if let engine = engines[app.id],
           engine.tappedObjects == app.audioObjects,
           engine.outputDeviceUID == targetOutputDeviceUID {
            engine.gain = Float(app.volume)
            return
        }
        // A row only earns a tap once the user asked for something other than
        // 100% on the system default output.
        guard rowMayBeTapped(app) else {
            discardEngine(for: app.id)
            clearPermissionIfNoActiveAdjustments()
            return
        }
        let configuration = MixerEngineRecovery.Configuration(
            objects: app.audioObjects,
            outputDeviceUID: targetOutputDeviceUID)
        guard engineRecovery.allowsBuild(app.id, configuration: configuration) else { return }
        guard #available(macOS 14.4, *), let token = builds.begin(app.id) else { return }

        buildQueue.async { [weak self] in
            let box = EngineBox(TapGainEngine(objects: app.audioObjects,
                                              gain: Float(app.volume),
                                              outputDeviceUID: targetOutputDeviceUID))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        box.engine?.stop()
                        return
                    }
                    self.install(box.engine, for: app.id, token: token)
                }
            }
        }
    }

    /// Lands one finished build on the main thread.
    private func install(_ engine: (any GainEngine)?, for id: String, token: Int) {
        let isCurrentBuild = builds.isCurrent(id, token: token)
        builds.finish(id, token: token)
        // A build that started before the mixer moved on (feature switched
        // off, output device changed, a newer build for the same row) would
        // add a second live tap to the app and render its sound twice.
        guard isCurrentBuild, !stopped else {
            engine?.stop()
            return
        }
        guard let engine else {
            // The tap could not be created: keeping the engine that is already
            // running beats leaving the app with none, unless it renders to a
            // device that is gone, in which case it can only mute the app.
            if let running = engines[id],
               !outputDevices.contains(where: { $0.uid == running.outputDeviceUID }) {
                discardEngine(for: id)
            }
            // A row that still has a tap running is plainly not being refused
            // for lack of consent, so the permission hint stays out of it.
            if engines[id] == nil, !needsPermission {
                needsPermission = true
            }
            return
        }
        if needsPermission {
            needsPermission = false
        }
        // The slider may have moved (or returned to 100%) while the engine was
        // being built, or the app's audio objects may have changed. Honor the
        // latest state, never an old tap target.
        guard let latestApp = apps.first(where: { $0.id == id }) else {
            engine.stop()
            return
        }
        guard latestApp.audioObjects == engine.tappedObjects,
              latestApp.effectiveOutputDeviceUID == engine.outputDeviceUID,
              appNeedsEngine(latestApp) else {
            engine.stop()
            applyRouting(for: latestApp)
            return
        }
        engine.gain = Float(latestApp.volume)
        let previous = engines.updateValue(engine, forKey: id)
        engineChangeAt[id] = CFAbsoluteTimeGetCurrent()
        // The fresh engine starts its render count over.
        engineRenderProgress.removeValue(forKey: id)
        previous?.stop()
        // A tap mutes immediately. Arm the render check here instead of
        // waiting for another HAL event, or a dead first aggregate can leave
        // the app silent until the mixer quits.
        reconcileEngines(with: apps)
    }

    /// Stops and forgets a row's engine. Used where silence is the intent
    /// (back to 100% on the default output, row gone), never for a rebuild.
    private func discardEngine(for id: String) {
        engines.removeValue(forKey: id)?.stop()
        engineChangeAt.removeValue(forKey: id)
        objectsLostAt.removeValue(forKey: id)
        engineRenderProgress.removeValue(forKey: id)
        engineRecovery.clear(id)
    }

    private func rowMayBeTapped(_ app: MixerApp) -> Bool {
        MixerRoutingSupport.rowMayBeTapped(
            savedVolume: storedVolume(for: app.identity, saved: savedVolumes()),
            savedRouteUID: storedRoute(for: app.identity, saved: savedOutputDeviceUIDs()),
            defaultOutputDeviceUID: currentOutputDeviceUID)
    }

    private func appNeedsEngine(_ app: MixerApp) -> Bool {
        MixerRoutingSupport.requiresEngine(hasAudioObjects: !app.audioObjects.isEmpty,
                                           volume: app.volume,
                                           selectedOutputDeviceUID: app.selectedOutputDeviceUID,
                                           targetOutputDeviceUID: app.effectiveOutputDeviceUID,
                                           defaultOutputDeviceUID: currentOutputDeviceUID)
    }

    private func applyOutputRoute(to app: inout MixerApp,
                                  savedOutputs: [String: String],
                                  availableUIDs: Set<String>,
                                  defaultUID: String?) {
        let selectedUID = storedRoute(for: app.identity, saved: savedOutputs)
        app.selectedOutputDeviceUID = selectedUID
        app.effectiveOutputDeviceUID = MixerRoutingSupport.effectiveDeviceUID(
            selectedUID: selectedUID,
            availableUIDs: availableUIDs,
            defaultUID: defaultUID)
        app.outputDeviceUnavailable = MixerRoutingSupport.selectedDeviceUnavailable(
            selectedUID: selectedUID,
            availableUIDs: availableUIDs)
    }

    // MARK: - Process discovery

    /// Kicks off one refresh. Reading the audio HAL happens on `halQueue`;
    /// everything published, every engine and every listener record is touched
    /// back on the main thread, where it lives.
    private func refreshApps() {
        // A throttled refresh can land after stop(); watching is over.
        guard listenerInstalled else { return }
        // A pass already reading the HAL holds the slot: running a second one
        // now would read against state the first has not published yet. The
        // request is remembered and runs as soon as that one lands.
        guard let generation = refresh.begin() else { return }
        let request = RefreshRequest(
            savedVolumes: savedVolumes(),
            savedOutputs: savedOutputDeviceUIDs(),
            sessionVolumes: sessionVolumes,
            sessionRoutes: sessionRoutes,
            hiddenRowIDs: MixerRoutingSupport.hiddenRowIDs(hiddenApps: savedHiddenApps(),
                                                           showFinder: true),
            ownPid: ProcessInfo.processInfo.processIdentifier)

        halQueue.async { [weak self] in
            let snapshot = Self.readSnapshot(request)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot, generation: generation) }
            }
        }
    }

    /// Main thread. Turns one HAL snapshot into published state, engines and
    /// listener records.
    private func apply(_ snapshot: RefreshSnapshot, generation: Int) {
        // The mixer no longer wants this pass (it stopped, or changed the
        // output itself, while the pass was reading).
        guard refresh.finish(generation) else { return }
        var refreshAgain = refresh.takeRepeatRequest()
        guard listenerInstalled else { return }
        defer { if refreshAgain { refreshApps() } }

        if (snapshot.defaultUID != currentOutputDeviceUID
            || snapshot.systemSoundUID != currentSystemSoundOutputDeviceUID),
           outputSwitchError != nil {
            outputSwitchError = nil
        }
        let audioEnvironmentChanged = currentOutputDeviceUID != nil
            && (snapshot.defaultUID != currentOutputDeviceUID || snapshot.outputDevices != outputDevices)
        if audioEnvironmentChanged {
            // Builds aimed at the previous audio environment can no longer be
            // installed; reconciliation below replaces the live engines one by
            // one, each new tap running before its predecessor stops.
            builds.invalidateAll()
        }
        // Assigning a @Published property signals SwiftUI even when the value is
        // identical, and refreshes run on every CoreAudio notification — publish
        // only real changes or a chatty HAL re-renders the panel continuously.
        if currentOutputDeviceUID != snapshot.defaultUID {
            currentOutputDeviceUID = snapshot.defaultUID
        }
        if currentSystemSoundOutputDeviceUID != snapshot.systemSoundUID {
            currentSystemSoundOutputDeviceUID = snapshot.systemSoundUID
        }
        if snapshot.outputDevices != outputDevices {
            outputDevices = snapshot.outputDevices
        }
        subscribeToOutputControls(of: snapshot.defaultDeviceID)
        if systemOutputVolume != snapshot.systemOutputVolume {
            systemOutputVolume = snapshot.systemOutputVolume
        }
        if systemOutputMuted != snapshot.systemOutputMuted {
            systemOutputMuted = snapshot.systemOutputMuted
        }

        guard let next = snapshot.apps else {
            if !apps.isEmpty {
                apps = []
            }
            return
        }

        let watchedBefore = runningListeners
        pruneRunningListeners(keeping: Set(snapshot.processObjects))
        for object in snapshot.processObjects {
            // Audio starting/stopping in a process flips IsRunningOutput
            // without changing the object list — subscribe per object.
            subscribeToRunningChanges(of: object)
        }
        // This snapshot read IsRunningOutput off the HAL queue before those
        // subscriptions existed, so a flip in between fired unheard. Read once
        // more now that they are live. The next pass subscribes nothing new,
        // which is what stops the chain.
        if MixerRoutingSupport.needsRunningRecheck(previouslyWatched: watchedBefore,
                                                   nowWatched: runningListeners) {
            refreshAgain = true
        }

        guard audioEnvironmentChanged || next != apps else { return }
        if apps != next {
            apps = next
        }
        reconcileEngines(with: next)
        clearPermissionIfNoActiveAdjustments()
    }

    /// Runs on `halQueue`. Every CoreAudio read of a refresh happens here and
    /// nothing outside the returned snapshot is touched.
    private nonisolated static func readSnapshot(_ request: RefreshRequest) -> RefreshSnapshot {
        let defaultUID = defaultOutputDeviceUID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let systemSoundUID = defaultOutputDeviceUID(
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        let nextOutputDevices = outputDevices(defaultUID: defaultUID)
        let defaultDevice = nextOutputDevices.first { $0.uid == defaultUID }
        let availableUIDs = Set(nextOutputDevices.map(\.uid))
        let systemOutputVolume = defaultDevice.flatMap { device in
            hasSettableOutputVolume(for: device.audioObjectID)
                ? outputVolume(for: device.audioObjectID).map(Double.init)
                : nil
        }
        let systemOutputMuted = defaultDevice.flatMap { outputMuted(for: $0.audioObjectID) }

        guard MixerCore.isSupported else {
            return RefreshSnapshot(defaultUID: defaultUID,
                                   systemSoundUID: systemSoundUID,
                                   outputDevices: nextOutputDevices,
                                   defaultDeviceID: defaultDevice?.audioObjectID,
                                   systemOutputVolume: systemOutputVolume,
                                   systemOutputMuted: systemOutputMuted,
                                   apps: nil,
                                   processObjects: [])
        }

        let ownPid = request.ownPid
        let saved = request.savedVolumes
        let savedOutputs = request.savedOutputs
        var groups: [pid_t: [AudioObjectID]] = [:]
        var playing: Set<pid_t> = []
        var bypassed: Set<pid_t> = []
        var bundleHints: [pid_t: String] = [:]
        let processObjects = audioProcessObjects()
        for object in processObjects {
            var pid: pid_t = -1
            guard MixerCore.read(object, kAudioProcessPropertyPID, &pid), pid > 0, pid != ownPid else { continue }

            // Show every regular app that holds an audio connection, not only
            // the ones making sound this instant, so apps are adjustable before
            // they play and stay put between sounds.
            guard let app = ResponsibleProcess.regularAppOwner(of: pid) else { continue }
            let owner = app.processIdentifier
            let name = ResponsibleProcess.displayName(pid: owner, fallback: app.localizedName ?? "pid \(owner)")
            // Bypassed apps (Zoom, DAWs) still get a row — hiding them reads
            // as a bug — but they are never tapped: volume pinned at unity, no
            // saved routing, so appNeedsEngine is always false for them.
            if MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: app.bundleIdentifier,
                                                      name: name) {
                bypassed.insert(owner)
            }

            var running: UInt32 = 0
            _ = MixerCore.read(object, kAudioProcessPropertyIsRunningOutput, &running)
            if running != 0 { playing.insert(owner) }

            groups[owner, default: []].append(object)
            if bundleHints[owner] == nil {
                // The audio object knows the bundle id of its own process,
                // which is the app itself whenever it plays its own sound.
                // For a helper that plays on an app's behalf the owner found
                // above is the app, and its bundle id is the one that counts.
                bundleHints[owner] = app.bundleIdentifier
                    ?? (pid == owner ? processBundleIdentifier(of: object) : nil)
            }
        }

        var next: [MixerApp] = []
        for (owner, objects) in groups {
            let fallbackName = "pid \(owner)"
            let name = ResponsibleProcess.displayName(pid: owner, fallback: fallbackName)
            // The pid fallback is not a name to save under: pids recycle.
            let identity = MixerRoutingSupport.rowIdentity(bundleIdentifier: bundleHints[owner],
                                                           ownerPid: owner,
                                                           displayName: name == fallbackName ? nil : name)
            // Hidden means no row, and with no row the engine reconciliation
            // below tears its tap down too: an app taken off the list always
            // plays untouched, never silently attenuated.
            if MixerRoutingSupport.isHiddenFromMixer(persistenceID: identity.persistenceID,
                                                     hiddenIDs: request.hiddenRowIDs) { continue }
            let isBypassed = bypassed.contains(owner)
            let route = isBypassed ? nil : storedRoute(for: identity,
                                                       saved: savedOutputs,
                                                       session: request.sessionRoutes)
            next.append(MixerApp(id: identity.rowID,
                                 persistenceID: identity.persistenceID,
                                 ownerPid: owner,
                                 name: name,
                                 audioObjects: objects.sorted(),
                                 isPlaying: playing.contains(owner),
                                 isBypassed: isBypassed,
                                 selectedOutputDeviceUID: route,
                                 effectiveOutputDeviceUID: isBypassed ? nil : MixerRoutingSupport.effectiveDeviceUID(
                                    selectedUID: route,
                                    availableUIDs: availableUIDs,
                                    defaultUID: defaultUID),
                                 outputDeviceUnavailable: isBypassed ? false : MixerRoutingSupport.selectedDeviceUnavailable(
                                    selectedUID: route,
                                    availableUIDs: availableUIDs),
                                 volume: isBypassed ? 1 : (storedVolume(for: identity,
                                                                       saved: saved,
                                                                       session: request.sessionVolumes) ?? 1)))
        }
        next.sort {
            MixerRoutingSupport.displayOrderedBefore(name: $0.name, id: $0.id,
                                                     otherName: $1.name, otherID: $1.id)
        }
        next = coalescingAppsWithDuplicateIDs(next)

        return RefreshSnapshot(defaultUID: defaultUID,
                               systemSoundUID: systemSoundUID,
                               outputDevices: nextOutputDevices,
                               defaultDeviceID: defaultDevice?.audioObjectID,
                               systemOutputVolume: systemOutputVolume,
                               systemOutputMuted: systemOutputMuted,
                               apps: next,
                               processObjects: processObjects)
    }

    nonisolated static func coalescingAppsWithDuplicateIDs(_ apps: [MixerApp]) -> [MixerApp] {
        var merged: [MixerApp] = []
        var indexesByID: [String: Int] = [:]

        for app in apps {
            guard let index = indexesByID[app.id] else {
                indexesByID[app.id] = merged.count
                merged.append(app)
                continue
            }

            let existing = merged[index]
            let audioObjects = Array(Set(existing.audioObjects).union(app.audioObjects)).sorted()
            merged[index] = MixerApp(id: existing.id,
                                     persistenceID: existing.persistenceID,
                                     ownerPid: existing.ownerPid,
                                     name: existing.name,
                                     audioObjects: audioObjects,
                                     isPlaying: existing.isPlaying || app.isPlaying,
                                     // Bypass is a property of the app, not of
                                     // one of its processes: losing it here
                                     // would tap an app that must never be
                                     // tapped.
                                     isBypassed: existing.isBypassed || app.isBypassed,
                                     selectedOutputDeviceUID: existing.selectedOutputDeviceUID,
                                     effectiveOutputDeviceUID: existing.effectiveOutputDeviceUID,
                                     outputDeviceUnavailable: existing.outputDeviceUnavailable,
                                     volume: existing.volume)
        }
        return merged
    }

    /// Builds taps for apps that need one, drops taps for apps that stopped
    /// playing, retargets taps whose process set changed (new helper spawned),
    /// and applies saved volumes to newcomers.
    ///
    /// A tap is never torn down to be rebuilt right after: the replacement is
    /// built first (applyRouting) and the old one stops once it is running.
    /// Rows that keep changing fold into a single trailing rebuild instead of
    /// one per notification.
    private func reconcileEngines(with apps: [MixerApp]) {
        let apps = Self.coalescingAppsWithDuplicateIDs(apps)
        var byId: [String: MixerApp] = [:]
        for app in apps {
            byId[app.id] = app
        }

        let now = CFAbsoluteTimeGetCurrent()
        var nextPassDelay: Double?

        for (id, engine) in Array(engines) {
            let app = byId[id]
            let hasAudioObjects = !(app?.audioObjects.isEmpty ?? true)

            // The row is gone or momentarily has no audio object: an app that
            // recreates its audio unit between clips does exactly this and is
            // back a few milliseconds later. Nothing is audible in between, so
            // the tap is kept for a short window instead of being destroyed
            // and rebuilt once per notification.
            guard hasAudioObjects, let app else {
                let lostAt = objectsLostAt[id]
                if let delay = MixerRoutingSupport.engineTeardownDelay(
                    hasAudioObjects: false,
                    lastChangeAt: lostAt,
                    now: now) {
                    if lostAt == nil { objectsLostAt[id] = now }
                    nextPassDelay = min(nextPassDelay ?? delay, delay)
                } else {
                    discardEngine(for: id)
                }
                continue
            }
            // The audio came back inside the window, so the next disappearance
            // starts its own wait rather than inheriting this one.
            objectsLostAt.removeValue(forKey: id)

            // Waking from sleep, or a device renegotiating right after, can
            // leave the aggregate wedged: its IO proc never runs again while
            // the tap keeps muting the app, and nothing else about the engine
            // looks wrong. A render count that stops moving while the app is
            // playing is conclusive: the engine goes away at once, which
            // unmutes the app even if the rebuild below cannot land yet, and a
            // fresh tap takes its place.
            switch MixerRoutingSupport.engineRenderVerdict(previous: engineRenderProgress[id],
                                                           cycles: engine.renderCycles,
                                                           isPlaying: app.isPlaying,
                                                           now: now) {
            case .note(let observation, let recheckAfter):
                engineRenderProgress[id] = observation
                if recheckAfter == nil {
                    engineRecovery.clear(id)
                }
                if let recheckAfter {
                    nextPassDelay = min(nextPassDelay ?? recheckAfter, recheckAfter)
                }
            case .stalled(let recheckAfter):
                nextPassDelay = min(nextPassDelay ?? recheckAfter, recheckAfter)
            case .wedged:
                engines.removeValue(forKey: id)?.stop()
                engineRenderProgress.removeValue(forKey: id)
                engineChangeAt[id] = now
                let configuration = MixerEngineRecovery.Configuration(
                    objects: engine.tappedObjects,
                    outputDeviceUID: engine.outputDeviceUID)
                let shouldRetry = engineRecovery.recordFailure(id, configuration: configuration)
                if shouldRetry {
                    applyRouting(for: app)
                }
                continue
            case nil:
                engineRenderProgress.removeValue(forKey: id)
            }

            guard engine.tappedObjects != app.audioObjects
                || engine.outputDeviceUID != app.effectiveOutputDeviceUID
                || !appNeedsEngine(app) else { continue }

            engineChangeAt[id] = now
            guard appNeedsEngine(app) else {
                // Back to 100% on the default output: passthrough is the point.
                discardEngine(for: id)
                continue
            }
            // An engine rendering to a device that is gone (headphones just
            // unplugged) can only mute the app, so it goes right away; every
            // other rebuild keeps its tap until the replacement is running.
            if !outputDevices.contains(where: { $0.uid == engine.outputDeviceUID }) {
                engines.removeValue(forKey: id)?.stop()
                engineRenderProgress.removeValue(forKey: id)
            }
            applyRouting(for: app)
        }

        for app in apps where appNeedsEngine(app) && engines[app.id] == nil {
            applyRouting(for: app)
        }
        forgetEngineStateOfMissingRows(byId)
        if let nextPassDelay {
            scheduleEngineReconcile(after: nextPassDelay)
        }
    }

    private func scheduleEngineReconcile(after delay: Double) {
        guard !engineReconcilePending else { return }
        engineReconcilePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.01)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engineReconcilePending = false
                guard !self.stopped, self.listenerInstalled else { return }
                self.reconcileEngines(with: self.apps)
            }
        }
    }

    private func forgetEngineStateOfMissingRows(_ byId: [String: MixerApp]) {
        for id in engineChangeAt.keys where byId[id] == nil && engines[id] == nil {
            engineChangeAt.removeValue(forKey: id)
            objectsLostAt.removeValue(forKey: id)
            engineRecovery.clear(id)
        }
    }

    // MARK: - Persistence

    /// Upstream's `Defaults.sanitizedAppVolume`: a volume read back from disk
    /// or handed in by a slider is never trusted to be finite or in range.
    private nonisolated static func sanitizedVolume(_ volume: Double) -> Double {
        guard volume.isFinite else { return 1 }
        return min(max(volume, 0), MixerCore.maxVolume)
    }

    private func savedVolumes() -> [String: Double] {
        let raw = UserDefaults.standard.dictionary(forKey: MixerDefaultsKey.appVolumes) ?? [:]
        var sanitized: [String: Double] = [:]
        for (id, value) in raw {
            let number: Double?
            if let value = value as? Double {
                number = value
            } else if let value = value as? NSNumber {
                number = value.doubleValue
            } else {
                number = nil
            }
            guard let number, number.isFinite else { continue }
            sanitized[id] = Self.sanitizedVolume(number)
        }
        return sanitized
    }

    private func savedOutputDeviceUIDs() -> [String: String] {
        let raw = UserDefaults.standard.dictionary(forKey: MixerDefaultsKey.appOutputs) ?? [:]
        return MixerRoutingSupport.sanitizedRouteMap(raw)
    }

    // MARK: - List visibility

    func hideFromList(_ app: MixerApp) {
        guard let id = app.persistenceID else { return }
        var hidden = savedHiddenApps()
        hidden[id] = app.name
        persistHiddenApps(hidden)
        refreshApps()
    }

    func showInList(id: String) {
        var hidden = savedHiddenApps()
        hidden.removeValue(forKey: id)
        persistHiddenApps(hidden)
        refreshApps()
    }

    private func savedHiddenApps() -> [String: String] {
        MixerRoutingSupport.sanitizedHiddenApps(
            UserDefaults.standard.dictionary(forKey: MixerDefaultsKey.hiddenApps) ?? [:])
    }

    private func persistHiddenApps(_ hidden: [String: String]) {
        if hidden.isEmpty {
            UserDefaults.standard.removeObject(forKey: MixerDefaultsKey.hiddenApps)
        } else {
            UserDefaults.standard.set(hidden, forKey: MixerDefaultsKey.hiddenApps)
        }
        publishHiddenApps()
    }

    private func publishHiddenApps() {
        var entries = savedHiddenApps().map { MixerHiddenApp(id: $0.key, name: $0.value) }
        entries.sort {
            MixerRoutingSupport.displayOrderedBefore(name: $0.name, id: $0.id,
                                                     otherName: $1.name, otherID: $1.id)
        }
        if hiddenApps != entries { hiddenApps = entries }
    }

    /// The volume of a row: from disk when the row has a key to save under,
    /// otherwise from this session only. Static so a refresh pass can resolve
    /// rows off the main thread from copies of the session maps.
    private nonisolated static func storedVolume(for identity: MixerRowIdentity,
                                                 saved: [String: Double],
                                                 session: [String: Double]) -> Double? {
        guard let key = identity.persistenceID else { return session[identity.rowID] }
        return saved[key]
    }

    private nonisolated static func storedRoute(for identity: MixerRowIdentity,
                                                saved: [String: String],
                                                session: [String: String]) -> String? {
        guard let key = identity.persistenceID else { return session[identity.rowID] }
        return saved[key]
    }

    private func storedVolume(for identity: MixerRowIdentity, saved: [String: Double]) -> Double? {
        Self.storedVolume(for: identity, saved: saved, session: sessionVolumes)
    }

    private func storedRoute(for identity: MixerRowIdentity, saved: [String: String]) -> String? {
        Self.storedRoute(for: identity, saved: saved, session: sessionRoutes)
    }

    private func persistVolume(_ volume: Double, for app: MixerApp) {
        guard let id = app.persistenceID else {
            if isUnity(volume) {
                sessionVolumes.removeValue(forKey: app.id)
            } else {
                sessionVolumes[app.id] = volume
            }
            return
        }
        var volumes = savedVolumes()
        if isUnity(volume) {
            volumes.removeValue(forKey: id)
        } else {
            volumes[id] = volume
        }
        UserDefaults.standard.set(volumes, forKey: MixerDefaultsKey.appVolumes)
    }

    private func persistOutputDeviceUID(_ uid: String?, for app: MixerApp) {
        guard let id = app.persistenceID else {
            if let uid {
                sessionRoutes[app.id] = uid
            } else {
                sessionRoutes.removeValue(forKey: app.id)
            }
            return
        }
        var routes = savedOutputDeviceUIDs()
        if let uid {
            routes[id] = uid
        } else {
            routes.removeValue(forKey: id)
        }
        UserDefaults.standard.set(routes, forKey: MixerDefaultsKey.appOutputs)
    }

    private func persistOutputDeviceUIDs(_ routes: [String: String]) {
        if routes.isEmpty {
            UserDefaults.standard.removeObject(forKey: MixerDefaultsKey.appOutputs)
        } else {
            UserDefaults.standard.set(routes, forKey: MixerDefaultsKey.appOutputs)
        }
    }

    private func clearPermissionIfNoActiveAdjustments() {
        guard needsPermission,
              !apps.contains(where: appNeedsEngine),
              engines.isEmpty,
              builds.isEmpty else { return }
        needsPermission = false
    }

    // MARK: - CoreAudio plumbing

    private nonisolated static func audioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    /// The bundle id the audio HAL itself reports for a process object. Used
    /// only to fill in an identity the running-application lookup could not
    /// provide, never to override it.
    private nonisolated static func processBundleIdentifier(of object: AudioObjectID) -> String? {
        guard #available(macOS 14.4, *) else { return nil }
        var bundleRef: CFString = "" as CFString
        guard MixerCore.read(object, kAudioProcessPropertyBundleID, &bundleRef) else { return nil }
        let bundleID = bundleRef as String
        return bundleID.isEmpty ? nil : bundleID
    }

    private nonisolated static let outputVolumeSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyVolumeScalar,
    ]

    private nonisolated static func outputVolume(for deviceID: AudioObjectID) -> Float32? {
        for selector in outputVolumeSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var volume: Float32 = 0
            if MixerCore.read(deviceID, selector, &volume, scope: kAudioObjectPropertyScopeOutput) {
                return volume
            }
        }
        return nil
    }

    private nonisolated static func hasSettableOutputVolume(for deviceID: AudioObjectID) -> Bool {
        for selector in outputVolumeSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var isSettable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
               isSettable.boolValue {
                return true
            }
        }
        return false
    }

    private nonisolated static func outputDevices(defaultUID: String?) -> [MixerOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceIDs) == noErr else { return [] }

        var devices: [MixerOutputDevice] = []
        for deviceID in deviceIDs {
            guard hasOutputStreams(deviceID) else { continue }

            var isAlive: UInt32 = 1
            if MixerCore.read(deviceID, kAudioDevicePropertyDeviceIsAlive, &isAlive), isAlive == 0 {
                continue
            }
            var isHidden: UInt32 = 0
            if MixerCore.read(deviceID, kAudioDevicePropertyIsHidden, &isHidden), isHidden != 0 {
                continue
            }
            let canBeDefaultOutput = canBeDefault(deviceID,
                                                  selector: kAudioDevicePropertyDeviceCanBeDefaultDevice)
            let canBeDefaultSystemOutput = canBeDefault(
                deviceID,
                selector: kAudioDevicePropertyDeviceCanBeDefaultSystemDevice)

            var uidRef: CFString = "" as CFString
            guard MixerCore.read(deviceID, kAudioDevicePropertyDeviceUID, &uidRef) else { continue }
            let uid = uidRef as String
            guard !uid.isEmpty else { continue }

            var nameRef: CFString = "" as CFString
            let name = MixerCore.read(deviceID, kAudioObjectPropertyName, &nameRef)
                ? nameRef as String
                : uid
            // The mixer's own aggregate device is not somewhere to route to.
            guard name != "Prosper Mixer" else { continue }
            let dataSourceName = outputDataSourceName(for: deviceID)

            devices.append(MixerOutputDevice(id: uid,
                                             uid: uid,
                                             name: name,
                                             isDefault: uid == defaultUID,
                                             isHeadphones: MixerRoutingSupport.outputLooksLikeHeadphones(
                                                name: name,
                                                uid: uid,
                                                dataSourceName: dataSourceName),
                                             canBeDefaultOutput: canBeDefaultOutput,
                                             canBeDefaultSystemOutput: canBeDefaultSystemOutput,
                                             audioObjectID: deviceID))
        }

        return devices.sorted { lhs, rhs in
            MixerRoutingSupport.deviceDisplayOrderedBefore(
                isDefault: lhs.isDefault, name: lhs.name, uid: lhs.uid,
                otherIsDefault: rhs.isDefault, otherName: rhs.name, otherUID: rhs.uid)
        }
    }

    private nonisolated static func outputDataSourceName(for deviceID: AudioObjectID) -> String? {
        var dataSourceID: UInt32 = 0
        guard MixerCore.read(deviceID,
                             kAudioDevicePropertyDataSource,
                             &dataSourceID,
                             scope: kAudioObjectPropertyScopeOutput) else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var nameRef: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &dataSourceID) { dataSourcePointer in
            withUnsafeMutablePointer(to: &nameRef) { namePointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(dataSourcePointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(namePointer),
                    mOutputDataSize: UInt32(MemoryLayout<CFString>.size))
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    &size,
                    &translation)
            }
        }
        guard status == noErr else { return nil }
        return nameRef as String
    }

    private nonisolated static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
            && size >= MemoryLayout<AudioObjectID>.size
    }

    private nonisolated static func canBeDefault(_ deviceID: AudioObjectID,
                                                 selector: AudioObjectPropertySelector) -> Bool {
        var value: UInt32 = 0
        return MixerCore.read(deviceID, selector, &value, scope: kAudioObjectPropertyScopeOutput) && value != 0
    }

    private nonisolated static func defaultOutputDeviceUID(
        selector: AudioObjectPropertySelector = kAudioHardwarePropertyDefaultOutputDevice
    ) -> String? {
        var defaultDevice = AudioObjectID(0)
        guard MixerCore.read(AudioObjectID(kAudioObjectSystemObject),
                             selector, &defaultDevice),
              defaultDevice != 0 else { return nil }
        var uidRef: CFString = "" as CFString
        guard MixerCore.read(defaultDevice, kAudioDevicePropertyDeviceUID, &uidRef) else { return nil }
        return uidRef as String
    }

    private nonisolated static func setDefaultDevice(_ deviceID: AudioObjectID,
                                                     selector: AudioObjectPropertySelector) -> OSStatus {
        var nextDeviceID = deviceID
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &address,
                                          0,
                                          nil,
                                          UInt32(MemoryLayout<AudioObjectID>.size),
                                          &nextDeviceID)
    }

    private nonisolated static func setOutputVolume(_ volume: Float32, for deviceID: AudioObjectID) -> Bool {
        let clamped = min(max(volume, 0), 1)
        for selector in outputVolumeSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }

            var isSettable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
                  isSettable.boolValue else { continue }

            var nextVolume = clamped
            let status = AudioObjectSetPropertyData(deviceID,
                                                    &address,
                                                    0,
                                                    nil,
                                                    UInt32(MemoryLayout<Float32>.size),
                                                    &nextVolume)
            if status == noErr {
                return true
            }
        }
        return false
    }

    /// System volume as people mean it: the default output device's main
    /// scalar. Static on purpose so callers never spin the mixer up; false
    /// when the device exposes no software volume control.
    @discardableResult
    nonisolated static func setSystemOutputVolume(_ volume: Double) -> Bool {
        guard let device = defaultOutputDeviceID() else { return false }
        let clamped = Float32(min(max(volume, 0), 1))
        let applied = setOutputVolume(clamped, for: device)
        // Mute is a separate switch from the level, so asking for a volume
        // while the Mac is muted would set a number nobody can hear. Asking
        // for sound means asking for sound, which is what the volume keys do.
        if clamped > 0 { setOutputMuted(false, for: device) }
        return applied
    }

    /// Whether the sound is currently cut, or nil when this output has no
    /// mute switch of its own.
    nonisolated static func systemOutputIsMuted() -> Bool? {
        guard let device = defaultOutputDeviceID() else { return nil }
        return outputMuted(for: device)
    }

    @discardableResult
    nonisolated static func setSystemOutputMuted(_ muted: Bool) -> Bool {
        guard let device = defaultOutputDeviceID() else { return false }
        return setOutputMuted(muted, for: device)
    }

    private nonisolated static func defaultOutputDeviceID() -> AudioObjectID? {
        var device = AudioObjectID(0)
        guard MixerCore.read(AudioObjectID(kAudioObjectSystemObject),
                             kAudioHardwarePropertyDefaultOutputDevice, &device),
              device != 0 else { return nil }
        return device
    }

    /// The mute switch can sit on the device as a whole or on each channel,
    /// depending on the driver, so both are tried before giving up.
    private nonisolated static func muteElements(for deviceID: AudioObjectID) -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain, 1, 2]
    }

    private nonisolated static func outputMuted(for deviceID: AudioObjectID) -> Bool? {
        for element in muteElements(for: deviceID) {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
            else { continue }
            return value != 0
        }
        return nil
    }

    @discardableResult
    private nonisolated static func setOutputMuted(_ muted: Bool, for deviceID: AudioObjectID) -> Bool {
        var changed = false
        for element in muteElements(for: deviceID) {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                changed = true
            }
        }
        return changed
    }
}
