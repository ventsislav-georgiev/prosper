import XCTest
@testable import LuaRuntime

final class LuaRuntimeTests: XCTestCase {

    func testRunAndCallGlobal() throws {
        let lua = try LuaRuntime()
        try lua.run("function greet(who) return 'hi ' .. who end")
        XCTAssertEqual(try lua.callGlobal("greet", ["world"]), "hi world")
    }

    func testArithmeticResult() throws {
        let lua = try LuaRuntime()
        try lua.run("function add(a, b) return tonumber(a) + tonumber(b) end")
        XCTAssertEqual(try lua.callGlobal("add", ["19", "23"]), "42")
    }

    func testCompileErrorThrows() throws {
        let lua = try LuaRuntime()
        XCTAssertThrowsError(try lua.run("function broken(")) { err in
            guard case LuaRuntime.LuaError.compile = err else {
                return XCTFail("expected .compile, got \(err)")
            }
        }
    }

    func testRuntimeErrorThrows() throws {
        let lua = try LuaRuntime()
        try lua.run("function boom() error('kaboom') end")
        XCTAssertThrowsError(try lua.callGlobal("boom")) { err in
            guard case LuaRuntime.LuaError.runtime(let m) = err else {
                return XCTFail("expected .runtime, got \(err)")
            }
            XCTAssertTrue(m.contains("kaboom"))
        }
    }

    func testCallMissingFunctionThrows() throws {
        let lua = try LuaRuntime()
        XCTAssertThrowsError(try lua.callGlobal("nope")) { err in
            XCTAssertEqual(err as? LuaRuntime.LuaError, .notAFunction("nope"))
        }
    }

    // MARK: - Sandbox

    func testDangerousGlobalsRemoved() throws {
        let lua = try LuaRuntime()
        for global in ["io", "os", "package", "require", "dofile", "loadfile", "load"] {
            try lua.run("function probe() return tostring(\(global)) end")
            XCTAssertEqual(try lua.callGlobal("probe"), "nil",
                           "\(global) should be sandboxed to nil")
        }
    }

    func testFilesystemAccessUnavailable() throws {
        let lua = try LuaRuntime()
        // io is nil → indexing it is a runtime error, proving no file access.
        try lua.run("function readfile() return io.open('/etc/passwd') end")
        XCTAssertThrowsError(try lua.callGlobal("readfile"))
    }

    // MARK: - Budget

    func testInstructionBudgetAbortsRunaway() throws {
        let lua = try LuaRuntime(maxInstructions: 100_000)
        try lua.run("function spin() while true do end end")
        XCTAssertThrowsError(try lua.callGlobal("spin")) { err in
            guard case LuaRuntime.LuaError.runtime(let m) = err else {
                return XCTFail("expected .runtime, got \(err)")
            }
            XCTAssertTrue(m.contains("budget"), "got: \(m)")
        }
    }

    func testBudgetDoesNotKillNormalWork() throws {
        let lua = try LuaRuntime(maxInstructions: 10_000_000)
        try lua.run("""
        function sum(n)
            local t = 0
            for i = 1, tonumber(n) do t = t + i end
            return t
        end
        """)
        XCTAssertEqual(try lua.callGlobal("sum", ["1000"]), "500500")
    }

    // MARK: - Host functions

    func testRegisteredHostFunction() throws {
        let lua = try LuaRuntime()
        lua.register("host_upper") { rt in
            let s = rt.stringArgument(1) ?? ""
            rt.push(s.uppercased())
            return 1
        }
        try lua.run("function shout(x) return host_upper(x) end")
        XCTAssertEqual(try lua.callGlobal("shout", ["hello"]), "HELLO")
    }

    func testHostFunctionNumberRoundTrip() throws {
        let lua = try LuaRuntime()
        lua.register("host_double") { rt in
            rt.push((rt.numberArgument(1) ?? 0) * 2)
            return 1
        }
        try lua.run("function twice(n) return host_double(tonumber(n)) end")
        XCTAssertEqual(try lua.callGlobal("twice", ["21"]), "42.0")
    }

    // MARK: - Hot reload

    func testResetReappliesHostFunctionsAndClearsState() throws {
        let lua = try LuaRuntime()
        lua.register("host_const") { rt in rt.push("constant"); return 1 }
        try lua.run("function g() return 1 end")
        XCTAssertEqual(try lua.callGlobal("g"), "1")

        try lua.reset()

        // Old script gone after reset…
        XCTAssertThrowsError(try lua.callGlobal("g"))
        // …but host function reapplied, so a fresh script can use it.
        try lua.run("function useconst() return host_const() end")
        XCTAssertEqual(try lua.callGlobal("useconst"), "constant")
    }
}
