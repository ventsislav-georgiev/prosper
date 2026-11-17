import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1239: the Agent Sessions header's title slot under the Rename field, read from the real accessibility tree. While
/// renaming, the parts leave the tree by their own flag (AgentHeaderRenameHidden), not only by the slot's opacity 0
/// (which drops a transparent view on macOS 27 and is not verified on macOS 14 to 26). Offscreen only: every view is
/// hosted in a window that is never shown (AXTreeSupport), the flags are this process's own and put back, no event is
/// posted, no menu is opened. Every row runs on the main actor; the poll closures run on it too, inside the row.
final class AgentWindowHeaderRenameTreeTests: XCTestCase {
    static let now: TimeInterval = 1_800_000_000
    static let title = "claude-example-1 title"
    static let path = "/Users/example/api"
    static let marker = "marker-text"

    /// An idle session ten minutes old with 3 agents: the slot holds the title (path as its value), the chip's glyph and
    /// words, the count group, a separator and the age.
    @MainActor
    func session() -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: "claude-example-1"), alias: Self.title,
                     activity: Self.now - 600, state: .idle, agents: 3, meta: nil, version: "1.30.0",
                     claudeSessionID: nil, transcriptPath: nil)
    }

    @MainActor
    func row(_ s: AgentSession) -> AgentSidebar.Row {
        AgentSidebar.Row(id: .live(s.key), title: Self.title, state: s.state, detail: s.state.label,
                         age: AgentIsland.age(of: s, now: Self.now), prs: [], agents: 3, session: s)
    }

    @MainActor
    func header(_ s: AgentSession, rename: AgentRenameEdit?, mode: AgentPaneMode = .terminal) -> AgentSessionHeader {
        AgentSessionHeader(row: row(s), session: s, cwd: Self.path, open: {}, rename: rename, mode: mode)
    }

    /// Every word a part of the slot is read by when not renaming (Terminal mode).
    @MainActor
    func slotWords(_ s: AgentSession) throws -> [String] {
        let ago = try XCTUnwrap(AgentIsland.ago(row(s).age))
        XCTAssertEqual(ago, "10m ago")
        return [Self.title, Self.path, AgentState.idle.glyph, AgentStateChip(state: .idle).label, "3 agents", ago]
    }

    /// The words that must never be read: the separators (their own hidden) and the width chips (hidden()).
    @MainActor
    var neverRead: [String] {
        ["\u{00B7}", "3", AgentStateChip.endedLabel] + AgentState.allCases.filter { $0 != .idle }.map(\.label)
    }

    /// The belt's own half, alone, on a plain fully opaque Text: present with renaming false, absent with renaming true.
    /// No opacity is involved, so only the flag can take it out: this row fails if the modifier stops following renaming.
    @MainActor
    func testRenameHiddenFlagAloneTakesAnOpaqueTextOutOfTheTree() {
        let word = "claude-example-1"
        for renaming in [false, true] {
            let view = VStack {
                Text(verbatim: Self.marker)
                Text(verbatim: word).modifier(AgentHeaderRenameHidden(renaming: renaming))
            }
            let tree = AXTreeSupport.tree(view, CGSize(width: 240, height: 60)) { t in
                t.contains { $0.reads(Self.marker) } && (renaming || t.contains { $0.reads(word) })
            }
            XCTAssertTrue(tree.contains { $0.reads(Self.marker) }, "the tree was built (renaming \(renaming))")
            XCTAssertEqual(tree.contains { $0.reads(word) }, !renaming, "read exactly when not renaming")
        }
    }

    /// The slot's own line (slotLine, Terminal mode, with the counts and age) hosted WITHOUT the slot's opacity (that sits
    /// one level up, on titleSlot): at full opacity every part is read when not renaming and none while renaming, so a
    /// part that loses the belt is read here. The separators and the width chips are never read (their own hidden stays
    /// in force under a part's hidden(false), the #1120 trap).
    @MainActor
    func testSlotLineAtFullOpacityHidesEveryPartWhileRenaming() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let s = session()
        let words = try slotWords(s)
        for renaming in [false, true] {
            let edit = renaming ? AgentRenameEdit(key: s.key, text: "api-qa") : nil
            let h = header(s, rename: edit)
            let view = VStack(alignment: .leading) { Text(verbatim: Self.marker); h.slotLine(folder: true) }
            let tree = AXTreeSupport.tree(view, CGSize(width: 900, height: 80)) { t in
                t.contains { $0.reads(Self.marker) } && (renaming || words.allSatisfy { w in t.contains { $0.reads(w) } })
            }
            let tag = "renaming \(renaming)"
            print("#1239 slotLine tree \(tag): " + tree.filter { !$0.ignored && !$0.names.isEmpty }.map { "\($0.role) \($0.names)" }
                .joined(separator: ", "))
            XCTAssertTrue(tree.contains { $0.reads(Self.marker) }, "the tree was built (\(tag))")
            for w in words { XCTAssertEqual(tree.contains { $0.reads(w) }, !renaming, "\(w) (\(tag))") }
            for w in neverRead { XCTAssertFalse(tree.contains { $0.reads(w) }, "\(w) is never read (\(tag))") }
            if renaming {
                XCTAssertEqual(tree.filter { !$0.ignored && !$0.names.isEmpty && !$0.reads(Self.marker) }.map(\.names), [],
                               "nothing of the slot is read while renaming")
            }
        }
    }

    /// The real header, one host, renaming started and ended in place (the root view swapped, nothing else): every part
    /// read before, none while the field lies over them (the field is, with its label), all of them again after, at the
    /// same frames. The separators are never read.
    @MainActor
    func testRealHeaderPartsLeaveAndComeBackWithRenaming() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let s = session()
        let words = try slotWords(s)
        let size = CGSize(width: 900, height: 80)
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (win, host) = AXTreeSupport.hosted(header(s, rename: nil), size)
        defer { win.close() }
        var before: [String: CGRect] = [:]
        for (step, renaming) in [false, true, false].enumerated() {
            host.rootView = header(s, rename: renaming ? AgentRenameEdit(key: s.key, text: "api-qa") : nil)
            let tree = AXTreeSupport.poll(host) { t in
                renaming ? t.contains { $0.role == "AXTextField" } : words.allSatisfy { w in t.contains { $0.reads(w) } }
            }
            let tag = "step \(step) renaming \(renaming)"
            for w in words { XCTAssertEqual(tree.contains { $0.reads(w) }, !renaming, "\(w) (\(tag))") }
            // R1239-1: not renaming, each word is read by exactly one node (a second copy under a part's hidden(false) would show).
            if !renaming { for w in words { XCTAssertEqual(tree.filter { $0.reads(w) }.count, 1, "\(w) is read exactly once (\(tag))") } }
            for w in neverRead { XCTAssertFalse(tree.contains { $0.reads(w) }, "\(w) is never read (\(tag))") }
            let fields = tree.filter { $0.role == "AXTextField" && !$0.ignored }
            XCTAssertEqual(fields.count, renaming ? 1 : 0, "the field (\(tag))")
            if renaming {
                XCTAssertEqual(fields.first?.reads("api-qa"), true, "the field reads its text")
                let field = views(host, AgentRenameTextField.self)
                XCTAssertEqual(field.count, 1, "one field")
                XCTAssertEqual(field.first?.accessibilityLabel(), "Session title", "with its label")
            }
            // Fixed slots: each part comes back at the frame it had before renaming.
            for w in words where !renaming {
                let f = tree.first { $0.reads(w) }?.frame
                if step == 0 { before[w] = f } else { XCTAssertEqual(f, before[w], "\(w) at the same frame after renaming") }
            }
            XCTAssertFalse(win.isVisible, "never on screen")
        }
    }

    /// N1159-a: the tree built LATE, as when VoiceOver starts with the window already open: the header is hosted and laid
    /// out with the flags as found, then the flags go on (AXTreeSupport.axOn) and the walk reads the title with its path.
    /// The flags are put back to what they were before (axOn's restore), checked here.
    @MainActor
    func testHeaderTitleIsReadWhenTheTreeIsBuiltAfterHosting() {
        let s = session()
        let size = CGSize(width: 900, height: 80)
        let prior = AXTreeSupport.flags()
        let (win, host) = AXTreeSupport.hosted(header(s, rename: nil, mode: .transcript), size)
        defer { win.close() }
        host.layoutSubtreeIfNeeded()   // built and laid out before any flag is turned on
        let restore = AXTreeSupport.axOn()
        let tree = AXTreeSupport.poll(host) { t in t.contains { $0.reads(Self.title) } }
        restore()
        let title = tree.filter { $0.reads(Self.title) }
        XCTAssertEqual(title.count, 1, "the title is read once")
        XCTAssertEqual(title.first?.value, Self.path, "with the path as its value")
        XCTAssertEqual(AXTreeSupport.flags(), prior, "the flags are back as found")
        XCTAssertFalse(win.isVisible, "never on screen")
    }

    @MainActor
    private func views<T: NSView>(_ v: NSView, _ t: T.Type) -> [T] {
        ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views($0, t) }
    }
}
