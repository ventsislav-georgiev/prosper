import Foundation
import XCTest
@testable import LuaRuntime

/// #1099: what Ghostty's init can leave the process in (it sets LC_ALL from LANG): a UTF-8 LC_CTYPE and a
/// comma decimal point.
let luaTestLocale = "de_DE.UTF-8"

/// Runs `body` with LC_CTYPE and LC_NUMERIC set to `locale` and restores both after; skips when it is missing.
func withProcessLocale(_ locale: String, _ body: () throws -> Void) throws {
    // Copied now: the pointer setlocale returns is reused by the next call.
    let saved = [LC_CTYPE, LC_NUMERIC].map { ($0, String(cString: setlocale($0, nil))) }
    defer { for (category, name) in saved { setlocale(category, name) } }
    for category in [LC_CTYPE, LC_NUMERIC] where setlocale(category, locale) == nil {
        throw XCTSkip("locale \(locale) is not available")
    }
    try body()
}

/// #1099: the embedded Lua's string and number paths use the C locale whatever the process locale is. Before,
/// under a UTF-8 LC_CTYPE lower() rewrote UTF-8 lead bytes and the % classes matched bytes over 127, and under
/// a comma LC_NUMERIC tostring(1.5) was "1,5", so extensions changed behaviour once the first terminal opened.
final class LuaLocaleTests: XCTestCase {
    private func currentLocale() -> [String] {
        [LC_CTYPE, LC_NUMERIC].map { String(cString: setlocale($0, nil)) }
    }

    /// Each row: a Lua expression evaluated in the app's sandboxed runtime, loaded and run under the test
    /// locale, and the string it must return.
    private func assertUnderTestLocale(_ rows: [(String, String)], line: UInt = #line) throws {
        try withProcessLocale(luaTestLocale) {
            // A leg that silently ran in "C" would pin nothing.
            XCTAssertEqual(currentLocale(), [luaTestLocale, luaTestLocale], line: line)
            XCTAssertEqual(String(cString: localeconv().pointee.decimal_point), ",", line: line)
            let lua = try LuaRuntime(allowLoad: true)
            for (expr, expected) in rows {
                try lua.run("function probe() return \(expr) end")
                XCTAssertEqual(try lua.callGlobal("probe"), expected, expr, line: line)
            }
        }
    }

    /// The high bytes (as hex) that `test` holds for, "" when none.
    private func highBytes(_ test: String) -> String {
        "(function() local t = {} for b = 128, 255 do local c = string.char(b) "
            + "if \(test) then t[#t + 1] = string.format('%02X', b) end end return table.concat(t, ' ') end)()"
    }

    func testLowerAndUpperLeaveUTF8BytesAlone() throws {
        try assertUnderTestLocale([
            ("('ÀÉÎõü Abc'):lower()", "ÀÉÎõü abc"),
            ("('ÀÉÎõü Abc'):upper()", "ÀÉÎõü ABC"),
            (highBytes("c:lower() ~= c or c:upper() ~= c"), ""),
        ])
    }

    func testPercentClassesMatchNoByteOver127() throws {
        try assertUnderTestLocale([
            (highBytes("c:find('^%a$')"), ""),
            (highBytes("c:find('^%w$')"), ""),
            (highBytes("c:find('^%l$')"), ""),
            (highBytes("c:find('^%u$')"), ""),
            (highBytes("c:find('^%s$')"), ""),
            (highBytes("c:find('^%p$')"), ""),
            (highBytes("c:find('^%c$')"), ""),
            (highBytes("c:find('^%g$')"), ""),
            // The no-break space: a UTF-8 LC_CTYPE made it %s, which broke the clipboard check (#1021).
            ("tostring(('\\xA0'):find('%s'))", "nil"),
            ("tostring(('ÀÉ'):find('%a'))", "nil"),
            // ASCII still classifies.
            ("(('Ab1 _!\\t'):gsub('%a', ''))", "1 _!\t"),
            ("(('Ab1 _!\\t'):gsub('%s', ''))", "Ab1_!"),
            ("(('Ab1 _!\\t'):gsub('%p', ''))", "Ab1 \t"),
        ])
    }

    func testNumbersUseADotWhateverTheLocale() throws {
        try assertUnderTestLocale([
            ("tostring(1.5)", "1.5"),
            ("tostring(2.0)", "2.0"),
            ("tostring(tonumber('1.5'))", "1.5"),
            ("tostring(tonumber('1,5'))", "nil"),
            ("string.format('%.2f', 1.5)", "1.50"),
            ("tostring(load('return 1.5')())", "1.5"),
            ("tostring(load('return 1.5')() == 3 / 2)", "true"),
            ("tostring('10' + 0.5)", "10.5"),
        ])
    }

    func testExtensionsCannotReachOsSetlocale() throws {
        // The sandbox nils the os global, but the debug library still reaches the registry's _LOADED.os.
        let lua = try LuaRuntime()
        try lua.run("""
            function probe()
              local ok, f = pcall(function() return debug.getregistry()._LOADED.os.setlocale end)
              return tostring(not ok or f == nil)
            end
            """)
        XCTAssertEqual(try lua.callGlobal("probe"), "true")
    }

    func testLocaleHelperRestoresTheProcessLocale() throws {
        let before = currentLocale()
        var inside: [String] = []
        try withProcessLocale(luaTestLocale) { inside = currentLocale() }
        XCTAssertEqual(inside, [luaTestLocale, luaTestLocale])
        XCTAssertNotEqual(before, inside, "the process already ran under \(luaTestLocale): a leak would not show")
        XCTAssertEqual(currentLocale(), before, "withProcessLocale leaked the process locale")
    }
}
