// Inline-autocomplete benchmark harness (tool-agnostic).
//
// Drives the built E2EHost dummy app (a real frontmost focused field) with
// synthesized typing, waits for whatever inline-autocomplete engine is live on
// the system (Cotypist OR the installed Prosper), accepts the ghost, and reads
// back the field via Accessibility. The accepted completion = fieldAfter with
// the seeded prefix stripped from the front and the `after` text from the tail.
//
// Build:  swiftc -O bench/bench.swift -o .build/bench -framework AppKit
// Run:    .build/bench --corpus bench/corpus.json --out bench/results-cotypist.json \
//                      --tool cotypist --kind nstextview --accept right --prewait 3.0
//
// It is deliberately standalone (no MLX compile) so it iterates fast and tests
// the REAL shipping apps exactly as a user experiences them.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - args

func arg(_ name: String, _ def: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--\(name)"), i + 1 < a.count { return a[i + 1] }
    return def
}
let corpusPath = arg("corpus", "bench/corpus.json")
let outPath    = arg("out", "bench/results.json")
let tool       = arg("tool", "unknown")
let kindArg    = arg("kind", "nstextview")
let acceptKey  = arg("accept", "right")          // right | tab
let acceptMode = arg("acceptmode", "auto")       // auto | once | loop (loop = press until ghost exhausted)
let preWait    = Double(arg("prewait", "3.0")) ?? 3.0
let growWait   = Double(arg("growwait", "1.2")) ?? 1.2
let maxGhostWait = Double(arg("ghostwait", "6.0")) ?? 6.0   // extra budget for a late first ghost
let onlyLang   = arg("lang", "")                 // en|bg|lat|"" (all)
let limit      = Int(arg("limit", "0")) ?? 0     // 0 = all
let typeMode   = arg("type", "full")             // last (AX-seed head + type last char) | full (type whole prefix)
let perKey     = Double(arg("perkey", "0.05")) ?? 0.05
let capture    = arg("capture", "ghost")         // ghost (read AX overlay, no accept, no quota) | accept
let engineApp  = arg("engineapp", "")            // app name whose ghost overlay to read (Prosper | Cotypist)

// MARK: - corpus

struct Case: Codable { let id: String; let lang: String; let kind: String; let prefix: String; let expect: String; let after: String? }
struct Corpus: Codable { let cases: [Case] }

guard let data = try? Data(contentsOf: URL(fileURLWithPath: corpusPath)),
      let corpus = try? JSONDecoder().decode(Corpus.self, from: data) else {
    FileHandle.standardError.write(Data("bench: cannot read corpus at \(corpusPath)\n".utf8)); exit(2)
}
var cases = corpus.cases
if !onlyLang.isEmpty { cases = cases.filter { $0.lang == onlyLang } }
if limit > 0 { cases = Array(cases.prefix(limit)) }

// MARK: - E2EHost launch (wrap the built binary in a .app for a real TSM session)

func hostBinary() -> String {
    // Package.swift lives in app/, so the binary is under app/.build; also accept
    // a repo-root .build for flexibility. First existing wins.
    let cwd = FileManager.default.currentDirectoryPath
    let candidates = ["\(cwd)/app/.build/debug/E2EHost", "\(cwd)/.build/debug/E2EHost",
                      arg("host", "")]
    for c in candidates where !c.isEmpty && FileManager.default.isExecutableFile(atPath: c) { return c }
    return candidates[0]
}

func makeHostApp() -> URL? {
    let bin = hostBinary()
    guard FileManager.default.isExecutableFile(atPath: bin) else {
        FileHandle.standardError.write(Data("bench: E2EHost not built at \(bin) (swift build --product E2EHost)\n".utf8)); return nil
    }
    let fm = FileManager.default
    let app = URL(fileURLWithPath: bin).deletingLastPathComponent().appendingPathComponent("E2EHostBench.app")
    let macos = app.appendingPathComponent("Contents/MacOS")
    let exe = macos.appendingPathComponent("E2EHost")
    try? fm.removeItem(at: app)
    try? fm.createDirectory(at: macos, withIntermediateDirectories: true)
    try? fm.copyItem(at: URL(fileURLWithPath: bin), to: exe)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>E2EHost</string>
    <key>CFBundleIdentifier</key><string>com.prosper.e2ehostbench</string>
    <key>CFBundleName</key><string>E2EHostBench</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    </dict></plist>
    """
    try? plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    return app
}

var hostPID: pid_t = 0
var runningApp: NSRunningApplication?

func launchHost(kind: String) -> Bool {
    guard let app = makeHostApp() else { return false }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    cfg.createsNewApplicationInstance = true
    cfg.arguments = [kind]
    let sem = DispatchSemaphore(value: 0)
    var launched: NSRunningApplication?
    NSWorkspace.shared.openApplication(at: app, configuration: cfg) { running, _ in launched = running; sem.signal() }
    let deadline = Date().addingTimeInterval(12)
    while sem.wait(timeout: .now()) == .timedOut, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    guard let l = launched else { return false }
    runningApp = l; hostPID = l.processIdentifier
    return true
}

// MARK: - AX helpers (address host by pid — stable, independent of frontmost race)

func focusedEl() -> AXUIElement? {
    let appEl = AXUIElementCreateApplication(hostPID)
    var f: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f) == .success,
          let el = f, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
    return (el as! AXUIElement)
}

func rect(of el: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success else { return nil }
    var pos = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pos); AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: pos, size: size)
}

func windowRect() -> CGRect? {
    let appEl = AXUIElementCreateApplication(hostPID)
    var w: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &w) == .success,
          let arr = w as? [AXUIElement], let win = arr.first else { return nil }
    return rect(of: win)
}

func readValue() -> String? {
    guard let el = focusedEl() else { return nil }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
    return v as? String
}

/// Set value + caret at utf16 offset `caret`.
func seed(_ text: String, caret: Int) {
    guard let el = focusedEl() else { return }
    AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef)
    var r = CFRange(location: caret, length: 0)
    if let axr = AXValueCreate(.cfRange, &r) {
        AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axr)
    }
}

func clickToFocus() {
    guard let r = (focusedEl().flatMap(rect(of:))) ?? windowRect() else { return }
    let c = CGPoint(x: r.midX, y: r.midY)
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        CGEvent(mouseEventSource: src, mouseType: down ? .leftMouseDown : .leftMouseUp,
                mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cgSessionEventTap)
    }
    pump(0.08)
}

func waitFocused(_ timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        clickToFocus()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == hostPID { return true }
        pump(0.15)
    }
    return false
}

// MARK: - keyboard synthesis (unicode = layout-independent, needed for Cyrillic/latinica)

func typeString(_ s: String, perKey: TimeInterval = 0.02) {
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in s {
        var u = Array(String(ch).utf16)
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) {
                e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
                e.post(tap: .cgSessionEventTap)
            }
        }
        pump(perKey)
    }
}

func tapKey(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)?.post(tap: .cgSessionEventTap)
    }
    pump(0.03)
}

let kRight: CGKeyCode = 124
let kLeft:  CGKeyCode = 123
let kTab:   CGKeyCode = 48
let kEsc:   CGKeyCode = 53
let kDelete: CGKeyCode = 51   // backspace

func accept() { tapKey(acceptKey == "tab" ? kTab : kRight) }

func pump(_ s: TimeInterval) { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(s)) }

// MARK: - measurement

struct Result: Codable {
    let id, lang, kind, prefix, expect: String
    let after: String
    let completion: String    // accepted continuation (value - prefix - after)
    let grew: Bool
    let latencyMs: Int
    let raw: String           // full field value after accept (debug)
}

func stripTrailing(_ s: String, _ suffix: String) -> String {
    guard !suffix.isEmpty, s.hasSuffix(suffix) else { return s }
    return String(s.dropLast(suffix.count))
}

// Resolve the engine app's pid (Prosper | Cotypist) once.
func enginePID() -> pid_t? {
    guard !engineApp.isEmpty else { return nil }
    return NSWorkspace.shared.runningApplications.first { $0.localizedName == engineApp }?.processIdentifier
}
let engPID = enginePID()

// Collect all AXStaticText values under an app (the ghost overlay is one of them).
func staticTexts(_ pid: pid_t) -> [String] {
    var out: [String] = []
    func walk(_ el: AXUIElement, _ d: Int) {
        if d > 6 || out.count > 200 { return }
        var r: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r) == .success,
           (r as? String) == (kAXStaticTextRole as String) {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
               let s = v as? String, !s.isEmpty { out.append(s) }
        }
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
           let arr = kids as? [AXUIElement] { for k in arr { walk(k, d + 1) } }
    }
    walk(AXUIElementCreateApplication(pid), 0)
    return out
}

func measure(_ c: Case) -> Result {
    let after = c.after ?? ""
    // Clear the field first.
    seed("", caret: 0); pump(0.05)
    // Baseline the engine's overlay texts while the field is empty (no ghost yet),
    // so we can tell the fresh ghost apart from any static chrome.
    let baseline = (capture == "ghost" && engPID != nil) ? Set(staticTexts(engPID!)) : []
    let t0 = Date()
    if typeMode == "full" {
        // Type the ENTIRE prefix as real keystrokes — the faithful trigger for
        // engines (Cotypist) that ignore AX-set values and only react to typing.
        typeString(c.prefix, perKey: perKey)
        if !after.isEmpty {
            // Append the after-text, then walk the caret back to the prefix end so
            // the completion is requested mid-line.
            typeString(after, perKey: perKey)
            for _ in 0..<after.count { tapKey(kLeft) }
        }
    } else {
        // Fast path: AX-seed everything but the last char, then type the last char.
        let head = String(c.prefix.dropLast())
        let last = String(c.prefix.suffix(1))
        seed(head + after, caret: head.utf16.count); pump(0.12)
        typeString(last)
    }
    // --- ghost capture: read the engine's inline overlay via AX, never accept ---
    // No quota burn (nothing is accepted), no field pollution, and it records how
    // fast the ghost first appears + captures the full suggestion (engines refine it
    // while typing/idle, so we keep the latest once it stabilizes).
    if capture == "ghost", let pid = engPID {
        // The engine shows an INSTANT lexicon guess first, then the model refines it
        // ~model-latency later. We must observe long enough to capture the refined
        // ghost, not exit on the first stable value (that grabbed the lexicon snap).
        // Track the LATEST ghost across a fixed window, and only settle after the
        // model has had time (minObserve) AND the ghost has been stable a beat.
        var ghost = ""
        var firstSeen: Date? = nil
        var lastChange = Date()
        let minObserve = Date().addingTimeInterval(preWait)          // let the model land
        let dl = Date().addingTimeInterval(preWait + maxGhostWait)
        while Date() < dl {
            let fresh = staticTexts(pid).filter { !baseline.contains($0) }.first ?? ""
            if fresh != ghost {
                if !fresh.isEmpty && firstSeen == nil { firstSeen = Date() }
                ghost = fresh; lastChange = Date()
            }
            // Settle only after the minimum observation window (model latency) so the
            // model-refined ghost replaces the instant lexicon snap before we read it.
            if Date() > minObserve, !ghost.isEmpty, Date().timeIntervalSince(lastChange) > 0.4 { break }
            pump(0.12)
        }
        let latency = firstSeen.map { Int($0.timeIntervalSince(t0) * 1000) } ?? Int(Date().timeIntervalSince(t0) * 1000)
        let comp = ghost
        let grew = !comp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        seed("", caret: 0); pump(0.05)
        return Result(id: c.id, lang: c.lang, kind: c.kind, prefix: c.prefix, expect: c.expect,
                      after: after, completion: comp, grew: grew, latencyMs: latency, raw: c.prefix + comp)
    }

    // Give the model an initial head-start to produce a ghost.
    pump(preWait)
    let loop = (acceptMode == "loop") || (acceptMode == "auto" && acceptKey == "tab")
    var value = readValue() ?? ""
    var accepted = 0
    // Budget for the ghost to appear on the FIRST accept (model gen can be late/variable).
    let ghostDeadline = Date().addingTimeInterval(maxGhostWait)
    while true {
        let before = value
        accept()
        // Wait for this press to land in the field.
        let dl = Date().addingTimeInterval(growWait)
        while Date() < dl { pump(0.1); value = readValue() ?? value; if value != before { break } }
        if value == before {
            // Arrow-accept with no ghost is a silent no-op (no \t pollution). If we
            // haven't captured anything yet and the budget remains, the ghost may
            // just be late — wait and retry; otherwise we're done.
            if accepted == 0 && Date() < ghostDeadline { pump(0.3); continue }
            break
        }
        if value.hasSuffix("\t") {
            // Tab past the end of a ghost inserts a stray tab. Remove it. Before any
            // real word: the ghost wasn't ready yet → retry within budget. After a
            // word: the ghost is exhausted → done.
            tapKey(kDelete); pump(0.2); value = readValue() ?? value
            if accepted > 0 { break }
            if Date() < ghostDeadline { pump(0.3); continue }
            break
        }
        accepted += 1
        if !loop { break }            // once-mode (→ accepts the whole suggestion)
        if accepted >= 8 { break }    // safety cap on word-by-word
    }
    let latency = Int(Date().timeIntervalSince(t0) * 1000)
    // completion = value with prefix stripped from front and `after`+stray tabs from tail.
    var comp = value
    while comp.hasSuffix("\t") { comp = String(comp.dropLast()) }
    if comp.hasPrefix(c.prefix) { comp = String(comp.dropFirst(c.prefix.count)) }
    comp = stripTrailing(comp, after)
    let grew = comp.count > 0
    // Reset: clear the field via AX (NO Esc — Esc puts some engines into a
    // suppressed state that survives the clear and kills the next suggestion).
    seed("", caret: 0); pump(0.05)
    return Result(id: c.id, lang: c.lang, kind: c.kind, prefix: c.prefix, expect: c.expect,
                  after: after, completion: comp, grew: grew, latencyMs: latency, raw: value)
}

// MARK: - main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("bench: Accessibility NOT trusted for this process — grant it and rerun.\n".utf8)); exit(3)
}

guard launchHost(kind: kindArg) else {
    FileHandle.standardError.write(Data("bench: failed to launch E2EHost\n".utf8)); exit(4)
}
guard waitFocused(15) else {
    FileHandle.standardError.write(Data("bench: E2EHost never became frontmost/focused\n".utf8)); exit(5)
}
clickToFocus(); pump(0.3)

// --- probe mode: type a prefix, then dump AX trees to hunt for the ghost text ---
func attr(_ el: AXUIElement, _ key: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, key as CFString, &v) == .success else { return nil }
    if let s = v as? String { return s }
    if CFGetTypeID(v!) == AXValueGetTypeID() { return nil }
    return nil
}
func dumpAX(_ el: AXUIElement, depth: Int, out: inout [String]) {
    if depth > 6 || out.count > 400 { return }
    let role = attr(el, kAXRoleAttribute as String) ?? "?"
    let val = attr(el, kAXValueAttribute as String)
    let title = attr(el, kAXTitleAttribute as String)
    let desc = attr(el, kAXDescriptionAttribute as String)
    let help = attr(el, "AXHelp")
    let parts = [("val", val), ("title", title), ("desc", desc), ("help", help)]
        .compactMap { k, v in (v?.isEmpty == false) ? "\(k)=\(v!.replacingOccurrences(of: "\n", with: "\\n").prefix(80))" : nil }
    if !parts.isEmpty || role.contains("Text") {
        out.append("\(String(repeating: "  ", count: depth))[\(role)] \(parts.joined(separator: " "))")
    }
    var kids: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
       let arr = kids as? [AXUIElement] {
        for k in arr { dumpAX(k, depth: depth + 1, out: &out) }
    }
}
let probePrefix = arg("probe", "")
if !probePrefix.isEmpty {
    let probeApp = arg("probeapp", "")   // app name to dump; empty = frontmost autocomplete apps
    seed("", caret: 0); pump(0.1)
    typeString(probePrefix, perKey: 0.05)
    FileHandle.standardError.write(Data("probe: typed \"\(probePrefix)\", waiting for ghost...\n".utf8))
    pump(4.0)
    let running = NSWorkspace.shared.runningApplications
    for ra in running {
        let name = ra.localizedName ?? ""
        let want = probeApp.isEmpty
            ? (name == "Prosper" || name == "Cotypist" || name == "E2EHostBench")
            : (name == probeApp)
        guard want else { continue }
        var lines: [String] = []
        dumpAX(AXUIElementCreateApplication(ra.processIdentifier), depth: 0, out: &lines)
        FileHandle.standardError.write(Data("\n===== AX dump: \(name) (pid \(ra.processIdentifier)) =====\n".utf8))
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
    runningApp?.terminate(); exit(0)
}

FileHandle.standardError.write(Data("bench: tool=\(tool) kind=\(kindArg) accept=\(acceptKey) cases=\(cases.count) prewait=\(preWait)s\n".utf8))

var results: [Result] = []
for (i, c) in cases.enumerated() {
    // Re-win focus each case (a lost ghost or space switch can steal it).
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != hostPID { _ = waitFocused(6) }
    let r = measure(c)
    results.append(r)
    let mark = r.grew ? "✓" : "·"
    FileHandle.standardError.write(Data("  [\(i+1)/\(cases.count)] \(mark) \(c.id) \(c.lang) → \"\(r.completion.replacingOccurrences(of: "\n", with: "\\n"))\" (\(r.latencyMs)ms)\n".utf8))
}

struct Out: Codable { let tool, kind, accept: String; let preWait: Double; let results: [Result] }
let out = Out(tool: tool, kind: kindArg, accept: acceptKey, preWait: preWait, results: results)
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
if let d = try? enc.encode(out) { try? d.write(to: URL(fileURLWithPath: outPath)) }

let hits = results.filter { $0.grew }.count
FileHandle.standardError.write(Data("bench: done — \(hits)/\(results.count) produced a completion. wrote \(outPath)\n".utf8))
runningApp?.terminate()
exit(0)
