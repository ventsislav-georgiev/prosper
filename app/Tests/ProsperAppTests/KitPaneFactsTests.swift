import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// #918 S2: the kit pane's facts. Pure functions over fakes; the overrides row lists a hooks dir under the row's
/// tempDir(). Nothing is run.
final class KitPaneFactsTests: XCTestCase {
    func testRequirementsLookUpThePathAndRunNothing() {
        let present: Set<String> = ["/opt/example/bin/jq", "/Users/example/bin/node", "relative/python3"]
        var asked: [String] = []
        let got = KitPaneFacts.requirements(["jq", "node", "python3", "../jq", ""], path: "/Users/example/bin:relative::/opt/example/bin:") {
            asked.append($0)
            return present.contains($0)
        }
        XCTAssertEqual(got, [.init(name: "jq", found: true), .init(name: "node", found: true), .init(name: "python3", found: false),
                             .init(name: "../jq", found: false), .init(name: "", found: false)])
        XCTAssertTrue(asked.allSatisfy { $0.hasPrefix("/Users/example/bin/") || $0.hasPrefix("/opt/example/bin/") }, "absolute PATH entries only")
        XCTAssertFalse(asked.contains { $0.contains("..") }, "a name with a path is never looked up")
    }

    func testOverridesFollowTheRunnersRule() throws {
        let hooks = tempDir().appendingPathComponent("hooks", isDirectory: true).path
        let fm = FileManager.default
        try fm.createDirectory(atPath: hooks + "/dir.post", withIntermediateDirectories: true)
        let modes: [String: Int] = ["fmt.pre": 0o777, "fmt.post": 0o700, "gw.pre": 0o770, "lint.pre": 0o600, "notes.txt": 0o700, "bad name.pre": 0o700]
        for (n, m) in modes {
            let p = hooks + "/" + n
            try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: p))
            try fm.setAttributes([.posixPermissions: m], ofItemAtPath: p)
        }
        try fm.createSymbolicLink(atPath: hooks + "/lint.post", withDestinationPath: hooks + "/fmt.post")
        let dir = try KitPOSIXFS().openDir(hooks)
        XCTAssertEqual(KitPaneFacts.overrides(dir, uid: getuid()), [
            .init(name: "dir", point: .post, skipped: "not a regular file"),
            .init(name: "fmt", point: .post, skipped: nil),
            .init(name: "fmt", point: .pre, skipped: "group- or world-writable"),
            .init(name: "gw", point: .pre, skipped: "group- or world-writable"),
            .init(name: "lint", point: .post, skipped: "not a regular file"),
            .init(name: "lint", point: .pre, skipped: "not executable"),
        ])
        let other = KitPaneFacts.overrides(dir, uid: getuid() == 0 ? 1 : getuid() - 1) ?? []
        XCTAssertEqual(other.first { $0.name == "fmt" && $0.point == .post }?.skipped, "not yours")
    }

    func testInUseLines() {
        let now = Date()
        XCTAssertEqual(KitPaneFacts.inUse(.statusline, fired: now.addingTimeInterval(-60), now: now), "HUD running")
        XCTAssertEqual(KitPaneFacts.inUse(.statusline, fired: now.addingTimeInterval(-630), now: now), "last fired 10 min ago")
        XCTAssertEqual(KitPaneFacts.inUse(.statusline, fired: now.addingTimeInterval(-KitPaneFacts.hudWindow - 5), now: now), "last fired 2 min ago")
        XCTAssertEqual(KitPaneFacts.inUse(.hook, fired: now.addingTimeInterval(-90), now: now), "last fired 1 min ago")
        XCTAssertEqual(KitPaneFacts.inUse(.tools, fired: now.addingTimeInterval(60), now: now), "last fired 0 min ago")
        XCTAssertTrue(KitPaneFacts.inUse(.claudeMD, fired: now, now: now) == nil, "a claude-md piece has no runtime signal")
        XCTAssertTrue(KitPaneFacts.inUse(.hook, fired: nil, now: now) == nil, "never fired")
    }

    func testHooksDisabledIsReadOnlyFromATopLevelTrue() {
        func read(_ s: String) -> Bool { KitPaneFacts.hooksDisabled(Data(s.utf8)) }
        XCTAssertTrue(read(#"{"disableAllHooks": true, "model": "example"}"#))
        XCTAssertFalse(read(#"{"disableAllHooks": false}"#))
        XCTAssertFalse(read(#"{"hooks": {}}"#))
        XCTAssertFalse(read(#"{"disableAllHooks": tru"#))
        XCTAssertFalse(read(#"{"disableAllHooks": "true"}"#))
        XCTAssertFalse(read(#"[{"disableAllHooks": true}]"#))
        XCTAssertFalse(read(""))
    }
}
