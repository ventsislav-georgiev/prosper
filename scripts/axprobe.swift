// Standalone AX probe: focus a text field (e.g. Slack composer), run this, and it
// dumps every caret-geometry query Prosper relies on, every 2 s. Build & run:
//   swiftc -O scripts/axprobe.swift -o /tmp/axprobe && /tmp/axprobe
// Grant Accessibility to the resulting binary when macOS prompts.
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IONBF, 0) // unbuffered: output must stream through pipes

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var out: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &out)
    if err != .success { print("    \(name): ERR \(err.rawValue)"); return nil }
    return out
}
func param(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
    var out: CFTypeRef?
    let err = AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &out)
    if err != .success { print("    \(name): ERR \(err.rawValue)"); return nil }
    return out
}
func rect(_ v: CFTypeRef?) -> CGRect? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let ax = v as! AXValue
    guard AXValueGetType(ax) == .cgRect else { return nil }
    var r = CGRect.zero
    return AXValueGetValue(ax, .cgRect, &r) ? r : nil
}
func str(_ v: CFTypeRef?) -> String? {
    guard let v, CFGetTypeID(v) == CFStringGetTypeID() else { return nil }
    return (v as! CFString) as String
}

func markerBounds(_ el: AXUIElement, label: String) {
    print("  -- marker queries on \(label) --")
    guard let sel = attr(el, "AXSelectedTextMarkerRange") else {
        print("    AXSelectedTextMarkerRange: nil"); return
    }
    print("    AXSelectedTextMarkerRange: ok")
    let selBounds = rect(param(el, "AXBoundsForTextMarkerRange", sel))
    print("    bounds(selRange): \(selBounds.map(String.init(describing:)) ?? "nil")")
    // WebKit answers AXStartTextMarkerForTextMarkerRange; Chromium doesn't
    // (-25212) but supports AXTextMarkerForPosition — recover the caret marker
    // from the caret rect's screen position instead.
    var caretStart = param(el, "AXStartTextMarkerForTextMarkerRange", sel)
    if caretStart == nil {
        print("    AXStartTextMarkerForTextMarkerRange: nil — trying AXTextMarkerForPosition")
        if let b = selBounds {
            var pt = CGPoint(x: b.midX, y: b.midY)
            if let pv = AXValueCreate(.cgPoint, &pt) {
                caretStart = param(el, "AXTextMarkerForPosition", pv)
            }
        }
    }
    guard let caretStart else { print("    caret marker: unavailable"); return }
    print("    caretStart marker: ok")
    if let prev = param(el, "AXPreviousTextMarkerForTextMarker", caretStart) {
        print("    prev marker: ok")
        if let range = param(el, "AXTextMarkerRangeForUnorderedTextMarkers", [prev, caretStart] as CFArray) {
            print("    unordered range(prev, caretStart): ok")
            let b = rect(param(el, "AXBoundsForTextMarkerRange", range))
            print("    bounds(prevChar): \(b.map(String.init(describing:)) ?? "nil")")
            let s = str(param(el, "AXStringForTextMarkerRange", range))
            print("    string(prevChar): \(s.map { "\"\($0)\"" } ?? "nil")")
        }
    }
    // Line-based fallbacks some Chromium builds support:
    for name in ["AXLineTextMarkerRangeForTextMarker", "AXLeftLineTextMarkerRangeForTextMarker"] {
        if let lr = param(el, name, caretStart) {
            let b = rect(param(el, "AXBoundsForTextMarkerRange", lr))
            print("    bounds(\(name)): \(b.map(String.init(describing:)) ?? "nil")")
        }
    }
    // TextMarker → index/bounds round-trip:
    if let idxRef = param(el, "AXIndexForTextMarker", caretStart) {
        print("    AXIndexForTextMarker: \(idxRef)")
    }
    // Font at the caret via the marker attributed-string API (what
    // AXCaret.markerCaretFont relies on for Electron ghost sizing):
    if let prev = param(el, "AXPreviousTextMarkerForTextMarker", caretStart),
       let range = param(el, "AXTextMarkerRangeForUnorderedTextMarkers", [prev, caretStart] as CFArray),
       let out = param(el, "AXAttributedStringForTextMarkerRange", range),
       CFGetTypeID(out) == CFAttributedStringGetTypeID() {
        let a = out as! NSAttributedString
        if a.length > 0 {
            let attrs = a.attributes(at: 0, effectiveRange: nil)
            print("    attrStr(prevChar) keys: \(attrs.keys.map(\.rawValue).sorted().joined(separator: ", "))")
            if let f = attrs[.font] as? NSFont { print("    .font: \(f.fontName) \(f.pointSize)") }
            if let d = attrs[NSAttributedString.Key("AXFont")] as? [String: Any] {
                print("    AXFont dict: \(d)")
            }
        } else {
            print("    attrStr(prevChar): empty")
        }
    } else {
        print("    attrStr(prevChar): unavailable")
    }
}

func probe(bundleSubstring: String? = nil) {
    // Per-app AX works from spawned shells (and reads the app-LOCAL focused
    // element even when the app is not frontmost); the systemwide focus query
    // fails there with -25204. `app <substring>` mode targets the app directly.
    var focusedRef: CFTypeRef?
    var ferr = AXError.cannotComplete
    if let want = bundleSubstring?.lowercased() {
        guard let target = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.lowercased().contains(want) == true
        }) else { print("no running app matching \"\(want)\""); return }
        ferr = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(target.processIdentifier),
            kAXFocusedUIElementAttribute as CFString, &focusedRef)
    } else {
        ferr = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString, &focusedRef)
    }
    guard ferr == .success,
          let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
        print("no focused element (err \(ferr.rawValue), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
        return
    }
    let el = focusedRef as! AXUIElement
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    let app = NSRunningApplication(processIdentifier: pid)
    print("=== focused: \(app?.bundleIdentifier ?? "?") role=\(str(attr(el, kAXRoleAttribute)) ?? "?") subrole=\(str(attr(el, kAXSubroleAttribute)) ?? "-") ===")

    // Supported parameterized attributes — the authoritative capability list.
    var names: CFArray?
    if AXUIElementCopyParameterizedAttributeNames(el, &names) == .success, let names = names as? [String] {
        print("  paramAttrs: \(names.joined(separator: ", "))")
    } else {
        print("  paramAttrs: <unavailable>")
    }

    // Integer-range path.
    if let value = str(attr(el, kAXValueAttribute)) {
        print("  kAXValue: \(value.count) chars")
    } else {
        print("  kAXValue: nil/empty")
    }
    var selRange = CFRange()
    if let sr = attr(el, kAXSelectedTextRangeAttribute),
       CFGetTypeID(sr) == AXValueGetTypeID(),
       AXValueGetValue(sr as! AXValue, .cfRange, &selRange) {
        print("  selectedTextRange: loc=\(selRange.location) len=\(selRange.length)")
        for (loc, len) in [(selRange.location, 0), (max(0, selRange.location - 1), 1)] {
            var r = CFRange(location: loc, length: len)
            if let rv = AXValueCreate(.cfRange, &r) {
                let b = rect(param(el, kAXBoundsForRangeParameterizedAttribute as String, rv))
                print("  boundsForRange(\(loc),\(len)): \(b.map(String.init(describing:)) ?? "nil")")
            }
        }
        // Integer-range attributed string — Chromium lists it; dump the font attrs.
        var ar = CFRange(location: max(0, selRange.location - 1), length: min(1, max(selRange.location, 1)))
        if let arv = AXValueCreate(.cfRange, &ar),
           let out = param(el, kAXAttributedStringForRangeParameterizedAttribute as String, arv),
           CFGetTypeID(out) == CFAttributedStringGetTypeID() {
            let a = out as! NSAttributedString
            if a.length > 0 {
                let attrs = a.attributes(at: 0, effectiveRange: nil)
                print("  attrStrForRange keys: \(attrs.keys.map(\.rawValue).sorted().joined(separator: ", "))")
                if let f = attrs[.font] as? NSFont { print("  .font: \(f.fontName) \(f.pointSize)") }
                for key in ["AXFont", "NSFont"] {
                    if let d = attrs[NSAttributedString.Key(key)] as? [String: Any] {
                        print("  \(key) dict: \(d)")
                    }
                }
            } else { print("  attrStrForRange: empty") }
        } else { print("  attrStrForRange: unavailable") }
    } else {
        print("  selectedTextRange: nil")
    }

    // Marker path on the focused element, then up the ancestor chain (Chromium
    // sometimes only answers marker geometry on the web-area root).
    markerBounds(el, label: "focused")
    var cur = el
    for depth in 1...5 {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parentRef) == .success,
              let parentRef, CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { break }
        cur = parentRef as! AXUIElement
        let role = str(attr(cur, kAXRoleAttribute)) ?? "?"
        if role == "AXWebArea" || depth == 5 {
            markerBounds(cur, label: "ancestor[\(depth)] \(role)")
            if role == "AXWebArea" { break }
        }
    }
    print("")
}

guard AXIsProcessTrusted() else {
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    print("Not AX-trusted yet. Grant Accessibility to /tmp/axprobe in System Settings, then re-run.")
    exit(1)
}

// `axprobe wait <bundle-substring>`: poll quietly until the focused app matches,
// then take samples. Default: 5s lead, 8 samples.
let args = CommandLine.arguments
// `axprobe app <bundle-substring>`: probe the app's own focused element right
// now, no focus dance — works even when the app is in the background.
if args.count >= 3, args[1] == "app" {
    for _ in 0..<3 { probe(bundleSubstring: args[2]); Thread.sleep(forTimeInterval: 1) }
    exit(0)
}
if args.count >= 3, args[1] == "wait" {
    let want = args[2].lowercased()
    print("waiting for focus in an app matching \"\(want)\" (15min max)…\n")
    let deadline = Date().addingTimeInterval(900)
    while Date() < deadline {
        // NSWorkspace.frontmostApplication never refreshes without a run loop and
        // the systemwide AX focus query fails from spawned shells (-25204) —
        // CGWindowList works run-loop-free: frontmost app owns the first layer-0
        // window in z-order.
        var front = ""
        if let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]],
           let top = wins.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let pid = top[kCGWindowOwnerPID as String] as? pid_t {
            front = NSRunningApplication(processIdentifier: pid)?
                .bundleIdentifier?.lowercased() ?? ""
        }
        if front.contains(want) {
            for _ in 0..<6 { probe(); Thread.sleep(forTimeInterval: 2) }
            exit(0)
        }
        Thread.sleep(forTimeInterval: 1)
    }
    print("timed out — target app never focused")
    exit(1)
}
print("5s to focus the Slack composer… then 8 samples, 2s apart.\n")
Thread.sleep(forTimeInterval: 5)
for _ in 0..<8 {
    probe()
    Thread.sleep(forTimeInterval: 2)
}
