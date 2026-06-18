import XCTest
@testable import ProsperApp

final class RemoteInstallerTests: XCTestCase {

    func testParsesRepoRoot() {
        let s = RemoteInstaller.parse("https://github.com/owner/repo")
        XCTAssertEqual(s, .init(owner: "owner", repo: "repo", ref: "HEAD", subdir: ""))
    }

    func testParsesDotGitSuffix() {
        let s = RemoteInstaller.parse("https://github.com/owner/repo.git")
        XCTAssertEqual(s?.repo, "repo")
        XCTAssertEqual(s?.subdir, "")
    }

    func testParsesTreeRefAndSubdir() {
        let s = RemoteInstaller.parse("https://github.com/acme/tools/tree/main/extensions/hello")
        XCTAssertEqual(s, .init(owner: "acme", repo: "tools", ref: "main", subdir: "extensions/hello"))
    }

    func testParsesScpStyleRemote() {
        let s = RemoteInstaller.parse("git@github.com:owner/repo.git")
        XCTAssertEqual(s?.owner, "owner")
        XCTAssertEqual(s?.repo, "repo")
    }

    func testRejectsNonGitHub() {
        XCTAssertNil(RemoteInstaller.parse("https://gitlab.com/owner/repo"))
        XCTAssertNil(RemoteInstaller.parse("https://github.com/owner"))
        XCTAssertNil(RemoteInstaller.parse(""))
        XCTAssertNil(RemoteInstaller.parse("not a url"))
    }
}
