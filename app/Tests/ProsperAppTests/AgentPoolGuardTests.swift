import Network
import Security
import XCTest
@testable import ProsperApp

/// #871 guards: the Keychain query shape (no SecItem call), the production port and upstream never
/// touched by tests (errata C4/C5), loopback-only listener, no call site outside AgentPool/ in P1.
final class AgentPoolGuardTests: XCTestCase {
    private var testsDir: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }
    private var sourcesDir: URL { testsDir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp") }

    private func swiftFiles(under dir: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    private func ccpoolTestFiles() -> [URL] {
        swiftFiles(under: testsDir).filter { $0.lastPathComponent.hasPrefix("AgentPool") }
    }

    // 3.4 / errata C3: asserted without calling SecItem.
    func testAgentPoolKeychainQueryDictionaries() {
        let base = AgentPoolKeychainSecrets.baseQuery(id: "uuid-1")
        XCTAssertEqual(base[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(base[kSecAttrService as String] as? String, "eu.illegible.prosper.ccpool")
        XCTAssertEqual(base[kSecAttrAccount as String] as? String, "uuid-1", "keyed by an opaque id, not the label")
        XCTAssertEqual(base[kSecAttrSynchronizable as String] as? Bool, false, "per Mac, never iCloud")
        XCTAssertEqual(base[kSecUseDataProtectionKeychain as String] as? Bool, true, "the data-protection keychain, like SyncKeyStore")
        let add = AgentPoolKeychainSecrets.addQuery(id: "uuid-1", label: "alpha", token: Data("tok-alpha".utf8))
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(add[kSecAttrLabel as String] as? String, "Prosper ccpool: alpha")
        XCTAssertEqual(add[kSecValueData as String] as? Data, Data("tok-alpha".utf8))
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
        let read = AgentPoolKeychainSecrets.readQuery(id: "uuid-1")
        XCTAssertEqual(read[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(read[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertNil(read[kSecValueData as String])
        XCTAssertThrowsError(try AgentPoolKeychainSecrets.check(errSecMissingEntitlement)) {
            XCTAssertEqual($0 as? AgentPoolSecretsError, .unavailable)
        }
    }

    // Errata C4: the production constants, asserted, never dialled.
    func testAgentPoolProductionConstants() {
        XCTAssertEqual(AgentPoolService.defaultPort, 8790)
        XCTAssertEqual(AgentPoolService.productionUpstream.absoluteString, "https://api.anthropic.com")
        XCTAssertEqual(AgentPoolServiceConfig().port, AgentPoolService.defaultPort)
        XCTAssertEqual(AgentPoolServiceConfig().replayCap, 32 << 20)
    }

    // Errata C4: no AgentPool test names the production port outside the single assertion above.
    func testAgentPoolNoTestUsesTheProductionPort() throws {
        let needle = "87" + "90"
        var hits: [String] = []
        for f in ccpoolTestFiles() {
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where l.contains(needle) && !l.contains("XCTAssertEqual(AgentPoolService.defaultPort, \(needle))") {
                hits.append("\(f.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertGreaterThanOrEqual(ccpoolTestFiles().count, 3, "the guard found the AgentPool test files")
        XCTAssertEqual(hits, [])
    }

    // Errata C5: no AgentPool test reads the Python ccpool home or the Keychain.
    func testAgentPoolNoTestReadsPythonVaultOrKeychain() throws {
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

    // P2b-1: outside AgentPool/, AppDelegate owns the runtime (launch, enable/disable, quit) and
    // SettingsWindow mounts the pane. P2b-2: the island's --spawn asks the runtime for its routing
    // contributor, and the New session form for its hint (AgentPool.Routing). Nothing outside calls sessionEnv.
    // #1843: the agent-control reads register through AgentPoolControl, which builds every reply inside AgentPool/.
    func testAgentPoolNoCallSiteOutsideItsDirectory() throws {
        let symbol = try NSRegularExpression(pattern: #"\bAgentPool\w*|\bsessionEnv\b"#)
        var hits: Set<String> = []
        for f in swiftFiles(under: sourcesDir) where !f.path.contains("/AgentPool/") {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in symbol.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                hits.insert("\(f.lastPathComponent): \((text as NSString).substring(with: m.range))")
            }
        }
        XCTAssertFalse(swiftFiles(under: sourcesDir.appendingPathComponent("AgentPool")).isEmpty, "the guard found the sources")
        XCTAssertEqual(hits, ["AppDelegate.swift: AgentPoolRuntime", "SettingsWindow.swift: AgentPoolRuntime", "SettingsWindow.swift: AgentPoolPane",
                              "AgentIslandController.swift: AgentPoolRuntime", "AgentNewSession.swift: AgentPool",
                              "AgentNewSession.swift: AgentPoolRuntime", "ControlAgentPool.swift: AgentPoolControl"])
    }

    // P2b-1: under XCTest the app's runtime is never built, not even by a live push.
    @MainActor
    func testAgentPoolRuntimeNeverBuiltUnderTest() {
        XCTAssertNil(AgentPoolRuntime.shared)
        XCTAssertNil(AgentPoolRuntime.production())
        AgentPoolRuntime.setExtensionLive(false)
        AgentPoolRuntime.setExtensionLive(true)
        XCTAssertNil(AgentPoolRuntime.shared, "no store, Keychain or listener from a test run")
    }

    // P2a: the Python ccpool's path names exist once, in the one path rule (AgentPoolVaultImport.vaultURL).
    func testAgentPoolPythonPathsNamedOnce() throws {
        let files = swiftFiles(under: sourcesDir.appendingPathComponent("AgentPool"))
        let all = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        // ("state.json" is also Prosper's own store file, so it is not counted.)
        for literal in ["\"vault" + ".json\"", "\"." + "ccpool\"", "\"CCPOOL" + "_HOME\""] {
            XCTAssertEqual(all.components(separatedBy: literal).count - 1, 1, literal)
        }
    }

    // P2a: no modal UI, no global events, no pasteboard anywhere in the AgentPool sources.
    func testAgentPoolSourcesUseNoModalUIOrGlobalEvents() throws {
        let needles = ["NSAlert" + "(", "NSOpen" + "Panel", "NSMenu" + "(", "CGEvent" + "Post", "NSPaste" + "board", "runModal"]
        var hits: [String] = []
        for f in swiftFiles(under: sourcesDir.appendingPathComponent("AgentPool")) {
            let text = try String(contentsOf: f, encoding: .utf8)
            hits += needles.filter { text.contains($0) }.map { "\(f.lastPathComponent): \($0)" }
        }
        XCTAssertEqual(hits, [])
    }

    // Tests never dial the production upstream or bind the production port.
    func testAgentPoolRefusesProductionUpstreamAndPortUnderTest() {
        XCTAssertNotNil(AgentPoolService.refusalUnderTest(AgentPoolServiceConfig()))
        var cfg = AgentPoolServiceConfig()
        cfg.port = 0
        XCTAssertNotNil(AgentPoolService.refusalUnderTest(cfg), "production upstream refused")
        cfg.upstream = URL(string: "http://127.0.0.1:9")!
        XCTAssertNil(AgentPoolService.refusalUnderTest(cfg))
        cfg.port = AgentPoolService.defaultPort
        XCTAssertNotNil(AgentPoolService.refusalUnderTest(cfg), "production port refused")

        var prod = AgentPoolServiceConfig()
        prod.port = 0
        let log = AgentPoolCapturingLogger()
        let svc = AgentPoolService(config: prod, store: AgentPoolStore(directory: tempDir()), secrets: AgentPoolMemorySecrets(), logger: log)
        guard case .failed(let why) = svc.start() else { return XCTFail("started against the production upstream") }
        XCTAssertTrue(why.contains("production upstream"), why)
        svc.stop()
    }

    // N4: the usage probe never dials the production upstream under XCTest.
    func testAgentPoolUsageProbeRefusesProductionUpstreamUnderTest() async {
        XCTAssertTrue(AgentPoolService.refusesUnderTest(AgentPoolService.productionUpstream))
        XCTAssertFalse(AgentPoolService.refusesUnderTest(URL(string: "http://127.0.0.1:9")!))
        guard AgentPoolService.refusesUnderTest(AgentPoolService.productionUpstream) else { return }
        let probe = await AgentPoolUsage.probe(token: "tok-alpha", base: AgentPoolService.productionUpstream, timeout: 1)
        XCTAssertNil(probe)
    }

    // X16: a connection never holds its service unowned; a released service must not crash a request.
    func testAgentPoolNoUnownedReferences() throws {
        let files = swiftFiles(under: sourcesDir.appendingPathComponent("AgentPool"))
        XCTAssertFalse(files.isEmpty)
        let hits = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("unowned") }.map(\.lastPathComponent)
        XCTAssertEqual(hits, [])
    }

    // Loopback only: 127.0.0.1, no port sharing. #1675: SO_REUSEADDR (past TIME_WAIT), never SO_REUSEPORT (beside a live listener).
    func testAgentPoolListenerIsLoopbackOnly() throws {
        let l = try AgentPoolListener.open(port: 0).get()
        defer { l.cancel() }
        var a = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(l.fd, $0, &len) } }
        XCTAssertEqual(named, 0)
        XCTAssertEqual(Int32(a.sin_family), AF_INET)
        XCTAssertEqual(a.sin_addr.s_addr, UInt32(0x7f00_0001).bigEndian, "127.0.0.1 only")
        XCTAssertNotEqual(a.sin_port, 0)
        func opt(_ name: Int32) -> Int32 {
            var v: Int32 = -1
            var n = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(l.fd, SOL_SOCKET, name, &v, &n) == 0 ? v : -1
        }
        XCTAssertNotEqual(opt(SO_REUSEADDR), 0)
        XCTAssertEqual(opt(SO_REUSEPORT), 0, "never SO_REUSEPORT")
        XCTAssertNotEqual(opt(SO_NOSIGPIPE), 0)
        XCTAssertTrue(AgentPoolListener.isListeningTCP(l.fd), "listening (libproc; getsockopt SO_ACCEPTCONN is ENOPROTOOPT on Darwin)")
        XCTAssertNotEqual(fcntl(l.fd, F_GETFL) & O_NONBLOCK, 0)
        XCTAssertNotEqual(fcntl(l.fd, F_GETFD) & FD_CLOEXEC, 0)
        let all = try swiftFiles(under: sourcesDir.appendingPathComponent("AgentPool")).map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(all.contains("SO_REUSE" + "PORT,"), "no AgentPool source sets SO_REUSEPORT")
    }
}
