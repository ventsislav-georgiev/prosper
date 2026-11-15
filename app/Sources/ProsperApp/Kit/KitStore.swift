import CryptoKit
import Darwin
import Foundation

// #917 S5a (plan C S5, E-1, E-2, E-3, E-7, QA #749 INFO-2): the kit store, first half. It STAGES a kit:
// a no-follow copy of the source into <configHome>/prosper/kits/<ext-id>/staged/<version>+<tree>, the tree
// hash check, the validator on the copy, the Markdown render in the copy, and kit.env. A kit is outside data
// and untrusted code: its files are copied and read as bytes, never executed, sourced or opened as anything
// else. No link is ever followed (lstat, O_NOFOLLOW, a dir opened O_NOFOLLOW before readdir). Every write and
// every remove stays under kits/<ext-id>/ (prosper/ and kits/ are only created when missing). Nothing is logged.
// The swap into live, previous, shims and the stale-temp sweep are S5b's.

enum KitStoreError: Error, Equatable, Sendable {
    case badID, badVersion, badTree, badSlug
    /// a symbolic link where the store needs a dir or a file: refused, never followed ("" = the root)
    case link(String)
    case notADirectory(String)
    /// not a regular file, dir or link (a FIFO, socket, device), or an entry that changed under the copy
    case special(String)
    case setuid(String)
    case unreadableDir(String)
    case badName(String)
    case tooManyFiles, tooDeep, tooLarge
    /// a remove asked for a path that is not strictly inside kits/<ext-id>/
    case outsideStore
    /// kit.env exists but does not hold a recorded slug: never overwritten
    case kitEnvUnreadable
    case io(String, Int32)
}

/// The directory-stream seam (rider R917-s2a-q2): a row can make readdir fail part-way.
protocol KitDirStream: Sendable {
    /// opendir on the dir opened O_NOFOLLOW; nil when it cannot be opened
    func open(_ dir: String) -> (any KitDirHandle)?
}

protocol KitDirHandle: AnyObject {
    /// readdir: the next name's bytes, or nil and the errno it left (0 = the end of the list)
    func next() -> (name: [UInt8]?, error: Int32)
}

struct KitPOSIXDirStream: KitDirStream {
    func open(_ dir: String) -> (any KitDirHandle)? {
        let fd = Darwin.open(dir, O_RDONLY | O_DIRECTORY | KitStore.noFollow)
        guard fd >= 0 else { return nil }
        guard let d = fdopendir(fd) else { _ = close(fd); return nil }
        return Handle(d)
    }

    final class Handle: KitDirHandle {
        let d: UnsafeMutablePointer<DIR>
        init(_ d: UnsafeMutablePointer<DIR>) { self.d = d }
        deinit { closedir(d) }
        func next() -> (name: [UInt8]?, error: Int32) {
            errno = 0
            guard let e = readdir(d) else { return (nil, errno) }
            return (withUnsafeBytes(of: e.pointee.d_name) { raw in Array(raw.prefix { $0 != 0 }) }, 0)
        }
    }
}

/// The store's only way to the disk. Paths are absolute.
protocol KitFS: Sendable {
    /// lstat: a link is `.symlink`, never followed
    func kind(_ path: String) -> KitFileKind
    /// every name but "." and "..", sorted; nil when the dir cannot be opened (a link included) or readdir fails
    func names(_ dir: String) -> [String]?
    /// a regular file's bytes, opened O_NOFOLLOW | O_NONBLOCK; nil for anything else or for more than `limit` bytes
    func read(_ path: String, limit: Int) -> Data?
    /// mkdir 0700 when missing; then the dir is opened O_NOFOLLOW (a link or a file in its place is refused)
    /// and, when `narrow`, set to exactly 0700
    func ensureDir(_ path: String, narrow: Bool) throws
    /// a NEW file (O_CREAT | O_EXCL | O_NOFOLLOW) with exactly `mode`
    func create(_ path: String, _ data: Data, mode: mode_t) throws
    func rename(_ from: String, _ to: String) throws
    /// unlink, or rmdir when `dir`: a link is removed itself, never followed
    func remove(_ path: String, dir: Bool) throws
    var writer: any ManagedConfigFileWriter { get }
}

struct KitPOSIXFS: KitFS {
    var stream: any KitDirStream = KitPOSIXDirStream()
    var writer: any ManagedConfigFileWriter = ManagedConfigPOSIXWriter()

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

    func names(_ dir: String) -> [String]? { KitStore.listNames(dir, stream) }

    func read(_ path: String, limit: Int) -> Data? {
        guard limit >= 0 else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | KitStore.noFollow)
        guard fd >= 0 else { return nil }
        defer { _ = close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= Int64(limit) else { return nil }
        var out = Data()
        let chunk = 1 << 16
        var buf = [UInt8](repeating: 0, count: chunk)
        while true {
            let n = Darwin.read(fd, &buf, chunk)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return out }
            guard n <= limit - out.count else { return nil } // the file grew after fstat
            out.append(contentsOf: buf[0..<n])
        }
    }

    func ensureDir(_ path: String, narrow: Bool) throws {
        if mkdir(path, KitStore.dirMode) != 0, errno != EEXIST { throw KitStoreError.io("mkdir", errno) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | KitStore.noFollow)
        guard fd >= 0 else {
            let e = errno
            throw e == ELOOP ? KitStoreError.link(path) : e == ENOTDIR ? KitStoreError.notADirectory(path) : KitStoreError.io("open", e)
        }
        defer { _ = close(fd) }
        if narrow, fchmod(fd, KitStore.dirMode) != 0 { throw KitStoreError.io("chmod", errno) }
    }

    func create(_ path: String, _ data: Data, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | KitStore.noFollow, mode)
        guard fd >= 0 else { throw KitStoreError.io("create", errno) }
        defer { _ = close(fd) }
        guard fchmod(fd, mode) == 0 else { throw KitStoreError.io("chmod", errno) }
        var off = 0
        while off < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + off, data.count - off) }
            if n < 0 { if errno == EINTR { continue }; throw KitStoreError.io("write", errno) }
            off += n
        }
    }

    func rename(_ from: String, _ to: String) throws {
        guard Darwin.rename(from, to) == 0 else { throw KitStoreError.io("rename", errno) }
    }

    func remove(_ path: String, dir: Bool) throws {
        guard (dir ? rmdir(path) : unlink(path)) == 0 else { throw KitStoreError.io("remove", errno) }
    }
}

/// <configHome>/prosper/kits/<ext-id>/ and what is in it (plan C S5). S5a fills staged/, tmp/ and kit.env;
/// live, previous, bin, fired and state are created here and filled by S5b and later steps.
struct KitStoreLayout: Equatable, Sendable {
    var prosper: String
    var kits: String
    var root: String
    var live: String
    var staged: String
    var previous: String
    var bin: String
    var fired: String
    var tmp: String
    var state: String
    var kitEnv: String
    var piecesJSON: String
    var dirs: [String] { [live, staged, previous, bin, fired, tmp, state] }
}

/// A staged copy: keyed by version AND the announced tree (rider R917-s4b-a).
struct KitStaged: Equatable, Sendable {
    var version: String
    var tree: String
    var path: String
    var source: String
}

struct KitStore: Sendable {
    static let dirMode: mode_t = 0o700
    static let envMode: mode_t = 0o600
    static let noFollow = O_NOFOLLOW
    /// E-7: the caller picks; spec 4.9 for the Marketplace
    static let marketByteCap = 256 << 10
    static let localByteCap = 16 << 20

    let layout: KitStoreLayout
    let fs: any KitFS

    init(configHome: URL, extID: String, fs: any KitFS = KitPOSIXFS()) throws {
        layout = try Self.layout(configHome: configHome, extID: extID)
        self.fs = fs
    }

    static func layout(configHome: URL, extID: String) throws -> KitStoreLayout {
        // the extension id rule of KitValidator.validate: a path component, never "." or "..", no leading "-"
        guard ManagedConfigPaths.isValidID(extID), !extID.allSatisfy({ $0 == "." }), !extID.hasPrefix("-") else {
            throw KitStoreError.badID
        }
        let prosper = configHome.standardizedFileURL.path + "/prosper"
        let root = prosper + "/kits/" + extID
        return KitStoreLayout(prosper: prosper, kits: prosper + "/kits", root: root, live: root + "/live", staged: root + "/staged",
                              previous: root + "/previous", bin: root + "/bin", fired: root + "/fired", tmp: root + "/tmp",
                              state: root + "/state", kitEnv: root + "/kit.env", piecesJSON: root + "/pieces.json")
    }

    /// A version is a path component: 1 to 64 of [A-Za-z0-9._-], starting with a letter or digit ("+" never: it keys the tree).
    static func isValidVersion(_ v: String) -> Bool {
        let ok = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        guard let first = v.utf8.first, v.utf8.count <= 64, v.utf8.allSatisfy({ ok.contains($0) }) else { return false }
        return first != UInt8(ascii: ".") && first != UInt8(ascii: "-")
    }

    static func isTree(_ t: String) -> Bool { t.utf8.count == 64 && t.utf8.allSatisfy { Set("0123456789abcdef".utf8).contains($0) } }

    static func stagedName(_ version: String, _ tree: String) -> String { version + "+" + tree }

    func stagedPath(_ version: String, _ tree: String) -> String { layout.staged + "/" + Self.stagedName(version, tree) }

    /// kits/<ext-id> and its dirs, mode 0700: a wider one is narrowed, a link or a file in a dir's place is refused.
    /// prosper/ and kits/ are created when missing, never re-moded (a link there is refused all the same).
    func ensureLayout() throws {
        try fs.ensureDir(layout.prosper, narrow: false)
        try fs.ensureDir(layout.kits, narrow: false)
        try fs.ensureDir(layout.root, narrow: true)
        for d in layout.dirs { try fs.ensureDir(d, narrow: true) }
    }

    /// readdir through the stream seam; a read error part-way is nil, never a short list.
    static func listNames(_ dir: String, _ stream: any KitDirStream) -> [String]? {
        guard let h = stream.open(dir) else { return nil }
        var out: [String] = []
        while out.count <= KitValidator.maxEntries { // one past the bound is enough for the walk to refuse
            let (bytes, error) = h.next()
            guard let bytes else { if error != 0 { return nil }; break }
            let name = KitPOSIXFileReader.name(bytes)
            if name != ".", name != ".." { out.append(name) }
        }
        return out.sorted()
    }

    /// One entry of a walk: `mode` nil for a dir; a file's mode is normalized (see `copyMode`).
    struct Entry: Equatable {
        var rel: String
        var mode: mode_t?
        var data: Data
    }

    /// A copied file keeps the owner bits only: 0700 when the source has ANY x bit (so the validator still sees an
    /// executable), else 0600. setuid / setgid are refused before this.
    static func copyMode(_ mode: UInt16) -> mode_t { mode & 0o111 != 0 ? 0o700 : 0o600 }

    /// The no-follow walk the copy, the hash and the render share. The validator's bounds apply DURING the walk
    /// (4096 entries, a dir 16 deep refused, KitValidator.swift:267-275), and so does the byte cap: a huge tree stops early.
    func walk(_ root: String, byteCap: Int) throws -> [Entry] {
        guard byteCap >= 0 else { throw KitStoreError.tooLarge }
        switch fs.kind(root) {
        case .directory: break
        case .symlink: throw KitStoreError.link("")
        default: throw KitStoreError.notADirectory("")
        }
        var out: [Entry] = []
        var stack: [(rel: String, depth: Int)] = [("", 0)]
        var count = 0
        var bytes = 0
        while let top = stack.popLast() {
            let (rel, depth) = top
            guard let names = fs.names(rel.isEmpty ? root : root + "/" + rel) else { throw KitStoreError.unreadableDir(rel) }
            for name in names {
                count += 1
                guard count <= KitValidator.maxEntries else { throw KitStoreError.tooManyFiles }
                guard !name.isEmpty, !name.contains("/"), !name.contains("\0") else { throw KitStoreError.badName(rel) }
                let r = rel.isEmpty ? name : rel + "/" + name
                switch fs.kind(root + "/" + r) {
                case .directory:
                    guard depth + 1 < KitValidator.maxDepth else { throw KitStoreError.tooDeep }
                    out.append(Entry(rel: r, mode: nil, data: Data()))
                    stack.append((r, depth + 1))
                case .file(let mode, let size):
                    guard mode & 0o6000 == 0 else { throw KitStoreError.setuid(r) }
                    let room = byteCap - bytes
                    guard size <= Int64(room) else { throw KitStoreError.tooLarge }
                    guard let data = fs.read(root + "/" + r, limit: room) else { throw KitStoreError.special(r) }
                    bytes += data.count
                    out.append(Entry(rel: r, mode: Self.copyMode(mode), data: data))
                case .symlink: throw KitStoreError.link(r)
                case .missing, .other: throw KitStoreError.special(r)
                }
            }
        }
        return out
    }

    /// Copies `source` into staged/<version>+<tree> through tmp/ and ONE rename at the end. A refused or failed copy
    /// leaves no staged dir; its tmp dir is removed by the store's own remove. `tree` is the ANNOUNCED tree: `verify`
    /// checks the copy against it. A copy already staged under the same version and tree is replaced.
    func stageCopy(from source: String, version: String, tree: String, byteCap: Int) throws -> KitStaged {
        guard Self.isValidVersion(version) else { throw KitStoreError.badVersion }
        guard Self.isTree(tree) else { throw KitStoreError.badTree }
        let entries = try walk(source, byteCap: byteCap)
        try ensureLayout()
        let tmp = layout.tmp + "/" + UUID().uuidString
        try fs.ensureDir(tmp, narrow: true)
        do {
            // a dir's entry precedes its children's (the walk lists a dir before it lists the dir's names)
            for e in entries {
                if let mode = e.mode { try fs.create(tmp + "/" + e.rel, e.data, mode: mode) } else { try fs.ensureDir(tmp + "/" + e.rel, narrow: true) }
            }
            let dest = stagedPath(version, tree)
            if fs.kind(dest) != .missing { try removeTree(dest) }
            try fs.rename(tmp, dest)
            return KitStaged(version: version, tree: tree, path: dest, source: source)
        } catch {
            try? removeTree(tmp)
            throw error
        }
    }

    /// Hex SHA-256 of a tree. Entries sorted by the UTF-8 bytes of their relative path; each entry adds
    ///   1 byte tag ("d" dir, "f" file) | 2 bytes mode, big-endian (0700 for a dir, `copyMode` for a file) |
    ///   8 bytes path length, big-endian | path bytes | 8 bytes content length, big-endian | content bytes (none for a dir).
    /// Every variable field is length-prefixed, so two different trees cannot meet by concatenation.
    /// The root itself is not an entry. A link, special file or bound hit throws, as in the copy.
    func treeHash(of dir: String, byteCap: Int = KitStore.localByteCap) throws -> String {
        let entries = try walk(dir, byteCap: byteCap).sorted { $0.rel.utf8.lexicographicallyPrecedes($1.rel.utf8) }
        var h = SHA256()
        for e in entries {
            h.update(data: [e.mode == nil ? UInt8(ascii: "d") : UInt8(ascii: "f")])
            var m = UInt16(e.mode ?? Self.dirMode).bigEndian
            withUnsafeBytes(of: &m) { h.update(bufferPointer: $0) }
            Self.frame(Data(e.rel.utf8), into: &h)
            Self.frame(e.data, into: &h)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func frame(_ d: Data, into h: inout SHA256) {
        var n = UInt64(d.count).bigEndian
        withUnsafeBytes(of: &n) { h.update(bufferPointer: $0) }
        h.update(data: d)
    }

    /// nil when the copy hashes to the announced tree; else the machine's answer (rider R917-s4b-b).
    /// Run it before `render`: the render changes the Markdown bytes.
    func verify(_ s: KitStaged) -> KitUpdateEvent? {
        guard let h = try? treeHash(of: s.path), h == s.tree else { return .validationRefused(s.version, tree: s.tree) }
        return nil
    }

    /// QA #749 INFO-2: the validator sees the staged COPY only, never the source.
    func validate(_ s: KitStaged, manifest: ExtensionManifest, source: KitInstallSource, otherKitSlugs: Set<String>,
                  reader: any KitFileReader = KitPOSIXFileReader()) -> KitValidation {
        KitValidator.validate(kitDir: URL(fileURLWithPath: s.path, isDirectory: true), manifest: manifest, source: source,
                              otherKitSlugs: otherKitSlugs, reader: reader)
    }

    /// spec 4.2 / 4.12 test 2: `*.md` in the staged copy rendered in place through the atomic writer, mode kept;
    /// every other file is never rewritten.
    func render(_ s: KitStaged, _ c: KitRenderContext) throws {
        for e in try walk(s.path, byteCap: Self.localByteCap) where e.mode != nil && KitRender.isRendered(e.rel) {
            let out = KitRender.renderFile(e.rel, e.data, c)
            guard out != e.data, let mode = e.mode else { continue }
            let target = URL(fileURLWithPath: s.path + "/" + e.rel)
            try fs.writer.replace(target, with: fs.writer.writeTemp(Array(out), besides: target, mode: mode))
        }
    }

    /// Rider R917-s4b-a: the drop names the tree it means; a drop for a tree that is not staged removes nothing.
    func dropStaged(version: String, tree: String) throws {
        guard Self.isValidVersion(version), Self.isTree(tree) else { return }
        try removeTree(stagedPath(version, tree))
    }

    /// E-2: the slug recorded at first apply. A later call returns the recorded one and writes nothing.
    func recordSlug(_ slug: String) throws -> String {
        guard ManagedConfigPaths.isValidSlug(slug), !slug.hasPrefix("-") else { throw KitStoreError.badSlug }
        if let old = recordedSlug() { return old }
        guard fs.kind(layout.kitEnv) == .missing else { throw KitStoreError.kitEnvUnreadable }
        try ensureLayout()
        let target = URL(fileURLWithPath: layout.kitEnv)
        try fs.writer.replace(target, with: fs.writer.writeTemp(Array("KIT_SLUG='\(slug)'\n".utf8), besides: target, mode: Self.envMode))
        return slug
    }

    /// The slug kit.env records; nil when there is none or it is not a valid slug. Parsed as text, never sourced.
    func recordedSlug() -> String? {
        guard let d = fs.read(layout.kitEnv, limit: 4096), let text = String(data: d, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("KIT_SLUG='") && line.hasSuffix("'") && line.count > 11 {
            let slug = String(line.dropFirst(10).dropLast())
            return ManagedConfigPaths.isValidSlug(slug) && !slug.hasPrefix("-") ? slug : nil
        }
        return nil
    }

    /// The store's only remove: strictly inside kits/<ext-id>/, never a glob; a link is unlinked, never followed.
    func removeTree(_ path: String) throws {
        let head = layout.root + "/"
        let parts: [Substring] = path.hasPrefix(head) ? path.dropFirst(head.count).split(separator: "/", omittingEmptySubsequences: false) : []
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw KitStoreError.outsideStore }
        var stack: [(path: String, listed: Bool)] = [(path, false)]
        while let top = stack.popLast() {
            switch fs.kind(top.path) {
            case .missing: continue
            case .directory where !top.listed:
                guard let names = fs.names(top.path) else { throw KitStoreError.unreadableDir(top.path) }
                stack.append((top.path, true))
                for n in names where !n.isEmpty && !n.contains("/") { stack.append((top.path + "/" + n, false)) }
            case .directory: try fs.remove(top.path, dir: true)
            default: try fs.remove(top.path, dir: false)
            }
        }
    }
}
