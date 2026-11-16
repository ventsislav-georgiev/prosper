import XCTest
@testable import ProsperApp

/// #1075 (OQ-92): the consent sheet warns on every piece that runs a command and the Apply button names them.
/// Hand-built change sets (fake ids, /Users/example paths: nothing is read or written) and two rows that plan real
/// pieces in their own tempDir() through the recording consent (never a real sheet, window or Claude config file).
@MainActor
final class ManagedConfigCommandWarningTests: XCTestCase {
    private static let hookNote = "Claude Code will run `kit-run pre` on `PreToolUse` (`Bash`) in every session."
    private static let hookNote2 = "Claude Code will run `kit-run post` on `Stop` (every match) in every session."
    private static let statusNote = "Claude Code will run `kit-status` as the status line in every session."
    private static let liveNote = "Applies to open Claude Code sessions immediately."

    private static func file(_ notes: [String], target: String = "claude:settings.json") -> ManagedConfigChangeSet.File {
        .init(target: target, path: "/Users/example/.claude/settings.json",
              backupDirectory: "/Users/example/.config/prosper/managed-config/backups/claude",
              lines: [.init(sign: .added, text: "x")], notes: notes)
    }

    private static func set(_ files: [ManagedConfigChangeSet.File], _ action: ManagedConfigChangeSet.Action = .apply) -> ManagedConfigChangeSet {
        ManagedConfigChangeSet(action: action, owner: "kit-a", files: files, pieces: [])
    }

    private func model(_ set: ManagedConfigChangeSet) -> ManagedConfigConsentModel { ManagedConfigConsentModel(changes: set) { _ in } }

    func testNoCommandKeepsTodaysTitleAndShowsNoLine() {
        let s = Self.set([Self.file([Self.liveNote, "Read by new Claude Code sessions and after /compact."])])
        XCTAssertEqual(ManagedConfigCommandWarning.title(for: s), "Apply")
        XCTAssertEqual(ManagedConfigCommandWarning.count(s), 0)
        XCTAssertEqual(model(s).warnings(Self.file([Self.liveNote])), [])
        XCTAssertEqual(model(s).verb, "Apply")
    }

    func testOneCommandIsSingular() {
        let s = Self.set([Self.file([Self.liveNote, Self.hookNote])])
        XCTAssertEqual(ManagedConfigCommandWarning.title(for: s), "Apply and allow 1 command to run")
        XCTAssertEqual(ManagedConfigCommandWarning.lines(in: s.files[0]), ["Runs a command: `kit-run pre` on `PreToolUse` (`Bash`)"])
        XCTAssertEqual(model(s).verb, "Apply and allow 1 command to run")
    }

    func testSeveralCommandsAcrossFilesArePlural() {
        let s = Self.set([Self.file([Self.hookNote, Self.statusNote]), Self.file([Self.hookNote2], target: "claude:other")])
        XCTAssertEqual(ManagedConfigCommandWarning.title(for: s), "Apply and allow 3 commands to run")
        XCTAssertEqual(ManagedConfigCommandWarning.lines(in: s.files[0]),
                       ["Runs a command: `kit-run pre` on `PreToolUse` (`Bash`)", "Runs a command: `kit-status` as the status line"])
        XCTAssertEqual(ManagedConfigCommandWarning.lines(in: s.files[1]), ["Runs a command: `kit-run post` on `Stop` (every match)"])
        XCTAssertEqual(ManagedConfigCommandWarning.count(s), 3)
    }

    /// The sheet shows the lines in the file's card and the button names them.
    func testTheRenderedSheetCarriesTheLinesAndTheTitle() {
        let m = model(Self.set([Self.file([Self.statusNote])]))
        XCTAssertTrue(m.renderedStrings.contains("Runs a command: `kit-status` as the status line"))
        XCTAssertEqual(m.renderedStrings.last, "Apply and allow 1 command to run")
        XCTAssertFalse(m.renderedStrings.contains("Apply"))
    }

    /// A kind that runs nothing gets no line: a block, a permissions union, a seed and the live note.
    func testPiecesThatRunNothingGetNoLine() async throws {
        let env = makeMCEnv()
        _ = await env.mc.apply([MCPieces.block(), MCPieces.allow(["Read"]), MCPieces.seed()], owner: env.owner)
        let set = try XCTUnwrap(env.consent.seen.first)
        XCTAssertTrue(set.files.count >= 2, "the claude and the kitconfig files were planned")
        XCTAssertEqual(set.files.flatMap { ManagedConfigCommandWarning.lines(in: $0) }, [])
        XCTAssertEqual(ManagedConfigCommandWarning.title(for: set), "Apply")
    }

    /// The planner's own sentences, from real pieces: a change of its wording turns this red.
    func testARealHookAndStatusLineWarn() async throws {
        let env = makeMCEnv()
        _ = await env.mc.apply([MCPieces.hook(), MCPieces.statusLine()], owner: env.owner)
        let set = try XCTUnwrap(env.consent.seen.first)
        XCTAssertEqual(set.files.flatMap { ManagedConfigCommandWarning.lines(in: $0) },
                       ["Runs a command: `kit-run pre` on `PreToolUse` (`Bash`)", "Runs a command: `kit-status` as the status line"])
        XCTAssertEqual(ManagedConfigCommandWarning.title(for: set), "Apply and allow 2 commands to run")
    }

    func testRemoveKeepsItsTitleAndRepairKeepsItsTitleButShowsTheLines() {
        let notes = [Self.hookNote]
        let remove = Self.set([Self.file(notes)], .remove)
        XCTAssertEqual(model(remove).verb, "Remove")
        XCTAssertEqual(model(remove).warnings(remove.files[0]), [])
        let repair = Self.set([Self.file(notes)], .repair)
        XCTAssertEqual(model(repair).verb, "Repair")
        XCTAssertEqual(model(repair).warnings(repair.files[0]), ["Runs a command: `kit-run pre` on `PreToolUse` (`Bash`)"])
    }

    /// The kinds that warn, pinned: a kind added to or dropped from the list must be a decision here.
    func testTheKindsThatRunACommandAreTheLiteralList() {
        XCTAssertEqual(Set(ManagedConfigCommandWarning.kinds.map(\.rawValue)), ["hook", "statusLine"])
        XCTAssertEqual(ManagedConfigCommandWarning.kinds.count, 2)
        XCTAssertEqual(Set(ManagedConfigCommandWarning.Kind.allCases.map(\.rawValue)), ["hook", "statusLine"])
        // each kind of the list warns on its own planner sentence
        XCTAssertEqual(ManagedConfigCommandWarning.kind(of: Self.hookNote)?.kind, .hook)
        XCTAssertEqual(ManagedConfigCommandWarning.kind(of: Self.statusNote)?.kind, .statusLine)
        XCTAssertTrue(ManagedConfigCommandWarning.kind(of: Self.liveNote) == nil)
        XCTAssertTrue(ManagedConfigCommandWarning.kind(of: "Claude Code will run  in every session.") == nil)
    }

    /// The re-ask compares the sheet as shown: a changed command is a changed sheet, so the loop asks again.
    func testTheReAskSeesAChangedWarning() {
        let one = Self.set([Self.file([Self.hookNote])])
        let other = Self.set([Self.file(["Claude Code will run `kit-run other` on `PreToolUse` (`Bash`) in every session."])])
        XCTAssertTrue(one != other, "only the command differs")
        XCTAssertTrue(ManagedConfigCommandWarning.lines(in: one.files[0]) != ManagedConfigCommandWarning.lines(in: other.files[0]))
        let more = Self.set([Self.file([Self.hookNote, Self.hookNote2])])
        XCTAssertTrue(one != more, "one more command")
        XCTAssertTrue(ManagedConfigCommandWarning.title(for: one) != ManagedConfigCommandWarning.title(for: more))
        XCTAssertTrue(one == Self.set([Self.file([Self.hookNote])]))
    }
}
