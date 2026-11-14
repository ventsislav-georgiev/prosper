import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1103's review pictures, in a file of their own so the same probe runs on the tree before the change.
extension AgentWindowD1Tests {
    /// Offscreen PNGs for the operator, skipped unless PROSPER_HEADER_PNG_DIR is set: the header in both modes with a
    /// long title and a long path at 0.7, 0.85 and 1.0, light and dark, on the window's backdrop, and the whole window
    /// in both modes at 1.0. PROSPER_HEADER_PHASE (before/after) prefixes the names. The heights print as numbers.
    /// #1120 (QA 845 INFO-6): unset, it skips before it builds anything and writes nothing anywhere. Set, it writes its
    /// PNGs into that directory and never removes them: the directory is the caller's, and so is cleaning it.
    @MainActor
    func testAgentSessionHeaderReviewPictures() throws {
        guard let dir = ProcessInfo.processInfo.environment["PROSPER_HEADER_PNG_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("#1103 review pictures: set PROSPER_HEADER_PNG_DIR")
        }
        let phase = ProcessInfo.processInfo.environment["PROSPER_HEADER_PHASE"] ?? "run"
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette) = saved }
        let a = session("prosper-ios", .working, ago: 200,
                        alias: "prosper-ios release with a very long session name that truncates at the tail")
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let m = windowModel(st)
        m.setVisible(true)
        defer { m.close() }
        m.select(.live(a.key))
        let row = try XCTUnwrap(m.selectedRow)
        let path = "/Users/example/projects/prosper/app/Sources/ProsperApp/AgentWindow/Header/Long/Path"
        let todos = AgentTodos(items: (0..<7).map { .init(text: "task \($0)", status: $0 < 3 ? "completed" : "pending") })
        var log: [String] = []
        func write(_ rep: NSBitmapImageRep, _ name: String) throws {
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("\(phase)-\(name).png"))
        }
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved.1 : Self.lightPalette
            for scale: CGFloat in [0.7, 0.85, 1.0] {
                ThemeRuntime.scale = scale
                let room = 1000 * scale - sz(290) - 1
                for mode in [AgentPaneMode.terminal, .transcript] {
                    let h = AgentSessionHeader(row: row, session: a, cwd: path, open: {}, level: .constant(.default), todos: todos,
                                               store: st, mode: mode, setMode: { _ in })
                    let fit = NSHostingView(rootView: h.frame(width: room)).fittingSize.height
                    let name = "\(mode == .terminal ? "terminal" : "transcript")-\(dark ? "dark" : "light")-\(scale)"
                    if dark { log.append(String(format: "HEIGHT %@ %@ scale %.2f width %.0f h=%.1f", phase, name, scale, room, fit)) }
                    try autoreleasepool { try write(try render(h, size: CGSize(width: room, height: fit), dark: dark, margin: 0), name) }
                }
            }
        }
        // The whole window (the sidebar beside the header) at 1.0, both modes, light and dark: the demo model with a
        // fake terminal (nothing is spawned).
        ThemeRuntime.scale = 1.0
        try withModePref {
            let (wm, wst) = demoModel(Self.corpus.appendingPathComponent("2.1.318/b-compaction-agents-more-tools.jsonl"))
            _ = fakeTerminal(wm)
            defer { wm.close() }
            let s = try XCTUnwrap(wst.sessions.first { $0.name == "prosper" })
            for dark in [true, false] {
                ThemeRuntime.palette = dark ? saved.1 : Self.lightPalette
                for mode in [AgentPaneMode.terminal, .transcript] {
                    wm.setMode(mode, for: s)
                    try autoreleasepool {
                        try write(try render(AgentWindowRootView(model: wm, scrolls: false), size: CGSize(width: 1000, height: 680),
                                             dark: dark, margin: 0),
                                  "window-\(mode == .terminal ? "terminal" : "transcript")-\(dark ? "dark" : "light")-1.0")
                    }
                }
            }
        }
        print("#1103 review heights\n" + log.joined(separator: "\n"))
    }
}
