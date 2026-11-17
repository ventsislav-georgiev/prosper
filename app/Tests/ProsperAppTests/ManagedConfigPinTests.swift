import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// #1431: the commit's pinned folder. A mismatch is made through the pinnedDirPath seam, never by a race or a second
/// process. Every file and folder is inside the row's tempDir(); a mode changed here is put back in a defer.
final class ManagedConfigPinTests: XCTestCase {
    private final class Paths: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [String?] = []
        func add(_ v: String?) { lock.withLock { _values.append(v) } }
        var values: [String?] { lock.withLock { _values } }
    }

    private static let original = Array("# mine\n".utf8)
    private static let rulesEnd = "<!-- <<< prosper:kit-a:rules <<< -->"

    // MARK: R1243-i1, F_GETPATH

    /// The held folder names another path than the folder resolves to now: refused, the user's file keeps its bytes,
    /// and no temp or backup is left.
    func testAHeldFolderWhosePathDiffersIsRefused() async throws {
        let env = makeMCEnv()
        let url = env.claudeMD
        try Data(Self.original).write(to: url)
        let asked = Paths()
        let mc = ManagedConfig(roots: env.mc.roots, consent: env.consent, writer: ManagedConfigPOSIXWriter(), pinnedDirPath: { _ in
            asked.add("/Users/example/elsewhere")
            return "/Users/example/elsewhere"
        })
        let r = await mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(asked.values.count, 1, "the premise: the seam was asked once")
        XCTAssertEqual(r.status, .failed, r.message)
        XCTAssertTrue(r.message.contains("check directory failed: the directory is not the one held"), r.message)
        XCTAssertEqual(env.bytes(url), Self.original)
        XCTAssertEqual((ManagedConfig.entries(of: env.claude) ?? []).filter { $0.contains(".prosper-") }, [], "no temp")
        XCTAssertEqual(env.files(under: env.backups).filter { $0.hasSuffix(".orig") }, [], "no backup")
        XCTAssertTrue(mc.status(owner: env.owner).isEmpty, "nothing recorded")
    }

    /// The real F_GETPATH of the held folder spells /private/var while the resolved path spells /var (the tempDir is
    /// under /var, a link to /private/var); the commit normalises both the same way, so the normal commit lands.
    func testAHeldFolderWithItsOwnPathCommits() async throws {
        let env = makeMCEnv()
        try Data(Self.original).write(to: env.claudeMD)
        let seen = Paths()
        let mc = ManagedConfig(roots: env.mc.roots, consent: env.consent, writer: ManagedConfigPOSIXWriter(), pinnedDirPath: { fd in
            let p = ManagedConfig.path(of: fd)
            seen.add(p)
            return p
        })
        let r = await mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(seen.values.count, 1)
        let held = try XCTUnwrap(seen.values.last ?? nil)
        XCTAssertTrue(held.hasPrefix("/private/"), "the premise: the held path spells the /private the resolved one drops: \(held)")
        XCTAssertEqual(ManagedConfig.dropPrivatePrefix(held), env.claude.resolvingSymlinksInPath().path)
        XCTAssertTrue(env.read(env.claudeMD)?.contains("Follow the kit rules.") ?? false)
    }

    // MARK: R1431-s1, spelling; R1431-i2, no link followed

    private func isCaseSensitive(_ dir: URL) -> Bool { pathconf(dir.path, _PC_CASE_SENSITIVE) == 1 }

    /// A commit in a folder made as `made` while the roots spell it `spelled`: the commit lands on a case-insensitive volume.
    private func commitSpelled(made: String, spelled: String, label: String) async throws {
        let root = tempDir(label)
        if isCaseSensitive(root) { throw XCTSkip("the tempDir volume is case-sensitive") }
        let dir = root.appendingPathComponent(made, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = root.appendingPathComponent("extensions/kit-a", isDirectory: true)
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        let claude = root.appendingPathComponent(spelled, isDirectory: true)
        let md = dir.appendingPathComponent("CLAUDE.md")
        try Data(Self.original).write(to: md)
        let roots = ManagedConfigRoots(claude: claude, configHome: root.appendingPathComponent("config", isDirectory: true),
                                       stateDir: root.appendingPathComponent("state", isDirectory: true))
        let mc = ManagedConfig(roots: roots, consent: MCRecordingConsent(true), writer: ManagedConfigPOSIXWriter())
        let r = await mc.apply([MCPieces.block()], owner: ManagedConfigOwner(id: "kit-a", version: "1.0.0", kitSlug: "kit-a", extensionDir: ext))
        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue((try? String(contentsOf: md, encoding: .utf8))?.contains("Follow the kit rules.") ?? false, "the file is rewritten")
    }

    func testARootSpelledInAnotherCaseCommits() async throws {
        try await commitSpelled(made: "cfg", spelled: "CFG", label: "case")
    }

    func testARootSpelledInAnotherNormalizationCommits() async throws {
        try await commitSpelled(made: "caf\u{E9}", spelled: "cafe\u{301}", label: "nfd")
    }

    /// The seam hands back a link to the real folder: the held path is mapped, never resolved, so it is refused.
    func testAHeldPathThatIsALinkIsRefused() async throws {
        let env = makeMCEnv()
        try Data(Self.original).write(to: env.claudeMD)
        let link = env.root.appendingPathComponent("link-to-claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: env.claude)
        let mc = ManagedConfig(roots: env.mc.roots, consent: env.consent, writer: ManagedConfigPOSIXWriter(), pinnedDirPath: { _ in link.path })
        let r = await mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(r.status, .failed, r.message)
        XCTAssertTrue(r.message.contains("the directory is not the one held"), r.message)
        XCTAssertEqual(env.bytes(env.claudeMD), Self.original)
    }

    // MARK: R1243-i3, O_SEARCH

    /// A folder with search but no read permission (0300) still takes the commit: the pin needs search only.
    func testAFolderWithSearchButNoReadCommits() async throws {
        let env = makeMCEnv()
        let dir = env.claude
        try Data(Self.original).write(to: env.claudeMD)
        var st = stat()
        XCTAssertEqual(lstat(dir.path, &st), 0)
        let before = st.st_mode & 0o7777
        guard dir.path.hasPrefix(env.root.path + "/") else { return XCTFail("the premise: the folder is the row's own") }
        XCTAssertEqual(chmod(dir.path, 0o300), 0)
        defer { _ = chmod(dir.path, before) }
        let listing = opendir(dir.path)
        if let listing { closedir(listing) }
        XCTAssertTrue(listing == nil, "the premise: the folder cannot be listed")

        let r = await env.mc.apply([MCPieces.block()], owner: env.owner)

        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertTrue(env.read(env.claudeMD)?.contains("Follow the kit rules.") ?? false)
        XCTAssertEqual(lstat(dir.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o7777, 0o300, "the commit leaves the folder's mode alone")
    }

    // MARK: R1244-i1, one broken and one good block

    /// One CLAUDE.md holds two blocks of the same owner: "rules" with its end marker deleted by hand, and a well-formed
    /// "notes". The uninstall splices "notes" out exactly, leaves the broken "rules" text byte for byte, and drops both
    /// records.
    func testUninstallWithOneBrokenAndOneGoodBlockInOneFile() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let rules = MCPieces.block(), notes = MCPieces.block("notes", text: "Keep the notes.")
        let first = await env.mc.apply([rules], owner: env.owner)
        XCTAssertEqual(first.status, .done, first.message)
        let rulesOnly = try XCTUnwrap(env.read(env.claudeMD))
        let both = await env.mc.apply([rules, notes], owner: env.owner)
        XCTAssertEqual(both.status, .done, both.message)
        let text = try XCTUnwrap(env.read(env.claudeMD))
        XCTAssertTrue(text.contains("Keep the notes."), "the premise: the good block is in the file")
        XCTAssertEqual(text.components(separatedBy: Self.rulesEnd).count, 2, "the premise: one rules end marker")
        try env.write(text.replacingOccurrences(of: Self.rulesEnd, with: ""), env.claudeMD)
        XCTAssertTrue(env.mc.status(owner: env.owner).map(\.state).contains(.corrupt), "the premise: rules is broken")

        let r = await env.mc.uninstall(owner: env.owner)

        XCTAssertEqual(r.status, .done, r.message)
        XCTAssertEqual(r.pieces.sorted { $0.id < $1.id }, [.init(id: "notes", action: .remove), .init(id: "rules", action: .forget)])
        let brokenRulesOnly = Array(rulesOnly.replacingOccurrences(of: Self.rulesEnd, with: "").utf8)
        XCTAssertEqual(env.bytes(env.claudeMD), brokenRulesOnly, "the good block's bytes are gone, the broken text stays")
        XCTAssertTrue(env.mc.status(owner: env.owner).isEmpty, "both records go")
        XCTAssertFalse(env.mc.ownerIDs().contains(env.owner.id))
    }
}
