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
        let rule = /NSPasteboard\s*\.\s*`?general\b|generalPasteboard|kPasteboardClipboard|Apple CFPasteboard general|name:\s*(NSPasteboard\.Name\s*)?\.\s*`?general\b|NSPasteboard\s*[?!]?\s*=\s*\.\s*`?general\b|typealias\s+\w+\s*=\s*(AppKit\.)?NSPasteboard\b|\bpb(copy|paste)\b|(?i:\b(set|get)\s+the\s+clipboard\b)/
        let languages: Set<String> = ["swift", "m", "mm", "c", "h", "lua", "js"]
        var urls = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        urls.append(app.appendingPathComponent("plugin-host/plugin-host.js"))
        var offending: [String] = [], scanned = 0
        for url in urls where languages.contains(url.pathExtension) {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains(rule) && !url.path.hasSuffix("ProsperApp/Pasteboard.swift") {
                offending.append("\(url.path.replacingOccurrences(of: app.path + "/", with: "")):\(i + 1)")
            }
        }
        XCTAssertGreaterThan(scanned, 10, "scan found no sources at \(sources.path)")
        XCTAssertEqual(offending, [])
    }
}
