// Settings pane for the Volume Mixer. Master enable (adds/removes the menu-bar
// item live), the System Audio Recording permission hint, and the list of apps
// hidden from the panel so a hide made there can be undone from here.

import AppKit
import SwiftUI

struct VolumeMixerPane: View {
    @ObservedObject private var mixer = AppVolumeMixer.shared
    @ObservedObject private var inputs = AudioInputDeviceManager.shared
    @State private var enabled = Preferences.mixerEnabled
    @State private var iconEnabled = Preferences.mixerIconEnabled
    @State private var cycleCombo = ShortcutStore.combo(for: .mixerCycleOutput)
    @State private var micMuteCombo = ShortcutStore.combo(for: .mixerToggleMicMute)
    @AppStorage(MixerDefaultsKey.hideInactiveApps) private var hideInactiveApps = true

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Volume Mixer", accent: "Mixer",
                      subtitle: "Per-app volume, boost and output routing, from your menu bar")

            NeonSection("Volume Mixer",
                        footer: "Off means nothing runs \u{2014} no audio taps, no device listeners, no menu-bar item.") {
                if MixerCore.isSupported {
                    NeonRow("Enable volume mixer",
                            subtitle: "The whole feature: per-app volume, microphone routing and output switching") {
                        Toggle("", isOn: $enabled).labelsHidden()
                            .onChange(of: enabled) { _, v in
                                Preferences.mixerEnabled = v
                                MixerPanelController.shared.reload()
                                // Both mixer hotkeys are gated on this
                                // preference, so they have to be (un)registered now.
                                SettingsHooks.shared.onShortcutsChanged?()
                            }
                    }
                } else {
                    NeonRow("Enable volume mixer",
                            subtitle: "Per-app volume needs macOS 14.4 or newer.") { EmptyView() }
                }
            }

            if MixerCore.isSupported, enabled {
                // The icon is a separate switch: hiding it leaves the engine,
                // the shortcuts and the microphone routing running.
                NeonSection("Menu Bar") {
                    NeonRow("Show Volume Mixer",
                            subtitle: "Adds a volume item to the menu bar, replacing the native sound control") {
                        Toggle("", isOn: $iconEnabled).labelsHidden()
                            .onChange(of: iconEnabled) { _, v in
                                Preferences.mixerIconEnabled = v
                                MixerPanelController.shared.reload()
                            }
                    }
                    NeonDivider()
                    NeonRow("Hide inactive apps",
                            subtitle: "Lists only apps that are playing or already adjusted") {
                        Toggle("", isOn: $hideInactiveApps).labelsHidden()
                    }
                }

                if mixer.needsPermission {
                    NeonSection("Permission",
                                footer: "Prosper taps each app's audio to re-render it at your chosen volume; macOS gates that behind System Audio Recording.") {
                        NeonRow("System Audio Recording",
                                subtitle: "Not granted — apps are listed but their volume can't be changed") {
                            Button("Open System Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.neon)
                        }
                    }
                }

                NeonSection("Alerts",
                            footer: "Alert and interface sounds can play on a different device than your music and video \u{2014} handy when the main output is a headset.") {
                    NeonRow("Alert output",
                            subtitle: "Where macOS plays sound effects") {
                        Picker("", selection: soundEffectsSelection) {
                            if mixer.currentSystemSoundOutputDeviceUID == nil {
                                Text("Unavailable").tag(MixerRoutingSupport.systemDefaultSelectionID)
                            }
                            ForEach(soundEffectsDevices) { device in
                                Text(soundEffectsTitle(device)).tag(device.uid)
                            }
                            if let selected = mixer.currentSystemSoundOutputDeviceUID,
                               !soundEffectsDevices.contains(where: { $0.uid == selected }) {
                                Text("Unavailable").tag(selected)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .disabled(soundEffectsDevices.isEmpty)
                    }
                }

                NeonSection("Microphone",
                            footer: "Prosper re-selects this microphone whenever it is connected, and falls back to the system default while it is away.") {
                    NeonRow("Preferred input",
                            subtitle: inputSubtitle) {
                        Picker("", selection: inputSelection) {
                            Text("System default").tag(MixerRoutingSupport.systemDefaultSelectionID)
                            ForEach(inputs.inputDevices) { device in
                                Text(device.name).tag(device.uid)
                            }
                            if let preferred = inputs.preferredInputDeviceUID,
                               !inputs.inputDevices.contains(where: { $0.uid == preferred }) {
                                Text("Unavailable").tag(preferred)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .disabled(inputs.inputDevices.isEmpty)
                    }
                    NeonDivider()
                    NeonRow("Mute every microphone",
                            subtitle: micMuteSubtitle) {
                        ShortcutRecorder(combo: micMuteCombo) { combo in
                            setMicMuteCombo(combo)
                        }
                        .frame(width: sz(110), height: sz(24))
                        .fixedSize()
                        Button {
                            setMicMuteCombo(unsetKeyCombo)
                        } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .help("Disable this shortcut")
                        Toggle("", isOn: Binding(get: { inputs.micMuted },
                                                 set: { inputs.setMicMuted($0) }))
                            .labelsHidden()
                            .disabled(inputs.inputDevices.isEmpty)
                    }
                }

                NeonSection("Sound Output Switcher",
                            footer: "The shortcut steps through the ticked outputs in the order listed. Untick everything to switch it off; while nothing is ticked or unticked, every output takes part.") {
                    NeonRow("Next sound output", subtitle: cycleSubtitle) {
                        ShortcutRecorder(combo: cycleCombo) { combo in
                            setCycleCombo(combo)
                        }
                        .frame(width: sz(110), height: sz(24))
                        .fixedSize()
                        Button {
                            setCycleCombo(unsetKeyCombo)
                        } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .help("Disable this shortcut")
                    }
                    ForEach(cyclableOutputs) { device in
                        NeonDivider()
                        NeonRow(device.name) {
                            Toggle("", isOn: participation(device.uid)).labelsHidden()
                        }
                    }
                }

                NeonSection("Hidden Apps",
                            footer: "Hidden apps never appear in the panel and are never tapped.") {
                    if mixer.hiddenApps.isEmpty {
                        NeonRow("Nothing hidden",
                                subtitle: "Uncheck an app under \u{201C}Visible apps\u{201D} in the panel to hide it") { EmptyView() }
                    } else {
                        ForEach(mixer.hiddenApps) { hidden in
                            NeonRow(hidden.name) {
                                Button("Show") { mixer.showInList(id: hidden.id) }
                                    .buttonStyle(.neon)
                            }
                        }
                    }
                }
            }
        }
    }

    private var soundEffectsDevices: [MixerOutputDevice] {
        mixer.outputDevices.filter(\.canBeDefaultSystemOutput)
    }

    private var soundEffectsSelection: Binding<String> {
        Binding(
            get: {
                mixer.currentSystemSoundOutputDeviceUID
                    ?? MixerRoutingSupport.systemDefaultSelectionID
            },
            set: { selection in
                guard selection != MixerRoutingSupport.systemDefaultSelectionID else { return }
                mixer.setSystemSoundOutputDeviceUID(selection)
            }
        )
    }

    private func soundEffectsTitle(_ device: MixerOutputDevice) -> String {
        device.uid == mixer.currentSystemSoundOutputDeviceUID
            ? "\(device.name) (current)"
            : device.name
    }

    private var cyclableOutputs: [MixerOutputDevice] {
        mixer.outputDevices.filter(\.canBeDefaultOutput)
    }

    private var cycleSubtitle: String {
        if cycleCombo == unsetKeyCombo { return "No shortcut yet — click to record one" }
        if mixer.participatingOutputUIDs.count < 2 { return "Tick at least two outputs to cycle between" }
        return "Switches the system output to the next ticked device"
    }

    private var micMuteSubtitle: String {
        if micMuteCombo == unsetKeyCombo {
            return "Silences all inputs at the device, whichever app is listening"
        }
        return "Silences all inputs at the device \u{2014} the shortcut toggles it too"
    }

    private func setMicMuteCombo(_ combo: KeyCombo) {
        micMuteCombo = combo
        ShortcutStore.setCombo(combo, for: .mixerToggleMicMute)
        SettingsHooks.shared.onShortcutsChanged?()
    }

    private func setCycleCombo(_ combo: KeyCombo) {
        cycleCombo = combo
        ShortcutStore.setCombo(combo, for: .mixerCycleOutput)
        SettingsHooks.shared.onShortcutsChanged?()
    }

    /// Ticking a box for the first time freezes today's outputs into an explicit
    /// list — before that the list is absent and means "all of them".
    private func participation(_ uid: String) -> Binding<Bool> {
        Binding(
            get: { mixer.participatingOutputUIDs.contains(uid) },
            set: { on in
                var uids = mixer.participatingOutputUIDs
                if on {
                    if !uids.contains(uid) { uids.append(uid) }
                } else {
                    uids.removeAll { $0 == uid }
                }
                mixer.setSoundOutputCycleUIDs(uids)
            }
        )
    }

    private var inputSubtitle: String {
        if let error = inputs.lastError { return error }
        if inputs.inputDevices.isEmpty { return "No microphone available" }
        if inputs.preferredUnavailable { return "Not connected — using the system default" }
        return "The microphone Prosper keeps selected"
    }

    private var inputSelection: Binding<String> {
        Binding(
            get: {
                inputs.preferredInputDeviceUID
                    ?? inputs.currentInputDeviceUID
                    ?? MixerRoutingSupport.systemDefaultSelectionID
            },
            set: { selection in
                inputs.setPreferredInputDeviceUID(
                    selection == MixerRoutingSupport.systemDefaultSelectionID ? nil : selection)
            }
        )
    }
}
