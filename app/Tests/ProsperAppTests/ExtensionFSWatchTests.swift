import Foundation
import XCTest
@testable import ProsperApp

/// Real FSEventStream round trip for `ExtensionFSWatch` (#373): the callback reads
/// `eventPaths` as a CFArray, which only holds with `kFSEventStreamCreateFlagUseCFTypes`
/// (without it the first event dereferences a `char **` as a CFArray and SIGSEGVs).
@MainActor
final class ExtensionFSWatchTests: XCTestCase {
    func testWatchDeliversChangedFilePathOnMain() throws {
        let fm = FileManager.default
        // A per-run directory in the suite's TMPDIR subdirectory (not $TMPDIR's root,
        // which is slow enough to stretch FSEvents delivery). The test creates and removes it.
        let dir = fm.temporaryDirectory
            .appendingPathComponent("prosper-tests/fsw-\(UUID().uuidString)", isDirectory: true).path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let watcher = ExtensionFSWatch.shared
        let saved = watcher.invoke
        defer {
            watcher.unwatch(extensionID: "test.fsw", path: dir)
            watcher.invoke = saved
            try? fm.removeItem(atPath: dir)
        }

        let fileName = "touched-\(UUID().uuidString).txt"
        let fired = expectation(description: "fs watch handler invoked")
        fired.assertForOverFulfill = false
        var got: (ext: String, handler: String, payload: String, onMain: Bool)?
        watcher.invoke = { ext, handler, payload in
            // Several batches may arrive (dir creation, coalescing): keep the first one
            // that names our file.
            guard got == nil, payload.contains(fileName) else { return }
            got = (ext, handler, payload, Thread.isMainThread)
            fired.fulfill()
        }

        watcher.watch(extensionID: "test.fsw", path: dir, handler: "onChange")
        try "hello".write(toFile: (dir as NSString).appendingPathComponent(fileName),
                          atomically: false, encoding: .utf8)
        wait(for: [fired], timeout: 5)

        let result = try XCTUnwrap(got)
        XCTAssertEqual(result.ext, "test.fsw")
        XCTAssertEqual(result.handler, "onChange")
        let obj = try JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any]
        let paths = try XCTUnwrap(obj?["paths"] as? [String])
        XCTAssertTrue(paths.contains { $0.hasSuffix(fileName) }, "payload: \(result.payload)")
        XCTAssertTrue(result.onMain, "invoke must run on the main thread")
    }
}
