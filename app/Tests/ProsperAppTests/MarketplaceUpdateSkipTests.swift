import Foundation
import XCTest
@testable import ProsperApp

/// R1182-q1: the update check's memory of refused market updates (a pure rule and a small value), and R1182-p: the update
/// failure log line. Rows call only the rule, the value and the line's function: no check, download, install or file.
final class MarketplaceUpdateSkipTests: XCTestCase {
    private typealias Refused = ExtensionRegistry.RefusedUpdates
    private let refusal = ExtensionError.marketVersionMismatch(id: "com.example.kit", listed: "1.2.0", got: "v1.2.0")

    /// A refused (id, listed version) pair is skipped by the next check.
    func testRefusedPairIsSkipped() {
        var r = Refused()
        XCTAssertFalse(r.skips(id: "com.example.kit", listed: "1.2.0"), "nothing refused yet")
        r.note(refusal, id: "com.example.kit", listed: "1.2.0")
        XCTAssertTrue(r.skips(id: "com.example.kit", listed: "1.2.0"))
    }

    /// Another listed version of the same id is downloaded again, and its refusal replaces the pair (one per id).
    func testAnotherListedVersionIsNotSkippedAndReplacesThePair() {
        var r = Refused()
        r.note(refusal, id: "com.example.kit", listed: "1.2.0")
        XCTAssertFalse(r.skips(id: "com.example.kit", listed: "1.3.0"), "a new listed version must be offered")
        r.note(refusal, id: "com.example.kit", listed: "1.3.0")
        XCTAssertTrue(r.skips(id: "com.example.kit", listed: "1.3.0"))
        XCTAssertFalse(r.skips(id: "com.example.kit", listed: "1.2.0"))
        XCTAssertEqual(r.listed, ["com.example.kit": "1.3.0"])
    }

    /// A pair refused for one id never skips another id at the same version.
    func testAnotherIdIsNotSkipped() {
        var r = Refused()
        r.note(refusal, id: "com.example.kit", listed: "1.2.0")
        XCTAssertFalse(r.skips(id: "com.example.other", listed: "1.2.0"))
    }

    /// No network, a timeout, a server error, a cut body, a local unpack failure: not remembered, the next check tries
    /// again. A refusal of the downloaded content is remembered.
    func testTransientFailureIsNotRemembered() {
        let transient: [Error] = [URLError(.notConnectedToInternet), URLError(.timedOut),
                                  MarketClient.MarketError.http(500, nil), MarketClient.MarketError.decode,
                                  RemoteInstaller.InstallError.downloadFailed("timed out"),
                                  RemoteInstaller.InstallError.integrityFailed("empty or undecodable artifact"),
                                  RemoteInstaller.InstallError.extractFailed("tar exited 1"),
                                  CocoaError(.fileWriteOutOfSpace)]
        var r = Refused()
        for e in transient {
            XCTAssertFalse(Refused.isRefusal(e), "\(e)")
            r.note(e, id: "com.example.kit", listed: "1.2.0")
            XCTAssertFalse(r.skips(id: "com.example.kit", listed: "1.2.0"), "\(e)")
        }
        XCTAssertTrue(r.listed.isEmpty)
        let refused: [Error] = [refusal, ExtensionError.marketIdMismatch(expected: "com.example.kit", got: "com.example.other"),
                                ExtensionLoadError.parse("bad toml"), ExtensionLoadError.unsupportedAPILevel(need: 9, max: 1),
                                RemoteInstaller.InstallError.unsafeArchive("a link"),
                                RemoteInstaller.InstallError.manifestNotFound(subdir: "")]
        for e in refused { XCTAssertTrue(Refused.isRefusal(e), "\(e)") }
    }

    /// The id and the version are outside data: compared whole (no trim, no prefix), and at most maxCount ids are kept;
    /// an id already kept is still replaced at the bound.
    func testIdAndVersionComparedWholeAndBounded() {
        var r = Refused()
        r.note(refusal, id: "com.example.kit", listed: " 1.2.0")
        XCTAssertFalse(r.skips(id: "com.example.kit", listed: "1.2.0"))
        XCTAssertFalse(r.skips(id: "com.example.kit", listed: " 1.2.0 "))
        XCTAssertFalse(r.skips(id: " com.example.kit", listed: " 1.2.0"))
        XCTAssertFalse(r.skips(id: "com.example.ki", listed: " 1.2.0"))
        XCTAssertTrue(r.skips(id: "com.example.kit", listed: " 1.2.0"))
        for i in 0..<(Refused.maxCount + 10) { r.note(refusal, id: "com.example.kit\(i)", listed: "1.0.0") }
        XCTAssertEqual(r.listed.count, Refused.maxCount)
        XCTAssertFalse(r.skips(id: "com.example.kit\(Refused.maxCount + 9)", listed: "1.0.0"), "past the bound: not kept")
        r.note(refusal, id: "com.example.kit", listed: "2.0.0")
        XCTAssertTrue(r.skips(id: "com.example.kit", listed: "2.0.0"))
        XCTAssertEqual(r.listed.count, Refused.maxCount)
    }

    /// R1182-p: the line's words are as before; its public part is the id only, never the error text or a path in it.
    func testUpdateFailureLogPublicPartIsTheIdOnly() {
        let errors: [Error] = [RemoteInstaller.InstallError.downloadFailed("/Users/example/Downloads/kit.tgz"),
                               ExtensionError.notFound("/Users/example/kit"), refusal]
        for e in errors {
            let line = ExtensionRegistry.updateFailureLog(id: "com.example.kit", error: e)
            let why = (e as? LocalizedError)?.errorDescription ?? String(describing: e)
            XCTAssertEqual(line.shown, "update check failed for com.example.kit")
            XCTAssertEqual(line.why, why)
            XCTAssertEqual(line.shown + ": " + line.why, "update check failed for com.example.kit: " + why)
            XCTAssertFalse(line.shown.contains("/Users/example"), line.shown)
        }
    }
}
