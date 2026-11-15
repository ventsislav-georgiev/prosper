import Foundation
import XCTest
@testable import ProsperApp

/// #1181 (R1181-m a): the phone's models reply says "loaded" only when the resident model IS the row's model.
/// No model, no socket: DchChat's seams are fakes (made-up ids) and the reply goes to a recorder that is decoded as a value.
final class DchModelsReplyTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = [Data]()
        func add(_ d: Data) { lock.lock(); frames.append(d); lock.unlock() }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return frames }
    }

    private func reply(onDisk: Bool = true, resident: String?) async -> (type: UInt8, rows: [[String: Any]])? {
        let chat = DchChat(), rec = Recorder()
        chat.modelId = { "example-model-a" }
        chat.isModelOnDisk = { _ in onDisk }
        chat.residentId = { resident }
        await chat.models(Data()) { rec.add($0) }
        guard rec.all.count == 1, let f = rec.all.first, f.count > 5 else { return nil }
        let body = try? JSONSerialization.jsonObject(with: f.subdata(in: (f.startIndex + 5)..<f.endIndex))
        return (f[f.startIndex], body as? [[String: Any]] ?? [])
    }

    func testResidentIsTheSettingMarksLoaded() async {
        let r = await reply(resident: "example-model-a")
        XCTAssertEqual(r?.type, DchFrame.modelsResp)
        XCTAssertEqual(r?.rows.count, 1)
        XCTAssertEqual(r?.rows.first?["id"] as? String, "example-model-a")
        XCTAssertEqual(r?.rows.first?["loaded"] as? Bool, true)
    }

    func testAnotherResidentModelIsNotLoaded() async {
        let r = await reply(resident: "example-model-b")
        XCTAssertEqual(r?.rows.count, 1)
        XCTAssertEqual(r?.rows.first?["loaded"] as? Bool, false)
    }

    func testNoResidentModelIsNotLoaded() async {
        let r = await reply(resident: nil)
        XCTAssertEqual(r?.rows.first?["loaded"] as? Bool, false)
    }

    func testModelNotOnDiskIsTheEmptyList() async {
        let r = await reply(onDisk: false, resident: "example-model-a")
        XCTAssertEqual(r?.type, DchFrame.modelsResp)
        XCTAssertEqual(r?.rows.count, 0)
    }
}
