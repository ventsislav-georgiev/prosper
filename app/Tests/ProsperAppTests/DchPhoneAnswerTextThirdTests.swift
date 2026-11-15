import Foundation
import XCTest
@testable import ProsperApp

/// #988 (third dispatch): a refused rename matches dch's "no session" line on the whole line (a long name) and on the
/// name after the host (a remote name); tailscale's own stderr line never reaches the owner check's cause.
/// Pure functions fed made-up values: no dch, no Tailscale, no socket, no process. Expectations are literals.
/// Every call is synchronous on the test's own thread (the XCTAssertThrowsError closures too).
final class DchPhoneAnswerTextThirdTests: XCTestCase {
    /// R988b-1: a 200-character name gets the no-session sentence (the name shown cut to 64 as before).
    func testALongNameStillGetsTheNoSessionSentence() {
        let name = String(repeating: "n", count: 200), shown = String(repeating: "n", count: 64) + "\u{2026}"
        XCTAssertEqual(DchCommand.renameFailure(name, err: "no session: " + name + "\n", status: 1),
                       "Couldn't rename " + shown + ": no session: " + shown)
        XCTAssertEqual(DchCommand.renameFailure(name, err: "no session: " + name + "x\n", status: 1),
                       "Couldn't rename " + shown + ": dch exited 1", "the whole line, compared exactly")
        XCTAssertEqual(DchCommand.renameFailure(name, err: "no session: " + String(repeating: "n", count: 108) + "\n", status: 1),
                       "Couldn't rename " + shown + ": dch exited 1", "a line that is the long name cut is no match")
    }

    /// R988b-2: a remote dch prints the name after the host (the first ":"); exact, never a suffix test.
    func testARemoteNameMatchesTheNameAfterTheHost() {
        XCTAssertEqual(DchCommand.renameFailure("mac2:api", err: "no session: api\n", status: 1),
                       "Couldn't rename mac2:api: no session: mac2:api")
        XCTAssertEqual(DchCommand.renameFailure("mac2:api", err: "no session: mac2:api\n", status: 1),
                       "Couldn't rename mac2:api: no session: mac2:api")
        XCTAssertEqual(DchCommand.renameFailure("mac2:api", err: "no session: other\n", status: 1),
                       "Couldn't rename mac2:api: dch exited 1")
        XCTAssertEqual(DchCommand.renameFailure("mac2:api", err: "no session: xapi\n", status: 1),
                       "Couldn't rename mac2:api: dch exited 1")
        XCTAssertEqual(DchCommand.renameFailure("mac2:api", err: "no session: mac2\n", status: 1),
                       "Couldn't rename mac2:api: dch exited 1")
        XCTAssertEqual(DchCommand.renameFailure("mac2:api:qa", err: "no session: api:qa\n", status: 1),
                       "Couldn't rename mac2:api:qa: no session: mac2:api:qa")
        XCTAssertEqual(DchCommand.renameFailure("mac2:api:qa", err: "no session: qa\n", status: 1),
                       "Couldn't rename mac2:api:qa: dch exited 1")
        XCTAssertEqual(DchCommand.renameFailure("api", err: "no session: \n", status: 1), "Couldn't rename api: dch exited 1")
    }

    /// Tailscale's stderr can carry a path, a direction mark or a control: the cause is a fixed sentence.
    func testTailscaleStderrNeverReachesTheCause() {
        let err = "failed to connect to /Users/example/ts.sock\u{202E}\u{7}\nmore\n"
        XCTAssertThrowsError(try DchOwnerCheck.host(fromStatus: TailscaleCLIOutput(exit: 1, err: err))) {
            XCTAssertEqual($0 as? WhoisUnavailable, WhoisUnavailable(cause: "Tailscale isn't answering"))
        }
        XCTAssertThrowsError(try DchOwnerCheck.peer(fromWhois: TailscaleCLIOutput(exit: 1, err: err))) {
            XCTAssertEqual($0 as? WhoisUnusable, WhoisUnusable(cause: "tailscale whois failed"))
        }
        XCTAssertEqual(DchOwnerCheck.statusText(ip: "100.64.0.1", .unavailable("Tailscale isn't answering")),
                       "Couldn't verify 100.64.0.1: Tailscale isn't answering. "
                       + "Turning on \"Allow when Tailscale isn't answering\" would let it in.")
        XCTAssertEqual(DchOwnerCheck.statusText(ip: "100.64.0.1", .unusable("tailscale whois failed")),
                       "Couldn't verify 100.64.0.1: tailscale whois failed. "
                       + "Refused; \"Allow when Tailscale isn't answering\" doesn't cover this.")
    }
}
