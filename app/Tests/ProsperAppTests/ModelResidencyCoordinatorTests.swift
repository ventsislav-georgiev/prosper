import Foundation
import MLXLMCommon
import os.lock
import XCTest
@testable import ProsperApp

/// #411: the residency coordinator's release window, on a test instance whose
/// `makeEngine` returns fakes (`ModelResidencyCoordinator.shared` and real models are
/// never touched). The fakes' load and unload can park on continuations the test
/// resumes, so every interleaving below is driven, not raced.
///
/// `ModelResidencyCoordinator.activeFlag` is static (shared with the real instance):
/// every row restores it in tearDown.
@MainActor
final class ModelResidencyCoordinatorTests: XCTestCase {

    /// Shared ledger of every fake: what is resident, what is loading, what parked.
    final class Probe: @unchecked Sendable {
        struct State {
            var parkLoads = true
            var parkUnloads = false
            var parkedLoads: [CheckedContinuation<Void, Never>] = []
            var parkedUnloads: [CheckedContinuation<Void, Never>] = []
            var resident = 0, maxResident = 0
            var loading = 0, maxLoading = 0
            var unloadDuringLoad = false
            var log: [String] = []
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        func with<T>(_ body: (inout State) -> T) -> T { state.withLockUnchecked { body(&$0) } }
        var parkedLoads: Int { with { $0.parkedLoads.count } }
        var parkedUnloads: Int { with { $0.parkedUnloads.count } }
        /// No-op when nothing is parked (the waitUntil before it already failed the row).
        func resumeLoad() { with { $0.parkedLoads.isEmpty ? nil : $0.parkedLoads.removeFirst() }?.resume() }
        func resumeUnload() { with { $0.parkedUnloads.isEmpty ? nil : $0.parkedUnloads.removeFirst() }?.resume() }
    }

    /// Class-shaped like both real engines (actors). Resident from load start until its
    /// unload finishes; a load of an already-loaded instance returns at once (the
    /// `LlamaAgentEngine.ensureModel` shape).
    final class FakeEngine: AgentChatEngine, @unchecked Sendable {
        let name: String
        let probe: Probe
        private let mine = OSAllocatedUnfairLock(initialState: (loaded: false, loads: 0, unloads: 0))
        init(_ name: String, _ probe: Probe) { self.name = name; self.probe = probe }

        var loaded: Bool { mine.withLock { $0.loaded } }
        var loads: Int { mine.withLock { $0.loads } }
        var unloads: Int { mine.withLock { $0.unloads } }

        func load() async {
            if loaded { return }
            let park = probe.with { s -> Bool in
                s.loading += 1; s.maxLoading = max(s.maxLoading, s.loading)
                s.log.append("load-start \(name)")
                return s.parkLoads
            }
            mine.withLock { $0.loads += 1 }
            if park {
                await withCheckedContinuation { c in probe.with { $0.parkedLoads.append(c) } }
            }
            let wasLoaded = mine.withLock { m -> Bool in let w = m.loaded; m.loaded = true; return w }
            probe.with { s in
                s.loading -= 1
                if !wasLoaded { s.resident += 1; s.maxResident = max(s.maxResident, s.resident) }
                s.log.append("load-end \(name)")
            }
        }

        func unload() async {
            let park = probe.with { s -> Bool in
                if s.loading > 0 { s.unloadDuringLoad = true }
                s.log.append("unload-start \(name)")
                return s.parkUnloads
            }
            if park {
                await withCheckedContinuation { c in probe.with { $0.parkedUnloads.append(c) } }
            }
            let wasLoaded = mine.withLock { m -> Bool in let w = m.loaded; m.loaded = false; m.unloads += 1; return w }
            probe.with { s in
                if wasLoaded { s.resident -= 1 }
                s.log.append("unload-end \(name)")
            }
        }

        nonisolated func generateChat(
            messages: [MLXEngine.ChatTurn], tools: [ToolSpec], maxTokens: Int,
            temperature: Float, topP: Float, stop: [String]
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Engines handed out in order (a fresh instance per load, the MLX shape), or the
    /// same one every time when `singleton` is set (the GGUF shape).
    final class Factory: @unchecked Sendable {
        let probe = Probe()
        private let made = OSAllocatedUnfairLock(initialState: [FakeEngine]())
        let singleton: FakeEngine?
        init(singleton: Bool) { self.singleton = singleton ? FakeEngine("S", probe) : nil }
        var engines: [FakeEngine] { made.withLock { $0 } }

        func make() async -> FakeEngine {
            let engine = singleton ?? made.withLock { m -> FakeEngine in
                let e = FakeEngine(["A", "B", "C", "D"][m.count], probe); m.append(e); return e
            }
            await engine.load()
            return engine
        }

        func coordinator() -> ModelResidencyCoordinator {
            ModelResidencyCoordinator { _, _ in await self.make() }
        }
    }

    nonisolated(unsafe) private var savedFlag = false

    nonisolated override func setUp() {
        savedFlag = ModelResidencyCoordinator.activeFlag.withLock { $0 }
        ModelResidencyCoordinator.activeFlag.withLock { $0 = false }
    }

    nonisolated override func tearDown() {
        let saved = savedFlag
        ModelResidencyCoordinator.activeFlag.withLock { $0 = saved }
    }

    private var flag: Bool { ModelResidencyCoordinator.isAgentActive }

    private func waitUntil(
        _ what: String, file: StaticString = #filePath, line: UInt = #line,
        _ cond: () async -> Bool
    ) async {
        for _ in 0..<500 {
            if await cond() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// Long enough for a wrongly unblocked task to reach its next park point.
    private func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }

    private func acquire(_ c: ModelResidencyCoordinator) async throws -> FakeEngine {
        try await c.acquireAgent { _, _ in } as! FakeEngine
    }

    /// Acquire A and leave it resident.
    private func residentA(_ f: Factory, _ c: ModelResidencyCoordinator) async throws -> FakeEngine {
        let first = Task { try await acquire(c) }
        await waitUntil("A parked in load") { f.probe.parkedLoads == 1 }
        f.probe.resumeLoad()
        return try await first.value
    }

    // MARK: R1 — an acquire during releaseAgent's unload

    func testR1AcquireDuringReleaseWaitsAndLoadsAFreshEngine() async throws {
        let f = Factory(singleton: false)
        let c = f.coordinator()
        let a = try await residentA(f, c)
        XCTAssertEqual(a.name, "A")

        f.probe.with { $0.parkUnloads = true }
        let release = Task { await c.releaseAgent() }
        await waitUntil("A parked in unload") { f.probe.parkedUnloads == 1 }

        let returned = OSAllocatedUnfairLock<FakeEngine?>(initialState: nil)
        let second = Task { () throws -> FakeEngine in
            let e = try await acquire(c)
            returned.withLock { $0 = e }
            return e
        }
        await settle()
        XCTAssertNil(returned.withLock { $0 }, "acquire returned the engine being unloaded")
        XCTAssertEqual(f.probe.with { $0.log.filter { $0.hasPrefix("load-start") }.count }, 1,
                       "a fresh load started while A was still unloading")
        let modeDuringRelease = await c.mode
        XCTAssertEqual(modeDuringRelease, .inline)

        f.probe.resumeUnload()
        await release.value
        await waitUntil("B parked in load") { f.probe.parkedLoads == 1 }
        f.probe.resumeLoad()
        let b = try await second.value

        XCTAssertFalse(b === a, "acquire handed out the dying engine")
        XCTAssertEqual(b.name, "B")
        XCTAssertEqual(b.loads, 1)
        XCTAssertTrue(b.loaded)
        XCTAssertEqual(a.unloads, 1)
        XCTAssertFalse(a.loaded)
        let mode = await c.mode
        XCTAssertEqual(mode, .agent)
        let installed = await c.currentAgentEngine()
        XCTAssertTrue(installed as? FakeEngine === b)
        XCTAssertEqual(f.probe.with { $0.maxResident }, 1, "two engines resident: \(f.probe.with { $0.log })")
        XCTAssertFalse(f.probe.with { $0.unloadDuringLoad }, f.probe.with { $0.log }.joined(separator: ", "))
    }

    // MARK: R1b — a stale acquirer and the singleton engine

    /// Drives: acquire 1 parked in load, releaseAgent (cancels it; the fake ignores
    /// cancellation, so its load still completes), acquire 2 on the same instance.
    /// `newerFirst`: if acquire 2 also reached its load (it must not — it waits out the
    /// cancelled load), finish acquire 2 first so acquire 1's stale completion runs
    /// after the install (the brief's R1b order); otherwise and when false, finish
    /// acquire 1 first while acquire 2 is still in flight (QA's amendment order).
    private func runSingletonStaleAcquire(newerFirst: Bool) async throws {
        let f = Factory(singleton: true)
        let s = f.singleton!
        let c = f.coordinator()

        let first = Task { try await acquire(c) }
        await waitUntil("acquire 1 parked in load") { f.probe.parkedLoads == 1 }
        let release = Task { await c.releaseAgent() }
        await settle()   // the release has cancelled the load and waits it out
        let second = Task { try await acquire(c) }
        await settle()
        let bothParked = f.probe.parkedLoads == 2

        var unloadsAtInstall = -1
        if bothParked && newerFirst {
            f.probe.with { s in s.parkedLoads.swapAt(0, 1) }
            f.probe.resumeLoad()                       // acquire 2's load
            _ = try await second.value
            unloadsAtInstall = s.unloads
            f.probe.resumeLoad()                       // acquire 1's stale completion
            await assertCancelled(first)
        } else {
            XCTAssertFalse(bothParked, "acquire 2 loaded concurrently with the cancelled load")
            f.probe.resumeLoad()                       // acquire 1's load
            await assertCancelled(first)               // its completion ran, acquire 2 in flight
            if !bothParked {
                await waitUntil("acquire 2 parked in load") { f.probe.parkedLoads == 1 }
            }
            f.probe.resumeLoad()
            _ = try await second.value
            unloadsAtInstall = s.unloads
        }
        await release.value
        await settle()

        XCTAssertTrue(s.loaded, "the installed engine was unloaded: \(f.probe.with { $0.log })")
        XCTAssertEqual(s.unloads, unloadsAtInstall, "unloaded after acquire 2 installed it")
        let mode = await c.mode
        XCTAssertEqual(mode, .agent)
        let installed = await c.currentAgentEngine()
        XCTAssertTrue(installed as? FakeEngine === s)
        XCTAssertEqual(f.probe.with { $0.maxLoading }, 1, "two loads at once: \(f.probe.with { $0.log })")
        // No unload after acquire 2's load began.
        let log = f.probe.with { $0.log }
        let lastLoadStart = log.lastIndex(of: "load-start S")!
        XCTAssertFalse(log[lastLoadStart...].contains("unload-start S"), log.joined(separator: ", "))
        XCTAssertTrue(flag)
    }

    private func assertCancelled(_ t: Task<FakeEngine, Error>, line: UInt = #line) async {
        do { _ = try await t.value; XCTFail("stale acquire 1 returned an engine", line: line) }
        catch is CancellationError {}
        catch { XCTFail("stale acquire 1 threw \(error)", line: line) }
    }

    func testR1bStaleAcquirerCompletingAfterNewerInstallKeepsIt() async throws {
        try await runSingletonStaleAcquire(newerFirst: true)
    }

    func testR1bStaleAcquirerCompletingWhileNewerInFlightKeepsIt() async throws {
        try await runSingletonStaleAcquire(newerFirst: false)
    }

    // MARK: activeFlag

    func testActiveFlagAcrossAnInFlightRelease() async throws {
        let f = Factory(singleton: false)
        let c = f.coordinator()

        // Nothing resident, nothing loading: a release is a no-op that leaves it false.
        await c.releaseAgent()
        XCTAssertFalse(flag)

        _ = try await residentA(f, c)
        XCTAssertTrue(flag)
        await c.releaseAgent()
        XCTAssertFalse(flag, "a release with nothing newer must clear it")

        _ = try await residentA(f, c)
        f.probe.with { $0.parkUnloads = true }
        let release = Task { await c.releaseAgent() }
        await waitUntil("release parked in unload") { f.probe.parkedUnloads == 1 }
        XCTAssertTrue(flag, "cleared while the dying engine is still resident")
        let next = Task { try await acquire(c) }
        await settle()
        f.probe.resumeUnload()
        await release.value
        XCTAssertTrue(flag, "release cleared the flag under a newer in-flight acquire")
        await waitUntil("next acquire parked in load") { f.probe.parkedLoads == 1 }
        XCTAssertTrue(flag)
        f.probe.resumeLoad()
        _ = try await next.value
        XCTAssertTrue(flag)

        f.probe.with { $0.parkUnloads = false }
        await c.releaseAgent()
        XCTAssertFalse(flag)
    }
}
