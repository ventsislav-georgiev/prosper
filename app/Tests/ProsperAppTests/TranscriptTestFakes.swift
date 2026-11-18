import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

// #1471 b: test fakes moved out of the deleted Transcript test files (TranscriptJumpTests, TranscriptChapterListTests,
// AgentWindowVerbosityTests); the X-ray and outline rows still use them. Fakes only: no dch, nothing shown.

/// #904 fixtures: a fake transcript file in tempDir() and a standalone model that reads it inline (no watch, no timer,
/// no dch). Turn i is "Prompt i", a Bash call "make i" with its result, and "Done i": blocks 3i, 3i+1, 3i+2.
@MainActor
enum JumpFixture {
    static func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) + Data("\n".utf8) }
    static func entry(_ type: String, _ extra: [String: Any]) -> [String: Any] {
        ["type": type, "sessionId": "s-1", "version": "2.1.300"].merging(extra) { $1 }
    }
    static func user(_ text: String) -> [String: Any] { entry("user", ["message": ["role": "user", "content": text]]) }
    static func say(_ text: String) -> [String: Any] {
        entry("assistant", ["message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }
    static func bash(_ id: String, _ cmd: String) -> [[String: Any]] {
        [entry("assistant", ["message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": "Bash",
                                                                             "input": ["command": cmd]]]]]),
         entry("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]],
                        "toolUseResult": ["stdout": "ok", "stderr": ""]])]
    }
    static func turns(_ n: Int, from: Int = 0) -> [[String: Any]] {
        (from..<from + n).flatMap { i in [user("Prompt \(i)")] + bash("c\(i)", "make \(i)") + [say("Done \(i)")] }
    }
    static func write(_ url: URL, _ entries: [[String: Any]]) throws { try entries.map(line).reduce(Data(), +).write(to: url) }
    static func append(_ url: URL, _ entries: [[String: Any]]) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: entries.map(line).reduce(Data(), +))
        try h.close()
    }
    static func model(_ url: URL) -> AgentTranscriptModel {
        let m = AgentTranscriptModel()
        m.offMain = { $0() }
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/tmp/dch-test", name: "api"), dchVersion: "1.30.0",
                                       dchState: "idle", sessionId: "0b7c2f3e-1111-2222-3333-444455556666",
                                       transcriptPath: url.path))
        m.start()
        m.showAnyway = true
        return m
    }
}

/// #1319 rows: a presenter that never shows anything. It records each present and close and hosts the content in an
/// NSHostingView inside a borderless window that is never shown, ordered front or made key.
@MainActor
final class FakeCardPresenter: XrayCardPresenter {
    private(set) var presents = 0, closes = 0
    private(set) var size: CGSize?
    private(set) weak var anchor: NSView?
    private(set) var window: NSWindow?
    private var closed: (@MainActor () -> Void)?

    var isShown: Bool { closed != nil }

    func present(_ content: AnyView, size: CGSize, anchor: NSView, closed: @escaping @MainActor () -> Void) {
        presents += 1
        self.size = size
        self.anchor = anchor
        self.closed = closed
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        window = w
    }

    func close() {
        closes += 1
        let f = closed
        closed = nil
        window?.close()
        window = nil
        f?()
    }
}

extension AgentWindowD1Tests {
    func kind(_ b: TranscriptBlock) -> String {
        switch b.body {
        case .user: "user"
        case .assistant: "assistant"
        case .thinking: "thinking"
        case .image: "image"
        case .bash: "bash"
        case .diff: "diff"
        case .read: "read"
        case .search: "search"
        case .compaction: "compaction"
        case .notice: "notice"
        case .thread: "thread"
        case .command: "command"
        case .card(let t, _, _, let raw, _): raw == nil ? "card(\(t))" : "unknown"
        case .failed: "failed"
        }
    }
}
