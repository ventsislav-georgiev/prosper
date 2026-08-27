import SwiftUI
import XCTest
@testable import ProsperApp

/// Regression guard for #081/#083: the volume mixer popup must report the
/// exact same layout size whether the system output is muted or not. #081
/// fixed one cause (state-swapped SF Symbol glyphs with no reserved height);
/// this file proves that fix holds for every real glyph pair the popup uses,
/// and separately proves `EditableVolumePercent` (the "0%"/"6%" field) never
/// changes size across percent value or editing state — the two pieces of
/// `systemVolumeRow` that are conditional on mute/volume.
///
/// `AppVolumeMixer.shared`'s published output-volume/mute state is
/// `private(set)` (by design — only the mixer itself may set it) and its
/// setter drives the real CoreAudio HAL, so `MixerPanelView` itself cannot be
/// instantiated with fake state here. These tests measure the same
/// production types/values (`EditableVolumePercent`, the real symbol names,
/// `sz()`, `Neon.font`) in isolation instead.
@MainActor
final class MixerPanelSizingTests: XCTestCase {
    private func fittingSize<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // MARK: - EditableVolumePercent ("0%" vs "6%" vs "100%", read vs editing)

    private func percentField(percent: Int, editing: Bool) -> some View {
        EditableVolumePercent(currentPercent: percent,
                              maximumPercent: 100,
                              width: 40,
                              editorID: "row",
                              editingID: .constant(editing ? "row" : nil),
                              accessibilityLabel: "System output volume") {
            Text("\(percent)%")
                .font(Neon.font(10.5, weight: .medium))
                .monospacedDigit()
        } onCommit: { _ in }
    }

    func testEditableVolumePercentSizeIsStableAcrossPercentAndEditingState() {
        let muted = fittingSize(percentField(percent: 0, editing: false))
        let unmutedLow = fittingSize(percentField(percent: 6, editing: false))
        let unmutedHigh = fittingSize(percentField(percent: 100, editing: false))
        let editing = fittingSize(percentField(percent: 6, editing: true))

        XCTAssertEqual(muted.height, unmutedLow.height, accuracy: 0.01,
                       "0% vs 6% must not change the field's height")
        XCTAssertEqual(muted.width, unmutedLow.width, accuracy: 0.01,
                       "0% vs 6% must not change the field's width")
        XCTAssertEqual(muted.height, unmutedHigh.height, accuracy: 0.01,
                       "1 digit vs 3 digits must not change the field's height")
        XCTAssertEqual(muted.height, editing.height, accuracy: 0.01,
                       "entering edit mode must not change the field's height")
        XCTAssertEqual(muted.width, editing.width, accuracy: 0.01,
                       "entering edit mode must not change the field's width")
    }

    // MARK: - Mute glyph pairs (the #081 fix, proven at the real seam)

    /// Mirrors `mixerGlyphFrame()` in MixerPanelView.swift (a file-private
    /// extension, so it can't be called from here directly) at the exact
    /// values that helper applies.
    private func glyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(Neon.font(10, weight: .semibold))
            .frame(width: sz(16), height: sz(16))
    }

    func testMuteGlyphPairsShareIdenticalFittingSizeInsideTheReservedFrame() {
        let pairs: [(muted: String, unmuted: String)] = [
            ("speaker.slash.fill", "speaker.wave.2.fill"),
            ("mic.slash.fill", "mic.fill"),
        ]
        for pair in pairs {
            let mutedSize = fittingSize(glyph(pair.muted))
            let unmutedSize = fittingSize(glyph(pair.unmuted))
            XCTAssertEqual(mutedSize, unmutedSize,
                           "\(pair.muted) vs \(pair.unmuted) must report identical size " +
                           "once mixerGlyphFrame() constrains both")
        }
    }

    // MARK: - Whole row (item 5: muted vs unmuted model state, one fittingSize check)

    /// A structural copy of `systemVolumeRow` in MixerPanelView.swift, driven
    /// by a local volume value instead of `AppVolumeMixer.shared` (whose
    /// output-volume/mute state is `private(set)` and whose setter drives the
    /// real CoreAudio HAL — unsafe and inaccessible from a test target). Any
    /// future change to that row's modifier chain should be mirrored here.
    private func systemVolumeRowReplica(volume: Double) -> some View {
        let isMuted = volume <= 0.001
        return HStack(spacing: sz(8)) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(Neon.font(10, weight: .semibold))
                .frame(width: sz(16), height: sz(16))
            Slider(value: .constant(volume), in: 0...1)
                .controlSize(.small)
            EditableVolumePercent(currentPercent: Int((volume * 100).rounded()),
                                  maximumPercent: 100,
                                  width: sz(40),
                                  editorID: "system-output",
                                  editingID: .constant(nil),
                                  accessibilityLabel: "System output volume") {
                Text("\(Int((volume * 100).rounded()))%")
                    .font(Neon.font(10.5, weight: .medium))
                    .monospacedDigit()
            } onCommit: { _ in }
        }
    }

    func testSystemVolumeRowSizeIsIdenticalMutedVsUnmuted() {
        let muted = fittingSize(systemVolumeRowReplica(volume: 0))
        let unmuted = fittingSize(systemVolumeRowReplica(volume: 0.06))
        XCTAssertEqual(muted.height, unmuted.height, accuracy: 0.01,
                       "the row must not grow or shrink when volume crosses the mute threshold")
    }
}
