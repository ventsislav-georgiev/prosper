import Network
import XCTest
@testable import ProsperApp

/// #1326: account-pool leftovers carried from P2b-1. (a) a rename relabels the Keychain item, (b) an ended hold
/// leaves state.json on the next write, (d) a lost listener stays lost until Start. (c) lives in
/// AgentPoolThrottleRetryTests (its rig). Fake secrets, temp dirs and ephemeral loopback ports only.
final class AgentPoolCarryTests: XCTestCase {
    // (a): the pane's rename moves the item's label with the account; the token is untouched.
    @MainActor
    func testRenameRelabelsTheKeychainItem() async throws {
        let r = try ccpoolPaneRig()
        try r.add(["Example Org A"])
        let id = try XCTUnwrap(r.store.snapshot.accounts["Example Org A"]?.id)
        XCTAssertEqual(r.secrets.label(id: id), "Example Org A")
        r.model.rename("Example Org A", to: "Example Org B")
        XCTAssertEqual(r.store.snapshot.order, ["Example Org B"])
        XCTAssertEqual(r.secrets.label(id: id), "Example Org B", "the item follows the rename")
        XCTAssertEqual(try r.secrets.token(id: id), "tok-Example Org A", "the token is never rewritten")
        XCTAssertEqual(AgentPoolKeychainSecrets.itemLabel("Example Org B"), "Prosper ccpool: Example Org B")
    }

    // (a): a relabel that fails leaves the rename standing and logs the stale name, never the token.
    func testFailedRelabelKeepsTheRenameAndLogsTheOldName() throws {
        let log = AgentPoolCapturingLogger()
        let dir = tempDir()
        let store = AgentPoolStore(directory: dir, logger: log)
        let secrets = AgentPoolMemorySecrets()
        let id = try store.addAccount(label: "Example Org A", token: "tok-example-a", secrets: secrets)
        secrets.refuseRelabel = true
        try store.renameAccount("Example Org A", to: "Example Org B", secrets: secrets)
        XCTAssertEqual(store.snapshot.order, ["Example Org B"])
        XCTAssertEqual(AgentPoolStore(directory: dir).snapshot.order, ["Example Org B"], "on disk too")
        XCTAssertEqual(secrets.label(id: id), "Example Org A")
        let notes = log.lines.filter { $0.contains("could not be relabelled") }
        XCTAssertEqual(notes.count, 1, "\(log.lines)")
        XCTAssertTrue(notes.last?.contains("Prosper ccpool: Example Org A") == true, "\(notes)")
        XCTAssertFalse(log.lines.contains { $0.contains("tok-example") }, "\(log.lines)")
    }

    // (b): a state.json with an ended hold loads, and the next write drops it; a hold still running stays.
    func testEndedHoldLeavesStateOnTheNextWrite() throws {
        let t0 = 1_800_000_000
        let dir = tempDir()
        let five = AgentPoolCore.fiveHour
        let json = """
        {"order":["Example Org A","Example Org B"],"accounts":{
         "Example Org A":{"id":"id-a","cooldown":{"\(five)":\(t0 - 60)},"held":\(t0 - 60)},
         "Example Org B":{"id":"id-b","cooldown":{"\(five)":\(t0 + 3600)},"held":\(t0 + 3600)}}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("state.json"))
        let store = AgentPoolStore(directory: dir, clock: { Double(t0) })
        XCTAssertEqual(store.snapshot.order, ["Example Org A", "Example Org B"], "it loads")
        store.mutate { $0.order = ["Example Org B", "Example Org A"] }   // a write (#1838: was moveAccount, removed)
        let data = try Data(contentsOf: dir.appendingPathComponent("state.json"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try XCTUnwrap(obj["accounts"] as? [String: [String: Any]])
        XCTAssertTrue(accounts["Example Org A"]?["held"] == nil, "\(accounts)")
        XCTAssertEqual(accounts["Example Org B"]?["held"] as? Int, t0 + 3600)
        XCTAssertTrue(AgentPoolStore(directory: dir, clock: { Double(t0) }).snapshot.accounts["Example Org A"]?.held == nil)
    }

    // (d) decided: a listener lost after it ran is never re-armed by Prosper; Start is the way back.
    func testLostListenerIsNotReArmed() throws {
        let log = AgentPoolCapturingLogger()
        let store = AgentPoolStore(directory: tempDir())
        var cfg = AgentPoolServiceConfig()
        cfg.port = 0
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        let service = AgentPoolService(config: cfg, store: store, secrets: AgentPoolMemorySecrets(), logger: log)
        addTeardownBlock { service.stop() }
        guard case .running = service.start() else { return XCTFail("\(service.status)") }
        let l = try XCTUnwrap(service.currentListener)
        l.stateUpdateHandler?(.waiting(.posix(.ENETDOWN)))
        XCTAssertEqual(service.status, .failed(AgentPoolService.reasonLost))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(service.status, .failed(AgentPoolService.reasonLost), "still lost: nothing re-armed it")
        XCTAssertTrue(service.currentListener == nil)
        XCTAssertEqual(log.lines.filter { $0.contains("proxy listening on loopback") }.count, 1, "\(log.lines)")
        guard case .running = service.start() else { return XCTFail("Start brings it back: \(service.status)") }
    }
}
