import XCTest

/// #1026 / #1557 (QA #671 INFO-5): the one place a test pins zsh to a ZDOTDIR and HOME it made,
/// so the real ~/.zshenv and ~/.zprofile never run in a test.
extension XCTestCase {
    /// Writes a test .zshenv (exports PROSPER_TEST_ZSHENV) and .zprofile (PROSPER_TEST_ZPROFILE)
    /// into a fresh tempDir and returns our environment with ZDOTDIR and HOME pointing at it.
    func zshTestEnvironment() throws -> (dir: URL, environment: [String: String]) {
        let dir = tempDir("zdotdir")
        try "export PROSPER_TEST_ZSHENV=test-zshenv\n"
            .write(to: dir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try "export PROSPER_TEST_ZPROFILE=test-zprofile\n"
            .write(to: dir.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["ZDOTDIR"] = dir.path
        env["HOME"] = dir.path
        return (dir, env)
    }
}
