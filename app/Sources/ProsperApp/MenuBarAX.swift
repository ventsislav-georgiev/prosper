import AppKit
import ApplicationServices

/// Which menu-bar model this macOS runs. Decided once from the major version.
///
/// - `.windows` (≤ macOS 26): every status item is a window its app owns. CGS lists
///   them (`MenuBarBridge`), and a divider wider than the screen pushes everything
///   left of it off-screen — that is how hiding works there.
/// - `.hosted` (≥ macOS 27): `MenuBarAgent` hosts every item as a remote scene. Items
///   are no longer windows (CGS sees one "Menubar" window) and never leave the room
///   right of the notch (or of the app's menus): what doesn't fit moves, leftmost
///   first, into an OS overflow group behind a « button, and an item wider than the
///   whole room is dropped outright. Hiding therefore sizes the divider to the free
///   room (see `MenuBarManager.fit`) so the OS overflows everything left of it, and
///   enumeration goes through Accessibility (`MenuBarAX`).
enum MenuBarHost {
    static let isHosted = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
}

/// Accessibility view of the hosted (macOS 27+) menu bar. Two sources:
///  - `MenuBarAgent`'s own AX tree: the host's REAL layout — one wrapper per item it
///    placed, left→right, with the owning pid on the wrapper's child. Items in the
///    overflow group (or dropped) are simply absent.
///  - each app's `AXExtrasMenuBar`: every item the app *has*, overflowed ones
///    included. Their frames are the app-side approximation: exact while laid out,
///    stale (last laid-out position) while overflowed.
@MainActor
enum MenuBarAX {
    static let identifierPrefix = "eu.illegible.prosper.menubar."

    struct Laid {
        var frame: CGRect
        var pid: pid_t
        var identifier: String?
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static var agentPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
            .first?.processIdentifier
    }

    // MARK: - Host layout

    /// Every item MenuBarAgent currently lays out, left→right. Absent = overflowed/dropped.
    static func layout() -> [Laid] {
        guard trusted, let agent = agentPID else { return [] }
        let root = AXUIElementCreateApplication(agent)
        let screenW = NSScreen.main?.frame.width ?? 4000
        var found: [Laid] = []
        func visit(_ e: AXUIElement, depth: Int) {
            guard depth <= 3 else { return }
            if let f = frame(of: e), f.minY < 2, (20...48).contains(f.height), f.width < screenW / 2 {
                let child = children(of: e).first
                let ownerPID = child.map(pid) ?? agent
                found.append(Laid(frame: f, pid: ownerPID == 0 ? agent : ownerPID,
                                  identifier: child.flatMap(identifier(of:))))
                return
            }
            for c in children(of: e) { visit(c, depth: depth + 1) }
        }
        for c in children(of: root) { visit(c, depth: 1) }
        // The agent nests containers (Apple's item group, the overflow region) around
        // real items; drop anything that strictly contains another hit.
        let items = found.filter { a in
            !found.contains { b in a.frame != b.frame && a.frame.contains(b.frame) }
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// True host frame of one of our own chrome items (chevron / divider), or nil when
    /// the host didn't lay it out (overflowed or dropped).
    static func laidFrame(identifier id: String, nearMinX x: CGFloat? = nil) -> CGRect? {
        let mine = layout().filter { $0.pid == getpid() }
        return mine.first { $0.identifier == id }?.frame
            ?? x.flatMap { x in mine.first { abs($0.frame.minX - x) < 3 }?.frame }
    }

    /// Right edge of the frontmost app's menu titles — the status-item region can't
    /// start left of this. nil when AX can't read it (no permission) or when the
    /// frontmost app is an accessory (Spotlight, menu-bar apps, Prosper's own Settings):
    /// those own no menu bar, the previous app's titles stay up, so the caller keeps
    /// its last measurement.
    static func appMenuRight() -> CGFloat? {
        guard trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = attribute(ax, kAXMenuBarAttribute) else { return nil }
        let right = children(of: bar as! AXUIElement).compactMap { frame(of: $0)?.maxX }.max()
        return right.map { $0 > 0 ? $0 : nil } ?? nil
    }

    /// Left edge of the room the host may fill with status items on `screen`. A notch
    /// splits the bar: items never cross it, so the room starts at the notch's right
    /// edge (`auxiliaryTopRightArea`) no matter how narrow the app's menus are. Without
    /// a notch the frontmost app's menu titles bound it.
    static func regionLeft(on screen: NSScreen?) -> CGFloat? {
        if let notch = (screen ?? NSScreen.main)?.auxiliaryTopRightArea { return notch.minX }
        // ponytail: the pad past the menu titles is unmeasured (no notch-less display at
        // hand); raise it if fills there end up in the overflow group.
        return appMenuRight().map { $0 + 40 }
    }

    // MARK: - Items

    /// Hosted-mode replacement for the CGS enumeration: every status item on `display`
    /// from every app (Apple's, hosted by the agent, included), left→right. Frames are
    /// the host's where the item is laid out, the app's stale frame otherwise
    /// (`isLaidOut` tells which). Our own chrome (chevron, dividers) is filtered out;
    /// our own content items (Stats, extensions) are flagged `isOwn`.
    static func items(onDisplay display: CGDirectDisplayID) -> [MenuBarItem] {
        guard trusted, let agent = agentPID else { return [] }
        let laid = layout()
        let me = getpid()
        let controlX = ProsperStatusItems.controlMinX()
        var out: [MenuBarItem] = []
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            for (index, e) in extras(of: pid).enumerated() {
                if pid == agent, e.role == kAXButtonRole as String { continue }   // the OS overflow « button
                if pid == me {
                    if e.identifier?.hasPrefix(identifierPrefix) == true { continue }
                    if controlX.contains(where: { abs($0 - e.frame.minX) < 2 }) { continue }
                }
                let hit = laid.first { $0.pid == pid && abs($0.frame.minX - e.frame.minX) < 3 }
                let frame = hit?.frame ?? e.frame
                guard hit == nil || MenuBarBridge.displayID(for: frame) == display else { continue }
                let own = pid == me
                out.append(MenuBarItem(windowID: key(pid: pid, index: index), pid: pid, frame: frame,
                                       bundleID: own ? "com.prosper" : app.bundleIdentifier,
                                       displayID: display,
                                       title: own ? ProsperStatusItems.content(nearMinX: e.frame.minX)?.name : e.title,
                                       isOwn: own, isLaidOut: hit != nil))
            }
        }
        return out.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Stable stand-in for a window id (the preview keys captures by it): an app's
    /// extras keep creation order, so pid + ordinal identifies an item across reads.
    static func key(pid: pid_t, index: Int) -> CGWindowID {
        CGWindowID(truncatingIfNeeded: UInt32(bitPattern: pid) &* 64 &+ UInt32(index))
    }

    struct Extra {
        var frame: CGRect
        var role: String
        var title: String?
        var identifier: String?
    }

    /// `AXExtrasMenuBar` children of one app (nothing for apps without status items).
    static func extras(of pid: pid_t) -> [Extra] {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.25)   // a hung app must not stall the whole enumeration (default 6s)
        guard let bar = attribute(ax, kAXExtrasMenuBarAttribute) else { return [] }
        return children(of: bar as! AXUIElement).compactMap { e in
            guard let f = frame(of: e), f.width > 0 else { return nil }
            let title = (attribute(e, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Extra(frame: f, role: attribute(e, kAXRoleAttribute) as? String ?? "",
                         title: title, identifier: identifier(of: e))
        }
    }

    // MARK: - AX plumbing

    private static func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func children(of e: AXUIElement) -> [AXUIElement] {
        (attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func pid(_ e: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(e, &p)
        return p
    }

    /// AXIdentifier of the element, or of its first child (the hosting wrapper sits
    /// one level above the button that carries our identifier).
    private static func identifier(of e: AXUIElement) -> String? {
        if let id = attribute(e, kAXIdentifierAttribute) as? String, !id.isEmpty { return id }
        if let c = children(of: e).first, let id = attribute(c, kAXIdentifierAttribute) as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    /// Top-left-origin screen frame (same space as CGWindow bounds).
    private static func frame(of e: AXUIElement) -> CGRect? {
        guard let p = attribute(e, kAXPositionAttribute), let s = attribute(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else {
            return nil
        }
        return CGRect(origin: pt, size: sz)
    }
}
