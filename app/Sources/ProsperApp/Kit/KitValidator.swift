import Darwin
import Foundation

// #872 P1 (spec 4.2 "Validation at install", 4.3, 4.5 item 1, 4.9, errata A2, A5): the install-time
// validator. Pure apart from reading the kit dir through `KitFileReader`; it writes nothing and runs
// nothing. Plain value types, no actor isolation.

enum KitInstallSource: Sendable { case market, local }

enum KitFileKind: Equatable, Sendable {
    case missing, directory, symlink, other
    case file(mode: UInt16, size: Int64)
}

/// The validator's only way into the kit dir. Paths are absolute.
protocol KitFileReader: Sendable {
    /// lstat: a symlink is reported as `.symlink`, never followed.
    func kind(_ path: String) -> KitFileKind
    func contents(_ path: String) -> Data?
    /// Every name in a dir, dotfiles and AppleDouble `._*` names included; nil when unreadable.
    func names(_ dir: String) -> [String]?
    /// realpath(3); nil when the path does not resolve.
    func realPath(_ path: String) -> String?
}

struct KitPOSIXFileReader: KitFileReader {
    func kind(_ path: String) -> KitFileKind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return .file(mode: UInt16(st.st_mode & 0o7777), size: Int64(st.st_size))
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    func contents(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

    /// readdir, not FileManager: contentsOfDirectory hides "._*" names, which can hold a binary.
    func names(_ dir: String) -> [String]? {
        guard let d = opendir(dir) else { return nil }
        defer { closedir(d) }
        var out: [String] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != ".", name != ".." { out.append(name) }
        }
        return out.sorted()
    }

    func realPath(_ path: String) -> String? {
        guard let p = Darwin.realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}

/// A file a piece names, kit-relative. `name` is the tool name, or the path under a seed's `from`.
struct KitFileRef: Equatable, Sendable {
    var name: String
    var path: String
}

/// A kit that passed every install check: what the render step needs, nothing it has to re-read.
struct KitValidated: Equatable, Sendable {
    var extensionID: String
    var slug: String
    var version: String
    var kit: KitManifest
    /// tools piece id -> its tools, by name
    var tools: [String: [KitFileRef]] = [:]
    /// seed piece id -> its files, by path under `from`
    var seeds: [String: [KitFileRef]] = [:]
    var warnings: [KitRefusal] = []
}

enum KitValidation: Equatable, Sendable {
    case ok(KitValidated)
    case refused([KitRefusal])
}

enum KitValidator {
    static let maxEntries = 4096
    static let maxDepth = 16
    /// an executable bigger than this is not read and counts as non-text
    static let maxTextBytes = 1 << 20
    /// errata A2: ~/.claude/CLAUDE.md -> kit CLAUDE.md -> local.md uses 2 of Claude Code's 4 hops.
    static let maxImportDepth = 2
    /// distinct in-kit files one file may import; the walk reads each file once, so work is bounded
    static let maxImportTargets = 64
    /// {{kit_config}} is <configHome>/<slug>; <configHome>/prosper holds the runtime and every kit's shims
    static let reservedSlugs: Set<String> = ["prosper"]
    static let readmeHeadings = ["What it changes", "Requirements", "Customise", "Remove"]
    static let localImportLine = "@{{kit_config}}/local.md"

    static func validate(kitDir: URL, manifest: ExtensionManifest, source: KitInstallSource, otherKitSlugs: Set<String>,
                         reader: any KitFileReader = KitPOSIXFileReader()) -> KitValidation {
        let dir = kitDir.standardizedFileURL.path
        var run = Run(dir: dir, realDir: reader.realPath(dir) ?? dir, reader: reader, source: source)
        let meta = manifest.extension
        if !ManagedConfigPaths.isValidID(meta.id) || meta.id.allSatisfy({ $0 == "." }) { run.refuse("extension.id", .badExtensionID) }
        if !ManagedConfigPaths.isValidSlug(meta.name) { run.refuse("extension.name", .badSlug) }
        else if KitValidator.reservedSlugs.contains(meta.name) { run.refuse("extension.name", .slugReserved) }
        else if otherKitSlugs.contains(meta.name) { run.refuse("extension.name", .slugTaken) }

        run.walk()
        run.checkReadme()

        var kit: KitManifest?
        if let raw = manifest.contributes?.kit {
            let parsed = KitManifest.parse(raw)
            if parsed.refusals.isEmpty { kit = parsed.kit } else { run.refusals += parsed.refusals }
        } else {
            run.refuse("kit", .notATable)
        }
        var out = KitValidated(extensionID: meta.id, slug: meta.name, version: meta.version, kit: kit ?? KitManifest())
        if let kit {
            for p in kit.pieces { run.check(p, into: &out) }
        }
        run.checkExecutables()
        out.warnings = run.warnings
        return run.refusals.isEmpty ? .ok(out) : .refused(run.refusals)
    }

    /// Text: no Mach-O / fat magic, no NUL byte, valid UTF-8.
    static func isText(_ d: Data) -> Bool {
        let magic: Set<UInt32> = [0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA]
        if d.count >= 4, magic.contains(d.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }) { return false }
        return !d.contains(0) && String(data: d, encoding: .utf8) != nil
    }

    /// `@path` tokens outside fences and code spans; `\ ` is an escaped space (errata A4).
    static func imports(in text: String) -> [String] {
        var out: [String] = []
        var fence = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence.toggle(); continue }
            if fence { continue }
            let plain = raw.split(separator: "`", omittingEmptySubsequences: false).enumerated()
                .filter { $0.offset % 2 == 0 }.map { String($0.element) }.joined(separator: " ")
            var token = ""
            var escaped = false
            for ch in plain + " " {
                if escaped { token.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if ch.isWhitespace {
                    if token.hasPrefix("@"), token.count > 1 { out.append(String(token.dropFirst())) }
                    token = ""
                    continue
                }
                token.append(ch)
            }
        }
        return out
    }

    /// Level-2 heading texts, lowercased, outside fences; a closing `#` run is dropped.
    static func headings(in text: String) -> Set<String> {
        var out: Set<String> = []
        var fence = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fence.toggle(); continue }
            guard !fence, line.hasPrefix("## ") else { continue }
            var h = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            while h.hasSuffix("#") { h.removeLast() }
            out.insert(h.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return out
    }

    private enum Want { case file, dir }

    private struct Run {
        let dir: String
        let realDir: String
        let reader: any KitFileReader
        let source: KitInstallSource
        var refusals: [KitRefusal] = []
        var warnings: [KitRefusal] = []
        /// kit-relative path -> lstat kind, from the walk
        var entries: [String: KitFileKind] = [:]
        /// files that will run: any x bit, every `run` target, every tool
        var executables: Set<String> = []
        var toolNames: Set<String> = [] // {{kit_bin}} names across every tools piece, case-folded
        /// kit-relative file -> its resolved imports, so each file is read and scanned once per validate
        var importCache: [String: (files: [String], outside: Bool)] = [:]
        /// symlink entries an import ran through: each is decided (one realPath) and refused once
        var importSymlinks: Set<String> = []
        var seedTargets: Set<String> = [] // kitconfig: names across every seed piece, case-folded (A-INFO-5)

        /// A symlink entry: pathSymlink when it resolves inside the kit, pathLeaves otherwise.
        func symlinkReason(_ rel: String) -> KitReason {
            let inside = reader.realPath(path(rel)).map { $0 == realDir || $0.hasPrefix(realDir + "/") } ?? false
            return inside ? .pathSymlink : .pathLeaves
        }

        mutating func refuse(_ subject: String, _ reason: KitReason) { refusals.append(.init(subject: subject, reason: reason)) }
        mutating func warn(_ subject: String, _ reason: KitReason) { warnings.append(.init(subject: subject, reason: reason)) }
        func path(_ rel: String) -> String { rel.isEmpty ? dir : dir + "/" + rel }

        /// Every entry, without following a symlink. Bounded: 4096 entries, 16 levels.
        mutating func walk() {
            var stack: [(rel: String, depth: Int)] = [("", 0)]
            var count = 0
            while let top = stack.popLast() {
                let (rel, depth) = top
                for name in reader.names(path(rel)) ?? [] {
                    count += 1
                    let r = rel.isEmpty ? name : rel + "/" + name
                    guard count <= KitValidator.maxEntries else { refuse("kit", .tooManyFiles); return }
                    let kind = reader.kind(path(r))
                    entries[r] = kind
                    switch kind {
                    case .directory:
                        guard depth + 1 < KitValidator.maxDepth else { refuse("kit", .tooManyFiles); return }
                        stack.append((r, depth + 1))
                    case .file(let mode, _):
                        if mode & 0o6000 != 0 { refuse(r, .setuid) }
                        if mode & 0o111 != 0 { executables.insert(r) }
                    default:
                        break
                    }
                }
            }
        }

        /// spec 4.3: README.md with the four level-2 headings, any order, any case.
        /// A kit file's text: nil when over maxTextBytes (checked before the read), unreadable or not text.
        func readText(_ rel: String) -> String? {
            guard case .file(_, let size) = reader.kind(path(rel)), size <= Int64(KitValidator.maxTextBytes),
                  let data = reader.contents(path(rel)), KitValidator.isText(data) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        mutating func checkReadme() {
            guard case .file? = entries["README.md"] else { return refuse("README.md", .noReadme) }
            guard let text = readText("README.md") else { return refuse("README.md", .notText) }
            let found = KitValidator.headings(in: text)
            for h in KitValidator.readmeHeadings where !found.contains(h.lowercased()) { refuse("README.md ## \(h)", .readmeHeading) }
        }

        /// Spec 2.1 checks 1-2 (ManagedConfigPaths.checkRelative, then the standardized path stays
        /// under the kit dir), then no component may be a symlink, then the kind. Returns the
        /// kit-relative path, a trailing "/" of a dir dropped.
        mutating func resolve(_ raw: String, _ subject: String, _ want: Want) -> String? {
            var rel = raw
            if want == .dir, rel.hasSuffix("/") { rel.removeLast() }
            if ManagedConfigPaths.checkRelative(rel) != nil { refuse(subject, .badPath); return nil }
            guard URL(fileURLWithPath: dir).appendingPathComponent(rel).standardizedFileURL.path.hasPrefix(dir + "/") else {
                refuse(subject, .pathLeaves); return nil
            }
            var prefix = ""
            for part in rel.split(separator: "/") {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                switch reader.kind(path(prefix)) {
                case .missing:
                    refuse(subject, .pathMissing); return nil
                case .symlink:
                    refuse(subject, symlinkReason(prefix)); return nil
                default:
                    break
                }
            }
            switch (want, reader.kind(path(rel))) {
            case (.file, .file), (.dir, .directory): return rel
            case (.file, _): refuse(subject, .needsFile)
            case (.dir, _): refuse(subject, .needsDir)
            }
            return nil
        }

        mutating func check(_ p: KitManifest.Piece, into out: inout KitValidated) {
            switch p.kind {
            case .claudeMD:
                guard let rel = resolve(p.source ?? "", "\(p.id).source", .file) else { return }
                guard rel.lowercased().hasSuffix(".md") else { return refuse("\(p.id).source", .needsMarkdown) }
                guard let text = readText(rel) else { return refuse(rel, .notText) }
                let last = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
                if last != KitValidator.localImportLine { refuse(rel, .localImportLast) }
                if !importsFit(rel, text, level: 0) { refuse(rel, .importTooDeep) }

            case .tools:
                guard let rel = resolve(p.dir ?? "", "\(p.id).dir", .dir) else { return }
                var refs: [KitFileRef] = []
                for name in (reader.names(path(rel)) ?? []) {
                    let r = rel + "/" + name
                    if name.hasPrefix(".") { warn(r, .dotfileSkipped); continue }
                    guard case .file = reader.kind(path(r)) else { refuse(r, .toolsNotFile); continue }
                    guard KitValidator.isFileName(name) else { refuse(r, .badFileName); continue }
                    if !toolNames.insert(name.lowercased()).inserted { refuse(r, .duplicateTool) }
                    executables.insert(r)
                    refs.append(.init(name: name, path: r))
                }
                out.tools[p.id] = refs

            case .hook, .statusline:
                guard let rel = resolve(p.run ?? "", "\(p.id).run", .file) else { return }
                executables.insert(rel)

            case .permissions:
                break

            case .seed:
                guard let rel = resolve(p.from ?? "", "\(p.id).from", .dir) else { return }
                var refs: [KitFileRef] = []
                var ids: Set<String> = []
                for (r, kind) in entries.sorted(by: { $0.key < $1.key }) where r.hasPrefix(rel + "/") {
                    let under = String(r.dropFirst(rel.count + 1))
                    let parts = under.split(separator: "/")
                    if let i = parts.firstIndex(where: { $0.hasPrefix(".") }) {
                        if i == parts.count - 1 { warn(r, .dotfileSkipped) } // inside a dot dir: skipped with it
                        continue
                    }
                    switch kind {
                    case .directory: continue
                    case .symlink: refuse(r, .pathSymlink); continue
                    case .file: break
                    default: refuse(r, .needsFile); continue
                    }
                    guard ManagedConfigPaths.checkRelative(under) == nil, ManagedConfigPaths.checkRelative(r) == nil else {
                        refuse(r, .badPath); continue
                    }
                    let id = KitRender.seedPieceID(p.id, under)
                    guard under.split(separator: "/").allSatisfy({ KitValidator.isFileName(String($0)) }), ManagedConfigPaths.isValidID(id) else {
                        refuse(r, .badFileName); continue
                    }
                    if !ids.insert(id).inserted || !seedTargets.insert(under.lowercased()).inserted { refuse(r, .seedClash); continue }
                    refs.append(.init(name: under, path: r))
                }
                out.seeds[p.id] = refs
            }
        }

        /// errata A2: imports reach at most 2 levels below the kit CLAUDE.md. An import into the
        /// kit is followed; one outside it (a placeholder root, an absolute or ~ path) is a leaf;
        /// a token naming nothing in the kit is not an import. No visited set: the depth bound ends
        /// a cycle (it is refused as too deep). Bound: each kit file is read and scanned at most once
        /// (importCache, text <= 1 MiB); a token costs one lexical path standardization and dictionary
        /// lookups, no I/O; reader.realPath runs at most once per symlink entry (importSymlinks); a file
        /// names at most maxImportTargets distinct files, so the recursion makes at most
        /// 1 + 64 + 64 * 64 importsOf calls, all but the first read of each file served from the cache.
        mutating func importsFit(_ rel: String, _ text: String?, level: Int) -> Bool {
            let imp = importsOf(rel, text)
            if level + 1 > KitValidator.maxImportDepth, imp.outside || !imp.files.isEmpty { return false }
            for r in imp.files {
                if !importsFit(r, nil, level: level + 1) { return false }
            }
            return true
        }

        /// The import tokens of one file, resolved to kit-relative paths and deduped on the path.
        /// An import through a symlink is refused (Claude Code would follow it).
        mutating func importsOf(_ rel: String, _ given: String?) -> (files: [String], outside: Bool) {
            if let hit = importCache[rel] { return hit }
            var files: Set<String> = []
            var seen: Set<String> = []
            var outside = false
            if let text = given ?? readText(rel) {
                let base = (rel as NSString).deletingLastPathComponent
                tokens: for token in Set(KitValidator.imports(in: text)) {
                    guard let r = kitRelative(token, from: base) else { outside = true; continue }
                    guard seen.insert(r).inserted else { continue }
                    var prefix = ""
                    for part in r.split(separator: "/") {
                        prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                        if case .symlink? = entries[prefix] {
                            if importSymlinks.insert(prefix).inserted { refuse(prefix, symlinkReason(prefix)) }
                            continue tokens
                        }
                    }
                    guard case .file? = entries[r] else { continue }
                    files.insert(r)
                    if files.count > KitValidator.maxImportTargets { refuse(rel, .tooManyImports); break }
                }
            }
            let out = (files: files.sorted(), outside: outside)
            importCache[rel] = out
            return out
        }

        /// The kit-relative path an import names, or nil when it points outside the kit.
        func kitRelative(_ target: String, from base: String) -> String? {
            let rel: String
            if target.hasPrefix("{{kit_dir}}/") { rel = String(target.dropFirst("{{kit_dir}}/".count)) }
            else if target.hasPrefix("{{") || target.hasPrefix("/") || target.hasPrefix("~") { return nil }
            else { rel = base.isEmpty ? target : base + "/" + target }
            let std = URL(fileURLWithPath: dir).appendingPathComponent(rel).standardizedFileURL.path
            return std.hasPrefix(dir + "/") ? String(std.dropFirst(dir.count + 1)) : nil
        }

        /// spec 4.9: a market kit runs text only; a local one may carry a binary, with a warning.
        mutating func checkExecutables() {
            for rel in executables.sorted() {
                var text = false
                if case .file(_, let size) = reader.kind(path(rel)), size <= Int64(KitValidator.maxTextBytes),
                   let data = reader.contents(path(rel)) {
                    text = KitValidator.isText(data)
                }
                if !text {
                    if source == .market { refuse(rel, .binaryExecutable) } else { warn(rel, .binaryExecutable) }
                }
            }
        }
    }

    private static let fileNameChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// A tool or seed file name: `[A-Za-z0-9][A-Za-z0-9._-]*`, at most 64 characters.
    static func isFileName(_ s: String) -> Bool {
        guard let f = s.first, f.isASCII, f.isLetter || f.isNumber else { return false }
        return s.count <= 64 && s.allSatisfy { fileNameChars.contains($0) }
    }
}
