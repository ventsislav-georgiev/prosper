import Network
import Security
import XCTest
@testable import ProsperApp

/// #871 guards: the Keychain query shape (no SecItem call), the production port and upstream never
/// touched by tests (errata C4/C5), loopback-only listener, no call site outside CCPool/ in P1.
final class CCPoolGuardTests: XCTestCase {
    private var testsDir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }
    private var sourcesDir: URL { testsDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp") }

    private func swiftFiles(under dir: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    private func ccpoolTestFiles() -> [URL] {
        swiftFiles(under: testsDir).filter { $0.lastPathComponent.hasPrefix("CCPool") }
    }

    // 3.4 / errata C3: asserted without calling SecItem.
    func testCCPoolKeychainQueryDictionaries() {
        let base = CCPoolKeychainSecrets.baseQuery(id: "uuid-1")
        XCTAssertEqual(base[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(base[kSecAttrService as String] as? String, "eu.illegible.prosper.ccpool")
        XCTAssertEqual(base[kSecAttrAccount as String] as? String, "uuid-1", "keyed by an opaque id, not the label")
        XCTAssertEqual(base[kSecAttrSynchronizable as String] as? Bool, false, "per Mac, never iCloud")
        XCTAssertEqual(base[kSecUseDataProtectionKeychain as String] as? Bool, true, "the data-protection keychain, like SyncKeyStore")
        let add = CCPoolKeychainSecrets.addQuery(id: "uuid-1", label: "alpha", token: Data("tok-alpha".utf8))
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(add[kSecAttrLabel as String] as? String, "Prosper ccpool: alpha")
        XCTAssertEqual(add[kSecValueData as String] as? Data, Data("tok-alpha".utf8))
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
        let read = CCPoolKeychainSecrets.readQuery(id: "uuid-1")
        XCTAssertEqual(read[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(read[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertNil(read[kSecValueData as String])
        XCTAssertThrowsError(try CCPoolKeychainSecrets.check(errSecMissingEntitlement)) {
            XCTAssertEqual($0 as? CCPoolSecretsError, .unavailable)
        }
    }

    // Errata C4: the production constants, asserted, never dialled.
    func testCCPoolProductionConstants() {
        XCTAssertEqual(CCPoolService.defaultPort, 8790)
        XCTAssertEqual(CCPoolService.productionUpstream.absoluteString, "https://api.anthropic.com")
        XCTAssertEqual(CCPoolServiceConfig().port, CCPoolService.defaultPort)
        XCTAssertEqual(CCPoolServiceConfig().replayCap, 32 << 20)
    }

    // Errata C4: no CCPool test names the production port outside the single assertion above.
    func testCCPoolNoTestUsesTheProductionPort() throws {
        let needle = "87" + "90"
        var hits: [String] = []
        for f in ccpoolTestFiles() {
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where l.contains(needle) && !l.contains("XCTAssertEqual(CCPoolService.defaultPort, \(needle))") {
                hits.append("\(f.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertGreaterThanOrEqual(ccpoolTestFiles().count, 3, "the guard found the CCPool test files")
        XCTAssertEqual(hits, [])
    }

    // Errata C5: no CCPool test reads the Python ccpool home or the Keychain.
    func testCCPoolNoTestReadsPythonVaultOrKeychain() throws {
        let needles = ["." + "ccpool/", "CCPOOL" + "_HOME", "vault" + ".json", "SecItem" + "Copy", "SecItem" + "Add",
                       "SecItem" + "Delete", "SecItem" + "Update", "home" + "DirectoryForCurrentUser", "NSHome" + "Directory",
                       // P2a: nor the real environment or the real home by another route.
                       "ProcessInfo.processInfo" + ".environment", "getpw" + "uid", "homeDirectory" + "(forUser"]
        var hits: [String] = []
        for f in ccpoolTestFiles() {
            let text = try String(contentsOf: f, encoding: .utf8)
            hits += needles.filter { text.contains($0) }.map { "\(f.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(hits, [])
    }

    // P2b-1: outside CCPool/, exactly two Swift files name a CCPool symbol: AppDelegate owns the
    // runtime (launch, enable/disable, quit) and SettingsWindow mounts the pane. Nothing outside
    // calls sessionEnv (wired in P2b-2).
    func testCCPoolNoCallSiteOutsideItsDirectory() throws {
        let symbol = try NSRegularExpression(pattern: #"\bCCPool\w*|\bsessionEnv\b"#)
        var hits: Set<String> = []
        for f in swiftFiles(under: sourcesDir) where !f.path.contains("/CCPool/") {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in symbol.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                hits.insert("\(f.lastPathComponent): \((text as NSString).substring(with: m.range))")
            }
        }
        XCTAssertFalse(swiftFiles(under: sourcesDir.appendingPathComponent("CCPool")).isEmpty, "the guard found the sources")
        XCTAssertEqual(hits, ["AppDelegate.swift: CCPoolRuntime", "SettingsWindow.swift: CCPoolRuntime", "SettingsWindow.swift: CCPoolPane"])
    }

    // P2b-1: under XCTest the app's runtime is never built, not even by a live push.
    @MainActor
    func testCCPoolRuntimeNeverBuiltUnderTest() {
        XCTAssertNil(CCPoolRuntime.shared)
        XCTAssertNil(CCPoolRuntime.production())
        CCPoolRuntime.setExtensionLive(false)
        CCPoolRuntime.setExtensionLive(true)
        XCTAssertNil(CCPoolRuntime.shared, "no store, Keychain or listener from a test run")
    }

    // P2a: the Python ccpool's path names exist once, in the one path rule (CCPoolMigration.vaultURL).
    func testCCPoolPythonPathsNamedOnce() throws {
        let files = swiftFiles(under: sourcesDir.appendingPathComponent("CCPool"))
        let all = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        // ("state.json" is also Prosper's own store file, so it is not counted.)
        for literal in ["\"vault" + ".json\"", "\"." + "ccpool\"", "\"CCPOOL" + "_HOME\""] {
            XCTAssertEqual(all.components(separatedBy: literal).count - 1, 1, literal)
        }
    }

    // P2a: no modal UI, no global events, no pasteboard anywhere in the CCPool sources.
    func testCCPoolSourcesUseNoModalUIOrGlobalEvents() throws {
        let needles = ["NSAlert" + "(", "NSOpen" + "Panel", "NSMenu" + "(", "CGEvent" + "Post", "NSPaste" + "board", "runModal"]
        var hits: [String] = []
        for f in swiftFiles(under: sourcesDir.appendingPathComponent("CCPool")) {
            let text = try String(contentsOf: f, encoding: .utf8)
            hits += needles.filter { text.contains($0) }.map { "\(f.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(hits, [])
    }

    // Tests never dial the production upstream or bind the production port.
    func testCCPoolRefusesProductionUpstreamAndPortUnderTest() {
        XCTAssertNotNil(CCPoolService.refusalUnderTest(CCPoolServiceConfig()))
        var cfg = CCPoolServiceConfig()
        cfg.port = 0
        XCTAssertNotNil(CCPoolService.refusalUnderTest(cfg), "production upstream refused")
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        XCTAssertNil(CCPoolService.refusalUnderTest(cfg))
        cfg.port = CCPoolService.defaultPort
        XCTAssertNotNil(CCPoolService.refusalUnderTest(cfg), "production port refused")

        var prod = CCPoolServiceConfig()
        prod.port = 0
        let log = CCPoolCapturingLogger()
        let svc = CCPoolService(config: prod, store: CCPoolStore(directory: tempDir()), secrets: CCPoolMemorySecrets(), logger: log)
        guard case .failed(let why) = svc.start() else { return XCTFail("started against the production upstream") }
        XCTAssertTrue(why.contains("production upstream"), why)
        svc.stop()
    }

    // N4: the usage probe never dials the production upstream under XCTest.
    func testCCPoolUsageProbeRefusesProductionUpstreamUnderTest() async {
        XCTAssertTrue(CCPoolService.refusesUnderTest(CCPoolService.productionUpstream))
        XCTAssertFalse(CCPoolService.refusesUnderTest(URL(string: "http://127.0.0.1:9")!))
        guard CCPoolService.refusesUnderTest(CCPoolService.productionUpstream) else { return }
        let probe = await CCPoolUsage.probe(token: "tok-alpha", base: CCPoolService.productionUpstream, timeout: 1)
        XCTAssertNil(probe)
    }

    // X16: a connection never holds its service unowned; a released service must not crash a request.
    func testCCPoolNoUnownedReferences() throws {
        let files = swiftFiles(under: sourcesDir.appendingPathComponent("CCPool"))
        XCTAssertFalse(files.isEmpty)
        let hits = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("unowned") }.map(\.lastPathComponent)
        XCTAssertEqual(hits, [])
    }

    // Loopback only: 127.0.0.1 and the loopback interface, no address sharing.
    func testCCPoolListenerIsLoopbackOnly() {
        let p = CCPoolService.listenerParameters(port: 0)
        XCTAssertEqual(p.requiredInterfaceType, .loopback)
        XCTAssertFalse(p.allowLocalEndpointReuse)
        guard case .hostPort(let host, let port)? = p.requiredLocalEndpoint else { return XCTFail("no local endpoint") }
        XCTAssertEqual(host, .ipv4(.loopback))
        XCTAssertEqual(port, .any)
    }
}
