import XCTest
@testable import ProsperApp
import ProsperHelperProtocol

/// Entry 1234, second dispatch: an engage reply that comes after `callReply` gave up (`lateReplyLanded`, the late hook
/// of `setManualReply`). Fakes only: the fan connection is `FanHelperIdentityTests.FakeConn` or nil (no Mach service,
/// no helper, no SMC, no SMAppService), the identity throwaway factory returns nil, releases are injected or run on
/// the fake. Manual and the fast re-engage hold are set in the scratch defaults; the hold is off in every row.
@MainActor
final class FanLateEngageTests: XCTestCase {
    typealias FakeConn = FanHelperIdentityTests.FakeConn

    private var saved: (manual: Bool, hold: Bool) = (false, false)
    private var savedFactory: (() -> NSXPCConnection?)?
    private var released: [String] = []

    override func setUp() async throws {
        saved = (Preferences.fanManualEnabled, Preferences.fanHoldUnlock)
        Preferences.fanHoldUnlock = false
        savedFactory = FanControlHelper.makeIdentityConnection
        FanControlHelper.makeIdentityConnection = { nil }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.lateLandings = 0
        released = []
    }

    override func tearDown() async throws {
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.lateLandings = 0
        if let savedFactory { FanControlHelper.makeIdentityConnection = savedFactory }
        Preferences.fanManualEnabled = saved.manual
        Preferences.fanHoldUnlock = saved.hold
    }

    /// R1230-2: with manual on, every released late pin is followed by a recovery re-apply, so a helper whose replies
    /// always come late would cycle for good. The first two keep manual on (each hands back); the third in a row
    /// turns manual off, and its default release then tears down (one reset, the connection invalidated). A late
    /// refusal pinned nothing and does not count.
    func testThirdLatePinInARowTurnsManualOffAndTearsDown() async {
        Preferences.fanManualEnabled = true
        let fake = FakeConn()
        FanControlHelper.inject(connection: fake, engagesInFlight: 0)
        let two = expectation(description: "the first two late pins handed back")
        two.expectedFulfillmentCount = 2
        for n in 1...2 {
            FanControlHelper.lateReplyLanded(true, release: { two.fulfill() })
            XCTAssertTrue(Preferences.fanManualEnabled, "late pin \(n) turned manual off")
            XCTAssertEqual(FanControlHelper.lateLandings, n)
        }
        FanControlHelper.lateReplyLanded(false)   // a late refusal: nothing pinned, not counted, no release
        XCTAssertEqual(FanControlHelper.lateLandings, 2)
        await fulfillment(of: [two], timeout: 2)

        let closed = expectation(description: "the third late pin's release tore down")
        fake.onInvalidate = { closed.fulfill() }
        FanControlHelper.lateReplyLanded(true)   // every default: the injected count (0) and the real release
        XCTAssertFalse(Preferences.fanManualEnabled, "the third late pin in a row kept manual on")
        XCTAssertEqual(FanControlHelper.lateLandings, 0)
        await fulfillment(of: [closed], timeout: 2)
        fake.onInvalidate = nil
        XCTAssertEqual(fake.invalidations, 1)
        XCTAssertTrue(FanControlHelper.connection == nil, "the release kept the connection")
    }

    /// R1230-4: a late pin that a newer engage in flight overrides (the injected count, read by the default) is held,
    /// with manual on: no release, not counted. A later late pin with nothing in flight is released; the held one's
    /// release, had it been made first, would be recorded ahead of it.
    func testOverriddenLatePinIsHeldWhileANewerEngageIsInFlight() async {
        Preferences.fanManualEnabled = true
        FanControlHelper.inject(connection: nil, engagesInFlight: 1)
        FanControlHelper.lateEngageLanded(true, release: { self.released.append("held") })
        FanControlHelper.lateReplyLanded(true, release: { self.released.append("held late reply") })
        XCTAssertEqual(FanControlHelper.lateLandings, 0, "a held pin was counted")
        XCTAssertTrue(Preferences.fanManualEnabled)

        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        let free = expectation(description: "the pin with nothing in flight released")
        FanControlHelper.lateEngageLanded(true, release: { self.released.append("free"); free.fulfill() })
        await fulfillment(of: [free], timeout: 2)
        XCTAssertEqual(released, ["free"], "a pin held for the engage in flight was released")
    }
}
