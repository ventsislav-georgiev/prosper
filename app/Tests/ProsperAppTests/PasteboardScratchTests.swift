import AppKit
import XCTest
@testable import ProsperApp

/// #316: under XCTest the app's one pasteboard is a private per-process pasteboard, never the
/// user's clipboard. `.general` is never written here; only its identity and changeCount are read.
final class PasteboardScratchTests: XCTestCase {
    @MainActor
    func testPasteboardIsAPrivatePerProcessPasteboard() {
        guard Pasteboard.general !== NSPasteboard.general else {
            return XCTFail("Pasteboard.general is the user's clipboard under XCTest")
        }
        XCTAssertEqual(Pasteboard.general.name.rawValue, "eu.illegible.prosper.xctest.\(getpid())")
        let probe = "prosper.scratchProbe.\(UUID().uuidString)"
        let before = NSPasteboard.general.changeCount
        Pasteboard.general.clearContents()
        defer { Pasteboard.general.clearContents() }
        Pasteboard.general.setString(probe, forType: .string)
        XCTAssertEqual(Pasteboard.general.string(forType: .string), probe)
        XCTAssertEqual(NSPasteboard.general.changeCount, before)
    }

    /// ProsperApp/Pasteboard.swift is the only source in any target allowed to name the user's clipboard.
    /// #385 (QA #163): a pattern, not a literal: spaced or backticked `.general`, `NSPasteboard(name: .general)`
    /// and the raw "Apple CFPasteboard general" name, a typed `NSPasteboard = .general`, an NSPasteboard
    /// typealias, ObjC/C spellings, and pbcopy/pbpaste or AppleScript clipboard access (Process,
    /// osascript, Lua os.execute); over every source language under Sources plus the plugin host.
    func testOnlyPasteboardSwiftNamesNSPasteboardGeneral() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = app.appendingPathComponent("Sources")
        let rule = Self.makeRule()
        // AppleScript's write is always "set the clipboard to"; #843's Settings copy "set the clipboard while" is not one.
        XCTAssertTrue("set the clipboard to \"x\"".contains(rule) && "Get The Clipboard".contains(rule))
        XCTAssertFalse("Let sessions set the clipboard while you're viewing them".contains(rule))
        let languages: Set<String> = ["swift", "m", "mm", "c", "h", "lua", "js"]
        var urls = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        urls.append(app.appendingPathComponent("plugin-host/plugin-host.js"))
        var offending: [String] = [], scanned = 0
        for url in urls where languages.contains(url.pathExtension) {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            guard !url.path.hasSuffix("ProsperApp/Pasteboard.swift") else { continue }
            for n in Self.offendingLines(in: text, rule: rule) {
                offending.append("\(url.path.replacingOccurrences(of: app.path + "/", with: "")):\(n)")
            }
        }
        XCTAssertGreaterThan(scanned, 10, "scan found no sources at \(sources.path)")
        XCTAssertEqual(offending, [])
    }

    /// The row's pattern, built once per row by the caller (nothing is kept between rows).
    static func makeRule() -> some RegexComponent {
        /NSPasteboard\s*\.\s*`?general\b|generalPasteboard|kPasteboardClipboard|Apple CFPasteboard general|name:\s*(NSPasteboard\.Name\s*)?\.\s*`?general\b|NSPasteboard\s*[?!]?\s*=\s*\.\s*`?general\b|typealias\s+\w+\s*=\s*(AppKit\.)?NSPasteboard\b|\bpb(copy|paste)\b|(?i:\bset\s+the\s+clipboard\s+to\b|\bget\s+the\s+clipboard\b)/
    }

    /// 1-based numbers of the lines of `text` that hold `rule`. #1273: a file that holds none of the literals every
    /// alternative of the rule needs ("general", "kPasteboardClipboard", "pbcopy", "pbpaste", "NSPasteboard", and
    /// "clipboard" in any case for the two AppleScript alternatives) cannot hold a match, so it skips the per-line work.
    static func offendingLines(in text: String, rule: some RegexComponent) -> [Int] {
        let needles = ["general", "kPasteboardClipboard", "pbcopy", "pbpaste", "NSPasteboard"]
        guard needles.contains(where: { text.range(of: $0, options: .literal) != nil })
            || text.range(of: "clipboard", options: [.literal, .caseInsensitive]) != nil else { return [] }
        return text.components(separatedBy: "\n").enumerated()
            .filter { $0.element.contains(rule) }.map { $0.offset + 1 }
    }

    /// #1273: the per-file helper reports exactly the lines the old per-line loop reported (literal inputs).
    func testOffendingLinesHelperReportsTheForbiddenLines() {
        let rule = Self.makeRule()
        func lines(_ text: String) -> [Int] { Self.offendingLines(in: text, rule: rule) }
        XCTAssertEqual(lines("let a = 1\nlet p = NSPasteboard.general\nlet b = 2\n"), [2])
        XCTAssertEqual(lines("let a = NSPasteboard . `general`\nlet generalPasteboard = 1\nkPasteboardClipboard"), [1, 2, 3])
        // holds the prefilter literals, no match
        XCTAssertEqual(lines("general store\nthe clipboard notes\nNSPasteboardItem and pbcopyright\n"), [])
        XCTAssertEqual(lines("let x = 1\nlet y = 2"), [])
        // first line and last line, no trailing newline
        XCTAssertEqual(lines("pbcopy"), [1])
        XCTAssertEqual(lines("a\nb\npbpaste"), [3])
        XCTAssertEqual(lines("pbcopy | x\nmid\ntypealias PB = NSPasteboard"), [1, 3])
        // multi-byte characters before the match
        XCTAssertEqual(lines("caf\u{E9} \u{1F600}\n\u{E9}\u{E9} NSPasteboard.general\nx"), [2])
        XCTAssertEqual(lines("\u{E9}\u{E9} \u{1F600} NSPasteboard.general"), [1])
        // the case-insensitive AppleScript forms; the allow-listed Settings copy is not a match
        XCTAssertEqual(lines("x\nGet The Clipboard\nset the clipboard to \"x\""), [2, 3])
        XCTAssertEqual(lines("Let sessions set the clipboard while you're viewing them"), [])
    }

    /// #1273 rider: each input holds exactly one prefilter needle (kPasteboardClipboard also holds "clipboard" in
    /// another case), so dropping any one needle from the helper turns its line red.
    func testOffendingLinesHelperEachNeedleAloneStillScans() {
        let rule = Self.makeRule()
        for text in ["f(name: .general)", "Apple CFPasteboard general", "kPasteboardClipboard",
                     "typealias PB = AppKit.NSPasteboard", "pbcopy", "pbpaste", "get the clipboard"] {
            XCTAssertEqual(Self.offendingLines(in: text, rule: rule), [1], text)
        }
    }
}
