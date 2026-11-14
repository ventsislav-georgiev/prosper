import Foundation
import XCTest
@testable import LuaRuntime

/// #1154: one instruction budget per outermost host call. A host function that calls back into its own runtime
/// (`callGlobal` or `run`) runs that call on the budget of the call it is part of: the count goes on, a budget spent
/// there stays spent for the rest of the outer call, and the outer call still ends on its budget afterwards. Every
/// row runs with allowLoad off and on, a budget of 100,000 instructions, and only bounded loops (at most 3,000,000
/// iterations of four instructions), so a row whose guard fails ends by itself.
final class LuaNestedBudgetTests: XCTestCase {

    private static let budget: Int32 = 100_000
    /// What a host function records for a call back that threw the budget error.
    private static let spent = "threw runtime(\"execution budget exceeded\")"
    /// What `call` returns when the outer call threw it (a different prefix from any value a host function returns).
    private static let spentCall = "error runtime(\"execution budget exceeded\")"

    /// What the host functions got back from their calls into the runtime, in call order.
    final class Seen { var lines: [String] = [] }

    /// A runtime with the row's script and two host functions: `reenter(name, ...)` calls each named global back
    /// through `callGlobal` and returns the last result; `rerun(source)` runs a chunk through `run`. Each records
    /// what it got ("threw <error>" for a throw).
    private func runtime(_ allowLoad: Bool, _ seen: Seen, _ script: String) throws -> LuaRuntime {
        let lua = try LuaRuntime(maxInstructions: Self.budget, allowLoad: allowLoad)
        lua.register("reenter") { rt in
            let names = (0..<max(rt.argumentCount, 0)).compactMap { rt.stringArgument($0 + 1) }
            var last = "none"
            for name in names {
                do { last = try rt.callGlobal(name) ?? "nil" } catch { last = "threw \(error)" }
                seen.lines.append(last)
            }
            rt.push(last)
            return 1
        }
        lua.register("rerun") { rt in
            let got: String
            do { try rt.run(rt.stringArgument(1) ?? ""); got = "ran" } catch { got = "threw \(error)" }
            seen.lines.append(got)
            rt.push(got)
            return 1
        }
        lua.register("tight") { rt in
            let got: String
            do { got = try rt.callGlobal("inner", budget: 1) ?? "nil" } catch { got = "threw \(error)" }
            seen.lines.append(got)
            rt.push(got)
            return 1
        }
        try lua.run(script + "\nfunction count(name) return tostring(_G[name]) end")
        return lua
    }

    /// Calls `name` from the host with the main thread's stack at rest before and after; "error <error>" on a throw.
    private func call(_ lua: LuaRuntime, _ name: String, _ note: String,
                      file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(lua.mainStackHeight, 0, "main thread before \(name) [\(note)]", file: file, line: line)
        let got: String
        do { got = try lua.callGlobal(name) ?? "nil" } catch { got = "error \(error)" }
        XCTAssertEqual(lua.mainStackHeight, 0, "main thread after \(name) [\(note)]", file: file, line: line)
        return got
    }

    /// The global counter `name` as a number; at most `max` (four instructions per iteration of a 100,000 budget).
    private func assertCounted(_ lua: LuaRuntime, _ name: String, atMost max: Int, _ note: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let got = (try? lua.callGlobal("count", [name])) ?? "nil"
        guard let n = Int(got) else { return XCTFail("\(name) = \(got) [\(note)]", file: file, line: line) }
        XCTAssertTrue(n >= 0 && n <= max, "\(name) = \(n), want at most \(max) [\(note)]", file: file, line: line)
    }

    // MARK: - The outer call keeps its budget

    func testTheOuterCallEndsOnItsBudgetAfterACallBack() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function inner() return 'inner' end
                function f() local v = reenter('inner') n = 0 for i = 1, 3000000 do n = n + 1 end return v .. n end
                function fr() local v = rerun('ran = 1') m = 0 for i = 1, 3000000 do m = m + 1 end return v .. m end
                """)
            XCTAssertEqual(call(lua, "f", note), Self.spentCall, note)
            assertCounted(lua, "n", atMost: 25_000, note)
            XCTAssertEqual(call(lua, "fr", note), Self.spentCall, note)
            assertCounted(lua, "m", atMost: 25_000, note)
            XCTAssertEqual(seen.lines, ["inner", "ran"], note)
        }
    }

    func testACallBackRunsOnTheOuterCount() throws {
        // 15,000 outer iterations (60,000 instructions), then a call back that would need 80,000 more.
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function inner() k = 0 for i = 1, 20000 do k = k + 1 end return 'inner' .. k end
                function f() n = 0 for i = 1, 15000 do n = n + 1 end local v = reenter('inner') return v end
                """)
            XCTAssertEqual(call(lua, "f", note), Self.spentCall, note)
            XCTAssertEqual(seen.lines, [Self.spent], note)
            assertCounted(lua, "k", atMost: 10_000, note)
        }
    }

    func testABudgetSpentInsideACallBackStaysSpent() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function inner() return 'inner' end
                function spin() s = 0 for i = 1, 3000000 do s = s + 1 end return 'spun' end
                function tail() return reenter('spin') end
                function after() local v = reenter('spin', 'inner') m = 0 for i = 1, 1000 do m = m + 1 end return v .. m end
                """)
            // The host function catches the spent budget and the outer call returns without another instruction.
            XCTAssertEqual(call(lua, "tail", note), Self.spentCall, note)
            XCTAssertEqual(seen.lines, [Self.spent], note)
            assertCounted(lua, "s", atMost: 25_000, note)
            // The host function calls back again after the budget was spent, then the outer call goes on.
            seen.lines = []
            XCTAssertEqual(call(lua, "after", note), Self.spentCall, note)
            XCTAssertEqual(seen.lines, [Self.spent, Self.spent], note)
            XCTAssertEqual(try lua.callGlobal("count", ["m"]), "nil", note)
        }
    }

    // MARK: - What keeps working

    func testTheCallBackResultArrivesWhenTheBudgetIsNotSpent() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function inner() return 'inner' end
                function f()
                  n = 0
                  for i = 1, 1000 do n = n + 1 end
                  local v = reenter('inner')
                  local r = rerun('ran = (ran or 0) + 1')
                  local t = tight()
                  for i = 1, 1000 do n = n + 1 end
                  return v .. ':' .. r .. ':' .. t .. ':' .. n .. ':' .. ran
                end
                function g() n = 0 for i = 1, 22000 do n = n + 1 end return tostring(n) end
                """)
            XCTAssertEqual(call(lua, "f", note), "inner:ran:inner:2000:1", note)
            XCTAssertEqual(seen.lines, ["inner", "ran", "inner"], note)
            // The next call has the whole budget again (22,000 iterations: 88% of it).
            XCTAssertEqual(call(lua, "g", note), "22000", note)
        }
    }

    func testAPlainCallWithoutACallBackIsUnchanged() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function f() n = 0 for i = 1, 3000000 do n = n + 1 end return tostring(n) end
                function g() n = 0 for i = 1, 22000 do n = n + 1 end return tostring(n) end
                """)
            XCTAssertEqual(call(lua, "f", note), Self.spentCall, note)
            assertCounted(lua, "n", atMost: 25_000, note)
            XCTAssertEqual(call(lua, "g", note), "22000", note)
            XCTAssertEqual(call(lua, "f", note), Self.spentCall, note)
            XCTAssertEqual(call(lua, "g", note), "22000", note)
            XCTAssertEqual(seen.lines, [], note)
        }
    }

    func testASpentBudgetCaughtByAScriptPcallInATailCallIsReported() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function spin() n = 0 for i = 1, 3000000 do n = n + 1 end end
                function f() return pcall(spin) end
                function g() n = 0 for i = 1, 22000 do n = n + 1 end return tostring(n) end
                """)
            XCTAssertEqual(call(lua, "f", note), Self.spentCall, note)
            assertCounted(lua, "n", atMost: 25_000, note)
            XCTAssertEqual(call(lua, "g", note), "22000", note)
        }
    }

    // MARK: - A call back from a coroutine's host call (one host call per row)

    func testACoroutineGoesOnOnTheOuterBudgetAfterACallBack() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function inner() return 'inner' end
                function f()
                  n = 0
                  return coroutine.wrap(function()
                    local v = reenter('inner')
                    for i = 1, 3000000 do n = n + 1 end
                    return v .. n
                  end)()
                end
                """)
            XCTAssertEqual(call(lua, "f", note), Self.spentCall, note)
            XCTAssertEqual(seen.lines, ["inner"], note)
            assertCounted(lua, "n", atMost: 25_000, note)
        }
    }

    func testACallBackFromACoroutineReturnsItsResult() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function inner() return 'inner' end
                function f()
                  n = 0
                  return coroutine.wrap(function()
                    local v = reenter('inner')
                    for i = 1, 1000 do n = n + 1 end
                    return v .. ':' .. n
                  end)()
                end
                """)
            XCTAssertEqual(call(lua, "f", note), "inner:1000", note)
            XCTAssertEqual(seen.lines, ["inner"], note)
        }
    }
}

/// R1154-2: `callGlobal` asks for room for the function and its arguments and fails the call when there is none;
/// `pushJSON` on a full stack pushes nothing. Green only: these rows rely on the checks they pin, so they are never
/// run without them.
final class LuaCallGlobalStackTests: XCTestCase {

    private static let script = "function count(...) return select('#', ...) .. ':' .. tostring((select(-1, ...))) end"

    func testACallWithMoreArgumentsThanTheMinimumStackGetsThemAll() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)"
            let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
            let args = (1...300).map { "a\($0)" }
            var inner = "none"
            lua.register("many") { rt in
                do { inner = try rt.callGlobal("count", args) ?? "nil" } catch { inner = "threw \(error)" }
                rt.push(inner)
                return 1
            }
            try lua.run(Self.script + "\nfunction viaCo() return coroutine.wrap(function() return many() end)() end")
            XCTAssertEqual(try lua.callGlobal("count", args), "300:a300", note)
            XCTAssertEqual(lua.mainStackHeight, 0, note)
            XCTAssertEqual(try lua.callGlobal("viaCo"), "300:a300", note)
            XCTAssertEqual(inner, "300:a300", note)
            XCTAssertEqual(lua.mainStackHeight, 0, note)
        }
    }

    func testACallWithMoreArgumentsThanAStackHoldsIsRefused() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)"
            let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
            try lua.run(Self.script)
            for size in [999_999, 1_000_000] {
                XCTAssertThrowsError(try lua.callGlobal("count", Array(repeating: "", count: size))) { error in
                    XCTAssertEqual(error as? LuaRuntime.LuaError, .runtime("stack overflow"), "\(size) [\(note)]")
                }
                XCTAssertEqual(lua.mainStackHeight, 0, "\(size) [\(note)]")
            }
            XCTAssertEqual(try lua.callGlobal("count", ["x"]), "1:x", note)
        }
    }

    func testPushJSONOnAFullStackPushesNothing() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)"
            let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
            var heights: [Int32] = []
            lua.register("fill") { rt in
                // The push helpers stop at the stack's limit (about 1,000,200 slots, 16 MB).
                for _ in 0..<1_000_400 { rt.pushNil() }
                heights.append(rt.argumentCount)
                rt.pushJSON(["k": [1, 2]])
                heights.append(rt.argumentCount)
                return 0
            }
            try lua.run(Self.script + "\nfunction f() fill() return 'after' end")
            XCTAssertEqual(try lua.callGlobal("f"), "after", note)
            XCTAssertEqual(heights.count, 2, note)
            XCTAssertTrue((heights.first ?? 0) > 1_000_000, "filled to \(heights.first ?? 0) [\(note)]")
            XCTAssertEqual(heights.first, heights.last, note)
            XCTAssertEqual(lua.mainStackHeight, 0, note)
            XCTAssertEqual(try lua.callGlobal("count", ["x"]), "1:x", note)
        }
    }
}
