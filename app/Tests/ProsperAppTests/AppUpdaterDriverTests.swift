import XCTest
@testable import ProsperApp

/// #1003 (QA #107): AppUpdater's parts that decide without Sparkle or the network. The poll
/// cadence and the automatic-checks toggle are already pinned in MenuBarTests; there is no
/// version comparison of ours (Sparkle compares). No check runs: no SPUUpdater exists under
/// XCTest, and only background (not user-initiated) results are fed, which post no notification.
@MainActor
final class AppUpdaterDriverTests: XCTestCase {
    func testTheBetaChannelIsOfferedOnlyWhenOptedIn() {
        XCTAssertEqual(UpdaterChannelDelegate.channels(allowBeta: true), ["beta"])
        XCTAssertEqual(UpdaterChannelDelegate.channels(allowBeta: false), [])
    }

    private final class Seen {
        var downloading: [Bool] = []
        var progress: [Double?] = []
        var finished = 0
        var acks = 0
    }

    private func driver(_ seen: Seen) -> SilentUserDriver {
        let d = SilentUserDriver()
        d.onDownloadingChanged = { seen.downloading.append($0) }
        d.onProgressChanged = { seen.progress.append($0) }
        d.onCheckFinished = { seen.finished += 1 }
        return d
    }

    func testDownloadProgressIsTheFractionClampedAtOne() {
        let seen = Seen(), d = driver(seen)
        d.showDownloadInitiated(cancellation: {})
        d.showDownloadDidReceiveExpectedContentLength(200)
        d.showDownloadDidReceiveData(ofLength: 50)
        d.showDownloadDidReceiveData(ofLength: 100)
        d.showDownloadDidReceiveData(ofLength: 100)   // 250 of a declared 200
        XCTAssertEqual(seen.downloading, [true])
        XCTAssertEqual(seen.progress, [nil, 0, 0.25, 0.75, 1])
    }

    func testAnUnknownLengthStaysIndeterminate() {
        let seen = Seen(), d = driver(seen)
        d.showDownloadInitiated(cancellation: {})
        d.showDownloadDidReceiveExpectedContentLength(0)
        d.showDownloadDidReceiveData(ofLength: 10)
        XCTAssertEqual(seen.progress, [nil, nil, nil])
    }

    func testExtractionRestartsTheBarAndClampsItsProgress() {
        let seen = Seen(), d = driver(seen)
        d.showDownloadDidStartExtractingUpdate()
        d.showExtractionReceivedProgress(0.5)
        d.showExtractionReceivedProgress(1.5)
        d.showExtractionReceivedProgress(-0.5)
        XCTAssertEqual(seen.progress, [0, 0.5, 1, 0])
    }

    /// A background check that errors or finds nothing ends the activity and acknowledges.
    func testABackgroundErrorOrNoUpdateEndsTheCheckQuietly() {
        let seen = Seen(), d = driver(seen)
        d.userInitiated = false
        d.showUpdaterError(NSError(domain: "test", code: 1), acknowledgement: { seen.acks += 1 })
        d.showUpdateNotFoundWithError(NSError(domain: "test", code: 2), acknowledgement: { seen.acks += 1 })
        XCTAssertEqual(seen.downloading, [false, false])
        XCTAssertEqual(seen.finished, 2)
        XCTAssertEqual(seen.acks, 2)
        XCTAssertFalse(d.userInitiated)
    }

    func testInstalledOrDismissedClearsDownloading() {
        let seen = Seen(), d = driver(seen)
        d.showUpdateInstalledAndRelaunched(true, acknowledgement: { seen.acks += 1 })
        d.dismissUpdateInstallation()
        XCTAssertEqual(seen.downloading, [false, false])
        XCTAssertEqual(seen.acks, 1)
    }
}
