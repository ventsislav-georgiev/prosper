// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint's UI/MenuPanel/MixerSection.swift. The UX shape is
// upstream's — global output controls first, per-app rows below, a visibility
// footer last — rewritten against Prosper's `Neon`/`ThemePalette` tokens and
// `sz()` scaling instead of upstream's PanelSection / PanelMetricColor / L10n.

import AppKit
import SwiftUI

/// Accents the palette has no token for: the boost range and the "playing"
/// dot. Matched to the neon surfaces rather than the system accent.
private enum MixerAccent {
    static let boost = Color(red: 1.0, green: 0.68, blue: 0.20)   // amber, >100%
    static var playing: Color { Neon.terminal }
    static var muted: Color { Neon.magenta }
}

/// The popover behind Prosper's volume menu-bar item: a replacement for the
/// native sound control (system output volume, mute, device) with the per-app
/// mixer macOS never shipped underneath it.
struct MixerPanelView: View {
    @ObservedObject private var mixer = AppVolumeMixer.shared
    @ObservedObject private var inputs = AudioInputDeviceManager.shared
    @AppStorage(MixerDefaultsKey.hideInactiveApps) private var hideInactiveApps = false
    @State private var showListChooser = false
    @State private var editingVolumeID: String?
    /// Where the system slider was before the mute button zeroed it. The HAL
    /// mute property has no setter on the service, so "mute" is volume 0 that
    /// remembers — same contract as the per-app rows.
    @State private var lastSystemVolume: Double = 1

    /// Settings selection id `VolumeMixerPane` is registered under in
    /// `settingsSidebarGroups`; the gear button in the footer opens it.
    private static let settingsSelection = "audio-mixer"

    var body: some View {
        VStack(alignment: .leading, spacing: sz(10)) {
            header
            globalSection
            NeonDivider()
            appsSection
            NeonDivider()
            footer
        }
        .padding(sz(14))
        .frame(width: sz(340))
        .background(Neon.bgTop)
        .foregroundStyle(Neon.textPrimary)
        .tint(Neon.blue)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: sz(8)) {
            Image(systemName: "slider.horizontal.3")
                .font(Neon.font(13, weight: .semibold))
                .foregroundStyle(Neon.blue)
            neonAccentedText("Volume Mixer", accent: "Mixer")
                .font(Neon.font(15, weight: .bold, design: .rounded))
            Spacer()
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Neon.font(10, weight: .bold))
            .textCase(.uppercase)
            .tracking(sz(1.2))
            .foregroundStyle(Neon.textSecondary)
    }

    // MARK: - Global (native sound-control parity)

    private var globalSection: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            sectionLabel("Output")
            outputDeviceRow
            systemVolumeRow
            soundEffectsRow
            if let outputSwitchError = mixer.outputSwitchError {
                hint("Could not switch output: \(outputSwitchError)",
                     systemImage: "exclamationmark.triangle")
            }
            if universalOutputDevices.isEmpty {
                hint("No output devices available.", systemImage: "speaker.slash")
            }

            // MARK: Microphone input
            sectionLabel("Microphone")
                .padding(.top, sz(2))
            inputDeviceRow
            if let inputError = inputs.lastError {
                hint(inputError, systemImage: "exclamationmark.triangle")
            }
            if inputs.inputDevices.isEmpty {
                hint("No microphone available.", systemImage: "mic.slash")
            } else if inputs.preferredUnavailable {
                hint("Preferred microphone isn't connected — using the system default.",
                     systemImage: "mic.badge.xmark")
            }
        }
    }

    /// The mic glyph doubles as the mute-everything switch, the same way the
    /// system volume row's speaker glyph does.
    private var inputDeviceRow: some View {
        HStack(spacing: sz(8)) {
            Button {
                inputs.toggleMicMute()
            } label: {
                Image(systemName: inputs.micMuted ? "mic.slash.fill" : "mic.fill")
                    .font(Neon.font(10.5, weight: .semibold))
                    .foregroundStyle(inputs.micMuted ? MixerAccent.muted : Neon.textSecondary)
                    .frame(width: sz(16))
            }
            .buttonStyle(.plain)
            .disabled(inputs.inputDevices.isEmpty)
            .help(inputs.micMuted ? "Unmute every microphone" : "Mute every microphone")

            Text("Device")
                .font(Neon.font(11.5, weight: .medium))
                .foregroundStyle(Neon.textSecondary)
            Spacer(minLength: sz(6))
            Picker("Input device", selection: inputSelection) {
                Text("System default").tag(MixerRoutingSupport.systemDefaultSelectionID)
                ForEach(inputs.inputDevices) { device in
                    Text(inputTitle(device)).tag(device.uid)
                }
                if let preferred = inputs.preferredInputDeviceUID,
                   !inputs.inputDevices.contains(where: { $0.uid == preferred }) {
                    Text("Unavailable").tag(preferred)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: sz(178))
            .disabled(inputs.inputDevices.isEmpty)
        }
    }

    /// The picker shows the saved preference when there is one, so a microphone
    /// that is merely unplugged still reads as the choice; otherwise whatever
    /// the system is on.
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

    private func inputTitle(_ device: MixerInputDevice) -> String {
        device.isDefault ? "\(device.name) (current)" : device.name
    }

    private var outputDeviceRow: some View {
        HStack(spacing: sz(8)) {
            Image(systemName: "speaker.wave.2.fill")
                .font(Neon.font(10.5, weight: .semibold))
                .foregroundStyle(Neon.textSecondary)
                .frame(width: sz(16))
            Text("Device")
                .font(Neon.font(11.5, weight: .medium))
                .foregroundStyle(Neon.textSecondary)
            Spacer(minLength: sz(6))
            Picker("Output device", selection: universalOutputSelection) {
                if mixer.currentOutputDeviceUID == nil {
                    Text("Unavailable").tag(MixerRoutingSupport.systemDefaultSelectionID)
                }
                ForEach(universalOutputDevices) { device in
                    Text(deviceTitle(device)).tag(device.uid)
                }
                if let selected = mixer.currentOutputDeviceUID,
                   !universalOutputDevices.contains(where: { $0.uid == selected }) {
                    Text("Unavailable").tag(selected)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: sz(178))
            .disabled(universalOutputDevices.isEmpty)
        }
    }

    @ViewBuilder
    private var systemVolumeRow: some View {
        if let volume = mixer.systemOutputVolume {
            let isMuted = mixer.systemOutputMuted == true || volume <= 0.001
            HStack(spacing: sz(8)) {
                Button {
                    if volume > 0.001 {
                        lastSystemVolume = volume
                        mixer.setCurrentOutputVolume(0)
                    } else {
                        mixer.setCurrentOutputVolume(lastSystemVolume > 0.001 ? lastSystemVolume : 1)
                    }
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(Neon.font(10, weight: .semibold))
                        .foregroundStyle(isMuted ? MixerAccent.muted : Neon.textSecondary)
                        .frame(width: sz(16))
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Unmute system output" : "Mute system output")

                Slider(value: systemVolumeBinding, in: 0...1)
                    .controlSize(.small)
                    .tint(Neon.blue)
                    .accessibilityLabel("System output volume")

                EditableVolumePercent(currentPercent: Int((volume * 100).rounded()),
                                      maximumPercent: 100,
                                      width: sz(40),
                                      editorID: "system-output",
                                      editingID: $editingVolumeID,
                                      accessibilityLabel: "System output volume") {
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(Neon.font(10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Neon.textSecondary)
                } onCommit: {
                    mixer.setCurrentOutputVolume($0)
                }
            }
        }
    }

    private var soundEffectsRow: some View {
        HStack(spacing: sz(8)) {
            Image(systemName: "bell.fill")
                .font(Neon.font(10.5, weight: .semibold))
                .foregroundStyle(Neon.textSecondary)
                .frame(width: sz(16))
            Text("Alerts")
                .font(Neon.font(11.5, weight: .medium))
                .foregroundStyle(Neon.textSecondary)
            Spacer(minLength: sz(6))
            Picker("Sound effects output", selection: soundEffectsSelection) {
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
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: sz(178))
            .disabled(soundEffectsDevices.isEmpty)
        }
    }

    private var universalOutputDevices: [MixerOutputDevice] {
        mixer.outputDevices.filter(\.canBeDefaultOutput)
    }

    private var soundEffectsDevices: [MixerOutputDevice] {
        mixer.outputDevices.filter(\.canBeDefaultSystemOutput)
    }

    private var universalOutputSelection: Binding<String> {
        Binding(
            get: { mixer.currentOutputDeviceUID ?? MixerRoutingSupport.systemDefaultSelectionID },
            set: { selection in
                guard selection != MixerRoutingSupport.systemDefaultSelectionID else { return }
                mixer.setUniversalOutputDeviceUID(selection)
            }
        )
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

    private var systemVolumeBinding: Binding<Double> {
        Binding(
            get: { mixer.systemOutputVolume ?? 0 },
            set: { mixer.setCurrentOutputVolume($0) }
        )
    }

    private func deviceTitle(_ device: MixerOutputDevice) -> String {
        device.isDefault ? "\(device.name) (current)" : device.name
    }

    private func soundEffectsTitle(_ device: MixerOutputDevice) -> String {
        device.uid == mixer.currentSystemSoundOutputDeviceUID
            ? "\(device.name) (current)"
            : device.name
    }

    // MARK: - Per-app rows

    @ViewBuilder
    private var appsSection: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            sectionLabel("Apps")
            if !MixerCore.isSupported {
                empty("Per-app volume needs macOS 14.4 or newer.")
            } else if mixer.needsPermission {
                permissionHint
                rowList
            } else if visibleApps.isEmpty {
                empty("No app is playing audio.")
            } else {
                rowList
            }
        }
    }

    @ViewBuilder
    private var rowList: some View {
        if !visibleApps.isEmpty {
            // Cap the list instead of growing the popover past the screen; a
            // busy machine can hold a dozen audio clients.
            ScrollView {
                VStack(alignment: .leading, spacing: sz(4)) {
                    ForEach(visibleApps) { app in
                        MixerAppRow(app: app, editingVolumeID: $editingVolumeID)
                    }
                }
            }
            .frame(maxHeight: sz(280))
        }
    }

    private var visibleApps: [MixerApp] {
        mixer.apps.filter { app in
            MixerRoutingSupport.shouldShowApp(isPlaying: app.isPlaying,
                                              volume: app.volume,
                                              selectedOutputDeviceUID: app.selectedOutputDeviceUID,
                                              hideInactiveApps: hideInactiveApps)
        }
    }

    /// A banner, never a gate: rows the tap cannot reach still list, so the
    /// user sees what the grant would unlock.
    private var permissionHint: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            Text("Prosper needs Audio Recording access to change app volumes.")
                .font(Neon.font(10.5))
                .foregroundStyle(Neon.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.neon)
        }
        .padding(.vertical, sz(2))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: sz(8)) {
            HStack(spacing: sz(8)) {
                Text("Hide inactive apps")
                    .font(Neon.font(10.5))
                    .foregroundStyle(Neon.textSecondary)
                Spacer(minLength: sz(6))
                Toggle("Hide inactive apps", isOn: $hideInactiveApps)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            listChooser

            HStack(spacing: sz(8)) {
                Button("Reset all apps") { mixer.resetAll() }
                    .buttonStyle(.neon)
                    .disabled(mixer.apps.isEmpty)
                Spacer(minLength: sz(6))
                Button {
                    LiveExtensionHostServices.shared.settingsOpener?(Self.settingsSelection)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(Neon.font(12, weight: .semibold))
                        .foregroundStyle(Neon.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Volume mixer settings")
            }
        }
    }

    private var listChooser: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            Button {
                showListChooser.toggle()
            } label: {
                HStack(spacing: sz(8)) {
                    Text("Visible apps")
                        .font(Neon.font(10.5))
                        .foregroundStyle(Neon.textSecondary)
                    Spacer(minLength: sz(6))
                    Text(mixer.hiddenApps.isEmpty
                         ? "All shown"
                         : "Hidden: \(mixer.hiddenApps.count)")
                        .font(Neon.font(10))
                        .foregroundStyle(Neon.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(Neon.font(8, weight: .semibold))
                        .foregroundStyle(Neon.textSecondary)
                        .rotationEffect(.degrees(showListChooser ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showListChooser {
                ForEach(listChoices) { choice in
                    Toggle(isOn: listedBinding(for: choice)) {
                        Text(choice.name)
                            .font(Neon.font(10.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(!choice.canToggle)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: showListChooser)
    }

    private struct MixerListChoice: Identifiable {
        let id: String
        let name: String
        let isListed: Bool
        let canToggle: Bool
    }

    private var listChoices: [MixerListChoice] {
        var seen = Set<String>()
        var choices = mixer.hiddenApps.map { hidden -> MixerListChoice in
            seen.insert(hidden.id)
            return MixerListChoice(id: hidden.id, name: hidden.name,
                                   isListed: false, canToggle: true)
        }
        for app in mixer.apps {
            let id = app.persistenceID ?? app.id
            guard seen.insert(id).inserted else { continue }
            choices.append(MixerListChoice(id: id, name: app.name,
                                           isListed: true,
                                           canToggle: app.persistenceID != nil))
        }
        choices.sort {
            MixerRoutingSupport.displayOrderedBefore(name: $0.name, id: $0.id,
                                                     otherName: $1.name, otherID: $1.id)
        }
        return choices
    }

    private func listedBinding(for choice: MixerListChoice) -> Binding<Bool> {
        Binding(
            get: { choice.isListed },
            set: { listed in
                if listed {
                    mixer.showInList(id: choice.id)
                } else if let app = mixer.apps.first(where: {
                    ($0.persistenceID ?? $0.id) == choice.id
                }) {
                    mixer.hideFromList(app)
                }
            }
        )
    }

    // MARK: - Small shared bits

    private func hint(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(Neon.font(9.5))
            .foregroundStyle(Neon.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(Neon.font(11))
            .foregroundStyle(Neon.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, sz(6))
    }
}

// MARK: - One app row

private struct MixerAppRow: View {
    @ObservedObject private var mixer = AppVolumeMixer.shared
    let app: MixerApp
    @Binding var editingVolumeID: String?

    /// Icon spans the row's two lines; the bitmap must be requested at this
    /// size or the upscale looks blurry.
    private static let iconPointSize: CGFloat = 30

    /// Tie the visual state to the DISPLAYED percentage, so "amber" and
    /// ">100%" always agree.
    private var isBoosting: Bool { (app.volume * 100).rounded() > 100 }
    private var isMuted: Bool { app.volume <= 0.001 }
    /// The reset shows whenever the row was touched at all — volume moved off
    /// unity or a route was pinned.
    private var isTouched: Bool {
        !MixerRoutingSupport.isUnity(app.volume) || app.selectedOutputDeviceUID != nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: sz(10)) {
            icon
            VStack(alignment: .leading, spacing: sz(4)) {
                HStack(spacing: sz(8)) {
                    Text(app.name)
                        .font(Neon.font(11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: sz(4))
                    if !app.isBypassed { outputPicker }
                }

                if app.isBypassed {
                    // Conferencing and pro-audio apps are listed but never
                    // tapped: the row explains itself instead of the app
                    // silently missing from the mixer.
                    Text("Left untouched — tapping this app would break its audio.")
                        .font(Neon.font(10))
                        .foregroundStyle(Neon.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    controls
                    if app.outputDeviceUnavailable {
                        Label("Saved output is gone — playing on the system default.",
                              systemImage: "speaker.badge.exclamationmark")
                            .font(Neon.font(9.5))
                            .foregroundStyle(MixerAccent.boost)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, sz(2))
        .contextMenu {
            // Same action as unchecking the app in the footer chooser, one
            // right-click closer.
            if app.persistenceID != nil {
                Button("Hide from list") { mixer.hideFromList(app) }
            }
        }
    }

    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: ResponsibleProcess.icon(for: app.ownerPid,
                                                   pointSize: sz(Self.iconPointSize)))
                .resizable()
                .frame(width: sz(Self.iconPointSize), height: sz(Self.iconPointSize))
            if app.isPlaying {
                Circle()
                    .fill(MixerAccent.playing)
                    .frame(width: sz(8), height: sz(8))
                    .overlay(Circle().stroke(Neon.bgTop, lineWidth: 1.2))
                    .shadow(color: MixerAccent.playing.opacity(0.8), radius: sz(3))
                    .offset(x: -1, y: -1)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: sz(8)) {
            Slider(value: volumeBinding, in: 0...MixerCore.maxVolume)
                .controlSize(.small)
                .tint(isBoosting ? MixerAccent.boost : Neon.blue)
                .accessibilityLabel(app.name)
                .accessibilityValue("\(Int((app.volume * 100).rounded()))%")

            EditableVolumePercent(currentPercent: Int((app.volume * 100).rounded()),
                                  maximumPercent: Int(MixerCore.maxVolume * 100),
                                  width: sz(44),
                                  editorID: "app:\(app.id)",
                                  editingID: $editingVolumeID,
                                  accessibilityLabel: app.name) {
                HStack(spacing: sz(2)) {
                    if isBoosting {
                        Image(systemName: "bolt.fill")
                            .font(Neon.font(8, weight: .bold))
                            .foregroundStyle(MixerAccent.boost)
                    }
                    Text("\(Int((app.volume * 100).rounded()))%")
                        .font(Neon.font(10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isBoosting ? MixerAccent.boost : Neon.textSecondary)
                }
            } onCommit: {
                mixer.setVolume($0, for: app)
            }

            Button { mixer.resetRow(app) } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(Neon.font(9.5, weight: .semibold))
                    .foregroundStyle(isBoosting ? MixerAccent.boost : Neon.textSecondary)
                    .frame(width: sz(14))
            }
            .buttonStyle(.plain)
            .help("Reset to 100% on the system default output")
            .opacity(isTouched ? 1 : 0)
            .disabled(!isTouched)

            Button { mixer.toggleMute(app) } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(Neon.font(10))
                    .foregroundStyle(isMuted ? MixerAccent.muted : Neon.textSecondary)
                    .frame(width: sz(16))
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Unmute" : "Mute")
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { app.volume },
            set: { mixer.setVolume($0, for: app) }
        )
    }

    private var outputPicker: some View {
        Picker("Output device", selection: outputSelection) {
            Text("System Default").tag(MixerRoutingSupport.systemDefaultSelectionID)
            ForEach(mixer.outputDevices) { device in
                Text(device.isDefault ? "\(device.name) (current)" : device.name)
                    .tag(device.uid)
            }
            if let selected = app.selectedOutputDeviceUID, app.outputDeviceUnavailable {
                Text("Unavailable").tag(selected)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: sz(118))
        .disabled(app.isBypassed)
    }

    private var outputSelection: Binding<String> {
        Binding(
            get: { app.selectedOutputDeviceUID ?? MixerRoutingSupport.systemDefaultSelectionID },
            set: { selection in
                mixer.setOutputDeviceUID(
                    selection == MixerRoutingSupport.systemDefaultSelectionID ? nil : selection,
                    for: app)
            }
        )
    }
}
