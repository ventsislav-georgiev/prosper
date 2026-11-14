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
            userDir: tempDir("prosper-ext-test"),
            defaults: scratchDefaults("parity")
        )
        registry.discover()
        return registry
    }

    // MARK: - base64

    /// Native reference for the Base64 window's two panes (Base64Tool, the engine the launcher used): the encoding,
    /// and the decoding with "" where native says "(invalid base64)" (the Lua pane stays empty there).
    private func nativeBase64(forward: Bool, _ text: String) -> String? {
        let value = Base64Tool.run((forward ? "base64 " : "unbase64 ") + text)?.value
        return value == "(invalid base64)" ? "" : value
    }

    /// #1170: the Base64 window's forward and backward functions (the converter's `forward` / `backward` globals),
    /// run as the window runs them (AppDelegate.presentExtensionView's transform: callExtensionStringAsync on the
    /// extension's background lane), against the native engine.
    func testLuaBase64MatchesNative() async throws {
        let registry = try makeRegistry()
        let ext = "com.prosper.base64"
        guard registry.record(id: ext)?.isLive == true else { return XCTFail("\(ext) not discovered or not live") }
        let source = try String(contentsOf: extensionsDir().appendingPathComponent("base64/init.lua"), encoding: .utf8)
        XCTAssertTrue(source.contains(#"forward = "b64_encode""#) && source.contains(#"backward = "b64_decode""#),
                      "the window's pane functions are no longer b64_encode / b64_decode")

        let plain = ["hi", "hello world", "", "a", "ab", "abc", "héllo", "🔥 fire", "Mixed Case", "two\nlines"]
        let encoded = ["aGk=", "aGVsbG8gd29ybGQ=", "", " aGk= ", "8J+UpSBmaXJl",
                       // bad: illegal characters, length, a decoding that is not UTF-8
                       "not-base64!!", "aGk", "/w=="]
        // NOTE: degenerate all-padding input ("====") is intentionally excluded: Foundation decodes it to a stray
        // NUL byte, whereas the Lua port (and arguably the more sensible behavior) rejects it as invalid.
        var compared = 0
        for text in plain {
            let lua = await registry.callExtensionStringAsync(extensionID: ext, function: "b64_encode", args: [text])
            XCTAssertEqual(lua, nativeBase64(forward: true, text), "b64_encode parity for \(text.debugDescription)")
            let back = await registry.callExtensionStringAsync(extensionID: ext, function: "b64_decode",
                                                               args: [lua ?? ""])
            XCTAssertEqual(back, text, "b64_decode(b64_encode(\(text.debugDescription)))")
            compared += 1
        }
        for text in encoded {
            let lua = await registry.callExtensionStringAsync(extensionID: ext, function: "b64_decode", args: [text])
            XCTAssertEqual(lua, nativeBase64(forward: false, text), "b64_decode parity for \(text.debugDescription)")
            compared += 1
        }
        XCTAssertEqual(compared, plain.count + encoded.count)
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
