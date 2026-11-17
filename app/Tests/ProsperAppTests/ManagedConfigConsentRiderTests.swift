import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import ProsperApp

/// One value, set and read on main only.
private final class MCRBox<T>: @unchecked Sendable { var value: T? }

/// #1235 second dispatch: the display name filled from the manifest's title (A), the whole id under it (N1235-a), the
/// change set's stored fields as a literal list (N947-a), and the consent queue's give-up orders (N947-b, N947-c).
/// Fake ids (com.example.kit), /Users/example paths. The queue rows drive the panel through its show seam and the
/// consent's presenter seam: no panel is built or ordered front. The manifest rows write only inside their own tempDir().
/// The accessibility row hosts the view in a never-shown window through AXTreeSupport (flags on this process only,
/// put back). Everything runs on the main actor (the class is @MainActor) except the confirming tasks, which are
/// detached as a caller off main is; their closures only call `confirm`, which hops to main itself.
@MainActor
final class ManagedConfigConsentRiderTests: XCTestCase {
    @MainActor final class Log {
        var shown: [ManagedConfigConsentModel] = []
        var closed = 0
        /// Calls of the consent's presenter (one per confirm that reached it).
        var presented = 0
        /// Calls of a request's withdraw (the caller gave up after it was presented).
        var withdrawn = 0
        var enqueued: XCTestExpectation?
        var withdrew: XCTestExpectation?
    }

    /// A panel behind its show seam and a sheet consent whose presenter enqueues on it; every closure runs on main.
    private func rig() -> (Log, ManagedConfigSheetConsent) {
        let log = Log()
        let panel = ManagedConfigConsentPanel { model in
            log.shown.append(model)
            return { log.closed += 1 }
        }
        let consent = ManagedConfigSheetConsent { changes, done in
            log.presented += 1
            let withdraw = panel.enqueue(changes, done: done)
            log.enqueued?.fulfill()
            return {
                log.withdrawn += 1
                withdraw()
                log.withdrew?.fulfill()
            }
        }
        return (log, consent)
    }

    private static func set(_ owner: String, _ action: ManagedConfigChangeSet.Action = .apply) -> ManagedConfigChangeSet {
        ManagedConfigChangeSet(action: action, owner: owner, files: [], pieces: [],
                               identity: [["/Users/example/.claude/CLAUDE.md", "no file", "new 00", "mode 644"]])
    }

    /// Starts one confirm off main and returns once the panel holds it.
    private func ask(_ consent: ManagedConfigSheetConsent, _ set: ManagedConfigChangeSet, _ log: Log) async -> Task<Bool, Never> {
        let e = expectation(description: "enqueued \(set.owner)")
        log.enqueued = e
        let task = Task.detached { await consent.confirm(set) }
        await fulfillment(of: [e], timeout: 10)
        log.enqueued = nil
        return task
    }

    private func owners(_ log: Log) -> [String] { log.shown.map(\.changes.owner) }

    /// The task's value, or nil when it has none within 10 s (a broken queue under a mutant): never hangs the run.
    private func value<T: Sendable>(_ task: Task<T, Never>) async -> T? {
        let box = MCRBox<T>(), e = expectation(description: "answered")
        let waiter = Task { @MainActor in box.value = await task.value; e.fulfill() }
        await fulfillment(of: [e], timeout: 10)
        waiter.cancel()
        return box.value
    }

    /// Answers every sheet still up, the ones a mutant shows after a drain included (each answer ends one finite request).
    private func drain(_ log: Log) { while let m = log.shown.first(where: { !$0.answered }) { m.answer(false) } }

    // MARK: N947-a: the stored fields, by name

    /// A field added to the change set later fails here by name until it is placed in (or deliberately out of) the
    /// hand-written == (ManagedConfigModel.swift), whatever its position.
    func testChangeSetStoredFieldsAreTheLiteralList() {
        let literal = ["action", "owner", "displayName", "files", "pieces", "identity"]
        let labels = Mirror(reflecting: Self.set("kit-a")).children.compactMap(\.label)
        XCTAssertEqual(Set(labels), Set(literal), "new: \(Set(labels).subtracting(literal)), gone: \(Set(literal).subtracting(labels))")
        XCTAssertEqual(labels.count, literal.count, "\(labels)")
    }

    // MARK: N947-b: a give-up before the present task runs

    /// The caller is cancelled before confirm is entered, so onCancel's main task (gaveUp) is queued before the present
    /// task: the presenter is never called, the caller gets false, and the next request is shown at once.
    func testAConfirmCancelledBeforeItsPresentTaskRunsIsNeverPresented() async {
        let (log, consent) = rig()
        let set = Self.set("kit-a")
        // Not a timed wait: the sleep ends only by the cancel below (Task.sleep throws at once on a cancelled task),
        // so confirm is entered already cancelled. The hour is a ceiling that is never reached.
        let first = Task.detached { () -> Bool in
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            return await consent.confirm(set)
        }
        first.cancel()
        let got = await value(first)
        XCTAssertEqual(got, false, "the caller that gave up gets false")
        XCTAssertEqual(log.presented, 0, "the presenter was never reached")
        XCTAssertEqual(owners(log), [], "no sheet for a caller that already gave up")
        let second = await ask(consent, Self.set("kit-b"), log)
        XCTAssertEqual(owners(log), ["kit-b"], "the next request is shown at once")
        log.shown.last?.answer(true)
        drain(log)
        let got2 = await value(second)
        XCTAssertEqual(got2, true)
    }

    // MARK: N947-c: joined waiters

    /// Both waiters of one joined sheet give up: the sheet closes once and the next request is shown.
    func testBothJoinedWaitersGiveUpClosesTheSheetAndShowsTheNext() async {
        let (log, consent) = rig()
        let a = await ask(consent, Self.set("kit-a", .remove), log)
        let b = await ask(consent, Self.set("kit-a", .remove), log)
        let c = await ask(consent, Self.set("kit-c"), log)
        XCTAssertEqual(owners(log), ["kit-a"], "one sheet for the two, the third waits")
        a.cancel()
        let gotA = await value(a)
        XCTAssertEqual(gotA, false)
        XCTAssertEqual(log.closed, 0, "the other waiter still waits on it")
        b.cancel()
        let gotB = await value(b)
        XCTAssertEqual(gotB, false)
        XCTAssertEqual(log.closed, 1, "the last waiter gone: the sheet closed once")
        XCTAssertEqual(owners(log), ["kit-a", "kit-c"], "and the next request is shown")
        XCTAssertEqual(log.withdrawn, 2)
        log.shown.last?.answer(true)
        drain(log)
        let gotC = await value(c)
        XCTAssertEqual(gotC, true)
        XCTAssertEqual(log.closed, 2)
    }

    /// An answer and a cancel in one main-actor turn. Task.cancel sets the flag and runs onCancel at once on this
    /// thread; onCancel's withdraw is a main task that runs only after this turn, so the panel sees the click first and
    /// the withdraw after it. (The cancel is written first because the flag must be set before the canceller's
    /// confirm resumes off main; written after the click, the canceller may already have returned true: the click
    /// came first, a race of the caller, not of the queue.) The canceller gets false, the joined waiter the click,
    /// and the late withdraw touches nothing: the queue moves on once.
    func testAnAnswerThenACancelInOneTurnAnswersEachWaiterOnce() async {
        let (log, consent) = rig()
        let a = await ask(consent, Self.set("kit-a", .remove), log)
        let b = await ask(consent, Self.set("kit-a", .remove), log)
        let c = await ask(consent, Self.set("kit-c"), log)
        let withdrew = expectation(description: "the canceller's withdraw ran")
        log.withdrew = withdrew
        a.cancel()
        log.shown.first?.answer(true)
        await fulfillment(of: [withdrew], timeout: 10)
        log.withdrew = nil
        let gotA = await value(a), gotB = await value(b)
        XCTAssertEqual(gotA, false, "the canceller gets false")
        XCTAssertEqual(gotB, true, "the joined waiter gets the click")
        XCTAssertEqual(log.withdrawn, 1)
        XCTAssertEqual(owners(log), ["kit-a", "kit-c"], "the queue moved on once")
        XCTAssertEqual(log.closed, 1)
        XCTAssertEqual(log.shown.last?.answered, false, "the next sheet waits for its own answer: the late withdraw left it alone")
        log.shown.last?.answer(true)
        drain(log)
        let gotC = await value(c)
        XCTAssertEqual(gotC, true)
    }

    // MARK: A: the display name from the manifest's title

    /// An extension folder in the row's own tempDir(), loaded as the registry loads one. `title` is TOML text (escapes stay
    /// escapes in this file).
    private func loaded(title: String, label: String = #function) throws -> LoadedExtension {
        let dir = tempDir(label).appendingPathComponent("com.example.kit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [extension]
        id = "com.example.kit"
        name = "example-kit"
        title = "\(title)"
        description = "A test kit"
        version = "1.0.0"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "function noop() end".write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return try ExtensionLoader.load(directory: dir, isSystem: false, hostVersion: "2.0.0")
    }

    /// The sheet as prepare builds it for this owner (ManagedConfig.swift copies owner.displayName: pinned by
    /// ManagedConfigConsentSheetTests.testPrepareCarriesTheOwnersDisplayName).
    private func sheet(_ o: ManagedConfigOwner) -> ManagedConfigConsentModel {
        ManagedConfigConsentModel(changes: ManagedConfigChangeSet(action: .apply, owner: o.id, displayName: o.displayName, files: [], pieces: [])) { _ in }
    }

    func testTheOwnerCarriesTheManifestTitleAndTheSheetShowsItAboveTheId() async throws {
        let o = try loaded(title: "Fake Kit").managedConfigOwner
        XCTAssertEqual(o.displayName, "Fake Kit")
        XCTAssertEqual(o.id, "com.example.kit")
        XCTAssertEqual(o.kitSlug, "example-kit")
        // through prepare (a declining consent: nothing is written) onto the sheet: the title, then the id
        let env = makeMCEnv(consent: false)
        _ = await env.mc.apply([MCPieces.block()], owner: o)
        let changes = try XCTUnwrap(env.consent.seen.first)
        let m = ManagedConfigConsentModel(changes: changes) { _ in }
        XCTAssertEqual(m.title, "Extension \"Fake Kit\"")
        XCTAssertEqual(m.idLine, "com.example.kit")
        XCTAssertEqual(Array(m.renderedStrings.prefix(2)), ["Extension \"Fake Kit\"", "com.example.kit"], "the title above the id")
    }

    /// The title is outside data: the owner carries it as written, the sheet cleans and cuts it, and an empty title (or
    /// one with nothing left after cleaning) shows the id alone.
    func testAnEmptyOrHostileTitleNeverStandsInForTheId() throws {
        let hostile = try loaded(title: "Fake\\u202EKit\\u0007\\u2066\\nTwo").managedConfigOwner
        XCTAssertEqual(hostile.displayName, "Fake\u{202E}Kit\u{0007}\u{2066}\nTwo", "the owner carries the title as written")
        let shown = sheet(hostile)
        XCTAssertEqual(shown.title, "Extension \"FakeKitTwo\"", "no control, direction or line break reaches the title")
        XCTAssertEqual(shown.idLine, "com.example.kit", "the id is under it")
        for title in ["", "\\u2066 \\n \\uFEFF"] {
            let m = sheet(try loaded(title: title).managedConfigOwner)
            XCTAssertEqual(m.title, "com.example.kit", "'\(title)': the id alone")
            XCTAssertTrue(m.idLine == nil, "'\(title)': no second id line")
        }
        let long = sheet(try loaded(title: String(repeating: "Kit ", count: 80)).managedConfigOwner)
        XCTAssertEqual(long.displayName?.count, 120, "bounded")
        XCTAssertTrue(long.title.hasSuffix("\u{2026}\""))
        XCTAssertEqual(long.idLine, "com.example.kit")
    }

    // MARK: N1235-a: the whole id under the title

    private static let existing = ManagedConfigChangeSet.File(
        target: "claude:CLAUDE.md", path: "/Users/example/.claude/CLAUDE.md",
        backupDirectory: "/Users/example/.config/prosper/managed-config/backups/claude-CLAUDE.md",
        lines: [.init(sign: .context, text: "# mine"), .init(sign: .added, text: "Follow the kit rules.")], notes: [])

    private func named(_ id: String) -> ManagedConfigConsentModel {
        ManagedConfigConsentModel(changes: ManagedConfigChangeSet(action: .apply, owner: id, displayName: "Fake Kit",
                                                                  files: [Self.existing], pieces: [])) { _ in }
    }

    /// The panel's height rule (makePanel): the view's fitted height at the fixed width.
    private func fitting(_ model: ManagedConfigConsentModel) -> CGSize {
        let width = sz(ManagedConfigConsentPanel.width)
        let h = NSHostingController(rootView: ManagedConfigConsentView(model: model)).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: h)
    }

    private func tree(_ model: ManagedConfigConsentModel, _ size: CGSize, id: String) -> [AXTreeNode] {
        let view = ManagedConfigConsentView(model: model).frame(width: size.width).frame(maxHeight: .infinity, alignment: .top)
        return AXTreeSupport.tree(view, size) { t in t.contains { $0.named("Apply") } && t.contains { $0.named("Cancel") } && t.contains { $0.named(id) } }
    }

    /// A 128-character id (the longest an owner may have, ManagedConfigPaths.isValidID) is drawn whole under the title at
    /// UI scale 0.7, 0.85 and 1.0: as tall as the lines it needs, with the whole id as help and selectable like the backup
    /// line. The sheet's rule (fixed width, height fitted to the content) is kept: the buttons stay inside the sheet with
    /// the size and x they have under a short id, below the id; the sheet grows by at most two id lines.
    func testTheWholeIdIsShownUnderTheTitleAndTheButtonsStayInsideAtEveryScale() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let short = "com.example.kit"
        let long = "com.example." + String(repeating: "k", count: 116)
        XCTAssertEqual(long.count, 128)
        XCTAssertTrue(ManagedConfigPaths.isValidID(long))
        let backup = "Backup: \(Self.existing.backupDirectory)"
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (1 pt a pixel; 0.5 pt at 2x): never a literal 0.5
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            let tag = "scale \(scale)"
            let s = named(short), w = named(long)
            let size = fitting(w)
            let a = tree(s, fitting(s), id: short)
            let b = tree(w, size, id: long)
            let idNode = try XCTUnwrap(b.first { $0.named(long) && $0.frame.height > 0 }, "\(tag): \(b.map(\.name))")
            let title = try XCTUnwrap(b.first { $0.named("Extension \"Fake Kit\"") && $0.frame.height > 0 }, tag)
            XCTAssertLessThanOrEqual(idNode.frame.maxY, title.frame.minY + pixel, "\(tag): the id is below the title") // y up
            // whole: at least the lines the id needs at its width (a lower bound: a break may come earlier, never later)
            let font = NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .regular)
            let oneLine = (long as NSString).size(withAttributes: [.font: font]).width
            let lines = (oneLine / max(idNode.frame.width, 1)).rounded(.up)
            XCTAssertGreaterThanOrEqual(lines, 2, "\(tag): the long id needs more than one line at \(idNode.frame.width)")
            XCTAssertGreaterThanOrEqual(idNode.frame.height, lines * (font.ascender - font.descender) * 0.9, "\(tag): \(idNode.frame) for \(lines) lines: cut")
            XCTAssertLessThanOrEqual(idNode.frame.width, size.width, tag)
            XCTAssertTrue(b.contains { $0.help == long }, "\(tag): the help holds the whole id")
            // selectable: the id's nodes have the roles of the backup line's (a selectable Text)
            XCTAssertEqual(Set(b.filter { $0.named(long) }.map(\.role)), Set(b.filter { $0.named(backup) }.map(\.role)), "\(tag): selectable like the backup line")
            // the sheet's size rule: the buttons inside it, unchanged in size and x, below the whole id
            let content = try XCTUnwrap(b.first, tag).frame.insetBy(dx: -pixel, dy: -pixel)
            for button in ["Cancel", "Apply"] {
                let before = try XCTUnwrap(a.first { $0.named(button) && $0.frame.height > 0 }, "\(tag): \(button)")
                let after = try XCTUnwrap(b.first { $0.named(button) && $0.frame.height > 0 }, "\(tag): \(button)")
                XCTAssertTrue(content.contains(after.frame), "\(tag): \(button) at \(after.frame) inside the sheet \(content)")
                XCTAssertEqual(after.frame.width, before.frame.width, accuracy: pixel, "\(tag): \(button) keeps its width")
                XCTAssertEqual(after.frame.height, before.frame.height, accuracy: pixel, "\(tag): \(button) keeps its height")
                XCTAssertEqual(after.frame.minX, before.frame.minX, accuracy: pixel, "\(tag): \(button) keeps its x")
                XCTAssertLessThanOrEqual(after.frame.maxY, idNode.frame.minY + pixel, "\(tag): \(button) is below the whole id")
            }
            // bounded: at most two more id lines than a short id (the id line holds at most three)
            let grow = size.height - fitting(s).height
            let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
            XCTAssertLessThanOrEqual(grow, 2 * lineHeight * 1.25, "\(tag): the sheet grew \(grow) for one id")
            fputs("mc1235c fact \(tag): id frame \(idNode.frame), \(Int(lines)) lines at least, grew \(grow), roles \(Set(b.filter { $0.named(long) }.map(\.role)))\n", stderr)
        }
    }
}
