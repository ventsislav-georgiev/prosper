import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

private final class SheetInertServices: ExtensionHostServices, @unchecked Sendable {
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
}

/// #919 S4: the Kits row, the install routing and the pre-install kit sheet. Offscreen only: views are laid out in an
/// NSHostingController or a borderless window that is never shown (AXTreeSupport); the prepare, install, discard,
/// one-click install and link opener are recorders (or, in two rows, a registry over the row's tempDir with a fake
/// download and listing). Never NSWorkspace, NSPasteboard.general, an alert or the network.
@MainActor
final class MarketKitSheetTests: XCTestCase {
    typealias Prepared = ExtensionRegistry.PreparedMarketInstall

    /// Records every seam call; `prepareError` makes prepare throw, `hold` keeps it waiting (bounded) until released.
    @MainActor
    final class Fake {
        var prepares: [(id: String, version: String, kind: String?)] = []
        var installs: [Prepared] = []
        var discards: [Prepared] = []
        var directs: [(id: String, version: String)] = []
        var opened: [URL] = []
        var prepareError: Error?
        var hold = false
        let dir: URL
        init(dir: URL) { self.dir = dir }

        var seams: MarketInstallSeams {
            MarketInstallSeams(
                prepare: { id, version, kind in
                    self.prepares.append((id, version, kind))
                    let deadline = Date().addingTimeInterval(5)
                    while self.hold && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
                    if let e = self.prepareError { throw e }
                    return Prepared(id: id, version: version, directory: self.dir)
                },
                install: { self.installs.append($0) },
                discard: { self.discards.append($0) },
                installDirect: { self.directs.append(($0, $1)) },
                contents: { _ in MarketKitContents(readme: ["# Calm", "Read [more](https://example.com/kit)."], summary: ["rules: a block"]) },
                openURL: { self.opened.append($0) })
        }
    }

    private let kitID = "com.example.kit.calm"

    private func pkg(_ id: String, kind: String?, title: String? = nil, summary: [String] = []) -> MarketClient.Package {
        MarketClient.Package(id: id, title: title ?? id, description: "A fixture.", author: "Example Org", icon: nil, license: nil,
                             latest_version: "1.0.0", downloads: 0, updated_at: 0, kind: kind,
                             preview: kind == "kit" ? MarketClient.Preview(kit: KitListingPreview(summary: summary, readme: "Calm.")) : nil)
    }

    private func fake() -> Fake { Fake(dir: tempDir().appendingPathComponent("download", isDirectory: true)) }

    /// Waits for the sheet's prepare (its own task, bounded by the fake's 5 s hold).
    private func prepared(_ i: MarketInstaller) async -> MarketKitSheetModel? {
        let m = i.kitSheet
        await m?.task?.value
        return m
    }

    private static func marks(_ s: String) -> Int {
        var most = 0, run = 0
        for u in s.unicodeScalars {
            let c = u.properties.generalCategory
            run = c == .nonspacingMark || c == .enclosingMark ? run + 1 : 0
            most = max(most, run)
        }
        return most
    }

    // MARK: the Kits row

    /// A kit row shows the KIT badge (by its VoiceOver label), the Unreviewed line and its summary lines on the AX tree;
    /// a theme row shows none of them.
    func testKitRowShowsBadgeUnreviewedAndSummaryOnTheTreeAThemeRowDoesNot() {
        let kit = pkg(kitID, kind: "kit", summary: ["rules: a block in CLAUDE.md", "guard: a PreToolUse hook", "tools: one", "hud: fourth"])
        let tree = AXTreeSupport.tree(MarketplacePackageTexts(pkg: kit).frame(width: 600, alignment: .leading),
                                      CGSize(width: 600, height: 300)) { $0.contains { $0.named(MarketKitText.badgeLabel) } }
        XCTAssertTrue(tree.contains { $0.named(MarketKitText.badgeLabel) && $0.frame.width > 0 }, "\(tree.map(\.names))")
        XCTAssertTrue(tree.contains { $0.named(MarketKitText.unreviewed) }, "\(tree.map(\.names))")
        XCTAssertTrue(tree.contains { $0.named("rules: a block in CLAUDE.md") })
        XCTAssertTrue(tree.contains { $0.named("tools: one") })
        XCTAssertFalse(tree.contains { $0.named("hud: fourth") }, "the row shows the first three summary lines only")

        let theme = pkg("com.example.theme", kind: "theme")
        let themeTree = AXTreeSupport.tree(MarketplacePackageTexts(pkg: theme).frame(width: 600, alignment: .leading),
                                           CGSize(width: 600, height: 300)) { $0.contains { $0.named("THEME") } }
        XCTAssertTrue(themeTree.contains { $0.named("THEME") }, "the theme row was walked: \(themeTree.map(\.names))")
        XCTAssertFalse(themeTree.contains { $0.named(MarketKitText.badgeLabel) || $0.named(MarketKitText.badge) })
        XCTAssertFalse(themeTree.contains { $0.named(MarketKitText.unreviewed) })
    }

    /// QA R1520-i1: a summary line with stacked combining marks and a right-to-left override is drawn through OutsideText
    /// (override dropped, marks capped at three, cut) and clipped; a long marked title too; the row fits its room at
    /// scale 0.85, 1 and 1.5.
    func testHostileSummaryLineStaysClippedAndInertAtEveryScale() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let stacked = String(repeating: "e\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}", count: 120)
        let hostile = "guard: \u{202E}" + stacked + "\u{202C} done"
        let shown = MarketKitText.lines([hostile, "second"], max: MarketKitText.rowSummaryLines)
        XCTAssertEqual(shown.count, 2)
        let first = shown.first ?? ""
        XCTAssertFalse(first.unicodeScalars.contains { LinkPolicy.bidiControls.contains($0.value) }, "a direction control survived")
        XCTAssertLessThanOrEqual(Self.marks(first), OutsideText.maxMarks)
        XCTAssertLessThanOrEqual(first.count, MarketKitText.lineMax)

        let kit = pkg(kitID, kind: "kit", title: stacked, summary: [hostile])
        let tree = AXTreeSupport.tree(MarketplacePackageTexts(pkg: kit).frame(width: 600, alignment: .leading),
                                      CGSize(width: 600, height: 300)) { $0.contains { $0.named(MarketKitText.unreviewed) } }
        // by scalars: "e" and "e" with its marks are different Characters, so String.hasPrefix would never match
        XCTAssertTrue(tree.contains { $0.names.contains { $0.unicodeScalars.starts(with: "guard: e".unicodeScalars) } },
                      "\(tree.map(\.names).count) nodes")
        for n in tree.flatMap(\.names) {
            XCTAssertFalse(n.unicodeScalars.contains { LinkPolicy.bidiControls.contains($0.value) }, "a raw direction control on the tree")
            XCTAssertLessThanOrEqual(Self.marks(n), OutsideText.maxMarks)
        }
        for scale in [0.85, 1.0, 1.5] as [CGFloat] {
            ThemeRuntime.scale = scale
            let width = 480 * scale
            let hc = NSHostingController(rootView: MarketplacePackageTexts(pkg: kit))
            hc.view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            hc.view.layoutSubtreeIfNeeded()
            let got = hc.sizeThatFits(in: CGSize(width: width, height: 100_000))
            XCTAssertLessThanOrEqual(got.width, width + 1, "wider than its room at scale \(scale)")
            XCTAssertLessThan(got.height, 260 * scale, "a clipped line grew the row at scale \(scale): \(got.height)")
        }
    }

    // MARK: install routing

    /// Install on a kit row opens the sheet and prepares with the listing's kind; nothing installs.
    func testKitInstallPreparesAndNeverInstallsDirectly() async {
        let f = fake()
        let i = MarketInstaller(seams: f.seams)
        i.install(pkg(kitID, kind: "kit"))
        let m = await prepared(i)
        XCTAssertTrue(m != nil, "no sheet")
        XCTAssertEqual(f.prepares.count, 1)
        XCTAssertEqual(f.prepares.last?.kind, "kit")
        XCTAssertEqual(f.prepares.last?.version, "1.0.0")
        XCTAssertTrue(f.directs.isEmpty, "a kit installed in one click")
        XCTAssertTrue(f.installs.isEmpty)
        XCTAssertEqual(m?.phase, .ready)
        XCTAssertEqual(m?.contents.summary, ["rules: a block"])
    }

    /// A theme and a plain extension keep their one-click install: installed directly, no sheet, no prepare.
    func testThemeAndExtensionInstallStayOneClick() async throws {
        let f = fake()
        let i = MarketInstaller(seams: f.seams)
        for p in [pkg("com.example.theme", kind: "theme"), pkg("com.example.plain", kind: "extension")] {
            i.install(p)
            XCTAssertTrue(i.kitSheet == nil)
            let deadline = Date().addingTimeInterval(5)
            while i.installingID != nil && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        XCTAssertEqual(f.directs.map(\.id), ["com.example.theme", "com.example.plain"])
        XCTAssertTrue(f.prepares.isEmpty)
        XCTAssertTrue(i.installError == nil)
    }

    // MARK: the sheet

    /// The sheet's Install installs the prepared folder once, then the close discards it; a second press does nothing.
    func testSheetInstallInstallsOnceThenDiscards() async {
        let f = fake()
        let i = MarketInstaller(seams: f.seams)
        i.install(pkg(kitID, kind: "kit"))
        let m = await prepared(i)
        i.installFromSheet()
        i.installFromSheet()
        m?.install()
        XCTAssertEqual(f.installs.count, 1)
        XCTAssertEqual(f.installs.last?.directory, f.dir)
        XCTAssertEqual(f.discards.count, 1)
        XCTAssertTrue(i.kitSheet == nil)
        XCTAssertEqual(m?.phase, .installed)
    }

    /// Cancel discards the prepared folder once; the window's close does too; a sheet closed while its download runs
    /// discards the late result and never shows Install.
    func testCancelAndWindowCloseDiscard() async {
        let f = fake()
        let i = MarketInstaller(seams: f.seams)
        i.install(pkg(kitID, kind: "kit"))
        _ = await prepared(i)
        i.closeSheet()   // Cancel
        XCTAssertEqual(f.discards.count, 1)
        i.closeSheet()
        XCTAssertEqual(f.discards.count, 1, "discarded once")

        i.install(pkg(kitID, kind: "kit"))
        _ = await prepared(i)
        i.closeSheet()   // the window's willClose calls this
        XCTAssertEqual(f.discards.count, 2)
        XCTAssertTrue(f.installs.isEmpty)

        f.hold = true
        i.install(pkg(kitID, kind: "kit"))
        let late = i.kitSheet
        i.closeSheet()
        f.hold = false
        await late?.task?.value
        XCTAssertEqual(f.discards.count, 3, "the download that ended after the close is discarded")
        XCTAssertEqual(late?.canInstall, false)
    }

    /// A refused prepare shows its sentence in the sheet and no Install button; a ready sheet shows Install (the control).
    func testRefusedPrepareShowsTheRefusalAndNoInstall() async {
        let f = fake()
        f.prepareError = ExtensionError.marketKitRefused(id: kitID, .previewMismatch)
        let i = MarketInstaller(seams: f.seams)
        i.install(pkg(kitID, kind: "kit"))
        guard let m = await prepared(i) else { return XCTFail("no sheet") }
        let want = MarketplaceRootView.installErrorText(ExtensionError.marketKitRefused(id: kitID, .previewMismatch))
        XCTAssertEqual(m.phase, .refused(want))
        XCTAssertFalse(m.canInstall)
        XCTAssertTrue(f.installs.isEmpty && f.discards.isEmpty, "a refused prepare holds no folder")
        let tree = AXTreeSupport.tree(MarketKitSheetView(model: m, onInstall: {}, onCancel: {}), CGSize(width: 600, height: 700)) {
            $0.contains { $0.reads("Cancel") }
        }
        XCTAssertTrue(tree.contains { $0.named(want) }, "\(tree.map(\.names))")
        XCTAssertTrue(tree.contains { $0.reads("Cancel") })
        XCTAssertFalse(tree.contains { $0.reads("Install") }, "Install offered on a refused kit")

        let ok = MarketInstaller(seams: fake().seams)
        ok.install(pkg(kitID, kind: "kit"))
        guard let ready = await prepared(ok) else { return XCTFail("no sheet") }
        let readyTree = AXTreeSupport.tree(MarketKitSheetView(model: ready, onInstall: {}, onCancel: {}), CGSize(width: 600, height: 700)) {
            $0.contains { $0.reads("Install") }
        }
        XCTAssertTrue(readyTree.contains { $0.reads("Install") }, "the control: a ready sheet offers Install")
        XCTAssertTrue(readyTree.contains { $0.named(MarketKitText.badgeLabel) })
        XCTAssertTrue(readyTree.contains { $0.named(MarketKitText.untrustedNote) })
    }

    /// README and Report kit links open through the seam only, and only http and https.
    func testReadmeLinksOpenThroughTheSeamOnlyForHttp() async {
        let f = fake()
        let i = MarketInstaller(seams: f.seams)
        i.install(pkg(kitID, kind: "kit"))
        guard let m = await prepared(i) else { return XCTFail("no sheet") }
        for s in ["https://example.com/kit", "HTTP://example.com/a", "mailto:someone@example.com", "file:///Users/example/x.md",
                  "javascript:alert(1)", "docs/setup.md", "#remove", "https://example.com/\u{202E}x", "ftp://example.com/x"] {
            if let u = URL(string: s) { m.follow(u) }
        }
        XCTAssertEqual(f.opened.map(\.absoluteString), ["https://example.com/kit", "HTTP://example.com/a"])
        let report = m.reportURL
        XCTAssertEqual(report?.scheme, "https")
        XCTAssertTrue(report?.absoluteString.contains("Report%20kit") == true, "\(String(describing: report))")
        if let report { m.follow(report) }
        XCTAssertEqual(f.opened.count, 3)
    }

    // MARK: the README text (QA R1527)

    /// m1/s1: a README with raw direction controls, a zero-width space and stacked marks, and the same as character
    /// references (numeric and named), read from the prepared folder: no unseen scalar and at most three marks per base
    /// reach the AttributedString handed to Text. A plain link line keeps its link (the parse still runs).
    func testHostileReadmeAndItsCharacterReferencesNeverReachTheText() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marks8 = String(repeating: "&#x301;", count: 8)
        let lines: [String] = [
            "# Calm \u{202E}kit\u{202C}",
            "raw \u{200B}zero e" + String(repeating: "\u{0301}", count: 8) + " end",
            "see &#x202E;kit&#x202C; here",
            "stack e" + marks8 + " end",
            "a&#10;b &#0; &#x200B;z",
            "named &rlm;x&ZeroWidthSpace;y&NewLine;z",
            "# Head &#x202E;ing",
            "Read [more](https://example.com/kit).",
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: dir.appendingPathComponent("README.md"))
        let contents = MarketKitContents.read(dir, manifest: nil)
        XCTAssertEqual(contents.readme.count, 8)
        for line in contents.readme {
            XCTAssertFalse(line.unicodeScalars.contains(where: OutsideText.isUnseen), "an unseen scalar in a README line")
            XCTAssertLessThanOrEqual(Self.marks(line), OutsideText.maxMarks)
        }
        for line in contents.readme {
            let drawn = String(MarketKitSheetView.readmeText(line).characters)
            let bad = drawn.unicodeScalars.filter(OutsideText.isUnseen).map { String($0.value, radix: 16) }
            XCTAssertTrue(bad.isEmpty, "unseen scalars \(bad) drawn from line \(contents.readme.firstIndex(of: line) ?? -1)")
            XCTAssertLessThanOrEqual(Self.marks(drawn), OutsideText.maxMarks)
        }
        // a reference the parse would decode is drawn as typed
        XCTAssertEqual(String(MarketKitSheetView.readmeText("see &#x202E;kit&#x202C; here").characters), "see &#x202E;kit&#x202C; here")
        let link = MarketKitSheetView.readmeText(contents.readme.last ?? "")
        XCTAssertEqual(link.runs.compactMap { $0.link }.map(\.absoluteString), ["https://example.com/kit"])
    }

    /// n2: a link whose text reads as a web address on another host is drawn as plain text; a link on its own host and a
    /// worded link keep their link.
    func testLinkTextNamingAnotherHostIsDrawnWithoutItsLink() {
        func links(_ s: String) -> [String] { MarketKitSheetView.readmeText(s).runs.compactMap { $0.link }.map(\.absoluteString) }
        XCTAssertEqual(links("[https://example.org](https://evil.example/x)"), [])
        XCTAssertEqual(links("go [example.org/docs](https://evil.example/x) now"), [])
        XCTAssertEqual(links("[example.*org*](https://evil.example/x)"), [], "judged over the whole link text")
        XCTAssertEqual(links("[Example.com/kit](https://example.com/kit)"), ["https://example.com/kit"])
        XCTAssertEqual(links("[the setup page](https://example.com/setup)"), ["https://example.com/setup"])
        XCTAssertEqual(String(MarketKitSheetView.readmeText("[https://example.org](https://evil.example/x)").characters),
                       "https://example.org")
    }

    /// R1534-s1: a whitespace reference other than U+0020 and a soft hyphen read as a space / nothing and keep the link.
    func testSpaceAndSoftHyphenReferencesKeepTheLine() {
        let forms = ["&nbsp;", "&ensp;", "&emsp;", "&thinsp;", "&#9;", "&#x00A0;"]
        XCTAssertEqual(forms.count, 6)
        for f in forms {
            let r = MarketKitSheetView.readmeText("Install\(f)it from [the docs](https://example.com/docs)")
            XCTAssertEqual(String(r.characters), "Install it from the docs", f)
            XCTAssertEqual(r.runs.compactMap { $0.link }.map(\.absoluteString), ["https://example.com/docs"], f)
        }
        let shy = MarketKitSheetView.readmeText("Inst&shy;all [the docs](https://example.com/docs)")
        XCTAssertEqual(String(shy.characters), "Install the docs")
        XCTAssertEqual(shy.runs.compactMap { $0.link }.count, 1)
    }

    /// R1534-n1: the ideographic full stops read as "." in a link text, so a mismatched host loses its link.
    func testIdeographicDotsInLinkTextAreComparedAsDots() {
        let dots = ["\u{3002}", "\u{FF0E}", "\u{FF61}"]
        XCTAssertEqual(dots.count, 3)
        for d in dots {
            let r = MarketKitSheetView.readmeText("[example\(d)org](https://evil.example/x)")
            XCTAssertEqual(r.runs.compactMap { $0.link }, [], "U+\(String(d.unicodeScalars.first!.value, radix: 16))")
            let ok = MarketKitSheetView.readmeText("[example\(d)org](https://example.org/x)")
            XCTAssertEqual(ok.runs.compactMap { $0.link }.count, 1)
        }
    }

    /// R1536-s1: a dot carrying a mark, U+2024 and U+FE52 still read as a dot, so the mismatched link is dropped.
    func testMarkedAndCompatibilityDotsInLinkTextAreComparedAsDots() {
        let forms = ["github.\u{301}com", "github\u{3002}\u{301}com", "github\u{2024}com", "github\u{FE52}com"]
        XCTAssertEqual(forms.count, 4)
        for f in forms {
            let r = MarketKitSheetView.readmeText("[\(f)](https://evil.example/x)")
            XCTAssertEqual(r.runs.compactMap { $0.link }, [], f.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
        let ok = MarketKitSheetView.readmeText("[github.com](https://github.com/x)")
        XCTAssertEqual(ok.runs.compactMap { $0.link }.count, 1)
    }

    /// n1: quit sends no window close; a sheet open at quit discards its work folder (the quit notification is posted to
    /// the row's own center; the app is never terminated).
    func testAppQuitDiscardsTheOpenSheetsFolder() async {
        let f = fake()
        let center = NotificationCenter()
        let i = MarketInstaller(seams: f.seams, center: center)
        i.install(pkg(kitID, kind: "kit"))
        _ = await prepared(i)
        XCTAssertTrue(f.discards.isEmpty)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(f.discards.count, 1)
        XCTAssertEqual(f.discards.last?.directory, f.dir)
        XCTAssertTrue(i.kitSheet == nil)
    }

    /// i1: the spinner shown while the kit downloads has a VoiceOver label.
    func testPreparingSpinnerHasAVoiceOverLabel() async {
        let f = fake()
        f.hold = true
        let i = MarketInstaller(seams: f.seams)
        i.install(pkg(kitID, kind: "kit"))
        guard let m = i.kitSheet else { return XCTFail("no sheet") }
        XCTAssertEqual(m.phase, .preparing)
        let tree = AXTreeSupport.tree(MarketKitSheetView(model: m, onInstall: {}, onCancel: {}), CGSize(width: 600, height: 700)) {
            $0.contains { $0.named(MarketKitText.preparingLabel) }
        }
        XCTAssertTrue(tree.contains { $0.named(MarketKitText.preparingLabel) }, "\(tree.map(\.names))")
        f.hold = false
        await m.task?.value
        i.closeSheet()
    }

    // MARK: through the registry (fake download and listing under the row's tempDir)

    private func registry(_ root: URL, source: URL, detail: MarketClient.PackageDetail) -> ExtensionRegistry {
        let r = ExtensionRegistry(systemDir: nil, userDir: root.appendingPathComponent("user", isDirectory: true), hostVersion: "9.0.0",
                                  defaults: scratchDefaults("kit-sheet"), services: SheetInertServices())
        r.discover()
        r.marketFetch = { _, _ in
            let dir = root.appendingPathComponent("download-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: dir)
            return dir
        }
        r.marketDetail = { _ in detail }
        r.marketIndex = { nil }
        return r
    }

    private func kitDetail(_ p: KitListingPreview) -> MarketClient.PackageDetail {
        MarketClient.PackageDetail(kind: "kit", latest_version: "1.0.0", preview: MarketClient.Preview(kit: p), status: "active")
    }

    /// #1495 review: a listing of kind "kit" over an archive that is not a kit is refused in the sheet (the prepare gets
    /// the listing's kind), no Install, nothing installed.
    func testListedKitOverANonKitArchiveIsRefusedInTheSheet() async throws {
        let root = tempDir()
        let plainID = "com.example.plain"
        let source = root.appendingPathComponent("served/plain", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data((KitFixture.head.replacingOccurrences(of: "dev.example.kit.calm-agent", with: plainID)
                  .replacingOccurrences(of: "\"calm-agent\"", with: "\"plain\"")).utf8)
            .write(to: source.appendingPathComponent("extension.toml"))
        try Data("return {}\n".utf8).write(to: source.appendingPathComponent("init.lua"))
        let r = registry(root, source: source, detail: kitDetail(KitListingPreview(summary: ["rules: a block"], readme: "Calm.")))
        let i = MarketInstaller(seams: .live(r))
        i.install(pkg(plainID, kind: "kit"))
        guard let m = await prepared(i) else { return XCTFail("no sheet") }
        let want = MarketplaceRootView.installErrorText(ExtensionError.marketKitRefused(id: plainID, .listedKitNotKit))
        XCTAssertEqual(m.phase, .refused(want))
        XCTAssertFalse(m.canInstall)
        i.installFromSheet()
        XCTAssertTrue(r.record(id: plainID) == nil, "installed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("user/\(plainID)").path))
    }

    /// The sheet shows the downloaded kit's own README and the summary generated from it; its Install installs the kit
    /// untrusted.
    func testSheetShowsTheTarballReadmeAndSummaryAndInstallsUntrusted() async throws {
        let root = tempDir()
        let f = try makeKitDir(under: root.appendingPathComponent("served", isDirectory: true))
        try f.write("extension.toml", KitFixture.head + "\n" + KitFixture.kit + "\n")
        guard case .ok(let v) = try makeKitDir(under: tempDir()).validate() else { return XCTFail("the fixture kit is refused") }
        let listing = KitListingPreview.make(v, readme: KitDirFixture.readme)
        let r = registry(root, source: f.kit, detail: kitDetail(listing))
        let extID = "dev.example.kit.calm-agent"
        let i = MarketInstaller(seams: .live(r))
        i.install(pkg(extID, kind: "kit"))
        guard let m = await prepared(i) else { return XCTFail("no sheet") }
        XCTAssertEqual(m.phase, .ready)
        XCTAssertEqual(m.contents.summary, MarketKitText.lines(listing.summary, max: MarketKitText.sheetSummaryLines))
        XCTAssertFalse(m.contents.summary.isEmpty)
        XCTAssertTrue(m.contents.readme.contains("## Remove"), "the full README, past its first section")
        i.installFromSheet()
        let rec = r.record(id: extID)
        XCTAssertTrue(rec != nil, "not installed")
        XCTAssertEqual(rec?.trusted, false)
        XCTAssertTrue(i.kitSheet == nil)
    }
}
