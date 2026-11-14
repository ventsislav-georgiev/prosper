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
        model.ask(ext, publish: { published.count += 1 })
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
        model.ask(ext, publish: { published.count += 1 })
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
        let button = PublishButton(title: "Publish", help: "", dir: ext, model: model, publish: { published.count += 1 })
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
        let button = PublishButton(title: "Publish", help: "", dir: ext, model: model, publish: { published.count += 1 })
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
        let hosted = Hosted(row(model, ext, publish: { published.count += 1 }), width: paneRowWidth())
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
        model.ask(ext, publish: {})
        let hosted = Hosted(row(model, ext, publish: {}), width: paneRowWidth())
        defer { hosted.close() }
        let why = "Can't publish symbolic links (every install refuses them): x.lua"
        let items = hosted.wait { items in items.contains { $0.has(why) } && items.contains { $0.isButton("Cancel") } ? items : nil }
        XCTAssertNotNil(items, "the refusal or Cancel is not in the tree: "
                        + hosted.items().map { "\($0.role) \($0.text)" }.joined(separator: " | "))
        XCTAssertFalse((items ?? []).contains { $0.role == "AXButton" && $0.text.hasPrefix("Publish ") },
                       "a refused plan offers a publish")
    }

    /// The list closes when the row stops offering Publish (Untrust, a publish running, already live):
    /// the button leaves the tree, the list and its action go with it, and nothing is published.
    @MainActor
    func testListClosesWhenPublishIsNoLongerOffered() throws {
        let ext = try fixture(["extension.toml", "init.lua"])
        let model = PublishConfirmation()
        let offer = Offer()
        let published = Recorder()
        let hosted = Hosted(OfferedRow(offer: offer, model: model, dir: ext, publish: { published.count += 1 }),
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
                model.ask(dir, publish: {})
                let plan = try XCTUnwrap(model.plan)
                let lines = PublishConfirmation.lines(plan)
                let actions = (plan.refusal == nil ? [PublishConfirmation.actionTitle(plan)] : []) + ["Cancel"]
                let width = paneRowWidth()
                let hosted = Hosted(row(model, dir, publish: {}), width: width)
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

    /// The member names of the packer's archive, read back with tar -t from the row's own folder.
    private func packedMembers(_ ext: URL) throws -> [String] {
        let tgz = ext.deletingLastPathComponent().appendingPathComponent("out.tgz")
        try XCTUnwrap(Data(base64Encoded: try RemoteInstaller.packageForPublish(ext))).write(to: tgz)
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
    private func row(_ model: PublishConfirmation, _ dir: URL, publish: @escaping @MainActor () -> Void) -> some View {
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
private final class Recorder { var count = 0 }

/// Whether the row offers Publish, as the trusted, not-publishing condition does (main actor).
@MainActor
private final class Offer: ObservableObject { @Published var on = true }

/// The row's composition with the Publish button behind the row's condition, the list drawn outside it.
private struct OfferedRow: View {
    @ObservedObject var offer: Offer
    let model: PublishConfirmation
    let dir: URL
    let publish: @MainActor () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            HStack(spacing: sz(12)) {
                if offer.on { PublishButton(title: "Publish", help: "", dir: dir, model: model, publish: publish) }
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

    init<V: View>(_ view: V, width: CGFloat) {
        let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading))
        let size = CGSize(width: width, height: max(host.fittingSize.height, 240))
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
