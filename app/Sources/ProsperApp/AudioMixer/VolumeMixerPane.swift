// Settings pane for the Volume Mixer. Master enable (adds/removes the menu-bar
// item live), the System Audio Recording permission hint, and the list of apps
// hidden from the panel so a hide made there can be undone from here.

import AppKit
import SwiftUI

struct VolumeMixerPane: View {
    @ObservedObject private var mixer = AppVolumeMixer.shared
    @ObservedObject private var inputs = AudioInputDeviceManager.shared
    @State private var enabled = Preferences.mixerEnabled
    @State private var cycleCombo = ShortcutStore.combo(for: .mixerCycleOutput)
    @AppStorage(MixerDefaultsKey.hideInactiveApps) private var hideInactiveApps = false

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Volume Mixer", accent: "Mixer",
                      subtitle: "Per-app volume, boost and output routing, from your menu bar")

            NeonSection("Menu Bar") {
                if MixerCore.isSupported {
                    NeonRow("Show Volume Mixer",
                            subtitle: "Adds a volume item to the menu bar, replacing the native sound control") {
                        Toggle("", isOn: $enabled).labelsHidden()
                            .onChange(of: enabled) { _, v in
                                Preferences.mixerEnabled = v
                                MixerPanelController.shared.reload()
                                // The output-cycle hotkey is gated on this
                                // preference, so it has to be (un)registered now.
                                SettingsHooks.shared.onShortcutsChanged?()
                            }
                    }
                    NeonDivider()
                    NeonRow("Hide inactive apps",
                            subtitle: "Lists only apps that are playing or already adjusted") {
                        Toggle("", isOn: $hideInactiveApps).labelsHidden()
                    }
                } else {
                    NeonRow("Show Volume Mixer",
                            subtitle: "Per-app volume needs macOS 14.4 or newer.") { EmptyView() }
                }
            }

            if MixerCore.isSupported, enabled {
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
                            subtitle: "Silences all inputs at the device, whichever app is listening") {
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

    private var cyclableOutputs: [MixerOutputDevice] {
        mixer.outputDevices.filter(\.canBeDefaultOutput)
    }

    private var cycleSubtitle: String {
        if cycleCombo == unsetKeyCombo { return "No shortcut yet — click to record one" }
        if mixer.participatingOutputUIDs.count < 2 { return "Tick at least two outputs to cycle between" }
        return "Switches the system output to the next ticked device"
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
