import AppKit
import XCTest
@testable import ProsperApp

/// `FrontmostApp` — the cache that keeps `host.apps.frontmost()` off LaunchServices.
///
/// A Lua eventtap calls that host API on every keystroke from inside the CGEventTap
/// callback, and `NSRunningApplication.localizedName` is a synchronous XPC there.
/// These tests pin the two properties that make caching safe: a read never repeats
/// the expensive lookup, and an app activation replaces the cached identity with the
/// activating app's — so `app.frontmost()` stays correct across app switches.
@MainActor
final class FrontmostAppCacheTests: XCTestCase {

    /// Stands in for the `NSWorkspace.frontmostApplication` read, counting how often
    /// the expensive path is actually taken.
    @MainActor
    private final class Source {
        var reads = 0
        var next: FrontmostApp.Identity?
        init(_ next: FrontmostApp.Identity?) { self.next = next }
        func read() -> FrontmostApp.Identity? { reads += 1; return next }
    }

    private let stale = FrontmostApp.Identity(name: "stale", bundleID: "com.prosper.stale", pid: -1)

    // MARK: - Populate on first read, memory hit afterwards

    func testFirstReadPopulatesAndLaterReadsAreCached() {
        let app = FrontmostApp.Identity(name: "Safari", bundleID: "com.apple.Safari", pid: 42)
        let src = Source(app)
        let cache = FrontmostApp(center: NotificationCenter(), read: { src.read() })

        XCTAssertEqual(cache.current, app)
        XCTAssertEqual(cache.current, app)
        XCTAssertEqual(cache.current, app)
        XCTAssertEqual(src.reads, 1, "only the first read may hit LaunchServices")
    }

    /// No frontmost app is a transient answer, not a cacheable one — caching nil
    /// would strand `{}` forever if the first call landed in that window.
    func testNilReadIsNotCached() {
        let src = Source(nil)
        let cache = FrontmostApp(center: NotificationCenter(), read: { src.read() })

        XCTAssertNil(cache.current)
        let app = FrontmostApp.Identity(name: "Ghostty", bundleID: "com.mitchellh.ghostty", pid: 7)
        src.next = app
        XCTAssertEqual(cache.current, app)
        XCTAssertEqual(src.reads, 2)
    }

    // MARK: - Invalidation

    func testActivationNotificationReplacesCachedIdentity() {
        let center = NotificationCenter()
        let src = Source(stale)
        let cache = FrontmostApp(center: center, read: { src.read() })
        XCTAssertEqual(cache.current, stale)

        // The real notification's payload: the app that just became frontmost. Using
        // this process's own NSRunningApplication keeps the test headless.
        let activated = NSRunningApplication.current
        let expected = FrontmostApp.Identity(activated)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: activated])

        // The observer is queued on the main queue; drain it before asserting.
        let deadline = Date().addingTimeInterval(2)
        while cache.current != expected, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertEqual(cache.current, expected, "activation must refresh the cache")
        XCTAssertNotEqual(cache.current, stale, "the pre-activation identity must be gone")
        XCTAssertEqual(cache.current?.pid, Int(activated.processIdentifier))
        XCTAssertEqual(cache.current?.name, activated.localizedName ?? "")
        XCTAssertEqual(cache.current?.bundleID, activated.bundleIdentifier ?? "")
        XCTAssertEqual(src.reads, 1, "a refreshed cache must not fall back to the slow read")
    }

    /// A malformed activation (no app in the userInfo) must leave the cache alone
    /// rather than blank it.
    func testActivationWithoutAppKeepsCache() {
        let center = NotificationCenter()
        let cache = FrontmostApp(center: center, read: { self.stale })
        XCTAssertEqual(cache.current, stale)

        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(cache.current, stale)
    }

    // MARK: - Lua-visible shape (`host.apps.frontmost()`)

    func testFrontmostJSONShapeUnchanged() throws {
        let raw = AppControl.frontmostJSON()
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])

        // Headless CI can legitimately have no frontmost app -> "{}".
        try XCTSkipIf(obj.isEmpty, "no frontmost application in this environment")

        XCTAssertEqual(Set(obj.keys), ["name", "bundleID", "pid"])
        XCTAssertTrue(obj["name"] is String)
        XCTAssertTrue(obj["bundleID"] is String)
        let pid = try XCTUnwrap(obj["pid"] as? Int)
        XCTAssertEqual(pid, FrontmostApp.shared.current?.pid)
        XCTAssertEqual(obj["name"] as? String, FrontmostApp.shared.current?.name)
        XCTAssertEqual(obj["bundleID"] as? String, FrontmostApp.shared.current?.bundleID)
    }
}
