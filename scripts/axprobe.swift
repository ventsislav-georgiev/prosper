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
    guard let caretStart = param(el, "AXStartTextMarkerForTextMarkerRange", sel) else {
        print("    AXStartTextMarkerForTextMarkerRange: nil"); return
    }
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
}

func probe() {
    let systemWide = AXUIElementCreateSystemWide()
    var focusedRef: CFTypeRef?
    let ferr = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
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

print("5s to focus the Slack composer… then 8 samples, 2s apart.\n")
Thread.sleep(forTimeInterval: 5)
for _ in 0..<8 {
    probe()
    Thread.sleep(forTimeInterval: 2)
}
