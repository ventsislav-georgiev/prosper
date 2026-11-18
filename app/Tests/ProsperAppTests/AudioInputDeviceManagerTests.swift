import CoreAudio
import XCTest
@testable import ProsperApp

/// Mute All and its unmute through the `MicMuteHAL` seam: fake devices only,
/// no CoreAudio call, so no real microphone changes state (#1603).
@MainActor
final class AudioInputDeviceManagerTests: XCTestCase {

    /// "a" has a mute switch; "b" has none and is muted by its level.
    private final class FakeMics {
        var plugged: [String] = ["a", "b"]
        var switchMuted: [AudioObjectID: Bool] = [:]
        var volume: [AudioObjectID: Float] = [2: 0.6]
        var unmuteCalls = 0

        private let all = [
            MixerInputDevice(id: "a", uid: "a", name: "Mic A", isDefault: false, audioObjectID: 1),
            MixerInputDevice(id: "b", uid: "b", name: "Mic B", isDefault: false, audioObjectID: 2),
        ]

        var hal: MicMuteHAL {
            MicMuteHAL(
                inputDevices: { [self] in all.filter { plugged.contains($0.uid) } },
                setMuteSwitch: { [self] muted, id in
                    guard id == 1 else { return false }
                    if !muted { unmuteCalls += 1 }
                    switchMuted[id] = muted
                    return true
                },
                inputVolume: { [self] id in volume[id] },
                setInputVolume: { [self] level, id in
                    guard id == 2 else { return false }
                    volume[id] = level
                    return true
                })
        }
    }

    override func setUp() {
        super.setUp()
        Preferences.defaults.removeObject(forKey: MixerDefaultsKey.micMutedDevices)
        Preferences.defaults.removeObject(forKey: MixerDefaultsKey.micSavedInputVolumes)
    }

    override func tearDown() {
        Preferences.defaults.removeObject(forKey: MixerDefaultsKey.micMutedDevices)
        Preferences.defaults.removeObject(forKey: MixerDefaultsKey.micSavedInputVolumes)
        super.tearDown()
    }

    /// Mute both, unplug "b", unmute: "a" is live again and "b" is owed.
    private func owedUnmute(_ mics: FakeMics) -> AudioInputDeviceManager {
        let manager = AudioInputDeviceManager(muteHAL: mics.hal)
        manager.setMicMuted(true)
        mics.plugged = ["a"]
        manager.setMicMuted(false)
        XCTAssertEqual(manager.owedMuteUIDs, ["b"])
        XCTAssertFalse(manager.micMuted)
        return manager
    }

    func testMuteAfterAnOwedUnmuteStaysMutedWhenTheOwedMicReturns() {
        let mics = FakeMics()
        let manager = owedUnmute(mics)
        manager.setMicMuted(true)
        let unmutesBefore = mics.unmuteCalls

        mics.plugged = ["a", "b"]
        manager.finishOwedRestore(listedUIDs: ["a", "b"])

        XCTAssertTrue(manager.micMuted)
        XCTAssertEqual(mics.unmuteCalls, unmutesBefore)
        XCTAssertEqual(mics.switchMuted[1], true)
        XCTAssertEqual(mics.volume[2], 0)
        XCTAssertEqual(Set(Preferences.defaults.stringArray(forKey: MixerDefaultsKey.micMutedDevices) ?? []),
                       ["a", "b"])
    }

    func testMuteClearsTheOwedMicsItTookIntoItsRecord() {
        let mics = FakeMics()
        let manager = owedUnmute(mics)
        manager.setMicMuted(true)
        XCTAssertTrue(manager.micMuted)
        XCTAssertEqual(manager.owedMuteUIDs, [])
        let saved = Preferences.defaults.dictionary(forKey: MixerDefaultsKey.micSavedInputVolumes) as? [String: Double]
        XCTAssertEqual(saved?["b"] ?? 0, 0.6, accuracy: 0.001)
    }

    func testOwedMicReturningWhileUnmutedIsRestored() {
        let mics = FakeMics()
        let manager = owedUnmute(mics)

        mics.plugged = ["a", "b"]
        manager.finishOwedRestore(listedUIDs: ["a", "b"])

        XCTAssertFalse(manager.micMuted)
        XCTAssertEqual(mics.volume[2] ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(manager.owedMuteUIDs, [])
        XCTAssertTrue(Preferences.defaults.object(forKey: MixerDefaultsKey.micMutedDevices) == nil)
    }

    func testOwedMicStillAbsentLeavesTheRecord() {
        let mics = FakeMics()
        let manager = owedUnmute(mics)
        manager.finishOwedRestore(listedUIDs: ["a"])
        XCTAssertEqual(manager.owedMuteUIDs, ["b"])
        XCTAssertEqual(Preferences.defaults.stringArray(forKey: MixerDefaultsKey.micMutedDevices) ?? [], ["b"])
    }
}
