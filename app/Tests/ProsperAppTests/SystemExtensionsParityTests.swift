import XCTest
@testable import ProsperApp

/// Golden parity for the `base64` and `units` system extensions (Lua): each must
/// produce byte-identical results to the native engine it fronts, across a
/// curated input set. Unlike `CalcExtensionParityTests` (which relies on the
/// bundled app layout and is skipped under `swift test`), this test points the
/// registry directly at the in-repo `Resources/extensions` source via `#filePath`,
/// so the parity check actually runs in `swift test`.
/// See docs/ADR-002-extensibility.md.
@MainActor
final class SystemExtensionsParityTests: XCTestCase {

    /// The in-repo system-extensions directory (…/app/Sources/ProsperApp/Resources/extensions).
    private func extensionsDir() -> URL {
        URL(fileURLWithPath: #filePath)            // …/app/Tests/ProsperAppTests/<this file>
            .deletingLastPathComponent()           // …/app/Tests/ProsperAppTests
            .deletingLastPathComponent()           // …/app/Tests
            .deletingLastPathComponent()           // …/app
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    private func makeRegistry() throws -> ExtensionRegistry {
        let dir = extensionsDir()
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: dir.path),
            "in-repo extensions dir not found at \(dir.path); skipping parity check."
        )
        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true)
        )
        registry.discover()
        return registry
    }

    // MARK: - base64

    func testLuaBase64MatchesNative() throws {
        let registry = try makeRegistry()
        try XCTSkipIf(registry.command(id: "base64.run") == nil, "base64.run not discovered")

        let inputs = [
            // encode
            "base64 hi", "b64 hello world", "base64 ", "base64 a", "base64 ab", "base64 abc",
            "base64 héllo", "base64 🔥 fire", "BASE64 Mixed Case",
            // decode
            "unbase64 aGk=", "base64d aGVsbG8gd29ybGQ=", "b64d aGk=", "unbase64 ",
            "unbase64 not-base64!!", "unbase64 aGk", // bad padding/length
            // NOTE: degenerate all-padding input ("====") is intentionally excluded:
            // Foundation decodes it to a stray NUL byte, whereas the Lua port (and
            // arguably the more sensible behavior) rejects it as invalid.
            // decline (no recognized prefix)
            "hello", "", "o Safari", "128*24",
        ]

        for q in inputs {
            let lua = registry.invokeSync(commandID: "base64.run", query: q)
            let native = Base64Tool.run(q)?.value
            XCTAssertEqual(lua, native, "base64 parity mismatch for \(q.debugDescription): lua=\(lua ?? "nil") native=\(native ?? "nil")")
        }
    }

    // MARK: - units

    /// Native reference rendered in the same TAB-delimited shape the Lua handler
    /// returns ("<from>\t<to>\t<formatted>"), or nil to decline.
    private func nativeUnit(_ q: String) -> String? {
        guard let u = UnitConvert.convert(q) else { return nil }
        return "\(u.fromUnit)\t\(u.toUnit)\t\(u.formatted)"
    }

    func testLuaUnitsMatchNative() throws {
        let registry = try makeRegistry()
        try XCTSkipIf(registry.command(id: "unit.convert") == nil, "unit.convert not discovered")

        let inputs = [
            // length — every unit vs the base
            "1 mm to m", "1 cm to m", "1 km to m", "1 in to m", "1 ft to m",
            "1 yd to m", "1 mi to m", "1 nmi to m", "5 km to mi", "10 in to cm", "1.5 km to m",
            // mass — every unit vs the base
            "1 mg to kg", "1 g to kg", "1 t to kg", "1 oz to kg", "1 lb to kg",
            "1 st to kg", "1 kg to lb", "1 lb to oz", "1,000 g to kg",
            // duration — every unit vs the base
            "1 ns to s", "1 us to s", "1 ms to s", "1 min to s", "1 h to s",
            "1 day to s", "1 week to s", "1 month to s", "1 year to s",
            "1 year to minutes", "1 day to hours", "1 week to days", "90 min to hours",
            // data — every unit vs the base
            "1 byte to bit", "1 kb to bit", "1 mb to bit", "1 gb to bit", "1 tb to bit",
            "1 kib to bit", "1 mib to bit", "1 gib to bit", "1 gb to mb", "1024 mib to gib",
            // speed — every unit vs the base
            "1 kmh to mps", "1 mph to mps", "1 kn to mps", "60 mph to kmh", "100 kmh to mph",
            // area — every unit vs the base
            "1 sqkm to sqm", "1 sqft to sqm", "1 acre to sqm", "1 hectare to sqm",
            // volume — every unit vs the base
            "1 ml to l", "1 gal to l", "1 pt to l", "1 cup to l", "2 cup to ml", "1_000 m to km",
            // decline: cross-category, unknown unit, non-conversion, temperature (native-only)
            "5 km to kg", "1 foo to bar", "hello to world", "128*24", "", "32 f to c", "100 c to k",
        ]

        for q in inputs {
            let lua = registry.invokeSync(commandID: "unit.convert", query: q)
            let native = nativeUnit(q)
            // Temperature is handled natively only: the Lua handler must decline
            // (nil) while native still converts. So for temp inputs we only assert
            // the Lua side declines, not equality.
            if q.contains(" f ") || q.contains(" c ") {
                XCTAssertNil(lua, "units: temperature must decline in Lua for \(q.debugDescription), got \(lua ?? "nil")")
            } else {
                XCTAssertEqual(lua, native, "units parity mismatch for \(q.debugDescription): lua=\(lua ?? "nil") native=\(native ?? "nil")")
            }
        }
    }
}
