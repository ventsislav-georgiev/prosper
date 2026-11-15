import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// Inert host services: the registry here only installs into the row's own tempDir().
private final class OutsideRowInertServices: ExtensionHostServices, @unchecked Sendable {
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

/// #1251 third dispatch: an extension's own texts in the Settings extension list and the Marketplace rows are drawn
/// verbatim through ExtensionRowText (OutsideText.shown with a bound per field), and the list's title line is clipped.
/// Made-up manifests and packages only (com.example ids, "Example Author"): no fetch, no publish, no network; the registry
/// lives wholly in the row's tempDir(). Views sit in never-shown windows through AXTreeSupport (flags on this process
/// only, put back) or draw through ImageRenderer; no event is posted; a link is never opened. Every row runs on main.
@MainActor
final class ExtensionOutsideRowTextTests: XCTestCase {
    private static let letters = "abcdefghijklmnopqrstuvwxyz"

    private static func stacked(_ letters: String, _ marks: [String], _ n: Int = 24) -> String {
        letters.map { String($0) + marks.map { String(repeating: $0, count: n) }.joined() }.joined()
    }

    /// Compared scalar by scalar: String == is canonical equivalence and would hide a dropped or reordered mark.
    private static func scalars(_ s: String?) -> [UInt32] { (s ?? "").unicodeScalars.map(\.value) }

    private static func marks(_ c: Character) -> Int {
        c.unicodeScalars.filter { let g = $0.properties.generalCategory; return g == .nonspacingMark || g == .enclosingMark }.count
    }

    // MARK: the function, on literals

    func testTheFunctionCleansAndBoundsEachField() throws {
        let t = ExtensionRowText.title(Self.stacked(Self.letters, ["\u{0301}"]), id: "com.example.kit")
        XCTAssertEqual(t.count, Self.letters.count)
        XCTAssertTrue(t.allSatisfy { Self.marks($0) <= 3 }, "\(Self.scalars(t).count) scalars")
        XCTAssertEqual(String(t.compactMap { $0.unicodeScalars.first.map(Character.init) }), Self.letters, "every letter, in order")
        XCTAssertEqual(Self.scalars(ExtensionRowText.title(Self.stacked("ab", ["\u{0301}"]), id: "com.example.kit")),
                       Self.scalars("a\u{0301}\u{0301}\u{0301}b\u{0301}\u{0301}\u{0301}"))
        // a direction override and a zero-width character are dropped
        XCTAssertEqual(Self.scalars(ExtensionRowText.title("Ki\u{202E}t\u{200B}", id: "com.example.kit")), Self.scalars("Kit"))
        // a 500-character description is cut at 300
        let d = ExtensionRowText.description(String(repeating: "x", count: 500))
        XCTAssertEqual(d.count, ExtensionRowText.descriptionMax)
        XCTAssertTrue(d.hasSuffix("\u{2026}"))
        // nothing visible left: the id, then the fixed word
        for empty in ["", "   ", "\u{202E}\u{200B}", String(repeating: "\u{0301}", count: 24)] {
            XCTAssertEqual(ExtensionRowText.title(empty, id: "com.example.kit"), "com.example.kit", "\(Self.scalars(empty))")
        }
        XCTAssertEqual(ExtensionRowText.title("", id: ""), "Extension")
        XCTAssertEqual(ExtensionRowText.title("\u{0301}", id: "\u{200B}"), "Extension")
        XCTAssertEqual(Self.scalars(ExtensionRowText.title("", id: "com.example\u{202E}.kit")), Self.scalars("com.example.kit"))
        // ordinary titles unchanged
        XCTAssertEqual(Self.scalars(ExtensionRowText.title("Plain Kit", id: "x")), Self.scalars("Plain Kit"))
        XCTAssertEqual(Self.scalars(ExtensionRowText.title("Caf\u{0065}\u{0301}", id: "x")), Self.scalars("Caf\u{0065}\u{0301}"))
        // the other fields
        XCTAssertEqual(ExtensionRowText.version("1.0.0\u{202E}"), "v1.0.0")
        XCTAssertEqual(ExtensionRowText.version(String(repeating: "1", count: 100)).count, 1 + ExtensionRowText.versionMax)
        XCTAssertEqual(ExtensionRowText.byLine("Example\u{200B} Author"), "by Example Author")
        XCTAssertEqual(ExtensionRowText.byLine(""), "by ", "an empty author reads as before")
        XCTAssertEqual(ExtensionRowText.byLine(String(repeating: "a", count: 200)).count, 3 + ExtensionRowText.authorMax)
        XCTAssertEqual(ExtensionRowText.help(String(repeating: "a", count: 300)).count, ExtensionRowText.helpMax)
        XCTAssertEqual(ExtensionRowText.help("Dusk\u{202E} \u{00B7} dark"), "Dusk \u{00B7} dark", "the swatch tooltip")
    }

    // MARK: the Markdown fact

    /// A String interpolated into a Text's string literal (a LocalizedStringKey) is a format argument: its Markdown is
    /// not parsed, it reads literally and carries no link. Control: the same text written as the literal itself is
    /// parsed (the brackets and the target are gone from what the tree reads). The link is never opened.
    func testInterpolatedMarkdownIsNotInterpreted() {
        let author = "[x](https://example.com)"
        let size = CGSize(width: 400, height: 60)
        let interpolated = AXTreeSupport.tree(Text("by \(author)"), size) { $0.contains { $0.named(prefix: "by") } }
        let control = AXTreeSupport.tree(Text("by [y](https://example.com)"), size) { $0.contains { $0.named(prefix: "by") } }
        fputs("ort1251 fact interpolated: \(interpolated.map { "\($0.role) \($0.names)" })\n", stderr)
        fputs("ort1251 fact literal: \(control.map { "\($0.role) \($0.names)" })\n", stderr)
        XCTAssertTrue(interpolated.contains { $0.named("by [x](https://example.com)") }, "the interpolated value reads literally")
        XCTAssertFalse(interpolated.contains { $0.role == "AXLink" }, "no link from an interpolated value")
        XCTAssertTrue(control.contains { $0.named(prefix: "by") }, "control: the literal draws")
        XCTAssertFalse(control.contains { $0.names.contains { $0.contains("](") } },
                       "control: Markdown in the literal itself is parsed, or the method proves nothing")
    }

    // MARK: the hosted row (the method of ExtensionRowCloseWiringTests)

    private func manifest(id: String, title: String, description: String, author: String) -> String {
        """
        [extension]
        id = "\(id)"
        name = "kit"
        title = "\(title)"
        description = "\(description)"
        version = "1.0.0"
        author = "\(author)"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"
        """
    }

    /// A registry in the row's tempDir() with one extension installed from a folder beside it, left UNTRUSTED.
    private func untrustedRecord(_ name: String, title: String, description: String = "A test extension",
                                 author: String = "Example Author") throws -> (ExtensionRegistry, ExtensionRecord) {
        let user = tempDir().appendingPathComponent("user")
        let source = user.deletingLastPathComponent().appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try manifest(id: "com.example.kit", title: title, description: description, author: author)
            .write(to: source.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "function noop() end".write(to: source.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let registry = ExtensionRegistry(systemDir: nil, userDir: user, hostVersion: "2.0.0",
                                         defaults: scratchDefaults(name), services: OutsideRowInertServices())
        let installed = try registry.installLocal(from: source)
        return (registry, ExtensionRecord(loaded: installed.loaded, enabled: false, trusted: false))
    }

    private static let notLoaded = "Not loaded. Review the files, then Trust to load its commands."

    /// The row's tree at 760 pt: the fetch and the upload are inert fakes (Sendable; the fetch runs in the row's task
    /// off the main actor, the upload is never called: an untrusted row offers no Publish).
    private func rowTree(_ registry: ExtensionRegistry, _ record: ExtensionRecord) -> [AXTreeNode] {
        let row = ExtensionRow(registry: registry, record: record, fetchVersion: { _ in nil }, publishCall: { _, _, _, _ in })
            .frame(width: 760, alignment: .leading)
        return AXTreeSupport.tree(row, CGSize(width: 760, height: 400)) {
            $0.contains { $0.named("UNTRUSTED") } && $0.contains { $0.named(Self.notLoaded) }
        }
    }

    /// An UNTRUSTED record with a hostile title, description and author: the tree holds the cleaned texts, no raw
    /// override or zero-width character, no character with more than three marks, the UNTRUSTED badge and the warning.
    func testAnUntrustedRowWithHostileTextsShowsThemCleaned() throws {
        let title = "a" + String(repeating: "\u{0301}", count: 24) + "\u{202E}b\u{200B}c" + String(repeating: "\u{0301}", count: 24)
        let description = "d\u{202E}" + String(repeating: "x", count: 500)
        let (registry, record) = try untrustedRecord("outsiderow-hostile", title: title, description: description,
                                                     author: "Example\u{200B} Author\u{202E}")
        XCTAssertEqual(record.manifest.extension.title, title, "the decoded title is the raw value")
        let tree = rowTree(registry, record)
        let wantTitle = "a\u{0301}\u{0301}\u{0301}bc\u{0301}\u{0301}\u{0301}"
        let titleNode = try XCTUnwrap(tree.first { $0.named(wantTitle) }, "\(tree.map(\.names))")
        XCTAssertTrue(titleNode.names.contains { Self.scalars($0) == Self.scalars(wantTitle) }, "\(titleNode.names.map(Self.scalars))")
        XCTAssertTrue(tree.contains { $0.named("d" + String(repeating: "x", count: 298) + "\u{2026}") }, "the description, cut at 300")
        XCTAssertTrue(tree.contains { $0.named("by Example Author") }, "the author line")
        XCTAssertTrue(tree.contains { $0.named("v1.0.0") })
        for node in tree {
            for n in node.names {
                XCTAssertFalse(n.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{200B}" }, "raw unseen scalar in \(Self.scalars(n))")
                XCTAssertTrue(n.allSatisfy { Self.marks($0) <= 3 }, "more than three marks in \(Self.scalars(n).count) scalars")
            }
        }
        XCTAssertTrue(tree.contains { $0.named("UNTRUSTED") && $0.frame.width > 0 }, "the badge")
        XCTAssertTrue(tree.contains { $0.named(Self.notLoaded) }, "the warning line")
        XCTAssertTrue(tree.contains { $0.role == "AXButton" && $0.named("Trust") }, "the Trust button")
    }

    /// A title of 80 wide letters truncates first: the UNTRUSTED badge and the version keep the widths they have under
    /// "Kit", inside the row, and the warning line under them stays where it is.
    func testALongTitleLeavesTheBadgeAndTheVersionTheirSize() throws {
        let (r1, plain) = try untrustedRecord("outsiderow-plain", title: "Kit")
        let (r2, long) = try untrustedRecord("outsiderow-long", title: String(repeating: "W", count: 80))
        let a = rowTree(r1, plain), b = rowTree(r2, long)
        let row = try XCTUnwrap(b.first, "the host")
        for label in ["UNTRUSTED", "v1.0.0", Self.notLoaded] {
            let before = try XCTUnwrap(a.first { $0.named(label) && $0.frame.width > 0 }, "plain: \(label)")
            let after = try XCTUnwrap(b.first { $0.named(label) && $0.frame.width > 0 }, "long: \(label): \(b.map(\.names))")
            fputs("ort1251 fact \(label): plain \(before.frame), long \(after.frame), row \(row.frame)\n", stderr)
            XCTAssertEqual(after.frame.width, before.frame.width, accuracy: 0.5, "\(label) keeps its width")
            XCTAssertEqual(after.frame.height, before.frame.height, accuracy: 0.5, "\(label) keeps its height")
            XCTAssertEqual(after.frame.minY, before.frame.minY, accuracy: 0.5, "\(label) stays on its line")
            XCTAssertLessThanOrEqual(after.frame.maxX, row.frame.maxX + 0.5, "\(label) inside the row")
        }
        let titleNode = try XCTUnwrap(b.first { $0.named(String(repeating: "W", count: 80)) }, "the long title")
        let badge = try XCTUnwrap(b.first { $0.named("UNTRUSTED") })
        XCTAssertLessThanOrEqual(titleNode.frame.maxX, badge.frame.minX + 0.5, "the title ends before the badge")
    }

    // MARK: the clip, rendered offscreen (the method of ManagedConfigConsentMarksTests)

    /// The title piece with a RAW hostile string on a black field 40 pt above and below: no pixel row outside the
    /// title's own bounds differs from the background. The control, the same string in a plain unclipped Text with the
    /// same font, must put ink there, or the method proves nothing. Images bounded at 800 x 200 points, scale 1.
    func testTheTitleLineDrawsNothingOutsideItsOwnBounds() throws {
        let hostile = Self.stacked(Self.letters, ["\u{0323}", "\u{0301}"])
        let width: CGFloat = 400, pad: CGFloat = 40
        let ref = try XCTUnwrap(ImageRenderer(content: Color.black.frame(width: 4, height: 4)).cgImage)
        let refBytes = [UInt8](try XCTUnwrap(ref.dataProvider?.data as Data?))
        let bpp = ref.bitsPerPixel / 8
        XCTAssertEqual(ref.bitsPerPixel, 32)
        let background = Array(refBytes.prefix(bpp))
        // main actor (ImageRenderer and NSHostingView are main-actor); called only from this row
        @MainActor func ink<V: View>(_ line: V, _ tag: String) throws -> (outside: Int, inside: Int) {
            let h = NSHostingView(rootView: line.frame(width: width)).fittingSize.height
            let r = ImageRenderer(content: VStack(spacing: 0) {
                Color.clear.frame(height: pad)
                line.frame(width: width)
                Color.clear.frame(height: pad)
            }.foregroundStyle(Color.white).background(Color.black))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage, tag)
            XCTAssertLessThanOrEqual(cg.width, 800, tag)
            XCTAssertLessThanOrEqual(cg.height, 200, tag)
            XCTAssertEqual(cg.bitsPerPixel, ref.bitsPerPixel, tag)
            XCTAssertEqual(cg.bitmapInfo, ref.bitmapInfo, tag)
            let bytes = [UInt8](try XCTUnwrap(cg.dataProvider?.data as Data?, tag))
            let row = cg.bytesPerRow
            guard cg.bitsPerPixel == ref.bitsPerPixel, bytes.count >= row * cg.height, row >= cg.width * bpp else {
                XCTFail("\(tag): unexpected bitmap \(cg.width)x\(cg.height) row \(row) bytes \(bytes.count)")
                return (0, 0)
            }
            let top = Int(pad), bottom = Int((pad + h).rounded(.up))
            var outside = 0, inside = 0
            for y in 0..<cg.height {
                let start = y * row
                let drawn = (0..<cg.width).contains { x in !bytes[(start + x * bpp)..<(start + x * bpp + bpp)].elementsEqual(background) }
                guard drawn else { continue }
                if y < top || y >= bottom { outside += 1 } else { inside += 1 }
            }
            fputs("ort1251 fact \(tag): image \(cg.width)x\(cg.height), line box rows \(top)..<\(bottom) (h \(h)), ink rows outside \(outside), inside \(inside)\n", stderr)
            return (outside, inside)
        }
        let control = try ink(Text(verbatim: hostile).font(Neon.font(.body)).bold().lineLimit(1), "control")
        XCTAssertGreaterThan(control.inside, 0, "control: the line draws")
        XCTAssertGreaterThan(control.outside, 0, "control: no ink seen outside an unclipped line box: the measuring method is wrong, not the clip")
        guard control.outside > 0 else { return }
        let title = try ink(ExtensionRowTitle(text: hostile), "title")
        XCTAssertGreaterThan(title.inside, 0, "title: the line draws")
        XCTAssertEqual(title.outside, 0, "title: ink outside its own bounds")
    }

    // MARK: the Marketplace row's texts, from a made-up package (never a fetch)

    /// The package texts view of the Marketplace row (the window itself loads the index on appear, so it is not
    /// hosted): cleaned title, description and author line on the tree, the THEME badge and the version beside them.
    func testAMarketplacePackageWithHostileTextsShowsThemCleaned() throws {
        let pkg = MarketClient.Package(
            id: "com.example.kit", title: Self.stacked("ab", ["\u{0301}"]) + "\u{202E}c",
            description: "d\u{200B}" + String(repeating: "x", count: 500), author: "Example\u{200B} Author\u{202E}",
            icon: nil, license: nil, latest_version: "1.0.0\u{202E}", downloads: 3, updated_at: 0, kind: "theme", preview: nil)
        let tree = AXTreeSupport.tree(MarketplacePackageTexts(pkg: pkg).frame(width: 600, alignment: .leading),
                                      CGSize(width: 600, height: 200)) { $0.contains { $0.named("THEME") } }
        let wantTitle = "a\u{0301}\u{0301}\u{0301}b\u{0301}\u{0301}\u{0301}c"
        let titleNode = try XCTUnwrap(tree.first { $0.named(wantTitle) }, "\(tree.map(\.names))")
        XCTAssertTrue(titleNode.names.contains { Self.scalars($0) == Self.scalars(wantTitle) }, "\(titleNode.names.map(Self.scalars))")
        XCTAssertTrue(tree.contains { $0.named("d" + String(repeating: "x", count: 298) + "\u{2026}") }, "the description, cut at 300")
        XCTAssertTrue(tree.contains { $0.named("by Example Author \u{00B7} 3 downloads") }, "\(tree.map(\.names))")
        XCTAssertTrue(tree.contains { $0.named("v1.0.0") })
        XCTAssertTrue(tree.contains { $0.named("THEME") && $0.frame.width > 0 })
        for node in tree {
            for n in node.names {
                XCTAssertFalse(n.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{200B}" }, "raw unseen scalar in \(Self.scalars(n))")
                XCTAssertTrue(n.allSatisfy { Self.marks($0) <= 3 }, "more than three marks in \(Self.scalars(n).count) scalars")
            }
        }
    }
}
