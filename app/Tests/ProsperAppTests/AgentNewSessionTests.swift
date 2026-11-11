import XCTest
@testable import ProsperApp

/// #847: the New session form's pure rules: the name check, the free name, the folder, the argv.
final class AgentNewSessionTests: XCTestCase {

    func testAgentNewSessionNameErrorRulesInOrder() {
        let chars = "Use letters, digits, . _ and - only"
        for bad in ["a:b", "a/b", "a b", "a\u{1}b", "é", "host:api"] {
            XCTAssertEqual(AgentNewSession.nameError(bad, taken: []), chars, bad)
        }
        XCTAssertEqual(AgentNewSession.nameError("-x", taken: []), "Can't start with - or .")
        XCTAssertEqual(AgentNewSession.nameError(".x", taken: []), "Can't start with - or .")
        XCTAssertEqual(AgentNewSession.nameError(String(repeating: "a", count: 65), taken: []), "64 characters at most")
        for id in ["m0123456789abcdef", "M0123456789ABCDEF", " m0123456789abcdef ", "mABCDEF0123456789"] {
            XCTAssertEqual(AgentNewSession.nameError(id, taken: []), "Looks like a dch session id", id)
        }
        XCTAssertEqual(AgentNewSession.nameError("Api", taken: ["api"]), "Api is taken", "case-folded: one socket on APFS")
        XCTAssertEqual(AgentNewSession.nameError("api", taken: ["API"]), "api is taken")
        for ok in ["api-2", "a.b_c", String(repeating: "a", count: 64), "m0123456789abcde", "m0123456789abcdeg",
                   "x0123456789abcdef", "", "   ", "api"] {
            XCTAssertNil(AgentNewSession.nameError(ok, taken: ["api-3"]), ok)
        }
    }

    func testAgentNewSessionAutoNameIsTheFolderFreeNameCaseFolded() {
        XCTAssertEqual(AgentNewSession.autoName(folder: "/Users/example/My Repo", taken: []), "My-Repo")
        XCTAssertEqual(AgentNewSession.autoName(folder: "/Users/example/My Repo", taken: ["my-repo"]), "My-Repo-2")
        XCTAssertEqual(AgentNewSession.autoName(folder: "/Users/example/My Repo", taken: ["my-repo", "MY-REPO-2"]), "My-Repo-3")
        let long = AgentNewSession.autoName(folder: "/x/" + String(repeating: "b", count: 100), taken: [])
        XCTAssertEqual(long.count, AgentNewSession.nameMax - 4, "room for a -N under the cap")
        XCTAssertNil(AgentNewSession.nameError(long + "-999", taken: []))
    }

    func testAgentNewSessionFreeNameFoldsCaseOnTheIslandPathToo() {
        XCTAssertEqual(AgentIsland.freeName("Proj", taken: ["proj"]), "Proj-2")
        XCTAssertEqual(AgentIsland.freeName("app", taken: ["App", "APP-2"]), "app-3")
        XCTAssertEqual(AgentIsland.newSessionArgs(folder: "/src/App", command: ["claude"], taken: ["app"]),
                       ["--spawn", "App-2", "--", "claude"])
        XCTAssertEqual(AgentIsland.newSessionArgs(folder: "/src/app", command: ["/bin/zsh", "-l"], taken: ["x"], name: "x"),
                       ["--spawn", "x", "--", "/bin/zsh", "-l"], "a given name is used as is")
    }

    func testAgentNewSessionFolderError() {
        let exists = { (p: String) in p == "/Users/example/code" }
        XCTAssertEqual(AgentNewSession.folderError("", exists: exists), "Choose a folder")
        XCTAssertEqual(AgentNewSession.folderError("/Users/example/missing", exists: exists), "No such folder")
        XCTAssertEqual(AgentNewSession.folderError("code", exists: { _ in true }), "No such folder", "relative: never")
        XCTAssertNil(AgentNewSession.folderError("/Users/example/code", exists: exists))
        // The real check: a file is not a folder.
        let dir = tempDir()
        let file = dir.appendingPathComponent("f.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertEqual(AgentNewSession.folderError(file.path, exists: AgentIsland.isFolder), "No such folder")
        XCTAssertNil(AgentNewSession.folderError(dir.path, exists: AgentIsland.isFolder))
    }

    func testAgentNewSessionExpandAndAbbreviate() {
        let home = "/Users/example"
        XCTAssertEqual(AgentNewSession.expand("~", home: home), home)
        XCTAssertEqual(AgentNewSession.expand("~/x", home: home), "/Users/example/x")
        XCTAssertEqual(AgentNewSession.expand(" ~/x ", home: home), "/Users/example/x")
        XCTAssertEqual(AgentNewSession.expand("/abs", home: home), "/abs")
        XCTAssertEqual(AgentNewSession.expand("x~", home: home), "x~")
        XCTAssertEqual(AgentNewSession.expand("~other", home: home), "~other")
        XCTAssertEqual(AgentNewSession.abbreviate(home, home: home), "~")
        XCTAssertEqual(AgentNewSession.abbreviate("/Users/example/x", home: home), "~/x")
        XCTAssertEqual(AgentNewSession.abbreviate("/Users/examplex", home: home), "/Users/examplex")
    }

    func testAgentNewSessionArgvAndLoginShell() {
        XCTAssertEqual(AgentNewSession.argv("claude --chrome 'my x'", shell: "/bin/fish"), ["claude", "--chrome", "my x"])
        XCTAssertEqual(AgentNewSession.argv("", shell: "/bin/fish"), ["/bin/fish", "-l"])
        XCTAssertEqual(AgentNewSession.argv("   ", shell: "/bin/fish"), ["/bin/fish", "-l"])
        XCTAssertEqual(AgentNewSession.argv("", shell: nil), ["/bin/zsh", "-l"])
        XCTAssertEqual(AgentNewSession.argv("", shell: "fish"), ["/bin/zsh", "-l"], "a relative $SHELL: zsh")
    }

    func testAgentNewSessionRecentsLastFirstDedupedCappedExisting() {
        func rec(_ n: String, _ cwd: String) -> DchHistoryRecord {
            var r = DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: n))
            r.agent = .init(kind: "claude", cwd: cwd, launch: ["claude"])
            return r
        }
        let history = ["/a", "/b", "/gone", "/a", "/c", "/d", "/e", "/f", "/g", "/h", "/i"].enumerated().map { rec("r\($0)", $1) }
        let exists = { (p: String) in p != "/gone" && p != "/old" }
        XCTAssertEqual(AgentNewSession.recents(last: "/c", history: history, exists: exists),
                       ["/c", "/a", "/b", "/d", "/e", "/f", "/g", "/h"])
        XCTAssertEqual(AgentNewSession.recents(last: "/old", history: Array(history.prefix(3)), exists: exists), ["/a", "/b"],
                       "a last folder that went is dropped")
        XCTAssertEqual(AgentNewSession.recents(last: nil, history: [], exists: exists), [])
    }
}
