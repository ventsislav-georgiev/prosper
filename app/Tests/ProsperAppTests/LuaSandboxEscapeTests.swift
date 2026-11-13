import XCTest
@testable import LuaRuntime

/// #1125: what an extension's Lua can reach. Before, the sandbox opened every standard library and only
/// cleared seven globals, so the debug library reached os, io and package through the registry and could
/// clear the instruction budget. Every row runs in a default runtime AND an allowLoad runtime (every
/// extension that activate() runs gets allowLoad: ExtensionRegistry :899 is always true behind the trusted
/// guard; :156 is spec.privileged || spec.trusted). A closed path is proven by the function
/// being unreachable; nothing here executes, removes, opens or loads anything.
final class LuaSandboxEscapeTests: XCTestCase {

    /// Each row: a Lua expression and the exact string it must return, in both runtimes.
    private func assertRows(_ rows: [(String, String)], allowLoad: Bool, file: StaticString = #filePath,
                            line: UInt = #line) throws {
        let lua = try LuaRuntime(allowLoad: allowLoad)
        lua.register("hostfn") { lua in lua.push("host"); return 1 }
        for (expr, expected) in rows {
            try lua.run("function probe() return \(expr) end")
            XCTAssertEqual(try lua.callGlobal("probe"), expected, "\(expr) [allowLoad: \(allowLoad)]",
                           file: file, line: line)
        }
    }

    private func assertBoth(_ rows: [(String, String)], file: StaticString = #filePath, line: UInt = #line) throws {
        try assertRows(rows, allowLoad: false, file: file, line: line)
        try assertRows(rows, allowLoad: true, file: file, line: line)
    }

    /// The names of `table` in the sandbox (less the probe function itself), compared as a set with a literal
    /// list (a Lua update that adds a function fails by name).
    private func assertKeys(_ table: String, _ expected: [String], allowLoad: Bool,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let lua = try LuaRuntime(allowLoad: allowLoad)
        try lua.run("""
            function probe()
              local k = {} for n in pairs(\(table)) do if n ~= 'probe' then k[#k + 1] = tostring(n) end end
              table.sort(k) return table.concat(k, ' ')
            end
            """)
        let got = (try lua.callGlobal("probe") ?? "").split(separator: " ").map(String.init)
        XCTAssertEqual(Set(got), Set(expected), "\(table) [allowLoad: \(allowLoad)]", file: file, line: line)
        XCTAssertEqual(got.count, expected.count, "\(table) [allowLoad: \(allowLoad)]", file: file, line: line)
    }

    // MARK: - Set equality

    func testGlobalsAreExactlyTheGrantedOnes() throws {
        let globals = [
            "_G", "_VERSION", "assert", "collectgarbage", "coroutine", "debug", "error", "getmetatable",
            "ipairs", "math", "next", "pairs", "pcall", "print", "rawequal", "rawget", "rawlen", "rawset",
            "select", "setmetatable", "string", "table", "tonumber", "tostring", "type", "utf8", "warn", "xpcall",
        ]
        try assertKeys("_G", globals, allowLoad: false)
        try assertKeys("_G", globals + ["load"], allowLoad: true)
    }

    func testLibraryKeysAreExactlyTheGrantedOnes() throws {
        let libraries: [(String, [String])] = [
            ("string", ["byte", "char", "find", "format", "gmatch", "gsub", "len", "lower", "match", "pack",
                        "packsize", "rep", "reverse", "sub", "unpack", "upper"]),
            ("table", ["concat", "insert", "move", "pack", "remove", "sort", "unpack"]),
            ("math", ["abs", "acos", "asin", "atan", "ceil", "cos", "deg", "exp", "floor", "fmod", "huge", "log",
                      "max", "maxinteger", "min", "mininteger", "modf", "pi", "rad", "random", "randomseed",
                      "sin", "sqrt", "tan", "tointeger", "type", "ult"]),
            ("coroutine", ["close", "create", "isyieldable", "resume", "running", "status", "wrap", "yield"]),
            ("utf8", ["char", "charpattern", "codepoint", "codes", "len", "offset"]),
            ("debug", ["traceback"]),
        ]
        for allowLoad in [false, true] {
            for (table, keys) in libraries {
                try assertKeys(table, keys, allowLoad: allowLoad)
            }
        }
    }

    // MARK: - Escape rows (each must be unreachable)

    func testStrippedLibrariesAndLoadersAreUnreachable() throws {
        try assertBoth([
            ("tostring(io)", "nil"),
            ("tostring(os)", "nil"),
            ("tostring(package)", "nil"),
            ("tostring(require)", "nil"),
            ("tostring(dofile)", "nil"),
            ("tostring(loadfile)", "nil"),
            ("tostring(rawget(_G, 'os'))", "nil"),
            ("tostring(_G._G == _G)", "true"),
        ])
    }

    func testDebugLibraryHoldsNoEscape() throws {
        try assertBoth([
            ("tostring(debug.getregistry)", "nil"),
            ("tostring(debug.sethook)", "nil"),
            ("tostring(debug.gethook)", "nil"),
            ("tostring(debug.getupvalue)", "nil"),
            ("tostring(debug.setupvalue)", "nil"),
            ("tostring(debug.upvalueid)", "nil"),
            ("tostring(debug.upvaluejoin)", "nil"),
            ("tostring(debug.getinfo)", "nil"),
            ("tostring(debug.getlocal)", "nil"),
            ("tostring(debug.setlocal)", "nil"),
            ("tostring(debug.setmetatable)", "nil"),
            ("tostring(debug.getmetatable)", "nil"),
            ("tostring(debug.setuservalue)", "nil"),
            ("tostring(debug.getuservalue)", "nil"),
            ("tostring(debug.setcstacklimit)", "nil"),
            ("tostring(debug.debug)", "nil"),
            // A host closure's upvalues (the trampoline's pointers) were reachable only through getupvalue.
            // (The position prefix names the probe chunk; only the message after it is pinned.)
            ("select(2, pcall(function() return debug.getupvalue(hostfn, 1) end)):match(':1: (.*)$')",
             "attempt to call a nil value (field 'getupvalue')"),
        ])
    }

    func testTracebackIsKeptForXpcall() throws {
        try assertBoth([
            ("tostring(select(2, xpcall(function() error('boom', 0) end, debug.traceback))"
                + ":match('^boom\\nstack traceback:\\n') ~= nil)", "true"),
        ])
    }

    func testStringDumpIsGone() throws {
        try assertBoth([
            ("tostring(string.dump)", "nil"),
            ("tostring(('').dump)", "nil"),
            // The string metatable is the plain one; no setmetatable for non-tables is left to change it.
            ("tostring(getmetatable('').__index == string)", "true"),
        ])
    }

    func testDefaultRuntimeHasNoLoad() throws {
        try assertRows([("tostring(load)", "nil")], allowLoad: false)
    }

    func testAllowLoadTakesTextChunksOnly() throws {
        func both(_ call: String) -> String {
            "(function() local d = false local f, e = \(call) return tostring(f) .. ' ' .. tostring(e) end)()"
        }
        let refused = "nil attempt to load a binary chunk (mode is 't')"
        try assertRows([
            (both("load('\\27Lua' .. string.rep('x', 40))"), refused),
            (both("load('\\27Lua' .. string.rep('x', 40), 'c', 'b')"), refused),
            (both("load('\\27Lua' .. string.rep('x', 40), 'c', 'bt')"), refused),
            (both("load(function() if d then return nil end d = true return '\\27Lua' end)"), refused),
            // Text keeps working, with the env argument as before: given, absent (globals) and an explicit nil.
            ("tostring(load('return 1 + 2')())", "3"),
            ("load('return x', 'n', 't', {x = 'envx'})()", "envx"),
            ("(function() y = 'gy' return load('return y')() end)()", "gy"),
            ("select(2, pcall(load('return y', 'n', 't', nil)))",
             "[string \"n\"]:1: attempt to index a nil value (upvalue '_ENV')"),
        ], allowLoad: true)
    }

    // MARK: - Budget

    func testBudgetAbortsAPlainInfiniteLoop() throws {
        for allowLoad in [false, true] {
            let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
            try lua.run("function spin() while true do end end")
            XCTAssertThrowsError(try lua.callGlobal("spin")) { err in
                XCTAssertEqual(err as? LuaRuntime.LuaError, .runtime("execution budget exceeded"),
                               "allowLoad: \(allowLoad)")
            }
        }
    }
}
