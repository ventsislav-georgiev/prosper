import Foundation
import XCTest
@testable import ProsperApp

/// #1182 R1182-h: RemoteInstaller.runDraining (the one run behind runTarData, runTarCapture and runTar) drains stderr
/// while it reads stdout and keeps only stderr's first 4096 bytes. The drain rows run /bin/sh with a literal command
/// whose builtins (printf, [, exit) write bytes to its own stdout and stderr: no other program, no file, no network
/// (the commands of DchCaptureDrainTests). The helper rows run /usr/bin/tar on an archive each row builds in its tempDir().
/// R1182-f: what a person reads when tar fails is one fixed sentence; readdir names go through shownName.
/// Where things run: the call on one global-queue thread; the wait and the asserts on the test's thread. The 20 s is
/// a ceiling only: a green call returns at once. On the ceiling the row FAILS and signals nothing: the child is left
/// alone (when xctest ends its pipes close and the shell ends on its own).
final class RemoteInstallerDrainTests: XCTestCase {
    private typealias Run = (out: Data, err: String, status: Int32)

    private final class Call: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<Run, Error>?
    }

    private static let zeros4096 = String(repeating: "0", count: 4096)

    /// nil (and a failure) when the call did not return within the ceiling.
    private func run(_ script: String, path: String = "/bin/sh", captureOut: Bool = true) -> Result<Run, Error>? {
        let call = Call(), done = XCTestExpectation(description: "runDraining returned")
        DispatchQueue.global().async {
            let r = Result { try RemoteInstaller.runDraining(["-c", script], path: path, captureOut: captureOut) }
            call.lock.withLock { call.result = r }
            done.fulfill()
        }
        guard XCTWaiter().wait(for: [done], timeout: 20) == .completed else {
            XCTFail("runDraining did not return within the 20 s ceiling (nothing is signalled)")
            return nil
        }
        return call.lock.withLock { call.result }
    }

    private func ran(_ script: String, captureOut: Bool = true) throws -> Run {
        try XCTUnwrap(run(script, captureOut: captureOut)).get()
    }

    // MARK: - R1182-h, the drain

    /// The hang: 200000 bytes to stderr while stdout is still open, then "done", exit 3.
    func testAFloodOfStderrBeforeStdoutStillReturns() throws {
        let r = try ran("printf '%0200000d' 0 >&2; printf 'done\\n'; exit 3")
        XCTAssertEqual(String(decoding: r.out, as: UTF8.self), "done\n")
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.err, Self.zeros4096)
    }

    /// stdout large, stderr one line: both whole.
    func testLargeStdoutAndSmallStderrAreBothWhole() throws {
        let r = try ran("printf '%0300000d' 0; printf 'one line\\n' >&2")
        XCTAssertEqual(r.out, Data(repeating: 0x30, count: 300_000))
        XCTAssertEqual(r.err, "one line\n")
        XCTAssertEqual(r.status, 0)
    }

    /// Both large and interleaved (10 rounds of 30000 to stdout and 20000 to stderr): out whole, err the first 4096.
    func testBothLargeInterleavedReturnsWithStderrCut() throws {
        let r = try ran("i=0; while [ $i -lt 10 ]; do printf '%030000d' 0; printf '%020000d' 0 >&2; i=$((i+1)); done")
        XCTAssertEqual(r.out, Data(repeating: 0x30, count: 300_000))
        XCTAssertEqual(r.err, Self.zeros4096)
        XCTAssertEqual(r.status, 0)
    }

    /// Exactly 4096 bytes is kept whole; 4097 is cut to 4096.
    func testTheCapIs4096Bytes() throws {
        XCTAssertEqual(try ran("printf '%04096d' 0 >&2").err, Self.zeros4096)
        XCTAssertEqual(try ran("printf '%04097d' 0 >&2").err, Self.zeros4096)
    }

    /// A cut inside a two-byte character (U+00E9 as \303\251): the 4095 digits stay, the lone first byte becomes U+FFFD.
    func testACutInsideAUTF8SequenceKeepsTheValidText() throws {
        XCTAssertEqual(try ran("printf '%04095d\\303\\251' 0 >&2").err, String(repeating: "0", count: 4095) + "\u{FFFD}")
    }

    /// runTar's shape: stdout left where it was, a flood on stderr still returns; out is empty.
    func testStdoutNotCapturedWithAFloodOnStderrReturns() throws {
        let r = try ran("printf '%0200000d' 0 >&2; exit 2", captureOut: false)
        XCTAssertEqual(r.out, Data())
        XCTAssertEqual(r.err, Self.zeros4096)
        XCTAssertEqual(r.status, 2)
    }

    /// A path that does not exist throws extractFailed (Foundation's launch error), as the three helpers did.
    func testAMissingPathThrowsExtractFailedAsBefore() throws {
        let result = try XCTUnwrap(run("exit 0", path: "/Users/example/no-such-program"))
        XCTAssertThrowsError(try result.get()) {
            guard case .extractFailed? = $0 as? RemoteInstaller.InstallError else { return XCTFail("got \($0)") }
        }
    }

    // MARK: - R1182-h, the three helpers through their real callers (behaviour as before)

    private func write(_ root: URL, _ rel: String) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    /// The fixture's own tar (not the code under test); its stdout, stderr dropped.
    private func tar(_ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, args.joined(separator: " "))
        return String(decoding: data, as: UTF8.self)
    }

    /// A tiny extension in tmp/ext packed as tmp/kit.tgz with "./" members.
    private func tinyArchive(_ tmp: URL) throws -> URL {
        let ext = tmp.appendingPathComponent("ext")
        for rel in ["extension.toml", "init.lua", "lib/util.lua"] { try write(ext, rel) }
        let tgz = tmp.appendingPathComponent("kit.tgz")
        _ = try tar(["-czf", tgz.path, "-C", ext.path, "."])
        return tgz
    }

    /// runTarData: the publish blob is the whole archive, its members listed as before.
    func testPackageForPublishBlobIsWhole() throws {
        let tmp = tempDir()
        let ext = tmp.appendingPathComponent("ext")
        for rel in ["extension.toml", "init.lua", "lib/util.lua"] { try write(ext, rel) }
        let tgz = tmp.appendingPathComponent("out.tgz")
        try XCTUnwrap(Data(base64Encoded: try RemoteInstaller.packageForPublish(ext))).write(to: tgz)
        let members = try tar(["-tzf", tgz.path]).split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(Set(members), ["./extension.toml", "./init.lua", "./lib/util.lua"])
    }

    /// runTarCapture and runTar: a good archive lists and unpacks as before.
    func testUnpackOfAGoodArchiveIsAsBefore() throws {
        let tmp = tempDir()
        let tgz = try tinyArchive(tmp)
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertEqual(try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: false).path, out.path)
        for rel in ["extension.toml", "init.lua", "lib/util.lua"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent(rel).path), rel)
        }
    }

    /// runTarCapture: bytes that are no archive fail the listing with extractFailed (the case as before), now the
    /// fixed sentence; nothing is unpacked.
    func testListingOfANonArchiveThrowsExtractFailed() throws {
        let tmp = tempDir()
        let tgz = tmp.appendingPathComponent("bad.tgz")
        try Data("not an archive\n".utf8).write(to: tgz)
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try RemoteInstaller.unpack(tgz, into: out, stripTopLevel: false)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .extractFailed(RemoteInstaller.tarFailedText))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    /// runTar: the listing passes, the extract fails (its folder is missing): extractFailed, the fixed sentence.
    func testExtractIntoAMissingFolderThrowsExtractFailed() throws {
        let tmp = tempDir()
        let tgz = try tinyArchive(tmp)
        let missing = tmp.appendingPathComponent("missing")
        XCTAssertThrowsError(try RemoteInstaller.unpack(tgz, into: missing, stripTopLevel: false)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .extractFailed(RemoteInstaller.tarFailedText))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: - R1182-f, what a person reads

    /// A made-up tar error line naming an entry with a direction override (\342\200\256) and a zero-width space
    /// (\342\200\213), on two lines: the person reads the fixed sentence and nothing of tar's text.
    func testTarFailureShowsOnlyTheFixedSentence() throws {
        let r = try ran("printf 'tar: kit/a\\342\\200\\256b\\342\\200\\213.lua: Cannot open\\ntar: second line\\n' >&2; exit 1")
        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("Cannot open"), "the made-up line reached stderr")
        let error = RemoteInstaller.tarFailed(["-xzf"], r)
        XCTAssertEqual(error, .extractFailed(RemoteInstaller.tarFailedText))
        let shown = try XCTUnwrap(error.errorDescription)
        XCTAssertEqual(shown, "Could not unpack the download: tar could not process the archive; its message is in the log")
        for part in ["kit/", "Cannot open", "second line", "\u{202E}", "\u{200B}"] {
            XCTAssertFalse(shown.contains(part), part)
        }
    }

    /// "cannot stat <name>": a listed name lstat cannot find (the names seam) is shown cleaned.
    func testCannotStatShowsTheCleanedName() throws {
        let dir = tempDir()
        XCTAssertThrowsError(try RemoteInstaller.entries(dir, names: { _ in [Array("kit\u{202E}lua\u{200B}.txt".utf8)] })) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .extractFailed("cannot stat kitlua.txt"))
        }
    }

    /// "cannot read <folder>": a folder that does not exist is named cleaned.
    func testCannotReadShowsTheCleanedFolderName() throws {
        let gone = tempDir().appendingPathComponent("gone\u{202E}dir\u{200B}", isDirectory: true)
        XCTAssertThrowsError(try RemoteInstaller.readNames(gone)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .extractFailed("cannot read gonedir"))
        }
    }
}
