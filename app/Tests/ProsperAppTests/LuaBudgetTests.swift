import XCTest
@testable import LuaRuntime

/// #1126: one instruction budget per host call (`run` / `callGlobal`) that no script can outrun. It is
/// shared by every coroutine of the state, it stays spent until the call returns (a script's own
/// pcall, xpcall or coroutine.resume cannot keep going, nor can a message or close handler), and no
/// finalizer runs (one would run outside it). The rows that must abort run in a default AND an allowLoad runtime. Every loop here is bounded,
/// so a regression fails its row instead of hanging the run.
final class LuaBudgetTests: XCTestCase {

    private static let spent = LuaRuntime.LuaError.runtime("execution budget exceeded")

    /// `body` defines `f`; calling `f` must throw exactly the budget error, in both runtimes.
    private func assertSpent(_ body: String, budget: Int32 = 100_000,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        for allowLoad in [false, true] {
            let lua = try LuaRuntime(maxInstructions: budget, allowLoad: allowLoad)
            try lua.run(body)
            assertCallSpent(lua, "f", "allowLoad: \(allowLoad)", file: file, line: line)
        }
    }

    private func assertCallSpent(_ lua: LuaRuntime, _ name: String, _ note: String, budget: Int32? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        do {
            let got = try lua.callGlobal(name, budget: budget)
            XCTFail("\(name) returned \(got ?? "nil") [\(note)]", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LuaRuntime.LuaError, Self.spent, note, file: file, line: line)
        }
    }

    // MARK: - The three ways past a per-thread, re-armable budget

    func testFreshCoroutinesShareTheBudget() throws {
        // 5,000,000 loop iterations in 1000 coroutines at a budget of 100,000 instructions.
        try assertSpent("""
            function f()
              local total = 0
              for k = 1, 1000 do
                coroutine.wrap(function() for i = 1, 5000 do total = total + 1 end end)()
              end
              return tostring(total)
            end
            """)
    }

    func testPcallCannotCatchASpentBudget() throws {
        for catcher in [
            "pcall(function() while true do end end)",
            "xpcall(function() while true do end end, function(m) return m end)",
            "coroutine.resume(coroutine.create(function() while true do end end))",
        ] {
            try assertSpent("""
                function f()
                  local n = 0
                  for k = 1, 5 do if not \(catcher) then n = n + 1 end end
                  return tostring(n)
                end
                """)
        }
    }

    func testFinalizersAreRefused() throws {
        for allowLoad in [false, true] {
            let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
            try lua.run("""
                function f()
                  local n = 0
                  setmetatable({}, {__gc = function() for i = 1, 3000000 do n = n + 1 end end})
                  collectgarbage()
                  return tostring(n)
                end
                function probe(mt) return select(2, pcall(setmetatable, {}, mt)) end
                function rows()
                  local plain = setmetatable({}, {__index = {x = 'kept'}})
                  local cleared = setmetatable(setmetatable({}, {}), nil)
                  return probe({__gc = false}) .. '|' .. plain.x .. '|' .. tostring(getmetatable(cleared))
                end
                ran = 'no'
                function late()
                  -- __gc added after setmetatable does not mark the object (Lua 5.4); churn through GC cycles
                  local mt = {}
                  setmetatable({}, mt)
                  mt.__gc = function() ran = 'yes' end
                  for i = 1, 200000 do local t = {i} end
                  return ran
                end
                """)
            let note = "allowLoad: \(allowLoad)"
            do {
                let got = try lua.callGlobal("f")
                XCTFail("f returned \(got ?? "nil") [\(note)]")
            } catch {
                guard case .runtime(let message)? = error as? LuaRuntime.LuaError else {
                    return XCTFail("\(error) [\(note)]")
                }
                XCTAssertTrue(message.hasSuffix("bad argument #2 to 'setmetatable' (__gc is not available)"),
                              "\(message) [\(note)]")
            }
            XCTAssertEqual(try lua.callGlobal("rows"),
                           "bad argument #2 to 'setmetatable' (__gc is not available)|kept|nil", note)
            XCTAssertEqual(try lua.callGlobal("late", budget: 10_000_000), "no", note)
        }
    }

    // MARK: - What keeps working

    func testASpentBudgetInsideAPcallInsideACoroutineReachesTheHost() throws {
        try assertSpent("""
            function f()
              return coroutine.wrap(function()
                pcall(function() while true do end end)
                return 'swallowed'
              end)()
            end
            """)
    }

    func testOrdinaryErrorsAreStillCaught() throws {
        let lua = try LuaRuntime(maxInstructions: 100_000)
        try lua.run("""
            function f()
              local a, b = pcall(error, 'boom', 0)
              local c, d = xpcall(function() error('boom', 0) end, debug.traceback)
              local e, g = coroutine.resume(coroutine.create(function() error('boom', 0) end))
              return tostring(a) .. ' ' .. b .. '|' .. tostring(c) .. ' ' .. d:sub(1, 21) .. '|'
                .. tostring(e) .. ' ' .. g
            end
            """)
        XCTAssertEqual(try lua.callGlobal("f"), "false boom|false boom\nstack traceback:|false boom")
    }

    func testTheNextCallAfterASpentBudgetHasTheFullBudget() throws {
        let lua = try LuaRuntime(maxInstructions: 100_000)
        // g runs 22,000 iterations of 4 instructions: 88% of the budget.
        try lua.run("""
            function spin() while true do end end
            function g() n = 0 for i = 1, 22000 do n = n + 1 end return tostring(n) end
            """)
        assertCallSpent(lua, "spin", "first call")
        XCTAssertEqual(try lua.callGlobal("g"), "22000")
        assertCallSpent(lua, "spin", "again")
        XCTAssertEqual(try lua.callGlobal("g"), "22000")
    }

    func testALongJobSplitOverManyCallsIsNotAborted() throws {
        let lua = try LuaRuntime(maxInstructions: 100_000)
        try lua.run("acc = 0 function chunk() for i = 1, 10000 do acc = acc + 1 end return tostring(acc) end")
        var last: String?
        for _ in 0..<30 { last = try lua.callGlobal("chunk") }   // about 12x the budget in total
        XCTAssertEqual(last, "300000")
    }

    func testACoroutineKeepsWorkingAcrossCallsAndIsChargedInEach() throws {
        let lua = try LuaRuntime(maxInstructions: 100_000)
        try lua.run("""
            mode = 'yield'
            co = coroutine.create(function()
              while true do
                if mode == 'spin' then while true do end end
                coroutine.yield('ok')
              end
            end)
            function step() local ok, v = coroutine.resume(co) return tostring(ok) .. ' ' .. tostring(v) end
            function spin() mode = 'spin' return step() end
            function fresh() return coroutine.wrap(function() return 'fresh' end)() end
            """)
        XCTAssertEqual(try lua.callGlobal("step"), "true ok")
        XCTAssertEqual(try lua.callGlobal("step"), "true ok")
        assertCallSpent(lua, "spin", "resumed across calls")
        XCTAssertEqual(try lua.callGlobal("fresh"), "fresh")
    }

    /// The abort point: the loop body is 4 VM instructions (GETTABUP, ADDI, SETTABUP, JMP), so it aborts
    /// when 4 x n reaches the budget. Tolerance: 0.1% (1,000 of 1,000,000), in the main thread and in a
    /// coroutine. Counts instructions, never time.
    func testTheAbortPointMatchesTheBudget() throws {
        let budget: Int32 = 1_000_000
        let lua = try LuaRuntime(maxInstructions: budget)
        try lua.run("""
            function main() n = 0 while true do n = n + 1 end end
            function inco() n = 0 coroutine.wrap(function() while true do n = n + 1 end end)() end
            function count() return tostring(n) end
            """)
        for name in ["main", "inco"] {
            assertCallSpent(lua, name, name)
            let n = Int(try lua.callGlobal("count") ?? "") ?? 0
            // Range first: 4 x n is computed only for 0 < n <= budget / 4.
            guard n > 0, n <= Int(budget) / 4 else { XCTFail("\(name): n = \(n)"); continue }
            XCTAssertTrue(Int(budget) - 4 * n <= 1_000, "\(name): 4 x \(n) is not within 1,000 of \(budget)")
        }
    }

    func testANonPositiveBudgetAbortsAtOnce() throws {
        for budget: Int32 in [0, -5] {
            let lua = try LuaRuntime(maxInstructions: budget)
            do {
                try lua.run("for i = 1, 1000 do end")
                XCTFail("ran under budget \(budget)")
            } catch {
                XCTAssertEqual(error as? LuaRuntime.LuaError, Self.spent, "budget \(budget)")
            }
        }
        let lua = try LuaRuntime()
        try lua.run("function f() for i = 1, 1000 do end return 'ran' end")
        assertCallSpent(lua, "f", "per-call budget 0", budget: 0)
        XCTAssertEqual(try lua.callGlobal("f"), "ran")
    }

    // MARK: - Rider R1126-1: collectgarbage only reports

    func testCollectgarbageOnlyReports() throws {
        let lua = try LuaRuntime()
        try lua.run("""
            function f()
              local r = {type(collectgarbage('count')), tostring(collectgarbage()), tostring(collectgarbage('collect')),
                         tostring(collectgarbage('step')), tostring(collectgarbage('stop')),
                         tostring(collectgarbage('isrunning')), tostring(collectgarbage('generational')),
                         tostring(collectgarbage('bogus'))}
              return table.concat(r, ' ')
            end
            """)
        XCTAssertEqual(try lua.callGlobal("f"), "number 0 0 0 0 true 0 0")
    }

    // MARK: - Round 2: no handler runs past a spent budget

    private static let spin = "function() for i = 1, 3000000 do end end"
    private static let longHandler = "function(m) for i = 1, 3000000 do n = n + 1 end return m end"
    private static let longClose =
        "local x <close> = setmetatable({}, {__close = function() for i = 1, 3000000 do n = n + 1 end end})"
    private static let caseA = "function f() n = 0 xpcall(\(spin), \(longHandler)) return 'returned' end"
    private static let caseB = """
        function f() n = 0 return coroutine.wrap(function() \(longClose) for i = 1, 3000000 do end return 'returned' end)() end
        """

    /// `body` defines `f`, which zeroes the global `n` and leaves a handler that would count it up 3,000,000
    /// times. `f` must throw exactly the budget error and `n` must stay at or below `maxN`, in both runtimes.
    private func assertHandlerCharged(_ body: String, maxN: Int,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)"
            let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
            try lua.run(body + "\nfunction count() return tostring(n) end")
            assertCallSpent(lua, "f", note, file: file, line: line)
            let got = try lua.callGlobal("count")
            guard let n = Int(got ?? "") else { XCTFail("n = \(got ?? "nil") [\(note)]", file: file, line: line); continue }
            XCTAssertTrue(n >= 0 && n <= maxN, "n = \(n), want at most \(maxN) [\(note)]", file: file, line: line)
        }
    }

    func testAnXpcallMessageHandlerIsCharged() throws {
        try assertHandlerCharged(Self.caseA, maxN: 0)
    }

    func testAnXpcallMessageHandlerInACoroutineIsCharged() throws {
        try assertHandlerCharged("""
            function f() n = 0 return coroutine.wrap(function() xpcall(\(Self.spin), \(Self.longHandler)) return 'returned' end)() end
            """, maxN: 0)
    }

    func testTheCloseHandlerOfACoroutineTheBudgetEndedIsCharged() throws {
        try assertHandlerCharged(Self.caseB, maxN: 0)
    }

    func testTheCloseHandlerOfACoroutineTheBudgetEndedUnderPcallIsCharged() throws {
        try assertHandlerCharged("""
            function f() n = 0 pcall(coroutine.wrap(function() \(Self.longClose) for i = 1, 3000000 do end end)) return 'returned' end
            """, maxN: 0)
    }

    /// An ordinary error starts the handler under budget; it may spend what is left (4 instructions per
    /// iteration: at most 25,000 of a 100,000 budget), never more.
    func testAMessageHandlerForAnOrdinaryErrorStopsWhenTheBudgetIsSpent() throws {
        try assertHandlerCharged("""
            function f() n = 0 xpcall(function() error('boom') end, \(Self.longHandler)) return 'returned' end
            """, maxN: 25_000)
    }

    /// Already closed before round 2 (pins): coroutine.close after a spent resume, and a main-thread close
    /// handler under pcall.
    func testCloseHandlersAlreadyChargedStayCharged() throws {
        try assertHandlerCharged("""
            function f()
              n = 0
              local co = coroutine.create(function() \(Self.longClose) for i = 1, 3000000 do end end)
              coroutine.resume(co)
              coroutine.close(co)
              return 'returned'
            end
            """, maxN: 0)
        try assertHandlerCharged("""
            function f() n = 0 pcall(function() \(Self.longClose) for i = 1, 3000000 do end end) return 'returned' end
            """, maxN: 0)
    }

    func testOrdinaryMessageAndCloseHandlersRunToTheEnd() throws {
        for allowLoad in [false, true] {
            let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
            try lua.run("""
                function f()
                  n = 0
                  local count = function() for i = 1, 1000 do n = n + 1 end end
                  local ok, m = xpcall(function() error('boom', 0) end, function(e) count() return 'h:' .. e end)
                  local seen, cseen
                  pcall(function()
                    local x <close> = setmetatable({}, {__close = function(_, e) count() seen = e end})
                    error('main', 0)
                  end)
                  pcall(coroutine.wrap(function()
                    local y <close> = setmetatable({}, {__close = function(_, e) count() cseen = e end})
                    error('co', 0)
                  end))
                  return tostring(ok) .. ' ' .. m .. ' ' .. tostring(seen) .. ' ' .. tostring(cseen) .. ' ' .. tostring(n)
                end
                """)
            XCTAssertEqual(try lua.callGlobal("f"), "false h:boom main co 3000", "allowLoad: \(allowLoad)")
        }
    }

    func testTheNextCallAfterAHandlerWasStoppedHasTheFullBudget() throws {
        let lua = try LuaRuntime(maxInstructions: 100_000)
        try lua.run("function g() k = 0 for i = 1, 22000 do k = k + 1 end return tostring(k) end")
        for (name, body) in [("A", Self.caseA), ("B", Self.caseB)] {
            try lua.run(body)
            assertCallSpent(lua, "f", name)
            XCTAssertEqual(try lua.callGlobal("g"), "22000", "after \(name)")
        }
    }
}
