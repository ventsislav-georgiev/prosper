import CLua
import Foundation
import XCTest
@testable import LuaRuntime

/// #1127: one memory cap per Lua runtime, kept by the counting allocator in the shim (clua_shim.c clua_mem_alloc).
/// A growth past the cap inside a call fails that call with "not enough memory"; the runtime stays usable and the
/// failed call's garbage is collected. Every row that reaches a cap uses a small cap of its own (1 MiB) and bounded
/// loops; nothing here allocates more than a few MiB without the cap either.
final class LuaMemoryCapTests: XCTestCase {

    private static let smallCap = 1 << 20

    /// Calling `name` must fail with Lua's memory error (and nothing else).
    private func assertRefused(_ lua: LuaRuntime, _ name: String, _ note: String, args: [String] = [],
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            let got = try lua.callGlobal(name, args)
            XCTFail("\(name) returned \(got ?? "nil") [\(note)]", file: file, line: line)
        } catch {
            guard case .runtime(let message)? = error as? LuaRuntime.LuaError else {
                return XCTFail("\(name) threw \(error) [\(note)]", file: file, line: line)
            }
            XCTAssertTrue(message.hasSuffix("not enough memory"), "\(message) [\(note)]", file: file, line: line)
        }
    }

    /// A runtime with the small cap, `body` run, plus `g`: a call that needs a quarter of the cap.
    private func smallRuntime(_ body: String, allowLoad: Bool) throws -> LuaRuntime {
        let lua = try LuaRuntime(allowLoad: allowLoad, memoryLimit: Self.smallCap)
        try lua.run(body + "\nfunction g() return string.rep('y', 256 * 1024):sub(1, 3) end")
        return lua
    }

    /// After a refused call: the next call works and the refused call's garbage is gone.
    private func assertUsableAfterwards(_ lua: LuaRuntime, rest: Int, _ note: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(lua.memoryInUse, rest + (64 << 10), "garbage of the refused call [\(note)]", file: file, line: line)
        XCTAssertEqual(try lua.callGlobal("g"), "yyy", "the next call [\(note)]", file: file, line: line)
    }

    // MARK: - Past the cap: an ordinary error, then the next call works

    func testAStringPastTheCapIsRefused() throws {
        for allowLoad in [false, true] {
            let lua = try smallRuntime("function f() local s = string.rep('x', 2 << 20) return tostring(#s) end",
                                       allowLoad: allowLoad)
            let rest = lua.memoryInUse
            assertRefused(lua, "f", "allowLoad: \(allowLoad)")
            XCTAssertLessThanOrEqual(lua.memoryPeak, Self.smallCap, "allowLoad: \(allowLoad)")
            assertUsableAfterwards(lua, rest: rest, "allowLoad: \(allowLoad)")
        }
    }

    func testATablePastTheCapIsRefused() throws {
        for allowLoad in [false, true] {
            let lua = try smallRuntime("function f() local t = {} for i = 1, 200000 do t[i] = i end return tostring(#t) end",
                                       allowLoad: allowLoad)
            let rest = lua.memoryInUse
            assertRefused(lua, "f", "allowLoad: \(allowLoad)")
            XCTAssertLessThanOrEqual(lua.memoryPeak, Self.smallCap, "allowLoad: \(allowLoad)")
            assertUsableAfterwards(lua, rest: rest, "allowLoad: \(allowLoad)")
        }
    }

    func testACoroutineStackPastTheCapIsRefused() throws {
        for allowLoad in [false, true] {
            let lua = try smallRuntime("""
                local function deep(n) if n == 0 then return 0 end return 1 + deep(n - 1) end
                function f() return tostring(coroutine.wrap(function() return deep(100000) end)()) end
                """, allowLoad: allowLoad)
            let rest = lua.memoryInUse
            assertRefused(lua, "f", "allowLoad: \(allowLoad)")
            XCTAssertLessThanOrEqual(lua.memoryPeak, Self.smallCap, "allowLoad: \(allowLoad)")
            assertUsableAfterwards(lua, rest: rest, "allowLoad: \(allowLoad)")
        }
    }

    func testAHostResultPastTheCapFailsTheCallOnceTheHostReturns() throws {
        for allowLoad in [false, true] {
            let lua = try LuaRuntime(allowLoad: allowLoad, memoryLimit: Self.smallCap)
            lua.register("big") { rt in rt.push(String(repeating: "b", count: 2 << 20)); return 1 }
            lua.register("small") { rt in rt.push(String(repeating: "s", count: 1024)); return 1 }
            try lua.run("""
                function f() local s = big() return 'kept' end
                function h() return tostring(#small()) end
                function g() return string.rep('y', 256 * 1024):sub(1, 3) end
                """)
            let rest = lua.memoryInUse
            assertRefused(lua, "f", "allowLoad: \(allowLoad)")
            XCTAssertEqual(try lua.callGlobal("h"), "1024", "allowLoad: \(allowLoad)")
            assertUsableAfterwards(lua, rest: rest, "allowLoad: \(allowLoad)")
        }
    }

    /// The cap is off only while host code runs: once a host function returns, the rest of the call is capped again,
    /// also after a host function that called back into the same runtime (LuaRuntime does not refuse that).
    func testTheCapIsBackOnAfterAHostFunctionReturns() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)"
            let lua = try smallRuntime("""
                local function after(hostfn) local v = hostfn() local s = string.rep('x', 2 << 20) return v .. #s end
                function f() return after(small) end
                function r() return after(reenter) end
                function inner() return 'inner' end
                """, allowLoad: allowLoad)
            var reentered = ""
            lua.register("small") { rt in rt.push("small"); return 1 }
            lua.register("reenter") { rt in
                reentered = (try? rt.callGlobal("inner")) ?? "failed"
                rt.push(reentered)
                return 1
            }
            let rest = lua.memoryInUse
            assertRefused(lua, "f", note)
            assertUsableAfterwards(lua, rest: rest, note)
            assertRefused(lua, "r", note)
            XCTAssertEqual(reentered, "inner", "the host function called back into the runtime [\(note)]")
            assertUsableAfterwards(lua, rest: rest, note)
        }
    }

    func testArgumentsPastTheCapFailTheCallNotTheHost() throws {
        for allowLoad in [false, true] {
            let lua = try smallRuntime("function f(s) return tostring(#s) end", allowLoad: allowLoad)
            let rest = lua.memoryInUse
            assertRefused(lua, "f", "allowLoad: \(allowLoad)", args: [String(repeating: "a", count: 2 << 20)])
            assertUsableAfterwards(lua, rest: rest, "allowLoad: \(allowLoad)")
            XCTAssertEqual(try lua.callGlobal("f", ["abc"]), "3", "allowLoad: \(allowLoad)")
        }
    }

    func testACompilePastTheCapIsACompileError() throws {
        for allowLoad in [false, true] {
            let lua = try smallRuntime("", allowLoad: allowLoad)
            XCTAssertThrowsError(try lua.run("return '" + String(repeating: "x", count: 2 << 20) + "'")) { error in
                XCTAssertEqual(error as? LuaRuntime.LuaError, .compile("not enough memory"), "allowLoad: \(allowLoad)")
            }
            XCTAssertEqual(try lua.callGlobal("g"), "yyy", "allowLoad: \(allowLoad)")
        }
    }

    /// Both errors in one call: the memory error is caught by the script's own pcall, then the budget runs out.
    /// The host reports the budget (LuaRuntime.pcall: a spent budget wins over whatever unwound last).
    func testACallThatHitsTheCapThenSpendsItsBudgetReportsTheBudget() throws {
        for allowLoad in [false, true] {
            let lua = try LuaRuntime(maxInstructions: 2_000_000, allowLoad: allowLoad, memoryLimit: Self.smallCap)
            try lua.run("""
                function f()
                  local keep = {}
                  pcall(function() for i = 1, 200000 do keep[i] = i end end)
                  for i = 1, 100000000 do end
                  return 'finished'
                end
                """)
            XCTAssertThrowsError(try lua.callGlobal("f")) { error in
                XCTAssertEqual(error as? LuaRuntime.LuaError, .runtime("execution budget exceeded"), "allowLoad: \(allowLoad)")
            }
            XCTAssertGreaterThan(lua.memoryPeak, Self.smallCap / 2, "the table reached the cap first [allowLoad: \(allowLoad)]")
        }
    }

    // MARK: - The count

    func testAFreedBufferLowersTheCount() throws {
        let lua = try LuaRuntime()
        try lua.run("function f() local s = string.rep('x', 300000) return 'ok' end")
        let before = lua.memoryInUse
        XCTAssertEqual(try lua.callGlobal("f"), "ok")
        // string.rep builds in a buffer, then makes the string and frees the buffer within the call.
        XCTAssertGreaterThanOrEqual(lua.memoryPeak, before + 550_000, "buffer and string held at once")
        XCTAssertLessThan(lua.memoryInUse - before, 450_000, "the buffer was freed")
    }

    /// The allocator alone, on a counter of the test's own (no Lua state).
    func testTheCountFollowsGrowShrinkAndFree() throws {
        var m = clua_mem(used: 0, peak: 0, cap: 1 << 20, enforce: 1, refused: 0, work: 0, worklimit: 0, main: nil)
        // With no block, the old size is a type tag (lua_Alloc): it must not be taken off.
        var p = clua_mem_alloc(&m, nil, Int(LUA_TTABLE), 1000)
        XCTAssertTrue(p != nil)
        XCTAssertEqual(m.used, 1000)
        p = clua_mem_alloc(&m, p, 1000, 4000)
        XCTAssertTrue(p != nil)
        XCTAssertEqual(m.used, 4000)
        p = clua_mem_alloc(&m, p, 4000, 400)
        XCTAssertTrue(p != nil)
        XCTAssertEqual(m.used, 400, "a shrink lowers the count")
        XCTAssertEqual(m.peak, 4000)
        XCTAssertTrue(clua_mem_alloc(&m, p, 400, 0) == nil)
        XCTAssertEqual(m.used, 0, "a free lowers the count")
        XCTAssertEqual(m.refused, 0)
    }

    func testTheCapRefusesGrowthOnlyWhileEnforced() throws {
        var m = clua_mem(used: 0, peak: 0, cap: 1000, enforce: 1, refused: 0, work: 0, worklimit: 0, main: nil)
        var a = clua_mem_alloc(&m, nil, 0, 600)
        XCTAssertTrue(a != nil)
        XCTAssertTrue(clua_mem_alloc(&m, nil, 0, 600) == nil, "past the cap")
        XCTAssertEqual(m.refused, 1)
        XCTAssertEqual(m.used, 600)
        a = clua_mem_alloc(&m, a, 600, 1000)
        XCTAssertTrue(a != nil, "up to the cap exactly")
        XCTAssertEqual(m.used, 1000)
        XCTAssertTrue(clua_mem_alloc(&m, nil, 0, 1) == nil)
        m.enforce = 0
        let b = clua_mem_alloc(&m, nil, 0, 600)
        XCTAssertTrue(b != nil, "not enforced: counted, not refused")
        XCTAssertEqual(m.used, 1600)
        m.enforce = 1
        XCTAssertTrue(clua_mem_alloc(&m, nil, 0, 1) == nil, "over the cap: no growth")
        a = clua_mem_alloc(&m, a, 1000, 100)
        XCTAssertTrue(a != nil, "over the cap: a shrink still succeeds")
        XCTAssertEqual(m.used, 700)
        XCTAssertTrue(clua_mem_alloc(&m, a, 100, 0) == nil)
        XCTAssertTrue(clua_mem_alloc(&m, b, 600, 0) == nil)
        XCTAssertEqual(m.used, 0)
    }

    /// Sizes come from Lua: a growth that would wrap the count is refused even with the cap off, and a size
    /// larger than the count never takes it below zero. Only small real blocks are allocated.
    func testSizesThatWouldWrapTheCountAreRefused() throws {
        let nearTop = Int(bitPattern: UInt.max - 8)
        var m = clua_mem(used: nearTop, peak: 0, cap: 1 << 20, enforce: 0, refused: 0, work: 0, worklimit: 0, main: nil)
        let p = clua_mem_alloc(&m, nil, 0, 64)
        XCTAssertTrue(p == nil, "the count would wrap")
        if p != nil { free(p) }
        XCTAssertEqual(m.used, nearTop)
        XCTAssertEqual(m.refused, 1)

        var n = clua_mem(used: 0, peak: 0, cap: 1 << 20, enforce: 1, refused: 0, work: 0, worklimit: 0, main: nil)
        var q = clua_mem_alloc(&n, nil, 0, 64)
        XCTAssertTrue(q != nil)
        n.used = 8
        q = clua_mem_alloc(&n, q, 64, 16)
        XCTAssertTrue(q != nil)
        XCTAssertEqual(n.used, 0, "a shrink larger than the count stops at zero")
        n.used = 8
        XCTAssertTrue(clua_mem_alloc(&n, q, 16, 0) == nil)
        XCTAssertEqual(n.used, 0, "a free larger than the count stops at zero")
    }

    // MARK: - What a runtime could take before, and the shipped cap

    /// Facts: the state LuaRuntime made before #1127 (luaL_newstate: realloc, no limit) hands a script 8 MiB
    /// without refusing; the shipped cap leaves the same 8 MiB to a script.
    func testTheUncappedAllocatorHandsAScriptEightMiB() throws {
        let L = try XCTUnwrap(luaL_newstate())
        defer { lua_close(L) }
        luaL_openlibs(L)
        XCTAssertEqual(luaL_loadstring(L, """
            collectgarbage('collect') collectgarbage('stop')
            local before = collectgarbage('count')
            local s = string.rep('x', 8 << 20)
            return (collectgarbage('count') - before) * 1024
            """), LUA_OK)
        XCTAssertEqual(clua_pcall(L, 0, 1, 0), LUA_OK)
        let grew = lua_tonumberx(L, -1, nil)
        XCTAssertGreaterThanOrEqual(grew, Double(8 << 20))
        print("LUAMEM uncapped: an 8 MiB string grew the state by \(grew) bytes, nothing refused")

        let lua = try LuaRuntime()
        try lua.run("function f() return tostring(#string.rep('x', 8 << 20)) end")
        XCTAssertEqual(try lua.callGlobal("f"), "\(8 << 20)")
    }

    /// Driver for one extension *.test.lua, as ExtensionLuaSuiteTests runs it (standard libraries, the harness dir
    /// on package.path, arg[0] = the file, os.exit recorded instead of run). Returns "" on a pass.
    private static let suiteDriver = """
        local path, harness = ...
        package.path = harness .. "/?.lua;" .. package.path
        arg = { [0] = path }
        local code
        os.exit = function(c)
          if code == nil then
            if c == nil or c == true then code = 0 elseif c == false then code = 1 else code = math.tointeger(c) or 1 end
          end
          error("os.exit(" .. code .. ")", 0)
        end
        local chunk, err = loadfile(path)
        if not chunk then return tostring(err) end
        local ok, msg = xpcall(chunk, debug.traceback)
        if code ~= nil then return code == 0 and "" or ("os.exit(" .. code .. ")") end
        return ok and "" or tostring(msg)
        """

    /// The extension's init.lua loaded through the harness; returns the bytes it holds at rest, or "error: ...".
    private static let restDriver = """
        local init, harness = ...
        package.path = harness .. "/?.lua;" .. package.path
        arg = { [0] = init }
        local h = require("harness")
        local host = h.makeHost{}
        collectgarbage("collect") collectgarbage("collect")
        local base = collectgarbage("count")
        local ok, err = pcall(h.load, init, host)
        collectgarbage("collect") collectgarbage("collect")
        if not ok then return "error: " .. tostring(err) end
        return string.format("%.0f", (collectgarbage("count") - base) * 1024)
        """

    /// Runs `driver` with two string arguments on a fresh state with the shipped allocator, the cap enforced over
    /// the call. Returns the driver's string, the peak, and (after two full collections) the shim's count and
    /// Lua's own count read at the same point.
    private func runCapped(_ driver: String, _ a: String, _ b: String, cap: Int)
        -> (result: String, peak: Int, used: Int, luaCount: Int) {
        guard let L = clua_newstate(cap), let mem = clua_mem_of(L) else { return ("clua_newstate failed", 0, 0, -1) }
        defer { clua_close(L) }
        luaL_openlibs(L)
        var result = "driver did not compile"
        if luaL_loadstring(L, driver) == LUA_OK {
            lua_pushstring(L, a)
            lua_pushstring(L, b)
            clua_mem_enforce(L, 1)
            let status = clua_pcall(L, 2, 1, 0)
            clua_mem_enforce(L, 0)
            let text = clua_tostring(L, -1).map { String(cString: $0) } ?? "(not a string)"
            result = status == LUA_OK ? text : "driver: " + text
            clua_pop(L, 1)
        }
        let peak = mem.pointee.peak
        guard luaL_loadstring(L, "collectgarbage('collect') collectgarbage('collect') return collectgarbage('count')") == LUA_OK,
              clua_pcall(L, 0, 1, 0) == LUA_OK else { return (result, peak, mem.pointee.used, -1) }
        let used = mem.pointee.used   // nothing allocates between Lua's read and this one
        let kib = lua_tonumberx(L, -1, nil)
        let luaCount = kib.isFinite && kib >= 0 && kib < 1e12 ? Int(kib * 1024) : -1
        return (result, peak, used, luaCount)
    }

    /// Every extension Lua suite passes on a state with the shipped allocator and cap, and at the end the shim's
    /// count equals Lua's own (exact across every grow, shrink and free of a real workload). Prints the peaks.
    func testTheBuiltInSuitesPassUnderTheShippedCapWithAnExactCount() throws {
        try withProcessLocale("C") {
            let root = try XCTUnwrap(ExtensionLuaSuiteTests.repoRoot())
            let (files, missing) = ExtensionLuaSuiteTests.discover(in: root)
            XCTAssertTrue(missing.isEmpty, "\(missing)")
            XCTAssertGreaterThanOrEqual(files.count, 30)
            let harness = root.appendingPathComponent("scripts/ext-test").path
            var peaks: [(String, Int)] = []
            for rel in files {
                let run = runCapped(Self.suiteDriver, root.appendingPathComponent(rel).path, harness,
                                    cap: LuaRuntime.defaultMemoryLimit)
                XCTAssertEqual(run.result, "", rel)
                XCTAssertEqual(run.used, run.luaCount, "shim count vs Lua's count: \(rel)")
                XCTAssertLessThan(run.peak, LuaRuntime.defaultMemoryLimit, rel)
                peaks.append((rel, run.peak))
            }
            let top = peaks.sorted { $0.1 > $1.1 }.prefix(8)
            print("LUAMEM suite peaks (bytes): " + top.map { "\(($0.0 as NSString).lastPathComponent)=\($0.1)" }.joined(separator: " "))
        }
    }

    /// Every built-in extension's init.lua loads under the shipped cap; prints what each holds at rest.
    func testTheBuiltInExtensionsLoadUnderTheShippedCap() throws {
        let root = try XCTUnwrap(ExtensionLuaSuiteTests.repoRoot())
        let harness = root.appendingPathComponent("scripts/ext-test").path
        let fm = FileManager.default
        var inits: [String] = []
        for dir in ["app/Sources/ProsperApp/Resources/extensions", "app/Examples/extensions"] {
            let base = root.appendingPathComponent(dir)
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
                let file = base.appendingPathComponent(name).appendingPathComponent("init.lua").path
                if fm.fileExists(atPath: file) { inits.append(file) }
            }
        }
        XCTAssertGreaterThanOrEqual(inits.count, 30)
        var rests: [(String, Int)] = []
        var errors: [String] = []
        for file in inits.sorted() {
            let name = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let run = runCapped(Self.restDriver, file, harness, cap: LuaRuntime.defaultMemoryLimit)
            XCTAssertFalse(run.result.contains("not enough memory"), "\(name): \(run.result)")
            if let bytes = Int(run.result) { rests.append((name, bytes)) } else { errors.append("\(name): \(run.result.prefix(80))") }
        }
        let top = rests.sorted { $0.1 > $1.1 }.prefix(8)
        print("LUAMEM at rest after load (bytes): " + top.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        if !errors.isEmpty { print("LUAMEM not loadable with the default harness host: " + errors.joined(separator: " | ")) }
    }
}

/// #1127 rider R1127-3: the host reads and writes globals raw, so a host lookup or registration runs no
/// metamethod of the globals table (that would run outside the armed, protected call). The script below counts
/// every metamethod call; everything it calls is defined before its metatable goes on.
final class LuaHostGlobalsTests: XCTestCase {

    private static let script = """
        local counts = { index = 0, newindex = 0 }
        function counters() return counts.index .. "," .. counts.newindex end
        function present() return "present" end
        function spin() local n = 0 for i = 1, 1000000000 do n = n + 1 end return tostring(n) end
        function readmissing() local v = not_a_global return counters() end
        function haslate() return tostring(rawget(_G, "late") ~= nil) end
        function arm()
          setmetatable(_G, {
            __index = function(t, k) counts.index = counts.index + 1 return nil end,
            __newindex = function(t, k, v) counts.newindex = counts.newindex + 1 rawset(t, k, v) end,
          })
        end
        """

    private func armed(allowLoad: Bool) throws -> LuaRuntime {
        let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
        try lua.run(Self.script)
        try lua.callGlobal("arm")
        return lua
    }

    func testAHostLookupRunsNoGlobalsMetamethod() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)"
            let lua = try armed(allowLoad: allowLoad)
            XCTAssertThrowsError(try lua.callGlobal("not_registered")) { error in
                XCTAssertEqual(error as? LuaRuntime.LuaError, .notAFunction("not_registered"), note)
            }
            XCTAssertEqual(try lua.callGlobal("counters"), "0,0", note)
            XCTAssertEqual(try lua.callGlobal("present"), "present", note)
            XCTAssertThrowsError(try lua.callGlobal("spin")) { error in
                XCTAssertEqual(error as? LuaRuntime.LuaError, .runtime("execution budget exceeded"), note)
            }
            XCTAssertEqual(try lua.callGlobal("counters"), "0,0", note)
            // Inside a call, the script's own read of a missing global still reaches its __index.
            XCTAssertEqual(try lua.callGlobal("readmissing"), "1,0", note)
        }
    }

    func testAHostRegistrationRunsNoGlobalsMetamethod() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)"
            let lua = try armed(allowLoad: allowLoad)
            lua.register("late") { rt in rt.push("late"); return 1 }
            XCTAssertEqual(try lua.callGlobal("counters"), "0,0", note)
            XCTAssertEqual(try lua.callGlobal("haslate"), "true", note)
            XCTAssertEqual(try lua.callGlobal("late"), "late", note)
        }
    }
}

/// #1127 (R1127-4): the sandbox's setmetatable (#1126) keeps stock Lua's protected-metatable rule.
final class LuaProtectedMetatableTests: XCTestCase {

    func testAProtectedMetatableCannotBeReplacedAndAPlainOneCan() throws {
        for allowLoad in [false, true] {
            let lua = try LuaRuntime(allowLoad: allowLoad)
            try lua.run("""
                function probe()
                  local t = setmetatable({}, {__metatable = 'locked'})
                  local okSet, errSet = pcall(setmetatable, t, {})
                  local okClear, errClear = pcall(setmetatable, t, nil)
                  local u, m = setmetatable({}, {}), {}
                  setmetatable(u, m)
                  local replaced = getmetatable(u) == m
                  setmetatable(u, nil)
                  return table.concat({tostring(okSet), tostring(errSet), tostring(okClear), tostring(errClear),
                    tostring(getmetatable(t)), tostring(replaced), tostring(getmetatable(u))}, '|')
                end
                """)
            XCTAssertEqual(try lua.callGlobal("probe"),
                           "false|cannot change a protected metatable|false|cannot change a protected metatable"
                               + "|locked|true|nil", "allowLoad: \(allowLoad)")
        }
    }
}
