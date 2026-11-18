import Foundation
import XCTest

extension XCTestCase {
    /// Sets one process environment variable for the rest of this test; its teardown puts back what was there.
    /// The replaced value never reaches the caller (#1588: CCPoolGuardTests keeps the real environment out of CCPool tests).
    func overrideProcessEnv(_ name: String, _ value: String) {
        let saved = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        addTeardownBlock { if let saved { setenv(name, saved, 1) } else { unsetenv(name) } }
    }
}
