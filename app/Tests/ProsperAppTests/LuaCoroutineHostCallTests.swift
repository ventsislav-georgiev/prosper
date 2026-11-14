import Foundation
import XCTest
@testable import LuaRuntime

/// #1151: a host function reads its arguments from, and pushes its results onto, the Lua thread that called it,
/// a coroutine included, and the count it returns applies to that same thread. Each row makes one host call from a
/// coroutine (plus, where named, one from the main thread or one call back into the runtime) with a few values, and
/// compares what the host function saw, what the script got back and both stack heights.
final class LuaCoroutineHostCallTests: XCTestCase {

    /// What the host functions saw, in call order.
    final class Seen { var lines: [String] = [] }

    /// `show(...)` renders a call's results as "<count>,<v1>,<v2>...".
    static let show = """
        local function show(...)
          local t = table.pack(...)
          local out = { tostring(t.n) }
          for i = 1, t.n do out[#out + 1] = tostring(t[i]) end
          return table.concat(out, ",")
        end

        """

    /// The result every `probe("a", 21, false)` call hands back when the helpers act on the calling thread.
    static let probed = "4,r:a,21.0,true,nil"

    /// A runtime with a small explicit budget and `probe`: reads a string, a number and a boolean argument, records
    /// them with the calling frame's height and the main thread's height before and after its pushes, and returns
    /// four results ("r:" .. the string, the number, not the boolean, nil).
    private func runtime(_ allowLoad: Bool, _ seen: Seen, _ script: String) throws -> LuaRuntime {
        let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
        lua.register("probe") { rt in
            let argc = rt.argumentCount, main = rt.mainStackHeight
            let s = rt.stringArgument(1), n = rt.numberArgument(2), b = rt.boolArgument(3)
            rt.push("r:" + (s ?? "none"))
            rt.push(n ?? -1)
            rt.push(!(b ?? true))
            rt.pushNil()
            seen.lines.append("argc=\(argc) s=\(s ?? "none") n=\(n.map { "\($0)" } ?? "none") b=\(b.map { "\($0)" } ?? "none")"
                              + " frame=\(argc)>\(rt.argumentCount) main=\(main)>\(rt.mainStackHeight)")
            return 4
        }
        try lua.run(Self.show + script)
        return lua
    }

    /// Calls `name` from the host, with the main thread's stack at rest before and after.
    private func call(_ lua: LuaRuntime, _ name: String, _ note: String,
                      file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(lua.mainStackHeight, 0, "main thread before \(name) [\(note)]", file: file, line: line)
        let got: String
        do { got = try lua.callGlobal(name) ?? "nil" } catch { got = "threw \(error)" }
        XCTAssertEqual(lua.mainStackHeight, 0, "main thread after \(name) [\(note)]", file: file, line: line)
        return got
    }

    // MARK: - One host call from each kind of thread

    func testAHostCallFromTheMainThreadActsOnTheMainThread() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, "function direct() return show(probe('a', 21, false)) end")
            XCTAssertEqual(call(lua, "direct", note), Self.probed, note)
            XCTAssertEqual(seen.lines, ["argc=3 s=a n=21.0 b=false frame=3>7 main=3>7"], note)
        }
    }

    func testAHostCallFromACoroutineActsOnTheCoroutine() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function viaResume()
                  local co = coroutine.create(function(...) return show(probe(...)) end)
                  local ok, got = coroutine.resume(co, 'a', 21, false)
                  return tostring(ok) .. ':' .. tostring(got) .. ':' .. coroutine.status(co)
                end
                """)
            XCTAssertEqual(call(lua, "viaResume", note), "true:\(Self.probed):dead", note)
            // The main thread sits in coroutine.resume, holding the coroutine: one value, untouched by the call.
            XCTAssertEqual(seen.lines, ["argc=3 s=a n=21.0 b=false frame=3>7 main=1>1"], note)
        }
    }

    func testAHostCallFromANestedCoroutineActsOnThatCoroutine() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function viaNested()
                  local outer = coroutine.create(function()
                    local inner = coroutine.create(function(...) return show(probe(...)) end)
                    local ok, got = coroutine.resume(inner, 'a', 21, false)
                    return tostring(ok) .. ':' .. tostring(got) .. ':' .. coroutine.status(inner)
                  end)
                  local ok, got = coroutine.resume(outer)
                  return tostring(ok) .. ':' .. tostring(got) .. ':' .. coroutine.status(outer)
                end
                """)
            XCTAssertEqual(call(lua, "viaNested", note), "true:true:\(Self.probed):dead:dead", note)
            XCTAssertEqual(seen.lines, ["argc=3 s=a n=21.0 b=false frame=3>7 main=1>1"], note)
        }
    }

    func testAHostCallFromAWrappedCoroutineActsOnTheCoroutine() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function viaWrap()
                  return coroutine.wrap(function(...) return show(probe(...)) end)('a', 21, false)
                end
                """)
            XCTAssertEqual(call(lua, "viaWrap", note), Self.probed, note)
            // A wrap function hands every argument to the coroutine: its frame on the main thread is empty.
            XCTAssertEqual(seen.lines, ["argc=3 s=a n=21.0 b=false frame=3>7 main=0>0"], note)
        }
    }

    // MARK: - Calls back into the runtime and errors

    func testAHostFunctionThatCallsBackKeepsItsOwnThread() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function inner(x) return show(probe(x, 7, true)) end
                function viaCallback()
                  local co = coroutine.create(function(...) return show(reenter(...)) end)
                  local ok, got = coroutine.resume(co, 'a')
                  return tostring(ok) .. ':' .. tostring(got)
                end
                """)
            lua.register("reenter") { rt in
                let before = "argc=\(rt.argumentCount) s=\(rt.stringArgument(1) ?? "none") main=\(rt.mainStackHeight)"
                let during = (try? rt.callGlobal("inner", ["b"])) ?? "failed"
                let after = "argc=\(rt.argumentCount) s=\(rt.stringArgument(1) ?? "none") main=\(rt.mainStackHeight)"
                rt.push(before)
                rt.push(during)
                rt.push(after)
                return 3
            }
            XCTAssertEqual(call(lua, "viaCallback", note),
                           "true:3,argc=1 s=a main=1,4,r:b,7.0,false,nil,argc=1 s=a main=1", note)
            // During the call back, probe ran on the main thread, in a frame of its own.
            XCTAssertEqual(seen.lines, ["argc=3 s=b n=7.0 b=true frame=3>7 main=3>7"], note)
        }
    }

    func testAHostFunctionWhoseCallBackFailsKeepsItsOwnThread() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function boom(x) probe(x, 7, true) error('boom', 0) end
                function viaFailure()
                  local co = coroutine.create(function(...) return show(failing(...)) end)
                  local ok, got = coroutine.resume(co, 'a')
                  return tostring(ok) .. ':' .. tostring(got)
                end
                """)
            lua.register("failing") { rt in
                var outcome = "returned"
                do { try rt.callGlobal("boom", ["b"]) } catch { outcome = "\(error)" }
                let after = "argc=\(rt.argumentCount) s=\(rt.stringArgument(1) ?? "none") main=\(rt.mainStackHeight)"
                rt.push(outcome)
                rt.push(after)
                return 2
            }
            XCTAssertEqual(call(lua, "viaFailure", note), "true:2,runtime(\"boom\"),argc=1 s=a main=1", note)
            XCTAssertEqual(seen.lines, ["argc=3 s=b n=7.0 b=true frame=3>7 main=3>7"], note)
        }
    }

    func testACoroutineThatFailsAfterAHostCallLeavesTheMainThreadAsItWas() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function viaRaise()
                  local co = coroutine.create(function(...) local r = show(probe(...)) error('after ' .. r, 0) end)
                  local ok, got = coroutine.resume(co, 'a', 21, false)
                  return tostring(ok) .. ':' .. tostring(got) .. ':' .. coroutine.status(co)
                end
                function direct() return show(probe('a', 21, false)) end
                """)
            XCTAssertEqual(call(lua, "viaRaise", note), "false:after \(Self.probed):dead", note)
            // The next host call, from the main thread, reads and pushes there.
            XCTAssertEqual(call(lua, "direct", note), Self.probed, note)
            XCTAssertEqual(seen.lines, ["argc=3 s=a n=21.0 b=false frame=3>7 main=1>1",
                                        "argc=3 s=a n=21.0 b=false frame=3>7 main=3>7"], note)
        }
    }

    // MARK: - JSON helpers and the returned count

    func testJSONHelpersActOnTheCoroutine() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"k":[1,"two",true]}"#.utf8))
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function viaJSON()
                  local co = coroutine.create(function(v) local t = json(v) return show(t.k[1], t.k[2], t.k[3], #t.k) end)
                  local ok, got = coroutine.resume(co, { x = { 1, 2, 'three' } })
                  return tostring(ok) .. ':' .. tostring(got)
                end
                """)
            lua.register("json") { rt in
                seen.lines.append("argc=\(rt.argumentCount) json=\(rt.encodeJSON(at: 1)) main=\(rt.mainStackHeight)")
                rt.pushJSON(object)
                seen.lines.append("frame=\(rt.argumentCount) main=\(rt.mainStackHeight)")
                return 1
            }
            XCTAssertEqual(call(lua, "viaJSON", note), "true:4,1,two,true,3", note)
            XCTAssertEqual(seen.lines, [#"argc=1 json={"x":[1,2,"three"]} main=1"#, "frame=2 main=1"], note)
        }
    }

    func testAHostFunctionReturnsNoMoreValuesThanItsFrameHolds() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)", seen = Seen()
            let lua = try runtime(allowLoad, seen, """
                function viaShortCount()
                  local co = coroutine.create(function(...) local a, b, c = 1, 2, 3 return show(give(...)) end)
                  local ok, got = coroutine.resume(co, 'p')
                  return tostring(ok) .. ':' .. tostring(got)
                end
                """)
            // Pushes nothing and claims three results: only its one argument is in its frame.
            lua.register("give") { _ in 3 }
            XCTAssertEqual(call(lua, "viaShortCount", note), "true:1,p", note)
        }
    }
}

/// #1151: the push helpers grow the calling thread's stack before they push, and a count outside the frame is clamped.
final class LuaHostStackCheckTests: XCTestCase {

    private func runtime(_ allowLoad: Bool, _ script: String) throws -> LuaRuntime {
        let lua = try LuaRuntime(maxInstructions: 100_000, allowLoad: allowLoad)
        try lua.run(LuaCoroutineHostCallTests.show + script)
        return lua
    }

    func testAHostFunctionPushesPastTheMinimumStack() throws {
        let expected = "64," + (1...64).map { "\(Double($0))" }.joined(separator: ",")
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)"
            let lua = try runtime(allowLoad, """
                function direct() return show(many()) end
                function viaResume()
                  local co = coroutine.create(function() return show(many()) end)
                  local ok, got = coroutine.resume(co)
                  return tostring(ok) .. ':' .. tostring(got)
                end
                """)
            var heights: [String] = []
            lua.register("many") { rt in
                let main = rt.mainStackHeight
                for i in 1...64 { rt.push(Double(i)) }
                heights.append("frame=\(rt.argumentCount) main=\(main)>\(rt.mainStackHeight)")
                return 64
            }
            XCTAssertEqual(try lua.callGlobal("viaResume"), "true:" + expected, note)
            XCTAssertEqual(try lua.callGlobal("direct"), expected, note)
            XCTAssertEqual(heights, ["frame=64 main=1>1", "frame=64 main=0>64"], note)
            XCTAssertEqual(lua.mainStackHeight, 0, note)
        }
    }

    func testANegativeHostCountReturnsNothing() throws {
        for allowLoad in [false, true] {
            let note = "allowLoad: \(allowLoad)"
            let lua = try runtime(allowLoad, """
                function direct() return show(negative('p')) end
                function viaResume()
                  local co = coroutine.create(function() return show(negative('p')) end)
                  local ok, got = coroutine.resume(co)
                  return tostring(ok) .. ':' .. tostring(got)
                end
                """)
            lua.register("negative") { _ in -1 }
            XCTAssertEqual(try lua.callGlobal("viaResume"), "true:0", note)
            XCTAssertEqual(try lua.callGlobal("direct"), "0", note)
            XCTAssertEqual(lua.mainStackHeight, 0, note)
        }
    }
}
