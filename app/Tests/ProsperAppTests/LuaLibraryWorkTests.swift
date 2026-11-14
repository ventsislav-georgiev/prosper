import Foundation
import XCTest
@testable import LuaRuntime

/// #1145: work a library C function does inside one instruction (pattern matching, string.rep, %q, the table
/// functions, long-string comparisons, large allocations) is charged against the call's budget, so it ends a call
/// like the instruction count does. Every charge site has a row: the same call at the same budget returns with a
/// small input and is ended by a larger one, so only the charge tells the two apart. Inputs are small (a few times
/// the row's budget); every loop is bounded.
final class LuaLibraryWorkTests: XCTestCase {

    private static let spent = LuaRuntime.LuaError.runtime("execution budget exceeded")

    /// One charge site: `setup` defines globals and `f(n)`; `f(under)` returns at `budget`, `f(over)` is ended.
    struct Site { let setup: String; let budget: Int32; let under: Int; let over: Int }

    /// Every charge site, by name (literal; testTheSiteTableIsComplete pins the names).
    static let sites: [String: Site] = [
        "str_rep": Site(setup: #"function f(n) return tostring(#string.rep("", tonumber(n))) end"#,
                        budget: 10_000, under: 1_000, over: 1_000_000),
        "class": Site(setup: #"""
            S = ("b"):rep(8000); P = "[" .. ("a"):rep(1000) .. "b]+$"
            function f(n) return tostring(string.find(S, P, -tonumber(n))) end
            """#, budget: 10_000, under: 100, over: 8_000),
        "max_expand": Site(setup: #"""
            A = ("a"):rep(1 << 20)
            function f(n) return tostring(string.find(A, "a*$", -tonumber(n))) end
            """#, budget: 10_000, under: 1_000, over: 1 << 20),
        "capture": Site(setup: #"""
            X = ("x"):rep(65535) .. "y"
            function f(n) return tostring(string.find(X, "^(x*)%1y", -tonumber(n))) end
            """#, budget: 100_000, under: 1_024, over: 65_536),
        "match": Site(setup: #"""
            P = ("a"):rep(200) .. "b"
            function f(n) return tostring(string.match(("a"):rep(tonumber(n)), P)) end
            """#, budget: 10_000, under: 100, over: 2_000),
        "balance": Site(setup: #"function f(n) return tostring(string.find(("("):rep(tonumber(n)), "%b()")) end"#,
                        budget: 10_000, under: 100, over: 2_000),
        "frontier": Site(setup: #"""
            P = "%f[" .. ("a"):rep(1000) .. "]"
            function f(n) return tostring(string.find(("b"):rep(tonumber(n)), P)) end
            """#, budget: 10_000, under: 50, over: 2_000),
        "find_scan": Site(setup: #"""
            H = ("a"):rep(65536)
            function f(n)
              local k = 0
              for i = 1, tonumber(n) do if string.find(H, "zq", 1, true) then k = k + 1 end end
              return tostring(k)
            end
            """#, budget: 1_000, under: 2, over: 50),
        "find_candidate": Site(setup: #"""
            H = ("a"):rep(12288); P = ("a"):rep(4095) .. "b"
            function f(n) return tostring(string.find(H, P, -tonumber(n), true)) end
            """#, budget: 10_000, under: 4_200, over: 12_288),
        "quoted": Site(setup: #"function f(n) return tostring(#string.format("%q", ("a"):rep(tonumber(n)))) end"#,
                       budget: 10_000, under: 1_000, over: 50_000),
        "insert": Site(setup: #"""
            T = {}; for i = 1, 50000 do T[i] = "p" end
            function f(n) table.insert(T, #T - tonumber(n) + 1, "p"); return tostring(#T) end
            """#, budget: 10_000, under: 100, over: 50_000),
        "remove": Site(setup: #"""
            T = {}; for i = 1, 50000 do T[i] = "p" end
            function f(n) table.remove(T, #T - tonumber(n) + 1); return tostring(#T) end
            """#, budget: 10_000, under: 100, over: 49_000),
        "move": Site(setup: #"""
            T = {}; for i = 1, 50000 do T[i] = "p" end
            function f(n) table.move(T, 1, tonumber(n), 1, T); return tostring(#T) end
            """#, budget: 10_000, under: 100, over: 50_000),
        "concat": Site(setup: #"""
            T = {}; for i = 1, 50000 do T[i] = "p" end
            function f(n) return tostring(#table.concat(T, "", 1, tonumber(n))) end
            """#, budget: 10_000, under: 100, over: 50_000),
        "sort": Site(setup: #"""
            T = {}
            for _, m in ipairs({100, 16384}) do local t = {}; for i = 1, m do t[i] = (i * 7919) % m end; T[m] = t end
            function f(n) table.sort(T[tonumber(n)]); return "sorted" end
            """#, budget: 10_000, under: 100, over: 16_384),
        "lt": Site(setup: #"""
            A = ("x"):rep(65536); B = ("x"):rep(65535) .. "y"
            function f(n) local k = 0; for i = 1, tonumber(n) do if A < B then k = k + 1 end end; return tostring(k) end
            """#, budget: 1_000, under: 2, over: 50),
        "le": Site(setup: #"""
            A = ("x"):rep(65536); B = ("x"):rep(65535) .. "y"
            function f(n) local k = 0; for i = 1, tonumber(n) do if A <= B then k = k + 1 end end; return tostring(k) end
            """#, budget: 1_000, under: 2, over: 50),
        "eq": Site(setup: #"""
            A = ("x"):rep(65536); B = ("x"):rep(65536)
            function f(n) local k = 0; for i = 1, tonumber(n) do if A == B then k = k + 1 end end; return tostring(k) end
            """#, budget: 1_000, under: 2, over: 50),
        "alloc": Site(setup: #"""
            A = ("x"):rep(256 * 1024)
            function f(n) local k = 0; for i = 1, tonumber(n) do k = k + #(A .. "y") end; return tostring(k) end
            """#, budget: 1_000, under: 2, over: 50),
    ]

    /// f(under) returns, f(over) is ended with the budget error and leaves the stack at rest, and the runtime then
    /// returns f(under) again (the next call has its own limit).
    private func assertCharged(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let site = Self.sites[name] else { return XCTFail("no site \(name)", file: file, line: line) }
        let lua = try LuaRuntime()
        try lua.run(site.setup)
        XCTAssertNoThrow(try lua.callGlobal("f", [String(site.under)], budget: site.budget), "under", file: file, line: line)
        do {
            let got = try lua.callGlobal("f", [String(site.over)], budget: site.budget)
            XCTFail("\(name): f(\(site.over)) returned \(got ?? "nil")", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LuaRuntime.LuaError, Self.spent, name, file: file, line: line)
        }
        XCTAssertEqual(lua.mainStackHeight, 0, "\(name): stack after the error", file: file, line: line)
        XCTAssertNoThrow(try lua.callGlobal("f", [String(site.under)], budget: site.budget), "after", file: file, line: line)
    }

    func testTheSiteTableIsComplete() {
        XCTAssertEqual(Set(Self.sites.keys), [
            "str_rep", "class", "max_expand", "capture", "match", "balance", "frontier", "find_scan", "find_candidate",
            "quoted", "insert", "remove", "move", "concat", "sort", "lt", "le", "eq", "alloc",
        ])
    }

    // MARK: - One row per charge site (lstrlib.c, ltablib.c, lvm.c, clua_shim.c)

    func testStringRep() throws { try assertCharged("str_rep") }
    func testPatternSetClass() throws { try assertCharged("class") }
    func testPatternRepetition() throws { try assertCharged("max_expand") }
    func testPatternBackReference() throws { try assertCharged("capture") }
    func testPatternItems() throws { try assertCharged("match") }
    func testPatternBalance() throws { try assertCharged("balance") }
    func testPatternFrontier() throws { try assertCharged("frontier") }
    func testPlainFindScan() throws { try assertCharged("find_scan") }
    func testPlainFindCandidates() throws { try assertCharged("find_candidate") }
    func testFormatQuoted() throws { try assertCharged("quoted") }
    func testTableInsert() throws { try assertCharged("insert") }
    func testTableRemove() throws { try assertCharged("remove") }
    func testTableMove() throws { try assertCharged("move") }
    func testTableConcat() throws { try assertCharged("concat") }
    func testTableSort() throws { try assertCharged("sort") }
    func testLongStringLessThan() throws { try assertCharged("lt") }
    func testLongStringLessEqual() throws { try assertCharged("le") }
    func testLongStringEqual() throws { try assertCharged("eq") }
    func testLargeAllocations() throws { try assertCharged("alloc") }

    // MARK: - Ordinary heavy use passes under the default budget

    private func callDefault(_ body: String) throws -> String? {
        let lua = try LuaRuntime()
        try lua.run("function f() \(body) end")
        return try lua.callGlobal("f")
    }

    func testLinearGsubOverOneMebibyte() throws {
        XCTAssertEqual(try callDefault(#"""
            local s = ("hello world "):rep(87382)
            local r, n = s:gsub("world", "there")
            return tostring(n) .. "," .. #r
            """#), "87382,1048584")
    }

    func testSortOfOneHundredThousandShortStrings() throws {
        XCTAssertEqual(try callDefault(#"""
            local t = {}
            for i = 1, 100000 do t[i] = "k" .. ((i * 7919) % 100000) end
            table.sort(t)
            return t[1] .. "," .. t[#t]
            """#), "k0,k99999")
    }

    func testConcatOfOneHundredThousandParts() throws {
        XCTAssertEqual(try callDefault(#"""
            local t = {}
            for i = 1, 100000 do t[i] = "p" end
            return tostring(#table.concat(t, ","))
            """#), "199999")
    }

    func testPlainFindInOneMebibyte() throws {
        XCTAssertEqual(try callDefault(#"""
            local s = ("abcdefgh"):rep(131072) .. "needle"
            return tostring(s:find("needle", 1, true))
            """#), "1048577")
    }

    func testRepToOneMebibyte() throws {
        XCTAssertEqual(try callDefault(#"return tostring(#("x"):rep(1048576))"#), "1048576")
    }

    /// Many small strings and tables, near the instruction budget: small allocations are not charged.
    func testSmallStringAndTableChurn() throws {
        XCTAssertEqual(try callDefault(#"""
            local n = 0
            for i = 1, 600000 do local t = {i, tostring(i)}; local k = "k" .. i; n = n + #t + #k end
            return tostring(n)
            """#), "5288895")
    }

    // MARK: - Host functions are not library work

    /// A host function that waits and hands back a large string is neither timed nor charged; the script goes on.
    func testASlowHostFunctionIsNotCharged() throws {
        let lua = try LuaRuntime()
        lua.register("slow") { rt in
            Thread.sleep(forTimeInterval: 0.1)  // far longer than this call's limit of work would take
            rt.push(String(repeating: "x", count: 4 << 20))  // more units than the limit, were a host push charged
            return 1
        }
        try lua.run("function f() local s = slow(); local k = 0; for i = 1, 10 do k = k + 1 end; return tostring(#s + k) end")
        XCTAssertEqual(try lua.callGlobal("f", budget: 1_000), "4194314")
    }

    // MARK: - One limit per outermost call

    /// Each half charges about 60% of the limit at budget 10,000; one call holding both is ended.
    private static let halves = #"""
        function half() string.rep("", 150000); return "half" end
        function g() return half() end
        """#

    /// What the host function got back from its call into the runtime.
    final class Seen { var lines: [String] = [] }

    func testANestedCallKeepsTheOuterLimit() throws {
        let lua = try LuaRuntime()
        let seen = Seen()
        lua.register("inner") { rt in
            do { seen.lines.append(try rt.callGlobal("g", budget: Int32.max) ?? "nil") } catch { seen.lines.append("threw \(error)") }
            return 0
        }
        try lua.run(Self.halves + "\nfunction f() half(); inner(); return 'done' end")
        XCTAssertEqual(try lua.callGlobal("g", budget: 10_000), "half")
        XCTAssertThrowsError(try lua.callGlobal("f", budget: 10_000)) {
            XCTAssertEqual($0 as? LuaRuntime.LuaError, Self.spent)
        }
        XCTAssertEqual(seen.lines, ["threw runtime(\"execution budget exceeded\")"])
        XCTAssertEqual(lua.mainStackHeight, 0)
    }

    func testCoroutinesShareTheLimit() throws {
        let lua = try LuaRuntime()
        try lua.run(Self.halves + #"""

            function co(k) for i = 1, tonumber(k) do coroutine.wrap(half)() end; return "done" end
            """#)
        XCTAssertEqual(try lua.callGlobal("co", ["1"], budget: 10_000), "done")
        XCTAssertThrowsError(try lua.callGlobal("co", ["4"], budget: 10_000)) {
            XCTAssertEqual($0 as? LuaRuntime.LuaError, Self.spent)
        }
    }

    func testPcallCannotCatchTheLimit() throws {
        let lua = try LuaRuntime()
        try lua.run(#"""
            function f()
              local n = 0
              for k = 1, 4 do if not pcall(string.rep, "", 1000000) then n = n + 1 end end
              return tostring(n)
            end
            """#)
        XCTAssertThrowsError(try lua.callGlobal("f", budget: 10_000)) {
            XCTAssertEqual($0 as? LuaRuntime.LuaError, Self.spent)
        }
    }

    func testEachCallHasItsOwnLimit() throws {
        let lua = try LuaRuntime()
        try lua.run(Self.halves + "\nfunction both() half(); half(); return 'both' end")
        XCTAssertThrowsError(try lua.callGlobal("both", budget: 10_000))
        for _ in 1...3 { XCTAssertEqual(try lua.callGlobal("g", budget: 10_000), "half") }
    }
}
