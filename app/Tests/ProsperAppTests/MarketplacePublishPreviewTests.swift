import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1141: a Marketplace publish first lists what it will send (the packer's own list), refuses a
/// symbolic link or a folder it cannot read by name, and only the list's own action publishes. Riders:
/// the GitHub work-folder name is the same in every launch, and two installs of one name at once do not
/// clear each other's folder, and a failed extract frees its name. The publish here is always a recorder closure: no row uploads or downloads.
/// Rows named testWorkName* never delete (a recorder is the removal); every other row writes and deletes
/// only inside its own tempDir(). Views are hosted in never-shown windows.
final class MarketplacePublishPreviewTests: XCTestCase {

    // MARK: - The list (model and pure text)

    /// The list is the packer's: hidden files, test files and "._" metadata are counted as left out,
    /// never listed; the text and the action name the count.
    @MainActor
    func testListIsWhatThePackerSends() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/util.lua", ".DS_Store", ".omc/state/x.json",
                               "tests/a.lua", "lib/a.test.lua", "._init.lua"])
        let want = ["./extension.toml", "./init.lua", "./lib/util.lua"]
        let plan = RemoteInstaller.publishPlan(ext)
        XCTAssertEqual(plan, RemoteInstaller.PublishPlan(members: want, leftOut: 5))
        XCTAssertEqual(RemoteInstaller.publishMembers(ext), want)
        XCTAssertEqual(try packedMembers(ext), want)

        let model = PublishConfirmation()
        let published = Recorder()
        model.ask(ext, publish: { _ in published.count += 1 })
        let shown = try XCTUnwrap(model.plan)
        XCTAssertEqual(PublishConfirmation.lines(shown),
                       ["3 files will be published:", "extension.toml", "init.lua", "lib/util.lua",
                        "5 hidden or test items left out"])
        XCTAssertEqual(PublishConfirmation.actionTitle(shown), "Publish 3 files")
        XCTAssertEqual(published.count, 0, "asking publishes nothing")
    }

    /// One file and one left out read singular; past ten names the rest is a count.
    @MainActor
    func testListTextSingularAndCap() {
        let one = RemoteInstaller.PublishPlan(members: ["./extension.toml"], leftOut: 1)
        XCTAssertEqual(PublishConfirmation.lines(one),
                       ["1 file will be published:", "extension.toml", "1 hidden or test item left out"])
        XCTAssertEqual(PublishConfirmation.actionTitle(one), "Publish 1 file")
        let many = RemoteInstaller.PublishPlan(members: (1...12).map { String(format: "./f%02d.lua", $0) })
        XCTAssertEqual(PublishConfirmation.lines(many),
                       ["12 files will be published:"] + (1...10).map { String(format: "f%02d.lua", $0) }
                       + ["and 2 more"])
        XCTAssertEqual(PublishConfirmation.lines(RemoteInstaller.PublishPlan()), ["There are no files to publish."])
    }

    // MARK: - R1141-1, R1141-2: refused up front, by name

    /// A link to a file or to a folder refuses the publish and is named; a hidden link is left out like
    /// any hidden file. The packer refuses too, and the confirmation's action publishes nothing.
    @MainActor
    func testSymbolicLinkRefusesThePublishByName() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/util.lua"])
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: ext.appendingPathComponent("lib/link.lua").path, withDestinationPath: "util.lua")
        try fm.createSymbolicLink(atPath: ext.appendingPathComponent("assets").path, withDestinationPath: "lib")
        try fm.createSymbolicLink(atPath: ext.appendingPathComponent(".venv").path, withDestinationPath: "lib")
        let plan = RemoteInstaller.publishPlan(ext)
        XCTAssertEqual(plan.links, ["assets", "lib/link.lua"])
        XCTAssertEqual(plan.leftOut, 1)
        let why = "Can't publish symbolic links (every install refuses them): assets, lib/link.lua"
        XCTAssertEqual(plan.refusal, why)
        XCTAssertEqual(PublishConfirmation.lines(plan), [why])
        XCTAssertThrowsError(try RemoteInstaller.packageForPublish(ext)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .cannotPublish(why))
        }
        let model = PublishConfirmation()
        let published = Recorder()
        model.ask(ext, publish: { _ in published.count += 1 })
        model.confirm()
        XCTAssertEqual(published.count, 0, "a refused plan never publishes")
        XCTAssertTrue(model.plan == plan, "the refusal stays on screen")
    }

    /// A folder the walk cannot list refuses the publish and is named (the old walk skipped it in
    /// silence). An unreadable hidden folder is left out, never entered, and refuses nothing.
    @MainActor
    func testUnreadableFolderRefusesThePublishByName() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/private/secret.lua", ".git/objects/x"])
        let locked = [ext.appendingPathComponent("lib/private"), ext.appendingPathComponent(".git/objects")]
        let fm = FileManager.default
        defer { for d in locked { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path) } }
        for d in locked { try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: d.path) }

        let plan = RemoteInstaller.publishPlan(ext)
        XCTAssertEqual(plan.unreadable, ["lib/private"])
        XCTAssertEqual(plan.members, ["./extension.toml", "./init.lua"])
        let why = "Can't read the folder lib/private, so its files would be left out."
        XCTAssertEqual(plan.refusal, why)
        XCTAssertEqual(PublishConfirmation.lines(plan), [why])
        XCTAssertThrowsError(try RemoteInstaller.packageForPublish(ext)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .cannotPublish(why))
        }
        let two = RemoteInstaller.PublishPlan(members: ["./a.lua"], unreadable: ["a", "b"])
        XCTAssertEqual(two.refusal, "Can't read the folders a, b, so their files would be left out.")
    }

    // MARK: - Only the confirmation publishes

    /// The Publish button's action opens the list and publishes nothing; the list's action publishes once
    /// and closes it; Cancel closes it without publishing.
    @MainActor
    func testPublishButtonOnlyOpensTheList() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let model = PublishConfirmation()
        let published = Recorder()
        let button = PublishButton(title: "Publish", help: "", dir: ext, model: model, publish: { _ in published.count += 1 })
        button.tap()
        XCTAssertEqual(published.count, 0, "the Publish button published without the confirmation")
        XCTAssertEqual(model.plan?.members, ["./extension.toml", "./init.lua"])
        model.confirm()
        XCTAssertEqual(published.count, 1)
        XCTAssertTrue(model.plan == nil)
        model.confirm()
        XCTAssertEqual(published.count, 1, "a closed confirmation publishes nothing")
        button.tap()
        model.cancel()
        model.confirm()
        XCTAssertEqual(published.count, 1, "Cancel publishes nothing")
        XCTAssertTrue(model.plan == nil)
    }

    /// The list's action reads the folder again. A file added after the list was shown publishes
    /// nothing: the new list and action title are shown, and only that confirmation publishes, once.
    /// A link added after the list was shown turns it into the refusal, which never publishes.
    @MainActor
    func testFolderChangedAfterTheListPublishesOnlyWhatIsShown() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let model = PublishConfirmation()
        let published = Recorder()
        let button = PublishButton(title: "Publish", help: "", dir: ext, model: model, publish: { _ in published.count += 1 })
        button.tap()
        XCTAssertEqual(PublishConfirmation.actionTitle(try XCTUnwrap(model.plan)), "Publish 2 files")
        try FileManager.default.createDirectory(at: ext.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: ext.appendingPathComponent("lib/new.lua"))
        model.confirm()
        XCTAssertEqual(published.count, 0, "a file added after the list was shown was published unseen")
        let now = try XCTUnwrap(model.plan, "the changed list closed instead of showing")
        XCTAssertEqual(PublishConfirmation.lines(now),
                       ["3 files will be published:", "extension.toml", "init.lua", "lib/new.lua"])
        XCTAssertEqual(PublishConfirmation.actionTitle(now), "Publish 3 files")
        model.confirm()
        XCTAssertEqual(published.count, 1, "the shown list's confirmation publishes once")
        XCTAssertTrue(model.plan == nil)

        button.tap()
        try FileManager.default.createSymbolicLink(atPath: ext.appendingPathComponent("lib/link.lua").path,
                                                   withDestinationPath: "new.lua")
        model.confirm()
        let why = "Can't publish symbolic links (every install refuses them): lib/link.lua"
        XCTAssertEqual(model.plan?.refusal, why, "the link that appeared is not shown as the refusal")
        model.confirm()
        XCTAssertEqual(published.count, 1, "a refusal that appeared after the list publishes nothing")
    }

    /// The same through the real accessibility tree of a never-shown window: VoiceOver's press on
    /// Publish shows the list (each line read by name) and "Publish 2 files", which alone publishes.
    @MainActor
    func testAccessibilityPressPublishesOnlyThroughTheList() throws {
        let ext = try fixture(["extension.toml", "init.lua", ".DS_Store"])
        let model = PublishConfirmation()
        let published = Recorder()
        let hosted = Hosted(row(model, ext, publish: { _ in published.count += 1 }), width: paneRowWidth())
        defer { hosted.close() }
        let lines = ["2 files will be published:", "extension.toml", "init.lua", "1 hidden or test item left out"]

        let publish = try XCTUnwrap(hosted.wait { $0.first { $0.isButton("Publish") } }, "no Publish button in the tree")
        XCTAssertFalse(hosted.items().contains { $0.isButton("Publish 2 files") }, "the list shows before a press")
        XCTAssertTrue(press(publish.object))
        let action = hosted.wait { items in
            lines.allSatisfy { l in items.contains { $0.has(l) } } ? items.first { $0.isButton("Publish 2 files") } : nil
        }
        print("#1141 a11y tree:\n" + hosted.items().filter { !$0.text.isEmpty }
            .map { "  \($0.role) label=\($0.label) value=\($0.value) title=\($0.title)" }.joined(separator: "\n"))
        XCTAssertEqual(published.count, 0, "the Publish press published without the confirmation")
        let confirm = try XCTUnwrap(action, "the list or its action is not in the tree")
        XCTAssertNotNil(hosted.items().first { $0.isButton("Cancel") })
        XCTAssertTrue(press(confirm.object))
        XCTAssertNotNil(hosted.wait { _ in published.count == 1 ? true : nil }, "the list's action did not publish")
        XCTAssertTrue(model.plan == nil)
        XCTAssertFalse(hosted.window.isVisible, "never shown")
    }

    /// A refused plan reads its reason by name and offers Cancel only.
    @MainActor
    func testAccessibilityRefusalHasNoPublishAction() throws {
        let ext = try fixture(["extension.toml"])
        try FileManager.default.createSymbolicLink(atPath: ext.appendingPathComponent("x.lua").path,
                                                   withDestinationPath: "extension.toml")
        let model = PublishConfirmation()
        model.ask(ext, publish: { _ in })
        let hosted = Hosted(row(model, ext, publish: { _ in }), width: paneRowWidth())
        defer { hosted.close() }
        let why = "Can't publish symbolic links (every install refuses them): x.lua"
        let items = hosted.wait { items in items.contains { $0.has(why) } && items.contains { $0.isButton("Cancel") } ? items : nil }
        XCTAssertNotNil(items, "the refusal or Cancel is not in the tree: "
                        + hosted.items().map { "\($0.role) \($0.text)" }.joined(separator: " | "))
        XCTAssertFalse((items ?? []).contains { $0.role == "AXButton" && $0.text.hasPrefix("Publish ") },
                       "a refused plan offers a publish")
    }

    /// The list closes when the row stops offering Publish (Untrust, a publish running, already live):
    /// the row's closesPublishList (#1174: no longer the button's disappear) closes it, the list and its action
    /// go with it, and nothing is published.
    @MainActor
    func testListClosesWhenPublishIsNoLongerOffered() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let model = PublishConfirmation()
        let offer = Offer()
        let published = Recorder()
        let hosted = Hosted(OfferedRow(offer: offer, model: model, dir: ext, publish: { _ in published.count += 1 }),
                            width: paneRowWidth())
        defer { hosted.close() }
        let publish = try XCTUnwrap(hosted.wait { $0.first { $0.isButton("Publish") } }, "no Publish button in the tree")
        XCTAssertTrue(press(publish.object))
        XCTAssertNotNil(hosted.wait { $0.first { $0.isButton("Publish 2 files") } }, "the list did not open")
        offer.on = false
        let closed = hosted.wait { items in
            model.plan == nil && !items.contains { $0.isButton("Publish 2 files") } ? true : nil
        }
        XCTAssertNotNil(closed, "the list outlived the Publish button")
        model.confirm()
        XCTAssertEqual(published.count, 0, "the list published after the Publish button went away")
    }

    // MARK: - #1174: the list closes on the row's offer, not on a lazy list's disappear

    /// The row's offer is the condition PublishActions draws the button under: a trusted user extension, not
    /// publishing, its local version not live yet or ahead. Each way out turns it false, which closes the list.
    @MainActor
    func testRowOffersPublishOnlyWhileItsButtonShows() {
        func offers(system: Bool = false, trusted: Bool = true, publishing: Bool = false, published: String? = nil) -> Bool {
            PublishActions.offers(system: system, trusted: trusted, publishing: publishing, published: published,
                                  version: "1.1")
        }
        XCTAssertTrue(offers(), "never published")
        XCTAssertTrue(offers(published: "1.0"), "the local version is ahead")
        XCTAssertFalse(offers(trusted: false), "untrusted")
        XCTAssertFalse(offers(publishing: true), "a publish is running")
        XCTAssertFalse(offers(published: "1.1"), "this version is live")
        XCTAssertFalse(offers(published: "1.2"), "a newer version is live")
        XCTAssertFalse(offers(system: true), "a system extension")
    }

    /// A row scrolled far out of the Settings pane's lazy list (the real NeonScroll, 60 sections below it, in a
    /// never-shown window; the scroll is set on the clip view, no event) keeps its list open, and comes back with
    /// the same list model, still open.
    @MainActor
    func testListStaysOpenWhenItsRowScrollsFarOut() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let seen = Seen()
        let hosted = Hosted(NeonScroll {
            NeonSection("User Extensions") { OwnRow(dir: ext, seen: seen) }
            ForEach(0..<60, id: \.self) { i in NeonSection("Filler \(i)") { Color.clear.frame(height: 400) } }
        }, width: 600, height: 400)
        defer { hosted.close() }
        let opened = try XCTUnwrap(hosted.wait { _ in seen.model }, "the row did not appear")
        opened.ask(ext, publish: { _ in })
        XCTAssertNotNil(hosted.wait { $0.first { $0.isButton("Publish 2 files") } }, "the list did not open")
        let scroll = try XCTUnwrap(hosted.scrollView(), "no scroll view in the pane")
        let far = (scroll.documentView?.frame.height ?? 0) - 400
        XCTAssertGreaterThan(far, 4000, "the list below the row is not long")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: far))
        scroll.reflectScrolledClipView(scroll.contentView)
        // #1182: a lazy list that keeps the row is not the case under test: skip, saying what was seen.
        guard hosted.wait({ _ in seen.gone > 0 ? true : nil }) != nil else {
            throw XCTSkip("the lazy list kept the row: no disappear after the scroll to y \(Int(far)) "
                          + "(appeared \(seen.appeared), gone \(seen.gone), list open \(opened.plan != nil))")
        }
        XCTAssertTrue(opened.plan != nil, "scrolling the row out closed its list")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertNotNil(hosted.wait { _ in seen.appeared > 1 ? true : nil }, "the row did not come back")
        XCTAssertTrue(seen.model === opened, "the row came back with a new list model")
        XCTAssertTrue(opened.plan != nil, "the list closed while its row was out of view")
        XCTAssertNotNil(hosted.wait { $0.first { $0.isButton("Publish 2 files") } }, "the list is not drawn on return")
        XCTAssertFalse(hosted.window.isVisible, "never shown")
    }

    /// The extension removed: its row leaves the list with its own list model, and the same id back is a new row
    /// whose list is closed.
    @MainActor
    func testListEndsWhenTheExtensionIsRemoved() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let ids = Ids()
        let seen = Seen()
        try listEndsWithItsRow(RowList(ids: ids, dir: ext, seen: seen), ext, seen,
                               hide: { ids.list = [] }, show: { ids.list = ["eu.example.one"] })
    }

    /// Another Settings pane shown (signing out happens in the Account pane): the Extensions pane's rows end
    /// with their lists, and the pane shown again draws its row with the list closed.
    @MainActor
    func testListEndsWhenThePaneSwitches() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let pane = Offer()
        let seen = Seen()
        try listEndsWithItsRow(PaneSwitch(pane: pane, dir: ext, seen: seen), ext, seen,
                               hide: { pane.on = false }, show: { pane.on = true })
    }

    /// The Settings window closed (SettingsWindow's willClose detaches the hosting controller and drops the
    /// window): the row's list model is freed with the tree, so no list outlives the window. Never shown.
    @MainActor
    func testListEndsWhenTheSettingsWindowCloses() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let seen = Seen()
        var window: NSWindow? = autoreleasepool {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: paneRowWidth(), height: 240), styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OwnRow(dir: ext, seen: seen))
            return w
        }
        XCTAssertTrue(spin(window) { seen.model != nil }, "the row did not appear")
        seen.model?.ask(ext, publish: { _ in })
        XCTAssertTrue(seen.model?.plan != nil, "the list did not open")
        XCTAssertFalse(window?.isVisible ?? true, "never shown")
        autoreleasepool {
            window?.close()
            window?.contentViewController = nil
            window = nil
        }
        XCTAssertTrue(spin(nil) { seen.model == nil }, "the list's model outlived the closed window")
    }

    /// At UI scale 1.0, 0.85 and 0.7, in the narrowest row of the Settings pane, every line and both
    /// actions stay inside it, no line is cut short of its wrapped height, and the actions keep their
    /// natural width.
    @MainActor
    func testNothingClipsAtEveryScale() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let ext = try fixture(["extension.toml", "init.lua", "lib/a-long-file-name-for-a-narrow-pane.lua",
                               "themes/dark.json", ".DS_Store", "tests/a.lua"])
        let linked = try fixture(["extension.toml"])
        for name in ["assets-shared-with-another-extension", "lib/vendor-link-to-a-shared-library"] {
            try FileManager.default.createDirectory(at: linked.appendingPathComponent(name).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: linked.appendingPathComponent(name).path,
                                                       withDestinationPath: "extension.toml")
        }
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            for dir in [ext, linked] {
                let model = PublishConfirmation()
                model.ask(dir, publish: { _ in })
                let plan = try XCTUnwrap(model.plan)
                let lines = PublishConfirmation.lines(plan)
                let actions = (plan.refusal == nil ? [PublishConfirmation.actionTitle(plan)] : []) + ["Cancel"]
                let width = paneRowWidth()
                let hosted = Hosted(row(model, dir, publish: { _ in }), width: width)
                defer { hosted.close() }
                let items = hosted.wait { items in
                    lines.allSatisfy { l in items.contains { $0.has(l) } }
                        && actions.allSatisfy { a in items.contains { $0.isButton(a) } } ? items : nil
                } ?? []
                XCTAssertFalse(items.isEmpty, "scale \(scale): the list is not in the tree: "
                               + hosted.items().map { "\($0.role) \($0.text)" }.joined(separator: " | "))
                let win = hosted.window.frame
                func inside(_ f: CGRect) -> Bool {
                    !f.isNull && f.minX >= win.minX - 0.5 && f.maxX <= win.maxX + 0.5
                        && f.minY >= win.minY - 0.5 && f.maxY <= win.maxY + 0.5
                }
                for line in lines {
                    let f = items.first { $0.has(line) }?.frame ?? .null
                    XCTAssertTrue(inside(f), "scale \(scale): '\(line)' at \(f) outside \(win)")
                    // The height the line needs at its own width (+1: AX frames are whole points; the same breaks
                    // as in the row, whose width is at least this).
                    let need = NSHostingView(rootView: Text(line).font(Neon.font(.caption))
                        .frame(width: min(f.width + 1, width), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)).fittingSize.height
                    XCTAssertGreaterThanOrEqual(f.height, need - 1, "scale \(scale): '\(line)' cut to \(f.height) of \(need)")
                }
                for a in actions {
                    let f = items.first { $0.isButton(a) }?.frame ?? .null
                    let natural = NSHostingView(rootView: Text(a).font(Neon.font(.caption))
                        .fontWeight(a == "Cancel" ? Font.Weight.regular : .bold).fixedSize())
                        .fittingSize.width
                    XCTAssertTrue(inside(f), "scale \(scale): '\(a)' at \(f) outside \(win)")
                    // 1 pt: AX frames are whole points, the natural width is not.
                    XCTAssertGreaterThanOrEqual(f.width, natural - 1, "scale \(scale): '\(a)' squeezed to \(f.width)")
                }
                XCTAssertFalse(hosted.window.isVisible, "never shown")
            }
        }
    }

    // MARK: - #1160: the packer packs the confirmed list; the list survives the button's new title

    /// The confirmation hands its plan to the publish, and the packer given that plan packs it and nothing
    /// else: a file written after the confirm is not in the archive (a fresh walk would have packed it).
    @MainActor
    func testFileAddedAfterTheConfirmIsNotPacked() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/util.lua"])
        let want = ["./extension.toml", "./init.lua", "./lib/util.lua"]
        let model = PublishConfirmation()
        let published = Recorder()
        model.ask(ext, publish: { published.plans.append($0) })
        model.confirm()
        XCTAssertEqual(published.plans.count, 1)
        let plan = try XCTUnwrap(published.plans.last, "the confirmation did not hand over its plan")
        XCTAssertEqual(plan.members, want)
        try Data("x".utf8).write(to: ext.appendingPathComponent("late.lua"))
        try Data("x".utf8).write(to: ext.appendingPathComponent("lib/late.lua"))
        XCTAssertEqual(RemoteInstaller.publishMembers(ext).count, 5, "the folder now holds two more files")
        XCTAssertEqual(try packedMembers(ext, plan: plan), want, "a file added after the confirm was packed")
    }

    /// A member removed after the confirm stops the publish and the message names it; nothing is packed.
    @MainActor
    func testMemberRemovedAfterTheConfirmStopsThePublish() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/util.lua"])
        let model = PublishConfirmation()
        let published = Recorder()
        model.ask(ext, publish: { published.plans.append($0) })
        model.confirm()
        let plan = try XCTUnwrap(published.plans.last, "the confirmation did not hand over its plan")
        try FileManager.default.removeItem(at: ext.appendingPathComponent("lib/util.lua"))   // inside tempDir()
        let why = "The folder changed after you confirmed the list, so nothing was published: lib/util.lua (removed)."
            + " Publish again to see the new list."
        XCTAssertThrowsError(try RemoteInstaller.packageForPublish(ext, plan: plan)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .cannotPublish(why))
        }
    }

    /// A member replaced by a link after the confirm, a member reached through a folder now replaced by a
    /// link, and a member now a folder all stop the publish, each named.
    @MainActor
    func testMemberReplacedByALinkAfterTheConfirmStopsThePublish() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/util.lua", "x.lua"])
        let elsewhere = try fixture(["util.lua"])   // another tempDir() of this row, holding a real util.lua
        let model = PublishConfirmation()
        let published = Recorder()
        model.ask(ext, publish: { published.plans.append($0) })
        model.confirm()
        let plan = try XCTUnwrap(published.plans.last, "the confirmation did not hand over its plan")
        let fm = FileManager.default
        try fm.removeItem(at: ext.appendingPathComponent("init.lua"))   // every path here is inside tempDir()
        try fm.createSymbolicLink(atPath: ext.appendingPathComponent("init.lua").path, withDestinationPath: "extension.toml")
        try fm.removeItem(at: ext.appendingPathComponent("lib"))
        try fm.createSymbolicLink(atPath: ext.appendingPathComponent("lib").path, withDestinationPath: elsewhere.path)
        try fm.removeItem(at: ext.appendingPathComponent("x.lua"))
        try fm.createDirectory(at: ext.appendingPathComponent("x.lua"), withIntermediateDirectories: false)
        let why = "The folder changed after you confirmed the list, so nothing was published: init.lua (now a symbolic link),"
            + " lib/util.lua (now a symbolic link), x.lua (no longer a regular file). Publish again to see the new list."
        XCTAssertThrowsError(try RemoteInstaller.packageForPublish(ext, plan: plan)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .cannotPublish(why))
        }
    }

    /// The list stays open when the live version arrives and the button's title changes from "Publish" to
    /// "Publish v1.1" (the real PublishActions in a never-shown window); its action still publishes once.
    @MainActor
    func testListStaysOpenWhenTheLiveVersionArrives() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let model = PublishConfirmation()
        let live = Live()
        let published = Recorder()
        let hosted = Hosted(LiveRow(live: live, model: model, dir: ext, publish: { published.plans.append($0) }),
                            width: paneRowWidth())
        defer { hosted.close() }
        let publish = try XCTUnwrap(hosted.wait { $0.first { $0.isButton("Publish") } }, "no Publish button in the tree")
        XCTAssertTrue(press(publish.object))
        XCTAssertNotNil(hosted.wait { $0.first { $0.isButton("Publish 2 files") } }, "the list did not open")

        live.version = "1.0"
        XCTAssertNotNil(hosted.wait { $0.first { $0.isButton("Publish v1.1") } }, "the title did not change")
        // A second update that keeps the title: once it is drawn, the first update's disappear actions have run.
        live.version = "1.0.1"
        XCTAssertNotNil(hosted.wait { $0.first { $0.has("v1.0.1 published") } }, "the second update was not drawn")
        XCTAssertTrue(model.plan != nil, "the title change closed the list")
        let confirm = try XCTUnwrap(hosted.items().first { $0.isButton("Publish 2 files") }, "the list left the tree")
        XCTAssertTrue(press(confirm.object))
        XCTAssertNotNil(hosted.wait { _ in published.plans.count == 1 ? true : nil }, "the list's action did not publish")
        XCTAssertEqual(published.plans.last?.members, ["./extension.toml", "./init.lua"])
        XCTAssertFalse(hosted.window.isVisible, "never shown")
    }

    // MARK: - R1160-1: a name that is not valid UTF-8 is refused by name

    /// The listing's decode flags a name whose bytes are not valid UTF-8 (U+FFFD for each bad byte) and
    /// keeps valid ones exact; the plan's refusal names it. APFS refuses such a name (EILSEQ), so this is
    /// where the refusal is tested on this machine.
    @MainActor
    func testListedNameFlagsBytesThatAreNotUTF8() {
        for ok in ["init.lua", "café-\u{1F600}.lua", "e\u{301}.lua"] {
            XCTAssertTrue(RemoteInstaller.listedName(Array(ok.utf8)) == (ok, true), ok)
        }
        let bad: [UInt8] = Array("bad".utf8) + [0xFF] + Array(".lua".utf8)
        XCTAssertTrue(RemoteInstaller.listedName(bad) == ("bad\u{FFFD}.lua", false))
        XCTAssertFalse(RemoteInstaller.listedName([0x80]).exact, "a lone continuation byte")
        XCTAssertFalse(RemoteInstaller.listedName(Array("a".utf8) + [0xE2, 0x82]).exact, "a cut sequence")
        XCTAssertFalse(RemoteInstaller.listedName([0xC0, 0xAF]).exact, "an overlong slash")
        let plan = RemoteInstaller.PublishPlan(members: ["./init.lua"], notUTF8: ["lib/bad\u{FFFD}.lua"])
        let why = "Can't publish file names that are not valid UTF-8 (\u{FFFD} marks the bytes that can't be shown): "
            + "lib/bad\u{FFFD}.lua"
        XCTAssertEqual(plan.refusal, why)
        XCTAssertEqual(PublishConfirmation.lines(plan), [why])
    }

    /// The same through the folder, where the file system accepts the name: the plan names the file and the
    /// packer refuses it. Skipped where the file system refuses to create such a name (APFS: EILSEQ).
    func testNonUTF8NameInTheFolderIsRefusedByName() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let path: [UInt8] = Array(ext.path.utf8) + Array("/bad".utf8) + [0xFF] + Array(".lua".utf8) + [0]
        let fd = path.withUnsafeBufferPointer {
            $0.withMemoryRebound(to: CChar.self) { open($0.baseAddress!, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
        }
        guard fd >= 0 else {
            let e = errno
            throw XCTSkip("this file system refuses a name that is not valid UTF-8 (errno \(e) "
                          + "\(String(cString: strerror(e)))); testListedNameFlagsBytesThatAreNotUTF8 covers the refusal")
        }
        close(fd)
        let plan = RemoteInstaller.publishPlan(ext)
        XCTAssertEqual(plan.notUTF8, ["bad\u{FFFD}.lua"])
        XCTAssertEqual(plan.unreadable, [])
        let why = "Can't publish file names that are not valid UTF-8 (\u{FFFD} marks the bytes that can't be shown): bad\u{FFFD}.lua"
        XCTAssertEqual(plan.refusal, why)
        XCTAssertThrowsError(try RemoteInstaller.packageForPublish(ext)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .cannotPublish(why))
        }
    }

    // MARK: - #1168: the row's packing step, the read error, the listing, non-files, a partial listing

    /// The row's packing step hands the confirmed plan to the packer (a recorder here, run in the step's detached
    /// task), and with the real packer packs that plan only: a file added after the confirm stays out.
    @MainActor
    func testRowPackingStepPacksTheConfirmedPlan() async throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let model = PublishConfirmation()
        let published = Recorder()
        model.ask(ext, publish: { published.plans.append($0) })
        model.confirm()
        let plan = try XCTUnwrap(published.plans.last, "the confirmation did not hand over its plan")
        let handed = try await PublishActions.pack(ext, plan, packer: { _, p in p?.members.joined(separator: " ") ?? "no plan" })
        XCTAssertEqual(handed, "./extension.toml ./init.lua", "the packing step did not pass the confirmed plan")
        try Data("x".utf8).write(to: ext.appendingPathComponent("late.lua"))
        let blob = try await PublishActions.pack(ext, plan)
        XCTAssertEqual(try tarList(blob, ext), ["./extension.toml", "./init.lua"],
                       "a file added after the confirm was packed")
    }

    /// A member the publisher can no longer reach (its folder's mode changed in this row's tempDir()) stops the
    /// publish as "(can't be read)", not "(removed)".
    @MainActor
    func testUnreadableMemberAfterTheConfirmSaysCantBeRead() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/util.lua"])
        let plan = RemoteInstaller.publishPlan(ext)
        let lib = ext.appendingPathComponent("lib")
        defer { chmod(lib.path, 0o755) }
        XCTAssertEqual(chmod(lib.path, 0o000), 0)
        let why = "The folder changed after you confirmed the list, so nothing was published: lib/util.lua (can't be read)."
            + " Publish again to see the new list."
        XCTAssertThrowsError(try RemoteInstaller.packageForPublish(ext, plan: plan)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .cannotPublish(why))
        }
    }

    /// The walk itself meets names that are not valid UTF-8 (APFS cannot hold one, so the listing adds them to the
    /// real one): each is named with its folder, a hidden one is left out, and the packer refuses the plan.
    func testNonUTF8NameFromTheListingIsRefusedByName() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/util.lua"])
        let bad: [UInt8] = Array("bad".utf8) + [0xFF] + Array(".lua".utf8)
        let added: [String: [[UInt8]]] = ["ext": [bad, Array(".".utf8) + bad], "lib": [bad]]
        let plan = RemoteInstaller.publishPlan(ext, names: {
            try RemoteInstaller.readNames($0) + (added[$0.lastPathComponent] ?? [])
        })
        XCTAssertEqual(plan.notUTF8, ["bad\u{FFFD}.lua", "lib/bad\u{FFFD}.lua"])
        XCTAssertEqual(plan.unreadable, [])
        XCTAssertEqual(plan.leftOut, 1)
        XCTAssertEqual(plan.members, ["./extension.toml", "./init.lua", "./lib/util.lua"])
        let why = "Can't publish file names that are not valid UTF-8 (\u{FFFD} marks the bytes that can't be shown): "
            + "bad\u{FFFD}.lua, lib/bad\u{FFFD}.lua"
        XCTAssertEqual(plan.refusal, why)
        XCTAssertThrowsError(try RemoteInstaller.packageForPublish(ext, plan: plan)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .cannotPublish(why))
        }
    }

    /// Item 7: a folder whose listing fails part way names only the folder; the bad names it had already listed are
    /// a partial list and are not shown.
    func testFolderFailingPartWayNamesOnlyTheFolder() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/util.lua"])
        let bad: [UInt8] = Array("bad".utf8) + [0xFF] + Array(".lua".utf8)
        // A bad name, then a name lstat cannot find: entries throws after the bad name was reported.
        let plan = RemoteInstaller.publishPlan(ext, names: {
            try RemoteInstaller.readNames($0) + ($0.lastPathComponent == "lib" ? [bad, Array("ghost.lua".utf8)] : [])
        })
        XCTAssertEqual(plan.unreadable, ["lib"])
        XCTAssertEqual(plan.notUTF8, [], "a partial list of bad names was kept")
        XCTAssertEqual(plan.refusal, "Can't read the folder lib, so its files would be left out.")
    }

    /// A named pipe made in this row's tempDir() is refused by the plan itself, by name, with words for something that
    /// never was a file; the packer refuses before tar, and the confirmation publishes nothing. Nothing here opens
    /// it: the walk lstats it (entries), the refusal stops packageForPublish before changedMembers and tar.
    @MainActor
    func testPipeInTheFolderIsRefusedByTheList() throws {
        let ext = try fixture(["extension.toml", "init.lua", "lib/util.lua"])
        let pipe = ext.appendingPathComponent("lib/feed").path
        XCTAssertEqual(mkfifo(pipe, 0o600), 0)
        defer { unlink(pipe) }
        let plan = RemoteInstaller.publishPlan(ext)
        XCTAssertEqual(plan.notFiles, ["lib/feed"])
        XCTAssertEqual(plan.members, ["./extension.toml", "./init.lua", "./lib/util.lua"])
        let why = "Can't publish items that are not files or folders (a pipe, socket or device): lib/feed"
        XCTAssertEqual(plan.refusal, why)
        XCTAssertEqual(PublishConfirmation.lines(plan), [why])
        XCTAssertThrowsError(try RemoteInstaller.packageForPublish(ext)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .cannotPublish(why))
        }
        let model = PublishConfirmation()
        let published = Recorder()
        model.ask(ext, publish: { _ in published.count += 1 })
        model.confirm()
        XCTAssertEqual(published.count, 0, "a refused plan never publishes")
    }

    // MARK: - R1141-3: a work-folder name stable across launches (recorder only, nothing deleted)

    /// The literal pins the name across launches (String.hashValue is seeded per launch); the name passes
    /// the removal guard, which hands it to the recorder and deletes nothing.
    func testWorkNameIsStableAndPassesTheGuard() {
        let address = "https://github.com/example/tools/tree/main/hello"
        let name = RemoteInstaller.githubWorkName(repo: "tools", address: address)
        XCTAssertEqual(name, "prosper-ext-tools-2429cf1e5d792b81")
        XCTAssertEqual(RemoteInstaller.githubWorkName(repo: "tools", address: address + "/x"),
                       "prosper-ext-tools-673241f9b3074973", "another address, another folder")
        let temp = FileManager.default.temporaryDirectory
        var recorded: [String] = []
        XCTAssertTrue(RemoteInstaller.removeWorkFolder(temp.appendingPathComponent(name, isDirectory: true),
                                                       remove: { recorded.append($0.path) }))
        XCTAssertEqual(recorded, [temp.appendingPathComponent(name, isDirectory: true).path])
    }

    // MARK: - R1141-4: one install per work folder at a time (inside the row's own folder)

    /// While a download's folder is in use, a second extract of the same name is refused and the first
    /// folder stays whole; the cleanup frees the name for the next install.
    func testSecondInstallOfOneNameLeavesTheFirstFolderAlone() throws {
        let tmp = tempDir()
        let archive = ustar(["extension.toml"])
        let first = try RemoteInstaller.extract(archive, workName: "prosper-market-hello-1.0.0", tempRoot: tmp,
                                                stripTopLevel: false)
        let manifest = first.appendingPathComponent("extension.toml")
        XCTAssertThrowsError(try RemoteInstaller.extract(archive, workName: "prosper-market-hello-1.0.0", tempRoot: tmp,
                                                         stripTopLevel: false)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .extractFailed("this extension is already being installed"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path), "the second install cleared the first one's folder")
        let other = try RemoteInstaller.extract(archive, workName: "prosper-market-hello-1.0.1", tempRoot: tmp,
                                                stripTopLevel: false)
        RemoteInstaller.removeWorkFolder(holding: other, tempRoot: tmp)
        RemoteInstaller.removeWorkFolder(holding: first, tempRoot: tmp)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
        let again = try RemoteInstaller.extract(archive, workName: "prosper-market-hello-1.0.0", tempRoot: tmp,
                                                stripTopLevel: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.appendingPathComponent("extension.toml").path))
        RemoteInstaller.removeWorkFolder(holding: again, tempRoot: tmp)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
    }

    /// A failed extract frees its name and leaves no folder: bytes that do not unpack, then the same
    /// name extracts fine.
    func testFailedExtractFreesTheName() throws {
        let tmp = tempDir()
        let name = "prosper-market-hello-2.0.0"
        XCTAssertThrowsError(try RemoteInstaller.extract(Data("not an archive".utf8), workName: name, tempRoot: tmp,
                                                         stripTopLevel: false))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
        let ok = try RemoteInstaller.extract(ustar(["extension.toml"]), workName: name, tempRoot: tmp, stripTopLevel: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ok.appendingPathComponent("extension.toml").path))
        RemoteInstaller.removeWorkFolder(holding: ok, tempRoot: tmp)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.path), [])
    }

    // MARK: - R1182-l: a version the Marketplace would not list as written is refused before anything is packed

    private static func versionRefusal(_ shown: String) -> String {
        "Can't publish version \"\(shown)\": the Marketplace takes a version written like 1.2.0 (three numbers "
            + "joined by dots, then optionally - or + and a label), with nothing before or after it."
    }

    /// The pure rule and the plan's refusal, on literal versions: nothing is read, packed or sent. The literal plan leaves
    /// versionUnshown false (the flag is set only by the folder path: testARefusedVersionWithAnUnshownCharacterSaysSo).
    func testAVersionNotInTheListedFormIsRefused() {
        let refused: [(version: String, shown: String)] = [(" 1.2.0", " 1.2.0"), ("v1.2.0", "v1.2.0"), ("1.2", "1.2"), ("", ""),
                                                            ("1.2.0\n", "1.2.0"), ("1.2.0 ", "1.2.0 "), ("1.2.0.9", "1.2.0.9")]
        XCTAssertEqual(refused.count, 7)
        for row in refused {
            let bad = RemoteInstaller.badPublishVersion(row.version)
            XCTAssertEqual(bad, row.shown, row.version)
            XCTAssertEqual(RemoteInstaller.PublishPlan(members: ["./extension.toml"], badVersion: bad).refusal,
                           Self.versionRefusal(row.shown), row.version)
        }
        for version in ["1.2.0", "0.0.1", "10.20.30", "2.0.0-beta.1", "2.0.0+build.7"] {
            XCTAssertTrue(RemoteInstaller.badPublishVersion(version) == nil, version)
        }
        XCTAssertTrue(RemoteInstaller.PublishPlan(members: ["./extension.toml"]).refusal == nil)
    }

    /// The version a refusal shows is outside text: a direction override and a zero-width space are dropped, the rest cut at 32.
    func testARefusedVersionIsShownCleanedAndBounded() {
        let bad = RemoteInstaller.badPublishVersion("v1.2.0-\u{202E}x\u{200B}" + String(repeating: "a", count: 100))
        XCTAssertEqual(bad, "v1.2.0-x" + String(repeating: "a", count: 23) + "\u{2026}")
        let why = RemoteInstaller.PublishPlan(members: ["./extension.toml"], badVersion: bad).refusal ?? ""
        XCTAssertFalse(why.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{200B}" }, why)
    }

    /// The plan reads extension.toml's version from the folder it walks (inside this row's tempDir()); nothing is packed.
    func testThePlanReadsTheFoldersVersion() throws {
        for (version, refused) in [(" 1.2.0", true), ("1.2.0", false)] {
            let ext = try fixture(["init.lua"])
            try """
            [extension]
            id = "com.example.kit"
            name = "kit"
            title = "Kit"
            description = "A test extension"
            version = "\(version)"
            author = "Example Author"

            [extension.host]
            min_version = "2.0.0"
            api_level = 1

            [extension.entry]
            main = "init.lua"
            """.write(to: ext.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            let plan = RemoteInstaller.publishPlan(ext)
            XCTAssertEqual(plan.members, ["./extension.toml", "./init.lua"])
            XCTAssertEqual(plan.badVersion, refused ? " 1.2.0" : nil, version)
            XCTAssertEqual(plan.refusal, refused ? Self.versionRefusal(" 1.2.0") : nil, version)
        }
    }

    // MARK: - R1182-e: the folder's extension.toml must still hold what the upload lists (pure plan, this row's tempDir())

    /// An extension.toml for com.example.kit, each field in `change` given as TOML value text.
    private static func kitToml(_ change: [String: String] = [:], themes: Bool = false, apiLevel: Int = 1) -> String {
        let fields = [("id", "\"com.example.kit\""), ("name", "\"kit\""), ("title", "\"Kit\""),
                      ("description", "\"A test extension\""), ("version", "\"1.0.0\""), ("author", "\"Example Author\""),
                      ("icon", "\"icon.png\""), ("license", "\"MIT\"")]
        var text = "[extension]\n" + fields.map { "\($0.0) = \(change[$0.0] ?? $0.1)\n" }.joined()
        text += "\n[extension.host]\nmin_version = \"2.0.0\"\napi_level = \(apiLevel)\n\n[extension.entry]\nmain = \"init.lua\"\n"
        if themes { text += "\n[[contributes.themes]]\nid = \"com.example.kit.dark\"\ntitle = \"Dark\"\npath = \"dark.json\"\n" }
        return text
    }

    /// A folder in a fresh tempDir() of this row holding init.lua and `toml` as extension.toml.
    private func kitFolder(_ toml: String) throws -> URL {
        let ext = try fixture(["init.lua"])
        try toml.write(to: ext.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        return ext
    }

    private static func changedRefusal(_ fields: String) -> String {
        "Can't publish: this folder's extension.toml changed since the extension was listed (" + fields
            + "). Nothing was published. Press Publish again to open the list anew."
    }

    /// The record the row holds is the folder's manifest as loaded before the edit; the plan reads the folder again.
    /// Same manifest: no refusal. Each uploaded field edited afterwards: refused by name, with no value of it shown.
    func testUploadIsRefusedWhenTheFoldersManifestNoLongerMatchesTheRecord() throws {
        let ext = try kitFolder(Self.kitToml())
        let captured = try ExtensionLoader.load(directory: ext, isSystem: false, hostVersion: "0.0.0").manifest
        XCTAssertTrue(RemoteInstaller.publishPlan(ext).uploadRefusal(captured) == nil, "the same manifest was refused")
        let table: [(field: String, toml: String)] = [
            ("id", Self.kitToml(["id": "\"com.example.other\""])),
            ("version", Self.kitToml(["version": "\"1.0.1\""])),
            ("name", Self.kitToml(["name": "\"kit2\""])),
            ("title", Self.kitToml(["title": "\"Kit Two\""])),
            ("description", Self.kitToml(["description": "\"Another test extension\""])),
            ("author", Self.kitToml(["author": "\"Example Other\""])),
            ("icon", Self.kitToml(["icon": "\"other.png\""])),
            ("license", Self.kitToml(["license": "\"Apache-2.0\""])),
            ("themes", Self.kitToml(themes: true)),
            ("id, version", Self.kitToml(["id": "\"com.example.other\"", "version": "\"1.0.1\""])),
        ]
        XCTAssertEqual(table.count, 10)
        for row in table {
            try row.toml.write(to: ext.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            let plan = RemoteInstaller.publishPlan(ext)
            XCTAssertTrue(plan.refusal == nil, row.field)   // the list itself still offers the files
            XCTAssertEqual(plan.uploadRefusal(captured), Self.changedRefusal(row.field), row.field)
        }
    }

    /// A folder whose extension.toml no longer loads (one byte; an api_level this host lacks) refuses the upload with its
    /// own sentence; the list's own refusal stays none, as before. R1182-q2 is not built (TOMLGuardTests pins three
    /// decode sites): a bad version beside such an api_level is refused here, before any pack, but not for its version.
    func testUploadIsRefusedWhenTheFoldersManifestDoesNotLoad() throws {
        let ext = try kitFolder(Self.kitToml())
        let captured = try ExtensionLoader.load(directory: ext, isSystem: false, hostVersion: "0.0.0").manifest
        let unloaded = "Can't publish: this folder's extension.toml does not load as it is now, so it can't be checked "
            + "against what the upload lists. Nothing was published."
        for toml in ["x", Self.kitToml(apiLevel: 2), Self.kitToml(["version": "\" 1.2.0\""], apiLevel: 2)] {
            try toml.write(to: ext.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
            let plan = RemoteInstaller.publishPlan(ext)
            XCTAssertTrue(plan.manifest == nil && plan.badVersion == nil && plan.refusal == nil, toml)
            XCTAssertEqual(plan.uploadRefusal(captured), unloaded, toml)
        }
    }

    // MARK: - R1182-n: a refused version holding a character the cleaning drops is said to have one

    private static let unshownRefusal = "Can't publish this version: it has a character that cannot be shown. The Marketplace "
        + "takes a version written like 1.2.0 (three numbers joined by dots, then optionally - or + and a label), with nothing "
        + "before or after it."

    /// Read by the plan from a folder in this row's tempDir(); the versions are TOML escapes (a line feed, a direction
    /// override). A plain bad version keeps the R1182-l sentence word for word.
    func testARefusedVersionWithAnUnshownCharacterSaysSo() throws {
        let rows: [(version: String, unshown: Bool, shown: String)] = [("1.2.0\\n", true, "1.2.0"),
                                                                       ("1.2.0\\u202E", true, "1.2.0"),
                                                                       ("v1.2.0", false, "v1.2.0")]
        for row in rows {
            let plan = RemoteInstaller.publishPlan(try kitFolder(Self.kitToml(["version": "\"\(row.version)\""])))
            XCTAssertEqual(plan.badVersion, row.shown, row.version)
            XCTAssertEqual(plan.versionUnshown, row.unshown, row.version)
            XCTAssertEqual(plan.refusal, row.unshown ? Self.unshownRefusal : Self.versionRefusal(row.shown), row.version)
        }
        XCTAssertEqual(RemoteInstaller.PublishPlan(members: ["./extension.toml"], badVersion: "1.2.0", versionUnshown: true).refusal,
                       Self.unshownRefusal)
    }

    // MARK: - R1182-o: tar that cannot start says pack for a publish and unpack for a download

    /// A program path that does not exist inside this row's tempDir(): nothing runs. The unpack keeps its text byte for
    /// byte; the pack says it could not pack, then Foundation's launch error (one line, cleaned, at most 160).
    func testALaunchFailureSaysPackForAPublishAndUnpackForADownload() throws {
        let missing = tempDir().appendingPathComponent("no-such-tar").path
        var launch = ""
        XCTAssertThrowsError(try RemoteInstaller.runDraining(["-tf", "x"], path: missing, captureOut: true)) {
            guard case .extractFailed(let m)? = $0 as? RemoteInstaller.InstallError else { return XCTFail("got \($0)") }
            launch = m
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "Could not unpack the download: " + m)
        }
        XCTAssertTrue(launch.contains("no-such-tar") && !launch.contains("\n"), launch)
        XCTAssertThrowsError(try RemoteInstaller.runDraining(["-cf", "-", "."], path: missing, captureOut: true, packing: true)) {
            XCTAssertEqual($0 as? RemoteInstaller.InstallError, .cannotPublish("tar could not pack the folder: " + launch))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "tar could not pack the folder: " + launch)
        }
    }

    // MARK: - Helpers

    /// An extension folder in the row's own tempDir() holding a one-byte file at each relative path.
    private func fixture(_ files: [String]) throws -> URL {
        let ext = tempDir().appendingPathComponent("ext", isDirectory: true)
        for rel in files {
            let url = ext.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return ext
    }

    /// The member names of the packer's archive (given `plan`, or walking the folder), read back with tar -t
    /// from the row's own folder.
    private func packedMembers(_ ext: URL, plan: RemoteInstaller.PublishPlan? = nil) throws -> [String] {
        try tarList(try RemoteInstaller.packageForPublish(ext, plan: plan), ext)
    }

    /// The member names of a base64 archive, read back with tar -t from the row's own folder.
    private func tarList(_ blob: String, _ ext: URL) throws -> [String] {
        let tgz = ext.deletingLastPathComponent().appendingPathComponent("out.tgz")
        try XCTUnwrap(Data(base64Encoded: blob)).write(to: tgz)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-tzf", tgz.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The row's composition: the Publish button among the actions, the list under them.
    @MainActor
    private func row(_ model: PublishConfirmation, _ dir: URL,
                     publish: @escaping @MainActor (RemoteInstaller.PublishPlan) -> Void) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            HStack(spacing: sz(12)) {
                PublishButton(title: "Publish", help: "Publish this extension to the marketplace", dir: dir,
                              model: model, publish: publish)
            }
            PublishConfirmView(model: model)
        }
    }

    /// The narrowest row in the Settings pane: window sz(820) less the sidebar sz(218), its rule, the
    /// scroll's 2 x sz(26) and the section card's 2 x sz(16).
    private func paneRowWidth() -> CGFloat { sz(820) - sz(218) - 1 - 2 * sz(26) - 2 * sz(16) }

    private func press(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        guard o.responds(to: sel) else { return false }
        if let p = o as? NSAccessibilityProtocol { return p.accessibilityPerformPress() }
        _ = o.perform(sel)
        return true
    }

    /// Opens the list of the row `view` draws, ends the row with `hide`, brings it back with `show`: the row is
    /// new (appeared twice) and its list is closed. Never-shown window.
    @MainActor
    private func listEndsWithItsRow<V: View>(_ view: V, _ ext: URL, _ seen: Seen,
                                             hide: () -> Void, show: () -> Void) throws {
        let hosted = Hosted(view, width: paneRowWidth())
        defer { hosted.close() }
        let model = try XCTUnwrap(hosted.wait { _ in seen.model }, "the row did not appear")
        model.ask(ext, publish: { _ in })
        XCTAssertNotNil(hosted.wait { $0.first { $0.isButton("Publish 2 files") } }, "the list did not open")
        hide()
        XCTAssertNotNil(hosted.wait { items in seen.gone > 0 && !items.contains { $0.isButton("Publish") } ? true : nil },
                        "the row did not leave")
        show()
        let back = hosted.wait { items in seen.appeared > 1 && items.contains { $0.isButton("Publish") } ? seen.model : nil }
        XCTAssertTrue(back?.plan == nil && back != nil, "the row came back with its list open")
        XCTAssertFalse(hosted.items().contains { $0.isButton("Publish 2 files") }, "a list is drawn for the new row")
        XCTAssertFalse(hosted.window.isVisible, "never shown")
    }

    /// Lays out `window`'s content and runs the main run loop until `done`, or false after 5 s. Each pass drains
    /// its own autorelease pool, so an object the tree let go of is freed inside the wait.
    @MainActor
    private func spin(_ window: NSWindow?, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            autoreleasepool {
                window?.contentView?.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if done() { return true }
        } while Date() < deadline
        return false
    }

    /// A plain ustar archive of one-byte files (tar -xzf reads it uncompressed). From
    /// ExtensionWorkFolderCleanupTests, folders and links left out.
    private func ustar(_ names: [String]) -> Data {
        var out: [UInt8] = []
        for name in names {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, _ at: Int) { h.replaceSubrange(at..<at + s.utf8.count, with: Array(s.utf8)) }
            put(name, 0); put("0000644", 100); put("0000000", 108); put("0000000", 116)
            put(String(format: "%011lo", 1), 124); put("00000000000", 136); put("        ", 148)
            h[156] = UInt8(ascii: "0")
            put("ustar", 257); put("00", 263)
            put(String(format: "%06lo", h.reduce(0) { $0 + Int($1) }), 148)
            h[154] = 0
            out += h + [UInt8(ascii: "x")] + [UInt8](repeating: 0, count: 511)
        }
        return Data(out + [UInt8](repeating: 0, count: 1024))
    }
}

/// What a publish closure was asked to do (main actor, like the closures that write it).
@MainActor
private final class Recorder {
    var count = 0
    var plans: [RemoteInstaller.PublishPlan] = []   // #1160: the plans the confirmation handed over
}

/// Whether the row offers Publish, as the trusted, not-publishing condition does (main actor).
@MainActor
private final class Offer: ObservableObject { @Published var on = true }

/// The row's composition with the Publish button behind the row's condition, the list drawn outside it.
private struct OfferedRow: View {
    @ObservedObject var offer: Offer
    let model: PublishConfirmation
    let dir: URL
    let publish: @MainActor (RemoteInstaller.PublishPlan) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            HStack(spacing: sz(12)) {
                if offer.on { PublishButton(title: "Publish", help: "", dir: dir, model: model, publish: publish) }
            }
            PublishConfirmView(model: model)
        }
        .closesPublishList(model, offered: offer.on)   // #1174: as ExtensionRow closes it
    }
}

/// What a row that owns its list showed (main actor): its model once it appeared, and how often it came and went.
@MainActor
private final class Seen {
    weak var model: PublishConfirmation?
    var appeared = 0
    var gone = 0
}

/// A row owning its list model as ExtensionRow does (@StateObject), Publish offered, the list under the actions.
private struct OwnRow: View {
    let dir: URL
    let seen: Seen
    @StateObject private var model = PublishConfirmation()
    var body: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            HStack(spacing: sz(12)) {
                PublishButton(title: "Publish", help: "", dir: dir, model: model, publish: { _ in })
            }
            PublishConfirmView(model: model)
        }
        .closesPublishList(model, offered: true)
        .onAppear { seen.model = model; seen.appeared += 1 }
        .onDisappear { seen.gone += 1 }
    }
}

/// The installed ids, as the pane's ForEach lists them (main actor).
@MainActor
private final class Ids: ObservableObject { @Published var list = ["eu.example.one"] }

/// The installed list: one OwnRow per id, as installedList draws ExtensionRow.
private struct RowList: View {
    @ObservedObject var ids: Ids
    let dir: URL
    let seen: Seen
    var body: some View {
        VStack(alignment: .leading) { ForEach(ids.list, id: \.self) { _ in OwnRow(dir: dir, seen: seen) } }
    }
}

/// The Settings detail switching panes: the Extensions pane's row while `pane.on`, the Account pane otherwise.
private struct PaneSwitch: View {
    @ObservedObject var pane: Offer
    let dir: URL
    let seen: Seen
    var body: some View {
        if pane.on { OwnRow(dir: dir, seen: seen) } else { Text("Account") }
    }
}

/// The live Marketplace version a row has fetched, set by the row instead of the network (main actor).
@MainActor
private final class Live: ObservableObject { @Published var version: String? }

/// The row's publish part as ExtensionRow composes it: the real PublishActions among the actions (local
/// version 1.1, not publishing), the list under them.
private struct LiveRow: View {
    @ObservedObject var live: Live
    let model: PublishConfirmation
    let dir: URL
    let publish: @MainActor (RemoteInstaller.PublishPlan) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            HStack(spacing: sz(12)) {
                PublishActions(publishing: false, published: live.version, version: "1.1", dir: dir, model: model,
                               publish: publish)
            }
            PublishConfirmView(model: model)
        }
    }
}

/// One element of an AX client's walk. A plain Text reads as an AXStaticText whose value is its text.
private struct PublishAXItem {
    let object: NSObject
    let role: String, label: String, value: String, title: String, frame: CGRect
    var text: String { [label, value, title].first { !$0.isEmpty } ?? "" }
    func has(_ s: String) -> Bool { label == s || value == s || title == s }
    func isButton(_ name: String) -> Bool { role == "AXButton" && (label == name || title == name) }
}

/// A view in a never-shown borderless window, its accessibility tree built for this process only (as
/// an AX client's attribute write would ask); both attributes are put back on close. Main actor.
@MainActor
private final class Hosted {
    let window: NSWindow
    let host: NSView
    private let set = Selector(("accessibilitySetValue:forAttribute:"))
    private let attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]

    init<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil) {
        let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading))
        let size = CGSize(width: width, height: height ?? max(host.fittingSize.height, 240))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.host = host
        for a in attrs { NSApplication.shared.perform(set, with: NSNumber(value: true), with: a) }
    }

    func close() {
        for a in attrs { NSApplication.shared.perform(set, with: NSNumber(value: false), with: a) }
        window.close()
    }

    /// The first NSScrollView in the hosted view (a NeonScroll's).
    func scrollView() -> NSScrollView? {
        func find(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.lazy.compactMap(find).first }
        return find(host)
    }

    func items() -> [PublishAXItem] {
        var out: [PublishAXItem] = []
        walk(host, &out)
        return out
    }

    /// Lays out and reads the tree until `found` returns a value, or nil after 5 s.
    func wait<T>(_ found: ([PublishAXItem]) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let v = found(items()) { return v }
        } while Date() < deadline
        return nil
    }

    private func walk(_ e: Any, _ out: inout [PublishAXItem], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        let frame = o.responds(to: Selector(("accessibilityFrame")))
            ? (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero : .zero
        out.append(PublishAXItem(object: o, role: text("accessibilityRole"), label: text("accessibilityLabel"),
                                 value: text("accessibilityValue"), title: text("accessibilityTitle"), frame: frame))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(k, &out, depth: depth + 1) }
    }
}
