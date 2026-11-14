// #781: Always allow and the sidekick pattern in dch's own config file, so dch 1.30.0+ (the full build)
// answers permission prompts itself; DchAutoAllowGate reads `auto_allow = true` back through `dch --config`
// and the island's engine stands down. The format is dch's (dch.c config_line, config_set): `key = value`
// lines, the last one of a key wins, every other line belongs to the user. A pure core (`render`) and a thin
// file layer (`write`, atomic, the path injected). Foundation and Darwin only, every function nonisolated.

import Darwin
import Foundation
import os

enum DchConfigWriter {
    /// Round 5: dch 1.30.0 refuses hook and ask prompts (#080); an older master would answer them.
    static let handOffMinimum = [1, 30, 0]
    /// dch reads sidekick_pattern into a 256-byte buffer: a longer value would be cut into another regex.
    static let maxPatternBytes = 255
    /// #781 r2: a config file is a few lines; a bigger one is not read whole on the poll queue.
    static let maxFileBytes = 1 << 20
    private static let log = Logger(subsystem: "eu.illegible.prosper", category: "agentisland")

    /// dch's own path rule (dch_config_path): $DCH_CONFIG, else $XDG_CONFIG_HOME/dch/config, else
    /// $HOME/.config/dch/config; an empty variable counts as unset. nil: no path can be formed.
    static func defaultPath(env: [String: String]) -> String? {
        if let e = env["DCH_CONFIG"], !e.isEmpty { return e }
        if let x = env["XDG_CONFIG_HOME"], !x.isEmpty { return x + "/dch/config" }
        if let h = env["HOME"], !h.isEmpty { return h + "/.config/dch/config" }
        return nil
    }

    /// auto_allow's value: true only with the toggle on and the installed dch at `handOffMinimum` with the
    /// full build; false otherwise, so a dch below the gate never answers and the island stays the only engine.
    /// nil: the build is unknown (`--build` timed out), so nothing is written. `build` is asked only past
    /// the version (an older dch exits 1 on --build) and only with the toggle on.
    static func autoAllow(toggle: Bool, dch: DchCommand.Binary, build: (DchCommand.Binary) -> String?) -> Bool? {
        guard toggle, DchCommand.isAtLeast(dch.version, handOffMinimum) else { return false }
        guard let b = build(dch) else { return nil }
        return b == "full"
    }

    /// The island's pattern as dch gets it: the trimmed text when ICU and dch's POSIX ERE provably read it
    /// alike (`portable`) and the island uses it as a regex (valid, not matching ""); else "" (dch's picker
    /// then shows no Sidekicks tab), never a pattern that splits differently.
    static func sidekickValue(_ pattern: String) -> String {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p.utf8.count <= maxPatternBytes, portable(p),
              AgentIsland.sidekickCaption(p, tabs: true, names: []) == nil else { return "" }
        return p
    }

    /// The subset both engines read alike on ASCII names: printable ASCII; literals; `\` before one of
    /// `\^$.|?*+()[]{}`; the anchors `^` `$`; `(` `)` around something; `|` between two non-empty branches;
    /// one `*` `+` `?` right after a literal. Not in it: `.` (dch runs in the C locale: one byte, ICU one
    /// character), brackets and `\d`-style classes (ranges and Unicode digits differ), `{}`, `(?`, lazy or
    /// possessive quantifiers, a quantified group (ICU backtracks, the island may flip it to text).
    static func portable(_ p: String) -> Bool {
        enum Last { case open, atom, close, alt, quant, anchor }
        let special = Set("\\^$.|?*+()[]{}".unicodeScalars)
        var last = Last.open, depth = 0, escaped = false
        for u in p.unicodeScalars {
            guard u.value >= 0x20, u.value <= 0x7E else { return false }
            if escaped {
                guard special.contains(u) else { return false }
                escaped = false
                last = .atom
                continue
            }
            switch u {
            case "\\": escaped = true
            case "(": depth += 1; last = .open
            case ")":
                guard depth > 0, last != .open, last != .alt else { return false }
                depth -= 1
                last = .close
            case "|":
                guard last != .open, last != .alt else { return false }
                last = .alt
            case "*", "+", "?":
                guard last == .atom else { return false }
                last = .quant
            case "^", "$": last = .anchor
            case ".", "[", "]", "{", "}": return false
            default: last = .atom
            }
        }
        return !escaped && depth == 0 && last != .alt && last != .open
    }

    /// The pure core: `old` (the file's bytes, any encoding) with auto_allow and sidekick_pattern set the way
    /// dch's own `--config` sets them: a key's first line replaced, its later lines dropped, every other line
    /// kept byte for byte (CRLF, non-UTF-8 and comments too), a last line without a newline given one, a
    /// missing key appended. A pattern dch could not read back as one line (a control character, over
    /// `maxPatternBytes`) is written empty: no character of it ever starts another line.
    static func render(_ old: Data, autoAllow: Bool, pattern: String) -> Data {
        let oneLine = pattern.utf8.count <= maxPatternBytes && pattern.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        let owned = [("auto_allow", "auto_allow = \(autoAllow)"),
                     ("sidekick_pattern", "sidekick_pattern = \(oneLine ? pattern : "")")]
        var lines = old.split(separator: 0x0A, omittingEmptySubsequences: false)
        if old.isEmpty || old.last == 0x0A { _ = lines.popLast() }   // the final newline ends a line, it opens none
        var out = Data(), done = Set<String>()
        for line in lines {
            if let o = owned.first(where: { setsKey(line, $0.0) }) {
                if done.insert(o.0).inserted { out.append(contentsOf: Array((o.1 + "\n").utf8)) }
                continue
            }
            out.append(line)
            out.append(0x0A)
        }
        for (key, set) in owned where !done.contains(key) { out.append(contentsOf: Array((set + "\n").utf8)) }
        return out
    }

    /// dch's config_line: spaces or tabs, the key's bytes, spaces or tabs, then '='.
    static func setsKey(_ line: Data, _ key: String) -> Bool {
        let k = Array(key.utf8), rest = line.drop { $0 == 0x20 || $0 == 0x09 }
        guard rest.starts(with: k) else { return false }
        return rest.dropFirst(k.count).drop { $0 == 0x20 || $0 == 0x09 }.first == 0x3D
    }

    enum Outcome: Equatable {
        case written, unchanged
        /// Nothing was changed; why.
        case refused(String)
    }

    /// The file layer, on the caller's queue (the controller's poll queue). A symbolic link is followed and
    /// its target replaced (the link stays), as dch's own writer does; a link to nothing, a folder, an unreadable
    /// file or a failed write changes nothing and is logged. A missing file is created (its folder 0700, the
    /// file 0644); an existing one keeps its mode. The new text goes to a temporary file in the same folder,
    /// is synced, then renamed over the old one. The same text again writes nothing.
    /// shortcut: a write by dch or by hand between the read and the rename is lost, as with dch's own
    /// `--config`; add a compare-before-rename if both ever write at once.
    @discardableResult
    static func write(path: String, autoAllow: Bool, pattern: String) -> Outcome {
        let r = replace(path, autoAllow, pattern)
        if case .refused(let why) = r {
            log.error("dch config not written (\(why, privacy: .public)): \(path, privacy: .private)")
        }
        return r
    }

    private static func replace(_ path: String, _ autoAllow: Bool, _ pattern: String) -> Outcome {
        var target = path, st = stat()
        if lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFLNK {
            guard let real = realpath(path, nil) else { return .refused("a symbolic link to nothing") }
            target = String(cString: real)
            free(real)
        }
        let old: Data, mode: mode_t
        if stat(target, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFREG else { return .refused("not a regular file") }
            // shortcut: a file that grows between this stat and the read is read whole; bound the read if that ever matters.
            guard st.st_size <= maxFileBytes else { return .refused("over \(maxFileBytes) bytes") }
            guard let d = FileManager.default.contents(atPath: target) else { return .refused("unreadable") }
            old = d
            mode = st.st_mode & 0o7777
        } else if errno == ENOENT {
            let dir = (target as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            old = Data()
            mode = 0o644
        } else {
            return .refused("stat: \(String(cString: strerror(errno)))")
        }
        let new = render(old, autoAllow: autoAllow, pattern: pattern)
        guard new != old else { return .unchanged }
        let tmp = target + ".prosper-\(UUID().uuidString.prefix(8)).tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .refused("create: \(String(cString: strerror(errno)))") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        // FileHandle may not set errno: its failure is named, the POSIX calls' strerror is kept.
        var why: String? = (try? h.write(contentsOf: new)) == nil ? "write failed" : nil
        if why == nil, fchmod(fd, mode) != 0 || fsync(fd) != 0 { why = String(cString: strerror(errno)) }
        if close(fd) != 0, why == nil { why = String(cString: strerror(errno)) }
        if why == nil, rename(tmp, target) != 0 { why = String(cString: strerror(errno)) }
        if let why {
            unlink(tmp)
            return .refused("write: \(why)")
        }
        return .written
    }
}
