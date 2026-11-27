import AppKit
import SwiftUI
import XCTest
import LuaRuntime
@testable import ProsperApp

private final class NoopChartServices: ExtensionHostServices, @unchecked Sendable {
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

/// #2023: the `host.ui.chart` node. Decoding is the trust boundary (caps, dropped
/// non-finite points, errors for malformed nodes); the last rows build the view off-screen.
final class ExtensionChartViewTests: XCTestCase {
    private struct NotAChart: Error {}

    private func chart(_ json: String) throws -> ChartNode {
        guard case .chart(let n) = try ExtensionViewNode.decode(json: json) else {
            throw NotAChart()
        }
        return n
    }

    /// Lua source for one chart, run through the real host.ui builder and host.ui.render.
    private func luaChart(_ table: String) throws -> String {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test.chart", services: NoopChartServices()).install(into: lua)
        try lua.run("function show() return host.ui.render(host.ui.chart\(table)) end")
        return try XCTUnwrap(try lua.callGlobal("show"))
    }

    private func series(_ count: Int, points: Int) -> String {
        let pts = (0..<points).map { #"{"x":\#($0),"y":1}"# }.joined(separator: ",")
        let one = #"{"name":"s","points":[\#(pts)]}"#
        return #"{"type":"chart","kind":"line","series":[\#(Array(repeating: one, count: count).joined(separator: ","))]}"#
    }

    func testDecodeGoodLineChart() throws {
        let n = try chart("""
        {"type":"chart","title":"Closed per day","kind":"line","x_label":"Day","y_label":"Closed",
         "series":[{"name":"opus","points":[{"x":"11-25","y":4},{"x":"11-26","y":6}]},
                   {"name":"sonnet","points":[{"x":"11-25","y":2}]}]}
        """)
        XCTAssertEqual(n.kind, .line)
        XCTAssertEqual(n.title, "Closed per day")
        XCTAssertEqual(n.xLabel, "Day")
        XCTAssertEqual(n.yLabel, "Closed")
        XCTAssertEqual(n.series.map(\.name), ["opus", "sonnet"])
        XCTAssertEqual(n.series.first?.points, [.init(x: .text("11-25"), y: 4), .init(x: .text("11-26"), y: 6)])
        XCTAssertEqual(n.pointCount, 3)
        XCTAssertFalse(n.isEmpty)
        XCTAssertEqual(try ExtensionViewNode.decode(json: #"{"type":"chart","title":"T","kind":"bar"}"#).title, "T")
    }

    func testDecodeGoodBarChartFromLua() throws {
        let n = try chart(try luaChart("""
        { title = "Per tier", kind = "bar", y_label = "Closed",
          series = { { name = "closed", points = { { x = "opus", y = 12 }, { x = "sonnet", y = 7 } } } } }
        """))
        XCTAssertEqual(n.kind, .bar)
        XCTAssertEqual(n.series.count, 1)
        XCTAssertEqual(n.series.last?.points.map(\.y), [12, 7])
        XCTAssertEqual(n.series.last?.points.map(\.x.label), ["opus", "sonnet"])
    }

    func testNumericXGivesANumericAxis() throws {
        let n = try chart(#"{"type":"chart","kind":"line","series":[{"name":"a","points":[{"x":1,"y":2},{"x":2.5,"y":3}]}]}"#)
        XCTAssertTrue(n.isNumericX)
        XCTAssertEqual(n.series.first?.points.map(\.x), [.number(1), .number(2.5)])
    }

    func testStringXMakesTheWholeAxisCategorical() throws {
        // One text x anywhere makes every x text, so one Chart never mixes axis types.
        let n = try chart("""
        {"type":"chart","kind":"bar","series":[{"name":"a","points":[{"x":1,"y":2}]},
                                               {"name":"b","points":[{"x":"total","y":3}]}]}
        """)
        XCTAssertFalse(n.isNumericX)
        XCTAssertEqual(n.series.first?.points.first?.x.label, "1")
        XCTAssertEqual(n.series.last?.points.first?.x, .text("total"))
    }

    func testMoreThanTwelveSeriesIsADecodeError() throws {
        XCTAssertEqual(try chart(series(12, points: 1)).series.count, 12)
        XCTAssertThrowsError(try ExtensionViewNode.decode(json: series(13, points: 1)))
    }

    func testMoreThanAThousandPointsIsADecodeError() throws {
        XCTAssertEqual(try chart(series(1, points: 1000)).pointCount, 1000)
        XCTAssertThrowsError(try ExtensionViewNode.decode(json: series(1, points: 1001)))
    }

    private func chartJSON(counts: [Int]) -> String {
        let all = counts.map { n in
            let pts = (0..<n).map { #"{"x":\#($0),"y":1}"# }.joined(separator: ",")
            return #"{"name":"s","points":[\#(pts)]}"#
        }
        return #"{"type":"chart","kind":"line","series":[\#(all.joined(separator: ","))]}"#
    }

    func testTotalPointsAcrossSeriesIsCappedAtTwoThousand() throws {
        XCTAssertEqual(ChartNode.maxTotalPoints, 2000)
        XCTAssertEqual(try chart(chartJSON(counts: [1000, 1000])).pointCount, 2000)
        XCTAssertEqual(try chart(chartJSON(counts: [1000])).pointCount, 1000)
        // Each series is within the per-series cap, so only the total guard can reject this.
        XCTAssertThrowsError(try ExtensionViewNode.decode(json: chartJSON(counts: [667, 667, 667]))) {
            XCTAssertTrue(String(describing: $0).contains("2000 points in total"), "\($0)")
        }
    }

    func testNonFinitePointsAreDropped() throws {
        // Lua's NaN and inf encode as null; such a point is dropped, the rest stay.
        let n = try chart(try luaChart("""
        { kind = "line", series = { { name = "a", points = {
            { x = 1, y = 0/0 }, { x = 2, y = math.huge }, { x = 0/0, y = 1 }, { x = 4, y = 5 } } } } }
        """))
        XCTAssertEqual(n.series.first?.points, [.init(x: .number(4), y: 5)])
        let j = try chart(#"{"type":"chart","kind":"bar","series":[{"name":"a","points":[{"x":"d","y":null},{"x":"e","y":1}]}]}"#)
        XCTAssertEqual(j.pointCount, 1)
    }

    func testMissingOrUnknownKindOrMalformedPointIsADecodeError() {
        XCTAssertThrowsError(try ExtensionViewNode.decode(json: #"{"type":"chart","series":[]}"#))
        XCTAssertThrowsError(try ExtensionViewNode.decode(json: #"{"type":"chart","kind":"pie"}"#))
        XCTAssertThrowsError(try ExtensionViewNode.decode(json:
            #"{"type":"chart","kind":"line","series":[{"name":"a","points":[{"y":1}]}]}"#))
        XCTAssertThrowsError(try ExtensionViewNode.decode(json:
            #"{"type":"chart","kind":"line","series":[{"name":"a","points":[{"x":"a","y":"1"}]}]}"#))
        XCTAssertThrowsError(try ExtensionViewNode.decode(json:
            #"{"type":"chart","kind":"line","series":{"a":true}}"#))
    }

    func testEmptyChartShowsEmptyText() throws {
        // Lua encodes an empty table as {}, which counts as an empty list.
        let fromLua = try chart(try luaChart(#"{ kind = "line", series = {} }"#))
        XCTAssertTrue(fromLua.isEmpty)
        XCTAssertEqual(fromLua.emptyMessage, "No data")
        let empty = try chart(#"{"type":"chart","kind":"bar","series":[{"name":"a","points":[]}],"empty_text":"No closes yet"}"#)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.emptyMessage, "No closes yet")
        XCTAssertEqual(try chart(#"{"type":"chart","kind":"bar"}"#).emptyMessage, "No data")
    }

    func testAccessibilitySummaryNamesTitleSeriesAndPoints() throws {
        let n = try chart("""
        {"type":"chart","title":"WIP","kind":"line",
         "series":[{"name":"a","points":[{"x":1,"y":1},{"x":2,"y":2}]},{"name":"b","points":[{"x":1,"y":3}]}]}
        """)
        XCTAssertEqual(n.accessibilitySummary, "WIP, 2 series, 3 points")
        XCTAssertEqual(try chart(#"{"type":"chart","kind":"line"}"#).accessibilitySummary, "Chart, 0 series, 0 points")
    }

    @MainActor
    func testTwelveSeriesGetTwelveDistinctColours() {
        let colours = (0..<ChartNode.maxSeries).map { ChartRender.colour($0) }
        XCTAssertEqual(Set(colours).count, ChartNode.maxSeries)
    }

    /// A 12-series chart at the 2000-point cap: layout plus one draw into an offscreen bitmap (an unwindowed view has no
    /// backing store, so displayIfNeeded would draw nothing).
    @MainActor
    func testFullChartRendersWithinABound() throws {
        let counts = Array(repeating: 166, count: 11) + [174]
        let node = try ExtensionViewNode.decode(json: chartJSON(counts: counts))
        let start = Date()
        let host = NSHostingView(rootView: ExtensionRenderedView(node: node, onAction: { _, _, _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let ms = Date().timeIntervalSince(start) * 1000
        print("CHART_TIMING ms=\(Int(ms))")
        XCTAssertTrue(host.window == nil)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        // shortcut: generous bound until CI timings are known, tighten after the first CI run
        XCTAssertLessThan(ms, 2000)
    }

    /// Builds the view in an NSHostingView that is never put in a window.
    @MainActor
    func testChartViewBuildsOffScreen() throws {
        for json in [
            #"{"type":"chart","title":"Line","kind":"line","series":[{"name":"a","points":[{"x":"d1","y":1},{"x":"d2","y":3}]},{"name":"b","points":[{"x":"d1","y":2}]}]}"#,
            #"{"type":"chart","kind":"bar","x_label":"n","y_label":"v","series":[{"name":"a","points":[{"x":1,"y":1},{"x":2,"y":3}]}]}"#,
            #"{"type":"chart","kind":"bar","series":[]}"#,
        ] {
            let node = try ExtensionViewNode.decode(json: json)
            let host = NSHostingView(rootView: ExtensionRenderedView(node: node, onAction: { _, _, _ in }))
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(host.window == nil)
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }
}
