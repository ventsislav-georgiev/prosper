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
                       ["--spawn", "App-2", "--", "claude", "--name", "App-2"])
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

    // MARK: P1c Named Claude (OQ-68)

    /// T1, T2: `--name` right after the claude token, a wrapper's prefix kept.
    func testAgentNewSessionNamingInsertsAfterTheClaudeToken() {
        XCTAssertEqual(AgentIsland.naming(["claude"], name: "api"), ["claude", "--name", "api"])
        XCTAssertEqual(AgentIsland.naming(["headroom", "wrap", "claude", "--chrome"], name: "api"),
                       ["headroom", "wrap", "claude", "--name", "api", "--chrome"])
        XCTAssertEqual(AgentIsland.naming(["/opt/homebrew/bin/claude", "--model", "opus"], name: "api"),
                       ["/opt/homebrew/bin/claude", "--name", "api", "--model", "opus"], "the token by basename")
    }

    /// T3: the user's own name is replaced, never doubled.
    func testAgentNewSessionNamingReplacesTheUsersName() {
        for typed in [["claude", "-n", "old"], ["claude", "--name", "old"], ["claude", "--name=old"], ["claude", "-nold"],
                      ["claude", "--chrome", "-n", "old", "--model", "opus"]] {
            let got = AgentIsland.naming(typed, name: "api")
            XCTAssertEqual(got.filter { $0 == "--name" || $0 == "-n" || $0.hasPrefix("--name=") || $0.hasPrefix("-n") }, ["--name"],
                           "\(typed): one name")
            XCTAssertFalse(got.contains("old"), "\(typed): the old name is gone")
            XCTAssertEqual(Array(got.prefix(3)), ["claude", "--name", "api"])
        }
        XCTAssertEqual(AgentIsland.naming(["claude", "--chrome", "-n", "old", "--model", "opus"], name: "api"),
                       ["claude", "--name", "api", "--chrome", "--model", "opus"])
    }

    /// T4: after a bare "--" nothing is the user's name; --name goes before it.
    func testAgentNewSessionNamingLeavesWhatFollowsABareDashDash() {
        XCTAssertEqual(AgentIsland.naming(["claude", "--", "-n", "x"], name: "api"), ["claude", "--name", "api", "--", "-n", "x"])
        XCTAssertEqual(AgentIsland.strippingName(["claude", "-n", "a", "--", "--name", "b"]), ["claude", "--", "--name", "b"])
    }

    /// T5: a shell, another agent, a batch run, a subcommand, a basename that is not claude: untouched.
    func testAgentNewSessionNamingLeavesAnythingElse() {
        for argv in [["/bin/zsh", "-l"], ["node", "x.js"], ["claude", "-p", "hi"], ["claude", "--print", "hi"], ["claude", "mcp", "list"],
                     ["claude", "update"], ["/opt/x/claude-wrapper"], ["codex", "--name", "x"], ["claude", "-p", "-n", "x"], []] {
            XCTAssertEqual(AgentIsland.naming(argv, name: "api"), argv, "\(argv)")
            XCTAssertEqual(AgentIsland.strippingName(argv), argv, "\(argv)")
        }
        XCTAssertFalse(AgentIsland.isInteractiveClaude(["claude", "-p", "hi"]))
        XCTAssertTrue(AgentIsland.isInteractiveClaude(["claude", "--", "-p"]), "-p after -- is the prompt's")
        XCTAssertTrue(AgentIsland.isInteractiveClaude(["claude", "--chrome", "update"]), "only the word right after the token")
        XCTAssertEqual(AgentIsland.naming(["claude", "--", "-p"], name: "api"), ["claude", "--name", "api", "--", "-p"])
    }

    /// r2 (supervisor read): another option's value is never taken for a name, -n/--name still go, and a
    /// cluster's n loses its value but keeps its flags.
    func testAgentNewSessionStrippingNameReadsOptionValues() {
        for argv in [["claude", "--append-system-prompt", "-no emojis"], ["claude", "--model", "-n"], ["claude", "--agent", "--name"],
                     ["claude", "--system-prompt", "--name=x", "--chrome"], ["claude", "-r", "sid", "-c"]] {
            XCTAssertEqual(AgentIsland.strippingName(argv), argv, "\(argv): every word kept")
            XCTAssertEqual(AgentIsland.naming(argv, name: "api"), ["claude", "--name", "api"] + argv.dropFirst(), "\(argv): one --name")
        }
        XCTAssertEqual(AgentIsland.strippingName(["claude", "-n", "old", "--model", "x"]), ["claude", "--model", "x"])
        XCTAssertEqual(AgentIsland.strippingName(["claude", "-n", "--chrome", "--model", "x"]), ["claude", "--model", "x"],
                       "-n takes the next token whatever it is")
        XCTAssertEqual(AgentIsland.strippingName(["claude", "-cn", "old", "--chrome"]), ["claude", "-c", "--chrome"])
        XCTAssertEqual(AgentIsland.strippingName(["claude", "-cnold", "x"]), ["claude", "-c", "x"])
        XCTAssertEqual(AgentIsland.strippingName(["claude", "-cp"]), ["claude", "-cp"], "-p: a batch run, never touched")
        XCTAssertEqual(AgentIsland.strippingName(["claude", "-cv", "--add-dir", "/a", "-n", "x"]), ["claude", "-cv", "--add-dir", "/a"])
        XCTAssertEqual(AgentIsland.naming(["claude", "-cn", "old"], name: "api"), ["claude", "--name", "api", "-c"])
    }

    /// An optional-value ("o") option takes a bare next word and leaves a dashed one alone (cargv.c:236-240), so a
    /// -n/--name after `--resume` is still the user's name, and a -p after it is still print mode.
    func testAgentNewSessionOptionalValueLeavesADashedNextAlone() {
        for o in ["--resume", "-r", "--debug", "-d", "--worktree", "-w", "--from-pr", "--teleport"] {
            for batch in [["claude", o, "-p", "task"], ["claude", o, "--print", "task"]] {
                XCTAssertEqual(AgentIsland.naming(batch, name: "api"), batch, "\(batch): print mode, no name")
            }
            XCTAssertEqual(AgentIsland.strippingName(["claude", o, "-n", "old", "task"]), ["claude", o, "task"], "\(o) -n old")
            XCTAssertEqual(AgentIsland.naming(["claude", o, "--name", "old", "task"], name: "api"), ["claude", "--name", "api", o, "task"],
                           "\(o) --name old: replaced, never doubled")
            XCTAssertEqual(AgentIsland.strippingName(["claude", o, "sid", "-n", "old"]), ["claude", o, "sid"], "\(o) takes a bare value")
        }
    }

    /// The spec's any-token rule, pinned (the shortcut on isInteractiveClaude): a `claude` word that is another
    /// command's argument still gets --name after it. Deliberate: a wrapper must be named, and a spawn has no
    /// "agent seen" signal.
    func testAgentNewSessionNamingAnyClaudeWordIsTheToken() {
        XCTAssertEqual(AgentIsland.naming(["vim", "/Users/example/claude", "notes"], name: "api"),
                       ["vim", "/Users/example/claude", "--name", "api", "notes"])
    }

    /// T6: the spawn argv carries the final name; a quick shell does not.
    func testAgentNewSessionArgsNameTheClaude() {
        XCTAssertEqual(AgentIsland.newSessionArgs(folder: "/Users/example/api", command: ["claude"], taken: []),
                       ["--spawn", "api", "--", "claude", "--name", "api"])
        XCTAssertEqual(AgentIsland.newSessionArgs(folder: "/Users/example/api", command: ["claude", "-n", "old"], taken: ["api"]),
                       ["--spawn", "api-2", "--", "claude", "--name", "api-2"], "the free name, the typed one replaced")
        XCTAssertEqual(AgentIsland.newSessionArgs(folder: "/Users/example/api", command: ["claude"], taken: [], name: "mine"),
                       ["--spawn", "mine", "--", "claude", "--name", "mine"])
    }
}
