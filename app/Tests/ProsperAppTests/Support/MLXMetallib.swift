import Foundation
import XCTest

/// #1279: a row that touches the MLX runtime first calls this. SwiftPM compiles no .metal, so a
/// `swift test` scratch has no metallib and MLX aborts the whole xctest process ("Failed to load the
/// default metallib"). Before this, such rows passed only when an earlier row's `Bundle(url:)` scan of
/// /Applications had put an installed Prosper.app (and its metallib) into NSBundle.allBundles.
/// Only MLX's colocated lookups count (mlx device.cpp load_default_library): mlx.metallib,
/// Resources/mlx.metallib and Resources/default.metallib in the directory of the image MLX is linked
/// into, never allBundles and never an installed app.
/// shortcut: assumes MLX is linked statically into the test binary (SwiftPM does so today); if MLX ever
/// becomes its own dylib, take the directory from a Cmlx symbol instead of #dsohandle.
func requireMLXMetallib() throws {
    var info = Dl_info()
    guard dladdr(#dsohandle, &info) != 0, let file = info.dli_fname else {
        throw XCTSkip("MLX: cannot locate the test binary (dladdr failed), so no metallib check; not running MLX")
    }
    let dir = URL(fileURLWithPath: String(cString: file)).deletingLastPathComponent()
    let names = ["mlx.metallib", "Resources/mlx.metallib", "Resources/default.metallib"]
    guard names.contains(where: { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) else {
        throw XCTSkip("no mlx.metallib beside the test binary (\(dir.path)): SwiftPM compiles no .metal; copy the "
            + "default.metallib scripts/build.sh stages (app/.build/<config>/mlx-swift_Cmlx.bundle/Contents/Resources/) "
            + "to \(dir.appendingPathComponent("mlx.metallib").path)")
    }
}
