import CLua
import Foundation
import XCTest

/// #1035: every extension `*.test.lua` runs through the Lua the app embeds (vendored CLua, 5.4.9),
/// so a Lua regression fails `swift test` (test.yml, the QA suite) instead of waiting for someone to
/// run scripts/test-extensions.sh by hand on a stock Lua of another version.
enum LuaFileOutcome: Equatable {
    case passed
    case failed(String)
}

/// Stand-in for os.exit inside a driven file: the real one would end xctest. Upvalue 1 is the
/// driver's exit box; the first code is recorded there and the call unwinds with an error. The box,
/// not the error value, decides the outcome, so a pcall in the file cannot swallow the exit.
private func luaDriverExit(_ L: OpaquePointer?) -> Int32 {
    guard let L else { return 0 }
    let code: lua_Integer
    switch lua_type(L, 1) {
    case LUA_TNONE, LUA_TNIL: code = 0
    case LUA_TBOOLEAN: code = lua_toboolean(L, 1) != 0 ? 0 : 1
    default: code = luaL_checkinteger(L, 1)
    }
    let box = clua_upvalueindex(1)
    if lua_getfield(L, box, "code") == LUA_TNIL {
        lua_pushinteger(L, code)
        lua_setfield(L, box, "code")
    }
    clua_pop(L, 1)
    lua_pushstring(L, "os.exit(\(code))")
    return lua_error(L)
}

/// Message handler for the protected call: the error as a string plus a traceback, as lua.c prints it.
private func luaDriverTraceback(_ L: OpaquePointer?) -> Int32 {
    guard let L else { return 0 }
    let msg = luaL_tolstring(L, 1, nil)
    luaL_traceback(L, L, msg, 1)
    return 1
}

/// Runs one Lua test file the way `lua <file>` does under scripts/test-extensions.sh: a fresh state
/// with the standard libraries, the harness dir first on package.path, `arg[0]` = the file.
func runLuaTestFile(_ path: String, harnessDir: String) -> LuaFileOutcome {
    guard let L = luaL_newstate() else { return .failed("\(path): luaL_newstate failed") }
    defer { lua_close(L) }
    luaL_openlibs(L)

    lua_getglobal(L, "package")
    lua_getfield(L, -1, "path")
    let defaultPath = clua_tostring(L, -1).map { String(cString: $0) } ?? ""
    clua_pop(L, 1)
    lua_pushstring(L, harnessDir + "/?.lua;" + defaultPath)
    lua_setfield(L, -2, "path")
    clua_pop(L, 1)

    lua_createtable(L, 0, 0)
    lua_pushstring(L, path)
    lua_rawseti(L, -2, 0)
    lua_setglobal(L, "arg")

    lua_createtable(L, 0, 1)                      // 1: exit box
    lua_getglobal(L, "os")
    lua_pushvalue(L, 1)
    lua_pushcclosure(L, luaDriverExit, 1)
    lua_setfield(L, -2, "exit")
    clua_pop(L, 1)
    clua_pushcfunction(L, luaDriverTraceback)     // 2: message handler

    var status = luaL_loadfilex(L, path, nil)
    if status == LUA_OK { status = clua_pcall(L, 0, 0, 2) }
    let message = status == LUA_OK ? "" : (clua_tostring(L, -1).map { String(cString: $0) } ?? "(non-string error)")

    if lua_getfield(L, 1, "code") != LUA_TNIL {
        let code = lua_tointegerx(L, -1, nil)
        return code == 0 ? .passed : .failed("\(path): os.exit(\(code))")
    }
    return status == LUA_OK ? .passed : .failed(message)
}

final class ExtensionLuaSuiteTests: XCTestCase {
    /// The same three roots scripts/test-extensions.sh searches.
    static let roots = [
        "app/Sources/ProsperApp/Resources/extensions",
        "app/Examples/extensions",
        "scripts/ext-test",
    ]

    /// Files that must be found: the literal list and the floor are the pin, not the loop.
    static let mustFind: Set<String> = [
        "scripts/ext-test/harness.test.lua",
        "app/Sources/ProsperApp/Resources/extensions/shell/shell.test.lua",
        "app/Sources/ProsperApp/Resources/extensions/appupdates/appupdates.test.lua",
        "app/Sources/ProsperApp/Resources/extensions/bookmarks/bookmarks.test.lua",
        "app/Sources/ProsperApp/Resources/extensions/url-dispatcher/url-dispatcher.test.lua",
        "app/Sources/ProsperApp/Resources/extensions/toggles/toggles.test.lua",
        "app/Sources/ProsperApp/Resources/extensions/scripts/scripts.test.lua",
        "app/Sources/ProsperApp/Resources/extensions/migration/migration.test.lua",
        "app/Examples/extensions/hammerspoon-compat/hammerspoon-compat.test.lua",
    ]

    /// The repo root: the first ancestor of this file holding app/Package.swift.
    static func repoRoot(_ file: String = #filePath) -> URL? {
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("app/Package.swift").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Relative paths of every *.test.lua under the roots, sorted; a missing root is reported, not skipped.
    static func discover(in root: URL) -> (files: [String], missingRoots: [String]) {
        var files: [String] = []
        var missing: [String] = []
        let fm = FileManager.default
        for rel in roots {
            var isDir: ObjCBool = false
            let dir = root.appendingPathComponent(rel)
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  let walker = fm.enumerator(atPath: dir.path) else { missing.append(rel); continue }
            for case let sub as String in walker where sub.hasSuffix(".test.lua") {
                files.append(rel + "/" + sub)
            }
        }
        return (files.sorted(), missing)
    }

    private func harnessDir(_ root: URL) -> String {
        root.appendingPathComponent("scripts/ext-test").path
    }

    func testEveryLuaTestFilePasses() throws {
        try withProcessLocale("C") { try runEveryLuaTestFile(under: "C") }
    }

    /// #1099: the same files under the locale Ghostty's init can leave the process in (UTF-8 LC_CTYPE, comma
    /// LC_NUMERIC). Only this leg skips when that locale is missing.
    func testEveryLuaTestFilePassesUnderANonCLocale() throws {
        try withProcessLocale(luaTestLocale) { try runEveryLuaTestFile(under: luaTestLocale) }
    }

    private func runEveryLuaTestFile(under locale: String) throws {
        let root = try XCTUnwrap(Self.repoRoot(), "no app/Package.swift above \(#filePath)")
        let (files, missing) = Self.discover(in: root)
        XCTAssertTrue(missing.isEmpty, "Lua test roots missing: \(missing)")
        XCTAssertGreaterThanOrEqual(files.count, 30, "found only \(files.count) *.test.lua: \(files)")
        let absent = Self.mustFind.subtracting(files)
        XCTAssertTrue(absent.isEmpty, "expected Lua test files not found: \(absent.sorted())")

        let started = Date()
        var failed = 0
        for rel in files {
            if case .failed(let message) = runLuaTestFile(root.appendingPathComponent(rel).path, harnessDir: harnessDir(root)) {
                failed += 1
                XCTFail("\(rel) failed on the embedded Lua under locale \(locale): \(message)")
            }
        }
        print(String(format: "ExtensionLuaSuite (%@): %d Lua test file(s), %d failed, %.2f s", locale, files.count, failed, Date().timeIntervalSince(started)))
    }

    func testTheSuiteRunsOnTheLuaTheAppEmbeds() throws {
        let L = try XCTUnwrap(luaL_newstate())
        defer { lua_close(L) }
        luaL_openlibs(L)
        lua_getglobal(L, "_VERSION")
        XCTAssertEqual(clua_tostring(L, -1).map { String(cString: $0) }, "Lua 5.4")
        XCTAssertEqual(lua_version(L), 504)
        XCTAssertEqual("\(LUA_VERSION_MAJOR).\(LUA_VERSION_MINOR).\(LUA_VERSION_RELEASE)", "5.4.9")
    }

    // MARK: - The driver on literal files

    private func run(_ source: String, name: String = "case.test.lua") throws -> (LuaFileOutcome, String) {
        let file = tempDir().appendingPathComponent(name)
        try source.write(to: file, atomically: true, encoding: .utf8)
        let root = try XCTUnwrap(Self.repoRoot())
        return (runLuaTestFile(file.path, harnessDir: harnessDir(root)), file.path)
    }

    private func failure(_ outcome: LuaFileOutcome) -> String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }

    func testDriverPassesAFileThatReturnsNormally() throws {
        XCTAssertEqual(try run("local x = 1 + 1\nassert(x == 2)\n").0, .passed)
    }

    func testDriverFailsOnErrorWithMessageAndFileName() throws {
        // Lua shortens a long chunk name to its tail ("...<tail>", LUA_IDSIZE), so match the file name.
        let message = try XCTUnwrap(failure(try run("error(\"boom\")\n", name: "boom.test.lua").0))
        XCTAssertTrue(message.contains("boom.test.lua:1: boom"), message)
    }

    func testDriverFailsOnFailingAssert() throws {
        let message = try XCTUnwrap(failure(try run("assert(1 == 2, \"one is not two\")\n").0))
        XCTAssertTrue(message.contains("one is not two"), message)
    }

    func testDriverMapsOsExitCodes() throws {
        XCTAssertEqual(try run("os.exit(0)\nerror(\"after exit\")\n").0, .passed)
        XCTAssertEqual(try run("os.exit(true)\n").0, .passed)
        XCTAssertEqual(try run("os.exit()\n").0, .passed)
        XCTAssertTrue(failure(try run("os.exit(1)\n").0)?.contains("os.exit(1)") == true)
        XCTAssertTrue(failure(try run("os.exit(false)\n").0)?.contains("os.exit(1)") == true)
        // A pcall in the file cannot turn an exit into a pass.
        XCTAssertTrue(failure(try run("pcall(os.exit, 3)\n").0)?.contains("os.exit(3)") == true)
    }

    func testDriverFailsOnSyntaxErrorWithTheLine() throws {
        let message = try XCTUnwrap(failure(try run("local a = 1\nlocal = 2\n", name: "syntax.test.lua").0))
        XCTAssertTrue(message.contains("syntax.test.lua:2:"), message)
    }

    func testDriverFindsTheHarness() throws {
        XCTAssertEqual(try run("local h = require(\"harness\")\nassert(type(h.eq) == \"function\")\n").0, .passed)
    }

    func testDriverGivesEachFileAFreshState() throws {
        XCTAssertEqual(try run("LEAKED_GLOBAL = 1\n").0, .passed)
        XCTAssertEqual(try run("assert(LEAKED_GLOBAL == nil, \"global leaked between files\")\n").0, .passed)
    }
}
