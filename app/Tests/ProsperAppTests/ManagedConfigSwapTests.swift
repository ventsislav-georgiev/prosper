import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// #1243 (N1231-a, N947-d): the commit's time-of-check windows. Every swap is made through a seam (the commit's
/// beforeRename hook, or MCWriter's interleave), never by a race. Every file, link and FIFO is inside the row's
/// tempDir(), and every link points inside it. The row opens its FIFO's two ends with O_NONBLOCK first: the reader,
/// which never blocks, then the writer, which never blocks either while a reader exists. So no open of the FIFO
/// can block.
final class ManagedConfigSwapTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Int32] = []
        func add(_ v: Int32) { lock.withLock { _values.append(v) } }
        var values: [Int32] { lock.withLock { _values } }
    }

    private static let original = Array("# mine\n".utf8)

    /// lstat only: never opens what is there (a FIFO left by a failing row is not read).
    private func isRegular(_ url: URL) -> Bool { var s = stat(); return lstat(url.path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFREG }

    private func temps(in dir: URL, for url: URL) -> [String] {
        (ManagedConfig.entries(of: dir) ?? []).filter { $0.hasPrefix("." + url.lastPathComponent + ".prosper-") }
    }

    // MARK: N1231-a, the temp

    /// After the commit opened the temp, the temp's name is swapped for a hard link to a decoy, or for a link to
    /// it (the decoy is in the row's tempDir). The name is no longer the file held open, so nothing is renamed: the
    /// user's file keeps its bytes, the decoy keeps its bytes, and no temp or backup is left. The hook also reads the
    /// handle's flags: the temp was opened O_NONBLOCK.
    func testATempSwappedAfterItsOpenIsNeverRenamedIn() async throws {
        for hard in [true, false] {
            let env = makeMCEnv(label: "swap-\(hard ? "hardlink" : "symlink")")
            let url = env.claudeMD, prefix = "." + env.claudeMD.lastPathComponent + ".prosper-"
            try Data(Self.original).write(to: url)
            let decoy = env.root.appendingPathComponent("decoy.md")
            try env.write("# decoy\n", decoy)
            let flags = Box(), swapped = Box()
            let mc = ManagedConfig(roots: env.mc.roots, consent: env.consent, writer: ManagedConfigPOSIXWriter(), beforeRename: { temp, handle in
                guard temp.lastPathComponent.hasPrefix(prefix) else { return }
                flags.add(fcntl(handle, F_GETFL))
                swapped.add(unlink(temp.path))
                swapped.add(hard ? link(decoy.path, temp.path) : symlink(decoy.path, temp.path))
            })
            let r = await mc.apply([MCPieces.block()], owner: env.owner)
            XCTAssertEqual(swapped.values, [0, 0], "\(hard): the premise, the swap was made")
            XCTAssertEqual(r.status, .failed, "\(hard): \(r.message)")
            XCTAssertTrue(r.message.contains("check temp failed: the temp file was replaced"), r.message)
            XCTAssertTrue(isRegular(url), "\(hard): still a regular file")
            XCTAssertEqual(env.bytes(url), Self.original, "\(hard)")
            XCTAssertTrue(isRegular(decoy), "\(hard)")
            XCTAssertEqual(env.read(decoy), "# decoy\n", "\(hard)")
            XCTAssertEqual(temps(in: env.claude, for: url), [], "\(hard): the swapped name goes")
            XCTAssertEqual(env.files(under: env.backups).filter { $0.hasSuffix(".orig") }, [], "\(hard)")
            XCTAssertEqual(flags.values.count, 1, "\(hard)")
            XCTAssertTrue(flags.values.allSatisfy { $0 & O_NONBLOCK != 0 }, "\(hard): the temp's handle is non-blocking")
        }
    }

    /// A FIFO is put in the temp's place before the commit opens it. The open does not wait, and the handle is
    /// refused as not a regular file, so the user's file keeps its bytes and the FIFO goes. The row holds both
    /// ends (see the class note).
    func testATempThatIsAFIFOIsRefusedAsNotARegularFile() async throws {
        let env = makeMCEnv()
        let url = env.claudeMD, dir = env.claude, prefix = "." + env.claudeMD.lastPathComponent + ".prosper-"
        try Data(Self.original).write(to: url)
        let fds = Box()
        defer { for fd in fds.values where fd >= 0 { _ = close(fd) } }
        env.writer.interleave { t, _ in
            guard t.lastPathComponent == url.lastPathComponent else { return }
            for name in ManagedConfig.entries(of: dir) ?? [] where name.hasPrefix(prefix) {
                let temp = dir.appendingPathComponent(name).path
                _ = unlink(temp)
                guard mkfifo(temp, 0o600) == 0 else { continue }
                let reader = open(temp, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                fds.add(reader)
                if reader >= 0 { fds.add(open(temp, O_WRONLY | O_NONBLOCK | O_CLOEXEC)) }
            }
        }
        let r = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(fds.values.count, 2)
        XCTAssertTrue(fds.values.allSatisfy { $0 >= 0 }, "the premise: both ends held, so no open could block")
        XCTAssertEqual(r.status, .failed, r.message)
        XCTAssertTrue(r.message.contains("open temp failed: not a regular file"), r.message)
        guard isRegular(url) else { return XCTFail("the user's file was replaced") }
        XCTAssertEqual(env.bytes(url), Self.original)
        XCTAssertEqual(temps(in: dir, for: url), [], "the FIFO goes")
        XCTAssertEqual(env.files(under: env.backups).filter { $0.hasSuffix(".orig") }, [])
    }

    // MARK: N947-d, the directory

    /// After the commit pinned the directory, the directory of the user's file is moved away and a link to a decoy
    /// directory is put in its place. The decoy is in the row's tempDir and holds a file with the same bytes. The
    /// rename lands in the pinned directory, never through the link: the decoy keeps its bytes and gets no temp.
    func testAParentSwappedForALinkAfterThePinIsNotFollowed() async throws {
        let env = makeMCEnv()
        let url = env.claudeMD, dir = env.claude, name = env.claudeMD.lastPathComponent
        try Data(Self.original).write(to: url)
        let moved = env.root.appendingPathComponent("moved home", isDirectory: true)
        let decoyDir = env.root.appendingPathComponent("decoy home", isDirectory: true)
        try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
        let decoy = decoyDir.appendingPathComponent(name)
        try Data(Self.original).write(to: decoy)
        let swapped = Box()
        let mc = ManagedConfig(roots: env.mc.roots, consent: env.consent, writer: ManagedConfigPOSIXWriter(), beforeRename: { temp, _ in
            guard temp.lastPathComponent.hasPrefix("." + name + ".prosper-") else { return }
            swapped.add(rename(dir.path, moved.path))
            swapped.add(symlink(decoyDir.path, dir.path))
        })
        let r = await mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(swapped.values, [0, 0], "the premise: the parent is a link to the decoy at the rename")
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(env.read(moved.appendingPathComponent(name))?.contains("Follow the kit rules.") ?? false, "renamed in the pinned directory")
        XCTAssertTrue(isRegular(decoy))
        XCTAssertEqual(env.bytes(decoy), Self.original, "nothing written through the link")
        XCTAssertEqual(ManagedConfig.entries(of: decoyDir), [name], "no temp through the link")
        XCTAssertEqual(temps(in: moved, for: url), [])
    }

    /// Before the pin, a link is swapped in at the claude root itself (the pinned name, which O_NOFOLLOW refuses) or
    /// at its parent (which the open follows, but the re-resolve sees the target resolve elsewhere). The decoy dir
    /// holds a file with the user's bytes, so the C9 re-read cannot tell. Nothing is written through the link, and
    /// both files keep their bytes. The swap runs in the backup's temp write (MCWriter): after the commit's first
    /// shape check and before the pin. The replan's second sheet is declined.
    func testALinkSwappedInAboveTheTargetBeforeThePinFailsClosed() async throws {
        for atRoot in [true, false] {
            let env = makeMCEnv(label: "pin-\(atRoot ? "root" : "parent")")
            let home = env.root.appendingPathComponent("home", isDirectory: true)
            let claude = home.appendingPathComponent(".claude", isDirectory: true)
            let other = env.root.appendingPathComponent("other", isDirectory: true)
            let decoyClaude = other.appendingPathComponent(".claude", isDirectory: true)
            for d in [claude, decoyClaude] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
            let url = claude.appendingPathComponent("CLAUDE.md"), decoy = decoyClaude.appendingPathComponent("CLAUDE.md")
            try Data(Self.original).write(to: url)
            try Data(Self.original).write(to: decoy)
            let (from, to) = atRoot ? (claude, decoyClaude) : (home, other)
            let moved = env.root.appendingPathComponent("moved", isDirectory: true)
            let backups = env.backups.path, swapped = Box()
            env.writer.interleave { t, _ in
                guard t.path.hasPrefix(backups), swapped.values.isEmpty else { return }
                swapped.add(rename(from.path, moved.path))
                swapped.add(symlink(to.path, from.path))
            }
            let consent = MCRecordingConsent(false, script: [true])
            let roots = ManagedConfigRoots(claude: claude, configHome: env.config, stateDir: env.state)
            let mc = ManagedConfig(roots: roots, consent: consent, writer: env.writer)
            let r = await mc.apply([MCPieces.block()], owner: env.owner)
            XCTAssertEqual(swapped.values, [0, 0], "\(atRoot): the premise, swapped before the pin")
            XCTAssertNotEqual(r.status, .done, "\(atRoot): \(r.message)")
            if atRoot { XCTAssertTrue(r.message.contains("open directory failed"), r.message) }
            XCTAssertTrue(isRegular(decoy), "\(atRoot)")
            XCTAssertEqual(env.bytes(decoy), Self.original, "\(atRoot): nothing written through the link")
            let mine = atRoot ? moved.appendingPathComponent("CLAUDE.md") : moved.appendingPathComponent(".claude/CLAUDE.md")
            XCTAssertEqual(env.bytes(mine), Self.original, "\(atRoot)")
            XCTAssertEqual(temps(in: decoyClaude, for: url), [], "\(atRoot)")
        }
    }
}
