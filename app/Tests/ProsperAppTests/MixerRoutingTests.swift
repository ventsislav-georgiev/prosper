import XCTest
@testable import ProsperApp

/// Covers the pure routing helpers behind the app volume mixer: which rows may
/// be tapped at all, how a typed percentage becomes a gain, which apps are
/// never tapped, and the sort order the row list is rendered in.
final class MixerRoutingTests: XCTestCase {

    // MARK: - Unity detection

    func testIsUnityToleranceBand() {
        XCTAssertTrue(MixerRoutingSupport.isUnity(1))
        XCTAssertTrue(MixerRoutingSupport.isUnity(1.0049))
        XCTAssertTrue(MixerRoutingSupport.isUnity(0.9951))
        XCTAssertFalse(MixerRoutingSupport.isUnity(1.006))
        XCTAssertFalse(MixerRoutingSupport.isUnity(0.994))
        XCTAssertFalse(MixerRoutingSupport.isUnity(0))
        XCTAssertFalse(MixerRoutingSupport.isUnity(2))
    }

    // MARK: - The tap gate

    private func mayBeTapped(_ volume: Double?, _ route: String?, _ defaultUID: String?) -> Bool {
        MixerRoutingSupport.rowMayBeTapped(savedVolume: volume,
                                           savedRouteUID: route,
                                           defaultOutputDeviceUID: defaultUID)
    }

    func testUntouchedRowIsNeverTapped() {
        XCTAssertFalse(mayBeTapped(nil, nil, "default"))
        XCTAssertFalse(mayBeTapped(1, nil, "default"))
        XCTAssertFalse(mayBeTapped(nil, nil, nil))
    }

    func testVolumeChangeOpensTheTap() {
        XCTAssertTrue(mayBeTapped(0.5, nil, "default"))
        XCTAssertTrue(mayBeTapped(1.8, nil, "default"))
    }

    func testNonDefaultRouteOpensTheTapAndDefaultRouteDoesNot() {
        XCTAssertTrue(mayBeTapped(1, "speakers", "default"))
        XCTAssertFalse(mayBeTapped(1, "default", "default"))
        // No known system default yet: a saved route is enough to keep the row
        // eligible rather than silently dropping the user's choice.
        XCTAssertTrue(mayBeTapped(1, "speakers", nil))
    }

    private func requiresEngine(volume: Double,
                                selected: String?,
                                target: String?,
                                defaultUID: String?,
                                hasObjects: Bool = true) -> Bool {
        MixerRoutingSupport.requiresEngine(hasAudioObjects: hasObjects,
                                           volume: volume,
                                           selectedOutputDeviceUID: selected,
                                           targetOutputDeviceUID: target,
                                           defaultOutputDeviceUID: defaultUID)
    }

    func testUntouchedRowNeedsNoEngine() {
        XCTAssertFalse(requiresEngine(volume: 1, selected: nil, target: "default", defaultUID: "default"))
    }

    func testEngineNeedsAudioObjectsAndATarget() {
        XCTAssertFalse(requiresEngine(volume: 0.4, selected: nil, target: "default",
                                      defaultUID: "default", hasObjects: false))
        XCTAssertFalse(requiresEngine(volume: 0.4, selected: nil, target: nil, defaultUID: "default"))
    }

    func testVolumeChangeRequiresEngine() {
        XCTAssertTrue(requiresEngine(volume: 0.4, selected: nil, target: "default", defaultUID: "default"))
        XCTAssertTrue(requiresEngine(volume: 1.5, selected: nil, target: "default", defaultUID: "default"))
    }

    func testNonDefaultRouteRequiresEngineAtUnity() {
        XCTAssertTrue(requiresEngine(volume: 1, selected: "speakers", target: "speakers",
                                     defaultUID: "default"))
        // Routed to what is already the system default: nothing to re-render.
        XCTAssertFalse(requiresEngine(volume: 1, selected: "default", target: "default",
                                      defaultUID: "default"))
        // Default unknown — fail closed so an explicit selection is honoured.
        XCTAssertTrue(requiresEngine(volume: 1, selected: "speakers", target: "speakers",
                                     defaultUID: nil))
    }

    // MARK: - Percentage parsing

    private func fraction(_ text: String, max: Int = 200) -> Double? {
        MixerRoutingSupport.volumeFraction(fromPercentageText: text, maximumPercent: max)
    }

    func testPercentParsingPlainAndSuffixed() throws {
        XCTAssertEqual(try XCTUnwrap(fraction("85")), 0.85, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fraction("85%")), 0.85, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fraction("  85 %  ")), 0.85, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fraction("0")), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fraction("85.5")), 0.855, accuracy: 1e-9)
    }

    func testPercentParsingAcceptsLocaleDecimalSeparator() throws {
        // On a comma-decimal locale "85,5" must parse exactly like "85.5"; on a
        // dot locale this is the same assertion with the dot.
        let separator = Locale.current.decimalSeparator ?? "."
        XCTAssertEqual(try XCTUnwrap(fraction("85\(separator)5")), 0.855, accuracy: 1e-9)
    }

    func testPercentParsingClampsToRange() throws {
        XCTAssertEqual(try XCTUnwrap(fraction("250", max: 200)), 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fraction("150", max: 100)), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fraction("-10")), 0, accuracy: 1e-9)
    }

    func testPercentParsingRejectsJunk() {
        XCTAssertNil(fraction(""))
        XCTAssertNil(fraction("   "))
        XCTAssertNil(fraction("%"))
        XCTAssertNil(fraction("loud"))
        XCTAssertNil(fraction("8 5"))
        XCTAssertNil(fraction("inf"))
        XCTAssertNil(fraction("nan"))
        XCTAssertNil(fraction("85", max: -1))
    }

    // MARK: - Apps that manage their own audio

    func testZoomBypassesTheProcessTap() {
        XCTAssertTrue(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: "us.zoom.xos",
                                                             name: "zoom.us"))
        XCTAssertTrue(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: "US.ZOOM.XOS",
                                                             name: ""))
        XCTAssertTrue(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: "us.zoom.ZoomClips",
                                                             name: ""))
        XCTAssertTrue(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: nil, name: "Zoom"))
        XCTAssertTrue(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: nil, name: "zoom.us"))
        XCTAssertTrue(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: nil,
                                                             name: " Zoom Workplace "))
    }

    func testProAudioHostsBypassTheProcessTap() {
        XCTAssertTrue(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: "com.apple.logic10",
                                                             name: "Logic Pro"))
        XCTAssertTrue(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: "com.ableton.live",
                                                             name: "Live"))
    }

    func testOrdinaryAppsDoNotBypassTheProcessTap() {
        XCTAssertFalse(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: "com.apple.Safari",
                                                              name: "Safari"))
        XCTAssertFalse(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: nil,
                                                              name: "Zoomer"))
        XCTAssertFalse(MixerRoutingSupport.bypassesProcessTap(bundleIdentifier: nil, name: ""))
    }

    // MARK: - Sort order

    func testDisplayOrderIsByNameThenIDForStability() {
        XCTAssertTrue(MixerRoutingSupport.displayOrderedBefore(name: "Music", id: "b",
                                                               otherName: "Safari", otherID: "a"))
        XCTAssertFalse(MixerRoutingSupport.displayOrderedBefore(name: "Safari", id: "a",
                                                                otherName: "Music", otherID: "b"))
        // Same display name: the id decides, and decides the same way both ways
        // round, so two refreshes cannot swap the rows.
        XCTAssertTrue(MixerRoutingSupport.displayOrderedBefore(name: "Zoom", id: "a",
                                                               otherName: "zoom", otherID: "b"))
        XCTAssertFalse(MixerRoutingSupport.displayOrderedBefore(name: "zoom", id: "b",
                                                                otherName: "Zoom", otherID: "a"))
    }

    func testDeviceOrderPutsTheDefaultFirst() {
        XCTAssertTrue(MixerRoutingSupport.deviceDisplayOrderedBefore(
            isDefault: true, name: "Zebra", uid: "z",
            otherIsDefault: false, otherName: "Apple", otherUID: "a"))
        XCTAssertFalse(MixerRoutingSupport.deviceDisplayOrderedBefore(
            isDefault: false, name: "Apple", uid: "a",
            otherIsDefault: true, otherName: "Zebra", otherUID: "z"))
        // Identical model names, neither default: the uid keeps the order fixed.
        XCTAssertTrue(MixerRoutingSupport.deviceDisplayOrderedBefore(
            isDefault: false, name: "AirPods Pro", uid: "a",
            otherIsDefault: false, otherName: "AirPods Pro", otherUID: "b"))
    }

    // MARK: - Row identity and device-UID sanitizing

    func testRowIdentityPrefersBundleIdentifier() {
        let identity = MixerRoutingSupport.rowIdentity(bundleIdentifier: "com.apple.Music",
                                                       ownerPid: 501,
                                                       displayName: "Music")
        XCTAssertEqual(identity, MixerRowIdentity(rowID: "com.apple.Music",
                                                  persistenceID: "com.apple.Music"))
    }

    func testRowIdentityFallsBackToPidRowKeyedByDisplayName() {
        let identity = MixerRoutingSupport.rowIdentity(bundleIdentifier: nil,
                                                       ownerPid: 4242,
                                                       displayName: "quake")
        XCTAssertEqual(identity, MixerRowIdentity(rowID: "process:4242", persistenceID: "quake"))

        let anonymous = MixerRoutingSupport.rowIdentity(bundleIdentifier: "   ",
                                                        ownerPid: 7,
                                                        displayName: nil)
        XCTAssertEqual(anonymous, MixerRowIdentity(rowID: "process:7", persistenceID: nil))
    }

    func testSanitizedDeviceUIDRejectsUnusableValues() {
        XCTAssertEqual(MixerRoutingSupport.sanitizedDeviceUID("  BuiltInSpeakerDevice  "),
                       "BuiltInSpeakerDevice")
        XCTAssertNil(MixerRoutingSupport.sanitizedDeviceUID(nil))
        XCTAssertNil(MixerRoutingSupport.sanitizedDeviceUID(42))
        XCTAssertNil(MixerRoutingSupport.sanitizedDeviceUID(""))
        XCTAssertNil(MixerRoutingSupport.sanitizedDeviceUID("   "))
        XCTAssertNil(MixerRoutingSupport.sanitizedDeviceUID("bad\nuid"))
        XCTAssertNil(MixerRoutingSupport.sanitizedDeviceUID(String(repeating: "x", count: 513)))
    }

    // MARK: - Preferred microphone

    /// The whole "the preferred mic came back, switch to it; it left, fall back
    /// and say so" behaviour lives in this one function — the input manager just
    /// obeys it on every device-list change.
    func testPreferredInputDeviceIsReassertedOnlyWhenPresentAndNotCurrent() {
        // No preference: whatever the system is on wins, nothing to apply.
        let none = MixerRoutingSupport.resolveInputDevice(preferredUID: nil,
                                                          availableUIDs: ["builtin", "usb"],
                                                          currentUID: "builtin")
        XCTAssertEqual(none, MixerInputRouteResolution(effectiveUID: "builtin",
                                                       selectedUnavailable: false,
                                                       shouldApplyPreferred: false))

        // Preferred mic came back and is not current: switch to it.
        let cameBack = MixerRoutingSupport.resolveInputDevice(preferredUID: "usb",
                                                              availableUIDs: ["builtin", "usb"],
                                                              currentUID: "builtin")
        XCTAssertEqual(cameBack, MixerInputRouteResolution(effectiveUID: "usb",
                                                           selectedUnavailable: false,
                                                           shouldApplyPreferred: true))

        // Already on it: no HAL write, so a chatty device list cannot loop.
        let alreadyOn = MixerRoutingSupport.resolveInputDevice(preferredUID: "usb",
                                                               availableUIDs: ["builtin", "usb"],
                                                               currentUID: "usb")
        XCTAssertEqual(alreadyOn, MixerInputRouteResolution(effectiveUID: "usb",
                                                            selectedUnavailable: false,
                                                            shouldApplyPreferred: false))

        // Unplugged: fall back to the current device and flag it for the caption.
        let unplugged = MixerRoutingSupport.resolveInputDevice(preferredUID: "usb",
                                                               availableUIDs: ["builtin"],
                                                               currentUID: "builtin")
        XCTAssertEqual(unplugged, MixerInputRouteResolution(effectiveUID: "builtin",
                                                            selectedUnavailable: true,
                                                            shouldApplyPreferred: false))

        // Unplugged with no input at all: still flagged, no device to fall back to.
        let noInputs = MixerRoutingSupport.resolveInputDevice(preferredUID: "usb",
                                                              availableUIDs: [],
                                                              currentUID: nil)
        XCTAssertEqual(noInputs, MixerInputRouteResolution(effectiveUID: nil,
                                                           selectedUnavailable: true,
                                                           shouldApplyPreferred: false))
    }

    // MARK: - Row visibility

    func testHideInactiveAppsKeepsRowsCarryingASetting() {
        func shown(playing: Bool, volume: Double, route: String?, hide: Bool) -> Bool {
            MixerRoutingSupport.shouldShowApp(isPlaying: playing,
                                              volume: volume,
                                              selectedOutputDeviceUID: route,
                                              hideInactiveApps: hide)
        }
        XCTAssertTrue(shown(playing: false, volume: 1, route: nil, hide: false))
        XCTAssertFalse(shown(playing: false, volume: 1, route: nil, hide: true))
        XCTAssertTrue(shown(playing: true, volume: 1, route: nil, hide: true))
        XCTAssertTrue(shown(playing: false, volume: 0.3, route: nil, hide: true))
        XCTAssertTrue(shown(playing: false, volume: 1, route: "speakers", hide: true))
    }

    // MARK: - Helper-to-app attribution

    func testOwningRegularAppWalksTheParentChain() {
        // helper 300 -> 200 -> 100, only 100 is a regular app.
        let parents: [pid_t: pid_t] = [300: 200, 200: 100, 100: 1]
        let pid = MixerRoutingSupport.owningRegularAppPid(responsiblePid: 300,
                                                          isRegularApp: { $0 == 100 },
                                                          parentPid: { parents[$0] ?? 0 })
        XCTAssertEqual(pid, 100)

        XCTAssertEqual(MixerRoutingSupport.owningRegularAppPid(responsiblePid: 100,
                                                               isRegularApp: { $0 == 100 },
                                                               parentPid: { parents[$0] ?? 0 }),
                       100)
        XCTAssertNil(MixerRoutingSupport.owningRegularAppPid(responsiblePid: 300,
                                                             isRegularApp: { _ in false },
                                                             parentPid: { parents[$0] ?? 0 }))
        XCTAssertNil(MixerRoutingSupport.owningRegularAppPid(responsiblePid: 0,
                                                             isRegularApp: { _ in true },
                                                             parentPid: { _ in 0 }))
    }

    // MARK: - Sound-output cycling

    private func next(_ current: String?, _ selected: [String], _ available: [String]) -> String? {
        MixerRoutingSupport.nextSelectedOutputDeviceUID(currentUID: current,
                                                        selectedUIDs: selected,
                                                        availableUIDs: Set(available))
    }

    func testCycleWalksTheSelectionInOrderAndWraps() {
        let all = ["a", "b", "c"]
        XCTAssertEqual(next("a", all, all), "b")
        XCTAssertEqual(next("b", all, all), "c")
        XCTAssertEqual(next("c", all, all), "a")
    }

    func testCycleSkipsUnavailableDuplicateAndBlankEntries() {
        // "b" unplugged, "a" listed twice, one empty entry: the walk stays on the
        // real remaining devices instead of stalling on a dead UID.
        XCTAssertEqual(next("a", ["a", "b", "a", "", "c"], ["a", "c"]), "c")
        XCTAssertEqual(next("c", ["a", "b", "a", "", "c"], ["a", "c"]), "a")
    }

    func testCycleWithNothingSelectedOrNothingToSwitchToDoesNotSwitch() {
        XCTAssertNil(next("a", [], ["a", "b"]))
        XCTAssertNil(next("a", ["a"], ["a", "b"]))
        XCTAssertNil(next("a", ["a", "b"], ["a"]))
    }

    func testCycleStartsAtTheFirstSelectionWhenTheCurrentOutputIsOutsideIt() {
        XCTAssertEqual(next(nil, ["a", "b"], ["a", "b"]), "a")
        XCTAssertEqual(next("z", ["a", "b"], ["a", "b"]), "a")
    }
}
