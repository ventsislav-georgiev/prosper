import AppKit
import XCTest
@testable import ProsperApp

/// #721: links Prosper receives as the default browser — GURLs and opened .html
/// files (odoc, as file:// URLs) — reach the url-dispatcher as `url.open`, and are
/// never dropped when no extension handles that event. The native open is a seam:
/// nothing here opens anything.
@MainActor
final class OpenedLinkRouterTests: XCTestCase {
    private var broadcasts: [String] = []
    private var opens: [(url: String, bundleID: String)] = []

    private func router(handler: Bool, fallback: String? = nil,
                        selfIDs: Set<String> = OpenedLinkRouter.selfBundleIDs) -> OpenedLinkRouter {
        let r = OpenedLinkRouter(
            hasHandler: { handler },
            broadcast: { [unowned self] in broadcasts.append($0) },
            fallbackBrowser: { fallback },
            open: { [unowned self] in opens.append(($0, $1)) },
            selfIDs: selfIDs)
        r.ready()
        return r
    }

    private func decodedURL(_ payload: String) -> String? {
        let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String]
        return obj?["url"]
    }

    /// The odoc path: AppKit only calls application(_:open:) if the delegate has it.
    func testAppDelegateHandlesOpenedDocuments() {
        XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(NSApplicationDelegate.application(_:open:))))
    }

    func testOpenedFileURLIsForwardedAsURLOpen() {
        let file = URL(fileURLWithPath: "/Users/me/Sites/my page.html").absoluteString
        router(handler: true).receive(file)
        XCTAssertEqual(broadcasts.count, 1)
        XCTAssertEqual(broadcasts.first.flatMap(decodedURL), "file:///Users/me/Sites/my%20page.html")
        XCTAssertTrue(opens.isEmpty, "a handled link is never also opened natively")
    }

    func testNoHandlerOpensInSavedFallbackBrowser() {
        router(handler: false, fallback: "org.mozilla.firefox").receive("file:///tmp/a.htm")
        XCTAssertTrue(broadcasts.isEmpty)
        XCTAssertEqual(opens.map(\.url), ["file:///tmp/a.htm"])
        XCTAssertEqual(opens.map(\.bundleID), ["org.mozilla.firefox"])
    }

    func testNoHandlerAndNoFallbackOpensInSafari() {
        router(handler: false, fallback: nil).receive("https://example.com")
        router(handler: false, fallback: "").receive("https://example.org")
        XCTAssertEqual(opens.map(\.bundleID), ["com.apple.Safari", "com.apple.Safari"])
    }

    /// Prosper is the default browser here: opening in Prosper would bounce back forever.
    func testLoopGuardNeverOpensInProsper() {
        router(handler: false, fallback: "eu.illegible.prosper").receive("https://example.com")
        XCTAssertEqual(opens.map(\.bundleID), ["com.apple.Safari"])
    }

    /// QA #540 INFO-2: a dev build or fork runs under another bundle id; the guard
    /// must know that id too, or the link is handed back to this very app forever.
    func testLoopGuardKnowsTheRunningBundleID() {
        router(handler: false, fallback: "com.example.prosper-dev",
               selfIDs: ["com.example.prosper-dev"]).receive("https://example.com")
        XCTAssertEqual(opens.map(\.bundleID), ["com.apple.Safari"])
    }

    /// The default set is the shipped id plus whatever bundle is running.
    func testSelfBundleIDsAreTheShippedAndTheRunningID() {
        XCTAssertEqual(OpenedLinkRouter.selfBundleIDs,
                       Set(["eu.illegible.prosper", Bundle.main.bundleIdentifier].compactMap { $0 }))
        XCTAssertTrue(OpenedLinkRouter.selfBundleIDs.contains("eu.illegible.prosper"))
    }

    /// A cold launch by a link/file delivers it before extensions are discovered.
    func testLinksBeforeReadyAreHeldThenDeliveredInOrder() {
        let r = OpenedLinkRouter(
            hasHandler: { true },
            broadcast: { [unowned self] in broadcasts.append($0) },
            fallbackBrowser: { nil },
            open: { [unowned self] in opens.append(($0, $1)) })
        r.receive("file:///tmp/1.html")
        r.receive("https://two.test")
        XCTAssertTrue(broadcasts.isEmpty, "nothing delivered before the extensions are loaded")
        r.ready()
        XCTAssertEqual(broadcasts.compactMap(decodedURL), ["file:///tmp/1.html", "https://two.test"])
        r.receive("https://three.test")
        XCTAssertEqual(broadcasts.count, 3, "after ready, links go straight through")
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
                                             defaultAppID: { _ in "eu.illegible.prosper" })
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
                                   defaultAppID: { defaults[$0] })
        }
        XCTAssertTrue(target(pdf) == nil, "nil = ws.open(url): the .pdf goes to its own default app")
        XCTAssertEqual(target(html), installed["com.apple.Safari"])
    }

    func testInstalledBrowserIsUsed() {
        let app = URLServices.openTarget(for: link, bundleID: "org.mozilla.firefox",
                                         appFor: { self.installed[$0] },
                                         defaultAppID: { _ in "eu.illegible.prosper" })
        XCTAssertEqual(app, installed["org.mozilla.firefox"])
    }
}
