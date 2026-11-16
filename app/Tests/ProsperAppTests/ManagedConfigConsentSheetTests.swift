import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1235: the consent sheet's copy (the verb on the button, the display name as the title with the id below it,
/// no backup line for a new file), the two longer notes at UI scale 0.7, 0.85 and 1.0, and the change set's
/// hand-written equality (rider R947-1). Hand-built change sets (fake ids, /Users/example paths: nothing is
/// read or written) except the one prepare row, which works in its own tempDir(). The accessibility rows host the
/// view in a never-shown window and set the AX flags only on this test process's NSApplication, restoring them.
@MainActor
final class ManagedConfigConsentSheetTests: XCTestCase {
    private static let id = "kit-a"
    private static let existing = ManagedConfigChangeSet.File(
        target: "claude:CLAUDE.md", path: "/Users/example/.claude/CLAUDE.md",
        backupDirectory: "/Users/example/.config/prosper/managed-config/backups/claude-CLAUDE.md",
        lines: [.init(sign: .context, text: "# mine"), .init(sign: .added, text: "Follow the kit rules.")], notes: [])
    private static let created = ManagedConfigChangeSet.File(
        target: "kitconfig:kit.json", path: "/Users/example/.config/kit-a/kit.json",
        backupDirectory: "/Users/example/.config/prosper/managed-config/backups/kitconfig-kit.json",
        lines: [.init(sign: .added, text: "{}")], notes: [], newFile: true)
    /// The planner's drift note for a Remove (ManagedConfigPlanner.driftNote is private: its format, copied).
    private static let driftNote = "The rules block was edited by hand: Remove deletes those edits too. A copy of the file as it is now goes to the backups, "
        + "which keep the copies from Prosper's last \(ManagedConfig.preWriteBackupsKept) writes to this file."

    private static func set(_ action: ManagedConfigChangeSet.Action = .apply, name: String? = nil,
                            files: [ManagedConfigChangeSet.File]? = nil) -> ManagedConfigChangeSet {
        ManagedConfigChangeSet(action: action, owner: id, displayName: name, files: files ?? [existing], pieces: [])
    }

    private func model(_ set: ManagedConfigChangeSet) -> ManagedConfigConsentModel { ManagedConfigConsentModel(changes: set) { _ in } }

    // MARK: the copy, on the model

    func testButtonReadsTheOperationsVerb() {
        XCTAssertEqual(model(Self.set(.apply)).verb, "Apply")
        XCTAssertEqual(model(Self.set(.remove)).verb, "Remove")
        XCTAssertEqual(model(Self.set(.repair)).verb, "Repair")
        XCTAssertFalse(model(Self.set(.remove)).renderedStrings.contains("Apply"))
    }

    func testTitleIsTheDisplayNameWithTheIdBelowOrTheIdAlone() {
        let named = model(Self.set(name: "Fake Kit"))
        XCTAssertEqual(named.title, "Fake Kit")
        XCTAssertEqual(named.idLine, Self.id)
        let unnamed = model(Self.set())
        XCTAssertEqual(unnamed.title, Self.id)
        XCTAssertTrue(unnamed.idLine == nil, "the id is the title already")
        // outside data: no control, line break or direction character reaches the title
        let hostile = model(Self.set(name: "Fake\u{202E}Kit\n\u{0007}\u{2066}2"))
        XCTAssertEqual(hostile.title, "FakeKit2")
        XCTAssertFalse(hostile.title.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format })
        // nothing visible left: the id, as when no name is known
        let blank = model(Self.set(name: " \u{202E}\n "))
        XCTAssertEqual(blank.title, Self.id)
        XCTAssertTrue(blank.idLine == nil)
    }

    func testNoBackupLineForANewFile() {
        let m = model(Self.set(files: [Self.created, Self.existing]))
        XCTAssertTrue(m.backupLine(Self.created) == nil, "a new file has nothing to back up")
        XCTAssertEqual(m.backupLine(Self.existing), "Backup: \(Self.existing.backupDirectory)")
        XCTAssertEqual(m.renderedStrings.filter { $0.hasPrefix("Backup: ") }, ["Backup: \(Self.existing.backupDirectory)"])
    }

    /// prepare fills the change set's display name from the owner (ManagedConfig.swift, the one line); its own tempDir().
    func testPrepareCarriesTheOwnersDisplayName() async throws {
        let env = makeMCEnv()
        var owner = env.owner
        owner.displayName = "Fake Kit"
        _ = await env.mc.apply([MCPieces.block()], owner: owner)
        XCTAssertEqual(env.consent.seen.first?.displayName, "Fake Kit")
        XCTAssertEqual(env.consent.seen.first?.owner, "kit-a")
    }

    // MARK: rider R947-1: the hand-written equality

    /// Every stored field of the change set is placed on purpose: the shown ones in ==, identity out of it (the apply
    /// loop's re-ask compares the sheet and keeps its own digests). A field added later fails the Mirror count.
    func testChangeSetEqualityCoversEachShownFieldAndNotIdentity() {
        let inEquality = ["action", "owner", "displayName", "files", "pieces"], outOfEquality = ["identity"]
        let base = ManagedConfigChangeSet(action: .apply, owner: "kit-a", displayName: "Fake Kit", files: [Self.existing],
                                          pieces: [.init(id: "rules", action: .insert)],
                                          identity: [["/Users/example/.claude/CLAUDE.md", "no file", "new 00", "mode 644"]])
        let stored = Mirror(reflecting: base).children.compactMap(\.label)
        XCTAssertEqual(stored.count, inEquality.count + outOfEquality.count, "a new field: place it in or out of == on purpose: \(stored)")
        XCTAssertEqual(stored, inEquality + outOfEquality)
        var v = base
        v.action = .remove
        XCTAssertNotEqual(v, base, "action")
        v = base
        v.owner = "kit-b"
        XCTAssertNotEqual(v, base, "owner")
        v = base
        v.displayName = "Other Kit"
        XCTAssertNotEqual(v, base, "displayName")
        v = base
        v.files = [Self.created]
        XCTAssertNotEqual(v, base, "files")
        v = base
        v.pieces = [.init(id: "rules", action: .update)]
        XCTAssertNotEqual(v, base, "pieces")
        v = base
        v.identity = [["/Users/example/.claude/CLAUDE.md", "base 11", "new 22", "mode 600"]]
        XCTAssertEqual(v, base, "identity is not part of the sheet's equality")
        v.identity = nil
        XCTAssertEqual(v, base, "identity is not part of the sheet's equality")
    }

    // MARK: the real accessibility tree of a never-shown window

    private struct AXItem { let text: String; let frame: CGRect }

    /// The sheet's view, top-aligned as the panel's scroll view holds it, in a never-shown window of `size`; its AX
    /// tree walked until `done` holds, to a 5 s ceiling (polled, no fixed wait). Runs on main (the class is @MainActor).
    private func axTree(_ model: ManagedConfigConsentModel, _ size: CGSize, until done: ([AXItem]) -> Bool) -> [AXItem] {
        let root = ManagedConfigConsentView(model: model).frame(width: size.width).frame(maxHeight: .infinity, alignment: .top)
        let (win, host) = AXTreeSupport.hosted(root, size)
        defer { win.close() }
        let restore = AXTreeSupport.axOn()   // after hosting, as before; puts the flags back as found
        defer { restore() }
        // The first of label, title, value that is not empty; the poll loop is the shared one (layout, one 0.05 s pump, walk, 5 s ceiling).
        func items(_ t: [AXTreeNode]) -> [AXItem] {
            t.map { AXItem(text: [$0.label, $0.title, $0.value].first { !$0.isEmpty } ?? "", frame: $0.frame) }
        }
        let tree = items(AXTreeSupport.poll(host) { done(items($0)) })
        XCTAssertFalse(win.isVisible, "never shown")
        return tree
    }

    private func fitting(_ model: ManagedConfigConsentModel) -> CGSize {
        let width = sz(ManagedConfigConsentPanel.width)
        let h = NSHostingController(rootView: ManagedConfigConsentView(model: model)).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: h + 40)
    }

    /// B-INFO-6 on the tree: the verb's button (never Apply on Remove or Repair), the display name drawn as written
    /// (Markdown marks stay: never interpreted) with the id below it, one backup line for one existing file and one new.
    func testSheetCopyOnTheAccessibilityTreeAtEveryScale() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let name = "*Fake* `kit` [docs](https://example.com)"
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            for action: ManagedConfigChangeSet.Action in [.apply, .remove, .repair] {
                let m = model(Self.set(action, name: name, files: [Self.created, Self.existing]))
                let tag = "scale \(scale) \(action)"
                let tree = axTree(m, fitting(m)) { t in t.contains { $0.text == m.verb } && t.contains { $0.text == "Cancel" } && t.contains { $0.text == Self.id } }
                let texts = tree.map(\.text)
                XCTAssertTrue(texts.contains(m.verb), "\(tag): \(texts)")
                if action != .apply { XCTAssertFalse(texts.contains("Apply"), "\(tag): \(texts)") }
                XCTAssertTrue(texts.contains(name), "\(tag): the name as written: \(texts)")
                XCTAssertTrue(texts.contains(Self.id), "\(tag): the id below the name: \(texts)")
                // a selectable Text is on the tree twice (the text and its static text): distinct lines are counted
                XCTAssertEqual(Set(texts.filter { $0.hasPrefix("Backup: ") }), ["Backup: \(Self.existing.backupDirectory)"], "\(tag): \(texts)")
                if let title = tree.first(where: { $0.text == name }), let id = tree.first(where: { $0.text == Self.id }) {
                    XCTAssertLessThanOrEqual(id.frame.maxY, title.frame.minY + pixel, "\(tag): the id is below the title") // y up
                }
            }
        }
    }

    /// N1227-d: changedUnderSheetNote and the drift note are fully on the tree at UI scale 0.7, 0.85 and 1.0 (the
    /// whole text, a frame tall enough for every line it needs, above the buttons). Fixed: the title, the id, the
    /// lead and everything above the note keep their frames; the buttons keep their size and x and move down only.
    /// The file card grows.
    func testLongNotesAreWholeAndFixedPartsStayAtEveryScale() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for note in [ManagedConfigPlan.changedUnderSheetNote, Self.driftNote] {
            for scale: CGFloat in [0.7, 0.85, 1.0] {
                ThemeRuntime.scale = scale
                let tag = "scale \(scale) note \(note.prefix(16))"
                var noted = Self.existing
                noted.notes = [note]
                let without = model(Self.set(.remove, name: "Fake Kit"))
                let with = model(Self.set(.remove, name: "Fake Kit", files: [noted]))
                let size = fitting(with)
                let ready: ([AXItem]) -> Bool = { t in t.contains { $0.text == "Remove" } && t.contains { $0.text == "Fake Kit" } }
                let a = axTree(without, size, until: ready)
                let b = axTree(with, size) { t in ready(t) && t.contains { $0.text == note } }
                let item = try XCTUnwrap(b.first { $0.text == note }, "\(tag): \(b.map(\.text))")
                XCTAssertFalse(a.contains { $0.text == note }, tag)
                // whole: at least the lines the text needs at its width (a lower bound: SwiftUI may break earlier, never later)
                let font = NSFont.systemFont(ofSize: 12 * scale)
                let oneLine = (note as NSString).size(withAttributes: [.font: font]).width
                let lines = (oneLine / max(item.frame.width, 1)).rounded(.up)
                XCTAssertGreaterThanOrEqual(item.frame.height, lines * (font.ascender - font.descender) * 0.9,
                                            "\(tag): \(item.frame) for \(lines) lines: cut")
                XCTAssertLessThanOrEqual(item.frame.width, size.width, tag)
                // fixed: everything above the note (AX frames are in screen points, y up)
                let above = b.filter { $0.frame.height > 0 && $0.frame.minY >= item.frame.maxY && $0.text != note && !$0.text.isEmpty }
                XCTAssertTrue(above.contains { $0.text == "Fake Kit" } && above.contains { $0.text == Self.id }, "\(tag): \(above.map(\.text))")
                for e in above {
                    // per dimension, one device pixel: two drawn frames are not exactly equal at a fractional scale on a 1x runner
                    func same(_ f: CGRect) -> Bool {
                        abs(f.minX - e.frame.minX) <= pixel && abs(f.minY - e.frame.minY) <= pixel
                            && abs(f.width - e.frame.width) <= pixel && abs(f.height - e.frame.height) <= pixel
                    }
                    XCTAssertTrue(a.contains { $0.text == e.text && same($0.frame) }, "\(tag): \(e.text) at \(e.frame) moved when the note appeared")
                }
                for button in ["Cancel", "Remove"] {
                    let before = try XCTUnwrap(a.first { $0.text == button && $0.frame.height > 0 }, "\(tag): \(button)")
                    let after = try XCTUnwrap(b.first { $0.text == button && $0.frame.height > 0 }, "\(tag): \(button)")
                    // one device pixel: a control moved to a fractional y is pixel-aligned again (seen at 0.7: 20.0 -> 19.5 at 2x)
                    XCTAssertEqual(after.frame.width, before.frame.width, accuracy: pixel, "\(tag): \(button) keeps its width")
                    XCTAssertEqual(after.frame.height, before.frame.height, accuracy: pixel, "\(tag): \(button) keeps its height")
                    XCTAssertEqual(after.frame.minX, before.frame.minX, accuracy: pixel, "\(tag): \(button) keeps its x")
                    XCTAssertLessThanOrEqual(after.frame.maxY, item.frame.minY + pixel, "\(tag): \(button) is below the whole note")
                }
                fputs("mc1235 fact \(tag): note frame \(item.frame), \(Int(lines)) lines at least, \(above.count) elements above unmoved\n", stderr)
            }
        }
    }
}
