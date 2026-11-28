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
    /// #1172: dch reads a line with fgets into 1024 bytes; a longer line comes in pieces, and a piece may set a key
    /// that Prosper, reading whole lines, does not see.
    static let dchLineBytes = 1023
    /// #1172: masters 1.29.0 up to `handOffMinimum` read auto_allow but still answer hook and ask prompts.
    static let heldMinimum = [1, 29, 0]
    /// #1757 (#1755 contract): dch 1.124.0 reads `group = <name> = <regex>` lines; an older one only sidekick_pattern.
    static let groupsMinimum = [1, 124, 0]
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
        guard !p.isEmpty, p.utf8.count <= maxPatternBytes, portable(p), AgentIsland.sidekickMatch(p) == .regex else { return "" }
        return p
    }

    /// #1757: each group's line value, `<name> = <regex>`, in order: the regex as sidekickValue gives it, and a group
    /// dch would skip (a name it does not keep, a regex sidekickValue refuses) left out, so no line Prosper writes is one
    /// dch drops. #2062 (dch #721): a manual-only group (blank pattern) is `<name> =`, so `render` writes
    /// `group = <name> =`; a dch before #721 skips that line, so it is never a placeholder regex.
    static func groupValues(_ groups: [SessionGroup]) -> [String] {
        SessionGroup.normalized(groups).compactMap { g in
            if g.isManual { return "\(g.name) =" }
            let v = sidekickValue(g.pattern)
            return v.isEmpty ? nil : "\(g.name) = \(v)"
        }
    }

    /// #2061 (dch 1.196.0): each written group's colour line value, `<name> = #RRGGBB`, in groupValues' order: a group
    /// groupValues leaves out gets none (dch would colour a tab it does not draw). `colors`: Preferences.sessionGroupColors.
    static func colorValues(_ groups: [SessionGroup], colors: [String: String]) -> [String] {
        SessionGroup.normalized(groups).compactMap { g in
            guard !groupValues([g]).isEmpty, let c = colors[g.id].flatMap(SessionGroup.validColor) else { return nil }
            return "\(g.name) = \(c)"
        }
    }

    /// #1757: the group lines `render` owns for this dch: `values` at groupsMinimum, nil (the file's own group lines
    /// kept, none added) below it or with no dch found.
    static func groupLines(_ values: [String], dch: DchCommand.Binary?) -> [String]? {
        guard let dch, DchCommand.isAtLeast(dch.version, groupsMinimum) else { return nil }
        return values
    }

    /// #1766: the values of the file's group lines in order, found as `render` finds the lines it owns (setsKey), each
    /// read up to its first NUL as dch reads it, after its first "=", spaces, tabs and CR trimmed; a non-UTF-8 value is
    /// skipped. Empty when the file is missing or not one `write` would read (not regular, over maxFileBytes, unreadable).
    /// #2061 r2 (QA n12): `key` "group_color" reads the colour lines the same way.
    static func fileGroupValues(path: String, key: String = "group") -> [String] {
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxFileBytes,
              let d = FileManager.default.contents(atPath: path) else { return [] }
        return d.split(separator: 0x0A).compactMap { whole in
            let line = whole.prefix { $0 != 0 }
            guard setsKey(line, key), let v = String(data: Data(line.drop { $0 != 0x3D }.dropFirst()), encoding: .utf8) else { return nil }
            return v.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        }
    }

    /// #1766: the groups in those values that Prosper writes back as one line each: `<name> = <regex>` split at the
    /// first "=", a regex sidekickValue keeps; then normalized (a name dch keeps, first of a name, at most 8). Ids as
    /// the Settings editor makes a new row's. #2061 r2 (QA n12): `colors`, the file's group_color values
    /// (`<name> = #rrggbb`), become the picks of the groups they name (nameKey, the last line of a name winning as in
    /// dch); a value validColor refuses leaves its group Automatic, so the next owned write keeps the file's colours.
    static func adoptable(_ values: [String], colors: [String] = []) -> [SessionGroup] {
        var picks = [String: String]()
        for v in colors {
            guard let eq = v.firstIndex(of: "=") else { continue }
            picks[SessionGroup.nameKey(String(v[..<eq]))] = SessionGroup.validColor(v[v.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
        return SessionGroup.normalized(values.compactMap { v in
            guard let eq = v.firstIndex(of: "=") else { return nil }
            let name = String(v[..<eq]), raw = String(v[v.index(after: eq)...]), p = sidekickValue(raw)
            // #2062 (dch #721): a blank regex is a manual-only group, adopted with no pattern.
            guard !p.isEmpty || raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SessionGroup(id: String(UUID().uuidString.prefix(8)).lowercased(), name: name, pattern: p,
                                color: picks[SessionGroup.nameKey(name)])
        })
    }

    /// #1766: the one line logged when a stored list replaces different group lines in the file.
    static func logReplaced(_ had: [String], _ lines: [String]) {
        log.notice("dch config: \(had.count, privacy: .public) group line(s) replaced by Prosper's \(lines.count, privacy: .public)")
    }

    /// #1172: what may stand inside a bracket set, alone or as a range of one kind (digits, a-z, A-Z), low to high.
    static let setMembers = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_".unicodeScalars)

    /// The subset both engines read alike on ASCII names: printable ASCII; literals; `\` before one of
    /// `\^$.|?*+()[]{}`; the anchors `^` `$`; `(` `)` around something; `|` between two non-empty branches;
    /// one `*` `+` `?` right after a literal or a bracket set; #1172: a bracket set of `setMembers` and ranges (`[0-9]`,
    /// `[a-z_]`). A set of ASCII members matches one ASCII byte in dch and one ASCII character in ICU, and an ASCII byte
    /// never sits inside a multi-byte character, so non-ASCII names read alike too. Letters in a set fold case exactly as
    /// a literal letter does (the known limit: ICU also folds K U+212A to k and ſ U+017F to s, dch only ASCII).
    /// Not in it: `.` (dch runs in the C locale: one byte, ICU one character and never a line end), a negated set
    /// (`[^0-9]` takes one byte of a multi-byte character in dch, the whole character in ICU), `-` `^` `]` `[` `\` `:`
    /// or anything else inside a set (ICU escapes, nested sets, `&&`, POSIX classes), `\d`-style classes (Unicode
    /// digits), `{}`, `(?`, lazy or possessive quantifiers, a quantified group (ICU backtracks, the island may flip it to text).
    static func portable(_ p: String) -> Bool {
        enum Last { case open, atom, close, alt, quant, anchor }
        let special = Set("\\^$.|?*+()[]{}".unicodeScalars)
        let s = Array(p.unicodeScalars)
        var last = Last.open, depth = 0, i = 0
        while i < s.count {
            let u = s[i]
            i += 1
            guard u.value >= 0x20, u.value <= 0x7E else { return false }
            switch u {
            case "\\":
                guard i < s.count, special.contains(s[i]) else { return false }
                i += 1
                last = .atom
            case "[":
                guard let end = setEnd(s, from: i) else { return false }
                i = end
                last = .atom
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
            case ".", "]", "{", "}": return false
            default: last = .atom
            }
        }
        return depth == 0 && last != .alt && last != .open
    }

    /// The index just past the `]` of a set whose members start at `from` (after its `[`); nil when the set is empty
    /// or holds anything but `setMembers` and ranges of one kind, low to high.
    private static func setEnd(_ s: [Unicode.Scalar], from: Int) -> Int? {
        func kind(_ u: Unicode.Scalar) -> Int? {
            switch u.value {
            case 0x30...0x39: 0
            case 0x61...0x7A: 1
            case 0x41...0x5A: 2
            default: nil
            }
        }
        var i = from
        while i < s.count, setMembers.contains(s[i]) {
            if i + 2 < s.count, s[i + 1] == "-", setMembers.contains(s[i + 2]) {
                guard let k = kind(s[i]), k == kind(s[i + 2]), s[i].value <= s[i + 2].value else { return nil }
                i += 3
            } else {
                i += 1
            }
        }
        return i > from && i < s.count && s[i] == "]" ? i + 1 : nil
    }

    /// #1172: whether true must be held back from dch's config: a listed master in `heldMinimum` ..< `handOffMinimum`,
    /// or one whose version is not plain "X.Y.Z" ("" from a list without versions or a master too old to say, a
    /// suffix, garbage), or no list at all (nil: a list timed out or did not parse). Only a list read whole and every
    /// version outside the range lets true through.
    static func holdsTrue(_ masters: [String]?) -> Bool {
        guard let masters else { return true }
        return masters.contains { m in
            guard let v = plainVersion(m) else { return true }
            return DchCommand.isAtLeast(v, heldMinimum) && !DchCommand.isAtLeast(v, handOffMinimum)
        }
    }

    /// "X.Y.Z" of ASCII digits, at most 9 per part (so Int never overflows); anything else nil.
    static func plainVersion(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ (1...9).contains($0.utf8.count) && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } })
        else { return nil }
        return parts.compactMap { Int($0) }
    }

    /// #1172: every master's "version" in `--ls-json` outputs, one per socket dir; nil when any of them timed out (nil)
    /// or is not a JSON array of rows (unknown, never "no masters"). A row without a string version counts as "".
    static func masters(_ lists: [Data?]) -> [String]? {
        var out: [String] = []
        for d in lists {
            guard let d, let rows = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return nil }
            out += rows.map { $0["version"] as? String ?? "" }
        }
        return out
    }

    /// #1172: what dch reads for auto_allow in `file` (dch.c config_line and dch_config_bool): the last line setting it
    /// wins, its value after spaces or tabs, cut of trailing spaces, tabs and CR, true for true/1/yes/on in any ASCII
    /// case; false with no such line. nil when a line is over `dchLineBytes` (dch reads it in pieces: unknown).
    /// #1179: nil when the file holds a NUL byte anywhere (dch reads C strings: a line ends for it at the NUL).
    static func dchAllows(_ file: Data) -> Bool? {
        guard !file.contains(0) else { return nil }
        var on = false
        for line in file.split(separator: 0x0A, omittingEmptySubsequences: false) {
            guard line.count <= dchLineBytes else { return nil }
            guard setsKey(line, "auto_allow") else { continue }
            var v = line.drop { $0 != 0x3D }.dropFirst().drop { $0 == 0x20 || $0 == 0x09 }
            while let b = v.last, b == 0x20 || b == 0x09 || b == 0x0D { v = v.dropLast() }
            on = v.allSatisfy { $0 < 0x80 } && ["true", "1", "yes", "on"].contains(String(decoding: v, as: UTF8.self).lowercased())
        }
        return on
    }

    /// #1172: when `dch --config` timed out at the stand-down check, whether dch may answer by its own file. No path
    /// (no DCH_CONFIG, XDG_CONFIG_HOME or HOME) or no file: dch reads false. A file read the way dch reads it: its
    /// value. Anything Prosper cannot read as dch does (not a regular file, unreadable, over maxFileBytes, a line over
    /// dchLineBytes, a NUL byte, a stat error): true, so the island stands down and, if dch does not answer, the prompt goes to
    /// the human after the wait; never to both engines. Called on the controller's queue.
    static func mayAllow(path: String?) -> Bool {
        guard let path else { return false }
        var st = stat()
        guard stat(path, &st) == 0 else { return errno != ENOENT }
        guard st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxFileBytes,
              let d = FileManager.default.contents(atPath: path) else { return true }
        return dchAllows(d) ?? true
    }

    /// The pure core: `old` (the file's bytes, any encoding) with auto_allow and sidekick_pattern set the way
    /// dch's own `--config` sets them: a key's first line replaced, its later lines dropped, every other line
    /// kept byte for byte (CRLF, non-UTF-8 and comments too), a last line without a newline given one, a
    /// missing key appended. A pattern dch could not read back as one line (a control character, over
    /// `maxPatternBytes`) is written empty: no character of it ever starts another line.
    /// #1179: on a line holding a NUL byte dch sees its bytes up to the NUL, and a key in that prefix is a key setsKey
    /// sees on the whole line (the bytes through "=" hold no NUL), so both find the same key lines.
    /// #1185 (QA 916): any other such line is cut at its first NUL (the bytes dch reads stay) and dropped when nothing
    /// is left: kept whole, it made mayAllow read the file as unknown at every later `--config` timeout (the island stood down).
    /// #1757: `groups` non-nil owns the `group` key too: every group line goes, these values stand at the first one's
    /// place (else at the end), in order; [] leaves none, which with `sidekick_pattern =` empty is dch's empty list.
    /// #2061: with `groups` non-nil the `group_color` key is owned too: its lines go, `colors` (colorValues) follow the
    /// group lines as one block. With `groups` nil the file's colour lines are kept, as its group lines are.
    static func render(_ old: Data, autoAllow: Bool, pattern: String, groups: [String]? = nil, colors: [String] = []) -> Data {
        let oneLine = pattern.utf8.count <= maxPatternBytes && pattern.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        let owned = [("auto_allow", "auto_allow = \(autoAllow)"),
                     ("sidekick_pattern", "sidekick_pattern = \(oneLine ? pattern : "")")]
        var lines = old.split(separator: 0x0A, omittingEmptySubsequences: false)
        if old.isEmpty || old.last == 0x0A { _ = lines.popLast() }   // the final newline ends a line, it opens none
        var out = Data(), done = Set<String>()
        let groupText = (groups ?? []).map { "group = \($0)\n" }.joined()
            + (groups == nil ? [] : colors).map { "group_color = \($0)\n" }.joined()
        for line in lines {
            if groups != nil, setsKey(line, "group_color") { continue }
            if groups != nil, setsKey(line, "group") {
                if done.insert("group").inserted { out.append(contentsOf: Array(groupText.utf8)) }
                continue
            }
            if let o = owned.first(where: { setsKey(line, $0.0) }) {
                if done.insert(o.0).inserted { out.append(contentsOf: Array((o.1 + "\n").utf8)) }
                continue
            }
            // #1185 (QA 916): any other line is cut at its first NUL, so the rewritten file reads to Prosper as to dch.
            let cut = line.prefix { $0 != 0 }
            if cut.count < line.count, cut.isEmpty { continue }   // a NUL first: nothing dch reads is left
            out.append(cut)
            out.append(0x0A)
        }
        for (key, set) in owned where !done.contains(key) { out.append(contentsOf: Array((set + "\n").utf8)) }
        if groups != nil, !done.contains("group") { out.append(contentsOf: Array(groupText.utf8)) }
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
    static func write(path: String, autoAllow: Bool, pattern: String, groups: [String]? = nil, colors: [String] = []) -> Outcome {
        let r = replace(path, autoAllow, pattern, groups, colors)
        if case .refused(let why) = r {
            log.error("dch config not written (\(why, privacy: .public)): \(path, privacy: .private)")
        }
        return r
    }

    private static func replace(_ path: String, _ autoAllow: Bool, _ pattern: String, _ groups: [String]?, _ colors: [String]) -> Outcome {
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
            // #1172: a piece of a long line may set a key in dch that render does not see; leave such a file alone.
            guard !d.split(separator: 0x0A).contains(where: { $0.count > dchLineBytes }) else {
                return .refused("a line over \(dchLineBytes) bytes")
            }
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
        let new = render(old, autoAllow: autoAllow, pattern: pattern, groups: groups, colors: colors)
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
