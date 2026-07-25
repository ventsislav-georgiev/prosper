import XCTest
@testable import ProsperApp

/// A dch client that outlives its Prosper keeps a pty — and a window size the master
/// then serves to everyone, because dch keeps ONE size per session and the last client
/// to report wins. So orphans get SIGHUP'd on startup. What must NEVER be hit: the
/// `--master-of` daemons (that would kill the session and everything inside it) and
/// anyone else's dch. Lines below are verbatim `ps -axo pid=,ppid=,tty=,command=`
/// output from a Mac that had 39 leaked clients.
final class DchOrphanSweepTests: XCTestCase {

    private let ps = """
    26334     1 ??         /Applications/Prosper.app/Contents/Resources/dch --master-of /tmp/dch-502/new.sock -- /bin/zsh
    56579     1 ??         dch --master-of /tmp/dch-502/solution.cdv2.sock -- headroom
    10503     1 ttys001    /Applications/Prosper.app/Contents/Resources/dch -E -f -n solution.cdv2
    25066     1 ttys003    /Applications/Prosper.app/Contents/Resources/dch -E -f -n prosper-ios
     6289  3508 ttys035    /Applications/Prosper.app/Contents/Resources/dch -E -f -n prosper-ios
    33576 33424 ttys079    dch -l
    41000     1 ttys081    dch -a mine
    """

    func testOnlyOrphanedProsperClientsAreSwept() {
        XCTAssertEqual(DchCommand.orphanedClientPIDs(ps: ps), [10503, 25066])
    }

    func testMastersAreNeverSwept() {
        let pids = DchCommand.orphanedClientPIDs(ps: ps)
        XCTAssertFalse(pids.contains(26334), "killing a master kills the session")
        XCTAssertFalse(pids.contains(56579), "killing a master kills the session")
    }

    /// A client whose Prosper is still alive is that Prosper's business — it detaches it
    /// on close. And a plain user's `dch -a` is not ours to touch.
    func testLiveChildrenAndForeignClientsAreLeftAlone() {
        let pids = DchCommand.orphanedClientPIDs(ps: ps)
        XCTAssertFalse(pids.contains(6289), "still owned by a running Prosper (ppid 3508)")
        XCTAssertFalse(pids.contains(41000), "someone else's dch -a, no -E")
        XCTAssertFalse(pids.contains(33576))
    }

    func testGarbageIsIgnored() {
        XCTAssertTrue(DchCommand.orphanedClientPIDs(ps: "").isEmpty)
        XCTAssertTrue(DchCommand.orphanedClientPIDs(ps: "nonsense\n\n1 2\n").isEmpty)
    }
}
