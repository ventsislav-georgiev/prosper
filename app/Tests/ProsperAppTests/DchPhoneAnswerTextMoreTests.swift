import Foundation
import Network
import XCTest
@testable import ProsperApp

/// #988 (second dispatch): a refused rename answers the phone with a sentence of ours, never dch's own line; the owner
/// check and the listener put a fixed sentence in the Settings status line, never an error's description.
/// No dch, no Tailscale, no socket: each site's pure function or seam is fed made-up values. Expectations are literals.
/// Closures: the whois fake runs on a global queue (DchOwnerCheck.check), the verdict callback there too.
final class DchPhoneAnswerTextMoreTests: XCTestCase {
    /// An error whose description holds a made-up path.
    private struct LeakyError: Error, CustomStringConvertible {
        var description: String { "cannot open /Users/example/x: Permission denied" }
    }

    func testDchsOwnRenameRefusalsKeepASentenceOfOurs() {
        XCTAssertEqual(DchCommand.renameFailure("a", err: "no session: a\nsecond\n", status: 1),
                       "Couldn't rename a: no session: a")
        XCTAssertEqual(DchCommand.renameFailure("a", err: "dch: name looks like a session_id\n", status: 2),
                       "Couldn't rename a: the new name looks like a session id")
        let long = String(repeating: "x", count: 70), cut = String(repeating: "x", count: 64) + "\u{2026}"
        XCTAssertEqual(DchCommand.renameFailure(long, err: "no session: " + long + "\n", status: 1),
                       "Couldn't rename " + cut + ": no session: " + cut)
    }

    func testAnyOtherDchLineGivesOnlyTheExitStatus() {
        for err in ["dch: cannot open /Users/example/x: Permission denied\n",
                    "\u{202E}no session: a\u{7}\n",
                    "no session: a\u{1B}[31m",
                    "dch: no session a on example-host\n",
                    "no session: b\n",
                    "dch exited 0\n",
                    String(repeating: "/Users/example/", count: 100)] {
            let got = DchCommand.renameFailure("a", err: err, status: 1)
            XCTAssertEqual(got, "Couldn't rename a: dch exited 1", err)
            for leak in ["/Users/example", "\u{202E}", "\u{7}", "\u{1B}", "example-host"] {
                XCTAssertFalse(got.contains(leak), "\(err) leaked \(leak)")
            }
        }
        XCTAssertEqual(DchCommand.renameFailure("a", err: "", status: 3), "Couldn't rename a: dch exited 3")
        XCTAssertEqual(DchCommand.renameFailure("a", err: "/Users/example/x\n", status: -1), "Couldn't rename a: dch could not be run")
    }

    func testAnUnforeseenOwnerCheckErrorGivesTheFixedCause() {
        let check = DchOwnerCheck(whois: { _, _ in throw LeakyError() }, allowWhenDown: { false },
                                  isLocalAddress: { _ in false }, timeout: 2)
        final class Box: @unchecked Sendable { var v: DchOwnerCheck.Verdict? }
        let box = Box(), e = expectation(description: "verdict")
        check.check("100.64.0.1") { box.v = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertTrue(box.v == .unusable("Tailscale's answer couldn't be checked"), "\(String(describing: box.v))")
        let text = box.v.flatMap { DchOwnerCheck.statusText(ip: "100.64.0.1", $0) } ?? ""
        XCTAssertEqual(text, "Couldn't verify 100.64.0.1: Tailscale's answer couldn't be checked. "
                       + "Refused; \"Allow when Tailscale isn't answering\" doesn't cover this.")
        XCTAssertFalse(text.contains("/Users/example"))
        XCTAssertFalse(text.contains("Permission denied"))
    }

    func testAListenerFailureShowsThePortAndTheCodeOnly() {
        let posix = DchSessionServer.bindStatusText(.posix(.EADDRNOTAVAIL), port: 8771)
        XCTAssertEqual(posix, "Remote Terminal couldn't listen on port 8771 (error 49). It keeps retrying.")
        XCTAssertFalse(posix.contains("assign"), "no description text")
        XCTAssertEqual(DchSessionServer.bindStatusText(.posix(.EACCES), port: 8771),
                       "Remote Terminal couldn't listen on port 8771 (error 13). It keeps retrying.")
        for e in [NWError.dns(-65537), NWError.tls(-9800)] {
            XCTAssertEqual(DchSessionServer.bindStatusText(e, port: 8771),
                           "Remote Terminal couldn't listen on port 8771. It keeps retrying.")
        }
        // Unchanged neighbours.
        XCTAssertEqual(DchSessionServer.bindStatusText(.posix(.EADDRINUSE), port: 8771),
                       "Port 8771 on your Tailscale address is in use (dch serve?). Remote Terminal keeps retrying.")
    }
}
