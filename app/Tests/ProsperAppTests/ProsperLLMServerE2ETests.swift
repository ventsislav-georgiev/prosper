import XCTest
@testable import ProsperApp

/// End-to-end test of `ProsperLLMServer` over a real loopback socket — the seam
/// between the Codex harness and the in-process MLX engine. Exercises the HTTP/1.1
/// transport, bearer auth, and the unauthenticated liveness route WITHOUT loading
/// a model (so it runs in CI): `/health` and `/v1/models` need no inference.
final class ProsperLLMServerE2ETests: XCTestCase {

    private func get(_ url: String, token: String?) async throws -> (status: Int, body: String) {
        var req = URLRequest(url: URL(string: url)!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 5
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return (code, String(data: data, encoding: .utf8) ?? "")
    }

    func testServerBootsHealthAndAuth() async throws {
        let (port, token) = try ProsperLLMServer.shared.start()
        defer { ProsperLLMServer.shared.stop() }
        XCTAssertGreaterThan(port, 0)
        XCTAssertFalse(token.isEmpty)
        let base = "http://127.0.0.1:\(port)"

        // /health is unauthenticated liveness.
        let health = try await get("\(base)/health", token: nil)
        XCTAssertEqual(health.status, 200)
        XCTAssertTrue(health.body.contains("ok"), "health body: \(health.body)")

        // /v1/models requires the bearer token.
        let unauth = try await get("\(base)/v1/models", token: nil)
        XCTAssertEqual(unauth.status, 401, "missing token must be rejected")

        let wrong = try await get("\(base)/v1/models", token: "not-the-token")
        XCTAssertEqual(wrong.status, 401, "wrong token must be rejected")

        // With the minted token, /v1/models advertises the resident agent model.
        let ok = try await get("\(base)/v1/models", token: token)
        XCTAssertEqual(ok.status, 200)
        // JSONSerialization escapes "/" as "\/"; un-escape before comparing.
        let body = ok.body.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(body.contains(Preferences.agentModel),
                      "models body should advertise \(Preferences.agentModel); got \(ok.body)")
    }

    func testStartIsIdempotent() throws {
        let first = try ProsperLLMServer.shared.start()
        defer { ProsperLLMServer.shared.stop() }
        let second = try ProsperLLMServer.shared.start()
        XCTAssertEqual(first.port, second.port, "start() must reuse the bound port")
        XCTAssertEqual(first.token, second.token, "start() must reuse the minted token")
    }
}
