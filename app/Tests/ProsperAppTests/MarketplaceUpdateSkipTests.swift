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

    /// R1182-q4: a failed open or read of the unpacked manifest (a missing file, a folder where the file should be) is
    /// local and can pass next time: not remembered, the pair is tried again. Bytes that are not UTF-8 are the package's
    /// own: remembered. Both errors come from the real reader on files inside the row's own tempDir().
    func testManifestIOFailureIsNotRememberedButBadUTF8Is() throws {
        let dir = tempDir()
        let asFolder = dir.appendingPathComponent("folder.toml")
        try FileManager.default.createDirectory(at: asFolder, withIntermediateDirectories: true)
        let bad = dir.appendingPathComponent("bad.toml")
        try Data([0x61, 0xFF, 0x0A]).write(to: bad)
        var io: [Error] = []
        for url in [dir.appendingPathComponent("missing.toml"), asFolder] {
            do { _ = try ExtensionLoader.readManifest(url); XCTFail("\(url.lastPathComponent) must not read") } catch { io.append(error) }
        }
        XCTAssertEqual(io.count, 2)
        var r = Refused()
        for e in io {
            guard case ExtensionLoadError.unreadable = e else { XCTFail("\(e)"); continue }
            XCTAssertFalse(Refused.isRefusal(e), "\(e)")
            r.note(e, id: "com.example.kit", listed: "1.2.0")
            XCTAssertFalse(r.skips(id: "com.example.kit", listed: "1.2.0"), "tried again at the next check")
        }
        XCTAssertTrue(r.listed.isEmpty)
        do { _ = try ExtensionLoader.readManifest(bad); XCTFail("bad bytes must not read") } catch {
            XCTAssertEqual(error as? ExtensionLoadError, .invalidUTF8("extension.toml is not valid UTF-8"))
            XCTAssertTrue(Refused.isRefusal(error))
            r.note(error, id: "com.example.kit", listed: "1.2.0")
        }
        XCTAssertTrue(r.skips(id: "com.example.kit", listed: "1.2.0"))
    }

    /// R1182-q5: the status sentence. Nothing skipped or failed: as before. A skipped or failed candidate: one fixed
    /// sentence with the count (plural pinned), never "up to date"; with an install in the same pass that sentence wins.
    func testStatusSaysWhatWasNotInstalled() {
        typealias Tally = ExtensionRegistry.UpdateTally
        var none = Tally()
        XCTAssertEqual(none.status(force: true), "All extensions up to date.")
        XCTAssertNil(none.status(force: false), "an automatic check that did nothing keeps the status")
        none.installedOne()
        XCTAssertEqual(none.status(force: false), "Updated 1 extension.")
        none.installedOne()
        XCTAssertEqual(none.status(force: true), "Updated 2 extensions.")

        var forcedOverRefused = Tally()
        var refused = Refused()
        refused.note(refusal, id: "com.example.kit", listed: "1.2.0")
        if refused.skips(id: "com.example.kit", listed: "1.2.0") { forcedOverRefused.skippedOne() }
        XCTAssertEqual(forcedOverRefused.status(force: true), "1 update could not be installed.")
        forcedOverRefused.failedOne()
        XCTAssertEqual(forcedOverRefused.status(force: true), "2 updates could not be installed.")

        var failedOnly = Tally()
        failedOnly.failedOne()
        XCTAssertEqual(failedOnly.status(force: true), "1 update could not be installed.", "a failed candidate counts like a skipped one")
        var mixed = Tally()
        mixed.installedOne()
        mixed.skippedOne()
        XCTAssertEqual(mixed.status(force: true), "1 update could not be installed.", "the count sentence wins over Updated N")
        XCTAssertEqual(mixed.status(force: false), "1 update could not be installed.")
    }
}
