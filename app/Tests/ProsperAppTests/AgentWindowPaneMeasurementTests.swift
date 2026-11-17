import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1197 (#831 B1 step 6, spec 11.3 and 15 B1): measurements only, recorded as "#1197 ..." lines in the log; nothing here
/// asserts a measured number. Heavy-only. Fakes only: /tmp/dch-test sessions, transcripts written under tempDir() from literal
/// text, no dch, no window shown (never-shown borderless windows, no event posted). Every row saves the split gate, sets it
/// and restores it in a defer. Every closure here runs on the main actor unless its comment says otherwise.
extension AgentWindowD1Tests {
    final class PaneWakeBox { var polls = 0, watchEvents = 0 }

    /// The process's own counters (task_info TASK_POWER_INFO, getrusage): read by the test process about itself.
    struct PaneProcessSample { var interrupt: UInt64, idle: UInt64, timer1: UInt64, timer2: UInt64, cpuMicros: UInt64 }

    static func paneProcessSample() -> PaneProcessSample? {
        var info = task_power_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count) }
        }
        var u = rusage()
        guard kr == KERN_SUCCESS, getrusage(RUSAGE_SELF, &u) == 0, (0..<(1 << 31)).contains(u.ru_utime.tv_sec),
              (0..<(1 << 31)).contains(u.ru_stime.tv_sec) else { return nil }
        let micros = { (t: timeval) in UInt64(t.tv_sec) * 1_000_000 + UInt64(max(0, t.tv_usec)) }
        return PaneProcessSample(interrupt: info.task_interrupt_wakeups, idle: info.task_platform_idle_wakeups,
                                 timer1: info.task_timer_wakeups_bin_1, timer2: info.task_timer_wakeups_bin_2,
                                 cpuMicros: micros(u.ru_utime) + micros(u.ru_stime))
    }

    /// phys_footprint in bytes (as TextViewerLayoutTests and LlamaInlineEngineTests read it); 0 on failure.
    static func paneFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Counters only go up; a wrap or a failed read reads as 0, never a trap.
    static func up(_ a: UInt64, _ b: UInt64) -> UInt64 { b >= a ? b - a : 0 }

    static func mib(_ bytes: Int) -> String { String(format: "%.2f", Double(bytes) / 1_048_576) }

    /// MEASUREMENT 1 (spec 11.3): idle wakeups with 1 and then 6 shown transcript panes, each over a bounded 10 s window of
    /// real time (the thing measured is time-driven: a measurement, not a wait for a condition). The model alone, never a
    /// window: the tick timers, the watches and the age clock all live in the model (AgentTranscriptModel.start, the age
    /// clock in setVisible), so a drawn window adds view work but no other timer. Product cadence: the 2 s tick, the real
    /// io queue, the real TranscriptWatch, the 30 s age clock. Counted through existing seams: each idle tick's poll hands one
    /// job to `offMain` (counted, then given to the product's io queue), each watch event goes through `makeWatch`'s callback.
    @MainActor
    func testPaneMeasurementIdleWakeupsAtOneAndSixTranscriptPanesOver10sEach() throws {
        try requireHeavyTests()
        let gate = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        let names = ["p1", "p2", "p3", "p4", "p5", "p6"]
        let urls = try names.map { try transcriptFile($0) }
        var fires: [Int: Double] = [:]
        for n in [1, 6] {
            let pairs = Array(zip(names, urls).prefix(n))
            let st = store(pairs.map { session($0.0, .idle, path: $0.1.path) })
            let m = windowModel(st)
            defer { m.close() }
            let box = PaneWakeBox()
            m.ageInterval = 30   // the product's age clock (windowModel sets 3600)
            // Runs on main, from syncRuntimes. The tick interval stays the product's 2 s.
            m.onNewRuntime = { r in
                // Called on main by poll(); the job itself runs on the product's io queue.
                r.transcript.offMain = { job in box.polls += 1; AgentTranscriptModel.io.async(execute: job) }
                // The real kqueue watch; its callback runs on main (TranscriptWatch's source queue).
                r.transcript.makeWatch = { path, change in TranscriptWatch(path: path, onChange: { box.watchEvents += 1; change() }) }
            }
            m.paneArea = Self.wideArea
            m.adopt(paneLayout(pairs.map { paneTarget($0.0) }))
            m.setVisible(true)
            XCTAssertEqual(m.runtimes.values.filter { $0.transcript.running }.count, n, "\(n) panes run")
            box.polls = 0   // the first read was handed off in setVisible: the window counts ticks only
            box.watchEvents = 0
            let p0 = Self.paneProcessSample()
            let start = Date(), end = start.addingTimeInterval(10)
            while Date() < end { RunLoop.main.run(until: end) }
            let secs = Date().timeIntervalSince(start)
            let p1 = Self.paneProcessSample()
            let perSec = Double(box.polls) / secs
            fires[n] = perSec
            var line = "#1197 wakeups panes=\(n) window=\(String(format: "%.2f", secs))s tickPolls=\(box.polls) "
                + "perSec=\(String(format: "%.2f", perSec)) perPanePerSec=\(String(format: "%.3f", perSec / Double(n))) "
                + "watchEvents=\(box.watchEvents) blocks=\(m.runtimes.values.map { $0.transcript.blocks.count }.reduce(0, +))"
            if let a = p0, let b = p1 {
                line += " process: interruptWakeups=\(Self.up(a.interrupt, b.interrupt)) idleWakeups=\(Self.up(a.idle, b.idle))"
                    + " timerBin1=\(Self.up(a.timer1, b.timer1)) timerBin2=\(Self.up(a.timer2, b.timer2))"
                    + " cpuMs=\(Self.up(a.cpuMicros, b.cpuMicros) / 1000)"
            } else {
                line += " process: task_info(TASK_POWER_INFO) or getrusage unavailable"
            }
            print(line)
            XCTAssertTrue(perSec.isFinite, "recorded")
        }
        if let one = fires[1], let six = fires[6], one > 0 {
            print("#1197 wakeups ratio six/one=\(String(format: "%.2f", six / one)) (6.00 = six times one pane)")
        }
    }

    /// MEASUREMENT 2 (QA INFO-3, spec 15 B1): phys_footprint with 1 pane holding 2000 blocks, then 6 panes each holding 2000
    /// (a second model, the first kept so its pages are not reused), then 3 of the 6 Ended (their kept, suspended blocks).
    /// The fixture is built here from literal text (no 2000-block fixture exists under Tests/Fixtures). Before the 6-pane
    /// step the row predicts its bytes from the one-pane figure and does not start it above 48 MiB.
    @MainActor
    func testPaneMeasurementMemoryPerPaneWith2000BlocksAtOneAndSixPanesEndedIncluded() throws {
        try requireHeavyTests()
        let gate = AgentPaneLayout.splitsEnabled
        defer { AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        let names = ["m1", "m2", "m3", "m4", "m5", "m6"]
        // About 430 bytes a line, 2000 lines: about 0.86 MB a file, inside the product's 1 MiB first page.
        let text = String(repeating: "lorem ipsum ", count: 25)
        let urls = try names.map { name -> URL in
            try transcriptFile(name, (0..<2000).map { say("\(name) block \($0): \(text)") })
        }
        func model(_ n: Int) -> (AgentWindowModel, AgentIslandStore) {
            let pairs = Array(zip(names, urls).prefix(n))
            let st = store(pairs.map { session($0.0, .idle, path: $0.1.path) })
            let m = windowModel(st)   // inline reads, fake watch, 3600 s tick: the blocks only
            m.paneArea = Self.wideArea
            m.adopt(paneLayout(pairs.map { paneTarget($0.0) }))
            m.setVisible(true)
            return (m, st)
        }
        func blocks(_ m: AgentWindowModel) -> [Int] { m.runtimes.values.map { $0.transcript.blocks.count } }
        let f0 = Self.paneFootprint()
        let (one, _) = model(1)
        defer { one.close() }
        XCTAssertEqual(blocks(one), [2000], "the fixture gives 2000 blocks")
        let f1 = Self.paneFootprint()
        let d1 = f1 - f0
        let predicted = 6 * max(d1, 0)
        print("#1197 memory step=one-pane footprint0=\(Self.mib(f0))MiB footprint1=\(Self.mib(f1))MiB delta=\(Self.mib(d1))MiB "
              + "predicted-six=\(Self.mib(predicted))MiB")
        guard f0 > 0, f1 > 0, predicted <= 48 << 20 else {
            print("#1197 memory step=six-panes NOT STARTED (predicted over 48 MiB or no footprint)")
            return
        }
        let (six, st6) = model(6)
        defer { six.close() }
        XCTAssertEqual(blocks(six).filter { $0 == 2000 }.count, 6, "six panes of 2000 blocks")
        let f6 = Self.paneFootprint()
        let d6 = f6 - f1
        st6.sessions = st6.sessions   // a publish while all six show: their last live sights (4.1a)
        st6.sessions = Array(st6.sessions.prefix(3))   // m4, m5, m6 end: Ended panes keep their blocks suspended
        let ended = six.runtimes.values.filter { $0.ended != nil }
        XCTAssertEqual(ended.filter { $0.transcript.suspended && $0.transcript.blocks.count == 2000 }.count, 3, "3 Ended, kept")
        let fE = Self.paneFootprint()
        let dE = fE - f6
        let ratio = d1 > 0 ? Double(d6) / Double(d1) : .nan
        let total = f1 > 0 ? Double(f6) / Double(f1) : .nan
        print("#1197 memory step=six-panes footprint6=\(Self.mib(f6))MiB delta6=\(Self.mib(d6))MiB perPane=\(Self.mib(d6 / 6))MiB "
              + "ratio-delta6/delta1=\(String(format: "%.2f", ratio)) ratio-footprint6/footprint1=\(String(format: "%.3f", total))")
        print("#1197 memory step=three-ended footprintE=\(Self.mib(fE))MiB deltaFromSix=\(Self.mib(dE))MiB "
              + "keptBlocks=\(ended.map { $0.transcript.blocks.count }.reduce(0, +)) liveBlocks="
              + "\(six.runtimes.values.filter { $0.ended == nil }.map { $0.transcript.blocks.count }.reduce(0, +))")
    }

    /// Rider (a) for entry 900, facts only: with the split gate on, the sidebar's "Agent Sessions" and the session header's
    /// title at 0.7, 0.85 and 1.0 (Transcript mode), from the real accessibility frames of a never-shown window. Recorded,
    /// not asserted (the gate is off in the product; #1103 F2's row asserts the gate-off line).
    @MainActor
    func testPaneMeasurementGateOnTitleLinesAtEveryScale() throws {
        try requireHeavyTests()
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        _ = ThemeStore.shared   // its init sets ThemeRuntime.scale: built before the first pass (see #1103 F2's row)
        let saved = ThemeRuntime.scale, gate = AgentPaneLayout.splitsEnabled
        defer { ThemeRuntime.scale = saved; AgentPaneLayout.splitsEnabled = gate }
        AgentPaneLayout.splitsEnabled = true
        try withModePref {
            let (wm, wst) = demoModel(Self.corpus.appendingPathComponent("2.1.318/b-compaction-agents-more-tools.jsonl"))
            _ = fakeTerminal(wm)
            defer { wm.close() }
            let s = try XCTUnwrap(wst.sessions.first { $0.name == "prosper" })
            wm.setMode(.transcript, for: s)
            for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
            for scale: CGFloat in [0.7, 0.85, 1.0] {
                ThemeRuntime.scale = scale
                let title = try XCTUnwrap(wm.selectedRow?.title)
                let size = CGSize(width: 1000 * scale, height: 680 * scale), edge = AgentWindowModel.fullSidebarWidth
                let host = NSHostingView(rootView: AgentWindowRootView(model: wm, scrolls: false)
                    .frame(width: size.width, height: size.height, alignment: .top))
                host.frame = CGRect(origin: .zero, size: size)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
                win.isReleasedWhenClosed = false
                win.contentView = host
                defer { win.contentView = nil; win.close() }
                var side: CGRect?, head: CGRect?
                let deadline = Date().addingTimeInterval(5)   // until both titles are in the tree, bounded
                repeat {
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    var found: [(names: [String], frame: CGRect)] = []
                    Self.paneAXWalk(host, &found)
                    side = found.first { $0.names.contains(AgentsWindow.title) }?.frame
                    head = found.filter { $0.names.contains(title) && $0.frame.minX > edge }.max { $0.frame.minX < $1.frame.minX }?.frame
                } while (side == nil || head == nil) && Date() < deadline
                XCTAssertFalse(win.isVisible, "never on screen")
                let sf = try XCTUnwrap(side, "the sidebar title (\(scale))"), hf = try XCTUnwrap(head, "the header title (\(scale))")
                print("#1197 rider-a scale=\(scale) sidebarTitleMidY=\(sf.midY) headerTitleMidY=\(hf.midY) "
                      + "difference=\(sf.midY - hf.midY) band=\(AgentWindowBand.height) (accessibility frames, bottom-left origin)")
            }
        }
    }

    /// The accessibility tree's names (label, title, value) and frames; bounded depth.
    @MainActor
    static func paneAXWalk(_ e: Any, _ out: inout [(names: [String], frame: CGRect)], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        let frame = o.responds(to: Selector(("accessibilityFrame")))
            ? (o.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero : .zero
        out.append((names: ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].map(text).filter { !$0.isEmpty }, frame: frame))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { paneAXWalk(k, &out, depth: depth + 1) }
    }
}
