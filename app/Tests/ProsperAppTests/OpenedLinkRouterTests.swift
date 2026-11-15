import AppKit
import XCTest
@testable import ProsperApp

/// #721: links Prosper receives as the default browser — GURLs and opened .html
/// files (odoc, as file:// URLs) — reach the url-dispatcher as `url.open`, and are
/// never dropped when no extension handles that event. The native open is a seam:
/// nothing here opens anything.
@MainActor
final class OpenedLinkRouterTests: XCTestCase {
    /// Payload each fake listener was asked with, as "<name> <payload>", in asking order.
    private var asked: [String] = []
    private var opens: [(url: String, bundleID: String)] = []
    private let shipped: Set<String> = ["eu.illegible.prosper"]
    private struct Boom: Error {}

    /// #1070: a fake url.open listener named `name` that answers with `answer()`.
    private func listener(_ name: String, _ answer: @escaping () throws -> String?) -> OpenedLinkRouter.Listener {
        { [unowned self] payload in
            asked.append(name + " " + payload)
            return try answer()
        }
    }

    private func router(_ listeners: [OpenedLinkRouter.Listener] = [], fallback: String? = nil,
                        selfIDs: Set<String> = OpenedLinkRouter.selfBundleIDs) -> OpenedLinkRouter {
        let r = OpenedLinkRouter(
            listeners: { listeners },
            fallbackBrowser: { fallback },
            open: { [unowned self] in opens.append(($0, $1)) },
            selfIDs: selfIDs)
        r.ready()
        return r
    }

    private func names() -> [String] { asked.map { String($0.prefix(while: { $0 != " " })) } }

    private func decodedURL(_ payload: String) -> String? {
        let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String]
        return obj?["url"]
    }

    /// The odoc path: AppKit only calls application(_:open:) if the delegate has it.
    func testAppDelegateHandlesOpenedDocuments() {
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(NSApplicationDelegate.application(_:open:))))
    }

    func testOpenedFileURLIsForwardedAsURLOpen() async {
        let file = URL(fileURLWithPath: "/Users/me/Sites/my page.html").absoluteString
        await router([listener("a") { "handled" }]).receive(file)?.value
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first.map { String($0.dropFirst(2)) }.flatMap(decodedURL),
                       "file:///Users/me/Sites/my%20page.html")
        XCTAssertTrue(opens.isEmpty, "a handled link is never also opened natively")
    }

    func testNoHandlerOpensInSavedFallbackBrowser() {
        XCTAssertTrue(router(fallback: "org.mozilla.firefox").receive("file:///tmp/a.htm") == nil,
                      "no listener: opened at once, no task")
        XCTAssertTrue(asked.isEmpty)
        XCTAssertEqual(opens.map(\.url), ["file:///tmp/a.htm"])
        XCTAssertEqual(opens.map(\.bundleID), ["org.mozilla.firefox"])
    }

    func testNoHandlerAndNoFallbackOpensInSafari() {
        router(fallback: nil).receive("https://example.com")
        router(fallback: "").receive("https://example.org")
        XCTAssertEqual(opens.map(\.bundleID), ["com.apple.Safari", "com.apple.Safari"])
    }

    /// Prosper is the default browser here: opening in Prosper would bounce back forever.
    func testLoopGuardNeverOpensInProsper() {
        router(fallback: "eu.illegible.prosper", selfIDs: shipped).receive("https://example.com")
        XCTAssertEqual(opens.map(\.bundleID), ["com.apple.Safari"])
    }

    /// QA #540 INFO-2: a dev build or fork runs under another bundle id; the guard
    /// must know that id too, or the link is handed back to this very app forever.
    func testLoopGuardKnowsTheRunningBundleID() {
        router(fallback: "com.example.prosper-dev",
               selfIDs: ["com.example.prosper-dev"]).receive("https://example.com")
        XCTAssertEqual(opens.map(\.bundleID), ["com.apple.Safari"])
    }

    /// #1070: the guard is the running bundle's id; the shipped id only when the bundle has none.
    func testSelfBundleIDsAreTheRunningIDElseTheShippedOne() {
        XCTAssertEqual(OpenedLinkRouter.selfIDs(running: "com.example.prosper-dev"), ["com.example.prosper-dev"])
        XCTAssertEqual(OpenedLinkRouter.selfIDs(running: nil), ["eu.illegible.prosper"])
        XCTAssertEqual(OpenedLinkRouter.selfBundleIDs, OpenedLinkRouter.selfIDs(running: Bundle.main.bundleIdentifier))
    }

    /// #1070: a fork whose saved fallback is its own id, and whose dispatcher errors:
    /// the fallback still never goes back to the running app.
    func testLoopGuardWithANonDefaultBundleIDAfterAnError() async {
        let fork = OpenedLinkRouter.selfIDs(running: "com.example.prosper-dev")
        await router([listener("a") { throw Boom() }], fallback: "com.example.prosper-dev", selfIDs: fork)
            .receive("https://example.com")?.value
        XCTAssertEqual(opens.map(\.bundleID), ["com.apple.Safari"])
    }

    /// A cold launch by a link/file delivers it before extensions are discovered.
    func testLinksBeforeReadyAreHeldThenDeliveredInOrder() async {
        let r = OpenedLinkRouter(
            listeners: { [unowned self] in [listener("a") { "handled" }] },
            fallbackBrowser: { nil },
            open: { [unowned self] in opens.append(($0, $1)) })
        XCTAssertTrue(r.receive("file:///tmp/1.html") == nil)
        XCTAssertTrue(r.receive("https://two.test") == nil)
        XCTAssertTrue(asked.isEmpty, "nothing delivered before the extensions are loaded")
        for task in r.ready() { await task.value }
        XCTAssertEqual(asked.map { String($0.dropFirst(2)) }.compactMap(decodedURL),
                       ["file:///tmp/1.html", "https://two.test"])
        await r.receive("https://three.test")?.value
        XCTAssertEqual(asked.count, 3, "after ready, links go straight through")
        XCTAssertTrue(opens.isEmpty)
    }

    // MARK: #1070 the url.open answer: the fallback opens once unless a listener answered "handled"

    func testErroringListenerOpensTheFallbackOnce() async {
        await router([listener("a") { throw Boom() }], fallback: "org.mozilla.firefox")
            .receive("https://example.com/e")?.value
        XCTAssertEqual(names(), ["a"])
        XCTAssertEqual(opens.count, 1)
        XCTAssertEqual(opens.last?.url, "https://example.com/e")
        XCTAssertEqual(opens.last?.bundleID, "org.mozilla.firefox")
    }

    /// Returning nothing (an older extension) and any answer but "handled" both decline.
    func testDecliningListenerOpensTheFallbackOnce() async {
        await router([listener("a") { nil }], fallback: "org.mozilla.firefox").receive("https://example.com/n")?.value
        XCTAssertEqual(opens.map(\.url), ["https://example.com/n"])
        await router([listener("b") { "no" }], fallback: "org.mozilla.firefox").receive("https://example.com/s")?.value
        XCTAssertEqual(opens.map(\.url), ["https://example.com/n", "https://example.com/s"])
        XCTAssertEqual(names(), ["a", "b"])
    }

    /// Order rule: listeners are asked in list order, the second even after the first threw.
    func testFirstListenerErrorsThenTheSecondDecides() async {
        await router([listener("a") { throw Boom() }, listener("b") { "handled" }])
            .receive("https://example.com/h")?.value
        XCTAssertEqual(names(), ["a", "b"])
        XCTAssertTrue(opens.isEmpty, "the second listener handled it: no fallback")
        await router([listener("c") { throw Boom() }, listener("d") { nil }], fallback: "org.mozilla.firefox")
            .receive("https://example.com/d")?.value
        XCTAssertEqual(names(), ["a", "b", "c", "d"])
        XCTAssertEqual(opens.map(\.url), ["https://example.com/d"], "neither handled: one fallback open")
    }

    func testHandlingListenerOpensNoFallback() async {
        await router([listener("a") { "handled" }], fallback: "org.mozilla.firefox")
            .receive("https://example.com/ok")?.value
        XCTAssertEqual(names(), ["a"])
        XCTAssertTrue(opens.isEmpty)
    }

    // MARK: URLServices.openTarget — the loop guard under host.url.open and the native fallback

    private let installed = [
        "com.apple.Safari": URL(fileURLWithPath: "/Applications/Safari.app"),
        "org.mozilla.firefox": URL(fileURLWithPath: "/Applications/Firefox.app"),
    ]
    private let link = URL(string: "https://example.com")!

    /// The uninstalled fallback browser while Prosper is default: macOS's pick would be
    /// Prosper, which routes the link to the same missing browser forever.
    func testMissingBrowserWithProsperDefaultOpensInSafari() {
        for requested in ["com.google.Chrome", nil] as [String?] {
            let app = URLServices.openTarget(for: link, bundleID: requested,
                                             appFor: { self.installed[$0] },
                                             defaultAppID: { _ in "eu.illegible.prosper" },
                                             selfIDs: shipped)
            XCTAssertEqual(app, installed["com.apple.Safari"])
        }
    }

    func testMissingBrowserWithAnotherDefaultLeavesItToMacOS() {
        for requested in ["com.google.Chrome", nil] as [String?] {
            let app = URLServices.openTarget(for: link, bundleID: requested,
                                             appFor: { self.installed[$0] },
                                             defaultAppID: { _ in "org.mozilla.firefox" })
            XCTAssertNil(app, "nil = ws.open(url), macOS's own default")
        }
    }

    func testMissingBrowserWithAnotherProsperIDAsDefaultOpensInSafari() {
        let app = URLServices.openTarget(for: link, bundleID: "com.google.Chrome",
                                         appFor: { self.installed[$0] },
                                         defaultAppID: { _ in "com.example.prosper-dev" },
                                         selfIDs: ["com.example.prosper-dev"])
        XCTAssertEqual(app, installed["com.apple.Safari"])
    }

    /// QA #540 INFO-3: `open -a Prosper a.pdf` with the fallback browser gone. The
    /// file's own default app (not Prosper) is the right owner: nil = ws.open(url).
    /// An .html file whose default is Prosper still goes to Safari, never back here.
    func testMissingBrowserAndNonHTMLFileGoesToTheFileTypeDefault() {
        let pdf = URL(fileURLWithPath: "/Users/example/a.pdf")
        let html = URL(fileURLWithPath: "/Users/example/a.html")
        let defaults = [pdf: "com.apple.Preview", html: "eu.illegible.prosper"]
        let target = { (url: URL) in
            URLServices.openTarget(for: url, bundleID: "com.google.Chrome",
                                   appFor: { self.installed[$0] },
                                   defaultAppID: { defaults[$0] },
                                   selfIDs: self.shipped)
        }
        XCTAssertTrue(target(pdf) == nil, "nil = ws.open(url): the .pdf goes to its own default app")
        XCTAssertEqual(target(html), installed["com.apple.Safari"])
    }

    /// #1070 INFO-1: host.url.open naming this app's own (installed) id, as a fork's
    /// rule or fallback would, never opens in this app.
    func testRequestedSelfIDIsNeverTheTarget() {
        let fork = URL(fileURLWithPath: "/Applications/ProsperDev.app")
        let apps = installed.merging(["com.example.prosper-dev": fork]) { a, _ in a }
        let selfDefault = URLServices.openTarget(for: link, bundleID: "com.example.prosper-dev",
                                                 appFor: { apps[$0] }, defaultAppID: { _ in "com.example.prosper-dev" },
                                                 selfIDs: ["com.example.prosper-dev"])
        XCTAssertEqual(selfDefault, installed["com.apple.Safari"])
        let otherDefault = URLServices.openTarget(for: link, bundleID: "com.example.prosper-dev",
                                                  appFor: { apps[$0] }, defaultAppID: { _ in "org.mozilla.firefox" },
                                                  selfIDs: ["com.example.prosper-dev"])
        XCTAssertTrue(otherDefault == nil, "nil = ws.open(url), macOS's own default (not this app)")
    }

    func testInstalledBrowserIsUsed() {
        let app = URLServices.openTarget(for: link, bundleID: "org.mozilla.firefox",
                                         appFor: { self.installed[$0] },
                                         defaultAppID: { _ in "eu.illegible.prosper" })
        XCTAssertEqual(app, installed["org.mozilla.firefox"])
    }
}
