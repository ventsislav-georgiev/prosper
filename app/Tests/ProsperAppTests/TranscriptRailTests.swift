import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// A pane as the window stacks it: a header, the transcript, a composer (fixed heights), for the R1.1 frame rows.
struct RailHost: View {
    let model: AgentTranscriptModel
    let hover: TranscriptRailHover
    var rail: Bool
    var jumper: TranscriptJumper = .idle
    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: "Pane header api").frame(height: sz(28))
            AgentTranscriptView(model: model, ownsLifecycle: false, level: .focused, jumper: jumper, rail: rail, railHover: hover)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
            Text(verbatim: "Composer api").frame(height: sz(40))
        }
        .environment(\.colorScheme, .dark)
    }
}

/// #1318 (#832 X1 step C, spec v2.1 8.2, 13.3): the chapters rail. Offscreen only: pure geometry, the hover state
/// machine on a fake clock and a fake button read, clicks called as functions with points (no event is posted), hosted
/// views in borderless windows that are never shown, ordered front or made key; AX flags on this process only, put back.
/// Fake transcripts in tempDir() (JumpFixture), no dch.
@MainActor
final class TranscriptRailTests: XCTestCase {
    typealias Chapter = TranscriptOutline.Chapter

    private func chapters(_ n: Int, ids: ((Int) -> Int)? = nil, errors: Set<Int> = []) -> [Chapter] {
        (0..<n).map { i in Chapter(id: ids?(i) ?? i * 3, ordinal: i + 1, title: "Prompt \(i)", kind: .prompt, hasError: errors.contains(i)) }
    }
    private func rail(_ c: [Chapter], width: CGFloat = 560, height: CGFloat, older: Bool = false, cap: Bool = false) -> TranscriptRail {
        TranscriptRail(chapters: c, older: older, cap: cap, size: CGSize(width: sz(width), height: sz(height)))
    }

    // MARK: Ticks (13.3; X1 mutant 1)

    /// 0, 1, 40 and 900 chapters at 200*s and 900*s: tick i of k is centred at top + (i + 0.5) * height / k, one per
    /// chapter up to height / 4*s, then buckets whose tick is the bucket's first chapter (magenta when any of the bucket
    /// failed). Chapter ids far apart (a long turn between two prompts) change nothing: red when ticks follow offsets.
    func testTicksFollowOrdinalsAndBucket() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale in [0.7, 0.85, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            for h in [200, 900] as [CGFloat] {
                for n in [0, 1, 40, 900] {
                    // uneven ids: the first half of the chapters sit 1 apart, the rest 1000 apart
                    let c = chapters(n, ids: { $0 < n / 2 ? $0 : 1000 * $0 }, errors: [n / 3])
                    let r = rail(c, height: h)
                    let tag = "\(n) chapters, \(h)*s, scale \(scale)"
                    let k = n == 0 ? 0 : min(n, Int(sz(h) / sz(4)))
                    XCTAssertEqual(r.count, k, tag)
                    let t = r.ticks
                    XCTAssertEqual(t.count, k, tag)
                    for (i, tick) in t.enumerated() {
                        XCTAssertEqual(tick.y, (CGFloat(i) + 0.5) * sz(h) / CGFloat(k), accuracy: 0.001, "\(tag) tick \(i)")
                        let first = (i * n + k - 1) / k, next = i + 1 < k ? ((i + 1) * n + k - 1) / k : n
                        XCTAssertEqual(tick.chapter.ordinal, first + 1, "\(tag): a bucket's tick is its first chapter")
                        XCTAssertEqual(tick.error, (first..<next).contains(n / 3), "\(tag) tick \(i) error")
                    }
                    if n > 0, k < n { XCTAssertEqual(t.last?.chapter.ordinal, ((k - 1) * n + k - 1) / k + 1, tag) }
                }
            }
        }
        ThemeRuntime.scale = 1
        // 900 chapters at 200: 50 buckets of 18; at 900: 225 buckets of 4.
        XCTAssertEqual(rail(chapters(900), height: 200).count, 50)
        XCTAssertEqual(rail(chapters(900), height: 900).count, 225)
        XCTAssertEqual(rail(chapters(900), height: 200).ticks.dropFirst(1).first?.chapter.ordinal, 19)
        // The cap moves the ticks' area under it.
        let older = rail(chapters(4), height: 210, older: true)
        XCTAssertEqual(older.ticks.first?.y ?? 0, 10 + 0.5 * 200 / 4, accuracy: 0.001)
    }

    // MARK: The 340*s threshold (X1 mutant 5) and empty

    func testRailIsHiddenBelow340AndEmptyDrawsNothing() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let j = TranscriptJumper()
        for scale in [0.7, 0.85, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            XCTAssertFalse(rail(chapters(3), width: 339.5, height: 300).shown, "\(scale): below 340*s")
            XCTAssertFalse(rail(chapters(3), width: 335, height: 300).shown, "\(scale)")
            XCTAssertTrue(rail(chapters(3), width: 340, height: 300).shown, "\(scale): at 340*s")
            XCTAssertTrue(rail(chapters(3), width: 345, height: 300).shown, "\(scale)")
            for r in [rail(chapters(3), width: 335, height: 300), rail([], height: 300), rail([], height: 300, older: true)] {
                XCTAssertTrue(r.ticks.isEmpty, "\(scale): nothing drawn")
                XCTAssertTrue(r.hit(at: CGPoint(x: sz(7), y: sz(5))) == nil, "\(scale): no hover")
                XCTAssertTrue(r.hit(at: CGPoint(x: sz(7), y: sz(150))) == nil, "\(scale): no hover")
                var loads = 0
                r.click(at: CGPoint(x: sz(7), y: sz(5)), jumper: j, loadEarlier: { loads += 1 })
                r.click(at: CGPoint(x: sz(7), y: sz(150)), jumper: j, loadEarlier: { loads += 1 })
                XCTAssertEqual(loads, 0)
                XCTAssertTrue(j.request == nil, "\(scale): no click")
            }
        }
        let bad = TranscriptRail(chapters: chapters(3), older: false, cap: false, size: CGSize(width: CGFloat.nan, height: 300))
        XCTAssertFalse(bad.shown)
        XCTAssertEqual(bad.count, 0)
        let tall = TranscriptRail(chapters: chapters(3), older: false, cap: false, size: CGSize(width: 400, height: CGFloat.infinity))
        XCTAssertFalse(tall.shown, "a size that is not finite never reaches Int(")
    }

    // MARK: Hit area and click (13.3; X1 mutant 8)

    /// Three ticks at 50, 150, 250 (300*s): a click at the rail's x = 1*s and x = 13*s between two ticks jumps to the
    /// nearer one (this pane's jumper); the strip's edges count, a point outside it does not.
    func testBetweenTicksClickJumpsToTheNearestTick() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale in [0.7, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            let c = chapters(3), r = rail(c, height: 300), j = TranscriptJumper()
            XCTAssertEqual(r.ticks.count, 3)
            for (t, y) in zip(r.ticks, [50, 150, 250] as [CGFloat]) { XCTAssertEqual(t.y, sz(y), accuracy: 0.001) }
            for x in [1, 13] as [CGFloat] {
                for (y, want) in [(95, 0), (105, 1), (190, 1), (210, 2), (1, 0), (299, 2)] as [(CGFloat, Int)] {
                    let p = CGPoint(x: sz(x), y: sz(y))
                    XCTAssertEqual(r.hit(at: p), .tick(want), "\(scale): x \(x) y \(y)")
                    let before = j.request?.serial ?? 0
                    r.click(at: p, jumper: j, loadEarlier: { XCTFail("no load") })
                    XCTAssertEqual(j.request?.serial, before + 1, "\(scale): x \(x) y \(y) jumps")
                    XCTAssertEqual(j.request?.block, c[want].id, "\(scale): x \(x) y \(y) to chapter \(want + 1)")
                }
            }
            XCTAssertEqual(r.hit(at: CGPoint(x: 0, y: sz(150))), .tick(1))
            XCTAssertEqual(r.hit(at: CGPoint(x: sz(14), y: sz(150))), .tick(1))
            XCTAssertTrue(r.hit(at: CGPoint(x: sz(14) + 1, y: sz(150))) == nil, "\(scale): right of the strip")
            XCTAssertTrue(r.hit(at: CGPoint(x: sz(7), y: CGFloat.nan)) == nil)
        }
    }

    /// 7.6: the rail's strip is inside the pane frame, so a down there on an unfocused pane is the first click the
    /// window swallows (it only focuses: the rail never sees it); on the focused pane it passes to the rail.
    func testClickOnAnUnfocusedPanesRailOnlyFocusesIt() {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let a = UUID(), b = UUID()
        let frames = [a: CGRect(x: 0, y: 0, width: 400, height: 600), b: CGRect(x: 401, y: 0, width: 400, height: 600)]
        for scale in [0.7, 0.85, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            for x in [1, 7, 13] as [CGFloat] {
                XCTAssertEqual(AgentsNSWindow.firstClick(at: CGPoint(x: 401 + sz(x), y: 300), frames: frames, focused: a), b,
                               "\(scale): x \(x) on B's rail only focuses B")
                XCTAssertTrue(AgentsNSWindow.firstClick(at: CGPoint(x: sz(x), y: 300), frames: frames, focused: a) == nil,
                              "\(scale): x \(x) on the focused pane's rail reaches the rail")
            }
        }
    }

    // MARK: Earlier

    func testEarlierCapLoadsAndReadsTheHistoryCap() {
        let c = chapters(5), j = TranscriptJumper()
        var loads = 0
        let older = rail(c, height: 300, older: true)
        XCTAssertEqual(older.hit(at: CGPoint(x: sz(7), y: sz(5))), .earlier)
        XCTAssertEqual(older.label(.earlier)?.0, "Earlier chapters not loaded")
        older.click(at: CGPoint(x: sz(1), y: sz(4)), jumper: j, loadEarlier: { loads += 1 })
        XCTAssertEqual(loads, 1, "the cap runs loadEarlier")
        XCTAssertTrue(j.request == nil, "and jumps nowhere")
        XCTAssertEqual(older.hit(at: CGPoint(x: sz(7), y: sz(11))), .tick(0), "the ticks start under the cap")
        let capped = rail(c, height: 300, older: true, cap: true)
        XCTAssertEqual(capped.label(.earlier)?.0, "Older history is in the terminal")
        capped.click(at: CGPoint(x: sz(7), y: sz(5)), jumper: j, loadEarlier: { loads += 1 })
        XCTAssertEqual(loads, 1, "at the history cap it does nothing")
        let none = rail(c, height: 300)
        XCTAssertEqual(none.hit(at: CGPoint(x: sz(7), y: sz(5))), .tick(0), "no cap: the top is the first tick's")
        XCTAssertTrue(none.label(.earlier) == nil)
    }

    // MARK: Hover (fake clock, fake button)

    func testHoverDwellAndLeaveOnTheClock() {
        let h = TranscriptRailHover()
        var timers: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
        h.after = { d, f in timers.append((d, f)) }
        h.buttonDown = { false }
        func fire() { let t = timers; timers = []; t.forEach { $0.1() } }
        h.move(.tick(2))
        XCTAssertTrue(h.shown == nil, "no label before the dwell")
        XCTAssertEqual(timers.map(\.0), [0.15])
        h.move(.tick(3))
        XCTAssertEqual(timers.count, 1, "moving during the dwell does not restart it")
        fire()
        XCTAssertEqual(h.shown, .tick(3), "after 150 ms: the band under the pointer")
        h.move(.tick(4))
        XCTAssertEqual(h.shown, .tick(4), "once up, it follows at once")
        XCTAssertTrue(timers.isEmpty)
        h.move(nil)
        XCTAssertEqual(h.shown, .tick(4), "still up right after leaving")
        XCTAssertEqual(timers.map(\.0), [0.15])
        fire()
        XCTAssertTrue(h.shown == nil, "gone 150 ms after leaving")
        // Back before the 150 ms: the label stays.
        h.move(.tick(1)); fire()
        h.move(nil)
        h.move(.tick(0))
        XCTAssertEqual(h.shown, .tick(0))
        fire()
        XCTAssertEqual(h.shown, .tick(0), "the hide was called off")
        // Leaving during the dwell: never shown.
        h.move(nil); fire()
        h.move(.tick(2))
        h.move(nil)
        fire()
        XCTAssertTrue(h.shown == nil, "left before the dwell ended")
    }

    func testNoLabelWhileAButtonIsDown() {
        let h = TranscriptRailHover()
        var timers: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
        h.after = { d, f in timers.append((d, f)) }
        var down = true
        h.buttonDown = { down }
        func fire() { let t = timers; timers = []; t.forEach { $0.1() } }
        h.move(.tick(0)); h.move(.tick(1)); fire()
        XCTAssertTrue(h.shown == nil, "a drag across the rail shows nothing")
        down = false
        h.move(.tick(1)); fire()
        XCTAssertEqual(h.shown, .tick(1), "the dwell starts once the button is up")
        down = true
        h.move(.tick(2))
        XCTAssertTrue(h.shown == nil, "a button going down takes the label away")
        fire()
        XCTAssertTrue(h.shown == nil)
    }

    // MARK: R904-f1: the label's title is outside text

    func testHoverLabelTitleIsShownThroughTheMarkCap() {
        let piled = "ab" + String(repeating: "\u{0301}", count: 30) + "\u{202E}c\u{200B}d"
        let c = [Chapter(id: 0, ordinal: 12, title: piled, kind: .prompt, hasError: true)]
        let line = rail(c, height: 300).label(.tick(0))
        XCTAssertEqual(line?.0.unicodeScalars.map(\.value),
                       ("12 \u{00B7} ab" + String(repeating: "\u{0301}", count: 3) + "cd").unicodeScalars.map(\.value))
        XCTAssertEqual(line?.1, "error")
        XCTAssertTrue(rail(chapters(1), height: 300).label(.tick(0))?.1 == nil, "no error line")
    }

    /// At UI scale 0.7 and 0.85, a first line of piled marks inks nothing in the label's second line or outside it
    /// (compared with the same label on an empty first line); a plain unclipped line in the same place does.
    func testHoverLabelLineOneInksNothingBelowItAt07And085() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let hostile = "abcdefghijklmnop".map { String($0) + String(repeating: "\u{0323}", count: 24) + String(repeating: "\u{0301}", count: 24) }.joined()
        let pad: CGFloat = 40
        func rows<V: View>(_ v: V, _ tag: String) throws -> [[UInt8]] {
            let r = ImageRenderer(content: VStack(spacing: 0) {
                Color.clear.frame(height: pad)
                v
                Color.clear.frame(height: pad)
            }.background(Color.black))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage, tag)
            let bytes = [UInt8](try XCTUnwrap(cg.dataProvider?.data as Data?, tag))
            guard bytes.count >= cg.bytesPerRow * cg.height else { XCTFail("\(tag): unexpected bitmap"); return [] }
            return (0..<cg.height).map { Array(bytes[($0 * cg.bytesPerRow)..<($0 * cg.bytesPerRow + cg.bytesPerRow)]) }
        }
        /// The bitmap rows where `a` and `b` differ, outside line one's band [pad, pad + 20*s).
        func below(_ a: [[UInt8]], _ b: [[UInt8]]) -> Int {
            guard a.count == b.count else { return -1 }
            let top = Int(pad), end = Int((pad + sz(20)).rounded(.up))
            let rows = a.indices.filter { ($0 < top || $0 >= end) && a[$0] != b[$0] }
            fputs("rail1318a fact: line one band \(top)..<\(end), rows differing outside it \(rows)\n", stderr)
            return rows.count
        }
        for scale in [0.7, 0.85] as [CGFloat] {
            ThemeRuntime.scale = scale
            func plain(_ s: String) -> AnyView {
                AnyView(VStack(spacing: 0) {
                    Text(verbatim: s).font(Neon.font(11)).foregroundStyle(Neon.textPrimary).lineLimit(1).frame(height: sz(20))
                    Color.clear.frame(height: sz(20))
                }.frame(width: sz(280), height: sz(40), alignment: .top))
            }
            let control = below(try rows(plain(hostile), "control \(scale)"), try rows(plain(""), "control empty \(scale)"))
            fputs("rail1318a fact \(scale): unclipped line, rows inked below line one \(control)\n", stderr)
            XCTAssertGreaterThan(control, 0, "\(scale): an unclipped line inks below itself, else the method proves nothing")
            let label = try rows(TranscriptRailLabel(line: hostile, error: nil), "label \(scale)")
            let empty = try rows(TranscriptRailLabel(line: "", error: nil), "label empty \(scale)")
            XCTAssertNotEqual(label, empty, "\(scale): the line draws")
            let inked = below(label, empty)
            fputs("rail1318a fact \(scale): label, rows inked below line one \(inked)\n", stderr)
            XCTAssertEqual(inked, 0, "\(scale): line one inks the second line or outside the label")
        }
    }

    // MARK: Hosted frames (13.3, R1.1, the 340*s resize)

    private func scene(turns: Int, size: CGSize, _ check: (AgentTranscriptModel, TranscriptRailHover, NSWindow, NSHostingView<RailHost>) throws -> Void) throws {
        let url = tempDir().appendingPathComponent("r.jsonl")
        try JumpFixture.write(url, JumpFixture.turns(turns))
        let m = JumpFixture.model(url)
        defer { m.stop() }
        let hover = TranscriptRailHover()
        hover.after = { _, f in f() }
        hover.buttonDown = { false }
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (win, host) = AXTreeSupport.hosted(RailHost(model: m, hover: hover, rail: true), size)
        defer { win.close() }
        try check(m, hover, win, host)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// Every text, the scroll area and the document: role, name and frame, once the last turn (or the composer) is drawn.
    private func frames(_ host: NSView, last: String) -> [String] {
        _ = AXTreeSupport.poll(host) { t in t.contains { $0.names.contains(last) } }
        let tree = AXTreeSupport.poll(host) { _ in true }
        let doc = (scrollView(host)?.documentView?.frame).map { "doc \($0)" } ?? "no doc"
        return tree.filter { ["AXStaticText", "AXScrollArea", "AXButton"].contains($0.role) }.map { "\($0.role)|\($0.name)|\($0.frame)" } + [doc]
    }
    private func scrollView(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for c in v.subviews { if let s = scrollView(c) { return s } }
        return nil
    }

    /// 13.3 rail and R1.1: the header, every transcript text, the scroll area and the composer have the same frames
    /// with the rail drawn, without it and with its hover label up, for 0, 1 and 40 chapters, at 0.7, 0.85 and 1.0;
    /// the rail is shown where it should be (the probe). Red when the rail takes width (mutant rail-adds-width).
    func testTranscriptFramesAreTheSameWithAndWithoutTheRail() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved; TranscriptRailView.probe = nil }
        // Keyed by the model it was drawn for: a previous scene's view (alive after its scene) reports too.
        var seen: [ObjectIdentifier: TranscriptRail] = [:]
        TranscriptRailView.probe = { seen[ObjectIdentifier($0)] = $1 }
        let cases: [(CGFloat, Int, CGSize)] = [(0.7, 40, CGSize(width: 560, height: 400)), (0.85, 40, CGSize(width: 560, height: 400)),
                                               (1.0, 40, CGSize(width: 560, height: 400)), (1.0, 40, CGSize(width: 900, height: 900)),
                                               (1.0, 40, CGSize(width: 330, height: 260)), (1.0, 1, CGSize(width: 560, height: 260)),
                                               (1.0, 0, CGSize(width: 560, height: 260))]
        for (scale, turns, size) in cases {
            ThemeRuntime.scale = scale
            seen = [:]
            let tag = "\(turns) chapters, \(size), scale \(scale)"
            try scene(turns: turns, size: size) { m, hover, _, host in
                let last = turns == 0 ? "Composer api" : "Done \(turns - 1)"
                let on = frames(host, last: last)
                XCTAssertEqual(m.chapters.count, turns, tag)
                let r = try XCTUnwrap(seen[ObjectIdentifier(m)], "\(tag): the rail laid out")
                XCTAssertEqual(r.shown, turns > 0 && size.width >= sz(340), tag)
                XCTAssertEqual(r.chapters.count, turns, tag)
                if r.shown {
                    hover.move(r.hit(at: CGPoint(x: sz(7), y: r.size.height / 2)))
                    XCTAssertTrue(hover.shown != nil, "\(tag): the label is up")
                    XCTAssertEqual(frames(host, last: last), on, "\(tag): the label moves nothing")
                    hover.move(nil)
                }
                host.rootView = RailHost(model: m, hover: hover, rail: false)
                XCTAssertEqual(frames(host, last: last), on, "\(tag): with and without the rail")
                XCTAssertTrue(on.contains { $0.hasPrefix("AXStaticText|Composer api|") }, "\(tag): the composer is read")
            }
        }
    }

    /// 13.3: a live resize 345*s, 335*s, 345*s across the threshold: hidden below, shown again, every frame equal to
    /// the transcript without the rail at the same width. Red when the rail shows below 340*s (X1 mutant 5).
    func testResizeAcross340HidesTheRailWithNoFrameChange() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved; TranscriptRailView.probe = nil }
        // Keyed by the model it was drawn for: the previous scene's view stays alive and, once its model stops, reports
        // its own old width with no chapters during this scene's first poll (ticket 1 of rail1318b, report.txt section 1).
        var seen: [ObjectIdentifier: TranscriptRail] = [:]
        TranscriptRailView.probe = { seen[ObjectIdentifier($0)] = $1 }
        for scale in [0.85, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            let height: CGFloat = 400
            seen = [:]
            try scene(turns: 40, size: CGSize(width: sz(345), height: height)) { m, _, win, host in
                let mine = ObjectIdentifier(m)
                var withRail: [String] = []
                for w in [345, 335, 345] as [CGFloat] {
                    let size = CGSize(width: sz(w), height: height)
                    win.setContentSize(size)
                    host.frame = CGRect(origin: .zero, size: size)
                    let tag = "\(w)*s at \(scale)"
                    // the probe reports after SwiftUI's update: wait for this width's report (5 s ceiling)
                    _ = AXTreeSupport.poll(host) { _ in abs((seen[mine]?.size.width ?? 0) - sz(w)) < 1 }
                    withRail = frames(host, last: "Done 39")
                    XCTAssertEqual(seen[mine]?.shown, w >= 340, "\(tag): shown at or above 340*s only")
                    XCTAssertEqual(seen[mine]?.size.width ?? 0, sz(w), accuracy: 1, tag)
                }
                host.rootView = RailHost(model: m, hover: TranscriptRailHover(), rail: false)
                XCTAssertEqual(frames(host, last: "Done 39"), withRail, "345*s at \(scale): no frame change after the round trip")
                win.setContentSize(CGSize(width: sz(335), height: height))
                host.frame = CGRect(origin: .zero, size: CGSize(width: sz(335), height: height))
                let without = frames(host, last: "Done 39")
                host.rootView = RailHost(model: m, hover: TranscriptRailHover(), rail: true)
                XCTAssertEqual(frames(host, last: "Done 39"), without, "335*s at \(scale): the hidden rail changes no frame")
            }
        }
    }

    /// R1318-n1: a label up, the pane drops below 340*s (no mouseExited), comes back: no label until a new move. The timer
    /// seam never fires here, so only an immediate clear when the rail hides can empty it.
    func testHoverLabelIsClearedWhenTheRailHidesBelow340() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved; TranscriptRailView.probe = nil }
        ThemeRuntime.scale = 1.0
        var seen: [ObjectIdentifier: TranscriptRail] = [:]
        TranscriptRailView.probe = { seen[ObjectIdentifier($0)] = $1 }
        try scene(turns: 40, size: CGSize(width: sz(345), height: 400)) { m, hover, win, host in
            let mine = ObjectIdentifier(m)
            @MainActor func resize(_ w: CGFloat) {
                let size = CGSize(width: sz(w), height: 400)
                win.setContentSize(size)
                host.frame = CGRect(origin: .zero, size: size)
                _ = AXTreeSupport.poll(host) { _ in abs((seen[mine]?.size.width ?? 0) - sz(w)) < 1 && seen[mine]?.shown == (w >= 340) }
            }
            resize(345)
            hover.move(.tick(0))   // the scene's clock fires at once: the label is up
            XCTAssertEqual(hover.shown, .tick(0))
            hover.after = { _, _ in }   // from here no timer fires
            resize(335)
            XCTAssertTrue(hover.shown == nil, "hidden below 340*s: the label goes with the rail")
            resize(345)
            XCTAssertTrue(hover.shown == nil, "back above: no old label until a new move")
        }
    }

    // MARK: The strip view (#1318 r2): wheel, hover, click

    /// The transcript (40 turns, 560x400) in a borderless window that is never shown but has a window number (a created
    /// event resolves to it), laid out to its last turn.
    private func live(rail on: Bool, jumper: TranscriptJumper = .idle,
                      _ check: (NSWindow, NSHostingView<RailHost>, TranscriptRailHover) throws -> Void) throws {
        let url = tempDir().appendingPathComponent("w.jsonl")
        try JumpFixture.write(url, JumpFixture.turns(40))
        let m = JumpFixture.model(url)
        defer { m.stop() }
        let hover = TranscriptRailHover()
        hover.after = { _, f in f() }
        hover.buttonDown = { false }
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let size = CGSize(width: 560, height: 400)
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        let host = NSHostingView(rootView: RailHost(model: m, hover: hover, rail: on, jumper: jumper))
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        _ = frames(host, last: "Done 39")
        try check(win, host, hover)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// A wheel over the 14*s strip reaches the transcript's scroll view, as with no rail. Rail off: a strip point
    /// hit-tests into that scroll view (the wheel climbs its responder chain to it). Rail on: it hit-tests to the strip
    /// view, which hands the same event to that scroll view. AppKit sends a wheel to the hit view. Red when the strip eats
    /// the wheel (mutant rail-eats-wheel), and with round 1's SwiftUI hit area (the hit view was the NSHostingView).
    /// The event is created and handed to the view, never posted.
    func testWheelOverTheStripReachesTheTranscriptScrollView() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
        let sym = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"))
        for scale in [0.7, 1.0] as [CGFloat] {
            ThemeRuntime.scale = scale
            for on in [false, true] {
                let tag = "rail \(on ? "on" : "off") at \(scale)"
                try live(rail: on) { win, host, _ in
                    let sv = try XCTUnwrap(scrollView(host), tag)
                    let area = sv.convert(sv.bounds, to: host)
                    for x in [1, 7, 13] as [CGFloat] {
                        for y in [area.minY + 5, area.midY, area.maxY - 5] {
                            let at = "\(tag): x \(x)*s y \(y)"
                            let p = CGPoint(x: area.minX + sz(x), y: y)
                            let hit = try XCTUnwrap(host.hitTest(host.convert(p, to: host.superview)), at)
                            let wp = host.convert(p, to: nil)
                            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0))
                            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                            // Field 51: the window NSEvent(cgEvent:) resolves; CGEventSetWindowLocation: its locationInWindow.
                            cg.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 51)), value: Int64(win.windowNumber))
                            unsafeBitCast(sym, to: SetWindowLocation.self)(cg, CGPoint(x: wp.x, y: win.frame.height - wp.y))
                            let e = try XCTUnwrap(NSEvent(cgEvent: cg))
                            XCTAssertTrue(e.window === win, "\(at): precondition, the event is this window's")
                            if on {
                                let strip = try XCTUnwrap(hit as? TranscriptRailStrip, "\(at): the hit view is \(type(of: hit))")
                                var got: [(NSScrollView, NSEvent)] = []
                                strip.wheel = { got.append(($0, $1)) }
                                strip.scrollWheel(with: e)
                                XCTAssertEqual(got.count, 1, "\(at): the strip hands the wheel on once")
                                XCTAssertTrue(got.first?.0 === sv, "\(at): to the transcript's scroll view")
                                XCTAssertTrue(got.first?.1 === e, "\(at): the same event")
                            } else {
                                XCTAssertTrue(hit.isDescendant(of: sv), "\(at): with no rail the wheel goes into the scroll view")
                            }
                        }
                    }
                }
            }
        }
    }

    /// The strip view is the hover and click area: a move over a tick shows its label (the clock fires at once here),
    /// leaving hides it, a down and up jumps this pane's jumper to that tick's chapter. Events created, never posted.
    func testStripViewHoversAndClicks() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1
        let jumper = TranscriptJumper()
        try live(rail: true, jumper: jumper) { win, host, hover in
            let sv = try XCTUnwrap(scrollView(host))
            let area = sv.convert(sv.bounds, to: host)
            let p = CGPoint(x: area.minX + sz(7), y: area.midY + 3)
            let strip = try XCTUnwrap(host.hitTest(host.convert(p, to: host.superview)) as? TranscriptRailStrip)
            let rail = try XCTUnwrap(strip.rail)
            XCTAssertEqual(rail.chapters.count, 40)
            guard case .tick(let i)? = rail.hit(at: strip.convert(p, from: host)) else { return XCTFail("a tick under the point") }
            func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: host.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                                 windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            strip.mouseMoved(with: try mouse(.mouseMoved))
            XCTAssertEqual(hover.shown, .tick(i), "the label of the band under the pointer")
            strip.mouseExited(with: try mouse(.mouseMoved))
            XCTAssertTrue(hover.shown == nil, "gone after leaving")
            XCTAssertTrue(jumper.request == nil)
            strip.mouseDown(with: try mouse(.leftMouseDown))
            strip.mouseUp(with: try mouse(.leftMouseUp))
            XCTAssertEqual(jumper.request?.block, rail.ticks.dropFirst(i).first?.chapter.id, "a click jumps to the tick's chapter")
        }
    }
}
