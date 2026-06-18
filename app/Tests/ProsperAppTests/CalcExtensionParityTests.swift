import XCTest
@testable import ProsperApp

/// Golden parity: the `calc` system extension (Lua) must produce byte-identical
/// results to the native `Calc` engine it replaces, across a curated input set
/// covering operators, precedence, parens, unary, separators, unicode, decimals,
/// repeating decimals (format edge), and decline cases (no operator / div-by-0 /
/// non-math). See docs/ADR-002-extensibility.md.
@MainActor
final class CalcExtensionParityTests: XCTestCase {

    /// Native reference: the formatted result, or nil to decline.
    private func native(_ q: String) -> String? {
        guard let v = Calc.evaluate(q) else { return nil }
        return Calc.format(v)
    }

    func testLuaCalcMatchesNativeAcrossGoldenInputs() throws {
        let registry = ExtensionRegistry(
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true)
        )
        registry.discover()
        // System extensions live in Bundle.main/Contents/Resources/extensions,
        // populated by scripts/bundle.sh in the .app. Under `swift test`,
        // Bundle.main is the xctest runner, which has no extensions dir, so the
        // calc extension cannot be discovered. Skip rather than fail: this parity
        // check is only meaningful when run against the bundled app layout.
        try XCTSkipIf(
            registry.command(id: "calc.eval") == nil,
            "calc.eval not discovered (extensions not bundled under `swift test`); skipping parity check."
        )

        let inputs = [
            // value-producing
            "128*24", "2+3*4", "(2+3)*4", "10/4", "2^10", "6×7", "1_000*2",
            "1,000+1", "100÷8", "-5+3", "2^-2", "3.5*2", "1/3", "10%3",
            "2 + 2", "((1+2)*3)^2", "7-3-2", "2^3^2",
            // decline (native returns nil → extension must too)
            "42", "hello", "5/0", "10%0", "", "abc+def",
        ]

        for q in inputs {
            let lua = registry.invokeSync(commandID: "calc.eval", query: q)
            let ref = native(q)
            XCTAssertEqual(lua, ref, "parity mismatch for \(q.debugDescription): lua=\(lua ?? "nil") native=\(ref ?? "nil")")
        }
    }

    /// In-repo system-extensions dir (…/app/Sources/ProsperApp/Resources/extensions).
    private func extensionsDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    /// Percentage shorthands the native Calc cannot express (Raycast parity).
    func testCalcPercentages() throws {
        let dir = extensionsDir()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "extensions dir missing")
        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: UserDefaults(suiteName: "calc-pct-\(UUID().uuidString)")!
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "calc.eval") == nil, "calc.eval not discovered")

        let cases: [(String, String)] = [
            ("52% of 900", "468"),
            ("3% of 123", "3.69"),
            ("3% of $123", "3.69"),
            ("what is 10% of 250", "25"),
            ("20% off 50", "40"),
            ("120 + 10%", "132"),
            ("120 - 10%", "108"),
            ("1,000 + 5%", "1050"),
        ]
        for (q, expected) in cases {
            XCTAssertEqual(registry.invokeSync(commandID: "calc.eval", query: q), expected,
                           "percentage mismatch for \(q.debugDescription)")
        }

        // Plain arithmetic still works and percentages don't hijack modulo.
        XCTAssertEqual(registry.invokeSync(commandID: "calc.eval", query: "10%3"), "1")
        XCTAssertEqual(registry.invokeSync(commandID: "calc.eval", query: "128*24"), "3072")
        // A bare percentage with no "of/off/±" still declines.
        XCTAssertNil(registry.invokeSync(commandID: "calc.eval", query: "10%"))
    }
}
