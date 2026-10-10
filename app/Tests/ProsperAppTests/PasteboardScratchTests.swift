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
    func testOnlyPasteboardSwiftNamesNSPasteboardGeneral() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offending: [String] = [], scanned = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains("NSPasteboard.general") && !url.path.hasSuffix("ProsperApp/Pasteboard.swift") {
                offending.append("\(url.path.replacingOccurrences(of: sources.path + "/", with: "")):\(i + 1)")
            }
        }
        XCTAssertGreaterThan(scanned, 10, "scan found no sources at \(sources.path)")
        XCTAssertEqual(offending, [])
    }
}
