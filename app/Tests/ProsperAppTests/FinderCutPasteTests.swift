import XCTest
@testable import ProsperApp

/// Everything the Finder ⌘X/⌘V move decides synchronously, tested headlessly —
/// no Finder, no Automation grant, no event tap. The Apple Events themselves are
/// covered by the manual matrix in the PR.
@MainActor
final class FinderCutPasteTests: XCTestCase {

    private let finder = "com.apple.finder"
    private let cutKey: Int64 = 7    // kVK_ANSI_X
    private let pasteKey: Int64 = 9  // kVK_ANSI_V

    private func chord(_ keyCode: Int64, cmd: Bool = true, alt: Bool = false,
                       ctrl: Bool = false, shift: Bool = false) -> KeyChord {
        KeyChord(keyCode: keyCode, cmd: cmd, alt: alt, ctrl: ctrl, shift: shift)
    }

    private func handled(_ chord: KeyChord, bundleID: String? = "com.apple.finder",
                         role: String? = "AXOutline", enabled: Bool = true,
                         pasteImage: Bool = false) -> FinderCutPasteAction? {
        FinderSupport.shouldHandle(chord: chord, bundleID: bundleID, role: role,
                                   cutPaste: enabled, pasteImage: pasteImage)
    }

    // MARK: - acceptsFocusedRole

    func testEditableRolesAreRejectedAndBrowsingRolesAccepted() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField"] {
            XCTAssertFalse(FinderSupport.acceptsFocusedRole(role), "\(role) owns ⌘X/⌘V")
        }
        XCTAssertTrue(FinderSupport.acceptsFocusedRole("AXOutline"))
        XCTAssertTrue(FinderSupport.acceptsFocusedRole("AXBrowser"))
        XCTAssertTrue(FinderSupport.acceptsFocusedRole("AXScrollArea"))
        // Unreadable role: not knowing is not a licence to swallow.
        XCTAssertFalse(FinderSupport.acceptsFocusedRole(nil))
    }

    // MARK: - shouldHandle matrix

    func testBareCommandXAndVInFinderAreOurs() {
        XCTAssertEqual(handled(chord(cutKey)), .cut)
        XCTAssertEqual(handled(chord(pasteKey)), .paste)
    }

    /// The sharpest failure mode this feature has: eating ⌘X while the user is
    /// editing a filename would destroy their edit with no way back.
    func testRenameFieldKeepsBothChords() {
        XCTAssertNil(handled(chord(cutKey), role: "AXTextField"))
        XCTAssertNil(handled(chord(pasteKey), role: "AXTextField"))
        // Finder's search field is the same shape.
        XCTAssertNil(handled(chord(pasteKey), role: "AXSecureTextField"))
        // An AX read that timed out or failed reads as "leave it alone".
        XCTAssertNil(handled(chord(cutKey), role: nil))
    }

    func testOnlyFinderAndOnlyWhenEnabled() {
        XCTAssertNil(handled(chord(cutKey), bundleID: "com.apple.Safari"))
        XCTAssertNil(handled(chord(cutKey), bundleID: nil))
        XCTAssertNil(handled(chord(cutKey), enabled: false))
        XCTAssertNil(handled(chord(pasteKey), enabled: false))
    }

    func testModifiedChordsAreNotOurs() {
        // ⌥⌘V is Finder's own "Move Item Here" and must reach it untouched.
        XCTAssertNil(handled(chord(pasteKey, alt: true)))
        XCTAssertNil(handled(chord(pasteKey, shift: true)))
        XCTAssertNil(handled(chord(pasteKey, ctrl: true)))
        XCTAssertNil(handled(chord(cutKey, alt: true)))
        // No ⌘ at all: plain "x" is typing.
        XCTAssertNil(handled(chord(cutKey, cmd: false)))
    }

    func testOtherKeysAreNotOurs() {
        XCTAssertNil(handled(chord(8)))   // ⌘C — Finder already handles copy
        XCTAssertNil(handled(chord(0)))   // ⌘A
        var media = chord(pasteKey)
        media.mediaCode = 0               // a media key that happens to share a keyCode
        XCTAssertNil(handled(media))
    }

    /// The role read is expensive (a cross-process AX message inside the tap), so
    /// it must not run for keystrokes that were never ours.
    func testRoleIsOnlyReadAfterTheCheapChecksPass() {
        var reads = 0
        func role() -> String? { reads += 1; return "AXOutline" }

        _ = FinderSupport.shouldHandle(chord: chord(cutKey), bundleID: finder,
                                       role: role(), cutPaste: false, pasteImage: false)
        _ = FinderSupport.shouldHandle(chord: chord(cutKey), bundleID: "com.apple.Safari",
                                       role: role(), cutPaste: true, pasteImage: false)
        _ = FinderSupport.shouldHandle(chord: chord(11), bundleID: finder,
                                       role: role(), cutPaste: true, pasteImage: false)
        XCTAssertEqual(reads, 0, "no AX message for a keystroke that cannot be ours")

        _ = FinderSupport.shouldHandle(chord: chord(cutKey), bundleID: finder,
                                       role: role(), cutPaste: true, pasteImage: false)
        XCTAssertEqual(reads, 1)
    }

    // MARK: - uniqueDestination

    func testUniqueDestinationAppendsCounterBeforeTheExtension() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        XCTAssertEqual(FinderSupport.uniqueDestination(for: "a.txt", in: dir, fm: fm).lastPathComponent,
                       "a.txt", "no collision, no rename")

        try Data().write(to: dir.appendingPathComponent("a.txt"))
        XCTAssertEqual(FinderSupport.uniqueDestination(for: "a.txt", in: dir, fm: fm).lastPathComponent,
                       "a 2.txt")

        try Data().write(to: dir.appendingPathComponent("a 2.txt"))
        XCTAssertEqual(FinderSupport.uniqueDestination(for: "a.txt", in: dir, fm: fm).lastPathComponent,
                       "a 3.txt")

        // Extensionless names keep the counter at the end.
        try Data().write(to: dir.appendingPathComponent("README"))
        XCTAssertEqual(FinderSupport.uniqueDestination(for: "README", in: dir, fm: fm).lastPathComponent,
                       "README 2")

        // Dotted names: only the last component is the extension.
        try Data().write(to: dir.appendingPathComponent("archive.tar.gz"))
        XCTAssertEqual(FinderSupport.uniqueDestination(for: "archive.tar.gz", in: dir, fm: fm).lastPathComponent,
                       "archive.tar 2.gz")
    }

    // MARK: - paste-time pasteboard staleness

    /// The whole reason there is no synthetic re-post: ⌘V is only ours while the
    /// pasteboard is still the one the cut wrote. Anything copied since belongs to
    /// the user, and their ⌘V must reach Finder untouched.
    func testMarksGoStaleWhenThePasteboardMovesOn() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(rawValue: "eu.illegible.prosper.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        let markedChangeCount = pasteboard.changeCount
        XCTAssertEqual(pasteboard.changeCount, markedChangeCount, "our own write is not stale")

        pasteboard.clearContents()
        pasteboard.setString("something the user copied", forType: .string)
        XCTAssertNotEqual(pasteboard.changeCount, markedChangeCount,
                          "a copy made since must invalidate the marks")
    }

    // MARK: - outcome summary

    func testMoveOutcomeSummaryCountsHonestly() {
        XCTAssertEqual(FinderMoveOutcome(moved: 0, failed: 0).summary, "Nothing to move")
        XCTAssertEqual(FinderMoveOutcome(moved: 1, failed: 0).summary, "Moved 1 item")
        XCTAssertEqual(FinderMoveOutcome(moved: 3, failed: 0).summary, "Moved 3 items")
        // A partial batch must never read as a clean success — that is exactly the
        // case Finder's own non-atomic batch move hides.
        XCTAssertEqual(FinderMoveOutcome(moved: 2, failed: 1).summary, "Moved 2 items, 1 failed")
        XCTAssertEqual(FinderMoveOutcome(moved: 0, failed: 2).summary, "Could not move 2 items")
    }

    // MARK: - preference default

    func testPreferenceIsOffUntilTheUserAsks() {
        let keys = ["finderCutPasteEnabled", "finderPasteImageEnabled"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        XCTAssertFalse(Preferences.finderCutPasteEnabled, "absent must read as off")
        XCTAssertFalse(Preferences.finderPasteImageEnabled, "absent must read as off")
        // Neither feature on: the tap must not even ask.
        XCTAssertFalse(FinderCutPaste.shared.isEnabled)
    }

    // MARK: - paste image as PNG (#038)

    /// With only the image feature on, ⌘X is Finder's again — swallowing it would
    /// break the cut the user asked us not to handle.
    func testImageFeatureAloneClaimsOnlyCommandV() {
        XCTAssertNil(handled(chord(cutKey), enabled: false, pasteImage: true))
        XCTAssertEqual(handled(chord(pasteKey), enabled: false, pasteImage: true), .paste)
        // Both off: nothing is ours.
        XCTAssertNil(handled(chord(pasteKey), enabled: false, pasteImage: false))
        // Still gated on Finder and on a non-editable role.
        XCTAssertNil(handled(chord(pasteKey), bundleID: "com.apple.Safari",
                             enabled: false, pasteImage: true))
        XCTAssertNil(handled(chord(pasteKey), role: "AXTextField", enabled: false, pasteImage: true))
        // ⌥⌘V stays Finder's "Move Item Here".
        XCTAssertNil(handled(chord(pasteKey, alt: true), enabled: false, pasteImage: true))
    }

    /// The gate that decides whether ⌘V is swallowed at all. A `public.file-url`
    /// means the user copied FILES — Finder's own paste, never ours, even though
    /// the pasteboard also carries a preview image of them.
    func testPreferredImageTypeIgnoresPasteboardsCarryingFileURLs() {
        XCTAssertNil(FinderSupport.preferredImageType(in: ["public.file-url", "public.png"]))
        XCTAssertNil(FinderSupport.preferredImageType(in: ["public.file-url", "public.tiff",
                                                           "public.url-name"]))
        // No image at all: an ordinary text paste.
        XCTAssertNil(FinderSupport.preferredImageType(in: ["public.utf8-plain-text"]))
        XCTAssertNil(FinderSupport.preferredImageType(in: []))
    }

    /// PNG wins when it is there (it is written through without a re-encode);
    /// otherwise the first type that is an image at all.
    func testPreferredImageTypePrefersPNG() {
        XCTAssertEqual(FinderSupport.preferredImageType(in: ["public.tiff", "public.png"]),
                       "public.png")
        XCTAssertEqual(FinderSupport.preferredImageType(in: ["public.utf8-plain-text", "public.tiff"]),
                       "public.tiff")
        XCTAssertEqual(FinderSupport.preferredImageType(in: ["public.jpeg"]), "public.jpeg")
    }

    /// Fixed locale and calendar: the name must not become Arabic-Indic digits or a
    /// Buddhist year because of the user's region.
    func testPastedImageFileNameIsStableAcrossLocales() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(FinderSupport.fileName(for: date, timeZone: utc),
                       "Pasted_Image_20231114_221320.png")
        // Same instant, different zone: the LOCAL wall clock is what names the file.
        XCTAssertEqual(FinderSupport.fileName(for: date, timeZone: TimeZone(identifier: "Europe/Sofia")!),
                       "Pasted_Image_20231115_001320.png")
    }

    /// The pasted PNG lands beside whatever is already there, never on top of it.
    func testPastedImageNameIsUniquifiedOnCollision() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let name = FinderSupport.fileName(for: Date(timeIntervalSince1970: 1_700_000_000),
                                          timeZone: TimeZone(identifier: "UTC")!)
        try Data().write(to: dir.appendingPathComponent(name))
        XCTAssertEqual(FinderSupport.uniqueDestination(for: name, in: dir, fm: fm).lastPathComponent,
                       "Pasted_Image_20231114_221320 2.png")
    }
}
