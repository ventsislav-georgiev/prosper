import Carbon
import XCTest
@testable import ProsperApp

/// #985: the Settings › Shortcuts runner targets follow their extensions. A built-in
/// target (Open App, Run Shell Command, Quicklinks) is offered only while the extension
/// that declares its prefix is live; a saved shortcut on one that is off keeps its row
/// with a note; the locked-mode Quicklinks / Quickdirs listings stop with their extension.
/// Rows read lists and decisions only: no hotkey is registered, nothing is run or opened.
@MainActor
final class ShortcutTargetLiveTests: XCTestCase {

    /// Synthetic Open / Shell / Quicklinks system extensions declaring the real built-in
    /// prefixes (empty init.lua, no VM), in this row's tempDir() on scratch defaults.
    /// Titles differ from the built-in labels so a row shows which source it came from.
    private func ownersRegistry() throws -> ExtensionRegistry {
        let root = tempDir("target-live")
        let systemDir = root.appendingPathComponent("system", isDirectory: true)
        let exts: [(id: String, command: String, title: String, prefixes: String)] = [
            (CommandRouter.openID, "open.run", "Open Fixture", #"prefix = "o ""#),
            (CommandRouter.shellID, "shell.run", "Shell Fixture", #"prefix = "> "\#nprefixes = ["!"]"#),
            (CommandRouter.quicklinksID, "quicklinks.run", "Links Fixture", #"prefix = "ql ""#),
        ]
        for ext in exts {
            let dir = systemDir.appendingPathComponent(ext.id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let toml = """
            [extension]
            id = "\(ext.id)"
            name = "target"
            title = "Target"
            description = "shortcut target fixture"
            version = "1.0.0"
            author = "tester"
            system = true

            [extension.host]
            min_version = "2.0.0"
            api_level = 1

            [extension.entry]
            main = "init.lua"

            [[contributes.commands]]
            id = "\(ext.command)"
            title = "\(ext.title)"
            mode = "no-view"
            \(ext.prefixes)

            """
            try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            try "".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        }
        return GateFixture(systemDir: systemDir,
                           userDir: root.appendingPathComponent("user", isDirectory: true),
                           defaults: scratchDefaults("target-live")).registry()
    }

    private func t(_ label: String, _ prefix: String) -> ActivationTarget {
        ActivationTarget(label: label, prefix: prefix)
    }

    /// The picker's list as a set (equal-length prefixes have no fixed order), plus a
    /// count check so a duplicate cannot hide in the set.
    private func assertTargets(_ reg: ExtensionRegistry?, _ expected: Set<ActivationTarget>,
                               _ message: String, line: UInt = #line) {
        let got = ActivationTarget.allTargets(registry: reg)
        XCTAssertEqual(Set(got), expected, message, line: line)
        XCTAssertEqual(got.count, expected.count, "\(message): no duplicate", line: line)
        XCTAssertEqual(got.first, t("Blank Runner", ""), "Blank Runner stays first", line: line)
    }

    // MARK: - Picker (INFO-2)

    func testAllLiveListsEachExtensionTargetOnceAndTheNativeBuiltins() throws {
        let reg = try ownersRegistry()
        assertTargets(reg, [t("Blank Runner", ""), t("Open Fixture", "o "), t("Shell Fixture", "> "),
                            t("Links Fixture", "ql "), t("Emoji Picker", ":")], "all live")
    }

    func testOpenDisabledDropsOpenApp() throws {
        let reg = try ownersRegistry()
        try reg.setEnabled(false, id: CommandRouter.openID)
        assertTargets(reg, [t("Blank Runner", ""), t("Shell Fixture", "> "),
                            t("Links Fixture", "ql "), t("Emoji Picker", ":")], "Open off")
        try reg.setEnabled(true, id: CommandRouter.openID)
        assertTargets(reg, [t("Blank Runner", ""), t("Open Fixture", "o "), t("Shell Fixture", "> "),
                            t("Links Fixture", "ql "), t("Emoji Picker", ":")], "Open back on")
    }

    func testShellDisabledDropsRunShellCommand() throws {
        let reg = try ownersRegistry()
        try reg.setEnabled(false, id: CommandRouter.shellID)
        assertTargets(reg, [t("Blank Runner", ""), t("Open Fixture", "o "),
                            t("Links Fixture", "ql "), t("Emoji Picker", ":")], "Shell off")
    }

    func testQuicklinksDisabledDropsQuicklinks() throws {
        let reg = try ownersRegistry()
        try reg.setEnabled(false, id: CommandRouter.quicklinksID)
        assertTargets(reg, [t("Blank Runner", ""), t("Open Fixture", "o "),
                            t("Shell Fixture", "> "), t("Emoji Picker", ":")], "Quicklinks off")
    }

    /// Emoji Picker and Blank Runner have no owning extension: they stay.
    func testAllDisabledLeavesOnlyTheUnownedBuiltins() throws {
        let reg = try ownersRegistry()
        for id in [CommandRouter.openID, CommandRouter.shellID, CommandRouter.quicklinksID] {
            try reg.setEnabled(false, id: id)
        }
        assertTargets(reg, [t("Blank Runner", ""), t("Emoji Picker", ":")], "all off")
    }

    /// No registry (direct callers, tests): ungated, as CommandRouter.extensionLive is.
    func testNoRegistryListsEveryBuiltin() {
        assertTargets(nil, [t("Blank Runner", ""), t("Open App", "o "), t("Run Shell Command", "> "),
                            t("Quicklinks", "ql "), t("Emoji Picker", ":")], "no registry")
    }

    // MARK: - Saved shortcut on a disabled target (INFO-2, second half)

    private func runnerRows(_ reg: ExtensionRegistry, _ custom: [CustomShortcut],
                            apps: [AppShortcut] = []) -> [BindableAction] {
        ShortcutCatalog.build(prosperActions: [], combos: [:],
                              activationTargets: ActivationTarget.allTargets(registry: reg),
                              customShortcuts: custom, appShortcuts: apps)
    }

    private let chord = KeyCombo(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(optionKey), display: "test")

    /// The current value stays a row, under its saved label, bound, and says why it is off;
    /// the unbound disabled built-ins are not offered at all.
    func testSavedShortcutOnADisabledTargetKeepsItsRowWithTheNote() throws {
        let reg = try ownersRegistry()
        try reg.setEnabled(false, id: CommandRouter.shellID)
        try reg.setEnabled(false, id: CommandRouter.quicklinksID)
        let saved = CustomShortcut(combo: chord, prefix: "> ", label: "Run Shell Command")
        let rows = runnerRows(reg, [saved]).filter { $0.kind == .runnerPrefix }
        XCTAssertEqual(Set(rows.map(\.key)), ["", "o ", ":", "> "], "ql (off, unsaved) is not offered")
        XCTAssertEqual(rows.count, 4)
        let row = rows.first { $0.key == "> " }
        XCTAssertEqual(row?.title, "Run Shell Command")
        XCTAssertEqual(row?.recordID, saved.id)
        XCTAssertTrue(row?.isBound ?? false)
        XCTAssertEqual(row?.conflictNote, ShortcutCatalog.disabledTargetNote)
        XCTAssertTrue(rows.filter { $0.key != "> " }.allSatisfy { $0.conflictNote == nil })
    }

    func testSavedShortcutOnALiveTargetHasNoNote() throws {
        let reg = try ownersRegistry()
        let saved = CustomShortcut(combo: chord, prefix: "> ", label: "Run Shell Command")
        let rows = runnerRows(reg, [saved]).filter { $0.kind == .runnerPrefix }
        XCTAssertEqual(rows.filter { $0.key == "> " }.count, 1, "merged onto the live target")
        XCTAssertEqual(rows.first { $0.key == "> " }?.recordID, saved.id)
        XCTAssertTrue(rows.allSatisfy { $0.conflictNote == nil })
    }

    /// A renamed quickdir's orphan row is not claimed to be a disabled extension.
    func testOrphanedNonBuiltinPrefixHasNoDisabledNote() throws {
        let reg = try ownersRegistry()
        let saved = CustomShortcut(combo: chord, prefix: "old ", label: "Old Quickdir")
        let row = runnerRows(reg, [saved]).first { $0.key == "old " }
        XCTAssertEqual(row?.title, "Old Quickdir")
        XCTAssertTrue(row?.conflictNote == nil)
    }

    /// The note and a chord clash share the one note line; neither hides the other.
    func testDisabledNoteKeepsAChordConflict() throws {
        let reg = try ownersRegistry()
        try reg.setEnabled(false, id: CommandRouter.openID)
        let saved = CustomShortcut(combo: chord, prefix: "o ", label: "Open App")
        let app = AppShortcut(target: "com.example.a", combo: chord, name: "A")
        let note = runnerRows(reg, [saved], apps: [app]).first { $0.key == "o " }?.conflictNote ?? ""
        XCTAssertTrue(note.hasPrefix(ShortcutCatalog.disabledTargetNote), note)
        XCTAssertTrue(note.contains("Also used by A"), note)
    }

    // MARK: - Locked-mode listings (INFO-1)

    private func install(_ registry: ExtensionRegistry) {
        let previous = CommandRouter.registry
        CommandRouter.registry = registry
        addTeardownBlock { @MainActor in CommandRouter.registry = previous }
    }

    /// The XCTest in-memory Preferences store, restored on teardown (never `save`).
    private func setPref(_ value: Any, _ key: String) {
        let d = Preferences.defaults
        let old = d.object(forKey: key)
        d.set(value, forKey: key)
        addTeardownBlock {
            if let old { d.set(old, forKey: key) } else { d.removeObject(forKey: key) }
        }
    }

    func testLockedQuicklinksListingStopsWithTheExtension() async throws {
        let reg = try gateFixture([(CommandRouter.quicklinksID, ["quicklinks.run"])]).registry()
        install(reg)
        setPref(#"{"zzqlink985":"https://example.com/"}"#, "ext.com.prosper.quicklinks.links")
        let mode = RunnerMode.ext(id: "quicklinks.run", title: "Quicklinks", icon: "link")
        func isListing(_ o: RunnerOutcome) -> Bool { if case .quicklinks = o { return true }; return false }

        let o1 = await CommandRouter.run("", mode: mode)
        XCTAssertTrue(isListing(o1), "live: the locked listing")
        try reg.setEnabled(false, id: CommandRouter.quicklinksID)
        let o2 = await CommandRouter.run("", mode: mode)
        XCTAssertFalse(isListing(o2), "off: no locked listing")
        let o3 = await CommandRouter.run("zzql", mode: mode)
        XCTAssertFalse(isListing(o3), "off: no filtered listing")
        try reg.setEnabled(true, id: CommandRouter.quicklinksID)
        let o4 = await CommandRouter.run("", mode: mode)
        XCTAssertTrue(isListing(o4), "back on")
    }

    func testLockedQuickdirsListingsStopWithTheExtension() async throws {
        let reg = try gateFixture([(CommandRouter.quickdirsID, ["quickdirs.run"])]).registry()
        install(reg)
        setPref(#"[{"name":"gatedir985","path":"/nonexistent-985","prefix":"zq","action":"","actionLabel":""}]"#,
                "ext.com.prosper.quickdirs.dirs")
        let picker = RunnerMode.ext(id: "quickdirs.run", title: "Quickdirs", icon: "folder")
        let browse = RunnerMode.ext(id: "quickdirs.run", title: "gatedir985", icon: "folder", arg: "gatedir985")
        func isNative(_ o: RunnerOutcome) -> Bool {
            switch o { case .quickdirsMenu, .quickdirs: return true; default: return false }
        }

        let o5 = await CommandRouter.run("", mode: picker)
        XCTAssertTrue(isNative(o5), "live: picker")
        let o6 = await CommandRouter.run("", mode: browse)
        XCTAssertTrue(isNative(o6), "live: one quickdir")
        try reg.setEnabled(false, id: CommandRouter.quickdirsID)
        let o7 = await CommandRouter.run("", mode: picker)
        XCTAssertFalse(isNative(o7), "off: no picker")
        let o8 = await CommandRouter.run("", mode: browse)
        XCTAssertFalse(isNative(o8), "off: no quickdir listing")
    }
}
